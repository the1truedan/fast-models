#!/usr/bin/env bash
# Device-bound dual NVMe → Btrfs RAID0 → layout → bees → NFS v4.2
set -euo pipefail

AI_DATA="${AI_DATA:-/ai-data}"
DEV0="${DEV0:-/dev/nvme0n1}"
DEV1="${DEV1:-/dev/nvme1n1}"
ALLOW_FORMAT="${ALLOW_FORMAT:-0}"
FORCE_FORMAT="${FORCE_FORMAT:-0}"
NFS_CLIENTS="${NFS_CLIENTS:-192.168.0.0/16}"
BTRFS_LABEL="${BTRFS_LABEL:-fast-models}"
ENABLE_BEES="${ENABLE_BEES:-1}"
ENABLE_NFS="${ENABLE_NFS:-1}"
NFSD_THREADS="${NFSD_THREADS:-8}"
BEES_DB="${BEES_DB:-/var/lib/bees}"
BEES_CONF="${BEES_CONF:-/etc/bees/beesd.conf}"
BEES_HASH_SIZE="${BEES_HASH_SIZE:-1G}"
BEES_SCAN_MODE="${BEES_SCAN_MODE:-4}"
BEES_THREADS="${BEES_THREADS:-1}"
LAYOUT_DIRS="${LAYOUT_DIRS:-models uv-cache hf-cache github pinokio stability-matrix work docker-registry}"

log() { echo "[fast-models $(date -Iseconds)] $*"; }
die() { log "ERROR: $*"; exit 1; }

require_devices() {
  [[ -b "$DEV0" ]] || die "missing block device DEV0=$DEV0 (set NVME0 by-id path in .env)"
  [[ -b "$DEV1" ]] || die "missing block device DEV1=$DEV1 (set NVME1 by-id path in .env)"
  log "devices: $DEV0 + $DEV1"
}

device_has_fs() {
  local dev="$1"
  local t
  t="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
  [[ -n "$t" ]]
}

device_btrfs_uuid() {
  local dev="$1"
  blkid -o value -s UUID -t TYPE=btrfs "$dev" 2>/dev/null || true
}

is_mounted_host_side() {
  local dev="$1"
  # findmnt may see host mounts when privileged + shared namespaces
  findmnt -n -S "$dev" >/dev/null 2>&1
}

mount_existing() {
  mkdir -p "$AI_DATA"
  if findmnt -n "$AI_DATA" >/dev/null 2>&1; then
    log "already mounted: $AI_DATA"
    return 0
  fi

  local uuid
  uuid="$(device_btrfs_uuid "$DEV0")"
  if [[ -z "$uuid" ]]; then
    uuid="$(device_btrfs_uuid "$DEV1")"
  fi

  if [[ -n "$uuid" ]]; then
    log "mounting existing Btrfs UUID=$uuid → $AI_DATA"
    mount -t btrfs -o defaults,noatime,compress=zstd:3 "UUID=$uuid" "$AI_DATA" \
      || mount -t btrfs -o defaults,noatime,compress=zstd:3 "$DEV0" "$AI_DATA"
    return 0
  fi

  # Fallback: try either device if blkid is slow after reboot
  if blkid -o value -s TYPE "$DEV0" 2>/dev/null | grep -qx btrfs; then
    log "mounting $DEV0 (btrfs) → $AI_DATA"
    mount -t btrfs -o defaults,noatime,compress=zstd:3 "$DEV0" "$AI_DATA"
    return 0
  fi

  return 1
}

format_raid0() {
  log "FORMAT REQUESTED: Btrfs RAID0 label=$BTRFS_LABEL on $DEV0 + $DEV1"
  log "WARNING: RAID0 has no parity — single drive failure loses the pool."

  for d in "$DEV0" "$DEV1"; do
    if is_mounted_host_side "$d"; then
      die "$d appears mounted on the host — unmount / remove from Unraid array before format"
    fi
  done

  if [[ "$FORCE_FORMAT" != "1" ]]; then
    for d in "$DEV0" "$DEV1"; do
      if device_has_fs "$d"; then
        die "$d already has a filesystem ($(blkid -o value -s TYPE "$d")). Set FORCE_FORMAT=1 to wipe (destructive)."
      fi
    done
  else
    log "FORCE_FORMAT=1 — wiping existing signatures"
    wipefs -a "$DEV0" "$DEV1" || true
  fi

  mkfs.btrfs -f \
    -d raid0 \
    -m raid0 \
    -L "$BTRFS_LABEL" \
    "$DEV0" "$DEV1"

  mkdir -p "$AI_DATA"
  mount -t btrfs -o defaults,noatime,compress=zstd:3 "LABEL=$BTRFS_LABEL" "$AI_DATA" \
    || mount -t btrfs -o defaults,noatime,compress=zstd:3 "$DEV0" "$AI_DATA"
  log "formatted and mounted $AI_DATA"
}

ensure_mount() {
  if mount_existing; then
    return 0
  fi
  if [[ "$ALLOW_FORMAT" == "1" ]]; then
    format_raid0
    return 0
  fi
  die "no Btrfs on devices and ALLOW_FORMAT=0. First boot: set ALLOW_FORMAT=1 (once), then set back to 0."
}

tune_btrfs() {
  # Best-effort compression property (may already be set)
  btrfs property set "$AI_DATA" compression zstd 2>/dev/null || true
  log "btrfs fi show:"
  btrfs fi show "$AI_DATA" || true
  log "btrfs fi df:"
  btrfs fi df "$AI_DATA" || true
}

ensure_layout() {
  local d
  for d in $LAYOUT_DIRS; do
    mkdir -p "$AI_DATA/$d"
  done
  # marker for healthchecks / operators
  cat >"$AI_DATA/.fast-models-info" <<EOF
label=${BTRFS_LABEL}
devices=${DEV0},${DEV1}
layout=${LAYOUT_DIRS}
nfs_clients=${NFS_CLIENTS}
updated=$(date -Iseconds)
EOF
  log "layout ready under $AI_DATA: $LAYOUT_DIRS"
}

write_bees_conf() {
  mkdir -p "$(dirname "$BEES_CONF")" "$BEES_DB" /etc/bees
  local uuid
  uuid="$(btrfs fi show "$AI_DATA" 2>/dev/null | awk '/uuid:/ {print $4; exit}')"
  if [[ -z "$uuid" ]]; then
    uuid="$(findmnt -n -o UUID "$AI_DATA" 2>/dev/null || true)"
  fi
  if [[ -z "$uuid" ]]; then
    log "WARNING: could not determine Btrfs UUID (bees still runs on path)"
    uuid="unknown"
  fi

  sed \
    -e "s|@UUID@|${uuid}|g" \
    -e "s|@AI_DATA@|${AI_DATA}|g" \
    -e "s|@BEES_DB@|${BEES_DB}|g" \
    /etc/fast-models/bees.conf.template >"$BEES_CONF"
  log "bees config UUID=$uuid → $BEES_CONF (DB=$BEES_DB)"
}

ensure_bees_hash() {
  # Upstream requires beeshash.dat before first start (multiple of 128 KiB).
  # BEESHOME may live on XFS appdata (v0.11+ supports non-btrfs BEESHOME).
  local hash="$BEESHOME/beeshash.dat"
  if [[ -f "$hash" ]]; then
    log "bees hash present: $hash ($(stat -c%s "$hash" 2>/dev/null || stat -f%z "$hash" 2>/dev/null || echo '?') bytes)"
    return 0
  fi
  log "creating bees hash table $hash size=${BEES_HASH_SIZE}"
  truncate -s "$BEES_HASH_SIZE" "$hash"
  chmod 700 "$hash"
}

start_bees() {
  if [[ "$ENABLE_BEES" != "1" ]]; then
    log "ENABLE_BEES=0 — skipping bees"
    return 0
  fi
  if ! command -v bees >/dev/null 2>&1; then
    die "ENABLE_BEES=1 but bees binary missing — rebuild image (pin BEES_REF=v0.11 + musl gettid patch)"
  fi
  write_bees_conf
  export BEESHOME="${BEESHOME:-$BEES_DB}"
  export BEESSTATUS="${BEESSTATUS:-$BEESHOME/bees.status}"
  mkdir -p "$BEESHOME"
  ensure_bees_hash

  # Modest defaults for ~32 GiB Unraid hosts. Scan mode 4 = extent (v0.11 default;
  # best for model pools with near-identical GGUF/ONNX blobs).
  local -a cmd=(bees --thread-count="${BEES_THREADS}" --scan-mode="${BEES_SCAN_MODE}" --timestamps "$AI_DATA")
  log "starting bees threads=${BEES_THREADS} scan-mode=${BEES_SCAN_MODE} BEESHOME=${BEESHOME} → $AI_DATA"
  if command -v ionice >/dev/null 2>&1; then
    nice -n 19 ionice -c3 "${cmd[@]}" &
  else
    nice -n 19 "${cmd[@]}" &
  fi
  BEES_PID=$!
  # brief settle so a crash-on-start is visible in logs
  sleep 1
  if ! kill -0 "$BEES_PID" 2>/dev/null; then
    die "bees exited immediately (pid=${BEES_PID}) — check BEESHOME/hash and btrfs root mount"
  fi
  log "bees pid=${BEES_PID} status=${BEESSTATUS}"
}

write_exports() {
  sed \
    -e "s|@AI_DATA@|${AI_DATA}|g" \
    -e "s|@NFS_CLIENTS@|${NFS_CLIENTS}|g" \
    /etc/fast-models/exports.template >/etc/exports
  log "NFS exports:"
  cat /etc/exports
}

start_nfs() {
  if [[ "$ENABLE_NFS" != "1" ]]; then
    log "ENABLE_NFS=0 — skipping NFS"
    return 0
  fi

  write_exports

  # Kernel modules must exist on Unraid host; privileged container can load if allowed
  modprobe nfsd 2>/dev/null || log "modprobe nfsd skipped/failed (host may already provide nfsd)"
  modprobe exportfs 2>/dev/null || true

  mkdir -p /run/rpcbind /var/lib/nfs/v4recovery /var/lib/nfs/rpc_pipefs
  # rpc_pipefs often needed for nfsd
  if ! mountpoint -q /var/lib/nfs/rpc_pipefs 2>/dev/null; then
    mount -t rpc_pipefs sunrpc /var/lib/nfs/rpc_pipefs 2>/dev/null || true
  fi
  if ! mountpoint -q /proc/fs/nfsd 2>/dev/null; then
    mount -t nfsd nfsd /proc/fs/nfsd 2>/dev/null || true
  fi

  rpcbind -w || rpcbind || true
  exportfs -ra

  # nfsd thread count
  rpc.nfsd "$NFSD_THREADS" || die "rpc.nfsd failed — is Unraid NFS plugin conflicting, or is privileged/host network set?"
  rpc.mountd -N 2 -N 3 || rpc.mountd || die "rpc.mountd failed"
  # optional idmapd for NFSv4 name mapping
  if command -v rpc.idmapd >/dev/null 2>&1; then
    rpc.idmapd || true
  fi

  log "NFS v4.2 export active on host network (port 2049)"
  exportfs -v || true
}

shutdown() {
  log "shutting down..."
  if [[ -n "${BEES_PID:-}" ]] && kill -0 "$BEES_PID" 2>/dev/null; then
    kill "$BEES_PID" 2>/dev/null || true
  fi
  exportfs -ua 2>/dev/null || true
  rpc.nfsd 0 2>/dev/null || true
  if findmnt -n "$AI_DATA" >/dev/null 2>&1; then
    umount "$AI_DATA" 2>/dev/null || umount -l "$AI_DATA" 2>/dev/null || true
  fi
  exit 0
}

trap shutdown SIGTERM SIGINT

main() {
  log "starting manager-fast-models storage plane"
  require_devices
  ensure_mount
  tune_btrfs
  ensure_layout
  start_bees
  start_nfs
  log "ready — pool mounted at $AI_DATA, NFS clients=${NFS_CLIENTS}"
  # Stay alive; re-export periodically in case of nfsd restarts
  while true; do
    if ! findmnt -n "$AI_DATA" >/dev/null 2>&1; then
      die "mount lost: $AI_DATA"
    fi
    if [[ "$ENABLE_NFS" == "1" ]]; then
      exportfs -r 2>/dev/null || true
    fi
    sleep 30
  done
}

main "$@"
