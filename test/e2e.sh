#!/usr/bin/env bash
# SC2015: A && pass || fail is intended. SC2016: the remote shell expands.
# shellcheck disable=SC2015,SC2016
# End-to-end test: start an rtest container, then drive it with the client.
#
#   test/e2e.sh              uses the image rtest:dev and builds the client
#   RTEST_IMAGE=x RTEST_BIN=/path/to/rtest test/e2e.sh
#
# It works with bash 3.2 (macOS) and with bash 5 (Linux CI).
set -uo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd -P)
image=${RTEST_IMAGE:-rtest:dev}
name=rtest-e2e-$$
work=$(mktemp -d "${TMPDIR:-/tmp}/rtest-e2e.XXXXXX")
work=$(cd "$work" && pwd -P)
failures=0
rtest=${RTEST_BIN:-}
if [ -z "$rtest" ]; then
  rtest=$work/rtest
  (cd "$repo" && go build -o "$rtest" ./cmd/rtest) || exit 1
fi
# The client keeps its SSH control sockets in the user cache directory.
if [ "$(uname)" = Darwin ]; then
  controls=$HOME/Library/Caches/rtest
else
  controls=${XDG_CACHE_HOME:-$HOME/.cache}/rtest
fi

cleanup() {
  ssh -F "$work/ssh_config" -o ControlPath="$controls/%C" -O exit rtest-e2e >/dev/null 2>&1
  docker rm -f -v "$name" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  [ -z "${2:-}" ] || sed 's/^/      /' "$2"
  failures=$((failures + 1))
}
# expect NAME STATUS COMMAND...: run COMMAND, compare its exit status.
expect() {
  local label=$1 want=$2
  shift 2
  "$@" >"$work/out" 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then pass "$label"; else
    echo "exit status $got, want $want" >>"$work/out"
    fail "$label" "$work/out"
  fi
}
remote() { ssh -F "$work/ssh_config" rtest-e2e "$@"; }

echo "== start $image"
ssh-keygen -q -t ed25519 -N '' -f "$work/key"
docker run -d --name "$name" --privileged \
  -e RTEST_AUTHORIZED_KEYS="$(cat "$work/key.pub")" -e RTEST_MAX_RUNS=2 \
  -e RTEST_MIN_FREE_MEMORY_MB=0 -e RTEST_MAX_LOAD=0 \
  -p 127.0.0.1::22 "$image" >/dev/null || exit 1
port=$(docker port "$name" 22/tcp | head -n 1 | sed 's/.*://')
cat >"$work/ssh_config" <<EOF
Host rtest-e2e
  HostName 127.0.0.1
  Port $port
  User runner
  IdentityFile $work/key
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
export RTEST_SSH="ssh -F $work/ssh_config" RTEST_HOST=rtest-e2e
for _ in $(seq 90); do
  remote rtest-healthcheck >/dev/null 2>&1 && break
  sleep 1
done
expect 'server is healthy (sshd and dockerd)' 0 remote rtest-healthcheck

echo "== fixture project"
proj=$work/proj
mkdir -p "$proj/sub" "$proj/build" "$proj/rs/src" "$proj/js" "$proj/py"
cd "$proj" || exit 1
cat >go.mod <<'EOF'
module example.com/proj

go 1.27
EOF
cat >proj_test.go <<'EOF'
package proj

import (
	"os"
	"testing"
)

func TestPass(t *testing.T) {}

func TestFail(t *testing.T) {
	if os.Getenv("E2E_FAIL") == "1" {
		t.Fatal("failure requested")
	}
}
EOF
printf 'hello\n' >sub/hello.txt
printf 'ignored.txt\nbuild/\n' >.gitignore
printf 'secret\n' >ignored.txt
printf 'artifact\n' >build/out
dd if=/dev/urandom of=big.bin bs=1024 count=4096 2>/dev/null
cat >rs/Cargo.toml <<'EOF'
[package]
name = "e2e"
version = "0.1.0"
edition = "2021"
EOF
printf '#[test]\nfn adds() { assert_eq!(1 + 1, 2); }\n' >rs/src/lib.rs
printf '{"name":"e2e","private":true,"scripts":{"test":"node --test"}}\n' >js/package.json
printf "const test = require('node:test');\ntest('adds', () => {});\n" >js/add.test.js
printf 'import unittest\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(1 + 1, 2)\n' >py/test_add.py
git init -q && git add -A && git -c user.name=e2e -c user.email=e2e@example.com commit -qm init
git remote add origin https://example.com/e2e/proj.git

echo "== runs"
expect 'toolchains are installed' 0 "$rtest" -q \
  'go version && node --version && pnpm --version && python3 --version && uv --version && rustc --version && cargo --version && sccache --version'
expect 'passing go test exits 0' 0 "$rtest" -q go test ./...
expect 'exit status passes through' 7 "$rtest" -q 'exit 7'
expect 'failing go test exits 1 (--env)' 1 "$rtest" -q -e E2E_FAIL=1 go test -run TestFail ./...
grep -q 'failure requested' "$work/out" && pass 'failing test output streams back' || fail 'failing test output streams back' "$work/out"
expect 'rust test with sccache' 0 "$rtest" -q 'cd rs && cargo test -q'
expect 'node test' 0 "$rtest" -q 'cd js && npm test --silent'
expect 'python test' 0 "$rtest" -q 'cd py && python3 -m unittest -q'
expect 'docker in docker' 0 "$rtest" -q 'docker run --rm busybox:1.37 echo dind-ok'
grep -q dind-ok "$work/out" && pass 'docker output streams back' || fail 'docker output streams back' "$work/out"

"$rtest" -q 'echo to-stdout; echo to-stderr >&2' >"$work/stdout" 2>"$work/stderr"
if [ "$(cat "$work/stdout")" = to-stdout ] && [ "$(cat "$work/stderr")" = to-stderr ]; then
  pass 'stdout and stderr stay separate'
else fail 'stdout and stderr stay separate' "$work/stderr"; fi

# With a terminal, rtest asks SSH for a remote terminal. script(1) fakes one.
if [ "$(uname)" = Darwin ]; then
  script -q "$work/tty" "$rtest" -q 'test -t 1 && echo has-tty; exit 3' </dev/null >/dev/null 2>&1
else
  script -qec "$rtest -q 'test -t 1 && echo has-tty; exit 3'" "$work/tty" </dev/null >/dev/null 2>&1
fi
got=$?
if [ "$got" = 3 ] && grep -q has-tty "$work/tty"; then pass 'terminal mode: remote terminal and exit status'; else
  echo "exit status $got" >>"$work/tty"; fail 'terminal mode: remote terminal and exit status' "$work/tty"; fi

out=$(cd sub && "$rtest" -q 'pwd; test -f hello.txt && echo found')
case $out in */sub*found) pass 'runs from the same relative directory' ;; *) echo "$out" >"$work/out"; fail 'runs from the same relative directory' "$work/out" ;; esac

expect 'ignored files and .git are not sent' 0 "$rtest" -q \
  'test ! -e ignored.txt && test ! -e build && test ! -e .git && test -f big.bin && test -f .gitignore'
expect 'remote copies are deleted after the run' 0 remote 'test -z "$(ls -A /work/runs)"'

echo "== cache"
before=$(remote 'stat -c %i /work/sources/proj-*/big.bin')
"$rtest" -q true
after=$(remote 'stat -c %i /work/sources/proj-*/big.bin')
[ -n "$before" ] && [ "$before" = "$after" ] && pass 'unchanged files are not sent again' ||
  { echo "inode $before then $after" >"$work/out"; fail 'unchanged files are not sent again' "$work/out"; }
printf 'changed\n' >sub/hello.txt
expect 'changed files are sent' 0 "$rtest" -q 'grep -q changed sub/hello.txt'
mv sub/hello.txt "$work/hello.txt"
expect 'deleted files disappear' 0 "$rtest" -q 'test ! -e sub/hello.txt'
mv "$work/hello.txt" sub/hello.txt

cp -R "$proj" "$work/proj2"
"$rtest" -C "$work/proj2" true >"$work/out" 2>&1
grep -q 'seeding it from proj-' "$work/out" && pass 'a new worktree starts from the mirror of the same repository' ||
  fail 'a new worktree starts from the mirror of the same repository' "$work/out"

echo "== parallel runs and queue (RTEST_MAX_RUNS=2)"
start=$(date +%s)
pids=''
for i in 1 2 3 4; do
  "$rtest" "sleep 4; echo run-$i" >"$work/par-$i" 2>&1 &
  pids="$pids $!"
done
ok=1
for p in $pids; do wait "$p" || ok=0; done
elapsed=$(($(date +%s) - start))
for i in 1 2 3 4; do grep -q "run-$i" "$work/par-$i" || ok=0; done
if [ "$ok" = 1 ] && [ "$elapsed" -ge 8 ] && [ "$elapsed" -lt 14 ]; then
  pass "4 runs of 4s, 2 at a time, finished in ${elapsed}s"
else
  cat "$work"/par-* >"$work/out"; echo "elapsed ${elapsed}s" >>"$work/out"; fail 'parallel runs, 2 at a time' "$work/out"; fi
cat "$work"/par-* >"$work/out"
grep -q 'queued at position 1, 2 of 2 runs in progress' "$work/out" && grep -q 'started after about' "$work/out" &&
  pass 'queued runs say why they wait, then start' || fail 'queued runs say why they wait, then start' "$work/out"
expect 'remote copies and queue entries are deleted after parallel runs' 0 \
  remote 'test -z "$(find /work/runs /work/queue /work/active -mindepth 1 -maxdepth 1)"'

# The memory gate holds a run while another run is in progress, and the run
# starts when the host is idle.
"$rtest" -q 'sleep 6' >/dev/null 2>&1 &
holder=$!
for _ in $(seq 20); do
  [ "$(remote 'ls /work/active | wc -l')" -ge 1 ] && break
  sleep 0.5
done
remote 'mkdir /work/runs/memtest && RTEST_MIN_FREE_MEMORY_MB=99999999 rtest-exec memtest '"$(printf 'echo mem-ok' | base64)" \
  < <(sleep 30) >"$work/out" 2>&1
got=$?
wait "$holder"
if [ "$got" = 0 ] && grep -q 'MB of memory free, 99999999 MB needed' "$work/out" && grep -q mem-ok "$work/out"; then
  pass 'low memory holds a run until the host is idle'
else echo "exit status $got" >>"$work/out"; fail 'low memory holds a run until the host is idle' "$work/out"; fi

# A client that goes away while queued leaves no ticket and no copy.
"$rtest" -q 'sleep 20' >/dev/null 2>&1 &
h1=$!
"$rtest" -q 'sleep 20' >/dev/null 2>&1 &
h2=$!
for _ in $(seq 20); do
  [ "$(remote 'ls /work/active | wc -l')" -ge 2 ] && break
  sleep 0.5
done
"$rtest" -q 'echo never' >"$work/out" 2>&1 &
queued=$!
for _ in $(seq 20); do
  [ "$(remote 'ls /work/queue | wc -l')" -ge 1 ] && break
  sleep 0.5
done
kill "$queued"
sleep 4
expect 'a client that leaves the queue leaves no ticket and no copy' 0 \
  remote 'ls /work/queue /work/active /work/runs; test -z "$(ls -A /work/queue)" && test "$(ls /work/runs | wc -l)" -eq 2'
kill "$h1" "$h2" 2>/dev/null
wait "$h1" "$h2" 2>/dev/null

echo "== timeout, disconnect"

start=$(date +%s)
expect '--timeout stops the command with exit status 124' 124 "$rtest" -q -t 2 sleep 60
[ $(($(date +%s) - start)) -lt 20 ] && pass 'timeout is prompt' || fail 'timeout is prompt'

"$rtest" -q 'sleep 300' >/dev/null 2>&1 &
client=$!
for _ in $(seq 30); do
  remote 'pgrep -f "^sleep 300"' >/dev/null 2>&1 && break
  sleep 1
done
kill "$client"
gone=0
for _ in $(seq 20); do
  if ! remote 'pgrep -f "^sleep 300"' >/dev/null 2>&1 && remote 'test -z "$(ls -A /work/runs)"'; then
    gone=1
    break
  fi
  sleep 1
done
[ "$gone" = 1 ] && pass 'killing the client stops the remote command and deletes the copy' ||
  fail 'killing the client stops the remote command and deletes the copy'

echo "== janitor and info"
remote 'mkdir /work/runs/orphan && touch -d "3 hours ago" /work/runs/orphan'
docker exec "$name" rtest-janitor >/dev/null 2>&1
expect 'janitor deletes orphan copies' 0 remote 'test ! -e /work/runs/orphan'
expect 'rtest --info' 0 "$rtest" --info
grep -q '^go ' "$work/out" && pass '--info prints versions' || fail '--info prints versions' "$work/out"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  docker logs "$name" 2>&1 | tail -n 30
  exit 1
fi
echo 'all checks passed'
