#!/usr/bin/env bash
# file: data/log-rotate-by-size.sh v1.0
#
# Size-based rotation for myfakesite access log without logrotate.
# - Rotates when access.log reaches 1 MiB
# - Keeps rotated files for 7 days
# - Safe for fail2ban (truncate in place)

set -euo pipefail

LOG_DIR="/var/log/myfakesite"
LOG_FILE="${LOG_DIR}/access.log"
MAX_SIZE_BYTES=$((1024 * 1024)) # 1 MiB
RETENTION_DAYS=7

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)

if [[ "$size" -ge "$MAX_SIZE_BYTES" ]]; then
  ts=$(date +%Y%m%d-%H%M%S)
  rotated="${LOG_DIR}/access.log.${ts}"

  cp "$LOG_FILE" "$rotated"
  : > "$LOG_FILE"
fi

find "$LOG_DIR" -type f -name 'access.log.*' -mtime +"$RETENTION_DAYS" -delete

