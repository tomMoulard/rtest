# rtest

rtest runs your tests on a remote machine over SSH. You type
`rtest go test ./...` on your laptop. The test runs on the server, the output
streams back to your terminal, and `rtest` exits with the exit status of the
test. A non-zero exit status is a failure, as in CI.

The repository has three parts:

1. A Docker image: an SSH server with Go, Node, Python, Rust and Docker-in-Docker.
2. The `rtest` client: one Go binary for macOS and Linux.
3. A `remote-test` skill: it tells Claude Code and Codex how to use `rtest`.

## How a run works

```text
laptop                                    rtest server (/work)
------                                    --------------------
rtest go test ./...
  1. rsync the changed files   ------->   sources/<mirror>/     one mirror per checkout
                                          runs/<run>/           private copy for this run
  2. ssh rtest-exec            ------->   cd runs/<run>/<same subdirectory>
     output                    <-------   go test ./...
     exit status               <-------   exit status, then delete runs/<run>/
```

1. The client sends the project to a mirror on the server. rsync sends only the files that changed since the last run.
2. The server copies the mirror into a private directory for this run. Parallel runs do not share files.
3. If the host is busy, the run waits in a queue. See [Queue](#queue).
4. The server runs the command from the same subdirectory as your shell.
5. The output streams back. stdout and stderr stay separate.
6. The client exits with the exit status of the command.
7. The server deletes the private directory. The mirror stays for the next run.

## What the image contains

| Tool | Version | Notes |
|---|---|---|
| Go | 1.27.4 | `GOTOOLCHAIN=auto` downloads the version that `go.mod` asks for. |
| Node.js | 26.12.1 | npm, pnpm and yarn. |
| Python | 3.13 | `python3`, `venv`, `pip`, and `uv` for other Python versions. |
| Rust | stable | rustup, clippy, rustfmt. `rust-toolchain.toml` works. sccache caches the compiled crates. |
| Docker | latest | Docker engine, buildx and compose, inside the container (Docker-in-Docker). |
| Other | | `git`, `make`, `build-essential`, `pkg-config`, `libssl-dev`, `jq`, `curl`, `rsync`. |

The image sets `CI=true` for every run. The build arguments `GO_VERSION`,
`NODE_VERSION`, `RUST_VERSION`, `UV_VERSION` and `SCCACHE_VERSION` change the
versions.

## Run the server

The server is one container. It needs `privileged: true`, because Docker runs
inside it.

> Warning: a privileged container has root access to the host. Give SSH access
> only to people that you trust with root on the host.

### With make-my-server

make-my-server includes rtest as the `rtest` service. See
`rtest/README.md` in make-my-server.

### With Docker Compose

1. Put your SSH public key in `conf/authorized_keys`:

   ```bash
   mkdir -p conf && cat ~/.ssh/id_ed25519.pub >> conf/authorized_keys
   ```

2. Start the container:

   ```bash
   docker compose up -d
   ```

3. Make sure that the server answers:

   ```bash
   ssh -p 2222 runner@<server> rtest-info
   ```

The container listens on port 2222. Set `RTEST_SSH_PORT` to change it.

### Server configuration

| Variable | Default | Effect |
|---|---|---|
| `RTEST_AUTHORIZED_KEYS` | empty | SSH public keys, one per line. They add to `/etc/rtest/authorized_keys`. |
| `RTEST_COPY_MODE` | `copy` | `copy` gives each run a full copy of the mirror. `hardlink` is faster for very large projects, see [Cache](#cache). |
| `RTEST_MAX_RUNS` | CPU count | The most runs at the same time. `0` removes the limit. See [Queue](#queue). |
| `RTEST_MIN_FREE_MEMORY_MB` | `1024` | A new run waits while less memory is free. `0` removes the limit. |
| `RTEST_MAX_LOAD` | CPU count | A new run waits while the 1-minute load average is at or above this value. `0` removes the limit. |
| `RTEST_ORPHAN_MINUTES` | `60` | The janitor deletes a run directory that no process owns after this time. |
| `RTEST_SOURCE_TTL_DAYS` | `14` | The janitor deletes a mirror that nobody used for this number of days. |
| `RTEST_DOCKER_PRUNE_UNTIL` | `72h` | The janitor deletes stopped containers, unused images and networks older than this, and all unused volumes. Set `off` to disable it. |

### Volumes

| Path | Content |
|---|---|
| `/etc/rtest` | `authorized_keys`. Mount it read-only. |
| `/work` | Mirrors, run directories, package caches, and the SSH host key. |
| `/var/lib/docker` | The images and containers of the inner Docker engine. Use a named volume: the inner engine needs overlayfs, and a bind mount on macOS does not support it. |

Keep `/work` on one volume. Hard links and reflinks work only inside one file
system, and the caches use them.

## Install the client

1. Install the client in `~/.local/bin`. The script downloads the latest
   release for your platform and makes sure that its checksum is correct:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/tomMoulard/rtest/main/install.sh | sh
   ```

   With Go, you can also build it: `go install github.com/tomMoulard/rtest/cmd/rtest@latest`.
   The [releases page](https://github.com/tomMoulard/rtest/releases) has the
   archives for macOS and Linux, on amd64 and arm64.

2. Add the server to `~/.ssh/config`. The client uses the host name `rtest` by default:

   ```text
   Host rtest
     HostName <server>
     Port 2222
     User runner
   ```

3. Make sure that the client reaches the server:

   ```bash
   rtest --info
   ```

The client calls your `ssh` and `rsync` commands, so your SSH configuration,
agent and jump hosts apply. The macOS versions of `ssh` and `rsync` work.

The install script reads two variables. `RTEST_VERSION` selects a release tag
instead of the latest release. `RTEST_INSTALL_DIR` selects another directory.

## Use the client

```bash
rtest go test ./...                          # a command and its arguments
rtest 'go vet ./... && go test -race ./...'  # one argument is a shell script
cd pkg/api && rtest go test ./...            # runs from pkg/api on the server
rtest -e LOG_LEVEL=debug pytest -x           # set a variable for the command
rtest -t 600 cargo test                      # stop after 600 seconds
rtest 'npm ci && npm test'                   # install the dependencies first
rtest -H other-box make test                 # use another SSH host
```

| Option | Effect |
|---|---|
| `-H, --host HOST` | SSH destination. The default is `$RTEST_HOST`, else `rtest`. |
| `-C, --dir DIR` | Project directory to send. The default is the git top level, else the current directory. |
| `-e, --env NAME=VALUE` | Set a variable for the command. You can repeat it. |
| `-t, --timeout SECS` | Stop the command after SECS seconds. The exit status is then 124. |
| `-k, --keep` | Keep the remote copy for debugging. The janitor deletes it after `RTEST_ORPHAN_MINUTES`. |
| `-q, --quiet` | Do not print the `rtest:` status lines. |
| `--info` | Print the toolchain versions, the runs in progress and the free disk space. |

| Variable | Effect |
|---|---|
| `RTEST_HOST` | Default SSH destination. |
| `RTEST_SSH` | SSH command and its options, split on spaces. The default is `ssh`. |
| `RTEST_NO_MUX` | Set to `1` to disable SSH connection sharing. |

### Exit status

| Exit status | Meaning |
|---|---|
| 0 | The command passed. |
| 1 to 123 | The command failed. |
| 124 | `--timeout` stopped the command. |
| 125 | rtest did not prepare the run, for example because the sync failed. |
| 255 | SSH failed. |

### What the client sends

The client sends the files that git does not ignore, which includes
uncommitted and untracked files. It never sends `.git`. In a git work tree,
git itself lists the ignored files, so every gitignore rule applies. Outside a
git work tree, rsync reads the `.gitignore` files.

To exclude more files, add rsync exclude patterns to a `.rtestignore` file at
the project root.

The server does not receive ignored directories like `node_modules` or `.venv`.
Install the dependencies in the command: `rtest 'npm ci && npm test'`. The
package caches make this fast after the first run.

### Parallel runs

Each run gets its own copy, so you can start runs in parallel:

```bash
rtest go test ./pkg/a/... & rtest go test ./pkg/b/... & wait
```

The client shares one SSH connection between its runs. Parallel runs do not
pay the connection time again. Set `RTEST_NO_MUX=1` to disable this.

### Queue

A run starts only with room on the host. Other runs wait in a
queue, in arrival order. A run starts after all of these conditions are true:

1. It is the oldest run in the queue.
2. Fewer than `RTEST_MAX_RUNS` runs are in progress.
3. At least `RTEST_MIN_FREE_MEMORY_MB` of memory is free. The server reads the
   host memory and the memory limit of the container.
4. The 1-minute load average is below `RTEST_MAX_LOAD`.

When no run is in progress, the oldest run always starts, so that the queue
cannot block forever. A waiting run prints its position and the reason:

```text
rtest: queued at position 1, 2 of 2 runs in progress
rtest: started after about 6s in the queue
```

`--timeout` counts only the time of the command, not the time in the queue.
To leave the queue, stop the client. `rtest --info` shows the runs in progress,
the queued runs, and whether a new run starts now.

### Stop a run

With a terminal, Ctrl-C stops the remote command. Without a terminal, for
example in an agent or in CI, the client keeps the SSH input open for the
duration of the run. When the client stops, the input closes and the server
stops the command. A network connection that breaks for about one minute also
stops the command.

### Limits

- Files that the command writes on the server do not come back. Run code
  generators, formatters and snapshot updates locally.
- All runs share one Docker engine. Two runs that publish the same fixed host
  port at the same time conflict. Use random ports, as testcontainers does.

## Cache

rtest avoids work at four levels.

1. Mirror. The server keeps one mirror per checkout. rsync compares the files
   with the mirror and sends only the changes. A run after a one-line change
   sends one file.
2. Seed. A new checkout of a known repository, for example a new git worktree,
   starts as a copy of the latest mirror of that repository. The repository
   identity comes from the `origin` remote URL. The first sync of the new
   worktree then sends only its differences.
3. Package caches. The Go module and build caches, the cargo registry, and the
   npm, pnpm, pip and uv caches stay in `/work/caches` between runs.
4. Compiled Rust crates. sccache keeps compiled dependencies in
   `/work/caches/sccache`, so each run does not compile them again.

Each run starts from a full copy of the mirror (`RTEST_COPY_MODE=copy`). On a
file system with reflinks, like Btrfs or XFS, the copy is instant. On other
file systems, the copy time grows with the project size. For very
large projects, `RTEST_COPY_MODE=hardlink` makes the copy instant, but the run
shares the files with the mirror. A test that changes a project file in place
then also changes the mirror for runs that start at the same time. The next
sync repairs the mirror.

## Cleanup

1. At the end of the command, the server deletes the run directory. This also
   applies after a failure or a timeout.
2. When the client goes away, the server stops the command and deletes the run
   directory.
3. Every ten minutes, a janitor deletes orphan run directories, unused mirrors
   and old Docker objects. See [Server configuration](#server-configuration).

At exit, the client deletes its local temporary files.

## Install the skill

The `remote-test` skill tells an agent the right moment and the right way to
call `rtest`. It works with Claude Code and with Codex. You do not need a
clone of this repository. If the client is missing, the skill installs it with
the install script.

For Claude Code, install the plugin from this repository:

```bash
claude plugin marketplace add tomMoulard/rtest
claude plugin install rtest@rtest
```

In a Claude Code session, `/plugin install rtest --marketplace tomMoulard/rtest`
does the same in one step. The skill name is then `rtest:remote-test`. To get
a new version, run `claude plugin update rtest@rtest`.

For Codex, download the skill:

```bash
mkdir -p ~/.codex/skills/remote-test
curl -fsSL -o ~/.codex/skills/remote-test/SKILL.md \
  https://raw.githubusercontent.com/tomMoulard/rtest/main/skills/remote-test/SKILL.md
```

The same command with `~/.claude/skills/remote-test` installs the skill in
Claude Code without the plugin. To get a new version, run the command again.

To make sure that the agent sees the skill, start a new session and ask:
"run the unit tests remotely". The agent finds or installs `rtest`, calls
`rtest --info`, then calls `rtest` with the test command.

## Development

```bash
make lint   # gofmt, go vet, shellcheck, hadolint, yamllint
make unit   # Go unit tests of the client
make test   # build the image, then run test/e2e.sh against a container
```

`test/e2e.sh` builds the client, starts a container, then drives it with the
client. It covers the toolchains, exit statuses, output streams, ignored files,
the cache, parallel runs, timeouts, disconnects and the janitor.

To release, push a tag like `v0.2.0`. CI then runs the tests, and
[GoReleaser](https://goreleaser.com) builds the client archives and
`checksums.txt` and publishes them on a GitHub release. CI also publishes the
image `tommoulard/rtest:v0.2.0`. `make release` builds the archives locally
in `dist/`, without a release. On every push to `main`, CI publishes
`tommoulard/rtest:latest`. CI needs the `DOCKERHUB_USERNAME` and
`DOCKERHUB_TOKEN` secrets to publish the image.
