# shellcheck shell=bash
# Shared helpers for the rtest server scripts.

# shellcheck disable=SC2034 # used by the scripts that source this file
RTEST_ROOT=/work
RTEST_SOURCES=$RTEST_ROOT/sources
RTEST_RUNS=$RTEST_ROOT/runs
RTEST_STATE=$RTEST_ROOT/state
RTEST_LOCKS=$RTEST_ROOT/locks

# SSH sessions do not inherit the container environment. Load the toolchain
# environment and the configuration that the entrypoint wrote.
load_env() {
  set -a
  # shellcheck disable=SC1091
  [ -r /etc/environment ] && . /etc/environment
  # shellcheck disable=SC1091
  [ -r /run/rtest.env ] && . /run/rtest.env
  set +a
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
