#!/bin/bash
# Persist dual-NVMe fast-models Btrfs host mount + NFSv4 export for Mac/Linux clients.
# Array share NFS stays disabled (shareNFSEnabled=no); only /mnt/ai-data is exported.
# bees continues inside the fast-models container on the same pool.
# Invoke as: bash /boot/config/plugins/fast-models/host-nfs-export.sh
# Never exec this path from /boot/config/go — FAT32 has no +x (console Permission denied).
set -euo pipefail
UUID="<btrfs-pool-uuid>"  # set to your pool's UUID (blkid)
MNT="/mnt/ai-data"
CLIENTS="192.168.0.0/16"

mkdir -p "$MNT"
if ! findmnt -n "$MNT" >/dev/null 2>&1; then
  # Wait for NVMe after array start
  for i in $(seq 1 30); do
    blkid -U "$UUID" >/dev/null 2>&1 && break
    sleep 2
  done
  mount -t btrfs -o defaults,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2 \
    "UUID=$UUID" "$MNT"
fi

# Export only the model pool (do not re-enable Unraid share NFS UI paths)
cat > /etc/exports << EOF
# fast-models Btrfs pool (host mount; bees in docker)
$MNT ${CLIENTS}(rw,sync,no_subtree_check,no_root_squash,fsid=0,insecure)
EOF
exportfs -ra

# Start nfsd even if shareNFSEnabled=no
if ! ss -lntp | grep -q ':2049'; then
  /etc/rc.d/rc.nfsd start || {
    rpc.nfsd 8
    rpc.mountd
  }
fi
exportfs -v
