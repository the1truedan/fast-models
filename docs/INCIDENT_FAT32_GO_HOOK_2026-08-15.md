# Incident — Unraid `/boot/config/go` exec on FAT32 (2026-08-15)

**Lab id:** CVE-FAUX-2026-0815-2  
**Not a CVE.** Not a bees bug. Not an NFS protocol bug. A boot-script
misconfiguration that looks like “the AI gateway is down.”

## What operators saw

After a NAS reboot:

- The Unraid **console** printed **Permission denied** while a startup script ran.
- Linux/macOS clients could not mount the model pool (`connection refused` on
  port 2049 / rpcbind 111).
- A Docker stack on a desk host failed to start a container whose volume was
  an NFS bind to `…:/mnt/ai-data/uv-cache`.
- The `fast-models` container itself was **healthy**. bees was still walking
  the pool *inside* the container.

## What was actually wrong

`/boot/config/go` contained:

```bash
( sleep 45; /boot/config/plugins/fast-models/host-nfs-export.sh ) &
```

Unraid’s `/boot` flash is **FAT32**. It cannot store Unix execute bits. The
script lived there as `-rw-------`. After the 45s sleep, the shell tried to
exec it → **Permission denied** → the persist script never ran.

Consequences:

- Host `/mnt/ai-data` stayed an empty placeholder directory, not a Btrfs mount.
- `/etc/exports` stayed the stock comment stub.
- Host nfsd / rpcbind never started.
- The real pool was mounted only inside the container.

## What did *not* fix it (and wasted a session)

These were written down as a 2026-07-28 stopgap and then copied into an
operator chat. They are the wrong restore:

| Stopgap | Why it fails |
|---------|----------------|
| `/etc/rc.d/rc.nfsd start` | Daemon up, export table empty → clients still get nothing |
| Unraid **Settings → NFS** | Turns on array-share NFS; this stack wants `shareNFSEnabled=no` |
| Treat it as the chat-proxy / LiteLLM container | That process never reached its config; the volume mount failed first |
| “NFS has been down since July” | The export was live in early August. It died on *this* reboot because the hook could not exec |

## Fix

```bash
# 1. Make the hook survive FAT32
# in /boot/config/go
( sleep 45; bash /boot/config/plugins/fast-models/host-nfs-export.sh ) &

# 2. Run it once now
bash /boot/config/plugins/fast-models/host-nfs-export.sh

# 3. Check from a client
showmount -e <nas-host-ip>
```

The script host-mounts the pool, writes `/etc/exports`, and starts nfsd.

## Disclosure notes

- **CVE-FAUX-2026-0815** (same day, earlier) was a lab joke number for an
  agent stating “the NAS rebooted” without checking `uptime`.
- **CVE-FAUX-2026-0815-2** is this follow-on: the same class of miss
  (narrating LiteLLM / “NFS never fixed” instead of reading the console
  Permission denied).
- No CVE reservation. No vendor advisory. Published here so the next Unraid
  operator does not spend an evening on the stopgaps above.

Full operator steps: [UNRAID_NFS_PERSIST.md](UNRAID_NFS_PERSIST.md).
