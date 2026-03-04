#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="$ROOT_DIR/profiles"
BUILD_DIR="$ROOT_DIR/build"
ROOTFS_BASE="$BUILD_DIR/rootfs"
ARTIFACTS_DIR="$BUILD_DIR/artifacts"

ARCH="amd64"
SUITE="bookworm"
MIRROR="http://deb.debian.org/debian"
DRY_RUN=0

usage() {
  cat <<USAGE
Uso:
  $(basename "$0") <work|games|edu|slim|all> [--suite bookworm] [--arch amd64] [--mirror URL] [--dry-run]

Descrizione:
  Crea il sistema operativo vero e proprio (root filesystem live) per i profili prismOS.
  Output in build/rootfs/<profile>/ e build/artifacts/<profile>/.
USAGE
}

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERRORE] $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Comando richiesto non trovato: $1"; return 1; }
}

load_profile() {
  local profile="$1"
  # shellcheck disable=SC1090
  source "$PROFILES_DIR/common.conf"
  # shellcheck disable=SC1090
  source "$PROFILES_DIR/$profile.conf"
}

bootstrap_rootfs() {
  local profile="$1"
  local rootfs="$ROOTFS_BASE/$profile"
  load_profile "$profile"

  rm -rf "$rootfs"
  mkdir -p "$rootfs"

  local packages
  packages="$(xargs <<<"$BASE_PACKAGES $PACKAGES")"

  if command -v mmdebstrap >/dev/null 2>&1; then
    log "Bootstrap rootfs con mmdebstrap ($profile)"
    mmdebstrap --architectures="$ARCH" --include="$packages" "$SUITE" "$rootfs" "$MIRROR"
  else
    need_cmd debootstrap
    log "Bootstrap rootfs con debootstrap ($profile)"
    debootstrap --arch="$ARCH" "$SUITE" "$rootfs" "$MIRROR"
    cp /etc/resolv.conf "$rootfs/etc/resolv.conf"
    chroot "$rootfs" apt-get update
    chroot "$rootfs" apt-get install -y $packages
    chroot "$rootfs" apt-get clean
  fi

  mkdir -p "$rootfs/etc/prismos" "$rootfs/etc/skel/.config/prismos"
  cp "$ROOT_DIR/overlays/common/etc/prismos-release" "$rootfs/etc/prismos/prismos-release"
  cp "$ROOT_DIR/overlays/common/etc/skel/.config/prismos/first-run.txt" "$rootfs/etc/skel/.config/prismos/first-run.txt"

  if [[ "${POLICY_FILE:-}" != "" ]]; then
    cp "$ROOT_DIR/$POLICY_FILE" "$rootfs/etc/prismos/edu.policy.json"
  fi

  cat > "$rootfs/etc/prismos/edition.env" <<META
PROFILE_ID=$PROFILE_ID
DISPLAY_NAME=$DISPLAY_NAME
BASE_DESKTOP=$BASE_DESKTOP
DISPLAY_MANAGER=${DISPLAY_MANAGER:-}
KERNEL_FLAVOR=$KERNEL_FLAVOR
TARGET_HARDWARE=$TARGET_HARDWARE
TUNING=$TUNING
META

  # configurazioni di base sistema live
  echo "prismos" > "$rootfs/etc/hostname"
  cat > "$rootfs/etc/hosts" <<HOSTS
127.0.0.1 localhost
127.0.1.1 prismos
HOSTS

  if [[ -d "$ROOT_DIR/overlays/$profile" ]]; then
    cp -a "$ROOT_DIR/overlays/$profile/." "$rootfs/"
  fi
}

pack_rootfs() {
  local profile="$1"
  local rootfs="$ROOTFS_BASE/$profile"
  local out="$ARTIFACTS_DIR/$profile"
  mkdir -p "$out"

  if command -v mksquashfs >/dev/null 2>&1; then
    mksquashfs "$rootfs" "$out/filesystem.squashfs" -noappend >/dev/null
    log "Creato filesystem.squashfs per $profile"
  else
    tar -czf "$out/filesystem.tar.gz" -C "$rootfs" .
    warn "mksquashfs non trovato, fallback filesystem.tar.gz"
  fi

  tar -czf "$out/rootfs.tar.gz" -C "$rootfs" .
  sha256sum "$out"/* > "$out/SHA256SUMS"
}

build_one() {
  local profile="$1"
  [[ -f "$PROFILES_DIR/$profile.conf" ]] || { err "Profilo sconosciuto: $profile"; exit 1; }

  if [[ $DRY_RUN -eq 1 ]]; then
    load_profile "$profile"
    log "[dry-run] build rootfs $profile"
    log "[dry-run] pacchetti: $(xargs <<<"$BASE_PACKAGES $PACKAGES")"
    return
  fi

  bootstrap_rootfs "$profile"
  pack_rootfs "$profile"
  log "Sistema operativo creato per $profile in $ROOTFS_BASE/$profile"
}

main() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  local target="$1"; shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --suite) SUITE="$2"; shift 2 ;;
      --arch) ARCH="$2"; shift 2 ;;
      --mirror) MIRROR="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) err "Argomento sconosciuto: $1"; usage; exit 1 ;;
    esac
  done

  mkdir -p "$ROOTFS_BASE" "$ARTIFACTS_DIR"

  case "$target" in
    work|games|edu|slim) build_one "$target" ;;
    all)
      for p in work games edu slim; do
        build_one "$p"
      done
      ;;
    *) err "Target non valido: $target"; usage; exit 1 ;;
  esac
}

main "$@"
