#!/bin/sh
# Install the rtest client from the GitHub releases.
#
#   curl -fsSL https://raw.githubusercontent.com/tomMoulard/rtest/main/install.sh | sh
#
# RTEST_VERSION      release tag to install (default: the latest release)
# RTEST_INSTALL_DIR  target directory (default: ~/.local/bin)
# RTEST_DOWNLOAD_URL base URL of the release files (for tests)
#
# Without a release for this platform, it falls back to `go install` when Go
# is available.
set -eu

repo=tomMoulard/rtest
dir=${RTEST_INSTALL_DIR:-$HOME/.local/bin}
version=${RTEST_VERSION:-latest}

case $(uname -s) in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) echo "rtest: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
case $(uname -m) in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) echo "rtest: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

if [ "$version" = latest ]; then
  base=https://github.com/$repo/releases/latest/download
else
  base=https://github.com/$repo/releases/download/$version
fi
base=${RTEST_DOWNLOAD_URL:-$base}
archive=rtest_${os}_${arch}.tar.gz

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if curl -fsSL -o "$tmp/$archive" "$base/$archive" && curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"; then
  want=$(grep " $archive\$" "$tmp/checksums.txt" | cut -d ' ' -f 1)
  if command -v sha256sum >/dev/null; then
    got=$(sha256sum "$tmp/$archive" | cut -d ' ' -f 1)
  else
    got=$(shasum -a 256 "$tmp/$archive" | cut -d ' ' -f 1)
  fi
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "rtest: checksum mismatch for $archive" >&2
    exit 1
  fi
  tar -xzf "$tmp/$archive" -C "$tmp" rtest
  mkdir -p "$dir"
  install -m 0755 "$tmp/rtest" "$dir/rtest"
elif command -v go >/dev/null; then
  echo "rtest: no release download, building with go install" >&2
  [ "$version" = latest ] || ref=$version
  GOBIN=$dir go install "github.com/$repo/cmd/rtest@${ref:-latest}"
else
  echo "rtest: cannot download $base/$archive, and Go is not installed" >&2
  exit 1
fi

echo "rtest: installed $("$dir/rtest" --version) in $dir/rtest"
case :$PATH: in
  *:"$dir":*) ;;
  *) echo "rtest: $dir is not in PATH. Add it, or call $dir/rtest." ;;
esac
