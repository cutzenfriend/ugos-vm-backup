#!/usr/bin/env bash
# Runs all tests in a disposable container based on Debian 12, the base system of
# UGOS. The project is mounted read-only.
set -eu
cd "$(dirname "$0")/.."

docker run --rm -v "$PWD:/src:ro" debian:12 bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends qemu-utils python3 shellcheck tzdata whiptail curl procps ncurses-base >/dev/null 2>&1
  echo "== shellcheck"
  shellcheck -S warning /src/ugvm-backup.sh
  echo "  ok   no warnings"
  bash /src/tests/run-tests.sh
'
