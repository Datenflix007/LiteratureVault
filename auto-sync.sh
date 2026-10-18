#!/usr/bin/env bash
set -u

# Activity monitor only: the provider desktop client syncs this folder. Do not
# add Zotero attachments to Git or Git LFS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH_PATH="${1:-}"

if [ -z "$WATCH_PATH" ] && [ -f "$SCRIPT_DIR/.env" ]; then
  WATCH_PATH="$(sed -n 's/^ZOTERO_STORAGE_PATH=//p' "$SCRIPT_DIR/.env" | head -n 1)"
fi
WATCH_PATH="${WATCH_PATH:-$SCRIPT_DIR/data}"
case "$WATCH_PATH" in /*) ;; *) WATCH_PATH="$SCRIPT_DIR/$WATCH_PATH" ;; esac
mkdir -p "$WATCH_PATH"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1"; }
log "Speicher-Monitor gestartet: $WATCH_PATH"
log "Die Cloud-App synchronisiert diesen Ordner; Anhaenge werden nicht in Git uebernommen."

last_stamp="$(find "$WATCH_PATH" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)"
while true; do
  sleep 5
  stamp="$(find "$WATCH_PATH" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)"
  if [ "$stamp" != "$last_stamp" ]; then
    last_stamp="$stamp"
    log "Dateien im externen Speicher wurden aktualisiert."
  fi
done
