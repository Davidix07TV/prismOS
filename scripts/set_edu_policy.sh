#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_FILE="$ROOT_DIR/profiles/edu.policy.json"

allow_apps=""
deny_web=""
disable_settings=""

usage() {
  cat <<USAGE
Uso:
  $(basename "$0") --allow-apps "a,b,c" --deny-web "x,y" --disable-settings "k,z"
USAGE
}

json_array_from_csv() {
  local csv="$1"
  local escaped
  escaped="$(echo "$csv" | sed 's/,/","/g')"
  printf '["%s"]' "$escaped"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-apps)
      allow_apps="$2"
      shift 2
      ;;
    --deny-web)
      deny_web="$2"
      shift 2
      ;;
    --disable-settings)
      disable_settings="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Argomento sconosciuto: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$allow_apps" || -z "$deny_web" || -z "$disable_settings" ]]; then
  echo "[ERRORE] Parametri incompleti." >&2
  usage
  exit 1
fi

cat > "$POLICY_FILE" <<JSON
{
  "allow_apps": $(json_array_from_csv "$allow_apps"),
  "deny_web": $(json_array_from_csv "$deny_web"),
  "disable_settings": $(json_array_from_csv "$disable_settings")
}
JSON

echo "[OK] Policy EDU aggiornata: $POLICY_FILE"
