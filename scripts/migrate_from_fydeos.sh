#!/usr/bin/env bash
# =============================================================================
# migrate_from_fydeos.sh - Migrate user data from FydeOS to prismOS.
#
# Three operating modes:
#
#   --collect [DIR]     Run on the LIVE FydeOS machine (crosh -> shell, logged
#                       in as the user to migrate). Collects the user files and
#                       the safe Chrome profile items into a tar.gz bundle with
#                       a JSON manifest and SHA256SUMS.
#   --restore BUNDLE    Run on the LIVE prismOS machine after the first login
#                       (user vault mounted). Restores the bundle contents.
#   --offline MOUNT     Run from any Linux with the FydeOS stateful partition
#                       mounted read-only. Recovers whatever is NOT inside an
#                       encrypted cryptohome vault and reports the rest.
#
# What is collected/restored (whitelist, safe by default):
#   Downloads, Documents, Pictures, Music, Videos, Playfiles (Android files),
#   wallpapers, .face (avatar), Chrome profile: Bookmarks + Web Applications
#   (PWA metadata). With --chrome-deep also Preferences (restored ONLY with
#   an explicit --restore-chrome-prefs because it is machine-specific).
#
# What is NEVER collected: credentials (Login Data), cookies, keys, TPM-bound
# material. Those are encrypted with the FydeOS account key and cannot be
# decrypted on another machine: use Google sync (while FydeOS still runs) or
# export passwords explicitly from the browser before migrating.
#
# Device policies found on FydeOS are copied into the bundle under
# policies-reference/ for documentation only; they are never auto-restored
# (prismOS manages its own policies through set_edu_policy.sh).
#
# Requirements: bash 5+, coreutils, tar, gzip. python3 for the JSON manifest
# (a pure-bash fallback is used when python3 is absent).
# =============================================================================
set -euo pipefail

readonly PROG="migrate_from_fydeos"
readonly VERSION="1.0.0"

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=scripts/lib/prismos_common.sh
source "${SCRIPT_DIR}/lib/prismos_common.sh"

# --- Overridable roots (tests run the script against fake trees) --------------
# Live FydeOS user home as seen from the shell (symlink into the chronos vault)
FYN_HOME="${PRISMOS_FYN_HOME:-/home/user}"
# Live FydeOS chronos directory (offline/account discovery)
FYN_CHRONOS="${PRISMOS_FYN_CHRONOS:-/home/chronos}"
# FydeOS system root for policies and metadata
FYN_ROOT="${PRISMOS_FYN_ROOT:-/}"
# prismOS live user home for --restore
PXS_HOME="${PRISMOS_PXS_HOME:-/home/user}"

readonly USER_DIRS=(Downloads Documents Pictures Music Videos Playfiles)
readonly USER_EXTRA=(wallpapers .face)
readonly CHROME_PROFILE="Default"
readonly CHROME_SAFE_ITEMS=(Bookmarks "Web Applications")
readonly CHROME_DEEP_ITEMS=(Preferences)
readonly POLICY_DIRS=(etc/opt/chrome/policies/managed etc/chromium/policies/managed)

ARG_MODE=""
ARG_SOURCE=""
ARG_OUTPUT=""
ARG_TARGET=""
ARG_CHROME_DEEP=0
ARG_RESTORE_CHROME_PREFS=0
ARG_FORCE=0

usage() {
	cat >&2 <<USAGE
${PROG} ${VERSION} - Migrate user data from FydeOS to prismOS

Usage:
  ${PROG} --collect [--output DIR] [--chrome-deep]
  ${PROG} --restore BUNDLE.tar.gz [--target DIR] [--restore-chrome-prefs] [--force]
  ${PROG} --offline MOUNTPOINT [--output DIR]
  ${PROG} --list BUNDLE.tar.gz
  ${PROG} --help

Modes:
  --collect          Collect from the LIVE FydeOS session into a bundle
                     (default output: /tmp/prismos-migration)
  --restore BUNDLE   Restore a bundle on LIVE prismOS (default target: /home/user)
  --offline MOUNT    Recover non-encrypted data from a mounted FydeOS stateful
  --list BUNDLE      Show the bundle manifest without restoring

Options:
  --output DIR               Bundle output directory (collect/offline)
  --chrome-deep              Also collect Preferences (collect only)
  --restore-chrome-prefs     Also restore Preferences (restore only; risky,
                             machine-specific keys are kept as-is)
  --target DIR               Restore target home (default ${PXS_HOME})
  --force                    Restore even if the target file already exists
  --help                     This help

Environment overrides (testing):
  PRISMOS_FYN_HOME    live FydeOS user home   (default /home/user)
  PRISMOS_FYN_CHRONOS FydeOS chronos dir      (default /home/chronos)
  PRISMOS_FYN_ROOT    FydeOS system root      (default /)
  PRISMOS_PXS_HOME    live prismOS user home  (default /home/user)

Notes:
  * Run --collect inside crosh -> shell on FydeOS while logged in as the user
    to migrate (the cryptohome vault is mounted and readable only then).
  * Credentials/cookies are never collected: they are bound to the FydeOS
    account key. Export passwords from the browser before migrating or rely on
    Google sync.
USAGE
}

parse_args() {
	while (( $# )); do
		case "$1" in
			--collect)              ARG_MODE="collect"; shift ;;
			--restore)              ARG_MODE="restore"; ARG_SOURCE="${2:-}"; shift 2 ;;
			--offline)              ARG_MODE="offline"; ARG_SOURCE="${2:-}"; shift 2 ;;
			--list)                 ARG_MODE="list"; ARG_SOURCE="${2:-}"; shift 2 ;;
			--output)               ARG_OUTPUT="${2:-}"; shift 2 ;;
			--target)               ARG_TARGET="${2:-}"; shift 2 ;;
			--chrome-deep)          ARG_CHROME_DEEP=1; shift ;;
			--restore-chrome-prefs) ARG_RESTORE_CHROME_PREFS=1; shift ;;
			--force)                ARG_FORCE=1; shift ;;
			-h|--help)              usage; exit 0 ;;
			*)                      usage; die 1 "unknown option: $1" ;;
		esac
	done
	[[ -n "${ARG_MODE}" ]] || { usage; die 1 "no mode specified (--collect/--restore/--offline/--list)"; }
	ARG_OUTPUT="${ARG_OUTPUT:-/tmp/prismos-migration}"
	ARG_TARGET="${ARG_TARGET:-${PXS_HOME}}"
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
collect_home_root() {
	# Resolve the real home: --target/PRISMOS override, live /home/user symlink,
	# or the first chronos user vault (offline mode).
	local candidate
	for candidate in "${FYN_HOME}" "${ARG_SOURCE}/home/user"; do
		if [[ -d "${candidate}" ]]; then
			printf '%s\n' "${candidate}"
			return 0
		fi
	done
	for candidate in "${FYN_CHRONOS}"/u-* "${ARG_SOURCE}/home/chronos"/u-*; do
		if [[ -d "${candidate}" ]]; then
			printf '%s\n' "${candidate}"
			return 0
		fi
	done
	return 1
}

chrome_profile_dir() {
	local home="$1" candidate
	for candidate in "${home}/${CHROME_PROFILE}" "${home}/.config/google-chrome/${CHROME_PROFILE}"; do
		[[ -d "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
	done
	return 1
}

copy_tree() {
	# copy_tree SRC DST [mode] - tolerant copy keeping permissions/times.
	local src="$1" dst="$2" mode="${3:-0644}"
	[[ -e "${src}" ]] || return 0
	if [[ -d "${src}" ]]; then
		mkdir -p "${dst}" || return 1
		cp -a "${src}/." "${dst}/" || return 1
	else
		mkdir -p "$(dirname "${dst}")" || return 1
		if [[ -f "${dst}" && ${ARG_FORCE} -eq 0 ]]; then
			log_warn "skipped (exists, use --force): ${dst}"
			return 0
		fi
		install -m "${mode}" "${src}" "${dst}" || return 1
	fi
	log_ok "copied: ${src#"$HOME_BASE/"} -> ${dst#"$STAGE_BASE/"}"
}

build_manifest() {
	# build_manifest STAGE_DIR MANIFEST_FILE
	local stage="$1" manifest="$2"
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$stage" "$manifest" <<'PY'
import hashlib, json, os, sys, time

stage, manifest = sys.argv[1], sys.argv[2]
entries = []
total = 0
for root, dirs, files in os.walk(stage):
    dirs.sort()
    for name in sorted(files):
        path = os.path.join(root, name)
        rel = os.path.relpath(path, stage)
        try:
            st = os.lstat(path)
        except OSError:
            continue
        sha = ""
        if os.path.isfile(path):
            h = hashlib.sha256()
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            sha = h.hexdigest()
        entries.append({"path": rel, "bytes": st.st_size, "sha256": sha})
        total += st.st_size
data = {
    "tool": "migrate_from_fydeos",
    "version": "1.0.0",
    "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "hostname": os.uname().nodename,
    "entries": len(entries),
    "total_bytes": total,
    "files": entries,
}
with open(manifest, "w") as f:
    json.dump(data, f, indent=1)
print("manifest: %d file, %.1f MiB" % (len(entries), total / 1048576.0))
PY
	else
		# Pure-bash fallback manifest (no hashes).
		local count=0 total=0 f
		: > "${manifest}.tmp"
		while IFS= read -r -d '' f; do
			local sz
			sz=$(stat -c %s "${f}" 2>/dev/null || echo 0)
			printf '%s\t%s\n' "${f#"${stage}/"}" "${sz}" >> "${manifest}.tmp"
			count=$((count + 1))
			total=$((total + sz))
		done < <(find "${stage}" -type f -print0 | sort -z)
		mv "${manifest}.tmp" "${manifest}"
		log_info "manifest bash: ${count} file, ${total} byte (python3 assente: nessun hash)"
	fi
}

# -----------------------------------------------------------------------------
# MODE: collect (live FydeOS)
# -----------------------------------------------------------------------------
mode_collect() {
	log_banner "${PROG}: collect (FydeOS live)" "output: ${ARG_OUTPUT}"

	local home profile stage bundle
	home="$(collect_home_root)" || die 1 "home FydeOS non trovata (${FYN_HOME} o ${FYN_CHRONOS}/u-*)"
	log_ok "home utente FydeOS: ${home}"
	HOME_BASE="${home}"

	mkdir -p "${ARG_OUTPUT}" || die 1 "impossibile creare ${ARG_OUTPUT}"
	stage="$(mktemp -d "${ARG_OUTPUT}/stage.XXXXXXXX")"
	STAGE_BASE="${stage}"

	# 1. Standard user directories.
	local d
	for d in "${USER_DIRS[@]}"; do
		copy_tree "${home}/${d}" "${stage}/home/${d}" || log_warn "directory non copiata: ${d}"
	done
	for d in "${USER_EXTRA[@]}"; do
		copy_tree "${home}/${d}" "${stage}/home/${d}" || true
	done

	# 2. Chrome profile: safe items (+ deep when requested).
	if profile="$(chrome_profile_dir "${home}")"; then
		log_ok "profilo Chrome: ${profile}"
		local item items=("${CHROME_SAFE_ITEMS[@]}")
		(( ARG_CHROME_DEEP )) && items+=("${CHROME_DEEP_ITEMS[@]}")
		for item in "${items[@]}"; do
			copy_tree "${profile}/${item}" "${stage}/chrome/${item}" || log_warn "item profilo non copiato: ${item}"
		done
	else
		log_warn "profilo Chrome (${CHROME_PROFILE}) non trovato: solo file utente nel bundle"
	fi

	# 3. Device policies on FydeOS (reference only).
	local pdir found_policy=0
	for pdir in "${POLICY_DIRS[@]}"; do
		if [[ -d "${FYN_ROOT}/${pdir}" ]] && compgen -G "${FYN_ROOT}/${pdir}/*.json" >/dev/null; then
			local label="${pdir//\//-}"; label="${label#etc-}"
			copy_tree "${FYN_ROOT}/${pdir}" "${stage}/policies-reference/${label}" || true
			found_policy=1
		fi
	done
	(( found_policy )) && log_info "policy FydeOS copiate in policies-reference/ (solo documentazione)" \
	                   || log_warn "nessuna policy locale trovata su FydeOS"

	# 4. Notes file for the operator.
	cat > "${stage}/MIGRATION-NOTES.txt" <<NOTES
prismOS migration bundle - created by ${PROG} ${VERSION}

Restored with:  migrate_from_fydeos.sh --restore <bundle>
Credentials, cookies and TPM-bound data are NOT in this bundle by design.
Before wiping FydeOS make sure to:
  1. export passwords from the browser (Settings -> Autofill -> Passwords),
  2. note the Google account used (Chrome sync will re-download the rest),
  3. check policies-reference/ for any school/work policy to re-apply on
     prismOS with scripts/set_edu_policy.sh.
NOTES

	# 5. Manifest + bundle.
	build_manifest "${stage}" "${stage}/manifest.json"
	bundle="${ARG_OUTPUT}/prismos-migration-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
	tar -C "${stage}" -czf "${bundle}" . || die 1 "creazione bundle fallita"
	( cd "${stage}" && find . -type f -exec sha256sum {} + > "${bundle}.SHA256SUMS" 2>/dev/null ) || true
	rm -rf "${stage}"

	log_ok "bundle creato: ${bundle}"
	log_info "copia il bundle su una chiavetta USB, poi su prismOS:"
	log_info "  scripts/migrate_from_fydeos.sh --restore /media/<usb>/$(basename "${bundle}")"
}

# -----------------------------------------------------------------------------
# MODE: restore (live prismOS)
# -----------------------------------------------------------------------------
mode_restore() {
	[[ -f "${ARG_SOURCE}" ]] || die 1 "bundle inesistente: ${ARG_SOURCE}"
	log_banner "${PROG}: restore (prismOS live)" "bundle: ${ARG_SOURCE}" "target: ${ARG_TARGET}"

	[[ -d "${ARG_TARGET}" ]] || die 1 "target inesistente: ${ARG_TARGET} (esegui il restore dopo il primo login)"

	local stage
	stage="$(mktemp -d /tmp/prismos-restore.XXXXXXXX)"
	tar -C "${stage}" -xzf "${ARG_SOURCE}" || { rm -rf "${stage}"; die 1 "estrazione bundle fallita"; }
	STAGE_BASE="${stage}"
	HOME_BASE="${ARG_TARGET}"

	# Integrity (optional SHA256SUMS).
	if [[ -f "${ARG_SOURCE}.SHA256SUMS" ]]; then
		( cd "${stage}" && sha256sum -c "${ARG_SOURCE}.SHA256SUMS" --quiet ) \
			&& log_ok "integrita' verificata (SHA256SUMS)" \
			|| log_warn "verifica SHA256SUMS fallita: bundle danneggiato?"
	fi

	# 1. User directories.
	local d
	for d in "${USER_DIRS[@]}" "${USER_EXTRA[@]}"; do
		[[ -e "${stage}/home/${d}" ]] && copy_tree "${stage}/home/${d}" "${ARG_TARGET}/${d}" || true
	done

	# 2. Chrome profile items.
	local profile item
	if profile="$(chrome_profile_dir "${ARG_TARGET}")"; then
		for item in "${CHROME_SAFE_ITEMS[@]}"; do
			[[ -e "${stage}/chrome/${item}" ]] && copy_tree "${stage}/chrome/${item}" "${profile}/${item}" || true
		done
		if (( ARG_RESTORE_CHROME_PREFS )); then
			for item in "${CHROME_DEEP_ITEMS[@]}"; do
				[[ -e "${stage}/chrome/${item}" ]] && \
					copy_tree "${stage}/chrome/${item}" "${profile}/${item}" || true
			done
			log_warn "Preferences ripristinate: riavvia la sessione e verifica chrome://settings"
		else
			[[ -e "${stage}/chrome/Preferences" ]] && \
				log_info "Preferences nel bundle non ripristinate (usa --restore-chrome-prefs)"
		fi
	else
		log_warn "profilo Chrome prismOS non ancora creato: esegui il primo login, poi rilancia il restore"
	fi

	# 3. Report.
	[[ -f "${stage}/MIGRATION-NOTES.txt" ]] && sed -n '1,20p' "${stage}/MIGRATION-NOTES.txt" >&2
	if [[ -d "${stage}/policies-reference" ]]; then
		log_info "policy FydeOS di riferimento in: ${stage}/policies-reference (bundle)"
	fi
	rm -rf "${stage}"
	log_ok "restore completato verso ${ARG_TARGET}"
}

# -----------------------------------------------------------------------------
# MODE: offline (mounted stateful)
# -----------------------------------------------------------------------------
mode_offline() {
	[[ -d "${ARG_SOURCE}" ]] || die 1 "mountpoint inesistente: ${ARG_SOURCE}"
	log_banner "${PROG}: offline" "mount: ${ARG_SOURCE}" "output: ${ARG_OUTPUT}"

	local home stage bundle vault_count=0
	HOME_BASE="${ARG_SOURCE}"
	mkdir -p "${ARG_OUTPUT}" || die 1 "impossibile creare ${ARG_OUTPUT}"
	stage="$(mktemp -d "${ARG_OUTPUT}/stage.XXXXXXXX")"
	STAGE_BASE="${stage}"

	if home="$(collect_home_root)"; then
		log_ok "home trovata: ${home}"
		local d
		for d in "${USER_DIRS[@]}" "${USER_EXTRA[@]}"; do
			copy_tree "${home}/${d}" "${stage}/home/${d}" || true
		done
		local profile item
		if profile="$(chrome_profile_dir "${home}")"; then
			for item in "${CHROME_SAFE_ITEMS[@]}" "${CHROME_DEEP_ITEMS[@]}"; do
				copy_tree "${profile}/${item}" "${stage}/chrome/${item}" || true
			done
		fi
	else
		log_warn "nessuna home utente leggibile nel mountpoint"
	fi

	# Report cryptohome vaults (encrypted, not recoverable offline).
	local v
	for v in "${ARG_SOURCE}"/home/chronos/u-* "${ARG_SOURCE}"/home/.shadow/u-*; do
		[[ -d "${v}" ]] && vault_count=$((vault_count + 1))
	done
	if (( vault_count )); then
		cat > "${stage}/OFFLINE-WARNING.txt" <<WARN
${vault_count} cryptohome vault(s) found on the stateful partition.
Vault contents are ENCRYPTED with the account key and cannot be recovered
offline. To migrate them: boot FydeOS, log in as the user and run
  migrate_from_fydeos.sh --collect
from the live session instead.
WARN
		log_warn "${vault_count} vault cryptohome rilevati: contenuti cifrati NON recuperabili offline"
	fi

	build_manifest "${stage}" "${stage}/manifest.json"
	bundle="${ARG_OUTPUT}/prismos-migration-offline-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
	tar -C "${stage}" -czf "${bundle}" . || die 1 "creazione bundle fallita"
	rm -rf "${stage}"
	log_ok "bundle offline creato: ${bundle}"
}

# -----------------------------------------------------------------------------
# MODE: list
# -----------------------------------------------------------------------------
mode_list() {
	[[ -f "${ARG_SOURCE}" ]] || die 1 "bundle inesistente: ${ARG_SOURCE}"
	log_banner "${PROG}: list" "bundle: ${ARG_SOURCE}"
	local stage
	stage="$(mktemp -d /tmp/prismos-list.XXXXXXXX)"
	tar -C "${stage}" -xzf "${ARG_SOURCE}" manifest.json MIGRATION-NOTES.txt OFFLINE-WARNING.txt 2>/dev/null || \
		tar -C "${stage}" -xzf "${ARG_SOURCE}" || die 1 "lettura bundle fallita"
	if [[ -f "${stage}/manifest.json" ]] && command -v python3 >/dev/null 2>&1; then
		python3 - "${stage}/manifest.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print("created : %s" % data.get("created_utc", "?"))
print("host    : %s" % data.get("hostname", "?"))
print("files   : %d (%.1f MiB)" % (data.get("entries", 0), data.get("total_bytes", 0) / 1048576.0))
for e in data.get("files", [])[:40]:
    print("  %-60s %10d" % (e["path"], e["bytes"]))
if data.get("entries", 0) > 40:
    print("  ... (%d altri)" % (data["entries"] - 40))
PY
	else
		tar -tzf "${ARG_SOURCE}" | head -50
	fi
	for f in MIGRATION-NOTES.txt OFFLINE-WARNING.txt; do
		[[ -f "${stage}/${f}" ]] && { printf '\n--- %s ---\n' "${f}" >&2; cat "${stage}/${f}" >&2; }
	done
	rm -rf "${stage}"
}

# -----------------------------------------------------------------------------
main() {
	parse_args "$@"
	case "${ARG_MODE}" in
		collect) mode_collect ;;
		restore) mode_restore ;;
		offline) mode_offline ;;
		list)    mode_list ;;
		*)       usage; die 1 "mode sconosciuta: ${ARG_MODE}" ;;
	esac
	exit 0
}

main "$@"
