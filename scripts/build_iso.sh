#!/usr/bin/env bash
# =============================================================================
#  prismOS :: scripts/build_iso.sh
# -----------------------------------------------------------------------------
#  Costruzione interattiva delle immagini prismOS Legacy nell'ambiente chroot di
#  cros_sdk (ChromiumOS). Genera una delle quattro edizioni - oppure tutte - a
#  partire dal board amd64-prismos, con floor ISA SSE4.1 (CPU senza SSE4.2, es.
#  Intel Pentium P6100 / Arrandale).
#
#  FASI
#    1. validazione dell'ambiente (python3, git, cros_sdk, spazio su disco)
#    2. caricamento del profilo di edizione (profiles/<edizione>.conf)
#    3. selezione interattiva delle applicazioni da profiles/app_pool.json
#    4. generazione di /etc/skel/.config/chromiumos/shelf.json (Dock centrata)
#    5. generazione di /etc/prismos/edition.conf (stato dei sottosistemi)
#    6. sincronizzazione degli overlay nel cros_sdk (link simbolici)
#    7. setup_board --board=amd64-prismos
#    8. build_packages --board=amd64-prismos
#    9. build_image --board=amd64-prismos dev
#   10. raccolta in output/prismOS_<edizione>_legacy.img
#
#  USO
#    ./scripts/build_iso.sh <edu|home|work|slim|all> [opzioni]
#
#  ESEMPI
#    ./scripts/build_iso.sh slim                     # interattivo
#    ./scripts/build_iso.sh edu --apps 1,3,5         # selezione non interattiva
#    ./scripts/build_iso.sh home --bundle            # usa il bundle di edizione
#    ./scripts/build_iso.sh all --bundle --jobs 8    # tutte le edizioni
#    ./scripts/build_iso.sh work --dry-run           # solo preparazione
# =============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit extglob nullglob

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
# shellcheck source=scripts/lib/prismos_common.sh
source "$(dirname "${SCRIPT_PATH}")/lib/prismos_common.sh"
prismos_install_error_trap

readonly PROG="$(basename "${SCRIPT_PATH}")"
readonly PROG_VERSION="2.0.0"

# --- variabili globali ------------------------------------------------------------
ARG_EDITION=""
ARG_SDK_DIR=""
ARG_BOARD="${PRISMOS_DEFAULT_BOARD}"
ARG_JOBS=""
ARG_APPS=""
ARG_USE_BUNDLE=0
ARG_DRY_RUN=0
ARG_NO_SYNC=0
ARG_KEEP_BUILD=0
ARG_COPY_OVERLAYS=0
ARG_IMAGE_TYPE="dev"
ARG_REPO_MOUNT="/mnt/host/source/src/overlays/prismOS"
ARG_POLICY_MODE=""
ARG_SKIP_VERIFY=0
ARG_SYNC_ONLY=0
ARG_QUIET=0

EDITION=""
EDITION_NAME=""
BUILD_STAMP=""
SDK_DIR=""
SDK_SRC=""
BOARD_OVERLAY_DIR=""
STAGING_DIR=""
SELECTED_APP_IDS=()
PROFILE_VARS=()

# --- profilo di edizione (valori di default, sovrascritti da profiles/<ed>.conf) -----
PROFILE_ID=""
DISPLAY_NAME=""
EDITION_TAGLINE=""
BOARD="amd64-prismos"
KERNEL_SPLITCONFIG="chromiumos-x86_64/prismos_legacy"
KERNEL_VERSION="6.1"
IMAGE_TYPE="dev"
WAYDROID_BOOT_STATE="on-demand"
WINE_BOOT_STATE="on-demand"
SUBSYSTEM_IDLE_TIMEOUT="300"
SUBSYSTEM_MAX_INSTANCES="1"
SUBSYSTEM_TEARDOWN="graceful"
SUBSYSTEM_TEARDOWN_GRACE_SEC="15"
SHELF_ALIGNMENT="Bottom"
SHELF_AUTOHIDE="Always"
SHELF_CENTERED="true"
SHELF_ICON_SIZE="48"
SHELF_SQUIRCLE_RADIUS="0.28"
SHELF_SQUIRCLE_EXPONENT="5.0"
SHELF_PIN_MAX="8"
SHELF_LAUNCHER_ACCELERATOR="super+space"
SHELF_WEB_SEARCH_ACCELERATOR="super+shift+space"
SHELF_ANIMATIONS="1"
SHELF_BACKGROUND_BLUR="1"
SHELF_BACKGROUND_OPACITY="0.86"
SHELF_ANIMATION_DURATION_MS="180"
SHELF_MAX_VISIBLE_WINDOWS="8"
POLICY_SOURCE=""
POLICY_TARGET=""
POLICY_MODE="none"
EDU_DOMAIN="scuola.edu"
ENCRYPTED_DOWNLOADS="0"
EXTRA_PACKAGES=""
REMOVED_PACKAGES=""
MIN_RAM_MB="1024"
TARGET_CPU="Intel Pentium P6100 (Arrandale, SSE4.1)"
ROOTFS_FILES=""

# I profili di edizione e i make.conf di Portage fanno riferimento a variabili
# non necessariamente definite (USE, CFLAGS, ...): il sourcing avviene quindi con
# `nounset` temporaneamente disattivato.
source_profile_file() {
	local file="$1"
	[[ -f "${file}" ]] || return 0
	set +u
	# shellcheck disable=SC1090
	source "${file}"
	set -u
	return 0
}

usage() {
	cat <<USAGE
${PRISMOS_C_BOLD}prismOS ${PROG_VERSION} - costruzione immagini ChromiumOS Legacy${PRISMOS_C_RESET}

USO
  ${PROG} <edu|home|work|slim|all> [opzioni]

ARGOMENTO OBBLIGATORIO
  edu            prismOS EDU   (Cloud-Managed / Local-Policy per istituti)
  home           prismOS Home  (streaming, multimedia, gaming leggero)
  work           prismOS Work  (Microsoft 365, VPN avanzata, Download cifrati)
  slim           prismOS Slim  (<2 GB RAM, sottosistemi on-demand)
  all            costruisce in sequenza edu, home, work e slim

OPZIONI
  --sdk-dir DIR        percorso del cros_sdk (default: \${CROS_SDK_DIR} oppure
                       ${PRISMOS_DEFAULT_SDK})
  --board NOME         board ChromiumOS (default: ${PRISMOS_DEFAULT_BOARD})
  --repo-mount PATH    percorso della repository visto da DENTRO il chroot
                       (default: ${ARG_REPO_MOUNT})
  --jobs N             parallelismo di build_packages (default: nproc)
  --apps LISTA         selezione non interattiva delle app: "1,3,5", "2-7", "all"
  --bundle             usa il bundle predefinito dell'edizione (nessun prompt)
  --image-type TIPO    dev | base | test (default: dev)
  --policy-mode MODO   EDU: local (Strada B, policy JSON di dispositivo) oppure
                       cloud (Strada A, solo flag di Enterprise Enrollment);
                       WORK: local | none. Default: quanto dichiara il profilo.
  --copy-overlays      copia gli overlay invece di creare link simbolici
  --no-sync            salta la sincronizzazione degli overlay nel cros_sdk
  --sync-only          genera gli artefatti e sincronizza gli overlay nel
                       cros_sdk, poi si ferma (nessuna compilazione); e' la
                       modalita' usata da scripts/sync_overlays.sh
  --skip-verify        salta la verifica ISA/JSON finale
  --keep-build         non rimuove la staging directory a fine build
  --dry-run            prepara tutto (shelf.json, edition.conf, overlay) ma non
                       esegue setup_board/build_packages/build_image
  --verbose            log di debug
  -h, --help           questo messaggio
  -V, --version        versione

FILE GENERATI
  build/<edizione>/etc/skel/.config/chromiumos/shelf.json   Dock centrata
  build/<edizione>/etc/prismos/edition.conf                 stato sottosistemi
  build/<edizione>/make.conf                                overlay concatenati
  output/prismOS_<edizione>_legacy.img                      immagine finale

ESEMPI
  ${PROG} slim
  ${PROG} edu --apps 1,3,5 --sdk-dir ~/chromiumos/cros_sdk
  ${PROG} home --bundle --jobs 8
  ${PROG} all --bundle --dry-run
USAGE
}

# =============================================================================
# ARGOMENTI
# =============================================================================
parse_args() {
	while (( $# > 0 )); do
		case "$1" in
			edu|home|work|slim|all)
				if [[ -n "${ARG_EDITION}" ]]; then
					die 1 "edizione gia' specificata (${ARG_EDITION}); argomento duplicato: $1"
				fi
				ARG_EDITION="$1"; shift ;;
			--sdk-dir)        ARG_SDK_DIR="${2:-}"; shift 2 ;;
			--sdk-dir=*)      ARG_SDK_DIR="${1#*=}"; shift ;;
			--board)          ARG_BOARD="${2:-}"; shift 2 ;;
			--board=*)        ARG_BOARD="${1#*=}"; shift ;;
			--repo-mount)     ARG_REPO_MOUNT="${2:-}"; shift 2 ;;
			--repo-mount=*)   ARG_REPO_MOUNT="${1#*=}"; shift ;;
			--jobs)           ARG_JOBS="${2:-}"; shift 2 ;;
			--jobs=*)         ARG_JOBS="${1#*=}"; shift ;;
			--apps)           ARG_APPS="${2:-}"; shift 2 ;;
			--apps=*)         ARG_APPS="${1#*=}"; shift ;;
			--image-type)     ARG_IMAGE_TYPE="${2:-}"; shift 2 ;;
			--image-type=*)   ARG_IMAGE_TYPE="${1#*=}"; shift ;;
			--policy-mode)    ARG_POLICY_MODE="${2:-}"; shift 2 ;;
			--policy-mode=*)  ARG_POLICY_MODE="${1#*=}"; shift ;;
			--bundle)         ARG_USE_BUNDLE=1; shift ;;
			--copy-overlays)  ARG_COPY_OVERLAYS=1; shift ;;
			--no-sync)        ARG_NO_SYNC=1; shift ;;
			--skip-verify)    ARG_SKIP_VERIFY=1; shift ;;
			--sync-only)      ARG_SYNC_ONLY=1; shift ;;
			--keep-build)     ARG_KEEP_BUILD=1; shift ;;
			--dry-run)        ARG_DRY_RUN=1; shift ;;
			--verbose)        PRISMOS_LOG_LEVEL="debug"; shift ;;
			--quiet|-q)       ARG_QUIET=1; PRISMOS_LOG_LEVEL="warn"; shift ;;
			-h|--help)        usage; exit 0 ;;
			-V|--version)     echo "${PROG} ${PROG_VERSION}"; exit 0 ;;
			--)               shift; break ;;
			-*)               usage >&2; die 1 "opzione sconosciuta: $1" ;;
			*)                usage >&2; die 1 "argomento inatteso: $1 (attesa una edizione)" ;;
		esac
	done

	if [[ -z "${ARG_EDITION}" ]]; then
		usage >&2
		die 1 "argomento obbligatorio mancante: indicare una fra edu, home, work, slim, all"
	fi

	case "${ARG_IMAGE_TYPE}" in
		dev|base|test) ;;
		*) die 1 "--image-type accetta solo dev, base o test (ricevuto: ${ARG_IMAGE_TYPE})" ;;
	esac

	if [[ -n "${ARG_JOBS}" ]] && ! [[ "${ARG_JOBS}" =~ ^[0-9]+$ ]]; then
		die 1 "--jobs richiede un intero positivo (ricevuto: ${ARG_JOBS})"
	fi
	if [[ -n "${ARG_APPS}" && ${ARG_USE_BUNDLE} -eq 1 ]]; then
		die 1 "--apps e --bundle sono mutuamente esclusivi"
	fi
	if [[ -n "${ARG_POLICY_MODE}" ]]; then
		case "${ARG_POLICY_MODE}" in
			local|cloud|none) ;;
			*) die 1 "--policy-mode accetta solo local, cloud o none (ricevuto: ${ARG_POLICY_MODE})" ;;
		esac
	fi
}

# =============================================================================
# AMBIENTE
# =============================================================================
validate_environment() {
	log_step "Validazione dell'ambiente di build"

	require_cmds python3 awk sed sort grep find date

	if ! have_cmd git; then
		log_warn "git non presente: il fingerprint di build non includera' la revisione"
	fi

	PRISMOS_SDK_RESOLVED=""
	if ! prismos_in_chroot; then
		if ! PRISMOS_SDK_RESOLVED="$(prismos_resolve_sdk "${ARG_SDK_DIR}")"; then
			log_warn "cros_sdk non trovato in '${ARG_SDK_DIR:-${PRISMOS_DEFAULT_SDK}}'"
			log_warn "Le fasi di compilazione verranno saltate; la preparazione"
			log_warn "(shelf.json, edition.conf, staging overlay) sara' comunque eseguita."
			log_warn "Per compilare: ./scripts/build_iso.sh <edizione> --sdk-dir /percorso/cros_sdk"
			PRISMOS_SDK_RESOLVED=""
		else
			log_ok "cros_sdk rilevato: ${PRISMOS_SDK_RESOLVED}"
		fi
	else
		log_ok "esecuzione dentro il chroot di cros_sdk"
		PRISMOS_SDK_RESOLVED="/mnt/host/source"
	fi
	export PRISMOS_SDK_RESOLVED

	if [[ -f "${PRISMOS_APP_POOL}" ]]; then
		json_validate_pool || die 1 "profiles/app_pool.json non valido"
		log_ok "pool applicazioni valido: $(json_app_count) voci totali"
	else
		die 1 "pool applicazioni mancante: ${PRISMOS_APP_POOL}"
	fi

	# Spazio su disco: una build ChromiumOS completa richiede ~150 GB.
	local avail_kb avail_gb
	avail_kb="$(df -Pk "${PRISMOS_ROOT}" 2>/dev/null | awk 'NR==2 { print $4 }')"
	if [[ -n "${avail_kb}" ]]; then
		avail_gb=$(( avail_kb / 1024 / 1024 ))
		if (( avail_gb < 20 )); then
			log_warn "spazio disponibile ridotto: ${avail_gb} GiB (ne servono >= 150 per una build completa)"
		else
			log_ok "spazio disponibile: ${avail_gb} GiB"
		fi
	fi

	log_info "host: $(prismos_host_summary)"
	log_info "repository: ${PRISMOS_ROOT} (rev $(prismos_git_revision))"
}

# =============================================================================
# PROFILO DI EDIZIONE
# =============================================================================
load_edition_profile() {
	local edition="$1"
	local profile_file="${PRISMOS_PROFILES_DIR}/${edition}.conf"

	log_step "Caricamento del profilo di edizione: ${edition}"

	if [[ ! -f "${profile_file}" ]]; then
		die 1 "profilo di edizione mancante: ${profile_file}"
	fi

	source_profile_file "${profile_file}"

	EDITION="${edition}"
	EDITION_NAME="${DISPLAY_NAME:-$(edition_display_name "${edition}")}"
	BOARD="${BOARD:-${ARG_BOARD}}"

	# I valori del make.conf dell'overlay di edizione hanno priorita' sul profilo.
	local overlay_conf="${PRISMOS_OVERLAYS_DIR}/overlay-prismos-${edition}/make.conf"
	if [[ -f "${overlay_conf}" ]]; then
		source_profile_file "${overlay_conf}"
		log_debug "make.conf di edizione caricato: ${overlay_conf}"
	else
		log_warn "make.conf di edizione assente: ${overlay_conf}"
	fi

	WAYDROID_BOOT_STATE="${PRISMOS_WAYDROID_BOOT_STATE:-${WAYDROID_BOOT_STATE}}"
	WINE_BOOT_STATE="${PRISMOS_WINE_BOOT_STATE:-${WINE_BOOT_STATE}}"
	SUBSYSTEM_IDLE_TIMEOUT="${PRISMOS_SUBSYSTEM_IDLE_TIMEOUT:-${SUBSYSTEM_IDLE_TIMEOUT}}"
	SUBSYSTEM_MAX_INSTANCES="${PRISMOS_SUBSYSTEM_MAX_INSTANCES:-${SUBSYSTEM_MAX_INSTANCES}}"
	SHELF_ALIGNMENT="${PRISMOS_SHELF_ALIGNMENT:-${SHELF_ALIGNMENT}}"
	SHELF_AUTOHIDE="${PRISMOS_SHELF_AUTOHIDE:-${SHELF_AUTOHIDE}}"
	SHELF_ICON_SIZE="${PRISMOS_SHELF_ICON_SIZE:-${SHELF_ICON_SIZE}}"
	SHELF_PIN_MAX="${PRISMOS_SHELF_PIN_MAX:-${SHELF_PIN_MAX}}"
	if [[ -n "${PRISMOS_SHELF_SQUIRCLE_RADIUS:-}" ]]; then
		SHELF_SQUIRCLE_RADIUS="${PRISMOS_SHELF_SQUIRCLE_RADIUS}"
	fi
	SUBSYSTEM_TEARDOWN="${PRISMOS_SUBSYSTEM_TEARDOWN:-${SUBSYSTEM_TEARDOWN}}"
	SUBSYSTEM_TEARDOWN_GRACE_SEC="${PRISMOS_SUBSYSTEM_TEARDOWN_GRACE_SEC:-${SUBSYSTEM_TEARDOWN_GRACE_SEC}}"
	SHELF_WEB_SEARCH_ACCELERATOR="${PRISMOS_SHELF_WEB_SEARCH_ACCELERATOR:-${SHELF_WEB_SEARCH_ACCELERATOR}}"
	SHELF_ANIMATIONS="${PRISMOS_SHELF_ANIMATIONS:-${SHELF_ANIMATIONS}}"
	SHELF_BACKGROUND_BLUR="${PRISMOS_SHELF_BACKGROUND_BLUR:-${SHELF_BACKGROUND_BLUR}}"
	SHELF_BACKGROUND_OPACITY="${PRISMOS_SHELF_BACKGROUND_OPACITY:-${SHELF_BACKGROUND_OPACITY}}"
	SHELF_MAX_VISIBLE_WINDOWS="${PRISMOS_SHELF_MAX_VISIBLE_WINDOWS:-${SHELF_MAX_VISIBLE_WINDOWS}}"
	SHELF_ANIMATION_DURATION_MS="${PRISMOS_SHELF_ANIMATION_DURATION_MS:-${SHELF_ANIMATION_DURATION_MS}}"
	POLICY_SOURCE="${PRISMOS_POLICY_SOURCE:-${POLICY_SOURCE}}"
	POLICY_TARGET="${PRISMOS_POLICY_TARGET:-${POLICY_TARGET}}"
	ROOTFS_FILES="${PRISMOS_ROOTFS_FILES:-${ROOTFS_FILES}}"
	EXTRA_PACKAGES="${PRISMOS_EXTRA_PACKAGES:-${EXTRA_PACKAGES}}"
	REMOVED_PACKAGES="${PRISMOS_REMOVED_PACKAGES:-${REMOVED_PACKAGES}}"
	ENCRYPTED_DOWNLOADS="${PRISMOS_ENCRYPTED_DOWNLOADS:-${ENCRYPTED_DOWNLOADS}}"
	IMAGE_TYPE="${PRISMOS_IMAGE_TYPE:-${ARG_IMAGE_TYPE}}"
	MIN_RAM_MB="${PRISMOS_MIN_RAM_MB:-${MIN_RAM_MB}}"

	if [[ -n "${ARG_POLICY_MODE}" ]]; then
		POLICY_MODE="${ARG_POLICY_MODE}"
		log_info "modalita' policy forzata da riga di comando: ${POLICY_MODE}"
	fi

	log_ok "edizione   : ${EDITION_NAME} (${EDITION})"
	log_info "board      : ${BOARD}"
	log_info "kernel     : ${KERNEL_VERSION} splitconfig ${KERNEL_SPLITCONFIG}"
	log_info "immagine   : tipo ${IMAGE_TYPE}, RAM minima ${MIN_RAM_MB} MiB"
	log_info "Waydroid   : ${WAYDROID_BOOT_STATE}"
	log_info "Wine       : ${WINE_BOOT_STATE}"
	log_info "Dock       : ${SHELF_ALIGNMENT}, autohide ${SHELF_AUTOHIDE}, max ${SHELF_PIN_MAX} pin"
}

# =============================================================================
# SELEZIONE DELLE APPLICAZIONI
# =============================================================================
declare -a APP_TABLE_IDS=()
declare -a APP_TABLE_NAMES=()
declare -a APP_TABLE_TYPES=()
declare -a APP_TABLE_URLS=()
declare -a APP_TABLE_ICONS=()
declare -a APP_TABLE_PRE=()

load_app_table() {
	local edition="$1"
	local line
	APP_TABLE_IDS=(); APP_TABLE_NAMES=(); APP_TABLE_TYPES=()
	APP_TABLE_URLS=(); APP_TABLE_ICONS=(); APP_TABLE_PRE=()

	while IFS= read -r line; do
		[[ -n "${line}" ]] || continue
		IFS=$'\t' read -r _idx id name type url icon pre <<< "${line}"
		APP_TABLE_IDS+=("${id}")
		APP_TABLE_NAMES+=("${name}")
		APP_TABLE_TYPES+=("${type}")
		APP_TABLE_URLS+=("${url}")
		APP_TABLE_ICONS+=("${icon}")
		APP_TABLE_PRE+=("${pre}")
	done < <(json_list_apps "${edition}")
}

print_app_menu() {
	local i total type_tag pre_tag
	total="${#APP_TABLE_IDS[@]}"
	if (( total == 0 )); then
		log_warn "nessuna applicazione disponibile per questa edizione"
		return 0
	fi

	printf '\n%s%s  APPLICAZIONI DISPONIBILI PER %s  (%d voci)%s\n' \
		"${PRISMOS_C_BOLD}" "${PRISMOS_C_BLUE}" "${EDITION_NAME^^}" "${total}" "${PRISMOS_C_RESET}" >&2
	printf '%s\n' "  -----------------------------------------------------------------------" >&2
	printf '  %s%-4s %-26s %-13s %-4s %s%s\n' \
		"${PRISMOS_C_BOLD}" "N." "APPLICAZIONE" "TIPO" "DEF." "" "${PRISMOS_C_RESET}" >&2
	printf '%s\n' "  -----------------------------------------------------------------------" >&2

	for (( i = 0; i < total; i++ )); do
		case "${APP_TABLE_TYPES[i]}" in
			Web_App)     type_tag="${PRISMOS_C_GREEN}Web_App${PRISMOS_C_RESET}      " ;;
			Android_Pkg) type_tag="${PRISMOS_C_YELLOW}Android_Pkg${PRISMOS_C_RESET}  " ;;
			Windows_Pkg) type_tag="${PRISMOS_C_MAGENTA}Windows_Pkg${PRISMOS_C_RESET}  " ;;
			*)           type_tag="${APP_TABLE_TYPES[i]}     " ;;
		esac
		if [[ "${APP_TABLE_PRE[i]}" == "1" ]]; then
			pre_tag="${PRISMOS_C_GREEN}*${PRISMOS_C_RESET}"
		else
			pre_tag=" "
		fi
		printf '  %-4s %-26s %b %-4s\n' \
			"$(( i + 1 ))." "${APP_TABLE_NAMES[i]}" "${type_tag}" "${pre_tag}" >&2
	done

	printf '%s\n' "  -----------------------------------------------------------------------" >&2
	printf '  %s*%s = selezionata di default dal bundle della edizione\n' \
		"${PRISMOS_C_GREEN}" "${PRISMOS_C_RESET}" >&2
	printf '  Web_App     -> PWA Chromium (nessun sottosistema)\n' >&2
	printf '  Android_Pkg -> Waydroid / LineageOS 16.0 x86 (no SSE4.2)\n' >&2
	printf '  Windows_Pkg -> Wine + Proton (wined3d su Intel HD Gen5)\n' >&2
	printf '\n' >&2
}

select_apps_interactive() {
	local total="${#APP_TABLE_IDS[@]}"
	if (( total == 0 )); then
		SELECTED_APP_IDS=()
		return 0
	fi

	local answer="" selection="" indices=()
	local default_selection=""
	local i
	for (( i = 0; i < total; i++ )); do
		if [[ "${APP_TABLE_PRE[i]}" == "1" ]]; then
			default_selection+="$(( i + 1 )),"
		fi
	done
	default_selection="${default_selection%,}"

	while :; do
		printf '%s' "" >&2
		read -r -p "$(printf '%bSeleziona le applicazioni da installare [es. 1,3,5 | 2-7 | all | none]%b\n(default: %s): ' "${PRISMOS_C_CYAN}" "${PRISMOS_C_RESET}" "${default_selection:-nessuna}")" answer || answer=""

		answer="${answer//[[:space:]]/}"
		if [[ -z "${answer}" ]]; then
			answer="${default_selection}"
			log_info "nessuna selezione: uso il bundle di default (${answer:-vuoto})"
		fi
		case "${answer,,}" in
			none|n|-) selection=""; break ;;
		esac

		if selection="$(parse_selection "${answer}" "${total}")"; then
			break
		fi
		log_warn "selezione non valida, riprovare"
	done

	if [[ -z "${selection}" ]]; then
		SELECTED_APP_IDS=()
		log_info "nessuna applicazione selezionata: la Dock conterra' solo le app di sistema"
		return 0
	fi

	read -r -a indices <<< "${selection}"
	SELECTED_APP_IDS=()
	for i in "${indices[@]}"; do
		SELECTED_APP_IDS+=("${APP_TABLE_IDS[i-1]}")
	done
}

select_apps_from_bundle() {
	local edition="$1"
	local pinned ids=()
	pinned="$(json_get_bundle_key "${edition}" default_pinned)"
	while IFS= read -r id; do
		[[ -n "${id}" ]] || continue
		ids+=("${id}")
	done <<< "${pinned}"

	if (( ${#ids[@]} == 0 )); then
		# Fallback: tutte le app pre-selezionate del bundle.
		pinned="$(json_get_bundle_key "${edition}" preselected)"
		while IFS= read -r id; do
			[[ -n "${id}" ]] || continue
			ids+=("${id}")
		done <<< "${pinned}"
	fi

	SELECTED_APP_IDS=("${ids[@]}")
}

select_apps_from_list() {
	local list="$1"
	local total="${#APP_TABLE_IDS[@]}"
	local selection indices=() i

	selection="$(parse_selection "${list}" "${total}")" || die 1 "selezione --apps non valida: ${list}"
	if [[ -z "${selection}" ]]; then
		SELECTED_APP_IDS=()
		return 0
	fi
	read -r -a indices <<< "${selection}"
	SELECTED_APP_IDS=()
	for i in "${indices[@]}"; do
		SELECTED_APP_IDS+=("${APP_TABLE_IDS[i-1]}")
	done
}

summarize_selection() {
	local id type count=0 android=0 windows=0 web=0
	log_step "Applicazioni selezionate (${#SELECTED_APP_IDS[@]})"
	for id in "${SELECTED_APP_IDS[@]}"; do
		type="$(json_get_app "${id}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("type",""))' 2>/dev/null || echo "?")"
		case "${type}" in
			Web_App)     (( ++web )) || true ;;
			Android_Pkg) (( ++android )) || true ;;
			Windows_Pkg) (( ++windows )) || true ;;
		esac
		(( ++count )) || true
		printf '  %2d. %-26s %s\n' "${count}" "${id}" "${type}" >&2
	done
	log_info "riepilogo: ${web} Web_App, ${android} Android_Pkg, ${windows} Windows_Pkg"
	if (( android > 0 )); then
		log_info "le app Android_Pkg richiedono Waydroid (stato: ${WAYDROID_BOOT_STATE})"
	fi
	if (( windows > 0 )); then
		log_info "le app Windows_Pkg richiedono Wine (stato: ${WINE_BOOT_STATE})"
	fi
}

# =============================================================================
# GENERAZIONE DI shelf.json (Dock centrata)
# =============================================================================
generate_shelf_json() {
	local edition="$1"
	local target_dir="${STAGING_DIR}/etc/skel/.config/chromiumos"
	local target="${target_dir}/shelf.json"

	log_step "Generazione di /etc/skel/.config/chromiumos/shelf.json"
	ensure_dir "${target_dir}"

	local ids_json="[]"
	if (( ${#SELECTED_APP_IDS[@]} > 0 )); then
		ids_json="$(printf '"%s",' "${SELECTED_APP_IDS[@]}")"
		ids_json="[${ids_json%,}]"
	fi

	PRISMOS_SHELF_EDITION="${edition}" \
	PRISMOS_SHELF_IDS="${ids_json}" \
	PRISMOS_SHELF_ALIGNMENT="${SHELF_ALIGNMENT}" \
	PRISMOS_SHELF_AUTOHIDE="${SHELF_AUTOHIDE}" \
	PRISMOS_SHELF_CENTERED="${SHELF_CENTERED}" \
	PRISMOS_SHELF_ICON_SIZE="${SHELF_ICON_SIZE}" \
	PRISMOS_SHELF_SQUIRCLE_RADIUS="${SHELF_SQUIRCLE_RADIUS}" \
	PRISMOS_SHELF_SQUIRCLE_EXPONENT="${SHELF_SQUIRCLE_EXPONENT}" \
	PRISMOS_SHELF_PIN_MAX="${SHELF_PIN_MAX}" \
	PRISMOS_SHELF_ACCELERATOR="${SHELF_LAUNCHER_ACCELERATOR}" \
	PRISMOS_SHELF_WEB_ACCELERATOR="${SHELF_WEB_SEARCH_ACCELERATOR}" \
	PRISMOS_SHELF_ANIMATIONS="${SHELF_ANIMATIONS}" \
	PRISMOS_SHELF_BLUR="${SHELF_BACKGROUND_BLUR}" \
	PRISMOS_SHELF_OPACITY="${SHELF_BACKGROUND_OPACITY}" \
	PRISMOS_SHELF_ANIM_MS="${SHELF_ANIMATION_DURATION_MS}" \
	PRISMOS_SHELF_MAX_WINDOWS="${SHELF_MAX_VISIBLE_WINDOWS}" \
	PRISMOS_SHELF_EDITION_NAME="${EDITION_NAME}" \
	PRISMOS_SHELF_STAMP="${BUILD_STAMP}" \
	PRISMOS_JSON_FILE="${PRISMOS_APP_POOL}" \
	python3 - "${target}" <<'PY'
import json, os, sys

target = sys.argv[1]
pool_path = os.environ["PRISMOS_JSON_FILE"]

with open(pool_path, encoding="utf-8") as fh:
    pool = json.load(fh)

def truthy(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on", "si")


apps = {a["id"]: a for a in pool.get("applications", []) if "id" in a}
selected = json.loads(os.environ["PRISMOS_SHELF_IDS"])
edition = os.environ["PRISMOS_SHELF_EDITION"]
bundle = pool.get("flavor_bundles", {}).get(edition, {})
blocked = set(bundle.get("blocked_by_policy", []))
dock = pool.get("dock_defaults", {})

pin_max = int(os.environ.get("PRISMOS_SHELF_PIN_MAX", "8"))
try:
    pin_max = min(pin_max, int(bundle.get("max_pinned", pin_max)))
except (TypeError, ValueError):
    pass

pinned = []
order = 1
for app_id in selected:
    if app_id in blocked:
        sys.stderr.write("shelf.json: '%s' esclusa (bloccata dalla policy di edizione)\n" % app_id)
        continue
    app = apps.get(app_id)
    if app is None:
        sys.stderr.write("shelf.json: '%s' non presente nel pool, ignorata\n" % app_id)
        continue
    if len(pinned) >= pin_max:
        sys.stderr.write("shelf.json: limite di %d pin raggiunto, '%s' resta nel launcher\n" % (pin_max, app_id))
        continue
    entry = {
        "id": app["id"],
        "name": app.get("name", app["id"]),
        "type": app.get("type", "Web_App"),
        "launch_url": app.get("launch_url", ""),
        "install_url": app.get("install_url", ""),
        "scope": app.get("scope", ""),
        "icon": app.get("icon", ""),
        "glyph": app.get("glyph", ""),
        "color": app.get("color", "#5B6CFF"),
        "category": app.get("category", ""),
        "app_window": bool(app.get("app_window", True)),
        "requires_signin": bool(app.get("requires_signin", False)),
        "offline_capable": bool(app.get("offline_capable", False)),
        "subsystem": "none",
        "order": order,
    }
    if entry["type"] == "Android_Pkg":
        entry["subsystem"] = "waydroid"
        entry["android_package"] = app.get("android_package", "")
        entry["android_activity"] = app.get("android_activity", "")
        entry["container_unit"] = pool["runtime_engines"]["android"]["unit_container"]
        entry["session_unit"] = pool["runtime_engines"]["android"]["unit_session"]
        entry["launcher"] = "/usr/bin/prismos-slim-launcher"
    elif entry["type"] == "Windows_Pkg":
        entry["subsystem"] = "wine"
        entry["wine_prefix"] = app.get("wine_prefix", "Default")
        entry["wine_arch"] = app.get("wine_arch", "win32")
        entry["installer_url"] = app.get("install_url", "")
        entry["installer_args"] = app.get("installer_args", [])
        entry["post_install_binary"] = app.get("post_install_binary", "")
        entry["wine_dependencies"] = app.get("wine_dependencies", [])
        entry["session_unit"] = pool["runtime_engines"]["windows"]["unit_session"]
        entry["launcher"] = "/usr/bin/prismos-wine-run"
    pinned.append(entry)
    order += 1

shelf = {
    "schema_version": "1.0.0",
    "generated_by": "prismOS build_iso.sh %s" % os.environ.get("PRISMOS_SHELF_STAMP", ""),
    "edition": edition,
    "edition_name": os.environ.get("PRISMOS_SHELF_EDITION_NAME", edition),
    "target_path": "/etc/skel/.config/chromiumos/shelf.json",
    "shelf": {
        "alignment": os.environ.get("PRISMOS_SHELF_ALIGNMENT", dock.get("alignment", "Bottom")),
        "autohide": os.environ.get("PRISMOS_SHELF_AUTOHIDE", dock.get("autohide", "Always")),
        "centered": os.environ.get("PRISMOS_SHELF_CENTERED", "true").lower() in ("1", "true", "yes"),
        "icon_size": int(os.environ.get("PRISMOS_SHELF_ICON_SIZE", dock.get("icon_size", 48))),
        "icon_spacing": int(dock.get("icon_spacing", 8)),
        "squircle_radius": float(os.environ.get("PRISMOS_SHELF_SQUIRCLE_RADIUS", dock.get("squircle_radius", 0.28))),
        "squircle_exponent": float(os.environ.get("PRISMOS_SHELF_SQUIRCLE_EXPONENT", dock.get("squircle_exponent", 5.0))),
        "launcher_button_position": "center",
        "launcher_accelerator": os.environ.get("PRISMOS_SHELF_ACCELERATOR", dock.get("launcher_accelerator", "super+space")),
        "web_search_accelerator": os.environ.get("PRISMOS_SHELF_WEB_ACCELERATOR", "super+shift+space"),
        "show_window_indicators": True,
        "magnification_on_hover": False,
        "background_blur": truthy(os.environ.get("PRISMOS_SHELF_BLUR", "1")),
        "background_opacity": float(os.environ.get("PRISMOS_SHELF_OPACITY", "0.86")),
        "animations_enabled": truthy(os.environ.get("PRISMOS_SHELF_ANIMATIONS", "1")),
        "animation_duration_ms": int(os.environ.get("PRISMOS_SHELF_ANIM_MS", "180")),
        "max_visible_windows": int(os.environ.get("PRISMOS_SHELF_MAX_WINDOWS", "8")),
        "max_pinned": pin_max,
    },
    "policy_mapping": {
        "ShelfAlignment": os.environ.get("PRISMOS_SHELF_ALIGNMENT", "Bottom"),
        "ShelfAutoHideBehavior": os.environ.get("PRISMOS_SHELF_AUTOHIDE", "Always"),
        # PinnedLauncherApps accetta solo riferimenti ad applicazioni web (URL o
        # ID del Web Store): i nomi pacchetto Android non sono ID di launcher
        # validi in una build senza ARC e verrebbero ignorati da Chrome con un
        # avviso nel log. Le icone Android/Windows restano in pinned_apps, da
        # cui Ash le aggiunge alla shelf leggendo shelf.json.
        "PinnedLauncherApps": [e["launch_url"] for e in pinned if e["type"] == "Web_App"],
        "WebAppInstallForceList": [
            {"url": e["launch_url"], "create_url": e.get("install_url") or e["launch_url"]}
            for e in pinned if e["type"] == "Web_App"
        ],
    },
    "pinned_apps": pinned,
    "unselected_apps": [aid for aid in apps if aid not in {e["id"] for e in pinned}],
    "subsystems": {
        "android": pool["runtime_engines"]["android"],
        "windows": pool["runtime_engines"]["windows"],
        "web": pool["runtime_engines"]["web"],
    },
}

shelf["policy_mapping"]["PinnedLauncherApps"] = [
    u for u in shelf["policy_mapping"]["PinnedLauncherApps"] if u
]

with open(target, "w", encoding="utf-8") as fh:
    json.dump(shelf, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

print("%s: %d icone bloccate su %d selezionate" % (target, len(pinned), len(selected)))
PY

	json_validate "${target}" || die 1 "shelf.json generato non valido"
	log_ok "${target}"
}

# =============================================================================
# GENERAZIONE DI edition.conf
# =============================================================================
generate_edition_conf() {
	local edition="$1"
	local target_dir="${STAGING_DIR}/etc/prismos"
	local target="${target_dir}/edition.conf"

	log_step "Generazione di /etc/prismos/edition.conf"
	ensure_dir "${target_dir}"

	{
		echo "# ============================================================================="
		echo "#  /etc/prismos/edition.conf  -  generato da scripts/build_iso.sh"
		echo "#  NON modificare a mano: viene rigenerato ad ogni build."
		echo "# ============================================================================="
		echo "PRISMOS_EDITION_ID=\"${edition}\""
		echo "PRISMOS_EDITION_NAME=\"${EDITION_NAME}\""
		echo "PRISMOS_EDITION_TAGLINE=\"${EDITION_TAGLINE:-}\""
		echo "PRISMOS_BOARD=\"${BOARD}\""
		echo "PRISMOS_BUILD_STAMP=\"${BUILD_STAMP}\""
		echo "PRISMOS_BUILD_REVISION=\"$(prismos_git_revision)\""
		echo "PRISMOS_BUILD_HOST=\"$(hostname -f 2>/dev/null || hostname)\""
		echo "PRISMOS_IMAGE_TYPE=\"${IMAGE_TYPE}\""
		echo "PRISMOS_ISA_FLOOR=\"x86_64-SSE4.1\""
		echo "PRISMOS_TARGET_CPU=\"${TARGET_CPU}\""
		echo "PRISMOS_MIN_RAM_MB=\"${MIN_RAM_MB}\""
		echo "PRISMOS_KERNEL_VERSION=\"${KERNEL_VERSION}\""
		echo "PRISMOS_KERNEL_SPLITCONFIG=\"${KERNEL_SPLITCONFIG}\""
		echo ""
		echo "# --- Stato di avvio dei sottosistemi -----------------------------------------"
		echo "PRISMOS_WAYDROID_BOOT_STATE=\"${WAYDROID_BOOT_STATE}\""
		echo "PRISMOS_WINE_BOOT_STATE=\"${WINE_BOOT_STATE}\""
		echo "PRISMOS_SUBSYSTEM_IDLE_TIMEOUT=\"${SUBSYSTEM_IDLE_TIMEOUT}\""
		echo "PRISMOS_SUBSYSTEM_MAX_INSTANCES=\"${SUBSYSTEM_MAX_INSTANCES}\""
		echo "PRISMOS_SUBSYSTEM_TEARDOWN=\"${SUBSYSTEM_TEARDOWN}\""
		echo "PRISMOS_SUBSYSTEM_TEARDOWN_GRACE_SEC=\"${SUBSYSTEM_TEARDOWN_GRACE_SEC}\""
		echo "PRISMOS_SUBSYSTEMS_TARGET_ENABLED=\"$( [[ "${WAYDROID_BOOT_STATE}" == "on-demand" && "${WINE_BOOT_STATE}" == "on-demand" ]] && echo 0 || echo 1 )\""
		echo ""
		echo "# --- Dock macOS-like ----------------------------------------------------------"
		echo "PRISMOS_SHELF_ALIGNMENT=\"${SHELF_ALIGNMENT}\""
		echo "PRISMOS_SHELF_AUTOHIDE=\"${SHELF_AUTOHIDE}\""
		echo "PRISMOS_SHELF_CENTERED=\"${SHELF_CENTERED}\""
		echo "PRISMOS_SHELF_ICON_SIZE=\"${SHELF_ICON_SIZE}\""
		echo "PRISMOS_SHELF_SQUIRCLE_RADIUS=\"${SHELF_SQUIRCLE_RADIUS}\""
		echo "PRISMOS_SHELF_PIN_MAX=\"${SHELF_PIN_MAX}\""
		echo "PRISMOS_LAUNCHER_ACCELERATOR=\"${SHELF_LAUNCHER_ACCELERATOR}\""
		echo "PRISMOS_WEB_SEARCH_ACCELERATOR=\"${SHELF_WEB_SEARCH_ACCELERATOR}\""
		echo "PRISMOS_SHELF_ANIMATIONS=\"${SHELF_ANIMATIONS}\""
		echo "PRISMOS_SHELF_BACKGROUND_BLUR=\"${SHELF_BACKGROUND_BLUR}\""
		echo "PRISMOS_SHELF_BACKGROUND_OPACITY=\"${SHELF_BACKGROUND_OPACITY}\""
		echo "PRISMOS_SHELF_MAX_VISIBLE_WINDOWS=\"${SHELF_MAX_VISIBLE_WINDOWS}\""
		echo ""
		echo "# --- Policy -------------------------------------------------------------------"
		echo "PRISMOS_POLICY_MODE=\"${POLICY_MODE}\""
		echo "PRISMOS_POLICY_TARGET=\"${POLICY_TARGET}\""
		echo "PRISMOS_EDU_DOMAIN=\"${EDU_DOMAIN}\""
		echo ""
		echo "# --- Crittografia --------------------------------------------------------------"
		echo "PRISMOS_ENCRYPTED_DOWNLOADS=\"${ENCRYPTED_DOWNLOADS}\""
		echo ""
		echo "# --- Applicazioni selezionate in fase di build ----------------------------------"
		echo "PRISMOS_SELECTED_APPS=\"${SELECTED_APP_IDS[*]}\""
		echo "PRISMOS_SELECTED_APP_COUNT=\"${#SELECTED_APP_IDS[@]}\""
	} > "${target}"

	chmod 0644 "${target}"
	bash -n "${target}" || die 1 "edition.conf generato non e' bash valido"
	log_ok "${target}"
}

# =============================================================================
# SINCRONIZZAZIONE DEGLI OVERLAY NEL cros_sdk
# =============================================================================
sync_overlays() {
	local edition="$1"

	log_step "Sincronizzazione degli overlay nel cros_sdk"

	if [[ ${ARG_NO_SYNC} -eq 1 ]]; then
		log_warn "--no-sync: sincronizzazione degli overlay saltata"
		return 0
	fi
	if [[ -z "${PRISMOS_SDK_RESOLVED}" ]]; then
		log_warn "cros_sdk non disponibile: gli overlay restano nella staging directory"
		log_info "staging: ${STAGING_DIR}/overlays"
		return 0
	fi

	local sdk_overlays
	if ! sdk_overlays="$(prismos_sdk_overlays_dir)"; then
		die 1 "cros_sdk non risolto: impossibile individuare la directory degli overlay"
	fi

	if [[ ! -d "${sdk_overlays}" ]]; then
		die 1 "directory degli overlay non trovata: ${sdk_overlays}"
	fi

	# 1. La repository deve risiedere dove il chroot la vede, cioe' in
	#    <checkout>/src/overlays/<nome>. Se lo script viene lanciato da un'altra
	#    posizione si crea un link simbolico assoluto verso PRISMOS_ROOT: il
	#    checkout e' bind-mounted in /mnt/host/source, quindi il link resta
	#    valido anche dentro il chroot.
	local repo_in_chroot="${ARG_REPO_MOUNT}"
	local repo_link_name
	repo_link_name="$(basename "${repo_in_chroot%/}")"
	local repo_link="${sdk_overlays}/${repo_link_name}"

	if ! prismos_in_chroot; then
		local host_repo_path
		host_repo_path="$(cd "${PRISMOS_ROOT}" && pwd)"
		if [[ "$(readlink -f "${repo_link}" 2>/dev/null || true)" == "${host_repo_path}" ]]; then
			log_debug "repository gia' collegata in ${repo_link}"
		elif [[ -e "${repo_link}" && ! -L "${repo_link}" ]]; then
			die 1 "${repo_link} esiste e non e' un link simbolico: spostarlo o usare --copy-overlays"
		else
			log_info "la repository non risiede in src/overlays/${repo_link_name}: creo il link simbolico"
			ln -sfn "${host_repo_path}" "${repo_link}" || \
				die 1 "impossibile collegare ${host_repo_path} in ${repo_link}"
		fi
		[[ -d "${repo_link}/overlays" ]] || \
			die 1 "link simbolico non risolvibile: ${repo_link}/overlays"
		log_ok "repository visibile nel chroot come ${repo_in_chroot}"
	fi

	# 2. Link simbolici (o copie) degli overlay prismOS.
	local ov name
	for ov in "${PRISMOS_OVERLAYS_DIR}"/overlay-*; do
		name="$(basename "${ov}")"
		case "${name}" in
			overlay-prismos-*) ;;
			overlay-"${ARG_BOARD}")
				# La board overlay e' rigenerata integralmente al passo 4: non
				# va ne' collegata ne' copiata qui.
				log_debug "board overlay gestita separatamente: ${name}"
				continue ;;
			*) log_warn "overlay inatteso ignorato: ${name}"; continue ;;
		esac
		if [[ ${ARG_COPY_OVERLAYS} -eq 1 ]]; then
			rm -rf "${sdk_overlays:?}/${name}"
			copy_tree "${ov}" "${sdk_overlays}/${name}"
			log_debug "copiato ${name}"
		else
			# Link RELATIVO: risolvibile sia dall'host sia dal chroot, che vede lo
			# stesso albero montato in /mnt/host/source.
			ln -sfn "${repo_link_name}/overlays/${name}" "${sdk_overlays}/${name}"
			[[ -d "${sdk_overlays}/${name}" ]] || \
				die 1 "link dell'overlay non risolvibile: ${sdk_overlays}/${name}"
			log_debug "link ${sdk_overlays}/${name} -> ${repo_link_name}/overlays/${name}"
		fi
	done

	# 3. Link simbolico "overlay attivo" per l'edizione corrente: comodo per
	#    ispezionare a mano la configurazione dell'edizione compilata.
	ln -sfn "overlay-prismos-${edition}" "${sdk_overlays}/overlay-prismos-active"
	log_ok "overlay attivo: ${sdk_overlays}/overlay-prismos-active -> overlay-prismos-${edition}"

	# 4. Board overlay: profilo parent con l'edizione appesa e make.conf
	#    concatenato (common -> edizione -> board).
	# La board overlay viene RICREATA DA ZERO ad ogni edizione: profiles/base/parent,
	# make.conf e l'albero board/ sono specifici dell'edizione e, se si lavorasse
	# per merge, i file di un'edizione precedente (per esempio /etc/prismos/
	# slim-tuning.conf) resterebbero nell'immagine di quella successiva.
	local board_overlay="${sdk_overlays}/overlay-${ARG_BOARD}"
	local board_source="${PRISMOS_OVERLAYS_DIR}/overlay-${ARG_BOARD}"
	[[ -d "${board_source}" ]] || die 1 "overlay del board mancante: ${board_source}"
	rm -rf "${board_overlay}"
	copy_tree "${board_source}" "${board_overlay}"
	log_ok "board overlay ricreata: ${board_overlay}"

	cat > "${board_overlay}/profiles/base/parent" <<PARENT
# =============================================================================
#  Board ${ARG_BOARD} :: profilo base :: parent   (GENERATO, non modificare)
#  Generato da scripts/build_iso.sh il $(date -Is) per l'edizione ${edition}.
# =============================================================================
chromiumos:default/linux/amd64/10.0/chromeos
prismos-common:base
prismos-${edition}:base
PARENT
	log_ok "parent del board: chromiumos + prismos-common + prismos-${edition}"

	local board_make="${board_overlay}/make.conf"
	cat > "${board_make}" <<MAKEHEADER
# =============================================================================
#  Board ${ARG_BOARD} :: make.conf   (GENERATO da scripts/build_iso.sh)
#  Edizione: ${edition} (${EDITION_NAME})  -  ${BUILD_STAMP}
#  Ordine di concatenazione: common (floor ISA) -> ${edition} -> board.
#  NON modificare a mano: il file viene riscritto ad ogni build.
# =============================================================================
MAKEHEADER
	cat "${PRISMOS_OVERLAYS_DIR}/overlay-prismos-common/make.conf" >> "${board_make}"
	printf '\n# ---- overlay-prismos-%s/make.conf ----\n' "${edition}" >> "${board_make}"
	cat "${PRISMOS_OVERLAYS_DIR}/overlay-prismos-${edition}/make.conf" >> "${board_make}"
	printf '\n# ---- overlay-%s/make.conf (identita del board) ----\n' "${ARG_BOARD}" >> "${board_make}"
	cat "${PRISMOS_OVERLAYS_DIR}/overlay-${ARG_BOARD}/make.conf" >> "${board_make}"
	log_ok "make.conf di board generato: $(grep -c '' "${board_make}") righe"

	# 5. File radice dell'edizione -> board/<albero rootfs>
	if [[ -n "${ROOTFS_FILES}" && -d "${PRISMOS_ROOT}/${ROOTFS_FILES}" ]]; then
		copy_tree "${PRISMOS_ROOT}/${ROOTFS_FILES}" "${board_overlay}/board"
		log_ok "file rootfs di edizione copiati in ${board_overlay}/board"
	else
		log_info "nessun albero rootfs di edizione per ${edition}"
	fi

	# 6. Artefatti generati in questa build (shelf.json, edition.conf).
	copy_tree "${STAGING_DIR}/etc" "${board_overlay}/board/etc"
	log_ok "shelf.json ed edition.conf copiati nella board overlay"

	# 7. Pool applicazioni, configurazione Dock e strumenti prismOS leggibili a
	#    runtime: i messaggi di prismos-waydroid-prepare e di prismos-slim-launcher
	#    rimandano a /usr/share/prismos/scripts/, che deve quindi esistere
	#    sull'immagine e non solo nella repository di sviluppo.
	ensure_dir "${board_overlay}/board/usr/share/prismos/scripts/lib"
	cp -f "${PRISMOS_APP_POOL}" "${board_overlay}/board/usr/share/prismos/app_pool.json"
	cp -f "${PRISMOS_OVERLAYS_DIR}/overlay-prismos-common/app-misc/prismos-dock/files/ash-shelf.conf" \
		"${board_overlay}/board/usr/share/prismos/ash-shelf.conf"

	local tool
	for tool in provision_waydroid_image.sh verify_legacy_cpu.sh set_edu_policy.sh \
	          generate_app_icons.sh sync_overlays.sh build_iso.sh; do
		if [[ -f "${PRISMOS_SCRIPTS_DIR}/${tool}" ]]; then
			cp -f "${PRISMOS_SCRIPTS_DIR}/${tool}" \
				"${board_overlay}/board/usr/share/prismos/scripts/${tool}"
			chmod 0755 "${board_overlay}/board/usr/share/prismos/scripts/${tool}"
		fi
	done
	cp -f "${PRISMOS_LIB_DIR}"/*.sh "${PRISMOS_LIB_DIR}"/*.py \
		"${board_overlay}/board/usr/share/prismos/scripts/lib/" 2>/dev/null || true
	log_ok "app_pool.json, ash-shelf.conf e 6 strumenti installati in /usr/share/prismos"

	# 8. Tema di icone squircle: se assente viene generato al volo.
	local icons_dir="${board_overlay}/board/usr/share/icons/prismOS-Squircle/apps/scalable"
	if [[ -d "${icons_dir}" ]] && \
	   [[ -n "$(find "${icons_dir}" -maxdepth 1 -name '*.svg' -print -quit 2>/dev/null)" ]]; then
		local icon_count=0 svg_file
		while IFS= read -r svg_file; do
			[[ -n "${svg_file}" ]] || continue
			(( ++icon_count )) || true
		done < <(find "${icons_dir}" -maxdepth 1 -name '*.svg' -type f 2>/dev/null)
		log_ok "tema di icone prismOS-Squircle presente: ${icon_count} SVG"
	elif [[ -x "${PRISMOS_SCRIPTS_DIR}/generate_app_icons.sh" ]]; then
		log_info "tema di icone assente: genero le icone squircle"
		if "${PRISMOS_SCRIPTS_DIR}/generate_app_icons.sh" --quiet; then
			log_ok "tema di icone generato in ${icons_dir}"
		else
			log_warn "generazione del tema di icone non riuscita: la Dock usera' i glifi testuali"
		fi
	else
		log_warn "generate_app_icons.sh assente: nessuna icona squircle nell'immagine"
	fi

	# 9. Policy Chromium dell'edizione.
	install_edition_policy "${board_overlay}"

	# 10. Splitconfig del kernel.
	sync_kernel_splitconfig
}

install_edition_policy() {
	local board_overlay="$1"
	local policy_dir="${board_overlay}/board/etc/chromium/policies/managed"
	local source nkeys

	case "${EDITION}" in
		edu)
			POLICY_MODE="${POLICY_MODE:-local}"
			source="${PRISMOS_ROOT}/overlays/overlay-prismos-edu/chrome_policy.json"
			if [[ "${POLICY_MODE}" == "cloud" ]]; then
				log_info "EDU Strada A (Cloud-Managed): nessuna policy JSON locale."
				log_info "  Iscrizione sulla Google Admin Console dell'istituto (dominio"
				log_info "  ${EDU_DOMAIN}) tramite i flag di Enterprise Enrollment presenti"
				log_info "  in /etc/default/chromium-browser."
				# Le policy di dispositivo hanno precedenza su quelle cloud: ogni
				# residuo di una precedente build Strada B va rimosso.
				rm -f "${policy_dir}/prismos_policy.json"
			else
				[[ -f "${source}" ]] || die 1 "policy EDU mancante: ${source}"
				ensure_dir "${policy_dir}"
				cp -f "${source}" "${policy_dir}/prismos_policy.json"
				json_validate "${policy_dir}/prismos_policy.json" || die 1 "policy EDU non valida"
				nkeys="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' \
					"${policy_dir}/prismos_policy.json" 2>/dev/null || echo 0)"
				log_ok "EDU Strada B: policy in ${policy_dir}/prismos_policy.json (${nkeys} chiavi)"
			fi
			;;
		work)
			if [[ "${POLICY_MODE}" == "none" ]]; then
				log_info "WORK: policy di dispositivo disattivata (--policy-mode none)"
				rm -f "${policy_dir}/prismos_policy.json"
			else
				source="${PRISMOS_ROOT}/overlays/overlay-prismos-work/files/etc/chromium/policies/managed/prismos_policy.json"
				if [[ -f "${source}" ]]; then
					ensure_dir "${policy_dir}"
					cp -f "${source}" "${policy_dir}/prismos_policy.json"
					json_validate "${policy_dir}/prismos_policy.json" || die 1 "policy Work non valida"
					log_ok "policy Work installata: ${policy_dir}/prismos_policy.json"
				else
					log_warn "policy Work attesa ma non trovata: ${source}"
				fi
			fi
			;;
		home|slim)
			log_info "edizione ${EDITION}: nessuna policy Chromium di dispositivo"
			rm -f "${policy_dir}/prismos_policy.json"
			;;
		*)
			log_warn "edizione sconosciuta ${EDITION}: nessuna policy applicata"
			;;
	esac

	# La Dock e' sempre governata da policy: il prefisso zz- fa vincere questo
	# file sugli altri presenti in /etc/chromium/policies/managed/.
	local dock_policy="${policy_dir}/zz-prismos-dock.json"
	ensure_dir "${policy_dir}"
	if [[ -f "${STAGING_DIR}/etc/skel/.config/chromiumos/shelf.json" ]]; then
		PRISMOS_JSON_FILE="${STAGING_DIR}/etc/skel/.config/chromiumos/shelf.json" \
		python3 - "${dock_policy}" <<'PY'
import json, os, sys

target = sys.argv[1]
with open(os.environ["PRISMOS_JSON_FILE"], encoding="utf-8") as fh:
    shelf = json.load(fh)

mapping = shelf.get("policy_mapping", {})
policy = {
    "ShelfAlignment": mapping.get("ShelfAlignment", "Bottom"),
    "ShelfAutoHideBehavior": mapping.get("ShelfAutoHideBehavior", "Always"),
}
pinned = [u for u in mapping.get("PinnedLauncherApps", []) if u]
if pinned:
    policy["PinnedLauncherApps"] = pinned
force_list = [e for e in mapping.get("WebAppInstallForceList", []) if e.get("url")]
if force_list:
    policy["WebAppInstallForceList"] = force_list

with open(target, "w", encoding="utf-8") as fh:
    json.dump(policy, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("policy Dock: %d pin, %d PWA" % (len(policy.get("PinnedLauncherApps", [])),
                                       len(policy.get("WebAppInstallForceList", []))))
PY
		log_ok "policy Dock generata: ${dock_policy}"
	fi
}

sync_kernel_splitconfig() {
	log_step "Sincronizzazione dello splitconfig del kernel"
	local kernel_rel="src/third_party/kernel/v${KERNEL_VERSION}/chromeos/config/chromiumos-x86_64"
	local kernel_dst sdk_overlays_dir

	if sdk_overlays_dir="$(prismos_sdk_overlays_dir)"; then
		kernel_dst="$(dirname "$(dirname "${sdk_overlays_dir}")")/${kernel_rel}"
	else
		kernel_dst="${STAGING_DIR}/kernel-out/chromeos/config/chromiumos-x86_64"
		log_warn "cros_sdk assente: splitconfig preparato in ${kernel_dst}"
	fi

	local parent_dir
	parent_dir="$(dirname "${kernel_dst}")"
	if [[ ! -d "${parent_dir}" ]]; then
		log_warn "albero del kernel v${KERNEL_VERSION} non trovato (${parent_dir})"
		log_warn "verificare CHROMEOS_KERNEL_VERSION in overlay-prismos-common/make.conf"
		mkdir -p "${kernel_dst}" 2>/dev/null || true
	fi

	if [[ -d "${kernel_dst}" ]]; then
		rm -rf "${kernel_dst}/prismos_legacy"
		copy_tree "${PRISMOS_KERNEL_DIR}/chromeos/config/chromiumos-x86_64/prismos_legacy" \
			"${kernel_dst}/prismos_legacy"
		log_ok "splitconfig copiato in ${kernel_dst}/prismos_legacy"
	fi
}

# Directory degli overlay all'interno del checkout del cros_sdk.
prismos_sdk_overlays_dir() {
	if prismos_in_chroot; then
		printf '%s' "/mnt/host/source/src/overlays"
		return 0
	fi
	[[ -n "${PRISMOS_SDK_RESOLVED:-}" ]] || return 1
	printf '%s' "$(dirname "${PRISMOS_SDK_RESOLVED}")/src/overlays"
}

# =============================================================================
# COMPILAZIONE
# =============================================================================
run_setup_board() {
	log_step "setup_board --board=${ARG_BOARD}"
	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_warn "[dry-run] saltato: setup_board --board=${ARG_BOARD}"
		return 0
	fi
	cros_sdk_run setup_board --board="${ARG_BOARD}" --force || \
		die 1 "setup_board fallito per il board ${ARG_BOARD}"
	log_ok "board ${ARG_BOARD} inizializzato"
}

run_build_packages() {
	log_step "build_packages --board=${ARG_BOARD}"
	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_warn "[dry-run] saltato: build_packages --board=${ARG_BOARD}"
		return 0
	fi

	local jobs="${ARG_JOBS:-$(nproc 2>/dev/null || echo 4)}"
	local pkg_list=()
	local pkg

	# Pacchetti aggiuntivi dichiarati dal make.conf dell'edizione.
	for pkg in ${EXTRA_PACKAGES}; do
		pkg_list+=("${pkg}")
	done
	if (( ${#pkg_list[@]} > 0 )); then
		log_info "pacchetti aggiuntivi: ${pkg_list[*]}"
	fi

	cros_sdk_run build_packages \
		--board="${ARG_BOARD}" \
		--nowithautotest \
		--skip_chroot_upgrade \
		--jobs="${jobs}" || die 1 "build_packages fallito"

	if (( ${#pkg_list[@]} > 0 )); then
		cros_sdk_shell "sudo emerge --board='${ARG_BOARD}' --noreplace ${pkg_list[*]}" || \
			log_warn "installazione dei pacchetti aggiuntivi non riuscita"
	fi

	if [[ -n "${REMOVED_PACKAGES//[[:space:]]/}" ]]; then
		# shellcheck disable=SC2086
		cros_sdk_shell "sudo emerge --board='${ARG_BOARD}' --unmerge ${REMOVED_PACKAGES}" || \
			log_warn "rimozione dei pacchetti ${REMOVED_PACKAGES} non riuscita"
	fi

	log_ok "build_packages completato"
}

run_build_image() {
	log_step "build_image --board=${ARG_BOARD} ${IMAGE_TYPE}"
	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_warn "[dry-run] saltato: build_image --board=${ARG_BOARD} ${IMAGE_TYPE}"
		return 0
	fi

	# --noenable_rootfs_verification e' indispensabile: prismOS applica policy e
	# preferenze di Ash a runtime (/etc/chromium/policies, Local State) e monta
	# vault cifrati in /home. Con la rootfs verificata tali scritture fallirebbero.
	cros_sdk_run build_image \
		--board="${ARG_BOARD}" \
		--noenable_rootfs_verification \
		"${IMAGE_TYPE}" || die 1 "build_image fallito"
	log_ok "immagine ${IMAGE_TYPE} generata"
}

apply_subsystem_boot_states() {
	log_step "Configurazione dello stato di avvio dei sottosistemi"
	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_warn "[dry-run] saltato"
		return 0
	fi

	local board_root="/build/${ARG_BOARD}"
	local script=""

	case "${WAYDROID_BOOT_STATE}" in
		enabled)  script+="sudo systemctl --root='${board_root}' enable prismos-waydroid-container.service; " ;;
		masked)   script+="sudo systemctl --root='${board_root}' mask prismos-waydroid-container.service; " ;;
		*)        script+="sudo systemctl --root='${board_root}' disable prismos-waydroid-container.service; " ;;
	esac
	case "${WINE_BOOT_STATE}" in
		enabled)  script+="sudo systemctl --root='${board_root}' enable prismos-wine-session@1000.service; " ;;
		masked)   script+="sudo systemctl --root='${board_root}' mask prismos-wine-session@1000.service; " ;;
		*)        script+="sudo systemctl --root='${board_root}' disable prismos-wine-session@1000.service; " ;;
	esac
	if [[ "${WAYDROID_BOOT_STATE}" == "on-demand" && "${WINE_BOOT_STATE}" == "on-demand" ]]; then
		script+="sudo systemctl --root='${board_root}' disable prismos-subsystems.target; "
		script+="sudo systemctl --root='${board_root}' mask prismos-subsystem-idle.timer; "
		log_info "edizione on-demand: prismos-subsystems.target disabilitato"
	else
		script+="sudo systemctl --root='${board_root}' enable prismos-subsystems.target; "
		script+="sudo systemctl --root='${board_root}' enable prismos-subsystem-idle.timer; "
	fi
	script+="sudo systemctl --root='${board_root}' enable prismos-dock-apply.service; "
	script+="sudo systemctl --root='${board_root}' enable prismos-accelerator-daemon.service; "
	script+="sudo systemctl --root='${board_root}' enable prismos-firstboot.service; "

	cros_sdk_shell "${script}" || log_warn "alcune operazioni systemctl non sono riuscite"
	log_ok "stati applicati: waydroid=${WAYDROID_BOOT_STATE} wine=${WINE_BOOT_STATE}"
}

# =============================================================================
# RACCOLTA DELL'IMMAGINE
# =============================================================================
collect_image() {
	local edition="$1"
	local out_name="prismOS_${edition}_legacy.img"
	local out_path="${PRISMOS_OUTPUT_DIR}/${out_name}"

	log_step "Raccolta dell'immagine in output/${out_name}"
	ensure_dir "${PRISMOS_OUTPUT_DIR}"

	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_warn "[dry-run] nessuna immagine prodotta"
		log_info "percorso atteso: ${out_path}"
		return 0
	fi

	local img_dirs=()
	if prismos_in_chroot; then
		img_dirs+=("/mnt/host/source/src/build/images/${ARG_BOARD}/latest")
	elif [[ -n "${PRISMOS_SDK_RESOLVED}" ]]; then
		img_dirs+=("$(dirname "${PRISMOS_SDK_RESOLVED}")/src/build/images/${ARG_BOARD}/latest")
	fi
	img_dirs+=("${STAGING_DIR}/image")

	local found=""
	local d
	for d in "${img_dirs[@]}"; do
		if [[ -f "${d}/chromiumos_image.bin" ]]; then
			found="${d}/chromiumos_image.bin"
			break
		fi
		if [[ -f "${d}/chromiumos_base_image.bin" ]]; then
			found="${d}/chromiumos_base_image.bin"
			break
		fi
	done

	if [[ -z "${found}" ]]; then
		die 1 "immagine non trovata in: ${img_dirs[*]}"
	fi

	local size
	size="$(stat -c '%s' "${found}" 2>/dev/null || echo 0)"
	log_info "sorgente : ${found} ($(bytes_human "${size}"))"

	cp -f "${found}" "${out_path}" || die 1 "copia dell'immagine in ${out_path} fallita"
	chmod 0644 "${out_path}"
	size="$(stat -c '%s' "${out_path}" 2>/dev/null || echo 0)"
	log_ok "output/${out_name} ($(bytes_human "${size}"))"

	# Metadati di build accanto all'immagine.
	{
		echo "edition=${edition}"
		echo "edition_name=${EDITION_NAME}"
		echo "board=${ARG_BOARD}"
		echo "image_type=${IMAGE_TYPE}"
		echo "build_stamp=${BUILD_STAMP}"
		echo "git_revision=$(prismos_git_revision)"
		echo "isa_floor=x86_64-SSE4.1"
		echo "kernel=${KERNEL_VERSION} ${KERNEL_SPLITCONFIG}"
		echo "waydroid_boot_state=${WAYDROID_BOOT_STATE}"
		echo "wine_boot_state=${WINE_BOOT_STATE}"
		echo "selected_apps=${SELECTED_APP_IDS[*]}"
		echo "selected_app_count=${#SELECTED_APP_IDS[@]}"
		echo "image_size_bytes=${size}"
		echo "sha256=$(sha256sum "${out_path}" 2>/dev/null | cut -d' ' -f1)"
	} > "${PRISMOS_OUTPUT_DIR}/prismOS_${edition}_legacy.img.info"

	cp -f "${STAGING_DIR}/etc/skel/.config/chromiumos/shelf.json" \
		"${PRISMOS_OUTPUT_DIR}/prismOS_${edition}_legacy.shelf.json" 2>/dev/null || true
	cp -f "${STAGING_DIR}/etc/prismos/edition.conf" \
		"${PRISMOS_OUTPUT_DIR}/prismOS_${edition}_legacy.edition.conf" 2>/dev/null || true

	log_ok "metadati e shelf.json copiati in output/"
}

verify_build() {
	local edition="$1"
	if [[ ${ARG_SKIP_VERIFY} -eq 1 ]]; then
		log_warn "verifica finale saltata (--skip-verify)"
		return 0
	fi
	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] verifica ISA saltata: nessun sysroot compilato"
		return 0
	fi

	log_step "Verifica finale"
	json_validate "${STAGING_DIR}/etc/skel/.config/chromiumos/shelf.json" && \
		log_ok "shelf.json valido"
	bash -n "${STAGING_DIR}/etc/prismos/edition.conf" && \
		log_ok "edition.conf valido"

	if [[ -f "${PRISMOS_OUTPUT_DIR}/prismOS_${edition}_legacy.img" ]]; then
		local size
		size="$(stat -c '%s' "${PRISMOS_OUTPUT_DIR}/prismOS_${edition}_legacy.img")"
		if (( size < 536870912 )); then
			log_warn "immagine inferiore a 512 MiB: build probabilmente incompleta"
		else
			log_ok "dimensione immagine coerente ($(bytes_human "${size}"))"
		fi
	fi

	# Verifica del floor ISA sui binari critici del sysroot appena compilato.
	if [[ -f "${PRISMOS_SCRIPTS_DIR}/verify_legacy_cpu.sh" ]]; then
		local isa_report="${PRISMOS_OUTPUT_DIR}/prismOS_${edition}_legacy.isa-report.json"
		local isa_rc=0
		if "${PRISMOS_SCRIPTS_DIR}/verify_legacy_cpu.sh" \
			--board "${ARG_BOARD}" --report "${isa_report%.json}.txt" \
			--json "${isa_report}" --quiet; then
			log_ok "verifica ISA superata: nessun binario richiede SSE4.2"
		else
			isa_rc=$?
			log_error "verifica ISA FALLITA (codice ${isa_rc}): dettagli in ${isa_report}"
			log_error "  il binario segnalato terminerebbe con SIGILL su Pentium P6100"
			log_error "  ricontrollare CFLAGS e gli argomenti GN di chromeos-chrome"
			return 1
		fi
	else
		log_warn "verify_legacy_cpu.sh assente: verifica del floor ISA non eseguita"
	fi
}

cleanup_build() {
	local edition="$1"
	if [[ ${ARG_KEEP_BUILD} -eq 1 ]]; then
		log_info "--keep-build: staging conservata in ${STAGING_DIR}"
		return 0
	fi

	# Conserva solo le tre staging piu' recenti per edizione: ogni build crea una
	# directory nuova con il timestamp e i resti si accumulano in fretta.
	local keep=3 dir count=0
	local -a dirs=()
	while IFS= read -r dir; do
		[[ -n "${dir}" ]] || continue
		dirs+=("${dir}")
	done < <(find "${PRISMOS_BUILD_DIR}" -maxdepth 1 -type d -name "${edition}-*" \
		-newermt '1970-01-01' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

	for dir in "${dirs[@]:-}"; do
		[[ -n "${dir}" ]] || continue
		(( ++count )) || true
		if (( count > keep )); then
			log_debug "rimozione staging obsoleta: ${dir}"
			rm -rf "${dir}"
		fi
	done
}

# =============================================================================
# COSTRUZIONE DI UNA EDIZIONE
# =============================================================================
build_edition() {
	local edition="$1"

	log_banner \
		"prismOS Legacy build - edizione ${edition^^}" \
		"floor ISA: x86_64-SSE4.1 (no SSE4.2 / no POPCNT)" \
		"board: ${ARG_BOARD}   kernel: ${KERNEL_VERSION} (${KERNEL_SPLITCONFIG})"

	EDITION=""
	SELECTED_APP_IDS=()
	BUILD_STAMP="$(prismos_build_stamp)"
	STAGING_DIR="${PRISMOS_BUILD_DIR}/${edition}-${BUILD_STAMP}"
	ensure_dir "${STAGING_DIR}" "${PRISMOS_LOG_DIR}"
	PRISMOS_LOG_FILE="${PRISMOS_LOG_DIR}/build-${edition}-${BUILD_STAMP}.log"
	export PRISMOS_LOG_FILE
	log_info "log di build: ${PRISMOS_LOG_FILE}"

	load_edition_profile "${edition}"
	load_app_table "${edition}"

	if (( ${#APP_TABLE_IDS[@]} == 0 )); then
		log_warn "nessuna applicazione nel pool per l'edizione ${edition}"
	elif [[ -n "${ARG_APPS}" ]]; then
		select_apps_from_list "${ARG_APPS}"
	elif [[ ${ARG_USE_BUNDLE} -eq 1 || "${edition}" == "all" || ! -t 0 ]]; then
		if [[ ! -t 0 ]]; then
			log_info "stdin non interattivo: uso il bundle predefinito dell'edizione"
		fi
		select_apps_from_bundle "${edition}"
	else
		print_app_menu
		select_apps_interactive
	fi

	summarize_selection
	generate_shelf_json "${edition}"
	generate_edition_conf "${edition}"
	sync_overlays "${edition}"

	if [[ ${ARG_SYNC_ONLY} -eq 1 ]]; then
		log_ok "sincronizzazione completata (--sync-only): compilazione non richiesta"
		log_info "overlay di board : $(prismos_sdk_overlays_dir 2>/dev/null || echo '<cros_sdk non disponibile>')/overlay-${ARG_BOARD}"
		log_info "artefatti        : ${STAGING_DIR}"
		cleanup_build "${edition}"
		return 0
	fi

	apply_subsystem_boot_states
	run_setup_board
	run_build_packages
	run_build_image
	collect_image "${edition}"
	verify_build "${edition}"
	cleanup_build "${edition}"

	log_ok "edizione ${edition} completata"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
	parse_args "$@"

	log_banner \
		"prismOS ${PROG_VERSION} - ChromiumOS Legacy image builder" \
		"Target: CPU x86_64 senza SSE4.2 (Intel Pentium P6100 / Arrandale)" \
		"Sottosistemi: Waydroid (LineageOS 16.0 x86) + Wine/Proton - ARC rimosso"

	validate_environment
	ensure_dir "${PRISMOS_BUILD_DIR}" "${PRISMOS_OUTPUT_DIR}"

	local editions=()
	if [[ "${ARG_EDITION}" == "all" ]]; then
		editions=("${PRISMOS_EDITIONS[@]}")
		log_info "costruzione di tutte le edizioni: ${editions[*]}"
	else
		is_valid_edition "${ARG_EDITION}" || die 1 "edizione non valida: ${ARG_EDITION}"
		editions=("${ARG_EDITION}")
	fi

	local failed=()
	local ed
	for ed in "${editions[@]}"; do
		if ! build_edition "${ed}"; then
			log_error "edizione ${ed} fallita"
			failed+=("${ed}")
			if [[ "${ARG_EDITION}" != "all" ]]; then
				exit 1
			fi
		fi
	done

	log_banner "Esito della build"
	if (( ${#failed[@]} == 0 )); then
		printf '  %s%sTUTTE LE EDIZIONI COSTRUITE CON SUCCESSO%s\n' \
			"${PRISMOS_C_GREEN}" "${PRISMOS_C_BOLD}" "${PRISMOS_C_RESET}" >&2
		printf '  Output in: %s\n' "${PRISMOS_OUTPUT_DIR}" >&2
		local f
		for f in "${PRISMOS_OUTPUT_DIR}"/prismOS_*_legacy.img; do
			[[ -e "${f}" ]] || continue
			printf '    %s (%s)\n' "$(basename "${f}")" "$(bytes_human "$(stat -c '%s' "${f}")")" >&2
		done
		if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
			printf '\n  %sEsecuzione in --dry-run: nessuna immagine compilata.%s\n' \
				"${PRISMOS_C_YELLOW}" "${PRISMOS_C_RESET}" >&2
			printf '  Artefatti di configurazione disponibili in %s\n' "${PRISMOS_BUILD_DIR}" >&2
		fi
		exit 0
	else
		printf '  %s%sEDIZIONI FALLITE: %s%s\n' \
			"${PRISMOS_C_RED}" "${PRISMOS_C_BOLD}" "${failed[*]}" "${PRISMOS_C_RESET}" >&2
		exit 1
	fi
}

main "$@"
