# fast-models

One fast share for the bulky AI files — models, caches, git checkouts, Pinokio
trees — so you stop copying them onto every machine.

This repo is the **storage plane**. It is not a chat stack. Pair it with
[ai-gateway](https://github.com/the1truedan/ai-gateway) if you want the
language-model side.

**v0.2.0** · [site](https://the1truedan.github.io/fast-models/) ·
[changelog](CHANGELOG.md) · [Unraid NFS runbook](docs/UNRAID_NFS_PERSIST.md)

| Layer | What we use | Upstream |
|-------|-------------|----------|
| Drives | Two NVMe devices (prefer `/dev/disk/by-id/…`) | — |
| Filesystem | Btrfs RAID0 (fast, **no parity** — one dead drive loses the pool) | [Btrfs](https://btrfs.readthedocs.io/) |
| Space saving | **bees** shares identical chunks so near-duplicate weights do not eat the disk twice | [Zygo/bees](https://github.com/Zygo/bees) |
| Sharing | Host NFS so Mac and Linux clients can mount the pool | kernel NFS |
| Scope | Storage only | [ai-gateway](https://github.com/the1truedan/ai-gateway) for chat/agents |

## Read this first (Unraid)

The persist script on the flash drive **cannot be executed**. Unraid `/boot`
is FAT32. It has no Unix execute bits. If `/boot/config/go` calls the script
as a bare path, the console prints **Permission denied**, host nfsd never
starts, and every client mount fails. The container can look perfectly healthy
while that happens.

```bash
# correct — in /boot/config/go, after emhttp
( sleep 45; bash /boot/config/plugins/fast-models/host-nfs-export.sh ) &
```

Wrong: `rc.nfsd start` alone (empty `/etc/exports`). Wrong: Settings → NFS
(array shares stay SMB). Details:
[docs/UNRAID_NFS_PERSIST.md](docs/UNRAID_NFS_PERSIST.md) ·
[what broke on 2026-08-15](docs/INCIDENT_FAT32_GO_HOOK_2026-08-15.md).

This Unraid host-nfsd layout is the stopgap until the pool lives on its own
non-Unraid host.

## Docker is not a VM passthrough

The container is privileged and sees the raw NVMe devices through the **host**
kernel. That is convenient. It is **not** the same as giving a VM exclusive
PCIe ownership of the drives.

**Do not** also put those NVMes in the Unraid array, a cache pool, or
Unassigned Devices auto-mount while this stack is using them.

## Prerequisites

1. **BIOS**: PCIe bifurcation for the dual-M.2 adapter slot (`x4x4` / vendor equivalent).
2. **Unraid plugins** (recommended): Unassigned Devices for inventory only — do not auto-mount these two. Dynamix SSD TRIM optional.
3. **Host free**: leave both NVMe **unassigned**.
4. **Docker Compose**: Compose Manager plugin, Portainer, or CLI `docker compose`.

```bash
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL
ls -l /dev/disk/by-id/nvme-*
```

## Import on Unraid

### A. Compose Manager (recommended)

1. Copy this folder to the array, e.g. `/mnt/user/appdata/fast-models/stack/`.
2. `cp .env.example .env` and set `NVME0` / `NVME1` to **by-id** paths.
3. Create appdata dirs:

   ```bash
   mkdir -p /mnt/user/appdata/fast-models/{bees,config}
   ```

4. Compose Manager → add project → this `docker-compose.yml` → **Compose Up**.

### B. CLI

```bash
cd /mnt/user/appdata/fast-models/stack
cp .env.example .env
# edit .env
mkdir -p /mnt/user/appdata/fast-models/{bees,config}
docker compose --env-file .env up -d --build
```

### First boot (format once)

Empty drives only:

```bash
# in .env
ALLOW_FORMAT=1
FORCE_FORMAT=0
```

```bash
docker compose --env-file .env up -d --build
docker logs -f fast-models
```

When healthy, set `ALLOW_FORMAT=0` and recreate. `FORCE_FORMAT=1` (with
`ALLOW_FORMAT=1`) is a destructive wipe. Never leave it set.

## Pool layout

Inside the container at `/ai-data` (NFS root with `fsid=0`):

```
/ai-data/
  models/
  uv-cache/
  hf-cache/
  github/
  pinokio/
  stability-matrix/
  work/
  docker-registry/
  .fast-models-info
```

## Client mounts (NFS)

### Verified production pattern

| Service | Role | Port 2049 |
|---------|------|-----------|
| **Unraid array NFS** | **Off** (`shareNFSEnabled=no`) — array paths are **SMB-only** | — |
| **Host NFS export** | `/mnt/ai-data` = same dual-NVMe Btrfs as the container | **Owns** 2049 (v3+v4, rpcbind-registered) |
| **fast-models** container | Btrfs RAID0 + **bees**; `ENABLE_NFS=0` | Does **not** run nfsd |

Alpine-in-Docker nfsd listens on 2049 and works from Linux, but often **fails
to register with host rpcbind**, so macOS `mount_nfs` returns *RPC prog. not
avail*. Host nfsd + host mount of the same Btrfs is the path that works for
both clients.

### Linux — NFSv4.2

`fsid=0` → mount path is **`/`** (not `/mnt/ai-data`):

```bash
sudo apt-get install -y nfs-common   # once
sudo mkdir -p /mnt/ai-data
sudo mount -t nfs -o vers=4.2,rsize=1048576,wsize=1048576,hard,noatime,nconnect=4 \
  <nas-host-ip>:/ /mnt/ai-data
test -f /mnt/ai-data/.fast-models-info && cat /mnt/ai-data/.fast-models-info
```

fstab:

```
<nas-host-ip>:/  /mnt/ai-data  nfs  vers=4.2,rsize=1048576,wsize=1048576,hard,noatime,nconnect=4,_netdev,x-systemd.automount  0  0
```

Fallback: `vers=4.1`, or `vers=3` with `<nas-host-ip>:/mnt/ai-data`.

### macOS — NFSv3 + full path

v4 root often fails with *RPC prog. not avail*:

```bash
sudo mkdir -p /Volumes/ai-data
sudo mount_nfs -o resvport,vers=3,tcp,rw,hard,intr \
  <nas-host-ip>:/mnt/ai-data /Volumes/ai-data
test -f /Volumes/ai-data/.fast-models-info && echo OK
```

### Multi-client write

macOS defaults to uid **501**, most Linux first users are **1000**. After a
bulk copy, keep shared dirs world-writable (LAN-only) or both uids can write:

```bash
ssh root@<nas-host-ip> 'chmod -R a+rwX /mnt/ai-data/{models,pinokio,uv-cache,work}'
```

Host-split uv caches (`uv-cache/<host>`) if more than one machine writes
the cache. A shared uv cache grows host-specific symlinks and then breaks.

## bees — background space saving

bees walks the Btrfs pool and shares identical chunks. It is **always on**
when `ENABLE_BEES=1` (not a nightly cron).

| Hash table | When |
|------------|------|
| **1G** | Small pools / first experiments |
| **2G** | **Default** for multi-TiB pools |
| **4G** | Only if 2G stays nearly full after a full re-crawl; ~4 GiB sticky RAM, no swap |

A table at 100% full is **not** a full disk and is **not** caused by Unraid
parity. bees still runs; it just forgets old fingerprints. Sizing notes:
[docs/BEES_HASH_SIZING.md](docs/BEES_HASH_SIZING.md).

Image pins bees **v0.11** (small musl/`gettid` fix for Alpine). Default: 1
thread, scan-mode 4, `nice` / `ionice`. The hash file lives on the **array**
under appdata, not on the NVMe pool.

```bash
docker exec fast-models pgrep -a bees
ls -lh /mnt/user/appdata/fast-models/bees/beeshash.dat
docker exec fast-models sh -c 'grep -E "cells occupied|Uptime" /var/lib/bees/beesstats.txt'
```

Optional deeper pass (IO-heavy; bees remains the everyday tool):

```bash
docker exec fast-models duperemove -r -d -h /ai-data/models
docker exec fast-models compsize /ai-data/models 2>/dev/null || true
```

Keep `BEES_THREADS=1` on ~32 GiB hosts unless you clearly have spare capacity.
`scripts/bees-health.sh` and `scripts/duperemove-weekly.sh` are for Unraid
User Scripts or cron.

## Until it lives on its own host

Today the pool is a privileged container on Unraid plus a host nfsd hook.
That works. It is also how a FAT32 `go` line can take the share down after
every reboot.

A dedicated host (bare metal, or a small VM with the NVMe card passed
through) would own Btrfs + bees + nfsd with a real Unix `/boot`. Unraid
becomes just another NFS client. Until that move, follow the persist
runbook and do not turn the container into the NFS server.

## Safety

| Rule | Why |
|------|-----|
| RAID0 | One drive failure loses the **entire** pool |
| Models re-downloadable | Prefer HF / Forgejo rehydrate over treating the pool as sole backup |
| No array membership | Prevents Unraid and the container fighting for the same devices |
| `ALLOW_FORMAT=0` steady-state | Avoids accidental `mkfs` on restart |
| Tighten `NFS_CLIENTS` | Default `192.168.0.0/16` is LAN-wide |

If Unraid NFS settings also export shares on 2049, pick one owner of that
port. This stack wants the **host** to own it.

## Optional: host Unraid pool instead

If you later prefer Unraid to own the Btrfs cache pool
(`Main → Add Pool → RAID0`) and only run NFS export in Docker, bind
`/mnt/fast-models` as a volume and drop `devices:` / format logic. That is
the “host pool” topology. This compose is the **device-bound** path.

## Optional: Alpine VM (true PCIe isolation)

VFIO passthrough of the dual-NVMe card + ZFS bclone + NFS inside a minimal
VM is the dedicated-host story. Not implemented in this compose.

## Verification checklist

1. `docker compose ps` — `fast-models` healthy.
2. `docker exec fast-models btrfs fi show` — both NVMe devices in one FS.
3. `docker exec fast-models ls /ai-data` — layout dirs present.
4. Client: NFS 4.2 mount + multi-GiB read/write (`test -f …/.fast-models-info`).
5. After reboot: host `/mnt/ai-data` is a **mount**, `showmount` lists it,
   console did **not** print Permission denied on the persist script.
6. (Later) two near-identical GGUFs under `models/` → bees/compsize shows savings.

## How this came to be

Shared models and tool trees got too big to copy onto every machine (desk
Mac, GPU host, NAS). After the caregiving pivot (**13 April 2026**) and the
race toward the ACL Phase 1 deadline (**31 July 2026**), the home lab needed
one honest pool: fast NVMe, Btrfs, bees for near-duplicates, NFS for clients.

This repo is that storage plane, spun out of the M.A.N.A.G.E.R. monorepo so
the gateway and coding agents have somewhere real to put weights. Public
release followed the ACL submission week as part of opening the stack piece
by piece.

**Timeline anchors:** vibecoding from **22 March 2026**; caregiving mission
from **13 April 2026**; LLC **20 April 2026**; public modular repos late
**July 2026**.

## Files

| File | Role |
|------|------|
| `docker-compose.yml` | Unraid import target |
| `Dockerfile` | Alpine + btrfs + bees + nfs-utils |
| `entrypoint.sh` | format/mount → layout → bees |
| `scripts/host-nfs-export.sh` | Host mount + nfsd persist (invoke with `bash`) |
| `config/exports.template` | NFS export (container path; unused when `ENABLE_NFS=0`) |
| `config/bees.conf.template` | bees notes / UUID stamp |
| `.env.example` | device paths + safety flags |
| `docs/` | Runbook, incident, [GitHub Pages](https://the1truedan.github.io/fast-models/) |

---

<p align="left">
  <a href="https://the1truedan.github.io/fast-models/"><img src="https://img.shields.io/badge/pages-fast--models-e8b84a?style=for-the-badge" alt="GitHub Pages"></a>
  <a href="https://github.com/the1truedan/fast-models/releases/tag/v0.2.0"><img src="https://img.shields.io/badge/release-v0.2.0-3dcaa0?style=for-the-badge" alt="v0.2.0"></a>
  <a href="https://linktr.ee/the1truedan"><img src="https://img.shields.io/badge/Linktree-39E09B?style=for-the-badge&logo=linktree&logoColor=white" alt="Linktree"></a>
  <a href="https://ko-fi.com/the1truedan"><img src="https://img.shields.io/badge/Ko--fi-F16061?style=for-the-badge&logo=ko-fi&logoColor=white" alt="Ko-fi"></a>
</p>

**© 2026 M.A.N.A.G.E.R. LLC** — *prepare for the care when we cannot be there*
