# Unraid dual-NVMe storage plane: Btrfs RAID0 + bees dedupe + NFS v4.2
# Build on Unraid (amd64). Privileged + host network at runtime.
FROM alpine:3.21

LABEL org.opencontainers.image.title="manager-fast-models"
LABEL org.opencontainers.image.description="Device-bound Btrfs RAID0 + bees + NFS v4.2 for dual NVMe on Unraid"
LABEL org.opencontainers.image.source="https://github.com/the1truedan/fast-models"

# Pin released bees (v0.11: extent scan default, BEESHOME safe on XFS appdata).
# Do not fall back to master — that hides a bad pin.
ARG BEES_REF=v0.11

COPY patches/bees-musl-gettid.patch /tmp/bees-musl-gettid.patch
COPY patches/apply-musl-gettid.py /tmp/apply-musl-gettid.py

# compsize not on Alpine 3.21; duperemove optional-soft.
# musl provides gettid(3); bees' weak gettid() throw() redefinition breaks g++.
RUN apk add --no-cache \
      bash \
      coreutils \
      util-linux \
      blkid \
      findmnt \
      btrfs-progs \
      nfs-utils \
      rpcbind \
      libtirpc \
      tini \
      curl \
      ca-certificates \
      tzdata \
    && (apk add --no-cache duperemove || echo "WARN: duperemove package unavailable") \
    && (apk add --no-cache compsize || echo "WARN: compsize package unavailable") \
    && apk add --no-cache --virtual .bees-build \
      build-base \
      git \
      linux-headers \
      btrfs-progs-dev \
      patch \
      python3 \
    && git clone --depth 1 --branch "${BEES_REF}" https://github.com/Zygo/bees.git /tmp/bees \
    && cd /tmp/bees \
    && python3 /tmp/apply-musl-gettid.py \
    && (patch -p1 --forward --dry-run < /tmp/bees-musl-gettid.patch >/dev/null 2>&1 || true) \
    && (command -v markdown >/dev/null \
        || printf '#!/bin/sh\ncat >/dev/null\n' > /usr/local/bin/markdown && chmod +x /usr/local/bin/markdown) \
    && make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" \
    && test -x bin/bees \
    && mkdir -p /usr/local/sbin /usr/local/bin \
    && install -m 0755 bin/bees /usr/local/sbin/bees \
    && ln -sf /usr/local/sbin/bees /usr/local/bin/bees \
    && test -x /usr/local/sbin/bees \
    && echo "bees ${BEES_REF} installed" \
    && cd / \
    && rm -rf /tmp/bees /tmp/bees-musl-gettid.patch /tmp/apply-musl-gettid.py \
    && apk del .bees-build

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config/bees.conf.template /etc/fast-models/bees.conf.template
COPY config/exports.template /etc/fast-models/exports.template

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /ai-data /var/lib/bees /etc/bees /run/rpcbind

ENV AI_DATA=/ai-data \
    BEES_DB=/var/lib/bees \
    BEESHOME=/var/lib/bees \
    ALLOW_FORMAT=0 \
    FORCE_FORMAT=0 \
    NFS_CLIENTS=192.168.0.0/16 \
    BTRFS_LABEL=fast-models \
    ENABLE_BEES=1 \
    ENABLE_NFS=1 \
    NFSD_THREADS=8 \
    BEES_THREADS=1 \
    BEES_SCAN_MODE=4 \
    BEES_HASH_SIZE=1G

VOLUME ["/var/lib/bees"]

EXPOSE 2049/tcp 111/tcp 111/udp

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
