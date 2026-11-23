#!/usr/bin/env bash
# Build the release archives of the rtest client into dist/.
#
#   scripts/build-release.sh v1.2.3
set -euo pipefail

version=${1:?usage: build-release.sh VERSION}
cd "$(dirname "$0")/.."
rm -rf dist
mkdir -p dist

for target in darwin/amd64 darwin/arm64 linux/amd64 linux/arm64; do
  os=${target%/*} arch=${target#*/}
  work=$(mktemp -d)
  CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath \
    -ldflags "-s -w -X main.version=$version" -o "$work/rtest" ./cmd/rtest
  tar -czf "dist/rtest_${os}_${arch}.tar.gz" -C "$work" rtest
  rm -rf "$work"
done

(cd dist && if command -v sha256sum >/dev/null; then sha256sum ./*.tar.gz; else shasum -a 256 ./*.tar.gz; fi |
  sed 's| \./| |' >checksums.txt)
cat dist/checksums.txt
