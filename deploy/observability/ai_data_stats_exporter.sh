#!/bin/sh
# Textfile exporter: bees + btrfs capacity (+ optional content-hash audit JSON).
# Intended for node_exporter --collector.textfile.directory.
# Cron: every 15 minutes on the NAS host (host-local, not over NFS).
#
# Paths below are generic. Override with env. Do not point AUDIT_JSON at a
# client NFS mount.
set -eu

CONTAINER="${CONTAINER:-fast-models}"
AI_DATA_HOST="${AI_DATA_HOST:-/mnt/ai-data}"
AI_DATA_CTR="${AI_DATA_CTR:-/ai-data}"
OUT_DIR="${OUT_DIR:-/var/lib/node_exporter/textfile}"
OUT="$OUT_DIR/fast_models_stats.prom"
TMP="$OUT.tmp"
AUDIT_JSON="${AUDIT_JSON:-}"

mkdir -p "$OUT_DIR"
: >"$TMP"

echo "# fast_models_stats_exporter -- generated $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$TMP"

# ── bees process ────────────────────────────────────────────────────────────
BEES_UP=0
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  if docker exec "$CONTAINER" sh -c 'pgrep -x bees >/dev/null' 2>/dev/null; then
    BEES_UP=1
  fi
fi
{
  echo "# HELP bees_up 1 if bees is running inside the fast-models container."
  echo "# TYPE bees_up gauge"
  echo "bees_up $BEES_UP"
} >>"$TMP"

if [ "$BEES_UP" -eq 1 ]; then
  BEES_STATS=$(docker exec "$CONTAINER" sh -c 'cat "${BEESHOME:-/var/lib/bees}/beesstats.txt" 2>/dev/null' || true)
  if [ -n "$BEES_STATS" ]; then
    UPTIME=$(echo "$BEES_STATS" | sed -n 's/^Uptime:[[:space:]]*\([0-9.][0-9.]*\).*/\1/p' | head -1)
    OCC_PCT=$(echo "$BEES_STATS" | sed -n 's/.*cells occupied, \([0-9][0-9]*\)%.*/\1/p' | head -1)
    COMP_PCT=$(echo "$BEES_STATS" | sed -n 's/^compressed [0-9][0-9]* (\([0-9][0-9]*\)%).*/\1/p' | head -1)
    UNCOMP_PCT=$(echo "$BEES_STATS" | sed -n 's/.*uncompressed [0-9][0-9]* (\([0-9][0-9]*\)%).*/\1/p' | head -1)
    EXTENT_REF_OK=$(echo "$BEES_STATS" | sed -n 's/.*extent_ref_ok=\([0-9][0-9]*\).*/\1/p' | head -1)
    pct_to_ratio() { awk -v p="${1:-0}" 'BEGIN { if (p < 0) p = 0; printf "%.6f\n", p / 100.0 }'; }
    {
      [ -n "$UPTIME" ] && echo "# HELP bees_uptime_seconds bees uptime." && echo "# TYPE bees_uptime_seconds gauge" && echo "bees_uptime_seconds $UPTIME"
      [ -n "$OCC_PCT" ] && echo "# HELP bees_hash_table_occupancy_ratio bees hash fill (near 1.0 = table too small)." && echo "# TYPE bees_hash_table_occupancy_ratio gauge" && echo "bees_hash_table_occupancy_ratio $(pct_to_ratio "$OCC_PCT")"
      [ -n "$COMP_PCT" ] && echo "# HELP bees_extents_compressed_ratio Fraction of scanned extents that are compressed." && echo "# TYPE bees_extents_compressed_ratio gauge" && echo "bees_extents_compressed_ratio $(pct_to_ratio "$COMP_PCT")"
      [ -n "$UNCOMP_PCT" ] && echo "# HELP bees_extents_uncompressed_ratio Fraction of scanned extents that are uncompressed." && echo "# TYPE bees_extents_uncompressed_ratio gauge" && echo "bees_extents_uncompressed_ratio $(pct_to_ratio "$UNCOMP_PCT")"
      [ -n "$EXTENT_REF_OK" ] && echo "# HELP bees_extent_ref_ok_total Extents successfully deduplicated since bees start (not bytes)." && echo "# TYPE bees_extent_ref_ok_total counter" && echo "bees_extent_ref_ok_total $EXTENT_REF_OK"
    } >>"$TMP"
  fi
fi

# ── btrfs Data profile (physical after bees + zstd) ─────────────────────────
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  BTRFS_DF=$(docker exec "$CONTAINER" btrfs fi df -b "$AI_DATA_CTR" 2>/dev/null || true)
  if [ -n "$BTRFS_DF" ]; then
    DATA_TOTAL=$(echo "$BTRFS_DF" | sed -n 's/^Data,.*total=\([0-9][0-9]*\).*/\1/p' | head -1)
    DATA_USED=$(echo "$BTRFS_DF" | sed -n 's/^Data,.*used=\([0-9][0-9]*\).*/\1/p' | head -1)
    META_USED=$(echo "$BTRFS_DF" | sed -n 's/^Metadata,.*used=\([0-9][0-9]*\).*/\1/p' | head -1)
    {
      [ -n "$DATA_TOTAL" ] && echo "# HELP btrfs_ai_data_total_bytes btrfs Data profile total bytes." && echo "# TYPE btrfs_ai_data_total_bytes gauge" && echo "btrfs_ai_data_total_bytes $DATA_TOTAL"
      [ -n "$DATA_USED" ] && echo "# HELP btrfs_ai_data_used_bytes btrfs Data profile used bytes." && echo "# TYPE btrfs_ai_data_used_bytes gauge" && echo "btrfs_ai_data_used_bytes $DATA_USED"
      [ -n "$META_USED" ] && echo "# HELP btrfs_ai_data_metadata_used_bytes btrfs Metadata used bytes." && echo "# TYPE btrfs_ai_data_metadata_used_bytes gauge" && echo "btrfs_ai_data_metadata_used_bytes $META_USED"
    } >>"$TMP"
  fi
fi

# ── host df of the pool mount ───────────────────────────────────────────────
if [ -d "$AI_DATA_HOST" ]; then
  DF_LINE=$(df -B1 "$AI_DATA_HOST" 2>/dev/null | awk 'NR==2 {print}')
  if [ -n "$DF_LINE" ]; then
    echo "# HELP ai_data_mount_size_bytes Host df size of the pool mount." >>"$TMP"
    echo "# TYPE ai_data_mount_size_bytes gauge" >>"$TMP"
    echo "ai_data_mount_size_bytes $(echo "$DF_LINE" | awk '{print $2}')" >>"$TMP"
    echo "# HELP ai_data_mount_used_bytes Host df used of the pool mount." >>"$TMP"
    echo "# TYPE ai_data_mount_used_bytes gauge" >>"$TMP"
    echo "ai_data_mount_used_bytes $(echo "$DF_LINE" | awk '{print $3}')" >>"$TMP"
    echo "# HELP ai_data_mount_avail_bytes Host df available on the pool mount." >>"$TMP"
    echo "# TYPE ai_data_mount_avail_bytes gauge" >>"$TMP"
    echo "ai_data_mount_avail_bytes $(echo "$DF_LINE" | awk '{print $4}')" >>"$TMP"
  fi
fi

# ── optional L2 content-hash audit (report-only; not bees savings) ──────────
if [ -n "$AUDIT_JSON" ] && [ -f "$AUDIT_JSON" ]; then
  echo "# HELP ai_data_dedup_bucket_total_gb Indexed size per bucket (content-hash audit)." >>"$TMP"
  echo "# TYPE ai_data_dedup_bucket_total_gb gauge" >>"$TMP"
  jq -r '
    (.buckets // [])[]
    | select(.bucket | test("^[a-zA-Z0-9_./-]+$"))
    | "ai_data_dedup_bucket_total_gb{bucket=\"" + .bucket + "\"} " + ((.tally.total_gb // .summary.total_gb // 0) | tostring)
  ' "$AUDIT_JSON" >>"$TMP"
  echo "# HELP ai_data_dedup_bucket_reclaimable_gb Reclaim candidates per bucket (not automatic)." >>"$TMP"
  echo "# TYPE ai_data_dedup_bucket_reclaimable_gb gauge" >>"$TMP"
  jq -r '
    (.buckets // [])[]
    | select(.bucket | test("^[a-zA-Z0-9_./-]+$"))
    | "ai_data_dedup_bucket_reclaimable_gb{bucket=\"" + .bucket + "\"} " + ((.summary.reclaimable_gb // 0) | tostring)
  ' "$AUDIT_JSON" >>"$TMP"
fi

mv "$TMP" "$OUT"
