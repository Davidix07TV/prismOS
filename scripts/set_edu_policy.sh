#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_FILE="$ROOT_DIR/profiles/edu.policy.json"

allow_apps=""
deny_web=""
disable_settings=""
allow_guest="false"
max_idle_minutes="20"

usage() {
  cat <<USAGE
Uso:
  $(basename "$0") \
    --allow-apps "a,b,c" \
    --deny-web "x,y" \
    --disable-settings "k,z" \
    [--allow-guest true|false] \
    [--max-idle 20]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-apps) allow_apps="$2"; shift 2 ;;
    --deny-web) deny_web="$2"; shift 2 ;;
    --disable-settings) disable_settings="$2"; shift 2 ;;
    --allow-guest) allow_guest="$2"; shift 2 ;;
    --max-idle) max_idle_minutes="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Argomento sconosciuto: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$allow_apps" || -z "$deny_web" || -z "$disable_settings" ]]; then
  echo "[ERRORE] Parametri obbligatori mancanti" >&2
  usage
  exit 1
fi

python3 - "$POLICY_FILE" "$allow_apps" "$deny_web" "$disable_settings" "$allow_guest" "$max_idle_minutes" <<'PY'
import json
import pathlib
import sys

def parse_csv(value: str):
    return [v.strip() for v in value.split(',') if v.strip()]

policy_path = pathlib.Path(sys.argv[1])
allow_apps = parse_csv(sys.argv[2])
deny_web = parse_csv(sys.argv[3])
disable_settings = parse_csv(sys.argv[4])
allow_guest_raw = sys.argv[5].strip().lower()
max_idle = int(sys.argv[6])

if allow_guest_raw not in {"true", "false"}:
    raise SystemExit("--allow-guest deve essere true o false")

policy = {
    "allow_apps": allow_apps,
    "deny_web": deny_web,
    "disable_settings": disable_settings,
    "session": {
        "allow_guest": allow_guest_raw == "true",
        "max_idle_minutes": max_idle,
    },
}
policy_path.write_text(json.dumps(policy, indent=2), encoding="utf-8")
print(f"[OK] Policy EDU aggiornata: {policy_path}")
PY
