# fast-models

A small Unraid Docker stack that owns two NVMe drives as a shared **AI file pool**:
models, caches, git checkouts, Pinokio trees — the bulky stuff you want on one
fast share instead of copied onto every machine.

| Layer | What we use |
|-------|-------------|
| Drives | Two NVMe devices (prefer stable `/dev/disk/by-id/…` paths) |
| Filesystem | Btrfs RAID0 (fast, **no parity** — one dead drive loses the pool) |
| Space saving | **bees** keeps similar file chunks from eating disk twice |
| Sharing | NFS so Mac/Linux clients can mount the pool |
| Scope | **Storage only** — not your LLM chat stack |

This is the storage half of a home AI lab, not a full “AI platform in a box.”

## Docker is not a VM passthrough

The container is privileged and sees the raw NVMe block devices through the
**host** kernel. That is convenient; it is **not** the same as giving a VM
exclusive PCIe ownership of the drives.

**Do not** also put those NVMes in the Unraid array, a cache pool, or
Unassigned Devices auto-mount while this stack is using them.

## Prerequisites

1. **BIOS**: PCIe bifurcation for the dual-M.2 adapter slot (`x4x4` / vendor equivalent). ML350 Gen10 bifurcation can be picky — confirm both drives after boot.
2. **Unraid plugins** (recommended): Unassigned Devices (for inventory only; do not auto-mount these two), Dynamix SSD TRIM optional.
3. **Host free**: leave both NVMe **unassigned**.
4. **Docker Compose**: Compose Manager plugin, Portainer, or CLI `docker compose`.

Identify devices:

```bash
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL
ls -l /dev/disk/by-id/nvme-*
```

## Import on Unraid

### A. Compose Manager (recommended)

1. Copy this folder to the array, e.g.  
   `/mnt/user/appdata/fast-models/stack/`  
   (or your Compose Manager projects path).
2. `cp .env.example .env` and set `NVME0` / `NVME1` to **by-id** paths.
3. Create appdata dirs:
   ```bash
   mkdir -p /mnt/user/appdata/fast-models/{bees,config}
   ```
4. In **Compose Manager**: add project → point at this `docker-compose.yml` → **Compose Up** (build).

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

When healthy:

```bash
# set ALLOW_FORMAT=0 in .env and recreate
docker compose --env-file .env up -d
```

**Destructive wipe** of existing filesystems: `FORCE_FORMAT=1` (with `ALLOW_FORMAT=1`). Never leave this set.

## Pool layout

Mounted inside the container at `/ai-data` (NFS root with `fsid=0`):

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

## Client mounts (NFS) — coexistence with Unraid host NFS

### Verified production pattern (Unraid host, example IP `<unraid-host-ip>`) — 2026-07-15

| Service | Role | Port 2049 |
|---------|------|-----------|
| **Unraid array NFS** | **Off** (`shareNFSEnabled=no`) — array paths are **SMB-only** | — |
| **Host NFS export** | `/mnt/ai-data` = same dual-NVMe Btrfs as the container (UUID `fast-models`) | **Owns** 2049 (v3+v4, rpcbind-registered — Mac-friendly) |
| **fast-models** container | Btrfs RAID0 + **bees**; `ENABLE_NFS=0` | Does **not** run nfsd |

**Why not container `ENABLE_NFS=1` alone?** Alpine-in-Docker nfsd listens on 2049 and works from Linux, but often **fails to register with host rpcbind**, so macOS `mount_nfs` returns *RPC prog. not avail*. Host nfsd + host mount of the same Btrfs is the reliable dual-client path.

**Persistence:** `/boot/config/plugins/fast-models/host-nfs-export.sh` (also in repo `scripts/host-nfs-export.sh`; hooked from `/boot/config/go` after ~45s) remounts UUID and restarts export.

**Array shares:** use **SMB** (`//<unraid-host>/opt`, Media, …). Do not re-enable Unraid share NFS UI if you want a single clean model-pool export.

### Client mount commands

**macOS (verified):** NFSv3 + full path (v4 root often fails with *RPC prog. not avail*):

```bash
sudo mkdir -p /Volumes/ai-data
sudo mount_nfs -o resvport,vers=3,tcp,rw,hard,intr \
  <unraid-host-ip>:/mnt/ai-data /Volumes/ai-data
test -f /Volumes/ai-data/.fast-models-info && echo OK
df -h /Volumes/ai-data
```

**Linux client (verified NFSv4.2, example IP `<linux-client-ip>`, 2026-07-15):**

```bash
sudo apt-get install -y nfs-common   # once
sudo mkdir -p /mnt/ai-data
sudo mount -t nfs -o vers=4.2,rsize=1048576,wsize=1048576,hard,noatime,nconnect=4 \
  <unraid-host-ip>:/ /mnt/ai-data
test -f /mnt/ai-data/.fast-models-info && cat /mnt/ai-data/.fast-models-info
findmnt -no FSTYPE,OPTIONS /mnt/ai-data   # expect nfs4 + vers=4.2
```

`fsid=0` export → mount path is **`/`** (not `/mnt/ai-data`). Fallback: `vers=4.1` or `vers=3` with `<unraid-host-ip>:/mnt/ai-data`.

**fstab (Linux client):**

```
<unraid-host-ip>:/  /mnt/ai-data  nfs  vers=4.2,rsize=1048576,wsize=1048576,hard,noatime,nconnect=4,_netdev,x-systemd.automount  0  0
```

**Multi-client write:** macOS defaults to uid **501**, most Linux distros default to uid **1000** for the first user. After bulk copy, keep shared dirs world-writable (LAN-only share) or both uids can write:

```bash
ssh root@<unraid-host-ip> 'chmod -R a+rwX /mnt/ai-data/{models,pinokio,uv-cache,work}'
```

### rsync onto the pool

**Models (Mac → pool; run on Mac, source is local 2TB):**

```bash
caffeinate -dims rsync -aH --no-owner --no-group --no-perms --info=progress2 --partial \
  --exclude '.DS_Store' \
  /Volumes/2TB/_models/ /Volumes/ai-data/models/
```

**Pinokio + uv (Linux client → pool; additive merge, no `--delete`):**

```bash
# on the Linux client, after mount
rsync -aH --no-owner --no-group --info=progress2 --partial \
  /path/to/pinokio/ /mnt/ai-data/pinokio/
rsync -aH --no-owner --no-group --info=progress2 --partial \
  ~/.cache/uv/ /mnt/ai-data/uv-cache/
```

**Symlink locals to NFS (after rsync verifies; stop apps first):**

```bash
mv /path/to/pinokio /path/to/pinokio.local-bak-$(date +%Y%m%d)
ln -s /mnt/ai-data/pinokio /path/to/pinokio
mv ~/.cache/uv ~/.cache/uv.local-bak-$(date +%Y%m%d)
ln -s /mnt/ai-data/uv-cache ~/.cache/uv
```

Ollama multi-path stays local for now — plan out your own migration if you run Ollama on more than one client.

Verify bees + space:

```bash
ssh root@<unraid-host-ip> 'docker exec fast-models pgrep -a bees; docker exec fast-models btrfs fi df /ai-data; du -sh /mnt/ai-data/models'
```
## bees — background space saving

bees quietly walks the Btrfs pool and shares identical chunks so near-duplicate
model files do not each take a full second copy of disk. It is **always on**
when `ENABLE_BEES=1` (not a nightly cron job).

### Hash table size (important)

bees keeps a fixed-size fingerprint table in `APPDATA/bees/beeshash.dat`.
RAM use is roughly the same size as that file.

| Size | When |
|------|------|
| **1G** | Small pools / first experiments only |
| **2G** | **Recommended default** for multi‑TiB pools (our production after 2026-08-01) |
| **4G** | Only if the 2G table stays nearly full after a full re-crawl; costs ~4 GiB sticky RAM on a box with **no swap** |

If the table hits **100% full**, bees still runs but forgets old fingerprints
and dedupes worse. That is **not** the same as the disk being full, and it is
**not** caused by Unraid parity checks.

**Growing the table safely**

1. Leave `ALLOW_FORMAT=0` and `FORCE_FORMAT=0`.
2. Stop **only the bees process** (keep the container and NFS share up if you can).
3. Rename the old `beeshash.dat` and `beescrawl.dat` (do not truncate a live 1G table “up” to 2G in place).
4. Create a fresh empty file: `truncate -s 2G beeshash.dat` (or 4G).
5. Set `BEES_HASH_SIZE=2G` in `.env` so the next full container start matches.
6. Start bees again. Occupancy will look near zero, then climb — that is normal.

### Runtime notes

- Image pins bees **v0.11** (with a small musl/`gettid` build fix for Alpine).
- Default: 1 thread, scan-mode 4 (extent), low priority (`nice` / `ionice`).
- Hash lives on the **array** under appdata, not on the NVMe pool itself.

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

Daily health / optional weekly duperemove scripts live under `scripts/`
(`bees-health.sh`, `duperemove-weekly.sh`) for Unraid User Scripts or cron.

## Safety

| Rule | Why |
|------|-----|
| RAID0 | One drive failure loses the **entire** pool |
| Models re-downloadable | Prefer HF / Forgejo rehydrate over treating pool as sole backup |
| No array membership | Prevents Unraid and container fighting for the same devices |
| `ALLOW_FORMAT=0` steady-state | Avoids accidental `mkfs` on restart |
| Tighten `NFS_CLIENTS` | Default `192.168.0.0/16` is LAN-wide |

If Unraid **NFS settings** also export shares on 2049, disable host NFS or this stack’s `ENABLE_NFS` — only one NFS server should own port 2049.

## Optional: host Unraid pool instead

If you later prefer Unraid to own the Btrfs cache pool (`Main → Add Pool → RAID0`) and only run NFS export in Docker, bind `/mnt/fast-models` as a volume and drop `devices:` / format logic. That is the “host pool” topology; this compose is the **device-bound** path you selected.

## Optional: Alpine VM (true PCIe isolation)

For VFIO passthrough of the dual-NVMe card + ZFS bclone + NFS inside a minimal VM, use the Alpine/ZFS runbook from prior M.A.N.A.G.E.R. notes. Not implemented here.

## Verification checklist

1. `docker compose ps` — `fast-models` healthy.
2. `docker exec fast-models btrfs fi show` — both NVMe devices in one FS.
3. `docker exec fast-models ls /ai-data` — layout dirs present.
4. Client: NFS 4.2 mount + multi‑GiB read/write.
5. After reboot: remount works with `ALLOW_FORMAT=0`.
6. (Later) two near-identical GGUFs under `models/` → bees/compsize shows savings.


## How this came to be

Shared models and tool trees got too big to copy onto every laptop and GPU box.
After the caregiving pivot (**13 April 2026**) and the race toward the ACL
Phase 1 deadline (**31 July 2026**), the home lab needed one honest pool:
**ai-data** on Tower — fast NVMe, Btrfs, bees for near-duplicates, NFS for
clients.

This repo is that storage plane, spun out of the M.A.N.A.G.E.R. monorepo work
so the gateway and coding agents have somewhere real to put weights. It was
shaped in long Grok / Claude / ChatGPT design sessions, then grounded in git
on the Unraid host — not left as chat folklore. Public release followed the
ACL submission week as part of opening the stack piece by piece.

**Timeline anchors:** vibecoding from **22 March 2026**; caregiving mission from
**13 April 2026**; LLC **20 April 2026**; public modular repos late **July 2026**.

## Files

| File | Role |
|------|------|
| `docker-compose.yml` | Unraid import target |
| `Dockerfile` | Alpine + btrfs + bees + nfs-utils |
| `entrypoint.sh` | format/mount → layout → bees → nfsd |
| `config/exports.template` | NFS export |
| `config/bees.conf.template` | bees notes / UUID stamp |
| `.env.example` | device paths + safety flags |

---

<p align="left">
  <a href="https://linktr.ee/the1truedan"><img src="https://img.shields.io/badge/Linktree-39E09B?style=for-the-badge&logo=linktree&logoColor=white" alt="Linktree"></a>
  <a href="https://ko-fi.com/the1truedan"><img src="https://img.shields.io/badge/Ko--fi-F16061?style=for-the-badge&logo=ko-fi&logoColor=white" alt="Ko-fi"></a>
</p>

**© 2026 M.A.N.A.G.E.R. LLC** — *prepare for the care when we cannot be there*
