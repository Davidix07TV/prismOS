#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="$ROOT_DIR/profiles"

required=(PROFILE_ID DISPLAY_NAME BASE_DESKTOP KERNEL_FLAVOR TARGET_HARDWARE PACKAGES)

for conf in "$PROFILES_DIR"/*.conf; do
  [[ "$(basename "$conf")" == "common.conf" ]] && continue
  # shellcheck disable=SC1090
  source "$PROFILES_DIR/common.conf"
  # shellcheck disable=SC1090
  source "$conf"
  echo "Validazione $(basename "$conf")"
  for key in "${required[@]}"; do
    [[ -n "${!key:-}" ]] || { echo "[ERRORE] $key mancante in $conf" >&2; exit 1; }
  done
  if [[ "${PROFILE_ID}" == "edu" ]]; then
    python3 -m json.tool "$ROOT_DIR/${POLICY_FILE}" >/dev/null
  fi
done

echo "[OK] Tutti i profili sono validi"
