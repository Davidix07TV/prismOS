#!/usr/bin/env bash
# =============================================================================
#  prismOS :: scripts/sync_overlays.sh
# -----------------------------------------------------------------------------
#  Strumento operativo per la sincronizzazione degli overlay prismOS nel
#  checkout di cros_sdk. E' il front-end da usare quando si modifica una overlay
#  e si vuole aggiornare l'albero di build SENZA ricompilare, oppure quando si
#  vuole verificare/ripulire lo stato dei collegamenti.
#
#  CHE COSA VIENE SINCRONIZZATO
#    1. src/overlays/prismOS                      link alla repository
#    2. src/overlays/overlay-prismos-common       link simbolico relativo
#    3. src/overlays/overlay-prismos-<edizione>   link simbolico relativo
#    4. src/overlays/overlay-prismos-active       link all'edizione corrente
#    5. src/overlays/overlay-<board>              COPIA MATERIALIZZATA con
#         profiles/base/parent   chromiumos + prismos-common + prismos-<ed>
#         make.conf              common -> edizione -> board
#         board/                 albero rootfs dell'edizione + shelf.json +
#                                edition.conf + policy Chromium + icone
#    6. src/third_party/kernel/v<X>/chromeos/config/chromiumos-x86_64/
#         prismos_legacy/        splitconfig del kernel
#
#  La board overlay e' una copia e non un link perche' i suoi file di profilo
#  vengono riscritti ad ogni edizione: un link simbolico inquinerebbe il
#  checkout della repository.
#
#  USO
#    sync_overlays.sh --edition <edu|home|work|slim|all>   sincronizza
#    sync_overlays.sh --check [--edition <ed>]             verifica lo stato
#    sync_overlays.sh --list                               elenca gli overlay
#    sync_overlays.sh --diff [--edition <ed>]              differenze SDK/repo
#    sync_overlays.sh --clean [--yes]                      rimuove i collegamenti
# =============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit extglob nullglob

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
# shellcheck source=scripts/lib/prismos_common.sh
source "$(dirname "${SCRIPT_PATH}")/lib/prismos_common.sh"
prismos_install_error_trap

readonly PROG="$(basename "${SCRIPT_PATH}")"
readonly PROG_VERSION="1.0.0"
readonly KERNEL_CONFIG_REL="chromeos/config/chromiumos-x86_64/prismos_legacy"

# --- opzioni ----------------------------------------------------------------------------
MODE="sync"
ARG_EDITION=""
ARG_SDK_DIR=""
ARG_BOARD="${PRISMOS_DEFAULT_BOARD}"
ARG_REPO_MOUNT="/mnt/host/source/src/overlays/prismOS"
ARG_COPY=0
ARG_DRY_RUN=0
ARG_YES=0
ARG_QUIET=0
MODE_EXPLICIT=0

SDK_OVERLAYS=""
SDK_KERNEL_ROOT=""

usage() {
	cat <<USAGE
${PRISMOS_C_BOLD}prismOS ${PROG_VERSION} - sincronizzazione degli overlay nel cros_sdk${PRISMOS_C_RESET}

USO
  ${PROG} --edition <edu|home|work|slim|all> [opzioni]   sincronizza
  ${PROG} --check [--edition <ed>]                       verifica lo stato
  ${PROG} --list                                         elenca gli overlay
  ${PROG} --diff [--edition <ed>]                        differenze SDK/repo
  ${PROG} --clean [--yes]                                rimuove i collegamenti

MODALITA'
  --edition ED       edizione da sincronizzare (obbligatoria per la sincronia);
                     'all' sincronizza le quattro edizioni in sequenza, lasciando
                     attiva l'ultima (slim)
  --check            verifica che collegamenti, parent, make.conf, splitconfig e
                     policy siano presenti e coerenti; non scrive nulla
  --list             elenca le overlay della repository e il loro stato nel SDK
  --diff             confronta la board overlay materializzata con la sorgente
                     della repository (utile in modalita' --copy-overlays)
  --clean            rimuove dal SDK i link prismOS, la board overlay copiata e
                     lo splitconfig del kernel; richiede --yes o conferma

OPZIONI
  --sdk-dir DIR      percorso del cros_sdk (default: \${CROS_SDK_DIR} oppure
                     ${PRISMOS_DEFAULT_SDK})
  --board NOME       board ChromiumOS (default: ${PRISMOS_DEFAULT_BOARD})
  --repo-mount PATH  percorso della repository visto da dentro il chroot
                     (default: ${ARG_REPO_MOUNT})
  --copy-overlays    copia le overlay invece di creare link simbolici
  --dry-run          mostra le azioni senza eseguirle
  --yes              non chiede conferme (per --clean)
  --verbose          log di debug
  -h, --help         questo messaggio
  -V, --version      versione

ESEMPI
  ${PROG} --edition home
  ${PROG} --edition all --copy-overlays
  ${PROG} --check --edition edu
  ${PROG} --clean --yes
  ${PROG} --list --sdk-dir ~/chromiumos/cros_sdk
USAGE
}

parse_args() {
	local modes=0
	while (( $# > 0 )); do
		case "$1" in
			--edition)        ARG_EDITION="${2:-}"; shift 2 ;;
			--edition=*)      ARG_EDITION="${1#*=}"; shift ;;
			--check)          MODE="check"; MODE_EXPLICIT=1; (( ++modes )) || true; shift ;;
			--list)           MODE="list"; MODE_EXPLICIT=1; (( ++modes )) || true; shift ;;
			--diff)           MODE="diff"; MODE_EXPLICIT=1; (( ++modes )) || true; shift ;;
			--clean)          MODE="clean"; MODE_EXPLICIT=1; (( ++modes )) || true; shift ;;
			--sdk-dir)        ARG_SDK_DIR="${2:-}"; shift 2 ;;
			--sdk-dir=*)      ARG_SDK_DIR="${1#*=}"; shift ;;
			--board)          ARG_BOARD="${2:-}"; shift 2 ;;
			--board=*)        ARG_BOARD="${1#*=}"; shift ;;
			--repo-mount)     ARG_REPO_MOUNT="${2:-}"; shift 2 ;;
			--repo-mount=*)   ARG_REPO_MOUNT="${1#*=}"; shift ;;
			--copy-overlays)  ARG_COPY=1; shift ;;
			--dry-run)        ARG_DRY_RUN=1; shift ;;
			--yes|-y)         ARG_YES=1; shift ;;
			--verbose)        PRISMOS_LOG_LEVEL="debug"; shift ;;
			-q|--quiet)       ARG_QUIET=1; PRISMOS_LOG_LEVEL="warn"; shift ;;
			-h|--help)        usage; exit 0 ;;
			-V|--version)     echo "${PROG} ${PROG_VERSION}"; exit 0 ;;
			--)               shift; break ;;
			-*)               usage >&2; die 2 "opzione sconosciuta: $1" ;;
			*)                usage >&2; die 2 "argomento inatteso: $1" ;;
		esac
	done

	if (( modes > 1 )); then
		die 2 "--check, --list, --diff e --clean sono mutuamente esclusivi"
	fi
	# --edition seleziona il bersaglio: in presenza di una modalita' esplicita
	# (--check/--diff) non implica la sincronizzazione.
	if [[ -n "${ARG_EDITION}" ]]; then
		if (( MODE_EXPLICIT == 0 )); then
			MODE="sync"
		fi
		if [[ "${ARG_EDITION}" != "all" ]]; then
			is_valid_edition "${ARG_EDITION}" || die 2 "edizione non valida: ${ARG_EDITION}"
		fi
	fi
}

# =============================================================================
# RISOLUZIONE DEI PERCORSI
# =============================================================================
resolve_paths() {
	PRISMOS_SDK_RESOLVED=""
	if prismos_in_chroot; then
		PRISMOS_SDK_RESOLVED="/mnt/host/source"
		SDK_OVERLAYS="/mnt/host/source/src/overlays"
		SDK_KERNEL_ROOT="/mnt/host/source/src/third_party/kernel"
	elif PRISMOS_SDK_RESOLVED="$(prismos_resolve_sdk "${ARG_SDK_DIR}")"; then
		SDK_OVERLAYS="$(dirname "${PRISMOS_SDK_RESOLVED}")/src/overlays"
		SDK_KERNEL_ROOT="$(dirname "${PRISMOS_SDK_RESOLVED}")/src/third_party/kernel"
	else
		PRISMOS_SDK_RESOLVED=""
		SDK_OVERLAYS=""
		SDK_KERNEL_ROOT=""
	fi
	export PRISMOS_SDK_RESOLVED

	if [[ -n "${SDK_OVERLAYS}" ]]; then
		log_debug "cros_sdk     : ${PRISMOS_SDK_RESOLVED}"
		log_debug "overlay dir  : ${SDK_OVERLAYS}"
		log_debug "kernel dir   : ${SDK_KERNEL_ROOT}"
	fi
}

# Edizione attualmente attiva nel SDK (letta dal link overlay-prismos-active).
detect_active_edition() {
	[[ -n "${SDK_OVERLAYS}" ]] || return 1
	local link="${SDK_OVERLAYS}/overlay-prismos-active"
	[[ -L "${link}" ]] || return 1
	local target
	target="$(readlink "${link}")"
	target="${target##*/}"
	# Derive the edition from the shared list instead of a hardcoded case, so
	# that new editions (PRO) are recognized without touching this function.
	local ed
	for ed in "${PRISMOS_EDITIONS[@]}"; do
		if [[ "${target}" == "overlay-prismos-${ed}" ]]; then
			echo "${ed}"
			return 0
		fi
	done
	return 1
}

kernel_version_for() {
	local edition="${1:-edu}"
	local conf="${PRISMOS_OVERLAYS_DIR}/overlay-prismos-common/make.conf"
	local version=""
	if [[ -f "${conf}" ]]; then
		version="$(bash -c 'set +u; CHROMEOS_KERNEL_VERSION=""; source "$1" >/dev/null 2>&1; printf "%s" "${CHROMEOS_KERNEL_VERSION}"' _ "${conf}" 2>/dev/null || true)"
	fi
	[[ -n "${version}" ]] || version="6.1"
	printf '%s' "${version}"
}

# =============================================================================
# --list
# =============================================================================
list_overlays() {
	log_banner "Overlay prismOS e stato nel cros_sdk"

	printf '\n  %-28s %-10s %s\n' "OVERLAY" "TIPO" "STATO NEL SDK" >&2
	printf '  %s\n' "--------------------------------------------------------------------------" >&2

	local ov name kind state link
	for ov in "${PRISMOS_OVERLAYS_DIR}"/overlay-*; do
		name="$(basename "${ov}")"
		case "${name}" in
			overlay-"${ARG_BOARD}") kind="board" ;;
			overlay-prismos-common) kind="comune" ;;
			overlay-prismos-*)      kind="edizione" ;;
			*)                      kind="ignoto" ;;
		esac

		if [[ -z "${SDK_OVERLAYS}" ]]; then
			state="${PRISMOS_C_DIM}cros_sdk non disponibile${PRISMOS_C_RESET}"
		else
			link="${SDK_OVERLAYS}/${name}"
			if [[ -L "${link}" ]]; then
				if [[ -d "${link}" ]]; then
					state="${PRISMOS_C_GREEN}link -> $(readlink "${link}")${PRISMOS_C_RESET}"
				else
					state="${PRISMOS_C_RED}link INTERROTTO -> $(readlink "${link}")${PRISMOS_C_RESET}"
				fi
			elif [[ -d "${link}" ]]; then
				state="${PRISMOS_C_YELLOW}copia materializzata${PRISMOS_C_RESET}"
			else
				state="${PRISMOS_C_DIM}assente${PRISMOS_C_RESET}"
			fi
		fi
		printf '  %-28s %-10s %b\n' "${name}" "${kind}" "${state}" >&2
	done

	# Link dell'edizione attiva.
	if [[ -n "${SDK_OVERLAYS}" ]]; then
		local active="${SDK_OVERLAYS}/overlay-prismos-active"
		if [[ -L "${active}" ]]; then
			printf '  %-28s %-10s %b\n' "overlay-prismos-active" "alias" \
				"${PRISMOS_C_CYAN}$(readlink "${active}")${PRISMOS_C_RESET}" >&2
		else
			printf '  %-28s %-10s %b\n' "overlay-prismos-active" "alias" \
				"${PRISMOS_C_DIM}assente${PRISMOS_C_RESET}" >&2
		fi
	fi

	# Splitconfig del kernel.
	local kver split
	kver="$(kernel_version_for)"
	split="${PRISMOS_KERNEL_DIR}/chromeos/config/chromiumos-x86_64/prismos_legacy"
	printf '\n  %s\n' "Splitconfig del kernel (v${kver})" >&2
	if [[ -d "${split}" ]]; then
		local frag count=0
		for frag in "${split}"/*.config; do
			[[ -e "${frag}" ]] || continue
			(( ++count )) || true
			printf '    %-24s %s righe\n' "$(basename "${frag}")" "$(grep -c '' "${frag}")" >&2
		done
		printf '    %s\n' "frammenti nella repository: ${count}" >&2
		if [[ -n "${SDK_KERNEL_ROOT}" && -d "${SDK_KERNEL_ROOT}/v${kver}/${KERNEL_CONFIG_REL}" ]]; then
			printf '    %b\n' "${PRISMOS_C_GREEN}presente nel SDK${PRISMOS_C_RESET}" >&2
		else
			printf '    %b\n' "${PRISMOS_C_YELLOW}non ancora copiato nel SDK${PRISMOS_C_RESET}" >&2
		fi
	else
		printf '    %b\n' "${PRISMOS_C_RED}splitconfig assente nella repository${PRISMOS_C_RESET}" >&2
	fi

	# Repository prismOS nel SDK.
	if [[ -n "${SDK_OVERLAYS}" ]]; then
		local repo_link="${SDK_OVERLAYS}/$(basename "${ARG_REPO_MOUNT%/}")"
		printf '\n  %s\n' "Repository prismOS nel SDK" >&2
		if [[ -L "${repo_link}" && -d "${repo_link}" ]]; then
			printf '    %b\n' "${PRISMOS_C_GREEN}${repo_link} -> $(readlink "${repo_link}")${PRISMOS_C_RESET}" >&2
		elif [[ -d "${repo_link}" ]]; then
			printf '    %b\n' "${PRISMOS_C_YELLOW}${repo_link} (directory reale, non un link)${PRISMOS_C_RESET}" >&2
		else
			printf '    %b\n' "${PRISMOS_C_DIM}${repo_link} assente${PRISMOS_C_RESET}" >&2
		fi
	fi
	printf '\n' >&2
}

# =============================================================================
# --check
# =============================================================================
check_state() {
	local edition="${1:-}"
	local rc=0

	log_banner "Verifica dello stato degli overlay nel cros_sdk"

	if [[ -z "${SDK_OVERLAYS}" ]]; then
		log_error "cros_sdk non trovato: indicare --sdk-dir <percorso>"
		return 2
	fi
	if [[ ! -d "${SDK_OVERLAYS}" ]]; then
		log_error "directory degli overlay inesistente: ${SDK_OVERLAYS}"
		return 2
	fi

	# 1. Repository prismOS raggiungibile.
	local repo_link="${SDK_OVERLAYS}/$(basename "${ARG_REPO_MOUNT%/}")"
	if [[ -d "${repo_link}/overlays" ]]; then
		log_ok "repository prismOS raggiungibile: ${repo_link}"
	else
		log_error "repository prismOS NON raggiungibile: ${repo_link}"
		rc=1
	fi

	# 2. Link delle overlay.
	local name link
	# Il glob include gia' overlay-prismos-common; l'alias -active e' verificato a parte.
	for link in "${SDK_OVERLAYS}"/overlay-prismos-*; do
		name="$(basename "${link}")"
		[[ "${name}" == "overlay-prismos-active" ]] && continue
		if [[ -d "${link}" ]]; then
			log_ok "${name} presente e risolvibile"
		else
			log_error "${name} assente o link interrotto"
			rc=1
		fi
	done

	# 3. Edizione attiva.
	local active=""
	if active="$(detect_active_edition)"; then
		log_ok "edizione attiva nel SDK: ${active}"
		if [[ -n "${edition}" && "${edition}" != "all" && "${edition}" != "${active}" ]]; then
			log_warn "l'edizione richiesta (${edition}) non coincide con l'attiva (${active})"
		fi
	else
		log_error "link overlay-prismos-active assente o non riconosciuto"
		rc=1
	fi
	[[ -n "${edition}" ]] || edition="${active}"

	# 4. Board overlay: parent, make.conf, albero rootfs.
	local board_overlay="${SDK_OVERLAYS}/overlay-${ARG_BOARD}"
	if [[ ! -d "${board_overlay}" ]]; then
		log_error "board overlay assente: ${board_overlay}"
		return 1
	fi
	if [[ -L "${board_overlay}" ]]; then
		log_warn "la board overlay e' un link simbolico: build_iso.sh la materializza ad ogni build"
	fi

	local parent="${board_overlay}/profiles/base/parent"
	if [[ -f "${parent}" ]]; then
		if grep -q "^prismos-common:base$" "${parent}"; then
			log_ok "parent del board include prismos-common:base"
		else
			log_error "parent del board non include prismos-common:base"
			rc=1
		fi
		if [[ -n "${edition}" ]] && grep -q "^prismos-${edition}:base$" "${parent}"; then
			log_ok "parent del board include prismos-${edition}:base"
		elif [[ -n "${edition}" ]]; then
			log_error "parent del board NON include prismos-${edition}:base"
			rc=1
		fi
		if grep -q "^chromiumos:" "${parent}"; then
			log_ok "parent del board aggancia il profilo chromiumos di base"
		else
			log_error "parent del board privo del profilo chromiumos"
			rc=1
		fi
	else
		log_error "profiles/base/parent mancante nella board overlay"
		rc=1
	fi

	local make="${board_overlay}/make.conf"
	if [[ -f "${make}" ]]; then
		local flag
		for flag in "-march=nehalem" "-mno-sse4.2" "-msse4.1" "-mno-popcnt"; do
			if grep -qF -- "${flag}" "${make}"; then
				log_ok "make.conf di board contiene ${flag}"
			else
				log_error "make.conf di board NON contiene ${flag}"
				rc=1
			fi
		done
		if grep -q "CHROMEOS_KERNEL_SPLITCONFIG=\"chromiumos-x86_64/prismos_legacy\"" "${make}"; then
			log_ok "make.conf di board seleziona lo splitconfig prismos_legacy"
		else
			log_error "make.conf di board non seleziona lo splitconfig prismos_legacy"
			rc=1
		fi
		local markers
		markers="$(grep -c '^# ---- overlay-' "${make}" || true)"
		if (( markers >= 2 )); then
			log_ok "make.conf di board concatenato (${markers} marcatori di sezione)"
		else
			log_error "make.conf di board non concatenato correttamente (${markers} marcatori)"
			rc=1
		fi
	else
		log_error "make.conf mancante nella board overlay"
		rc=1
	fi

	# 5. Artefatti della board overlay.
	local artifact
	for artifact in \
		"board/etc/skel/.config/chromiumos/shelf.json" \
		"board/etc/prismos/edition.conf" \
		"board/usr/share/prismos/app_pool.json" \
		"board/usr/share/prismos/ash-shelf.conf"
	do
		if [[ -f "${board_overlay}/${artifact}" ]]; then
			log_ok "artefatto presente: ${artifact}"
		else
			log_error "artefatto mancante: ${artifact}"
			rc=1
		fi
	done

	if [[ -f "${board_overlay}/board/etc/skel/.config/chromiumos/shelf.json" ]]; then
		if json_validate "${board_overlay}/board/etc/skel/.config/chromiumos/shelf.json"; then
			log_ok "shelf.json della board overlay valido"
		else
			log_error "shelf.json della board overlay NON valido"
			rc=1
		fi
	fi

	# 6. Policy attese per l'edizione.
	local policy="${board_overlay}/board/etc/chromium/policies/managed/prismos_policy.json"
	local dock_policy="${board_overlay}/board/etc/chromium/policies/managed/zz-prismos-dock.json"
	case "${edition}" in
		edu|work)
			if [[ -f "${policy}" ]]; then
				json_validate "${policy}" && log_ok "policy di edizione valida: prismos_policy.json" \
					|| { log_error "policy di edizione NON valida"; rc=1; }
			else
				log_warn "policy di edizione assente (attesa per ${edition}): Strada A oppure --policy-mode none"
			fi
			;;
		home|slim)
			if [[ -f "${policy}" ]]; then
				log_warn "policy di edizione presente per ${edition}: inattesa, verificare --policy-mode"
			else
				log_ok "nessuna policy di edizione per ${edition} (atteso)"
			fi
			;;
	esac
	if [[ -f "${dock_policy}" ]]; then
		json_validate "${dock_policy}" && log_ok "policy della Dock valida: zz-prismos-dock.json" \
			|| { log_error "policy della Dock NON valida"; rc=1; }
	else
		log_warn "policy della Dock assente: la shelf non sara' forzata in basso con autohide"
	fi

	# 7. Splitconfig del kernel.
	local kver split_dir
	kver="$(kernel_version_for "${edition}")"
	split_dir="${SDK_KERNEL_ROOT}/v${kver}/${KERNEL_CONFIG_REL}"
	if [[ -d "${split_dir}" ]]; then
		local frag count=0
		for frag in "${split_dir}"/*.config; do
			[[ -e "${frag}" ]] || continue
			(( ++count )) || true
		done
		log_ok "splitconfig presente nel SDK (v${kver}): ${count} frammenti"
		local repo_split="${PRISMOS_KERNEL_DIR}/chromeos/config/chromiumos-x86_64/prismos_legacy"
		local repo_count=0
		for frag in "${repo_split}"/*.config; do
			[[ -e "${frag}" ]] || continue
			(( ++repo_count )) || true
		done
		if (( count != repo_count )); then
			log_warn "numero di frammenti diverso dalla repository (${count} nel SDK, ${repo_count} nella repo)"
		fi
	else
		log_error "splitconfig assente nel SDK: ${split_dir}"
		rc=1
	fi

	# 8. Icone del tema.
	local icons_dir="${board_overlay}/board/usr/share/icons/prismOS-Squircle/apps/scalable"
	if [[ -d "${icons_dir}" ]]; then
		local icons=0 line
		while IFS= read -r line; do
			[[ -n "${line}" ]] && (( ++icons )) || true
		done < <(find "${icons_dir}" -name '*.svg' -type f 2>/dev/null)
		log_ok "tema di icone presente: ${icons} SVG"
	else
		log_warn "tema di icone assente: eseguire scripts/generate_app_icons.sh"
	fi

	printf '\n' >&2
	if (( rc == 0 )); then
		log_ok "stato degli overlay coerente per l'edizione ${edition:-<non determinata>}"
	else
		log_error "stato degli overlay con incongruenze: eseguire ${PROG} --edition <ed>"
	fi
	return "${rc}"
}

# =============================================================================
# --diff
# =============================================================================
diff_state() {
	local edition="${1:-}"
	[[ -n "${SDK_OVERLAYS}" ]] || die 2 "cros_sdk non disponibile: indicare --sdk-dir"

	local board_overlay="${SDK_OVERLAYS}/overlay-${ARG_BOARD}"
	local board_source="${PRISMOS_OVERLAYS_DIR}/overlay-${ARG_BOARD}"

	log_banner "Differenze fra board overlay nel SDK e repository"

	if [[ ! -d "${board_overlay}" ]]; then
		log_warn "board overlay assente nel SDK: ${board_overlay}"
		return 0
	fi

	have_cmd diff || die 2 "diff non disponibile"

	local rc=0
	log_step "File della board overlay"
	# La board overlay contiene artefatti generati (make.conf, parent, board/etc)
	# che per costruzione differiscono dalla sorgente: si mostra solo il riepilogo.
	if diff -rq --exclude=make.conf --exclude=parent --exclude=board \
		"${board_source}" "${board_overlay}" >&2; then
		log_ok "nessuna differenza nei file non generati"
	else
		log_warn "differenze rilevate nei file non generati (dettaglio sopra)"
		rc=1
	fi

	log_step "Albero rootfs dell'edizione"
	if [[ -n "${edition}" && "${edition}" != "all" ]]; then
		local edition_files="${PRISMOS_OVERLAYS_DIR}/overlay-prismos-${edition}/files"
		if [[ -d "${edition_files}" ]]; then
			if diff -rq "${edition_files}" "${board_overlay}/board" >&2; then
				log_ok "albero rootfs dell'edizione allineato"
			else
				log_info "l'albero rootfs della board contiene anche artefatti generati:"
				log_info "  shelf.json, edition.conf, policy, icone, app_pool.json"
			fi
		else
			log_warn "nessun albero files/ per l'edizione ${edition}"
		fi
	else
		log_info "indicare --edition <ed> per confrontare l'albero rootfs"
	fi

	log_step "Overlay delle edizioni"
	local name
	for name in common edu home work slim; do
		local src="${PRISMOS_OVERLAYS_DIR}/overlay-prismos-${name}"
		local dst="${SDK_OVERLAYS}/overlay-prismos-${name}"
		[[ -d "${src}" ]] || continue
		if [[ -L "${dst}" ]]; then
			if [[ "$(readlink -f "${dst}")" == "$(readlink -f "${src}")" ]]; then
				log_ok "overlay-prismos-${name}: link alla sorgente (nessuna divergenza possibile)"
			else
				log_warn "overlay-prismos-${name}: link verso $(readlink "${dst}")"
			fi
		elif [[ -d "${dst}" ]]; then
			if diff -rq "${src}" "${dst}" >/dev/null 2>&1; then
				log_ok "overlay-prismos-${name}: copia identica alla sorgente"
			else
				log_error "overlay-prismos-${name}: copia DIVERGENTE dalla sorgente"
				if [[ "${PRISMOS_LOG_LEVEL}" == "debug" ]]; then
					diff -rq "${src}" "${dst}" >&2 || true
				fi
				rc=1
			fi
		else
			log_warn "overlay-prismos-${name}: assente nel SDK"
		fi
	done

	return "${rc}"
}

# =============================================================================
# --clean
# =============================================================================
clean_state() {
	log_banner "Rimozione dei collegamenti prismOS dal cros_sdk"

	[[ -n "${SDK_OVERLAYS}" ]] || die 2 "cros_sdk non disponibile: indicare --sdk-dir"
	[[ -d "${SDK_OVERLAYS}" ]] || { log_warn "nulla da rimuovere: ${SDK_OVERLAYS} inesistente"; return 0; }

	local targets=()
	local name link
	for name in prismos-common prismos-edu prismos-home prismos-work prismos-slim prismos-active; do
		link="${SDK_OVERLAYS}/overlay-${name}"
		if [[ -e "${link}" || -L "${link}" ]]; then targets+=("${link}"); fi
	done
	local board_link="${SDK_OVERLAYS}/overlay-${ARG_BOARD}"
	local repo_link="${SDK_OVERLAYS}/$(basename "${ARG_REPO_MOUNT%/}")"
	if [[ -e "${board_link}" || -L "${board_link}" ]]; then targets+=("${board_link}"); fi
	if [[ -e "${repo_link}" || -L "${repo_link}" ]]; then targets+=("${repo_link}"); fi

	local kver split_dir
	kver="$(kernel_version_for)"
	split_dir="${SDK_KERNEL_ROOT}/v${kver}/${KERNEL_CONFIG_REL}"
	if [[ -d "${split_dir}" ]]; then targets+=("${split_dir}"); fi

	if (( ${#targets[@]} == 0 )); then
		log_info "nessun elemento prismOS presente in ${SDK_OVERLAYS}"
		return 0
	fi

	printf '\n  %sElementi che verranno rimossi:%s\n' "${PRISMOS_C_YELLOW}" "${PRISMOS_C_RESET}" >&2
	local t
	for t in "${targets[@]}"; do
		[[ -n "${t}" ]] || continue
		printf '    %s\n' "${t}" >&2
	done
	printf '\n' >&2

	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] nessuna rimozione eseguita"
		return 0
	fi

	if (( ARG_YES == 0 )); then
		if [[ ! -t 0 ]]; then
			die 2 "rimozione distruttiva: confermare con --yes (stdin non interattivo)"
		fi
		local answer=""
		read -r -p "Procedere con la rimozione? [s/N] " answer || answer=""
		case "${answer,,}" in
			s|si|sì|y|yes) ;;
			*) log_info "rimozione annullata"; return 0 ;;
		esac
	fi

	for t in "${targets[@]}"; do
		[[ -n "${t}" ]] || continue
		[[ -e "${t}" || -L "${t}" ]] || continue
		case "${t}" in
			*/src/overlays/*|*/src/third_party/kernel/*) ;;
			*) log_warn "percorso inatteso, non rimosso: ${t}"; continue ;;
		esac
		rm -rf "${t}"
		log_ok "rimosso: ${t}"
	done

	log_ok "pulizia completata: il checkout di ChromiumOS non contiene piu' riferimenti a prismOS"
}

# =============================================================================
# SYNC
# =============================================================================
do_sync() {
	local edition="$1"

	log_banner \
		"Sincronizzazione degli overlay prismOS" \
		"Edizione: ${edition}   Board: ${ARG_BOARD}" \
		"SDK: ${SDK_OVERLAYS:-<non disponibile>}"

	local args=( "${edition}" --sync-only --board "${ARG_BOARD}" --repo-mount "${ARG_REPO_MOUNT}" )
	if (( ARG_COPY == 1 )); then args+=( --copy-overlays ); fi
	if (( ARG_DRY_RUN == 1 )); then args+=( --dry-run ); fi
	if [[ -n "${ARG_SDK_DIR}" ]]; then args+=( --sdk-dir "${ARG_SDK_DIR}" ); fi
	if [[ "${PRISMOS_LOG_LEVEL}" == "debug" ]]; then args+=( --verbose ); fi

	# La selezione delle applicazioni non e' interattiva in questo strumento: si
	# usa il bundle di edizione. Per una selezione puntuale usare build_iso.sh.
	args+=( --bundle )

	log_info "delega a build_iso.sh ${args[*]}"
	"${PRISMOS_SCRIPTS_DIR}/build_iso.sh" "${args[@]}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
	parse_args "$@"
	resolve_paths

	# Senza --edition e senza una modalita' esplicita si riusa l'edizione attiva
	# nel SDK: il rilevamento richiede i percorsi appena risolti.
	if [[ "${MODE}" == "sync" && -z "${ARG_EDITION}" ]]; then
		local detected=""
		detected="$(detect_active_edition || true)"
		if [[ -z "${detected}" ]]; then
			usage >&2
			die 2 "indicare --edition <edu|home|work|slim|all> oppure una modalita' (--check/--list/--diff/--clean)"
		fi
		ARG_EDITION="${detected}"
		log_info "nessuna edizione indicata: uso l'edizione attiva nel SDK (${ARG_EDITION})"
	fi

	case "${MODE}" in
		list)
			list_overlays
			exit 0
			;;
		check)
			local rc=0
			check_state "${ARG_EDITION}" || rc=$?
			exit "${rc}"
			;;
		diff)
			local rc=0
			diff_state "${ARG_EDITION}" || rc=$?
			exit "${rc}"
			;;
		clean)
			clean_state
			exit 0
			;;
		sync)
			if [[ "${ARG_EDITION}" == "all" ]]; then
				local ed failed=()
				for ed in "${PRISMOS_EDITIONS[@]}"; do
					do_sync "${ed}" || failed+=("${ed}")
				done
				if (( ${#failed[@]} > 0 )); then
					log_error "sincronizzazione fallita per: ${failed[*]}"
					exit 1
				fi
				log_ok "tutte le edizioni sincronizzate; attiva nel SDK: slim (ultima)"
				exit 0
			fi
			do_sync "${ARG_EDITION}"
			exit 0
			;;
		*)
			die 2 "modalita' non riconosciuta: ${MODE}"
			;;
	esac
}

main "$@"
