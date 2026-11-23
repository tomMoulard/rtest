IMAGE ?= rtest:dev

.PHONY: lint build test

lint:
	shellcheck client/rtest test/e2e.sh rootfs/usr/local/bin/* rootfs/usr/local/lib/rtest/common.sh
	docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile
	yamllint .

build:
	docker build -t $(IMAGE) .

test: build
	RTEST_IMAGE=$(IMAGE) test/e2e.sh
