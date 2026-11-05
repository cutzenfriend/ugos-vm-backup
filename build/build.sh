#!/usr/bin/env bash
# Builds the .upk packages into dist/. The build number must increase for every
# package installed on the same version.
set -eu
cd "$(dirname "$0")/.."

build_number=${1:-1}
docker buildx build \
  --file build/Dockerfile \
  --build-arg "BUILD_NUMBER=$build_number" \
  --target packages \
  --output type=local,dest=dist \
  .
ls -la dist
