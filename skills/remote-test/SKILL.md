---
name: remote-test
description: Run tests, builds and other checks on the remote rtest server over SSH, with `rtest <command>`. Use it for requests like "run it remotely", "offload the tests", "run on the test box", or "use rtest". Also use it for a heavy, slow or Docker-dependent test suite (Go, Node, Python, Rust, testcontainers). Also use it to run several test suites in parallel without loading this machine.
---

# Remote test runs with rtest

`rtest` copies the current project to the rtest server. It runs one command
there from the same relative directory and streams the output. It exits with
the exit status of the command. When the command ends, rtest deletes the remote copy.
A non-zero exit status is a failure, exactly as for a local run.

## Before the first run

1. Find the client. Use the first path that works as `rtest` in the commands
   below:

   ```bash
   command -v rtest || ls ~/.local/bin/rtest
   ```

2. If the client is missing, install it, then tell the user that you did. The
   script downloads the latest release for this platform, makes sure that its
   checksum is correct, and installs `~/.local/bin/rtest`:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/tomMoulard/rtest/main/install.sh | sh
   ```

3. Run `rtest --info` once per session. It prints the toolchain versions on
   the server. If it fails with exit status 255, SSH cannot reach the server.
   Tell the user, and do not fall back to a local run without asking. The
   user configures the server as the SSH host `rtest` in `~/.ssh/config`, or
   sets `RTEST_HOST`.

## Run a command

```bash
rtest go test ./...                       # one command and its arguments
rtest 'go vet ./... && go test -race ./...'   # one argument = a shell script
rtest -e LOG_LEVEL=debug pytest -x tests/   # set a variable for the command
rtest -t 900 cargo test --workspace         # stop after 900 seconds (exit 124)
```

- Run `rtest` from the directory of a local run. rtest runs the command from
  the same directory, relative to the project root.
- The server has no virtual environment and no `node_modules`, because rtest
  does not send ignored files. Install the dependencies in the same command:
  `rtest 'npm ci && npm test'`, `rtest 'uv sync && uv run pytest'`. The
  package caches on the server make this fast after the first run.
- The server has Docker. Tests that start containers (testcontainers,
  `docker compose`) work.
- `CI=true` is set on the server.

## Run in parallel

Each `rtest` call gets its own copy, so parallel calls do not interfere. Start
independent suites as separate background commands, then read each result:

```bash
rtest 'go test ./pkg/a/...' >/tmp/a.log 2>&1 & a=$!
rtest 'go test ./pkg/b/...' >/tmp/b.log 2>&1 & b=$!
wait $a; echo "a: $?"; wait $b; echo "b: $?"
```

In Claude Code, you can also start each `rtest` call as its own background
Bash command.

## Read the result

| Exit status | Meaning |
|---|---|
| 0 | The command passed. |
| 1 to 123 | The command failed. Read its output. |
| 124 | `--timeout` stopped the command. |
| 125 | rtest did not prepare the run, for example because the sync failed. |
| 255 | SSH failed. The command did not run, or the connection broke. |

Report a test failure from the output, as for a local run. Report 125 and 255
as infrastructure problems, not as test failures.

## Limits

- Files that the command writes on the server do not come back. Do not use
  rtest for commands that must change local files: code generation,
  formatters, snapshot updates, `go mod tidy`. Run those locally.
- To inspect the remote files after a run, add `--keep`. rtest prints the path
  of the kept copy, and the server deletes it after about one hour.
- rtest sends the files that git does not ignore, including uncommitted and
  untracked files. It never sends `.git`.
