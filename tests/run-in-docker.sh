#!/usr/bin/env bash
# Runs all tests in a disposable container based on Debian 12, the base system of
# UGOS. The project is mounted read-only.
set -eu
cd "$(dirname "$0")/.."

docker run --rm -v "$PWD:/src:ro" golang:1.25-bookworm bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends qemu-utils python3 shellcheck tzdata >/dev/null 2>&1
  echo "== shellcheck"
  shellcheck -S warning -x /src/app/rootfs_common/libexec/ugvm-backup.sh && echo "  ok   no warnings"
  echo "== backend"
  cp -r /src/app /tmp/app
  (cd /tmp/app/backend && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./...)
  bash /src/tests/script/run-tests.sh
'
