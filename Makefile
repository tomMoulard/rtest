IMAGE ?= rtest:dev
VERSION ?= dev
SHELL_FILES = install.sh scripts/build-release.sh test/e2e.sh \
	rootfs/usr/local/bin/* rootfs/usr/local/lib/rtest/common.sh

.PHONY: lint unit build test release

lint:
	test -z "$$(gofmt -l .)" || { gofmt -l .; exit 1; }
	go vet ./...
	shellcheck $(SHELL_FILES)
	docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile
	yamllint .

unit:
	go test -race ./...

build:
	docker build -t $(IMAGE) .

test: build
	RTEST_IMAGE=$(IMAGE) test/e2e.sh

release:
	scripts/build-release.sh $(VERSION)
