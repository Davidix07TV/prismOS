#!/usr/bin/env bash
# =============================================================================
#  scripts/lib/prismos_common.sh
# -----------------------------------------------------------------------------
#  Libreria condivisa degli script prismOS. Non e' eseguibile: viene sorgiata.
#
#  Fornisce:
#    * logging colorato e strutturato (info/warn/error/step/debug)
#    * gestione errori con trappola e report del comando fallito
#    * interrogazione JSON senza dipendenze (python3, con fallback su jq)
#    * rilevamento dell'ambiente cros_sdk (host oppure dentro il chroot)
#    * validazione delle edizioni e dei percorsi della repository
# =============================================================================

# Protezione contro il doppio sourcing.
if [[ -n "${_PRISMOS_COMMON_SH:-}" ]]; then
	return 0 2>/dev/null || true
fi
_PRISMOS_COMMON_SH=1

# --- prerequisiti di shell ----------------------------------------------------
if [[ -z "${BASH_VERSION:-}" ]]; then
	echo "prismOS: questo script richiede bash (rilevato: ${0})" >&2
	return 1 2>/dev/null || exit 1
fi
if (( BASH_VERSINFO[0] < 5 )); then
	echo "prismOS: richiede bash 5 o superiore (rilevato ${BASH_VERSION})" >&2
	return 1 2>/dev/null || exit 1
fi

set -o errexit
set -o nounset
set -o pipefail
shopt -s inherit_errexit
shopt -s extglob
shopt -s nullglob

# --- percorsi ------------------------------------------------------------------
PRISMOS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRISMOS_SCRIPTS_DIR="$(cd "${PRISMOS_LIB_DIR}/.." && pwd)"
PRISMOS_ROOT="$(cd "${PRISMOS_SCRIPTS_DIR}/.." && pwd)"
readonly PRISMOS_LIB_DIR PRISMOS_SCRIPTS_DIR PRISMOS_ROOT

PRISMOS_PROFILES_DIR="${PRISMOS_ROOT}/profiles"
PRISMOS_OVERLAYS_DIR="${PRISMOS_ROOT}/overlays"
PRISMOS_KERNEL_DIR="${PRISMOS_ROOT}/kernel"
PRISMOS_OUTPUT_DIR="${PRISMOS_ROOT}/output"
PRISMOS_BUILD_DIR="${PRISMOS_ROOT}/build"
PRISMOS_LOG_DIR="${PRISMOS_BUILD_DIR}/logs"
readonly PRISMOS_PROFILES_DIR PRISMOS_OVERLAYS_DIR PRISMOS_KERNEL_DIR
readonly PRISMOS_OUTPUT_DIR PRISMOS_BUILD_DIR PRISMOS_LOG_DIR

PRISMOS_APP_POOL="${PRISMOS_PROFILES_DIR}/app_pool.json"
PRISMOS_EDITIONS=(edu home work slim pro)
PRISMOS_DEFAULT_BOARD="amd64-prismos"
PRISMOS_DEFAULT_SDK="${HOME}/chromiumos/cros_sdk"

# --- colore (disattivato se stdout non e' un terminale o NO_COLOR e' impostato) --
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
	PRISMOS_C_RESET=$'\033[0m'
	PRISMOS_C_BOLD=$'\033[1m'
	PRISMOS_C_DIM=$'\033[2m'
	PRISMOS_C_RED=$'\033[0;31m'
	PRISMOS_C_GREEN=$'\033[0;32m'
	PRISMOS_C_YELLOW=$'\033[0;33m'
	PRISMOS_C_BLUE=$'\033[0;34m'
	PRISMOS_C_MAGENTA=$'\033[0;35m'
	PRISMOS_C_CYAN=$'\033[0;36m'
else
	PRISMOS_C_RESET='' PRISMOS_C_BOLD='' PRISMOS_C_DIM='' PRISMOS_C_RED=''
	PRISMOS_C_GREEN='' PRISMOS_C_YELLOW='' PRISMOS_C_BLUE=''
	PRISMOS_C_MAGENTA='' PRISMOS_C_CYAN=''
fi

PRISMOS_LOG_LEVEL="${PRISMOS_LOG_LEVEL:-info}"
PRISMOS_LOG_FILE="${PRISMOS_LOG_FILE:-}"

_prismos_level_rank() {
	case "${1:-info}" in
		debug) echo 10 ;;
		info)  echo 20 ;;
		warn)  echo 30 ;;
		error) echo 40 ;;
		*)     echo 20 ;;
	esac
}

_prismos_log() {
	local level="$1" color="$2" label="$3"
	shift 3
	local message="$*"
	local ts
	ts="$(date '+%H:%M:%S')"

	if (( $(_prismos_level_rank "${level}") >= $(_prismos_level_rank "${PRISMOS_LOG_LEVEL}") )); then
		printf '%s%s [%s]%s %s%s%s\n' \
			"${color}" "${label}" "${ts}" "${PRISMOS_C_RESET}" \
			"${PRISMOS_C_BOLD}" "${message}" "${PRISMOS_C_RESET}" >&2
	fi

	if [[ -n "${PRISMOS_LOG_FILE}" ]]; then
		printf '%s [%s] %s\n' "$(date -Is)" "${level}" "${message}" \
			>> "${PRISMOS_LOG_FILE}" 2>/dev/null || true
	fi
}

log_debug() { _prismos_log debug "${PRISMOS_C_DIM}"    "DEBUG" "$@"; }
log_info()  { _prismos_log info  "${PRISMOS_C_CYAN}"   "INFO " "$@"; }
log_ok()    { _prismos_log info  "${PRISMOS_C_GREEN}"  "OK   " "$@"; }
log_warn()  { _prismos_log warn  "${PRISMOS_C_YELLOW}" "WARN " "$@"; }
log_error() { _prismos_log error "${PRISMOS_C_RED}"    "ERROR" "$@"; }

log_step() {
	printf '\n%s%s==> %s%s\n' "${PRISMOS_C_MAGENTA}" "${PRISMOS_C_BOLD}" "$*" "${PRISMOS_C_RESET}" >&2
	if [[ -n "${PRISMOS_LOG_FILE}" ]]; then
		printf '%s [STEP] %s\n' "$(date -Is)" "$*" >> "${PRISMOS_LOG_FILE}" 2>/dev/null || true
	fi
}

log_banner() {
	local line
	line="$(printf '=%.0s' {1..78})"
	printf '\n%s%s%s%s\n' "${PRISMOS_C_BLUE}" "${PRISMOS_C_BOLD}" "${line}" "${PRISMOS_C_RESET}" >&2
	while (( $# > 0 )); do
		printf '%s%s  %s%s\n' "${PRISMOS_C_BLUE}" "${PRISMOS_C_BOLD}" "$1" "${PRISMOS_C_RESET}" >&2
		shift
	done
	printf '%s%s%s%s\n' "${PRISMOS_C_BLUE}" "${PRISMOS_C_BOLD}" "${line}" "${PRISMOS_C_RESET}" >&2
}

die() {
	local code="${1:-1}"
	shift || true
	log_error "$*"
	exit "${code}"
}

# Trappola di errore: riporta comando, riga e funzione in cui e' avvenuto.
prismos_trap_error() {
	local exit_code=$1 line=${2:-?} cmd=${3:-?} func=${4:-main}
	log_error "comando fallito con codice ${exit_code}"
	log_error "  riga    : ${line}"
	log_error "  funzione: ${func}"
	log_error "  comando : ${cmd}"
	if [[ -n "${PRISMOS_LOG_FILE}" ]]; then
		log_error "  log     : ${PRISMOS_LOG_FILE}"
	fi
}

prismos_install_error_trap() {
	trap 'prismos_trap_error $? ${LINENO} "${BASH_COMMAND}" "${FUNCNAME[0]:-main}"' ERR
}

# --- utilita' generiche ---------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
	local missing=()
	local c
	for c in "$@"; do
		have_cmd "${c}" || missing+=("${c}")
	done
	if (( ${#missing[@]} > 0 )); then
		die 1 "comandi obbligatori non trovati: ${missing[*]}"
	fi
}

# Assicura che una directory esista.
ensure_dir() {
	local d
	for d in "$@"; do
		[[ -d "${d}" ]] || mkdir -p "${d}" || die 1 "impossibile creare ${d}"
	done
}

# Copia ricorsiva preserving mode/ownership quando possibile.
copy_tree() {
	local src="$1" dst="$2"
	[[ -d "${src}" ]] || return 0
	mkdir -p "${dst}" || die 1 "impossibile creare ${dst}"
	cp -a "${src}/." "${dst}/" || die 1 "copia di ${src} in ${dst} fallita"
}

bytes_human() {
	local bytes="${1:-0}"
	awk -v b="${bytes}" 'BEGIN {
		split("B KiB MiB GiB TiB", u, " ");
		i = 1;
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i];
	}'
}

# --- JSON -------------------------------------------------------------------------
# Motore JSON: python3 (sempre presente nel cros_sdk); jq come alternativa.
prismos_json_engine() {
	if have_cmd python3; then echo "python3"; return 0; fi
	if have_cmd jq; then echo "jq"; return 0; fi
	echo ""
}

# Valida sintatticamente un file JSON.
json_validate() {
	local file="$1"
	[[ -f "${file}" ]] || { log_error "file JSON inesistente: ${file}"; return 1; }
	case "$(prismos_json_engine)" in
		python3)
			python3 -c 'import json,sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        json.load(fh)
except Exception as exc:
    sys.stderr.write("%s\n" % exc)
    sys.exit(1)' "${file}"
			;;
		jq) jq empty "${file}" ;;
		*)  log_error "nessun motore JSON disponibile (python3 o jq)"; return 1 ;;
	esac
}

# Esegue un programma python3 con accesso al pool di applicazioni.
# Uso: json_run <file.json> <<'PY' ... PY
json_run() {
	local file="$1"
	have_cmd python3 || die 1 "python3 e' obbligatorio per le operazioni sul pool di applicazioni"
	PRISMOS_JSON_FILE="${file}" python3 - "${file}"
}

# Ritorna il numero di applicazioni del pool.
json_app_count() {
	json_run "${PRISMOS_APP_POOL}" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(len(data.get("applications", [])))
PY
}

# Elenca le applicazioni del pool filtrate per edizione.
# Output: una riga per app con campi separati da TAB:
#   index \t id \t name \t type \t launch_url \t icon \t preselected(0|1)
json_list_apps() {
	local edition="${1:-all}"
	json_run "${PRISMOS_APP_POOL}" <<PY
import json, os, sys
edition = "${edition}"
with open(os.environ["PRISMOS_JSON_FILE"], encoding="utf-8") as fh:
    data = json.load(fh)
bundle = data.get("flavor_bundles", {}).get(edition, {})
preselected = set(bundle.get("preselected", []))
blocked = set(bundle.get("blocked_by_policy", []))
index = 0
# PRO is the all-in-one image: like "all", it sees every application of the
# pool; its bundle decides what is preselected and pinned.
inclusive = edition in ("all", "pro")
for app in data.get("applications", []):
    flavors = app.get("flavors", [])
    if not inclusive and edition not in flavors:
        continue
    if not inclusive and app.get("id") in blocked:
        continue
    index += 1
    flag = "1" if app.get("id") in preselected else "0"
    print("\t".join([
        str(index),
        str(app.get("id", "")),
        str(app.get("name", "")),
        str(app.get("type", "")),
        str(app.get("launch_url", "")),
        str(app.get("icon", "")),
        flag,
    ]))
PY
}

# Restituisce il JSON completo di una singola applicazione per id.
json_get_app() {
	local app_id="$1"
	json_run "${PRISMOS_APP_POOL}" <<PY
import json, os, sys
with open(os.environ["PRISMOS_JSON_FILE"], encoding="utf-8") as fh:
    data = json.load(fh)
for app in data.get("applications", []):
    if app.get("id") == "${app_id}":
        print(json.dumps(app, ensure_ascii=False))
        break
PY
}

# Restituisce una chiave di primo livello del bundle di edizione.
json_get_bundle_key() {
	local edition="$1" key="$2"
	json_run "${PRISMOS_APP_POOL}" <<PY
import json, os, sys
with open(os.environ["PRISMOS_JSON_FILE"], encoding="utf-8") as fh:
    data = json.load(fh)
bundle = data.get("flavor_bundles", {}).get("${edition}", {})
value = bundle.get("${key}", [])
if isinstance(value, list):
    print("\n".join(str(v) for v in value))
else:
    print(value)
PY
}

# Valida il pool contro le regole dichiarate in "validation".
json_validate_pool() {
	local file="${1:-${PRISMOS_APP_POOL}}"
	json_run "${file}" <<'PY'
import json, os, sys

path = os.environ["PRISMOS_JSON_FILE"]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)

rules = data.get("validation", {})
required = rules.get("required_fields", ["id", "name", "type", "launch_url", "icon"])
allowed_types = set(rules.get("allowed_types", ["Web_App", "Android_Pkg", "Windows_Pkg"]))
allowed_cats = set(rules.get("allowed_categories", []))
errors = []
ids = set()
urls = set()

apps = data.get("applications", [])
if not apps:
    errors.append("nessuna applicazione nel pool")

for app in apps:
    aid = app.get("id", "<senza id>")
    for field in required:
        if field not in app or app[field] in ("", None):
            errors.append(f"{aid}: campo obbligatorio mancante '{field}'")
    if aid in ids:
        errors.append(f"{aid}: id duplicato")
    ids.add(aid)
    url = app.get("launch_url")
    if url in urls:
        errors.append(f"{aid}: launch_url duplicata '{url}'")
    urls.add(url)
    if app.get("type") not in allowed_types:
        errors.append(f"{aid}: tipo non ammesso '{app.get('type')}'")
    if allowed_cats and app.get("category") not in allowed_cats:
        errors.append(f"{aid}: categoria non ammessa '{app.get('category')}'")
    if app.get("sse42_required") is not False:
        errors.append(f"{aid}: sse42_required deve essere false (floor ISA SSE4.1)")
    if app.get("type") == "Android_Pkg" and not app.get("android_package"):
        errors.append(f"{aid}: Android_Pkg senza android_package")
    if app.get("type") == "Android_Pkg" and app.get("arm_translation_required") is not False:
        errors.append(f"{aid}: traduzione ARM non ammessa (richiede SSE4.2)")
    if app.get("type") == "Windows_Pkg" and not app.get("wine_prefix"):
        errors.append(f"{aid}: Windows_Pkg senza wine_prefix")

for eid, bundle in data.get("flavor_bundles", {}).items():
    for key in ("preselected", "default_pinned", "blocked_by_policy"):
        for ref in bundle.get(key, []):
            if ref not in ids:
                errors.append(f"bundle {eid}.{key}: applicazione sconosciuta '{ref}'")

for key in ("schema_version", "pool_id", "isa_floor", "applications", "flavor_bundles"):
    if key not in data:
        errors.append(f"chiave di primo livello mancante: {key}")

if data.get("isa_floor") not in ("x86_64-SSE4.1", "x86_64-SSSE3"):
    errors.append(f"isa_floor non ammesso: {data.get('isa_floor')}")

if errors:
    sys.stderr.write("validazione del pool fallita (%d errori):\n" % len(errors))
    for err in errors:
        sys.stderr.write("  - %s\n" % err)
    sys.exit(1)
print("%d applicazioni valide (%d web, %d android, %d windows)" % (
    len(apps),
    sum(1 for a in apps if a.get("type") == "Web_App"),
    sum(1 for a in apps if a.get("type") == "Android_Pkg"),
    sum(1 for a in apps if a.get("type") == "Windows_Pkg"),
))
PY
}

# --- edizioni -----------------------------------------------------------------------
is_valid_edition() {
	local edition="$1" e
	for e in "${PRISMOS_EDITIONS[@]}"; do
		[[ "${e}" == "${edition}" ]] && return 0
	done
	return 1
}

edition_display_name() {
	case "$1" in
		edu)  echo "prismOS EDU" ;;
		home) echo "prismOS Home" ;;
		work) echo "prismOS Work" ;;
		slim) echo "prismOS Slim" ;;
		*)    echo "prismOS ${1}" ;;
	esac
}

# --- ambiente cros_sdk -----------------------------------------------------------------
# Ritorna 0 se lo script sta girando DENTRO il chroot di cros_sdk.
prismos_in_chroot() {
	[[ -d /mnt/host/source ]] && [[ -x /usr/bin/cros ]] && return 0
	[[ -n "${PRISMOS_FORCE_CHROOT:-}" ]] && return 0
	return 1
}

# Risolve la directory del cros_sdk (argomento > variabile d'ambiente > default).
# prismos_resolve_sdk CANDIDATE
# Normalizza --sdk-dir e restituisce la RADICE del checkout ChromiumOS, cioe'
# la directory che contiene l'eseguibile cros_sdk e src/overlays. Layout
# accettati:
#   1. percorso dell'eseguibile cros_sdk        -> dirname (checkout reale)
#   2. radice del checkout (<root>/cros_sdk + <root>/src)
#   3. layout legacy/stub (<root>/cros_sdk/ directory con dentro l'eseguibile
#      e <root>/src accanto)                    -> dirname
#   4. solo <root>/cros_sdk eseguibile, src non ancora sincronizzato
prismos_resolve_sdk() {
	local candidate="${1:-}"
	if [[ -z "${candidate}" ]]; then
		candidate="${PRISMOS_SDK_DIR:-${CROS_SDK_DIR:-${PRISMOS_DEFAULT_SDK}}}"
	fi
	[[ -n "${candidate}" ]] || return 1
	# 1. path diretto all'eseguibile cros_sdk
	if [[ -x "${candidate}" && ! -d "${candidate}" ]]; then
		candidate="$(dirname "${candidate}")"
	fi
	[[ -d "${candidate}" ]] || return 1
	# 2. layout reale: radice con cros_sdk eseguibile e src/
	if [[ -x "${candidate}/cros_sdk" && -d "${candidate}/src" ]]; then
		printf '%s' "$(cd "${candidate}" && pwd)"
		return 0
	fi
	# 3. layout legacy/stub: <candidate>/cros_sdk e' l'eseguibile e src/ sta
	#    accanto a candidate (harness CI: <root>/cros_sdk/cros_sdk + <root>/src)
	if [[ -x "${candidate}/cros_sdk" && -d "$(dirname "${candidate}")/src" ]]; then
		printf '%s' "$(cd "$(dirname "${candidate}")" && pwd)"
		return 0
	fi
	# 4. cros_sdk presente ma src non ancora sincronizzato
	if [[ -x "${candidate}/cros_sdk" ]]; then
		printf '%s' "$(cd "${candidate}" && pwd)"
		return 0
	fi
	return 1
}

# Esegue un comando dentro il chroot (o direttamente se gia' dentro).
cros_sdk_run() {
	if prismos_in_chroot; then
		log_debug "[chroot] $*"
		"$@"
		return $?
	fi
	local sdk="${PRISMOS_SDK_RESOLVED:-}"
	[[ -n "${sdk}" ]] || die 1 "cros_sdk non risolto: usare --sdk-dir <percorso>"
	log_debug "[host] (cd ${sdk} && ./cros_sdk -- $*)"
	( cd "${sdk}" && ./cros_sdk -- "$@" )
}

# Esegue una riga di shell dentro il chroot.
cros_sdk_shell() {
	local script="$1"
	if prismos_in_chroot; then
		log_debug "[chroot] bash -lc <script>"
		bash -lc "${script}"
		return $?
	fi
	local sdk="${PRISMOS_SDK_RESOLVED:-}"
	[[ -n "${sdk}" ]] || die 1 "cros_sdk non risolto: usare --sdk-dir <percorso>"
	( cd "${sdk}" && ./cros_sdk -- bash -lc "${script}" )
}

# Percorso della repository visto da dentro il chroot.
prismos_chroot_source_dir() {
	printf '%s' "/mnt/host/source/src/overlays/prismOS"
}

# --- parsing di selezioni numeriche ---------------------------------------------------------
# Converte "1,3,5-7,10" in un elenco di indici unici e ordinati.
# Uso: parse_selection "1,3,5-7" <max_index>
parse_selection() {
	local input="$1" max="$2"
	local out=() parts=()
	local part first last i

	input="${input//[[:space:]]/,}"
	input="${input//;;/,}"
	IFS=',' read -r -a parts <<< "${input}"

	for part in "${parts[@]}"; do
		[[ -n "${part}" ]] || continue
		case "${part}" in
			all|ALL|'*')
				for (( i = 1; i <= max; i++ )); do out+=("${i}"); done
				;;
			none|NONE|'-')
				;;
			*-*|*..*)
				first="${part%%[-.]*}"
				last="${part##*[-.]}"
				[[ "${first}" =~ ^[0-9]+$ && "${last}" =~ ^[0-9]+$ ]] || \
					{ log_error "intervallo non valido: ${part}"; return 1; }
				if (( first > last )); then
					local tmp="${first}"; first="${last}"; last="${tmp}"
				fi
				for (( i = first; i <= last; i++ )); do out+=("${i}"); done
				;;
			*)
				[[ "${part}" =~ ^[0-9]+$ ]] || { log_error "indice non numerico: ${part}"; return 1; }
				out+=("${part}")
				;;
		esac
	done

	# Deduplica e ordinamento numerico, con validazione del range.
	local valid=()
	for i in "${out[@]:-}"; do
		[[ -n "${i}" ]] || continue
		if (( i < 1 || i > max )); then
			log_warn "indice fuori range ignorato: ${i} (range 1-${max})"
			continue
		fi
		valid+=("${i}")
	done
	if (( ${#valid[@]} == 0 )); then
		return 0
	fi
	printf '%s\n' "${valid[@]}" | sort -n -u | paste -sd' ' -
}

# --- fingerprint della build -------------------------------------------------------------
prismos_build_stamp() { date -u '+%Y%m%d-%H%M%S'; }

prismos_git_revision() {
	if [[ -d "${PRISMOS_ROOT}/.git" ]] && have_cmd git; then
		git -C "${PRISMOS_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown"
	else
		echo "unknown"
	fi
}

prismos_host_summary() {
	printf 'CPU: %s | RAM: %s | core: %s' \
		"$(awk -F: '/^model name/ { gsub(/^ +/,"",$2); print $2; exit }' /proc/cpuinfo 2>/dev/null || echo 'n/d')" \
		"$(awk '/^MemTotal:/ { printf "%.0f MiB", $2/1024 }' /proc/meminfo 2>/dev/null || echo 'n/d')" \
		"$(nproc 2>/dev/null || echo 'n/d')"
}
