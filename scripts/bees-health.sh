#!/bin/bash
# Unraid User Scripts / cron: daily bees + free-space health log for fast-models.
# Prefer the managed Tower path:
#   /mnt/user/appdata/manager-orchestration/exporters/bees_health_cron.sh
# Schedule example: daily 03:15  (installed via install_dedup_cron.sh)
set -euo pipefail

# Delegate to the exporter-dir copy when present (single source of truth on Tower).
MANAGED="${MANAGED_BEES_HEALTH:-/mnt/user/appdata/manager-orchestration/exporters/bees_health_cron.sh}"
if [ -x "$MANAGED" ]; then
  exec "$MANAGED"
fi

LOG_DIR="${LOG_DIR:-/mnt/user/appdata/fast-models/logs}"
LOG="${LOG_DIR}/bees-health.log"
CONTAINER="${CONTAINER:-fast-models}"

mkdir -p "$LOG_DIR"
{
  echo "===== $(date -Iseconds) ====="
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "CONTAINER_DOWN: $CONTAINER"
    exit 1
  fi
  docker exec "$CONTAINER" sh -c 'pgrep -a bees || echo BEES_DOWN'
  docker exec "$CONTAINER" btrfs fi df /ai-data 2>/dev/null || echo "btrfs fi df failed"
  docker exec "$CONTAINER" df -h /ai-data 2>/dev/null || true
  docker exec "$CONTAINER" sh -c 'test -f /var/lib/bees/beeshash.dat && echo hash_ok || echo hash_MISSING'
} >>"$LOG" 2>&1
