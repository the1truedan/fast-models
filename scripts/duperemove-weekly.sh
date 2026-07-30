#!/bin/bash
# Unraid User Scripts / cron: optional weekly duperemove complement (IO-heavy).
# Schedule example: Sunday 04:00. bees remains primary continuous dedupe.
set -euo pipefail

LOG_DIR="${LOG_DIR:-/mnt/user/appdata/fast-models/logs}"
LOG="${LOG_DIR}/duperemove.log"
CONTAINER="${CONTAINER:-fast-models}"
TARGET="${TARGET:-/ai-data/models}"

mkdir -p "$LOG_DIR"
{
  echo "===== $(date -Iseconds) duperemove $TARGET ====="
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "CONTAINER_DOWN: $CONTAINER"
    exit 1
  fi
  docker exec "$CONTAINER" duperemove -r -d -h "$TARGET"
  docker exec "$CONTAINER" btrfs fi df /ai-data
  docker exec "$CONTAINER" compsize "$TARGET" 2>/dev/null || echo "compsize unavailable"
} >>"$LOG" 2>&1
