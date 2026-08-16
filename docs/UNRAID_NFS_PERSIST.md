# Unraid persist — host NFS for the model pool

This is the operator runbook while fast-models still rides an Unraid box.
The long-term shape is a dedicated host that owns the Btrfs pool and nfsd.
Until then, **host nfsd** exports `/mnt/ai-data`. The container does not.

## The one line that must be in `/boot/config/go`

`/boot` is FAT32. Execute bits do not stick. Always call the script with
`bash`:

```bash
# after emhttp; give the array / NVMe ~45s
( sleep 45; bash /boot/config/plugins/fast-models/host-nfs-export.sh ) &
```

Install the script first (copy from this repo, then set `UUID=` to your
pool's `blkid` value):

```bash
mkdir -p /boot/config/plugins/fast-models
cp scripts/host-nfs-export.sh /boot/config/plugins/fast-models/host-nfs-export.sh
# edit UUID= on the flash copy
```

## What the script does

1. Host-mounts the `fast-models` Btrfs UUID at `/mnt/ai-data` if it is not
   already a mount (the container may already have the same FS at `/ai-data`).
2. Writes `/etc/exports` for that path only (`fsid=0`, LAN clients).
3. Starts host nfsd / rpcbind if `:2049` is not listening.
4. `exportfs -v`.

It does **not** turn on Unraid Settings → NFS.

## Do not

| Action | Why |
|--------|-----|
| Exec the script as `./host-nfs-export.sh` from `go` | FAT32 → console **Permission denied** → nfsd never starts |
| `chmod +x` on `/boot` and call it done | Mode does not survive |
| `/etc/rc.d/rc.nfsd start` alone | Stock `/etc/exports` is empty comments; nothing is exported |
| Enable Unraid **Settings → NFS** | Fights `shareNFSEnabled=no`; array shares are SMB on purpose |
| Set `ENABLE_NFS=1` in the container | Alpine-in-Docker nfsd often misses host rpcbind; macOS `mount_nfs` then says *RPC prog. not avail* |

## After a reboot — 60 second check

On the Unraid host:

```bash
/etc/rc.d/rc.nfsd status
findmnt /mnt/ai-data
test -f /mnt/ai-data/.fast-models-info && cat /mnt/ai-data/.fast-models-info
showmount -e localhost
ss -lntp | grep -E ':2049|:111'
```

If the console printed **Permission denied** while a startup script ran,
`grep host-nfs /boot/config/go` — if the line has no `bash`, that is the bug.

If `/mnt/ai-data` is an empty directory (placeholder `models/`, `uv-cache/`)
and the `fast-models` container is healthy, the **host mount** is missing.
Run the script with `bash`. Do not start nfsd first.

## Client mounts

**Linux (preferred: NFSv4.2).** `fsid=0` means the mount path is `/`:

```bash
sudo mkdir -p /mnt/ai-data
sudo mount -t nfs -o vers=4.2,rsize=1048576,wsize=1048576,hard,noatime,nconnect=4 \
  <nas-host-ip>:/ /mnt/ai-data
test -f /mnt/ai-data/.fast-models-info && echo OK
```

fstab:

```
<nas-host-ip>:/  /mnt/ai-data  nfs  vers=4.2,rsize=1048576,wsize=1048576,hard,noatime,nconnect=4,_netdev,x-systemd.automount  0  0
```

**macOS (NFSv3 + full path).** NFSv4 root often fails with *RPC prog. not avail*:

```bash
sudo mkdir -p /Volumes/ai-data
sudo mount_nfs -o resvport,vers=3,tcp,rw,hard,intr \
  <nas-host-ip>:/mnt/ai-data /Volumes/ai-data
test -f /Volumes/ai-data/.fast-models-info && echo OK
```

## Until a dedicated host

Keep this Unraid stopgap if:

- The two NVMe devices stay **unassigned** (not array, not cache pool, not UD auto-mount).
- Host nfsd owns **2049**. Container `ENABLE_NFS=0`.
- Array shares stay **SMB**.
- `/boot/config/go` uses **`bash`**.

When the pool moves to its own box (bare metal or a small VM with the NVMe
card passed through), that host runs the same Btrfs + bees + nfsd story
without a FAT32 `/boot`. Unraid becomes just another NFS client.

See [INCIDENT_FAT32_GO_HOOK_2026-08-15.md](INCIDENT_FAT32_GO_HOOK_2026-08-15.md)
for the 2026-08-15 failure that made this runbook load-bearing.
