# Builds the .upk packages. Everything is pinned, and nothing runs on the host.
# Usage: bash build/build.sh [build-number]

FROM node:22-bookworm-slim AS sdk
WORKDIR /sdk
COPY build/sdk-entry.js .
RUN npm init -y >/dev/null \
    && npm install --ignore-scripts --no-audit --no-fund @ugreen-nas/core@1.7.42 esbuild@0.25.0 \
    && npx esbuild sdk-entry.js --bundle --minify --format=iife --target=es2020 --legal-comments=none --outfile=/out/ugos-sdk.js

FROM golang:1.25-bookworm AS backend
WORKDIR /src/backend
COPY app/backend/ .
# A test checks that the app and the script agree on the script version.
COPY app/rootfs_common/libexec/ugvm-backup.sh /src/rootfs_common/libexec/ugvm-backup.sh
ENV CGO_ENABLED=0 GOFLAGS=-buildvcs=false
RUN go vet ./... \
    && go test -count=1 ./... \
    && GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o /out/amd64/ugvm_serv . \
    && GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o /out/arm64/ugvm_serv .

# ugcli only exists for amd64 Linux. On Apple silicon this stage runs emulated.
FROM --platform=linux/amd64 debian:12 AS pack
ADD --chmod=755 --checksum=sha256:9d8500a49a739bd2c9bf612018c4c3457e4ffc3f4a20d0f2365a4a91637d4516 \
    https://osswaf.ugnas.com/pro/ugcli/download/ugcli-v1.1.0.25-linux-amd64 /usr/local/bin/ugcli
ARG BUILD_NUMBER=1
WORKDIR /project
COPY app/project.yaml project.yaml
COPY app/rootfs_common/ rootfs_common/
COPY --from=sdk /out/ugos-sdk.js rootfs_common/www/js/ugos-sdk.js
COPY --from=backend /out/amd64/ugvm_serv rootfs_amd64/bin/ugvm_serv
COPY --from=backend /out/arm64/ugvm_serv rootfs_arm64/bin/ugvm_serv
# Modes are stored in the package and restored on the NAS.
RUN find . -type d -exec chmod 0755 {} + \
    && find . -type f -exec chmod 0644 {} + \
    && chmod 0755 rootfs_amd64/bin/ugvm_serv rootfs_arm64/bin/ugvm_serv rootfs_common/libexec/ugvm-backup.sh \
    && ugcli check \
    && ugcli pack --arch all --build "$BUILD_NUMBER" \
    && mkdir /out \
    && find . -name '*.upk' -exec cp {} /out/ \; \
    && ls -la /out

FROM scratch AS packages
COPY --from=pack /out/ /
