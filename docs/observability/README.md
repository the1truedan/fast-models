# Observability — bees + btrfs (Grafana / Prometheus)

Import the dashboard, scrape the textfile exporter, do not publish LAN IPs.

| File | Role |
|------|------|
| [`grafana-bees-dashboard.json`](grafana-bees-dashboard.json) | Grafana import, uid `fast-models-bees-dedupe` |
| [`prometheus-scrape.example.yml`](prometheus-scrape.example.yml) | Sample scrape of `nas-host:9100` |
| [`sample-metrics.prom`](sample-metrics.prom) | Live-shaped snapshot (2026-08-15) |
| [`../../deploy/observability/ai_data_stats_exporter.sh`](../../deploy/observability/ai_data_stats_exporter.sh) | Writes the textfile node_exporter reads |

Site page with screenshots: [observability.html](../observability.html).

## Wire it

1. Run `ai_data_stats_exporter.sh` every 15 minutes on the **NAS host** (not from a Mac/GPU NFS client).
2. Point node_exporter at the output directory (`--collector.textfile.directory`).
3. Scrape that node_exporter from Prometheus.
4. Grafana → Import → `grafana-bees-dashboard.json`. Datasource uid defaults to `prometheus`.

## Two different “savings” numbers

1. **Block/extent (bees + zstd)** — compare logical size to `btrfs_ai_data_used_bytes`. This is real physical reclaim.
2. **Content-hash audit** — `ai_data_dedup_reclaimable_gb` is *candidates* for a human merge. It is not bees savings. The exporter only emits those series if you pass `AUDIT_JSON`.

## Sample snapshot (2026-08-15)

Generic buckets from `du` on a live two-NVMe RAID0 pool. bees was up. The hash-table file on the array was unreadable after the host reboot (I/O error), so occupancy is omitted on purpose.

| Bucket | Apparent size |
|--------|----------------|
| models | 1.6T |
| pinokio | 436G |
| uv-cache | 226G |
| github | 67G |
| hf-cache | 26G |
| **btrfs Data used / allocated** | **2.08 TiB / 2.22 TiB** |

Device raw capacity was about 3.68 TiB (1.82 + 1.86). RAID0 has no parity.

No hostnames, no LAN IPs, no home paths in these files.
