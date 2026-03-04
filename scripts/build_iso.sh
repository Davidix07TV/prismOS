#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="$ROOT_DIR/profiles"
OUTPUT_DIR="$ROOT_DIR/output"
BUILD_STAMP="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<USAGE
Uso:
  $(basename "$0") <work|games|edu|slim|all>
USAGE
}

require_profile() {
  local profile="$1"
  local profile_file="$PROFILES_DIR/${profile}.conf"
  if [[ ! -f "$profile_file" ]]; then
    echo "[ERRORE] Profilo non trovato: $profile" >&2
    exit 1
  fi
}

sanitize_packages() {
  echo "$1" | xargs
}

build_profile() {
  local profile="$1"
  local profile_file="$PROFILES_DIR/${profile}.conf"

  require_profile "$profile"
  # shellcheck disable=SC1090
  source "$profile_file"

  local workdir="$OUTPUT_DIR/${PROFILE_ID}-${BUILD_STAMP}"
  local isoroot="$workdir/iso-root"
  mkdir -p "$isoroot/.meta"

  cat > "$isoroot/.meta/profile.txt" <<META
PROFILE_ID=$PROFILE_ID
DISPLAY_NAME=$DISPLAY_NAME
BASE_DESKTOP=$BASE_DESKTOP
KERNEL_FLAVOR=$KERNEL_FLAVOR
TARGET_HARDWARE=$TARGET_HARDWARE
SERVICES_ENABLE=$SERVICES_ENABLE
SERVICES_DISABLE=$SERVICES_DISABLE
TUNING=$TUNING
PACKAGES=$(sanitize_packages "$PACKAGES")
META

  if [[ "${POLICY_FILE:-}" != "" ]]; then
    cp "$ROOT_DIR/$POLICY_FILE" "$isoroot/.meta/edu.policy.json"
  fi

  local iso_name="prismOS-${PROFILE_ID}-${BUILD_STAMP}.iso"
  if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs \
      -o "$OUTPUT_DIR/$iso_name" \
      -V "PRISM_${PROFILE_ID^^}" \
      "$isoroot" >/dev/null 2>&1
    echo "[OK] ISO generata: $OUTPUT_DIR/$iso_name"
  else
    tar -czf "$OUTPUT_DIR/${iso_name}.tar.gz" -C "$workdir" iso-root
    echo "[WARN] xorriso non trovato: creato fallback $OUTPUT_DIR/${iso_name}.tar.gz"
  fi
}

main() {
  if [[ "${1:-}" == "" ]]; then
    usage
    exit 1
  fi

  mkdir -p "$OUTPUT_DIR"

  case "$1" in
    work|games|edu|slim)
      build_profile "$1"
      ;;
    all)
      for profile in work games edu slim; do
        build_profile "$profile"
      done
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
