# shellcheck shell=bash
# Shared helpers for the rtest server scripts.

# shellcheck disable=SC2034 # used by the scripts that source this file
RTEST_ROOT=/work
RTEST_SOURCES=$RTEST_ROOT/sources
RTEST_RUNS=$RTEST_ROOT/runs
RTEST_STATE=$RTEST_ROOT/state
RTEST_LOCKS=$RTEST_ROOT/locks
RTEST_QUEUE=$RTEST_ROOT/queue
RTEST_ACTIVE=$RTEST_ROOT/active

# SSH sessions do not inherit the container environment. Load the toolchain
# environment and the configuration that the entrypoint wrote.
load_env() {
  set -a
  # shellcheck disable=SC1091
  [ -r /etc/environment ] && . /etc/environment
  set +a
  # The container configuration. A variable that the session sets wins.
  local name value
  if [ -r /run/rtest.env ]; then
    while IFS='=' read -r name value; do
      [ -n "${!name+x}" ] || eval "export $name=$value"
    done </run/rtest.env
  fi
}

die() {
  echo "rtest: $*" >&2
  exit 125
}

# A name is safe for a path component: letters, digits, dot, dash, underscore.
check_name() {
  case $1 in
    '' | .* | *[!A-Za-z0-9._-]*) die "invalid name: '$1'" ;;
  esac
  [ ${#1} -le 128 ] || die "name too long: '$1'"
}

# prune DIR deletes the queue entries whose process is gone. Each entry holds
# the process ID of its rtest-exec.
prune() {
  local entry pid
  for entry in "$1"/*; do
    [ -e "$entry" ] || continue
    pid=$(cat "$entry" 2>/dev/null)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$entry"
    fi
  done
}

# available_mb prints the available memory in MB: the smaller of the host
# available memory and the room left under the container memory limit.
available_mb() {
  local mem limit used
  mem=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
  if [ -r /sys/fs/cgroup/memory.max ]; then
    limit=$(cat /sys/fs/cgroup/memory.max)
    used=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)
    if [ "$limit" != max ] && [ $(((limit - used) / 1048576)) -lt "$mem" ]; then
      mem=$(((limit - used) / 1048576))
    fi
  fi
  echo "$mem"
}

# admit ACTIVE succeeds when the host has room for one more run, with ACTIVE
# runs in progress. On failure, it sets $why. With no run in progress, a run
# always starts, so that the queue cannot block forever.
#   RTEST_MAX_RUNS            most runs at the same time (default: CPU count, 0: no limit)
#   RTEST_MIN_FREE_MEMORY_MB  memory that must stay free (default: 1024, 0: no limit)
#   RTEST_MAX_LOAD            1-minute load average limit (default: CPU count, 0: no limit)
admit() {
  local active=$1 cpus max_runs min_mem max_load mem load
  why=''
  [ "$active" -gt 0 ] || return 0
  cpus=$(nproc)
  max_runs=${RTEST_MAX_RUNS:-$cpus}
  min_mem=${RTEST_MIN_FREE_MEMORY_MB:-1024}
  max_load=${RTEST_MAX_LOAD:-$cpus}

  if [ "$max_runs" -gt 0 ] && [ "$active" -ge "$max_runs" ]; then
    why="$active of $max_runs runs in progress"
    return 1
  fi
  mem=$(available_mb)
  if [ "$min_mem" -gt 0 ] && [ "$mem" -lt "$min_mem" ]; then
    why="${mem} MB of memory free, ${min_mem} MB needed"
    return 1
  fi
  load=$(cut -d ' ' -f 1 /proc/loadavg)
  if awk -v l="$load" -v m="$max_load" 'BEGIN { exit !(m > 0 && l >= m) }'; then
    why="load average $load, limit $max_load"
    return 1
  fi
  return 0
}
