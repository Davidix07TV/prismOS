#!/usr/bin/env bash
# =============================================================================
#  prismOS :: scripts/set_edu_policy.sh
# -----------------------------------------------------------------------------
#  Configurazione delle policy scolastiche dell'edizione EDU.
#
#  STRADA A - Cloud-Managed
#    Il dispositivo si iscrive alla Google Admin Console dell'istituto. Lo
#    script scrive in /etc/default/chromium-browser gli switch di Enterprise
#    Enrollment riconosciuti da Chromium (components/policy/policy_switches.cc):
#      --enterprise-enable-zero-touch-enrollment
#      --enterprise-enrollment-initial-modulus=<base64>          (opzionale)
#      --enterprise-enrollment-initial-modulus-length=<n>
#      --arc-availability=none
#    Nessuna policy JSON vincolante viene installata: la configurazione arriva
#    dal DM server dopo l'iscrizione. Con --with-domain-policy si aggiunge una
#    policy locale MINIMA (solo UserAllowlist e disattivazione ARC) per rendere
#    il dispositivo utilizzabile - e vincolato al dominio - prima che
#    l'iscrizione sia completata.
#
#  STRADA B - Local-Policy
#    Nessuna infrastruttura Google. Lo script scrive
#      /etc/chromium/policies/managed/prismos_policy.json
#    partendo dal template overlays/overlay-prismos-edu/chrome_policy.json,
#    sostituendo il dominio segnaposto con quello dell'istituto e componendo:
#      URLBlocklist  -> TikTok, YouTube, Twitch (+ CDN e shortener) ed eventuali
#                       ulteriori pattern passati con --blocklist
#      URLAllowlist  -> dominio scolastico e sottodomini, piu' i servizi
#                       didattici gia' presenti nel template e gli eventuali
#                       pattern passati con --allowlist
#      UserAllowlist -> *@<dominio> (rimovibile con --all-users)
#    Poiche' in Chromium la URLAllowlist ha PRECEDENZA sulla URLBlocklist, ogni
#    voce di allowlist che ricade in un dominio bloccato viene rimossa e
#    l'operazione viene registrata nel log.
#
#  DESTINAZIONI
#    --rootfs PATH   albero radice su cui operare: la directory board/ di una
#                    overlay, una rootfs montata con mount_image.sh, oppure
#                    /build/<board> dentro il chroot di cros_sdk
#    (nessuna opzione)
#                    se il sistema in esecuzione e' un prismOS EDU (esiste
#                    /etc/prismos/edition.conf) lo script opera dal vivo con
#                    sudo; altrimenti richiede --rootfs
#
#  USO
#    set_edu_policy.sh --strada a --domain istituto.edu [opzioni]
#    set_edu_policy.sh --strada b --domain istituto.edu [opzioni]
#    set_edu_policy.sh --show | --validate | --remove [opzioni]
# =============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit extglob nullglob

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
# shellcheck source=scripts/lib/prismos_common.sh
source "$(dirname "${SCRIPT_PATH}")/lib/prismos_common.sh"
prismos_install_error_trap

readonly PROG="$(basename "${SCRIPT_PATH}")"
readonly PROG_VERSION="2.0.0"

# Dominio segnaposto usato nel template delle policy e nei file di configurazione.
readonly TEMPLATE_DOMAIN="scuola.edu"
# Percorsi relativi alla radice target.
readonly REL_BROWSER_DEFAULTS="/etc/default/chromium-browser"
readonly REL_POLICY_DIR="/etc/chromium/policies/managed"
readonly REL_POLICY_FILE="/etc/chromium/policies/managed/prismos_policy.json"
# Branded builds (official Chrome, FydeOS, Chrome-branded ChromiumOS) read the
# managed policies from /etc/opt/chrome/policies, Chromium builds from
# /etc/chromium/policies (see Chromium docs/enterprise/policies.md). prismOS
# installs every policy in BOTH locations so the same image behaves identically
# on open-source ChromiumOS builds and on branded derivatives.
readonly REL_POLICY_DIR_BRANDED="/etc/opt/chrome/policies/managed"
readonly REL_POLICY_FILE_BRANDED="/etc/opt/chrome/policies/managed/prismos_policy.json"
readonly REL_EDITION_CONF="/etc/prismos/edition.conf"

# Pattern di blocco predefiniti della Strada B (distrazione didattica).
readonly DEFAULT_BLOCK_PATTERNS=(
	"*://tiktok.com/*"
	"*://*.tiktok.com/*"
	"*://*.tiktokcdn.com/*"
	"*://*.tiktokv.com/*"
	"*://*.musical.ly/*"
	"*://youtube.com/*"
	"*://*.youtube.com/*"
	"*://m.youtube.com/*"
	"*://music.youtube.com/*"
	"*://youtube-nocookie.com/*"
	"*://*.youtube-nocookie.com/*"
	"*://youtu.be/*"
	"*://*.youtu.be/*"
	"*://*.googlevideo.com/*"
	"*://*.ytimg.com/*"
	"*://twitch.tv/*"
	"*://*.twitch.tv/*"
	"*://twitch.com/*"
	"*://*.twitch.com/*"
	"*://*.ttvnw.net/*"
	"*://*.jtvnw.net/*"
)

# --- opzioni ----------------------------------------------------------------------------
ARG_STRADA=""
ARG_DOMAIN="${TEMPLATE_DOMAIN}"
ARG_TEMPLATE_DOMAIN="${TEMPLATE_DOMAIN}"
ARG_ALLOWLIST=()
ARG_BLOCKLIST=()
ARG_NO_DEFAULT_BLOCKLIST=0
ARG_ALL_USERS=0
ARG_WITH_DOMAIN_POLICY=0
ARG_DM_MODULUS=""
ARG_DM_MODULUS_LENGTH=""
ARG_ROOTFS=""
ARG_POLICY_TEMPLATE=""
ARG_BROWSER_TEMPLATE=""
ARG_BACKUP=1
ARG_DRY_RUN=0
ARG_SHOW=0
ARG_VALIDATE=0
ARG_REMOVE=0
ARG_RESTART_UI=0
ARG_JSON_OUT=""

# --- stato ------------------------------------------------------------------------------
TARGET_ROOT=""
PRIVILEGED=""
LIVE_MODE=0
WORK_DIR=""

usage() {
	cat <<USAGE
${PRISMOS_C_BOLD}prismOS ${PROG_VERSION} - policy scolastiche dell'edizione EDU${PRISMOS_C_RESET}

USO
  ${PROG} --strada <a|b> --domain <dominio> [opzioni]
  ${PROG} --show | --validate | --remove [opzioni]

STRADA (obbligatoria salvo --show/--validate/--remove)
  --strada a             Cloud-Managed: Enterprise Enrollment via Google Admin
  --strada b             Local-Policy: JSON in ${REL_POLICY_FILE}

IDENTITA' DELL'ISTITUTO
  --domain DOMINIO       dominio istituzionale (default: ${TEMPLATE_DOMAIN})
                         usato per URLAllowlist, UserAllowlist e per sostituire
                         il segnaposto nel template
  --template-domain D    dominio segnaposto presente nel template, se diverso
                         da ${TEMPLATE_DOMAIN}
  --all-users            non impone UserAllowlist "*@<dominio>" (Strada B)

STRADA A - Enterprise Enrollment
  --dm-modulus BASE64    modulo RSA iniziale del DM server
                         (--enterprise-enrollment-initial-modulus)
  --dm-modulus-length N  lunghezza del modulo iniziale
                         (--enterprise-enrollment-initial-modulus-length)
  --with-domain-policy   scrive anche una policy locale minima (UserAllowlist e
                         ArcEnabled=false) per il periodo precedente
                         l'iscrizione; ha precedenza sulle policy cloud

STRADA B - contenuti della policy
  --allowlist "URL URL"  pattern aggiuntivi da consentire (es. "*://*.miur.it/*")
  --blocklist "URL URL"  pattern aggiuntivi da bloccare (es. "*://*.badoo.com/*")
  --no-default-blocklist non include TikTok/YouTube/Twitch: usa solo --blocklist
  --policy-template F    template JSON alternativo
                         (default: overlays/overlay-prismos-edu/chrome_policy.json)

DESTINAZIONE
  --rootfs PATH          albero radice: board/ di una overlay, rootfs montata o
                         /build/<board> nel chroot. Senza questa opzione lo
                         script opera dal vivo su un prismOS EDU (con sudo)
  --browser-template F   template di ${REL_BROWSER_DEFAULTS}
                         (default: overlays/overlay-prismos-edu/files${REL_BROWSER_DEFAULTS})
  --json-out FILE        scrive la policy generata anche in FILE (staging di build)

COMPORTAMENTO
  --no-backup            non creare il backup .prismos-bak-<timestamp>
  --restart-ui           al termine riavvia la sessione grafica (solo dal vivo)
  --dry-run              mostra cosa verrebbe scritto senza toccare il disco
  --show                 riepiloga la configurazione EDU attualmente installata
  --validate             valida la policy installata (sintassi e conflitti
                         allowlist/blocklist)
  --remove               rimuove la policy locale e riporta la Strada A pura
  -h, --help             questo messaggio
  -V, --version          versione

ESEMPI
  # Dispositivo di laboratorio iscritto alla Admin Console di liceo-fermi.edu
  ${PROG} --strada a --domain liceo-fermi.edu --rootfs /build/amd64-prismos

  # Aula senza infrastruttura Google: blocco social, allowlist della scuola
  ${PROG} --strada b --domain ic-manzi.edu --allowlist "*://*.ic-manzi.edu/*"

  # Solo TikTok e Twitch bloccati, nessun vincolo sugli account
  ${PROG} --strada b --domain ic-manzi.edu --all-users \\
      --blocklist "*://*.tiktok.com/* *://*.twitch.tv/*" --no-default-blocklist

  # Verifica di quanto installato su un dispositivo acceso
  ${PROG} --show
  ${PROG} --validate
USAGE
}

# =============================================================================
# ARGOMENTI
# =============================================================================
parse_args() {
	while (( $# > 0 )); do
		case "$1" in
			--strada)              ARG_STRADA="${2:-}"; shift 2 ;;
			--strada=*)            ARG_STRADA="${1#*=}"; shift ;;
			-a|--strada-a)         ARG_STRADA="a"; shift ;;
			-b|--strada-b)         ARG_STRADA="b"; shift ;;
			--domain)              ARG_DOMAIN="${2:-}"; shift 2 ;;
			--domain=*)            ARG_DOMAIN="${1#*=}"; shift ;;
			--template-domain)     ARG_TEMPLATE_DOMAIN="${2:-}"; shift 2 ;;
			--template-domain=*)   ARG_TEMPLATE_DOMAIN="${1#*=}"; shift ;;
			--allowlist)           read -r -a ARG_ALLOWLIST <<< "${2:-}"; shift 2 ;;
			--allowlist=*)         read -r -a ARG_ALLOWLIST <<< "${1#*=}"; shift ;;
			--blocklist)           read -r -a ARG_BLOCKLIST <<< "${2:-}"; shift 2 ;;
			--blocklist=*)         read -r -a ARG_BLOCKLIST <<< "${1#*=}"; shift ;;
			--no-default-blocklist) ARG_NO_DEFAULT_BLOCKLIST=1; shift ;;
			--all-users)           ARG_ALL_USERS=1; shift ;;
			--with-domain-policy)  ARG_WITH_DOMAIN_POLICY=1; shift ;;
			--dm-modulus)          ARG_DM_MODULUS="${2:-}"; shift 2 ;;
			--dm-modulus=*)        ARG_DM_MODULUS="${1#*=}"; shift ;;
			--dm-modulus-length)   ARG_DM_MODULUS_LENGTH="${2:-}"; shift 2 ;;
			--dm-modulus-length=*) ARG_DM_MODULUS_LENGTH="${1#*=}"; shift ;;
			--rootfs)              ARG_ROOTFS="${2:-}"; shift 2 ;;
			--rootfs=*)            ARG_ROOTFS="${1#*=}"; shift ;;
			--policy-template)     ARG_POLICY_TEMPLATE="${2:-}"; shift 2 ;;
			--policy-template=*)   ARG_POLICY_TEMPLATE="${1#*=}"; shift ;;
			--browser-template)    ARG_BROWSER_TEMPLATE="${2:-}"; shift 2 ;;
			--browser-template=*)  ARG_BROWSER_TEMPLATE="${1#*=}"; shift ;;
			--json-out)            ARG_JSON_OUT="${2:-}"; shift 2 ;;
			--json-out=*)          ARG_JSON_OUT="${1#*=}"; shift ;;
			--no-backup)           ARG_BACKUP=0; shift ;;
			--restart-ui)          ARG_RESTART_UI=1; shift ;;
			--dry-run)             ARG_DRY_RUN=1; shift ;;
			--show)                ARG_SHOW=1; shift ;;
			--validate)            ARG_VALIDATE=1; shift ;;
			--remove)              ARG_REMOVE=1; shift ;;
			-h|--help)             usage; exit 0 ;;
			-V|--version)          echo "${PROG} ${PROG_VERSION}"; exit 0 ;;
			--)                    shift; break ;;
			-*)                    usage >&2; die 1 "opzione sconosciuta: $1" ;;
			*)                     usage >&2; die 1 "argomento inatteso: $1" ;;
		esac
	done

	local mutually=0
	(( mutually += ARG_SHOW )) || true
	(( mutually += ARG_VALIDATE )) || true
	(( mutually += ARG_REMOVE )) || true
	if (( mutually > 1 )); then
		die 1 "--show, --validate e --remove sono mutuamente esclusivi"
	fi

	ARG_STRADA="${ARG_STRADA,,}"
	case "${ARG_STRADA}" in
		a|cloud|cloud-managed)   ARG_STRADA="a" ;;
		b|local|local-policy)    ARG_STRADA="b" ;;
		"")
			if (( mutually == 0 )); then
				usage >&2
				die 1 "indicare --strada a (Cloud-Managed) oppure --strada b (Local-Policy)"
			fi
			;;
		*) die 1 "--strada accetta solo 'a' (Cloud-Managed) o 'b' (Local-Policy): ricevuto '${ARG_STRADA}'" ;;
	esac

	if [[ ${ARG_WITH_DOMAIN_POLICY} -eq 1 && "${ARG_STRADA}" != "a" ]]; then
		log_warn "--with-domain-policy ha effetto solo in Strada A: in Strada B la policy locale e' gia' completa"
		ARG_WITH_DOMAIN_POLICY=0
	fi
	if [[ -n "${ARG_DM_MODULUS}${ARG_DM_MODULUS_LENGTH}" && "${ARG_STRADA}" != "a" ]]; then
		log_warn "--dm-modulus e --dm-modulus-length valgono solo in Strada A: ignorati"
	fi
	if [[ ${ARG_NO_DEFAULT_BLOCKLIST} -eq 1 && ${#ARG_BLOCKLIST[@]} -eq 0 && "${ARG_STRADA}" == "b" ]]; then
		log_warn "--no-default-blocklist senza --blocklist: la URLBlocklist del template restera' invariata"
	fi
	if [[ ${ARG_DOMAIN} == */* || ${ARG_DOMAIN} == *[[:space:]]* ]]; then
		die 1 "--domain richiede un nome di dominio, non un URL: '${ARG_DOMAIN}'"
	fi
	if [[ -n "${ARG_DM_MODULUS_LENGTH}" ]] && ! [[ "${ARG_DM_MODULUS_LENGTH}" =~ ^[0-9]+$ ]]; then
		die 1 "--dm-modulus-length richiede un intero: '${ARG_DM_MODULUS_LENGTH}'"
	fi
}

# =============================================================================
# RISOLUZIONE DELLA DESTINAZIONE
# =============================================================================
resolve_target() {
	if [[ -n "${ARG_ROOTFS}" ]]; then
		[[ -d "${ARG_ROOTFS}" ]] || die 1 "--rootfs inesistente: ${ARG_ROOTFS}"
		TARGET_ROOT="$(cd "${ARG_ROOTFS}" && pwd)"
		# Una overlay prismOS espone l'albero radice nella sottodirectory board/.
		if [[ -d "${TARGET_ROOT}/board/etc" && ! -d "${TARGET_ROOT}/etc" ]]; then
			log_info "--rootfs punta a una overlay: uso l'albero ${TARGET_ROOT}/board"
			TARGET_ROOT="${TARGET_ROOT}/board"
		fi
		LIVE_MODE=0
		PRIVILEGED=""
		log_ok "destinazione (rootfs): ${TARGET_ROOT}"
		return 0
	fi

	if [[ -f "${REL_EDITION_CONF}" ]] || [[ -f /etc/prismos/prismos.conf ]]; then
		LIVE_MODE=1
		TARGET_ROOT=""
		if [[ "$(id -u)" -eq 0 ]]; then
			PRIVILEGED=""
		elif have_cmd sudo; then
			PRIVILEGED="sudo"
		else
			die 1 "servono i privilegi di root: usare sudo oppure --rootfs <albero>"
		fi
		local edition="sconosciuta"
		if [[ -f "${REL_EDITION_CONF}" ]]; then
			edition="$(. "${REL_EDITION_CONF}" 2>/dev/null && echo "${PRISMOS_EDITION_ID:-sconosciuta}")" || edition="sconosciuta"
		fi
		log_ok "destinazione (sistema live): / - edizione rilevata: ${edition}"
		if [[ "${edition}" != "edu" && "${edition}" != "sconosciuta" ]]; then
			log_warn "il sistema non e' un prismOS EDU (edizione '${edition}'): le policy scolastiche"
			log_warn "restano applicabili ma potrebbero confliggere con la configurazione di edizione"
		fi
		return 0
	fi

	die 1 "nessun prismOS rilevato sul sistema in esecuzione: indicare --rootfs <albero radice>"
}

target_path() { printf '%s%s' "${TARGET_ROOT}" "$1"; }

# Scrittura privilegiata e atomica di un file preparato in WORK_DIR.
install_file() {
	local src="$1" dst="$2" mode="${3:-0644}"

	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] ${dst}  ($(stat -c '%s' "${src}" 2>/dev/null || echo 0) byte, modo ${mode})"
		return 0
	fi

	if [[ ${ARG_BACKUP} -eq 1 && -e "${dst}" ]]; then
		local bak="${dst}.prismos-bak-$(date -u '+%Y%m%d%H%M%S')"
		if [[ -n "${PRIVILEGED}" ]]; then
			${PRIVILEGED} cp -a "${dst}" "${bak}" || log_warn "backup non riuscito: ${bak}"
		else
			cp -a "${dst}" "${bak}" || log_warn "backup non riuscito: ${bak}"
		fi
		log_info "backup: ${bak}"
	fi

	local dst_dir
	dst_dir="$(dirname "${dst}")"
	if [[ -n "${PRIVILEGED}" ]]; then
		${PRIVILEGED} install -D -m "${mode}" "${src}" "${dst}" || die 1 "scrittura fallita: ${dst}"
	else
		install -D -m "${mode}" "${src}" "${dst}" || die 1 "scrittura fallita: ${dst}"
	fi
	log_ok "scritto: ${dst}"
}

# Restituisce il file di policy realmente presente: prima il percorso Chromium,
# poi quello branded; se nessuno esiste, il percorso Chromium primario.
policy_file_primary() {
	local candidate
	for candidate in "${REL_POLICY_FILE}" "${REL_POLICY_FILE_BRANDED}"; do
		if [[ -f "$(target_path "${candidate}")" ]]; then
			printf '%s\n' "$(target_path "${candidate}")"
			return 0
		fi
	done
	printf '%s\n' "$(target_path "${REL_POLICY_FILE}")"
	return 0
}

# Copia la policy appena installata anche nel percorso branded.
mirror_policy_branded() {
	local src="$1" dst
	dst="$(target_path "${REL_POLICY_FILE_BRANDED}")"
	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] mirror branded: ${dst}"
		return 0
	fi
	install -D -m 0644 "${src}" "${dst}" 2>/dev/null || \
		${PRIVILEGED} install -D -m 0644 "${src}" "${dst}" || {
			log_warn "mirror branded non riuscito: ${dst}"
			return 1
		}
	log_ok "policy installata anche nel percorso branded: ${dst}"
	return 0
}

remove_file() {
	local dst="$1"
	[[ -e "${dst}" ]] || { log_info "assente, nulla da rimuovere: ${dst}"; return 0; }
	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] rimozione di ${dst}"
		return 0
	fi
	if [[ ${ARG_BACKUP} -eq 1 ]]; then
		local bak="${dst}.prismos-bak-$(date -u '+%Y%m%d%H%M%S')"
		if [[ -n "${PRIVILEGED}" ]]; then
			${PRIVILEGED} cp -a "${dst}" "${bak}" || log_warn "backup non riuscito: ${bak}"
		else
			cp -a "${dst}" "${bak}" || log_warn "backup non riuscito: ${bak}"
		fi
		log_info "backup: ${bak}"
	fi
	if [[ -n "${PRIVILEGED}" ]]; then
		${PRIVILEGED} rm -f "${dst}" || die 1 "rimozione fallita: ${dst}"
	else
		rm -f "${dst}" || die 1 "rimozione fallita: ${dst}"
	fi
	log_ok "rimosso: ${dst}"
}

# =============================================================================
# TEMPLATE
# =============================================================================
resolve_templates() {
	if [[ -z "${ARG_POLICY_TEMPLATE}" ]]; then
		ARG_POLICY_TEMPLATE="${PRISMOS_ROOT}/overlays/overlay-prismos-edu/chrome_policy.json"
	fi
	if [[ -z "${ARG_BROWSER_TEMPLATE}" ]]; then
		ARG_BROWSER_TEMPLATE="${PRISMOS_ROOT}/overlays/overlay-prismos-edu/files${REL_BROWSER_DEFAULTS}"
	fi

	# In assenza della repository (dispositivo in produzione) si ripiega sui file
	# installati dall'immagine, se presenti.
	if [[ ! -f "${ARG_POLICY_TEMPLATE}" ]]; then
		local installed
		for installed in \
			"$(target_path /usr/share/prismos/chrome_policy.json)" \
			/usr/share/prismos/chrome_policy.json \
			"$(target_path "${REL_POLICY_FILE}")" \
			"${REL_POLICY_FILE}"
		do
			if [[ -f "${installed}" ]]; then
				log_warn "template della repository assente: uso ${installed}"
				ARG_POLICY_TEMPLATE="${installed}"
				break
			fi
		done
	fi

	if [[ ! -f "${ARG_BROWSER_TEMPLATE}" ]]; then
		local installed_browser
		for installed_browser in \
			"$(target_path "${REL_BROWSER_DEFAULTS}")" \
			"${REL_BROWSER_DEFAULTS}"
		do
			if [[ -f "${installed_browser}" ]]; then
				log_warn "template di chromium-browser assente: uso ${installed_browser}"
				ARG_BROWSER_TEMPLATE="${installed_browser}"
				break
			fi
		done
	fi

	log_debug "template policy   : ${ARG_POLICY_TEMPLATE}"
	log_debug "template chromium : ${ARG_BROWSER_TEMPLATE}"
}

# =============================================================================
# STRADA A / STRADA B :: /etc/default/chromium-browser
# =============================================================================
write_browser_defaults() {
	local mode="$1"
	local out="${WORK_DIR}/chromium-browser"

	log_step "Generazione di ${REL_BROWSER_DEFAULTS} (Strada ${mode^^})"

	if [[ ! -f "${ARG_BROWSER_TEMPLATE}" ]]; then
		die 1 "template di ${REL_BROWSER_DEFAULTS} non trovato: ${ARG_BROWSER_TEMPLATE}"
	fi

	cp -f "${ARG_BROWSER_TEMPLATE}" "${out}"

	# 1. Identita' dell'edizione e dominio istituzionale.
	sed -i \
		-e "s|^PRISMOS_EDU_MODE=.*|PRISMOS_EDU_MODE=\"${mode}\"|" \
		-e "s|^PRISMOS_EDU_DOMAIN=.*|PRISMOS_EDU_DOMAIN=\"${ARG_DOMAIN}\"|" \
		"${out}"

	# 2. Modulo RSA del DM server (Strada A).
	if [[ "${mode}" == "cloud" && -n "${ARG_DM_MODULUS}" ]]; then
		sed -i -e "s|^PRISMOS_EDU_DM_MODULUS=.*|PRISMOS_EDU_DM_MODULUS=\"${ARG_DM_MODULUS}\"|" "${out}"
		log_info "modulo DM server impostato (${#ARG_DM_MODULUS} caratteri base64)"
	fi
	if [[ "${mode}" == "cloud" && -n "${ARG_DM_MODULUS_LENGTH}" ]]; then
		sed -i -e "s|--enterprise-enrollment-initial-modulus-length=[0-9]*|--enterprise-enrollment-initial-modulus-length=${ARG_DM_MODULUS_LENGTH}|g" "${out}"
		log_info "lunghezza del modulo iniziale: ${ARG_DM_MODULUS_LENGTH}"
	fi

	# 3. In Strada B l'enrollment automatico deve restare spento: il dispositivo
	#    non ha un DM server di riferimento.
	if [[ "${mode}" == "local" ]]; then
		sed -i \
			-e 's|--enterprise-enable-zero-touch-enrollment||g' \
			-e 's|--enterprise-enrollment-initial-modulus-length=[0-9]*||g' \
			-e 's|--enterprise-enrollment-initial-modulus=[^ "]*||g' \
			"${out}"
		# --arc-availability=none resta: e' indipendente dalla modalita' di gestione.
		log_info "switch di Enterprise Enrollment rimossi (Strada B: gestione locale)"
	fi

	# 4. Pulizia degli spazi doppi introdotti dalle sostituzioni.
	sed -i -e 's|  \\| \\|g' -e 's|[[:space:]]\+$||' "${out}"

	bash -n "${out}" || die 1 "il file ${REL_BROWSER_DEFAULTS} generato non e' bash valido"

	# Verifica che i flag richiesti siano effettivamente presenti.
	if [[ "${mode}" == "cloud" ]]; then
		grep -q -- "--enterprise-enable-zero-touch-enrollment" "${out}" || \
			die 1 "switch --enterprise-enable-zero-touch-enrollment assente dal template"
		grep -q -- "--arc-availability=none" "${out}" || \
			log_warn "--arc-availability=none assente: ARC non viene disattivato a riga di comando"
	fi
	grep -q -- "--ash-shelf-alignment=bottom" "${out}" || \
		log_warn "flag della Dock assenti: la shelf non sara' bassa e centrata"

	install_file "${out}" "$(target_path "${REL_BROWSER_DEFAULTS}")" 0644

	if [[ -n "${ARG_JSON_OUT}" ]]; then
		ensure_dir "$(dirname "${ARG_JSON_OUT}")" 2>/dev/null || true
		cp -f "${out}" "$(dirname "${ARG_JSON_OUT}")/chromium-browser" 2>/dev/null || true
	fi
}

# =============================================================================
# STRADA B :: policy JSON
# =============================================================================
write_policy_json() {
	local variant="${1:-full}"   # full | minimal
	local out="${WORK_DIR}/prismos_policy.json"
	local template="${ARG_POLICY_TEMPLATE}"

	log_step "Generazione di ${REL_POLICY_FILE} (Strada B, variante ${variant})"

	[[ -f "${template}" ]] || die 1 "template delle policy non trovato: ${template}"
	json_validate "${template}" || die 1 "template delle policy non valido: ${template}"

	local allow_arg="" block_arg=""
	allow_arg="${ARG_ALLOWLIST[*]:-}"
	if (( ARG_NO_DEFAULT_BLOCKLIST == 0 )); then
		block_arg="${DEFAULT_BLOCK_PATTERNS[*]} ${ARG_BLOCKLIST[*]:-}"
	else
		block_arg="${ARG_BLOCKLIST[*]:-}"
	fi

	PRISMOS_EDU_TEMPLATE="${template}" \
	PRISMOS_EDU_VARIANT="${variant}" \
	PRISMOS_EDU_DOMAIN="${ARG_DOMAIN}" \
	PRISMOS_EDU_TEMPLATE_DOMAIN="${ARG_TEMPLATE_DOMAIN}" \
	PRISMOS_EDU_ALLOWLIST="${allow_arg}" \
	PRISMOS_EDU_BLOCKLIST="${block_arg}" \
	PRISMOS_EDU_ALL_USERS="${ARG_ALL_USERS}" \
	python3 - "${out}" <<'PY'
import json, os, re, sys

target = sys.argv[1]
template = os.environ["PRISMOS_EDU_TEMPLATE"]
variant = os.environ["PRISMOS_EDU_VARIANT"]
domain = os.environ["PRISMOS_EDU_DOMAIN"].strip().lower()
tpl_domain = os.environ["PRISMOS_EDU_TEMPLATE_DOMAIN"].strip().lower()
allow_extra = os.environ["PRISMOS_EDU_ALLOWLIST"].split()
block_extra = os.environ["PRISMOS_EDU_BLOCKLIST"].split()
all_users = os.environ["PRISMOS_EDU_ALL_USERS"] == "1"

with open(template, encoding="utf-8") as fh:
    policy = json.load(fh)


def substitute_domain(value):
    """Sostituisce il dominio segnaposto in ogni stringa del documento."""
    if isinstance(value, str):
        return re.sub(re.escape(tpl_domain), domain, value, flags=re.IGNORECASE)
    if isinstance(value, list):
        return [substitute_domain(v) for v in value]
    if isinstance(value, dict):
        return {k: substitute_domain(v) for k, v in value.items()}
    return value


policy = substitute_domain(policy)

if variant == "minimal":
    # Strada A con --with-domain-policy: solo i vincoli che devono valere prima
    # dell'iscrizione al DM server.
    minimal = {
        "UserAllowlist": ["*@%s" % domain],
        "ArcEnabled": False,
        "ArcPolicy": "none",
        "UnaffiliatedArcAllowed": False,
        "UnaffiliatedDeviceArcAllowed": False,
        "DeviceGuestModeEnabled": False,
        "BrowserGuestModeEnabled": False,
        "VirtualMachinesAllowed": False,
        "DeviceUnaffiliatedCrostiniAllowed": False,
        "CrostiniAllowed": False,
    }
    if all_users:
        minimal.pop("UserAllowlist")
    with open(target, "w", encoding="utf-8") as fh:
        json.dump(minimal, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print("policy minima: %d chiavi" % len(minimal))
    sys.exit(0)

# --- URLAllowlist -------------------------------------------------------------------
allow = list(policy.get("URLAllowlist", []))
school_patterns = [
    "*://%s/*" % domain,
    "*://%s" % domain,
    "*://*.%s" % domain,
    "*://*.%s/*" % domain,
]
for pattern in school_patterns + allow_extra:
    if pattern and pattern not in allow:
        allow.append(pattern)

# --- URLBlocklist -------------------------------------------------------------------
block = list(policy.get("URLBlocklist", []))
for pattern in block_extra:
    if pattern and pattern not in block:
        block.append(pattern)

# La URLAllowlist ha precedenza sulla URLBlocklist: ogni voce consentita che
# ricade in un dominio bloccato annullerebbe il blocco e va quindi rimossa.
def host_of(pattern):
    m = re.match(r"^(?:\*://|https?://|\*://)?([^/]+)", pattern)
    if not m:
        return ""
    return m.group(1).lstrip("*.").lower()

blocked_hosts = {host_of(p) for p in block if host_of(p)}
shadowed = []
kept_allow = []
for pattern in allow:
    host = host_of(pattern)
    conflicts = any(host == bh or host.endswith("." + bh) or bh.endswith("." + host)
                    for bh in blocked_hosts if bh)
    if conflicts and pattern not in school_patterns:
        shadowed.append(pattern)
    else:
        kept_allow.append(pattern)

policy["URLAllowlist"] = kept_allow
policy["URLBlocklist"] = block

# Coerenza del blocco copia/incolla con la blocklist principale.
copy_paste = policy.get("URLBlockedForCopyPaste", [])
policy["URLBlockedForCopyPaste"] = [p for p in copy_paste if p in block] or copy_paste

# --- Vincolo sugli account -----------------------------------------------------------
if all_users:
    policy.pop("UserAllowlist", None)
else:
    policy["UserAllowlist"] = ["*@%s" % domain]

# --- URL di avvio --------------------------------------------------------------------
startup = policy.get("RestoreOnStartupURLs")
if isinstance(startup, list) and startup:
    policy["RestoreOnStartupURLs"] = startup

with open(target, "w", encoding="utf-8") as fh:
    json.dump(policy, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

sys.stderr.write("dominio: %s | allowlist: %d voci | blocklist: %d voci\n"
                 % (domain, len(kept_allow), len(block)))
if shadowed:
    sys.stderr.write("rimosse %d voci di allowlist in conflitto con la blocklist:\n" % len(shadowed))
    for pattern in shadowed:
        sys.stderr.write("  - %s\n" % pattern)
PY

	json_validate "${out}" || die 1 "la policy generata non e' JSON valido"

	install_file "${out}" "$(target_path "${REL_POLICY_FILE}")" 0644
	mirror_policy_branded "$(target_path "${REL_POLICY_FILE}")" || true

	if [[ -n "${ARG_JSON_OUT}" ]]; then
		ensure_dir "$(dirname "${ARG_JSON_OUT}")"
		cp -f "${out}" "${ARG_JSON_OUT}"
		log_ok "copia della policy in ${ARG_JSON_OUT}"
	fi
}

# =============================================================================
# AZIONI
# =============================================================================
apply_strada_a() {
	log_banner \
		"prismOS EDU - Strada A (Cloud-Managed)" \
		"Dominio istituzionale: ${ARG_DOMAIN}" \
		"Iscrizione: Google Admin Console tramite Enterprise Enrollment"

	write_browser_defaults "cloud"

	if (( ARG_WITH_DOMAIN_POLICY == 1 )); then
		write_policy_json "minimal"
		log_warn "policy locale minima installata: ha PRECEDENZA sulle policy cloud"
		log_warn "per le chiavi che definisce (UserAllowlist, ArcEnabled, guest, VM)"
	else
		local existing
		existing="$(policy_file_primary)"
		if [[ -f "${existing}" ]]; then
			log_warn "trovata una policy locale di una precedente Strada B: ${existing}"
			log_warn "le policy di dispositivo vincono su quelle cloud: rimuoverla con"
			log_warn "  ${PROG} --remove --rootfs '${ARG_ROOTFS:-/}'"
			log_warn "oppure mantenerla consapevolmente con --with-domain-policy"
		fi
	fi

	log_info "prossimi passi per l'amministratore:"
	log_info "  1. nella Admin Console: Dispositivi > Chrome > Impostazioni dispositivo,"
	log_info "     abilitare 'Iscrizione automatica dei dispositivi' (Forced Re-Enrollment"
	log_info "     o Zero-Touch) per l'unita' organizzativa dell'istituto"
	log_info "  2. censire i serial number dei dispositivi nella finestra di iscrizione"
	log_info "  3. al primo avvio la OOBE completa l'iscrizione senza intervento dell'utente"
	log_info "  4. verificare su chrome://policy lo stato 'Iscrizione: gestita da ${ARG_DOMAIN}'"
}

apply_strada_b() {
	log_banner \
		"prismOS EDU - Strada B (Local-Policy)" \
		"Dominio istituzionale: ${ARG_DOMAIN}" \
		"Policy: ${REL_POLICY_FILE}"

	write_browser_defaults "local"
	write_policy_json "full"

	local target
	target="$(target_path "${REL_POLICY_FILE}")"
	if [[ ${ARG_DRY_RUN} -eq 0 && -f "${target}" ]]; then
		log_info "riepilogo della policy installata:"
		PRISMOS_JSON_FILE="${target}" python3 - <<'PY'
import json, os

with open(os.environ["PRISMOS_JSON_FILE"], encoding="utf-8") as fh:
    policy = json.load(fh)

print("  chiavi totali          : %d" % len(policy))
print("  URLAllowlist           : %d voci" % len(policy.get("URLAllowlist", [])))
print("  URLBlocklist           : %d voci" % len(policy.get("URLBlocklist", [])))
print("  UserAllowlist          : %s" % ", ".join(policy.get("UserAllowlist", ["<nessun vincolo>"])))
print("  ArcEnabled             : %s" % policy.get("ArcEnabled", "<non impostata>"))
print("  GuestMode              : %s" % policy.get("BrowserGuestModeEnabled", "<non impostata>"))
PY
	fi

	log_info "verifica sul dispositivo: chrome://policy > 'Ricarica policy'"
	log_info "le policy in ${REL_POLICY_DIR}/ hanno precedenza su quelle cloud"
}

remove_policy() {
	log_banner "prismOS EDU - rimozione della policy locale"

	local policy_file found=0
	for policy_file in "$(target_path "${REL_POLICY_FILE}")" \
	                   "$(target_path "${REL_POLICY_FILE_BRANDED}")"; do
		if [[ -f "${policy_file}" ]]; then
			remove_file "${policy_file}"
			found=1
		fi
	done
	if (( found == 0 )); then
		log_warn "nessuna policy locale presente in $(target_path "${REL_POLICY_FILE}")"
	fi

	# Riporta il file di avvio del browser alla Strada A pura.
	resolve_templates
	if [[ -f "${ARG_BROWSER_TEMPLATE}" ]]; then
		write_browser_defaults "cloud"
		log_ok "configurazione riportata alla Strada A (Cloud-Managed)"
	else
		log_warn "template di ${REL_BROWSER_DEFAULTS} non disponibile: file live invariato"
		if [[ ${LIVE_MODE} -eq 1 && ${ARG_DRY_RUN} -eq 0 ]]; then
			local current="${REL_BROWSER_DEFAULTS}"
			if [[ -f "${current}" ]]; then
				sed -i -e 's|^PRISMOS_EDU_MODE=.*|PRISMOS_EDU_MODE="cloud"|' "${current}" 2>/dev/null || \
					${PRIVILEGED} sed -i -e 's|^PRISMOS_EDU_MODE=.*|PRISMOS_EDU_MODE="cloud"|' "${current}" || \
					log_warn "impossibile aggiornare PRISMOS_EDU_MODE in ${current}"
			fi
		fi
	fi
}

show_status() {
	log_banner "prismOS EDU - configurazione installata"

	local browser_file policy_file edition_file
	browser_file="$(target_path "${REL_BROWSER_DEFAULTS}")"
	policy_file="$(policy_file_primary)"
	edition_file="$(target_path "${REL_EDITION_CONF}")"

	printf '\n%sRadice%s: %s\n' "${PRISMOS_C_BOLD}" "${PRISMOS_C_RESET}" "${TARGET_ROOT:-/ (sistema live)}" >&2

	if [[ -f "${edition_file}" ]]; then
		local ed_id ed_name
		ed_id="$(. "${edition_file}" 2>/dev/null && echo "${PRISMOS_EDITION_ID:-}")" || ed_id=""
		ed_name="$(. "${edition_file}" 2>/dev/null && echo "${PRISMOS_EDITION_NAME:-}")" || ed_name=""
		printf '%sEdizione%s: %s (%s)\n' "${PRISMOS_C_BOLD}" "${PRISMOS_C_RESET}" "${ed_name:-n/d}" "${ed_id:-n/d}" >&2
	else
		printf '%sEdizione%s: nessun %s trovato\n' "${PRISMOS_C_BOLD}" "${PRISMOS_C_RESET}" "${REL_EDITION_CONF}" >&2
	fi

	printf '\n%s--- %s ---%s\n' "${PRISMOS_C_BOLD}" "${REL_BROWSER_DEFAULTS}" "${PRISMOS_C_RESET}" >&2
	if [[ -f "${browser_file}" ]]; then
		grep -E '^(PRISMOS_EDU_MODE|PRISMOS_EDU_DOMAIN|PRISMOS_EDU_DM_MODULUS|PRISMOS_EDU_ADMIN_CONSOLE)=' \
			"${browser_file}" | sed 's/^/  /' >&2 || true
		if grep -q -- '--enterprise-enable-zero-touch-enrollment' "${browser_file}"; then
			printf '  %sEnterprise Enrollment%s: ATTIVO (Zero-Touch)\n' \
				"${PRISMOS_C_GREEN}" "${PRISMOS_C_RESET}" >&2
		else
			printf '  %sEnterprise Enrollment%s: non attivo\n' \
				"${PRISMOS_C_YELLOW}" "${PRISMOS_C_RESET}" >&2
		fi
		if grep -q -- '--arc-availability=none' "${browser_file}"; then
			printf '  %sARC%s: disattivato a riga di comando (--arc-availability=none)\n' \
				"${PRISMOS_C_GREEN}" "${PRISMOS_C_RESET}" >&2
		else
			printf '  %sARC%s: switch di disattivazione ASSENTE\n' \
				"${PRISMOS_C_RED}" "${PRISMOS_C_RESET}" >&2
		fi
	else
		printf '  %snon presente%s\n' "${PRISMOS_C_YELLOW}" "${PRISMOS_C_RESET}" >&2
	fi

	printf '\n%s--- %s ---%s\n' "${PRISMOS_C_BOLD}" "${REL_POLICY_FILE}" "${PRISMOS_C_RESET}" >&2
	if [[ -f "${policy_file}" ]]; then
		PRISMOS_JSON_FILE="${policy_file}" python3 - <<'PY'
import json, os, sys

path = os.environ["PRISMOS_JSON_FILE"]
try:
    with open(path, encoding="utf-8") as fh:
        policy = json.load(fh)
except Exception as exc:
    print("  ERRORE di lettura: %s" % exc)
    sys.exit(0)

print("  chiavi               : %d" % len(policy))
users = policy.get("UserAllowlist", [])
print("  UserAllowlist        : %s" % (", ".join(users) if users else "<nessun vincolo>"))
allow = policy.get("URLAllowlist", [])
block = policy.get("URLBlocklist", [])
print("  URLAllowlist         : %d voci" % len(allow))
print("  URLBlocklist         : %d voci" % len(block))
social = [p for p in block if any(k in p for k in ("tiktok", "youtube", "twitch", "youtu.be"))]
print("  blocchi social       : %d (TikTok/YouTube/Twitch e CDN)" % len(social))
print("  ArcEnabled           : %s" % policy.get("ArcEnabled", "<assente>"))
print("  GuestMode            : %s" % policy.get("BrowserGuestModeEnabled", "<assente>"))
print("  RebootOnSignout      : %s" % policy.get("DeviceRebootOnUserSignout", "<assente>"))
PY
	else
		printf '  %snon presente%s (Strada A pura)\n' "${PRISMOS_C_YELLOW}" "${PRISMOS_C_RESET}" >&2
	fi

	printf '\n' >&2
}

validate_policy() {
	log_banner "prismOS EDU - validazione"
	local rc=0
	local policy_file browser_file
	policy_file="$(policy_file_primary)"
	browser_file="$(target_path "${REL_BROWSER_DEFAULTS}")"

	# 1. Sintassi del file di avvio del browser.
	if [[ -f "${browser_file}" ]]; then
		if bash -n "${browser_file}" 2>/dev/null; then
			log_ok "${REL_BROWSER_DEFAULTS}: sintassi bash valida"
		else
			log_error "${REL_BROWSER_DEFAULTS}: sintassi bash NON valida"
			rc=1
		fi
		if grep -q -- '--arc-availability=none' "${browser_file}"; then
			log_ok "${REL_BROWSER_DEFAULTS}: ARC disattivato a riga di comando"
		else
			log_error "${REL_BROWSER_DEFAULTS}: manca --arc-availability=none"
			rc=1
		fi
	else
		log_warn "${REL_BROWSER_DEFAULTS} non presente"
	fi

	# 2. Policy JSON: sintassi, conflitti e chiavi ARC.
	if [[ ! -f "${policy_file}" ]]; then
		log_warn "${REL_POLICY_FILE} non presente (Strada A pura: nessun controllo)"
		if (( rc == 0 )); then log_ok "validazione completata"; fi
		return "${rc}"
	fi

	if json_validate "${policy_file}"; then
		log_ok "${REL_POLICY_FILE}: JSON valido"
	else
		log_error "${REL_POLICY_FILE}: JSON NON valido"
		return 1
	fi

	if PRISMOS_JSON_FILE="${policy_file}" python3 - <<'PY'
import json, os, re, sys

with open(os.environ["PRISMOS_JSON_FILE"], encoding="utf-8") as fh:
    policy = json.load(fh)

errors = []
warnings = []

allow = policy.get("URLAllowlist", [])
block = policy.get("URLBlocklist", [])

# La variante minima (Strada A con --with-domain-policy) non contiene filtri URL:
# vincola soltanto gli account e disattiva i sottosistemi non presidiati.
minimal_variant = not allow and not block and "ArcEnabled" in policy
if minimal_variant:
    warnings.append("policy minima (Strada A --with-domain-policy): nessun filtro URL applicato")


def host_of(pattern):
    m = re.match(r"^(?:\*://|https?://)?([^/]+)", str(pattern))
    return m.group(1).lstrip("*.").lower() if m else ""


blocked = {host_of(p) for p in block if host_of(p)}
for pattern in allow:
    host = host_of(pattern)
    if any(host == b or host.endswith("." + b) for b in blocked if b):
        errors.append("allowlist shadowing: '%s' consente un dominio bloccato" % pattern)

for key in ("ArcEnabled", "UnaffiliatedArcAllowed", "UnaffiliatedDeviceArcAllowed"):
    if key not in policy:
        warnings.append("chiave ARC assente: %s (il blocco di ARC e' affidato solo a USE e agli switch)" % key)
    elif policy[key] is not False:
        errors.append("%s deve essere false su CPU senza SSE4.2, trovato %r" % (key, policy[key]))

if not minimal_variant:
    if not isinstance(allow, list) or not allow:
        errors.append("URLAllowlist vuota o malformata")
    if not isinstance(block, list) or not block:
        warnings.append("URLBlocklist vuota: nessun blocco attivo")

for pattern in allow + block:
    if not isinstance(pattern, str) or not pattern.strip():
        errors.append("pattern non valido in allowlist/blocklist: %r" % pattern)
        break

if policy.get("UserAllowlist"):
    for user in policy["UserAllowlist"]:
        if not isinstance(user, str) or "@" not in user:
            errors.append("UserAllowlist malformata: %r" % user)

for message in warnings:
    sys.stderr.write("WARN  %s\n" % message)
for message in errors:
    sys.stderr.write("ERROR %s\n" % message)

sys.exit(1 if errors else 0)
PY
	then
		log_ok "contenuto della policy coerente"
	else
		log_error "la policy presenta incongruenze (dettaglio sopra)"
		rc=1
	fi

	# 3. Eventuali file di backup residui.
	local leftovers=0
	while IFS= read -r bak; do
		[[ -n "${bak}" ]] || continue
		(( ++leftovers )) || true
		log_debug "backup residuo: ${bak}"
	done < <(find "$(dirname "${policy_file}")" -maxdepth 1 -name 'prismos_policy.json.prismos-bak-*' 2>/dev/null || true)
	if (( leftovers > 0 )); then
		log_warn "${leftovers} backup residui in $(dirname "${policy_file}"): Chromium ignora i file non .json"
	fi

	if (( rc == 0 )); then
		log_ok "validazione completata senza errori"
	else
		log_error "validazione completata CON errori"
	fi
	return "${rc}"
}

restart_ui() {
	[[ ${ARG_RESTART_UI} -eq 1 ]] || return 0
	if [[ ${LIVE_MODE} -eq 0 ]]; then
		log_warn "--restart-ui ignorato: non si opera su un sistema live"
		return 0
	fi
	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] riavvio della sessione grafica"
		return 0
	fi
	log_step "Riavvio della sessione grafica"
	if ${PRIVILEGED} systemctl restart ui.service 2>/dev/null; then
		log_ok "sessione riavviata (systemctl restart ui.service)"
	elif ${PRIVILEGED} restart ui 2>/dev/null; then
		log_ok "sessione riavviata (restart ui)"
	else
		log_warn "riavvio della sessione non riuscito: riavviare il dispositivo"
	fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
	parse_args "$@"

	log_banner \
		"prismOS EDU policy manager ${PROG_VERSION}" \
		"Strada A = Cloud-Managed (Enterprise Enrollment)" \
		"Strada B = Local-Policy (URLBlocklist + URLAllowlist scolastica)"

	require_cmds python3 sed grep install find dirname
	resolve_target
	resolve_templates

	WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prismos-edu-policy.XXXXXXXX")"
	# shellcheck disable=SC2064
	trap "rm -rf '${WORK_DIR}'" EXIT

	if (( ARG_SHOW == 1 )); then
		show_status
		return 0
	fi
	if (( ARG_VALIDATE == 1 )); then
		local rc=0
		validate_policy || rc=$?
		exit "${rc}"
	fi
	if (( ARG_REMOVE == 1 )); then
		remove_policy
		restart_ui
		return 0
	fi

	log_info "dominio istituzionale: ${ARG_DOMAIN} (segnaposto nel template: ${ARG_TEMPLATE_DOMAIN})"
	[[ "${ARG_DOMAIN}" == "${ARG_TEMPLATE_DOMAIN}" ]] && \
		log_warn "il dominio coincide con il segnaposto del template (${TEMPLATE_DOMAIN}):" && \
		log_warn "  in produzione indicare il dominio reale con --domain"

	case "${ARG_STRADA}" in
		a) apply_strada_a ;;
		b) apply_strada_b ;;
		*) die 1 "strada non riconosciuta: ${ARG_STRADA}" ;;
	esac

	restart_ui

	if (( ARG_DRY_RUN == 1 )); then
		log_warn "esecuzione in --dry-run: nessun file modificato"
		log_info "anteprima dei contenuti generati in ${WORK_DIR}"
		local preview
		for preview in "${WORK_DIR}"/*; do
			[[ -f "${preview}" ]] || continue
			printf '\n%s--- %s ---%s\n' "${PRISMOS_C_DIM}" "$(basename "${preview}")" "${PRISMOS_C_RESET}" >&2
			head -n 25 "${preview}" | sed 's/^/  /' >&2
		done
	else
		log_ok "configurazione EDU applicata (Strada ${ARG_STRADA^^})"
	fi
}

main "$@"
