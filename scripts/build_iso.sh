#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="$ROOT_DIR/profiles"
OVERLAYS_DIR="$ROOT_DIR/overlays"
OUTPUT_DIR="$ROOT_DIR/output"
TEMPLATES_DIR="$ROOT_DIR/templates"
STAMP="$(date +%Y%m%d-%H%M%S)"
RELEASE_NAME=""
CLEAN=0

usage() {
  cat <<USAGE
Uso:
  $(basename "$0") <work|games|edu|slim|all> [--name release-name] [--clean]

Esempi:
  $(basename "$0") work
  $(basename "$0") all --name beta1 --clean
USAGE
}

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERRORE] $*" >&2; }

sanitize_words() {
  xargs <<<"${1:-}" || true
}

require_profile() {
  local profile="$1"
  local profile_file="$PROFILES_DIR/${profile}.conf"
  [[ -f "$profile_file" ]] || { err "Profilo non trovato: $profile"; exit 1; }
}

load_profile() {
  local profile="$1"
  local common="$PROFILES_DIR/common.conf"
  local file="$PROFILES_DIR/${profile}.conf"
  [[ -f "$common" ]] || { err "Manca $common"; exit 1; }
  # shellcheck disable=SC1090
  source "$common"
  # shellcheck disable=SC1090
  source "$file"

  local required=(PROFILE_ID DISPLAY_NAME BASE_DESKTOP KERNEL_FLAVOR TARGET_HARDWARE PACKAGES)
  for key in "${required[@]}"; do
    [[ -n "${!key:-}" ]] || { err "Variabile obbligatoria mancante: $key ($file)"; exit 1; }
  done
}

setup_tree() {
  local rootfs="$1"
  mkdir -p "$rootfs/.meta" "$rootfs/etc/prismos" "$rootfs/boot/grub" "$rootfs/packages"
}

copy_overlays() {
  local profile="$1"
  local rootfs="$2"
  if [[ -d "$OVERLAYS_DIR/common" ]]; then
    cp -a "$OVERLAYS_DIR/common/." "$rootfs/"
  fi
  if [[ -d "$OVERLAYS_DIR/$profile" ]]; then
    cp -a "$OVERLAYS_DIR/$profile/." "$rootfs/"
  fi
}

render_metadata() {
  local rootfs="$1"
  local profile="$2"
  local release_tag="$3"
  local combined_packages
  combined_packages="$(sanitize_words "$BASE_PACKAGES $PACKAGES")"

  cat >"$rootfs/.meta/profile.env" <<META
DISTRO_NAME=$DISTRO_NAME
DISTRO_VERSION=$DISTRO_VERSION
PROFILE_ID=$PROFILE_ID
DISPLAY_NAME=$DISPLAY_NAME
EDITION_DESCRIPTION=${EDITION_DESCRIPTION:-}
RELEASE_TAG=$release_tag
BASE_DESKTOP=$BASE_DESKTOP
DISPLAY_MANAGER=${DISPLAY_MANAGER:-}
KERNEL_FLAVOR=$KERNEL_FLAVOR
TARGET_HARDWARE=$TARGET_HARDWARE
DEFAULT_LOCALE=$DEFAULT_LOCALE
DEFAULT_TIMEZONE=$DEFAULT_TIMEZONE
DEFAULT_KEYBOARD=$DEFAULT_KEYBOARD
SERVICES_ENABLE=$(sanitize_words "$SERVICES_ENABLE")
SERVICES_DISABLE=$(sanitize_words "$SERVICES_DISABLE")
TUNING=$TUNING
PACKAGES=$combined_packages
META

  printf '%s\n' $combined_packages >"$rootfs/packages/manifest.txt"
  printf '%s\n' $(sanitize_words "$SERVICES_ENABLE") >"$rootfs/packages/services.enable"
  printf '%s\n' $(sanitize_words "$SERVICES_DISABLE") >"$rootfs/packages/services.disable"

  if [[ -n "${POLICY_FILE:-}" ]]; then
    cp "$ROOT_DIR/$POLICY_FILE" "$rootfs/etc/prismos/edu.policy.json"
  fi

  if [[ -f "$TEMPLATES_DIR/grub.cfg" ]]; then
    sed \
      -e "s|{{DISPLAY_NAME}}|$DISPLAY_NAME|g" \
      -e "s|{{PROFILE_ID}}|$profile|g" \
      "$TEMPLATES_DIR/grub.cfg" >"$rootfs/boot/grub/grub.cfg"
  fi
}

build_artifact() {
  local rootfs="$1"
  local output_base="$2"
  local iso_path="${output_base}.iso"

  if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs \
      -o "$iso_path" \
      -V "PRISM_${PROFILE_ID^^}" \
      "$rootfs" >/dev/null 2>&1
    echo "$iso_path"
  else
    local tar_path="${iso_path}.tar.gz"
    tar -czf "$tar_path" -C "$(dirname "$rootfs")" "$(basename "$rootfs")"
    warn "xorriso non disponibile, creato fallback: $tar_path"
    echo "$tar_path"
  fi
}

generate_release_manifest() {
  local release_dir="$1"
  python3 - "$release_dir" <<'PY'
import hashlib, json, pathlib, sys
release = pathlib.Path(sys.argv[1])
artifacts = []
for path in sorted(release.glob("*")):
    if path.name == "manifest.json" or path.suffix == ".sha256":
        continue
    if not path.is_file():
        continue
    data = path.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    artifacts.append({"name": path.name, "sha256": sha, "size_bytes": len(data)})
    (release / f"{path.name}.sha256").write_text(f"{sha}  {path.name}\n", encoding="utf-8")
(release / "manifest.json").write_text(json.dumps({"artifacts": artifacts}, indent=2), encoding="utf-8")
print(f"Manifest scritto in {release/'manifest.json'}")
PY
}

build_profile() {
  local profile="$1"
  require_profile "$profile"
  load_profile "$profile"

  local release_tag="${RELEASE_NAME:-$STAMP}"
  local release_dir="$OUTPUT_DIR/$release_tag"
  local workdir="$release_dir/.work/${profile}"
  local rootfs="$workdir/iso-root"

  mkdir -p "$rootfs"
  setup_tree "$rootfs"
  copy_overlays "$profile" "$rootfs"
  render_metadata "$rootfs" "$profile" "$release_tag"

  local base_name="${DISTRO_NAME}-${profile}-${release_tag}"
  local artifact
  artifact="$(build_artifact "$rootfs" "$release_dir/$base_name")"
  log "Artefatto creato: $artifact"
}

parse_args() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  TARGET="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        RELEASE_NAME="$2"; shift 2 ;;
      --clean)
        CLEAN=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        err "Argomento sconosciuto: $1"; usage; exit 1 ;;
    esac
  done
}

main() {
  parse_args "$@"
  local release_tag="${RELEASE_NAME:-$STAMP}"
  local release_dir="$OUTPUT_DIR/$release_tag"

  [[ $CLEAN -eq 1 ]] && rm -rf "$release_dir"
  mkdir -p "$release_dir"

  case "$TARGET" in
    work|games|edu|slim)
      build_profile "$TARGET"
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

  generate_release_manifest "$release_dir"
  log "Release pronta in: $release_dir"
}

main "$@"
