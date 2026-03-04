#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if rg -n "^(<<<<<<<|=======|>>>>>>>)" . >/tmp/prismos-conflicts.txt 2>/dev/null; then
  echo "[ERRORE] Trovati marker di conflitto:" >&2
  cat /tmp/prismos-conflicts.txt >&2
  exit 1
fi

echo "[OK] Nessun marker di conflitto trovato nella working tree"
