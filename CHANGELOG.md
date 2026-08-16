# Changelog

All notable changes to **fast-models** are documented here.
Format inspired by [Keep a Changelog](https://keepachangelog.com/).

## [0.2.2] — 2026-08-15

### Changed

- Completed the 2026-08-15 bucket snapshot: apparent tree **3.2T** vs btrfs
  Data used **2.08 TiB**. Added opt, llms, `_dl`, work, comfyui,
  stability-matrix, comfyui-music3. Same generic names only.

## [0.2.1] — 2026-08-15

### Added

- **Grafana / Prometheus sample.** Importable dashboard
  (`docs/observability/grafana-bees-dashboard.json`), textfile exporter
  (`deploy/observability/ai_data_stats_exporter.sh`), example scrape config,
  and a 2026-08-15 metrics snapshot. Screenshots use generic bucket names
  and live sizes only (models 1.6T, pinokio 436G, uv-cache 226G, github 67G,
  hf-cache 26G; btrfs Data 2.08 / 2.22 TiB). No LAN IPs or home paths.
- Pages: [observability.html](https://the1truedan.github.io/fast-models/observability.html)

## [0.2.0] — 2026-08-15

Site: [the1truedan.github.io/fast-models](https://the1truedan.github.io/fast-models/)

### Added

- **Unraid persist runbook.** Host nfsd for `/mnt/ai-data` must be started from
  `/boot/config/go` with `bash`, not by executing the flash script. `/boot` is
  FAT32 and cannot hold Unix execute bits. A bare path prints
  `Permission denied` on the console and leaves NFS down.
- **GitHub Pages** (`docs/`): landing page with a bees/extent-share animation,
  operator runbook, and a public misconfiguration disclosure.
- `VERSION` file and this changelog.
- Public incident note
  [`docs/INCIDENT_FAT32_GO_HOOK_2026-08-15.md`](docs/INCIDENT_FAT32_GO_HOOK_2026-08-15.md)
  (lab id CVE-FAUX-2026-0815-2 — not a real CVE).

### Fixed

- `scripts/host-nfs-export.sh` header now says to invoke with `bash`.
- README no longer points at a private monorepo path for the persist bug.

### Documented (still true)

- Unraid **array** NFS stays off (`shareNFSEnabled=no`). Array shares are SMB.
- The `fast-models` container does **not** run nfsd (`ENABLE_NFS=0`). Host nfsd
  owns port 2049 so macOS and Linux clients can both mount.
- Linux clients: NFSv4.2, `fsid=0` → mount `/`. macOS: NFSv3 + full path.
- This Unraid host-nfsd layout is the stopgap until the pool lives on its own
  non-Unraid host.

## [0.1.0] — 2026-08-01

Initial public release: Unraid Docker stack, Btrfs RAID0 on two unassigned
NVMe devices, bees v0.11, host NFS export, MIT license.
