# bees hash table sizing

bees needs a fixed-size fingerprint table (`beeshash.dat`). Think of it as a
phone book of content chunks: when the book is full, bees still runs, but it
forgets older entries and dedupes less well.

## Defaults we recommend

| Size | Use when |
|------|----------|
| 1G | Small experiments only |
| **2G** | Multi-terabyte AI file pools (production default after 2026-08-01) |
| 4G | Only if 2G stays ~full after a full re-crawl; costs ~4 GiB sticky RAM |

On a 32 GiB Unraid host with **no swap**, prefer 2G first. Step up deliberately.

## Growing without drama

1. Keep `ALLOW_FORMAT=0` and `FORCE_FORMAT=0`.
2. Stop **bees only** if you can; leave the container and NFS share up.
3. Rename old `beeshash.dat` and `beescrawl.dat`.
4. `truncate -s 2G beeshash.dat` (fresh empty file — do not enlarge a live
   structured 1G table in place).
5. Set `BEES_HASH_SIZE=2G` in `.env`.
6. Start bees again. Occupancy near zero, then climbing, is expected.

A full hash table is **not** the same as a full disk, and Unraid parity does
not fill the bees table.

HTML version: [bees.html](bees.html) on the project site.
