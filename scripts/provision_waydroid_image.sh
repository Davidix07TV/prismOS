#!/usr/bin/env bash
# =============================================================================
#  prismOS :: scripts/provision_waydroid_image.sh
# -----------------------------------------------------------------------------
#  Provisioning delle immagini Android del sottosistema Waydroid.
#
#  IL PROBLEMA
#    Le immagini Waydroid x86_64 pubblicate a monte sono compilate con
#    -msse4.2 -mpopcnt: su una CPU senza SSE4.2 (Intel Pentium P6100,
#    Arrandale) il processo zygote termina con SIGILL all'avvio del container e
#    lxc continua a riavviarlo in un loop infinito. prismOS usa quindi
#    ESCLUSIVAMENTE la variante x86 a 32 bit (baseline SSE3), riconfigurata per
#    il floor ISA SSE4.1 e, quando serve, ricostruita dai sorgenti LineageOS
#    16.0 (Android 9) con le feature ART disattivate.
#
#  CHE COSA FA
#    1. individua l'archivio system.img / vendor.img (mirror prismOS, SourceForge
#       a monte, archivio locale oppure build dai sorgenti)
#    2. lo scarica con ripresa del trasferimento e verifica la somma SHA-256
#    3. estrae system.img e vendor.img in --images-dir
#    4. installa waydroid_base.prop e waydroid_mainline.prop con le proprieta'
#       ART del floor ISA (dalvik.vm.isa.x86.features=+sse4_1,-sse4_2,-popcnt)
#    5. verifica che l'ABI sia x86 e mai x86_64
#    6. con --deep-verify monta system.img in sola lettura e scandisce le
#       librerie native con scripts/verify_legacy_cpu.sh
#    7. scrive il marcatore ISA_FLOOR letto da prismos-waydroid-prepare
#
#  USO
#    provision_waydroid_image.sh --edition <edu|home|work|slim> [opzioni]
# =============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit extglob nullglob

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
# shellcheck source=scripts/lib/prismos_common.sh
source "$(dirname "${SCRIPT_PATH}")/lib/prismos_common.sh"
prismos_install_error_trap

readonly PROG="$(basename "${SCRIPT_PATH}")"
readonly PROG_VERSION="1.0.0"

# --- sorgenti ---------------------------------------------------------------------------
# Struttura reale dei file pubblicati dal progetto Waydroid su SourceForge:
#   images/system/lineage/waydroid_x86/lineage-<ver>-<data>-<VANILLA|GAPPS>-waydroid_x86-system.zip
#   images/vendor/waydroid_x86/lineage-<ver>-<data>-MAINLINE-waydroid_x86-vendor.zip
readonly UPSTREAM_BASE="https://sourceforge.net/projects/waydroid/files/images"
readonly UPSTREAM_SYSTEM_REL="system/lineage/waydroid_x86"
readonly UPSTREAM_VENDOR_REL="vendor/waydroid_x86"
# Mirror prismOS: ospita la ricostruzione LineageOS 16.0 (Android 9) x86 con
# floor ISA SSE4.1. Va sostituito con l'URL dell'istituto o del proprio server.
readonly PRISMOS_MIRROR_DEFAULT="https://mirror.prismos.example.org/waydroid"

# Versione LineageOS richiesta dal progetto prismOS (Android 9).
readonly LINEAGE_TARGET="16.0"
readonly ANDROID_TARGET="9"

# Destinazione predefinita (quella letta da /etc/waydroid/waydroid.cfg).
readonly IMAGES_DIR_DEFAULT="/var/lib/waydroid/images"
# Directory alternativa riconosciuta da `waydroid init -f` per immagini custom.
readonly IMAGES_DIR_EXTRA="/etc/waydroid-extra/images"
readonly ISA_MARKER="ISA_FLOOR"

# Proprieta' ART che realizzano il floor ISA nel runtime Android.
readonly ISA_FEATURES_X86="+sse3,+ssse3,+sse4_1,-sse4_2,-popcnt,-avx,-avx2"
readonly ABI_LIST="x86,armeabi-v7a,armeabi"
readonly ABI_LIST_32="x86,armeabi-v7a,armeabi"

# --- opzioni ----------------------------------------------------------------------------
ARG_EDITION=""
ARG_SOURCE="prismos"
ARG_MIRROR=""
ARG_SYSTEM_URL=""
ARG_VENDOR_URL=""
ARG_ARCHIVE=""
ARG_VARIANT="VANILLA"
ARG_VERSION="${LINEAGE_TARGET}"
ARG_DATE=""
ARG_IMAGES_DIR="${IMAGES_DIR_DEFAULT}"
ARG_BUILD=0
ARG_SOURCE_DIR=""
ARG_JOBS=""
ARG_FORCE=0
ARG_DEEP_VERIFY=0
ARG_NO_PROPS=0
ARG_SHA256_FILE=""
ARG_DRY_RUN=0
ARG_QUERY_LATEST=0
ARG_QUIET=0

PRIVILEGED=""
WORK_DIR=""
INSTALLED_SYSTEM=""
INSTALLED_VENDOR=""

usage() {
	cat <<USAGE
${PRISMOS_C_BOLD}prismOS ${PROG_VERSION} - provisioning delle immagini Waydroid${PRISMOS_C_RESET}

USO
  ${PROG} --edition <edu|home|work|slim> [opzioni]

EDIZIONE (obbligatoria)
  --edition ED         edu | home | work | slim; determina le proprieta' ART,
                       il budget di memoria e la variante dell'immagine

SORGENTE DELLE IMMAGINI
  --source SORGENTE    prismos  (default) mirror con la ricostruzione LineageOS
                                ${LINEAGE_TARGET} x86 a floor ISA SSE4.1
                       upstream SourceForge del progetto Waydroid (oggi pubblica
                                LineageOS 20.0 / Android 13: usare --deep-verify)
                       local    archivio locale indicato con --archive
                       build    ricostruzione dai sorgenti con --build
  --mirror URL         URL base del mirror prismOS
                       (default: ${PRISMOS_MIRROR_DEFAULT})
  --system-url URL     URL diretto dell'archivio di system
  --vendor-url URL     URL diretto dell'archivio di vendor
  --archive FILE       archivio locale (.zip con system.img e/o vendor.img)
  --variant V          VANILLA (default) | GAPPS. GAPPS include i servizi Google
                       Play: sconsigliato in EDU e su macchine con <2 GB di RAM
  --version V          versione LineageOS (default: ${LINEAGE_TARGET})
  --date AAAAMMGG      data della build; senza questa opzione si usa l'ultima
                       disponibile (--query-latest la mostra senza scaricare)
  --sha256-file F      file con le somme attese ("somma  nomefile" per riga)

RICOSTRUZIONE DAI SORGENTI
  --build              ricostruisce system.img/vendor.img da un checkout
                       LineageOS ${LINEAGE_TARGET} x86 applicando il floor ISA
  --source-dir DIR     checkout LineageOS per --build
  --jobs N             parallelismo della build (default: nproc)

DESTINAZIONE E VERIFICHE
  --images-dir DIR     directory di destinazione
                       (default: ${IMAGES_DIR_DEFAULT}; alternativa riconosciuta
                       da waydroid init -f: ${IMAGES_DIR_EXTRA})
  --force              riscarica e sovrascrive anche se le immagini esistono
  --deep-verify        monta system.img in sola lettura e scandisce le librerie
                       native con verify_legacy_cpu.sh (richiede root)
  --no-props           non installare i file .prop del floor ISA
  --query-latest       interroga la sorgente e mostra le build disponibili
  --dry-run            mostra le azioni senza scaricare ne' scrivere
  --verbose            log di debug
  -h, --help           questo messaggio
  -V, --version        versione

ESEMPI
  ${PROG} --edition slim --dry-run
  ${PROG} --edition home --source upstream --deep-verify
  ${PROG} --edition edu --archive ~/scaricati/lineage-16.0-waydroid_x86.zip
  ${PROG} --edition work --build --source-dir ~/lineageos-16.0 --jobs 8
  ${PROG} --edition home --query-latest --source upstream

CODICI DI USCITA
  0  provisioning completato e verificato
  1  immagini non conformi al floor ISA oppure verifica fallita
  2  errore d'uso o ambiente incompleto
USAGE
}

parse_args() {
	while (( $# > 0 )); do
		case "$1" in
			--edition)        ARG_EDITION="${2:-}"; shift 2 ;;
			--edition=*)      ARG_EDITION="${1#*=}"; shift ;;
			--source)         ARG_SOURCE="${2:-}"; shift 2 ;;
			--source=*)       ARG_SOURCE="${1#*=}"; shift ;;
			--mirror)         ARG_MIRROR="${2:-}"; shift 2 ;;
			--mirror=*)       ARG_MIRROR="${1#*=}"; shift ;;
			--system-url)     ARG_SYSTEM_URL="${2:-}"; shift 2 ;;
			--system-url=*)   ARG_SYSTEM_URL="${1#*=}"; shift ;;
			--vendor-url)     ARG_VENDOR_URL="${2:-}"; shift 2 ;;
			--vendor-url=*)   ARG_VENDOR_URL="${1#*=}"; shift ;;
			--archive)        ARG_ARCHIVE="${2:-}"; ARG_SOURCE="local"; shift 2 ;;
			--archive=*)      ARG_ARCHIVE="${1#*=}"; ARG_SOURCE="local"; shift ;;
			--variant)        ARG_VARIANT="${2:-}"; shift 2 ;;
			--variant=*)      ARG_VARIANT="${1#*=}"; shift ;;
			--version)        ARG_VERSION="${2:-}"; shift 2 ;;
			--version=*)      ARG_VERSION="${1#*=}"; shift ;;
			--date)           ARG_DATE="${2:-}"; shift 2 ;;
			--date=*)         ARG_DATE="${1#*=}"; shift ;;
			--sha256-file)    ARG_SHA256_FILE="${2:-}"; shift 2 ;;
			--sha256-file=*)  ARG_SHA256_FILE="${1#*=}"; shift ;;
			--build)          ARG_BUILD=1; ARG_SOURCE="build"; shift ;;
			--source-dir)     ARG_SOURCE_DIR="${2:-}"; shift 2 ;;
			--source-dir=*)   ARG_SOURCE_DIR="${1#*=}"; shift ;;
			--jobs)           ARG_JOBS="${2:-}"; shift 2 ;;
			--jobs=*)         ARG_JOBS="${1#*=}"; shift ;;
			--images-dir)     ARG_IMAGES_DIR="${2:-}"; shift 2 ;;
			--images-dir=*)   ARG_IMAGES_DIR="${1#*=}"; shift ;;
			--force)          ARG_FORCE=1; shift ;;
			--deep-verify)    ARG_DEEP_VERIFY=1; shift ;;
			--no-props)       ARG_NO_PROPS=1; shift ;;
			--query-latest)   ARG_QUERY_LATEST=1; shift ;;
			--dry-run)        ARG_DRY_RUN=1; shift ;;
			-v|--verbose)     PRISMOS_LOG_LEVEL="debug"; shift ;;
			-q|--quiet)       ARG_QUIET=1; PRISMOS_LOG_LEVEL="error"; shift ;;
			-h|--help)        usage; exit 0 ;;
			-V|--version)     echo "${PROG} ${PROG_VERSION}"; exit 0 ;;
			--)               shift; break ;;
			-*)               usage >&2; die 2 "opzione sconosciuta: $1" ;;
			*)                usage >&2; die 2 "argomento inatteso: $1" ;;
		esac
	done

	if [[ -z "${ARG_EDITION}" ]]; then
		usage >&2
		die 2 "argomento obbligatorio mancante: --edition <edu|home|work|slim>"
	fi
	is_valid_edition "${ARG_EDITION}" || die 2 "edizione non valida: ${ARG_EDITION}"

	case "${ARG_SOURCE}" in
		prismos|upstream|local|build) ;;
		*) die 2 "--source accetta prismos, upstream, local o build: '${ARG_SOURCE}'" ;;
	esac
	case "${ARG_VARIANT^^}" in
		VANILLA|GAPPS) ARG_VARIANT="${ARG_VARIANT^^}" ;;
		*) die 2 "--variant accetta VANILLA o GAPPS: '${ARG_VARIANT}'" ;;
	esac
	if [[ "${ARG_SOURCE}" == "local" ]]; then
		[[ -n "${ARG_ARCHIVE}" ]] || die 2 "--source local richiede --archive <file>"
		[[ -f "${ARG_ARCHIVE}" ]] || die 2 "archivio inesistente: ${ARG_ARCHIVE}"
	fi
	if [[ "${ARG_SOURCE}" == "build" ]]; then
		[[ -n "${ARG_SOURCE_DIR}" ]] || die 2 "--build richiede --source-dir <checkout LineageOS>"
		[[ -d "${ARG_SOURCE_DIR}" ]] || die 2 "checkout inesistente: ${ARG_SOURCE_DIR}"
	fi
	if [[ -n "${ARG_DATE}" ]] && ! [[ "${ARG_DATE}" =~ ^[0-9]{8}$ ]]; then
		die 2 "--date richiede il formato AAAAMMGG: '${ARG_DATE}'"
	fi
	if [[ -n "${ARG_JOBS}" ]] && ! [[ "${ARG_JOBS}" =~ ^[0-9]+$ ]]; then
		die 2 "--jobs richiede un intero: '${ARG_JOBS}'"
	fi
	if [[ "${ARG_EDITION}" == "slim" && "${ARG_VARIANT}" == "GAPPS" ]]; then
		log_warn "GAPPS in edizione Slim: i servizi Google Play aggiungono ~450 MB di"
		log_warn "  immagine e 300-400 MB di RAM residente. Fortemente sconsigliato."
	fi
	[[ -n "${ARG_MIRROR}" ]] || ARG_MIRROR="${PRISMOS_MIRROR_DEFAULT}"
	[[ -n "${ARG_JOBS}" ]] || ARG_JOBS="$(nproc 2>/dev/null || echo 4)"
}

# =============================================================================
# AMBIENTE
# =============================================================================
resolve_environment() {
	log_step "Preparazione dell'ambiente"

	require_cmds python3

	local tool
	for tool in curl wget unzip sha256sum; do
		if ! have_cmd "${tool}"; then
			case "${tool}" in
				curl) have_cmd wget || die 2 "servono curl o wget per il download" ;;
				wget) have_cmd curl || die 2 "servono curl o wget per il download" ;;
				*) die 2 "comando obbligatorio mancante: ${tool}" ;;
			esac
		fi
	done

	# Privilegi: le immagini finiscono di norma in /var/lib/waydroid, di proprieta'
	# di root. Se la destinazione e' gia' scrivibile dall'utente corrente (caso
	# di --images-dir in una directory di lavoro) sudo non viene usato affatto:
	# invocarlo creerebbe file di root che i passi successivi non potrebbero
	# leggere ne' riscrivere.
	if [[ "$(id -u)" -eq 0 ]]; then
		PRIVILEGED=""
		log_debug "esecuzione come root"
	elif [[ -d "${ARG_IMAGES_DIR}" && -w "${ARG_IMAGES_DIR}" ]] || \
	     [[ ! -e "${ARG_IMAGES_DIR}" && -d "$(dirname "${ARG_IMAGES_DIR}")" && -w "$(dirname "${ARG_IMAGES_DIR}")" ]]; then
		PRIVILEGED=""
		log_debug "destinazione scrivibile dall'utente corrente: sudo non necessario"
	elif have_cmd sudo; then
		PRIVILEGED="sudo"
		log_debug "destinazione non scrivibile: i comandi privilegiati useranno sudo"
	else
		die 2 "servono privilegi di root per scrivere in ${ARG_IMAGES_DIR} (sudo assente)"
	fi

	if [[ ${ARG_DEEP_VERIFY} -eq 1 ]]; then
		local needed=(losetup mount)
		for tool in "${needed[@]}"; do
			have_cmd "${tool}" || die 2 "--deep-verify richiede ${tool}"
		done
		[[ -f "${PRISMOS_SCRIPTS_DIR}/verify_legacy_cpu.sh" ]] || \
			die 2 "--deep-verify richiede scripts/verify_legacy_cpu.sh"
	fi

	WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prismos-waydroid.XXXXXXXX")"
	trap 'cleanup_workdir' EXIT
	log_debug "directory di lavoro: ${WORK_DIR}"

	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] immagini verrebbero installate in ${ARG_IMAGES_DIR}"
	else
		ensure_dir_local "${ARG_IMAGES_DIR}"
	fi

	log_ok "ambiente pronto (sorgente: ${ARG_SOURCE}, variante: ${ARG_VARIANT})"
}

ensure_dir_local() {
	local dir="$1"
	[[ -d "${dir}" ]] && return 0
	if [[ -n "${PRIVILEGED}" ]]; then
		${PRIVILEGED} install -d -m 0755 "${dir}" || die 2 "impossibile creare ${dir}"
	else
		install -d -m 0755 "${dir}" || die 2 "impossibile creare ${dir}"
	fi
	log_debug "creata: ${dir}"
}

privileged_cp() {
	local src="$1" dst="$2" mode="${3:-0644}"
	if [[ -n "${PRIVILEGED}" ]]; then
		${PRIVILEGED} install -D -m "${mode}" "${src}" "${dst}"
	else
		install -D -m "${mode}" "${src}" "${dst}"
	fi
}

privileged_rm() {
	local target="$1"
	if [[ -n "${PRIVILEGED}" ]]; then
		${PRIVILEGED} rm -rf "${target}"
	else
		rm -rf "${target}"
	fi
}

cleanup_workdir() {
	if [[ -n "${MOUNT_POINT:-}" && -d "${MOUNT_POINT}" ]]; then
		${PRIVILEGED} umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
	fi
	if [[ -n "${LOOP_DEV:-}" ]]; then
		${PRIVILEGED} losetup -d "${LOOP_DEV}" >/dev/null 2>&1 || true
	fi
	[[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
	return 0
}

# =============================================================================
# DOWNLOAD
# =============================================================================
fetch_url() {
	local url="$1" dest="$2"
	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] download di ${url}"
		return 0
	fi
	log_info "download: ${url}"
	if have_cmd curl; then
		curl --fail --location --continue-at - --progress-bar \
			--connect-timeout 30 --retry 3 --retry-delay 5 \
			--output "${dest}" "${url}" || return 1
	elif have_cmd wget; then
		wget --continue --tries=3 --timeout=30 --progress=bar:force \
			--output-document="${dest}" "${url}" || return 1
	else
		die 2 "nessun downloader disponibile (curl o wget)"
	fi
}

# Costruisce l'URL dell'archivio di system/vendor in base alla sorgente.
build_url() {
	local kind="$1"   # system | vendor
	local filename=""

	case "${ARG_SOURCE}" in
		upstream)
			if [[ "${kind}" == "system" ]]; then
				filename="lineage-${ARG_VERSION}-${ARG_DATE}-${ARG_VARIANT}-waydroid_x86-system.zip"
				printf '%s/%s/%s/download' "${UPSTREAM_BASE}" "${UPSTREAM_SYSTEM_REL}" "${filename}"
			else
				filename="lineage-${ARG_VERSION}-${ARG_DATE}-MAINLINE-waydroid_x86-vendor.zip"
				printf '%s/%s/%s/download' "${UPSTREAM_BASE}" "${UPSTREAM_VENDOR_REL}" "${filename}"
			fi
			;;
		prismos)
			# Il mirror prismOS pubblica la ricostruzione LineageOS 16.0 x86 con
			# floor ISA SSE4.1 e le somme SHA-256 accanto agli archivi.
			if [[ "${kind}" == "system" ]]; then
				filename="prismos-lineage-${ARG_VERSION}-x86-${ARG_VARIANT,,}-system.img.xz"
			else
				filename="prismos-lineage-${ARG_VERSION}-x86-mainline-vendor.img.xz"
			fi
			printf '%s/%s/%s' "${ARG_MIRROR%/}" "lineage-${ARG_VERSION}-x86" "${filename}"
			;;
		*)
			printf ''
			;;
	esac
}

# Interroga la sorgente per elencare le build disponibili.
query_latest() {
	log_banner "Build disponibili presso la sorgente '${ARG_SOURCE}'"

	if [[ "${ARG_SOURCE}" == "local" ]]; then
		log_info "sorgente locale: ${ARG_ARCHIVE}"
		return 0
	fi
	if [[ "${ARG_SOURCE}" == "build" ]]; then
		log_info "ricostruzione dai sorgenti in ${ARG_SOURCE_DIR}"
		return 0
	fi

	local listing_url folder
	if [[ "${ARG_SOURCE}" == "upstream" ]]; then
		folder="${UPSTREAM_BASE}/${UPSTREAM_SYSTEM_REL}/"
		listing_url="https://sourceforge.net/projects/waydroid/files/images/${UPSTREAM_SYSTEM_REL}/"
	else
		folder="${ARG_MIRROR%/}/lineage-${ARG_VERSION}-x86/"
		listing_url="${folder}"
	fi

	log_info "elenco richiesto a: ${listing_url}"

	local page="${WORK_DIR}/listing.html"
	if ! fetch_url "${listing_url}" "${page}"; then
		log_error "impossibile recuperare l'elenco da ${listing_url}"
		log_info "specificare --date AAAAMMGG oppure --system-url/--vendor-url"
		return 1
	fi
	[[ -s "${page}" ]] || { log_warn "risposta vuota dalla sorgente"; return 1; }

	PRISMOS_LISTING="${page}" PRISMOS_LISTING_VARIANT="${ARG_VARIANT}" \
	python3 - <<'PY'
import os, re, sys

with open(os.environ["PRISMOS_LISTING"], encoding="utf-8", errors="replace") as fh:
    text = fh.read()

variant = os.environ.get("PRISMOS_LISTING_VARIANT", "VANILLA")
pattern = re.compile(r"lineage-([\d.]+)-(\d{8})-([A-Z]+)-waydroid_x86-system\.zip")
found = {}
for match in pattern.finditer(text):
    version, date, kind = match.groups()
    found[(version, date, kind)] = True

if not found:
    # Mirror prismOS: archivi .img.xz.
    for match in re.finditer(r"prismos-lineage-([\d.]+)-x86-(\w+)-system\.img\.xz", text):
        found[(match.group(1), "", match.group(2).upper())] = True

if not found:
    print("nessuna build riconosciuta nell'elenco (formato inatteso)")
    sys.exit(1)

rows = sorted(found.keys(), key=lambda k: (k[0], k[1]), reverse=True)
print("  %-10s %-10s %-9s %s" % ("VERSIONE", "DATA", "VARIANTE", "COMPATIBILE"))
print("  " + "-" * 60)
for version, date, kind in rows[:20]:
    note = ""
    if version.startswith("16."):
        note = "SI - Android 9, target prismOS"
    elif kind != variant:
        note = "variante diversa da quella richiesta"
    else:
        note = "verificare con --deep-verify (Android >= 10)"
    print("  %-10s %-10s %-9s %s" % (version, date or "n/d", kind, note))
PY
	local rc=$?
	if (( rc != 0 )); then
		return 1
	fi

	if [[ "${ARG_SOURCE}" == "upstream" ]]; then
		log_warn "il progetto Waydroid pubblica oggi LineageOS 20.0 (Android 13): la"
		log_warn "  versione richiesta da prismOS e' LineageOS ${LINEAGE_TARGET} (Android ${ANDROID_TARGET})."
		log_warn "  Usare --source prismos (mirror con la ricostruzione 16.0) oppure"
		log_warn "  --build per ricompilare dai sorgenti con il floor ISA."
	fi
	return 0
}

verify_checksum() {
	local file="$1"
	[[ -f "${file}" ]] || return 0
	[[ -n "${ARG_SHA256_FILE}" ]] || { log_debug "nessun file di somme indicato: verifica saltata"; return 0; }
	[[ -f "${ARG_SHA256_FILE}" ]] || die 2 "file delle somme inesistente: ${ARG_SHA256_FILE}"

	have_cmd sha256sum || die 2 "sha256sum non disponibile"

	local base expected actual
	base="$(basename "${file}")"
	expected="$(awk -v n="${base}" '$2 == n || $1 == n { print ($2 == n ? $1 : $2); exit }' "${ARG_SHA256_FILE}")"
	if [[ -z "${expected}" ]]; then
		log_warn "nessuna somma per ${base} in ${ARG_SHA256_FILE}"
		return 0
	fi
	actual="$(sha256sum "${file}" | cut -d' ' -f1)"
	if [[ "${actual}" != "${expected}" ]]; then
		log_error "SHA-256 non corrispondente per ${base}"
		log_error "  atteso : ${expected}"
		log_error "  ottenuto: ${actual}"
		return 1
	fi
	log_ok "SHA-256 verificato: ${actual}"
}

# =============================================================================
# ESTRAZIONE
# =============================================================================
extract_archive() {
	local archive="$1" dest="$2"

	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] estrazione di ${archive} in ${dest}"
		printf '%s/system.img %s/vendor.img\n' "${dest}" "${dest}"
		return 0
	fi

	ensure_dir_local "${dest}"
	log_step "Estrazione di $(basename "${archive}")"

	# L'estrazione avviene nella directory temporanea dell'utente: mai con sudo,
	# altrimenti i file estratti non sarebbero leggibili dai passi successivi.
	local extracted="${WORK_DIR}/extract"
	ensure_dir "${extracted}"

	case "${archive}" in
		*.zip)
			have_cmd unzip || die 2 "unzip non disponibile per estrarre ${archive}"
			unzip -o -q "${archive}" -d "${extracted}" || die 1 "estrazione fallita: ${archive}"
			;;
		*.tar.xz|*.txz)
			have_cmd tar || die 2 "tar non disponibile"
			tar -xJf "${archive}" -C "${extracted}" || die 1 "estrazione fallita: ${archive}"
			;;
		*.tar.gz|*.tgz)
			tar -xzf "${archive}" -C "${extracted}" || die 1 "estrazione fallita: ${archive}"
			;;
		*.xz)
			have_cmd xz || die 2 "xz non disponibile per decomprimere ${archive}"
			local out="${extracted}/$(basename "${archive}" .xz)"
			xz -dc "${archive}" > "${out}" || die 1 "decompressione fallita: ${archive}"
			;;
		*.img)
			cp -f "${archive}" "${extracted}/"
			;;
		*)
			die 2 "formato di archivio non riconosciuto: ${archive}"
			;;
	esac

	local found_system found_vendor
	found_system="$(find "${extracted}" -type f -name 'system.img' -print -quit 2>/dev/null || true)"
	found_vendor="$(find "${extracted}" -type f -name 'vendor.img' -print -quit 2>/dev/null || true)"

	if [[ -z "${found_system}" ]]; then
		log_error "system.img non trovato nell'archivio ${archive}"
		log_error "  contenuto: $(find "${extracted}" -maxdepth 2 -type f -printf '%f ' 2>/dev/null | head -c 200)"
		return 1
	fi

	privileged_cp "${found_system}" "${dest}/system.img" 0644
	INSTALLED_SYSTEM="${dest}/system.img"
	log_ok "system.img installata ($(bytes_human "$(stat -c '%s' "${found_system}")"))"

	if [[ -n "${found_vendor}" ]]; then
		privileged_cp "${found_vendor}" "${dest}/vendor.img" 0644
		INSTALLED_VENDOR="${dest}/vendor.img"
		log_ok "vendor.img installata ($(bytes_human "$(stat -c '%s' "${found_vendor}")"))"
	else
		log_warn "vendor.img assente nell'archivio: verra' usata quella gia' presente"
		if [[ -s "${dest}/vendor.img" ]]; then
			INSTALLED_VENDOR="${dest}/vendor.img"
			log_info "vendor.img esistente conservata"
		fi
	fi

	rm -rf "${extracted}"
	return 0
}

# =============================================================================
# PROPRIETA' ART DEL FLOOR ISA
# =============================================================================
install_props() {
	local dest="$1"

	log_step "Installazione delle proprieta' ART del floor ISA"

	if (( ARG_NO_PROPS == 1 )); then
		log_warn "--no-props: i file .prop non verranno aggiornati"
		return 0
	fi

	local repo_props="${PRISMOS_OVERLAYS_DIR}/overlay-prismos-common/app-emulation/prismos-waydroid-config/files"
	local installed_props="/usr/share/prismos/waydroid"
	local base_src="" mainline_src=""

	for base_src in "${repo_props}/waydroid_base.prop" "${installed_props}/waydroid_base.prop"; do
		[[ -f "${base_src}" ]] && break
		base_src=""
	done
	for mainline_src in "${repo_props}/waydroid_mainline.prop" "${installed_props}/waydroid_mainline.prop"; do
		[[ -f "${mainline_src}" ]] && break
		mainline_src=""
	done

	if [[ -z "${base_src}" ]]; then
		log_warn "template waydroid_base.prop non trovato: genero un file minimo"
		base_src="${WORK_DIR}/waydroid_base.prop"
		cat > "${base_src}" <<'BASEPROP'
# Generato da provision_waydroid_image.sh in assenza del template di pacchetto.
ro.product.cpu.abilist=x86,armeabi-v7a,armeabi
ro.product.cpu.abilist32=x86,armeabi-v7a,armeabi
ro.product.cpu.abilist64=
ro.product.brand=prismOS
ro.product.manufacturer=prismOS
ro.build.flavor=lineage_waydroid_x86-userdebug
BASEPROP
	fi

	# Budget di memoria e compilazione AOT per edizione.
	local heap_growth="" heap_size="" dex2oat_threads="2" compile_filter="speed-profile"
	case "${ARG_EDITION}" in
		slim)
			heap_growth="128m"; heap_size="256m"; dex2oat_threads="1"; compile_filter="verify" ;;
		edu)
			heap_growth="192m"; heap_size="384m"; dex2oat_threads="2"; compile_filter="speed-profile" ;;
		home)
			heap_growth="256m"; heap_size="512m"; dex2oat_threads="2"; compile_filter="speed-profile" ;;
		work)
			heap_growth="192m"; heap_size="384m"; dex2oat_threads="2"; compile_filter="speed-profile" ;;
	esac

	local out="${WORK_DIR}/waydroid_base.prop"
	cp -f "${base_src}" "${out}"

	# Le proprieta' del floor ISA hanno sempre la precedenza: se il template le
	# contiene gia' vengono sostituite, altrimenti vengono aggiunte in coda.
	local -a overrides=(
		"ro.product.cpu.abilist=${ABI_LIST}"
		"ro.product.cpu.abilist32=${ABI_LIST_32}"
		"ro.product.cpu.abilist64="
		"dalvik.vm.isa.x86.features=${ISA_FEATURES_X86}"
		"dalvik.vm.isa.x86.variant=x86"
		"dalvik.vm.isa.x86_64.variant=x86_64"
		"dalvik.vm.isa.x86_64.features="
		"dalvik.vm.heapgrowthlimit=${heap_growth}"
		"dalvik.vm.heapsize=${heap_size}"
		"dalvik.vm.dex2oat-threads=${dex2oat_threads}"
		"dalvik.vm.dex2oat-filter=${compile_filter}"
		"dalvik.vm.usejit=true"
		"ro.config.low_ram=$([[ "${ARG_EDITION}" == "slim" ]] && echo true || echo false)"
		"ro.zygote=zygote32"
		"persist.waydroid.arch=x86"
		"persist.waydroid.multi_windows=true"
		"ro.prismos.isa_floor=x86-SSE4.1"
		"ro.prismos.edition=${ARG_EDITION}"
	)

	local kv key value
	for kv in "${overrides[@]}"; do
		key="${kv%%=*}"
		value="${kv#*=}"
		if grep -q "^${key}=" "${out}" 2>/dev/null; then
			sed -i "s|^${key}=.*|${key}=${value}|" "${out}"
		else
			printf '%s=%s\n' "${key}" "${value}" >> "${out}"
		fi
	done

	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] ${dest}/waydroid_base.prop (${#overrides[@]} proprieta' forzate)"
		return 0
	fi

	privileged_cp "${out}" "${dest}/waydroid_base.prop" 0644
	log_ok "waydroid_base.prop installata (${#overrides[@]} proprieta' del floor ISA)"
	log_info "  ABI: ${ABI_LIST} (nessuna ABI a 64 bit)"
	log_info "  ART: dalvik.vm.isa.x86.features=${ISA_FEATURES_X86}"
	log_info "  heap: growth ${heap_growth}, size ${heap_size}, dex2oat ${dex2oat_threads} thread (${compile_filter})"

	if [[ -n "${mainline_src}" ]]; then
		local main_out="${WORK_DIR}/waydroid_mainline.prop"
		cp -f "${mainline_src}" "${main_out}"
		if grep -q "^ro.product.cpu.abilist=" "${main_out}"; then
			sed -i "s|^ro.product.cpu.abilist=.*|ro.product.cpu.abilist=${ABI_LIST}|" "${main_out}"
		else
			printf 'ro.product.cpu.abilist=%s\n' "${ABI_LIST}" >> "${main_out}"
		fi
		privileged_cp "${main_out}" "${dest}/waydroid_mainline.prop" 0644
		log_ok "waydroid_mainline.prop installata (vendor MAINLINE)"
	else
		log_warn "template waydroid_mainline.prop non trovato: uso waydroid_base.prop"
	fi
}

# =============================================================================
# VERIFICHE
# =============================================================================
verify_abi() {
	local dest="$1"
	log_step "Verifica dell'ABI e del floor ISA"

	local prop="${dest}/waydroid_base.prop"
	if [[ ! -f "${prop}" ]]; then
		log_warn "waydroid_base.prop assente: verifica dell'ABI impossibile"
		return 0
	fi

	local rc=0
	if grep -q '^ro.product.cpu.abilist64=$' "${prop}" || ! grep -q 'x86_64' "${prop}"; then
		log_ok "nessuna ABI a 64 bit esposta (x86_64 assente): conforme"
	else
		log_error "l'immagine espone ABI x86_64: su CPU senza SSE4.2 zygote termina con SIGILL"
		rc=1
	fi

	local features
	features="$(sed -n 's/^dalvik\.vm\.isa\.x86\.features=//p' "${prop}" | head -1)"
	if [[ "${features}" == *"-sse4_2"* && "${features}" == *"-popcnt"* ]]; then
		log_ok "feature ART corrette: ${features}"
	else
		log_error "dalvik.vm.isa.x86.features non disattiva sse4_2/popcnt: '${features:-<assente>}'"
		rc=1
	fi

	if grep -q '^ro.product.cpu.abilist=.*x86' "${prop}"; then
		log_ok "ABI primaria x86 (32 bit) presente"
	else
		log_error "ABI primaria x86 assente"
		rc=1
	fi

	return "${rc}"
}

deep_verify_isa() {
	local dest="$1"
	local system_img="${dest}/system.img"

	log_step "Verifica approfondita delle librerie native (deep-verify)"

	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] verifica ISA approfondita saltata"
		return 0
	fi
	if [[ ! -s "${system_img}" ]]; then
		log_warn "system.img assente: verifica approfondita saltata"
		return 0
	fi

	MOUNT_POINT="${WORK_DIR}/system"
	ensure_dir "${MOUNT_POINT}"

	log_info "associazione di system.img a un loop device"
	if [[ -n "${PRIVILEGED}" ]]; then
		LOOP_DEV="$(${PRIVILEGED} losetup --find --show --read-only "${system_img}" 2>/dev/null)" || LOOP_DEV=""
	else
		LOOP_DEV="$(losetup --find --show --read-only "${system_img}" 2>/dev/null)" || LOOP_DEV=""
	fi
	if [[ -z "${LOOP_DEV}" ]]; then
		log_warn "losetup non riuscito: verifica approfondita non eseguibile"
		log_warn "  montare manualmente system.img e usare verify_legacy_cpu.sh --rootfs <mount>"
		return 0
	fi
	log_debug "loop device: ${LOOP_DEV}"

	local mounted=0
	if [[ -n "${PRIVILEGED}" ]]; then
		${PRIVILEGED} mount -o ro "${LOOP_DEV}" "${MOUNT_POINT}" 2>/dev/null && mounted=1
	else
		mount -o ro "${LOOP_DEV}" "${MOUNT_POINT}" 2>/dev/null && mounted=1
	fi
	if (( mounted == 0 )); then
		log_warn "mount di system.img non riuscito (formato sparse o ext4 con feature non supportate)"
		log_warn "  provare: simg2img system.img system.raw.img e poi --deep-verify"
		${PRIVILEGED} losetup -d "${LOOP_DEV}" >/dev/null 2>&1 || true
		LOOP_DEV=""
		return 0
	fi
	log_ok "system.img montata in ${MOUNT_POINT}"

	local rc=0
	if [[ ! -d "${MOUNT_POINT}/system" && ! -d "${MOUNT_POINT}/lib" ]]; then
		log_warn "struttura Android non riconosciuta nel filesystem montato"
	else
		log_info "scansione completa delle librerie native di system.img"
		if "${PRISMOS_SCRIPTS_DIR}/verify_legacy_cpu.sh" \
			--rootfs "${MOUNT_POINT}" --full --quiet \
			--report "${WORK_DIR}/isa-system.txt" \
			--json "${WORK_DIR}/isa-system.json" 2>/dev/null; then
			log_ok "system.img conforme al floor ISA SSE4.1"
		else
			log_error "system.img contiene librerie non conformi: ${WORK_DIR}/isa-system.txt"
			log_error "  su CPU senza SSE4.2 queste librerie produrrebbero SIGILL"
			rc=1
		fi
	fi

	${PRIVILEGED} umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
	${PRIVILEGED} losetup -d "${LOOP_DEV}" >/dev/null 2>&1 || true
	LOOP_DEV=""
	MOUNT_POINT=""

	return "${rc}"
}

write_isa_marker() {
	local dest="$1" source_url="$2"
	local marker="${dest}/${ISA_MARKER}"

	log_step "Scrittura del marcatore ${ISA_MARKER}"

	local system_size="0" vendor_size="0" system_sha="n/d"
	if [[ -s "${dest}/system.img" ]]; then
		system_size="$(stat -c '%s' "${dest}/system.img" 2>/dev/null || echo 0)"
		system_sha="$(sha256sum "${dest}/system.img" 2>/dev/null | cut -d' ' -f1 || echo 'n/d')"
	fi
	if [[ -s "${dest}/vendor.img" ]]; then
		vendor_size="$(stat -c '%s' "${dest}/vendor.img" 2>/dev/null || echo 0)"
	fi

	local content
	content="# =============================================================================
#  ${dest}/${ISA_MARKER}
#  Marcatore letto da prismos-waydroid-prepare: se assente o incoerente, il
#  container Waydroid NON viene avviato (evita il loop di riavvio su CPU senza
#  SSE4.2). Rigenerato da scripts/provision_waydroid_image.sh.
# =============================================================================
PRISMOS_ISA_FLOOR=\"x86-SSE4.1\"
PRISMOS_ISA_FORBIDDEN=\"sse4_2 popcnt avx avx2\"
PRISMOS_WAYDROID_ARCH=\"x86\"
PRISMOS_WAYDROID_ABI_LIST=\"${ABI_LIST}\"
PRISMOS_WAYDROID_ABI_64=\"\"
PRISMOS_WAYDROID_ART_FEATURES=\"${ISA_FEATURES_X86}\"
PRISMOS_LINEAGE_VERSION=\"${ARG_VERSION}\"
PRISMOS_ANDROID_VERSION=\"${ANDROID_TARGET}\"
PRISMOS_IMAGE_VARIANT=\"${ARG_VARIANT}\"
PRISMOS_IMAGE_SOURCE=\"${ARG_SOURCE}\"
PRISMOS_IMAGE_URL=\"${source_url}\"
PRISMOS_IMAGE_EDITION=\"${ARG_EDITION}\"
PRISMOS_SYSTEM_IMG_BYTES=\"${system_size}\"
PRISMOS_SYSTEM_IMG_SHA256=\"${system_sha}\"
PRISMOS_VENDOR_IMG_BYTES=\"${vendor_size}\"
PRISMOS_DEEP_VERIFY=\"$( (( ARG_DEEP_VERIFY == 1 )) && echo done || echo skipped )\"
PRISMOS_PROVISIONED_AT=\"$(date -Is)\"
PRISMOS_PROVISIONED_BY=\"${PROG} ${PROG_VERSION}\"
PRISMOS_PROVISIONED_HOST=\"$(hostname -f 2>/dev/null || hostname)\"
PRISMOS_GIT_REVISION=\"$(prismos_git_revision)\"
"

	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] ${marker}"
		printf '%s' "${content}" | sed -n '1,8p' >&2
		return 0
	fi

	local tmp="${WORK_DIR}/${ISA_MARKER}"
	printf '%s' "${content}" > "${tmp}"
	privileged_cp "${tmp}" "${marker}" 0644
	log_ok "marcatore scritto: ${marker}"
}

# =============================================================================
# RICOSTRUZIONE DAI SORGENTI
# =============================================================================
build_from_source() {
	local dest="$1"

	log_banner \
		"Ricostruzione delle immagini Waydroid dai sorgenti" \
		"Checkout: ${ARG_SOURCE_DIR}" \
		"LineageOS ${ARG_VERSION} x86 (Android ${ANDROID_TARGET}) - floor ISA SSE4.1"

	# 1. Verifica del checkout.
	local envsetup="${ARG_SOURCE_DIR}/build/envsetup.sh"
	[[ -f "${envsetup}" ]] || \
		die 2 "checkout LineageOS non valido: ${envsetup} assente (usare repo init -b lineage-${ARG_VERSION})"

	local isa_mk="${ARG_SOURCE_DIR}/vendor/prismos/prismos_isa.mk"
	log_step "Scrittura del vincolo ISA nell'albero dei sorgenti"

	if [[ ${ARG_DRY_RUN} -eq 1 ]]; then
		log_info "[dry-run] ${isa_mk} e compilazione non eseguiti"
		return 0
	fi

	ensure_dir_local "$(dirname "${isa_mk}")"
	cat > "${WORK_DIR}/prismos_isa.mk" <<'ISAMK'
# =============================================================================
#  vendor/prismos/prismos_isa.mk
# -----------------------------------------------------------------------------
#  Vincolo del floor ISA per le immagini Waydroid di prismOS.
#
#  Il target x86 a 32 bit di Android usa SSE3 come baseline: non richiede SSE4.2.
#  Le impostazioni qui sotto impediscono che il toolchain o ART abilitino SSE4.2,
#  POPCNT o AVX, che su Intel Pentium P6100 (Arrandale) producono SIGILL.
# =============================================================================

# Architettura: solo x86 a 32 bit. L'ABI x86_64 e' esclusa perche' le build a
# 64 bit del progetto Waydroid sono compilate con -msse4.2 -mpopcnt.
TARGET_ARCH := x86
TARGET_ARCH_VARIANT := x86
TARGET_CPU_ABI := x86
TARGET_CPU_ABI_LIST := x86,armeabi-v7a,armeabi
TARGET_CPU_ABI_LIST_32BIT := x86,armeabi-v7a,armeabi
TARGET_CPU_ABI_LIST_64BIT :=
TARGET_SUPPORTS_64_BIT_APPS := false
TARGET_IS_64_BIT := false

# Flag del toolchain: SSE3 come baseline, SSE4.2/POPCNT/AVX esplicitamente negati.
PRISMOS_ISA_CFLAGS := -msse3 -mno-sse4.1 -mno-sse4.2 -mno-popcnt -mno-avx -mno-avx2
GLOBAL_CFLAGS   += $(PRISMOS_ISA_CFLAGS)
GLOBAL_CPPFLAGS += $(PRISMOS_ISA_CFLAGS)
PRODUCT_CFLAGS  += $(PRISMOS_ISA_CFLAGS)

# ART: le feature ISA dichiarate al runtime non devono includere SSE4.2.
PRODUCT_PROPERTY_OVERRIDES += \
    dalvik.vm.isa.x86.features=+sse3,+ssse3,+sse4_1,-sse4_2,-popcnt,-avx,-avx2 \
    dalvik.vm.isa.x86.variant=x86 \
    dalvik.vm.isa.x86_64.features= \
    ro.product.cpu.abilist=x86,armeabi-v7a,armeabi \
    ro.product.cpu.abilist32=x86,armeabi-v7a,armeabi \
    ro.product.cpu.abilist64= \
    ro.zygote=zygote32 \
    ro.prismos.isa_floor=x86-SSE4.1

# Nessuna traduzione ARM basata su houdini/libndk_translation: entrambi
# richiedono SSE4.2 o superiore.
PRODUCT_PACKAGES := $(filter-out libhoudini libndk_translation,$(PRODUCT_PACKAGES))

# Compilazione AOT limitata: su macchine con 2 core e 2 GB di RAM la dex2oat
# parallella satura la memoria e fa fallire la build.
DEX2OAT_TARGET_CPU_VARIANT := x86
ISAMK
	cp -f "${WORK_DIR}/prismos_isa.mk" "${isa_mk}"
	log_ok "vincolo ISA scritto: ${isa_mk}"

	# 2. Compilazione.
	log_step "Compilazione di systemimage e vendorimage (${ARG_JOBS} processi)"
	local build_log="${WORK_DIR}/lineage-build.log"
	local build_script="${WORK_DIR}/build.sh"
	cat > "${build_script}" <<BUILDSCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
cd "${ARG_SOURCE_DIR}"
# Il vincolo ISA va agganciato al prodotto: si esporta come makefile incluso da
# tutti i lunch target tramite la variabile d'ambiente della build.
export PRISMOS_ISA_MK="vendor/prismos/prismos_isa.mk"
source build/envsetup.sh
lunch lineage_waydroid_x86-userdebug
m --jobs="${ARG_JOBS}" systemimage vendorimage
BUILDSCRIPT
	chmod 0755 "${build_script}"

	if ! "${build_script}" 2>&1 | tee "${build_log}"; then
		log_error "compilazione LineageOS fallita: log in ${build_log}"
		log_error "  verificare che il prodotto 'lineage_waydroid_x86' esista nel checkout"
		log_error "  e che PRISMOS_ISA_MK sia incluso dal device makefile:"
		log_error "    \$(call include-path-makefiles, \$(PRISMOS_ISA_MK))"
		return 1
	fi

	# 3. Raccolta dei risultati.
	local out_dir="${ARG_SOURCE_DIR}/out/target/product/waydroid_x86"
	[[ -d "${out_dir}" ]] || out_dir="${ARG_SOURCE_DIR}/out/target/product/x86"
	if [[ ! -f "${out_dir}/system.img" ]]; then
		log_error "system.img non prodotta dalla build (attesa in ${out_dir})"
		return 1
	fi

	privileged_cp "${out_dir}/system.img" "${dest}/system.img" 0644
	INSTALLED_SYSTEM="${dest}/system.img"
	log_ok "system.img installata ($(bytes_human "$(stat -c '%s' "${out_dir}/system.img")"))"
	if [[ -f "${out_dir}/vendor.img" ]]; then
		privileged_cp "${out_dir}/vendor.img" "${dest}/vendor.img" 0644
		INSTALLED_VENDOR="${dest}/vendor.img"
		log_ok "vendor.img installata ($(bytes_human "$(stat -c '%s' "${out_dir}/vendor.img")"))"
	fi
	return 0
}

# =============================================================================
# MAIN
# =============================================================================
main() {
	parse_args "$@"

	log_banner \
		"prismOS Waydroid provisioning ${PROG_VERSION}" \
		"Edizione: ${ARG_EDITION}   LineageOS ${ARG_VERSION} (Android ${ANDROID_TARGET}) x86" \
		"Floor ISA: SSE4.1 - SSE4.2/POPCNT/AVX esclusi, ABI x86_64 rifiutata"

	resolve_environment

	local rc=0

	if (( ARG_QUERY_LATEST == 1 )); then
		query_latest || rc=$?
		exit "${rc}"
	fi

	local dest="${ARG_IMAGES_DIR%/}"
	local system_url="" vendor_url=""
	local archive_path=""

	case "${ARG_SOURCE}" in
		build)
			build_from_source "${dest}" || rc=$?
			if (( rc != 0 )); then
				exit "${rc}"
			fi
			;;
		local)
			archive_path="${ARG_ARCHIVE}"
			log_step "Archivio locale: ${archive_path}"
			extract_archive "${archive_path}" "${dest}" || exit 1
			;;
		prismos|upstream)
			system_url="${ARG_SYSTEM_URL:-$(build_url system)}"
			vendor_url="${ARG_VENDOR_URL:-$(build_url vendor)}"
			if [[ -z "${system_url}" ]]; then
				die 2 "URL di system non determinabile: indicare --system-url"
			fi
			if [[ -z "${ARG_DATE}" && "${ARG_SOURCE}" == "upstream" && -z "${ARG_SYSTEM_URL}" ]]; then
				log_warn "--date non specificato: per la sorgente upstream e' obbligatorio"
				log_warn "  elencare le build disponibili: ${PROG} --edition ${ARG_EDITION} --query-latest --source upstream"
				die 2 "data della build mancante"
			fi

			# Immagini gia' presenti: si evita di riscaricare ~700 MB.
			if [[ -s "${dest}/system.img" && ${ARG_FORCE} -eq 0 && ${ARG_DRY_RUN} -eq 0 ]]; then
				log_info "system.img gia' presente in ${dest} ($(bytes_human "$(stat -c '%s' "${dest}/system.img")"))"
				log_info "  usare --force per riscaricarla"
				INSTALLED_SYSTEM="${dest}/system.img"
				if [[ -s "${dest}/vendor.img" ]]; then
					INSTALLED_VENDOR="${dest}/vendor.img"
				fi
			else
				local sys_archive="${WORK_DIR}/system.archive"
				local ven_archive="${WORK_DIR}/vendor.archive"
				log_step "Download dell'immagine di system"
				if ! fetch_url "${system_url}" "${sys_archive}"; then
					log_error "download fallito: ${system_url}"
					log_error "  verificare la raggiungibilita' del mirror oppure usare --archive/--build"
					exit 1
				fi
				if [[ -s "${sys_archive}" ]]; then
					verify_checksum "${sys_archive}" || exit 1
					extract_archive "${sys_archive}" "${dest}" || exit 1
				fi

				if [[ -n "${vendor_url}" ]]; then
					log_step "Download dell'immagine di vendor"
					if fetch_url "${vendor_url}" "${ven_archive}"; then
						if [[ -s "${ven_archive}" ]]; then
							verify_checksum "${ven_archive}" || exit 1
							extract_archive "${ven_archive}" "${dest}" || \
								log_warn "estrazione di vendor non riuscita: si conserva quella esistente"
						fi
					else
						log_warn "download di vendor fallito: ${vendor_url}"
						log_warn "  il vendor MAINLINE puo' essere riutilizzato se gia' presente"
					fi
				fi
			fi
			;;
	esac

	install_props "${dest}"

	local rc=0
	verify_abi "${dest}" || rc=1
	if (( ARG_DEEP_VERIFY == 1 )); then
		deep_verify_isa "${dest}" || rc=1
	fi

	if (( rc != 0 )); then
		log_error "provisioning completato ma le verifiche ISA sono fallite"
		log_error "  NON avviare il container: su CPU senza SSE4.2 andrebbe in loop di riavvio"
		log_error "  usare --source build oppure un'immagine x86 a 32 bit verificata"
		exit 1
	fi

	write_isa_marker "${dest}" "${system_url:-${archive_path:-build}}"

	log_banner "Esito del provisioning"
	printf '  %s\n' "edizione      : ${ARG_EDITION}" >&2
	printf '  %s\n' "sorgente      : ${ARG_SOURCE} (${ARG_VARIANT})" >&2
	printf '  %s\n' "destinazione  : ${dest}" >&2
	if [[ ${ARG_DRY_RUN} -eq 0 ]]; then
		local f
		for f in system.img vendor.img waydroid_base.prop waydroid_mainline.prop "${ISA_MARKER}"; do
			if [[ -s "${dest}/${f}" ]]; then
				printf '  %-24s %s\n' "${f}" "$(bytes_human "$(stat -c '%s' "${dest}/${f}")")" >&2
			else
				printf '  %-24s %s\n' "${f}" "${PRISMOS_C_YELLOW}assente${PRISMOS_C_RESET}" >&2
			fi
		done
	else
		printf '  %s\n' "[dry-run] nessun file scritto" >&2
	fi
	printf '\n' >&2
	log_ok "sottosistema Android pronto per prismos-waydroid-prepare"
	log_info "avvio manuale: systemctl start prismos-waydroid-container.service"
	log_info "  oppure, nelle edizioni on-demand, aprendo un file .apk"
	exit 0
}

main "$@"
