#!/usr/bin/env bash
# =============================================================================
#  prismOS :: scripts/verify_legacy_cpu.sh
# -----------------------------------------------------------------------------
#  Verifica del floor ISA x86-64 SSE4.1: nessun binario dell'immagine deve
#  contenere istruzioni che una CPU senza SSE4.2 (Intel Pentium P6100,
#  Arrandale, Celeron P4xxx, Core i3/i5/i7 di prima generazione) non possa
#  eseguire. Un'istruzione SSE4.2 su tali CPU produce SIGILL immediato.
#
#  METODO IN DUE FASI
#    Fase 1 (prefilter, veloce): ricerca nei byte del file delle codifiche
#      univoche delle istruzioni proibite. Nessun disassemblatore richiesto.
#    Fase 2 (conferma, precisa): i soli candidati della fase 1 vengono
#      disassemblati con objdump e le istruzioni sono identificate per
#      mnemonico, cosi' da eliminare i falsi positivi dovuti a dati che
#      casualmente riproducono una codifica.
#
#  LIBRERIE CON DISPATCH A RUNTIME
#    glibc (libc.so.6, libm.so.6), OpenSSL, zlib, LLVM/Mesa e i driver DRI
#    contengono LEGITTIMAMENTE percorsi SSE4.2/AVX selezionati a runtime con
#    IFUNC + CPUID: su CPU prive di SSE4.2 quelle funzioni non vengono mai
#    chiamate. Le evidenze su questi file sono classificate "dispatched" e
#    NON costituiscono errore (restano visibili con --verbose). Sono invece
#    critiche le evidenze su chrome, wine, waydroid e sui pacchetti prismOS,
#    compilati con un -march fisso.
#
#  USO
#    verify_legacy_cpu.sh --pe <binario>
#    verify_legacy_cpu.sh --rootfs <albero> [--full]
#    verify_legacy_cpu.sh --board amd64-prismos
#    verify_legacy_cpu.sh --image <chromiumos_image.bin>
#    verify_legacy_cpu.sh --config
#    verify_legacy_cpu.sh --host
#
#  CODICI DI USCITA
#    0  nessuna istruzione proibita
#    1  trovata almeno una istruzione proibita non dispatchata
#    2  errore d'uso o ambiente incompleto
# =============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit extglob nullglob

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
# shellcheck source=scripts/lib/prismos_common.sh
source "$(dirname "${SCRIPT_PATH}")/lib/prismos_common.sh"
prismos_install_error_trap

readonly PROG="$(basename "${SCRIPT_PATH}")"
readonly PROG_VERSION="1.0.0"

# Set di istruzioni verificato di default. sse4.2 comprende POPCNT e CRC32,
# che in GCC sono bit ISA indipendenti e vengono abilitati da -march=nehalem.
readonly DEFAULT_ISA_CHECKS="sse4.2,popcnt,crc32,avx,aes,pclmul,bmi,f16c"

# Percorsi critici all'interno di una rootfs ChromiumOS.
readonly CRITICAL_PATHS=(
	/opt/google/chrome
	/usr/lib64/chromium-browser
	/usr/lib/chromium-browser
	/usr/lib64/wine
	/usr/lib/wine
	/usr/lib32/wine
	/usr/lib64/waydroid
	/usr/lib/waydroid
	/var/lib/waydroid
	/usr/lib64/lxc
	/usr/bin/prismos-waydroid-prepare
	/usr/bin/prismos-waydroid-cleanup
	/usr/libexec/prismos
)

# --- opzioni ----------------------------------------------------------------------------
MODE=""
ARG_TARGET=""
ARG_BOARD=""
ARG_FULL=0
ARG_STRICT=0
ARG_ISA_CHECKS="${DEFAULT_ISA_CHECKS}"
ARG_JOBS=""
ARG_REPORT=""
ARG_JSON=""
ARG_VERBOSE=0
ARG_QUIET=0
ARG_MAX_BYTES=$(( 512 * 1024 * 1024 ))
MOUNT_CREATED=""
LOOP_DEVICE=""
SCAN_ROOT_PREFIX=""
WORK_DIR=""

usage() {
	cat <<USAGE
${PRISMOS_C_BOLD}prismOS ${PROG_VERSION} - verifica del floor ISA SSE4.1${PRISMOS_C_RESET}

USO
  ${PROG} --pe <binario>            verifica un singolo eseguibile (ELF o PE)
  ${PROG} --rootfs <albero>         verifica una rootfs estratta o montata
  ${PROG} --board <nome>            verifica /build/<nome> nel chroot cros_sdk
  ${PROG} --image <file.img>        monta l'immagine ChromiumOS e la verifica
  ${PROG} --config                  verifica la configurazione della repository
  ${PROG} --host                    riporta le capacita' ISA della CPU corrente

OPZIONI
  --full                con --rootfs/--board/--image scansiona TUTTI gli ELF,
                        non solo i percorsi critici (molto piu' lento)
  --check-isa LISTA     istruzioni da cercare, separate da virgola
                        (default: ${DEFAULT_ISA_CHECKS})
                        valori: sse4.2 popcnt crc32 avx aes pclmul bmi f16c
  --strict              tratta come errore anche AVX/AES/PCLMUL/BMI/F16C, che di
                        default producono solo un avviso (SSE4.2 resta fatale)
  --jobs N              thread paralleli per il disassemblatore (default: nproc)
  --max-bytes N         ignora i file piu' grandi di N byte (default: 536870912)
  --report FILE         scrive il rapporto testuale anche in FILE
  --json FILE           scrive il rapporto strutturato anche in FILE (JSON)
  --verbose             elenca anche le evidenze "dispatched" e i dettagli
  --quiet               solo il riepilogo finale
  -h, --help            questo messaggio
  -V, --version         versione

ESEMPI
  ${PROG} --pe ~/Downloads/installer.exe
  ${PROG} --rootfs /mnt/loop/rootfs --full --report /tmp/rapporto.txt
  ${PROG} --board amd64-prismos --json output/isa-report.json
  ${PROG} --config --verbose

NOTE
  Le librerie con dispatch IFUNC (glibc, OpenSSL, LLVM/Mesa) sono escluse dal
  giudizio di fallimento: i loro percorsi SSE4.2 non vengono mai selezionati su
  una CPU che non li supporta. Usare --verbose per ispezionarle.
USAGE
}

parse_args() {
	local mode_count=0
	while (( $# > 0 )); do
		case "$1" in
			--pe|--elf|--exe)   MODE="pe"; ARG_TARGET="${2:-}"; shift 2 ;;
			--pe=*)             MODE="pe"; ARG_TARGET="${1#*=}"; shift ;;
			--rootfs)           MODE="rootfs"; ARG_TARGET="${2:-}"; shift 2 ;;
			--rootfs=*)         MODE="rootfs"; ARG_TARGET="${1#*=}"; shift ;;
			--board)            MODE="board"; ARG_BOARD="${2:-}"; shift 2 ;;
			--board=*)          MODE="board"; ARG_BOARD="${1#*=}"; shift ;;
			--image)            MODE="image"; ARG_TARGET="${2:-}"; shift 2 ;;
			--image=*)          MODE="image"; ARG_TARGET="${1#*=}"; shift ;;
			--config)           MODE="config"; shift ;;
			--host)             MODE="host"; shift ;;
			--full)             ARG_FULL=1; shift ;;
			--strict)           ARG_STRICT=1; shift ;;
			--check-isa)        ARG_ISA_CHECKS="${2:-}"; shift 2 ;;
			--check-isa=*)      ARG_ISA_CHECKS="${1#*=}"; shift ;;
			--jobs)             ARG_JOBS="${2:-}"; shift 2 ;;
			--jobs=*)           ARG_JOBS="${1#*=}"; shift ;;
			--max-bytes)        ARG_MAX_BYTES="${2:-}"; shift 2 ;;
			--max-bytes=*)      ARG_MAX_BYTES="${1#*=}"; shift ;;
			--report)           ARG_REPORT="${2:-}"; shift 2 ;;
			--report=*)         ARG_REPORT="${1#*=}"; shift ;;
			--json)             ARG_JSON="${2:-}"; shift 2 ;;
			--json=*)           ARG_JSON="${1#*=}"; shift ;;
			-v|--verbose)       ARG_VERBOSE=1; PRISMOS_LOG_LEVEL="debug"; shift ;;
			-q|--quiet)         ARG_QUIET=1; PRISMOS_LOG_LEVEL="error"; shift ;;
			-h|--help)          usage; exit 0 ;;
			-V|--version)       echo "${PROG} ${PROG_VERSION}"; exit 0 ;;
			--)                 shift; break ;;
			-*)                 usage >&2; die 2 "opzione sconosciuta: $1" ;;
			*)                  usage >&2; die 2 "argomento inatteso: $1" ;;
		esac
	done

	if [[ -z "${MODE}" ]]; then
		usage >&2
		die 2 "indicare una modalita': --pe, --rootfs, --board, --image, --config, --host"
	fi

	if [[ -n "${ARG_JOBS}" ]] && ! [[ "${ARG_JOBS}" =~ ^[0-9]+$ ]]; then
		die 2 "--jobs richiede un intero positivo: '${ARG_JOBS}'"
	fi
	if ! [[ "${ARG_MAX_BYTES}" =~ ^[0-9]+$ ]]; then
		die 2 "--max-bytes richiede un intero: '${ARG_MAX_BYTES}'"
	fi

	local isa
	ARG_ISA_CHECKS="${ARG_ISA_CHECKS// /}"
	IFS=',' read -r -a _isa_list <<< "${ARG_ISA_CHECKS}"
	for isa in "${_isa_list[@]}"; do
		case "${isa,,}" in
			sse4.2|sse42|popcnt|crc32|avx|aes|pclmul|bmi|f16c) ;;
			"") ;;
			*) die 2 "--check-isa: valore non riconosciuto '${isa}' (ammessi: sse4.2, popcnt, crc32, avx, aes, pclmul, bmi, f16c)" ;;
		esac
	done
	unset _isa_list

	case "${MODE}" in
		pe)
			[[ -n "${ARG_TARGET}" ]] || die 2 "--pe richiede il percorso di un binario"
			[[ -f "${ARG_TARGET}" ]] || die 2 "binario inesistente: ${ARG_TARGET}"
			;;
		rootfs)
			[[ -n "${ARG_TARGET}" ]] || die 2 "--rootfs richiede il percorso di un albero"
			[[ -d "${ARG_TARGET}" ]] || die 2 "albero inesistente: ${ARG_TARGET}"
			ARG_TARGET="$(cd "${ARG_TARGET}" && pwd)"
			;;
		board)
			[[ -n "${ARG_BOARD}" ]] || die 2 "--board richiede il nome del board"
			if [[ -d "/build/${ARG_BOARD}" ]]; then
				ARG_TARGET="/build/${ARG_BOARD}"
			elif [[ -n "${PRISMOS_SDK_RESOLVED:-}" && -d "$(dirname "${PRISMOS_SDK_RESOLVED}")/chroot/build/${ARG_BOARD}" ]]; then
				ARG_TARGET="$(dirname "${PRISMOS_SDK_RESOLVED}")/chroot/build/${ARG_BOARD}"
			elif [[ -d "${HOME}/chromiumos/chroot/build/${ARG_BOARD}" ]]; then
				ARG_TARGET="${HOME}/chromiumos/chroot/build/${ARG_BOARD}"
			else
				die 2 "sysroot del board non trovato per '${ARG_BOARD}': eseguire la verifica dentro il chroot oppure usare --rootfs"
			fi
			;;
		image)
			[[ -n "${ARG_TARGET}" ]] || die 2 "--image richiede il percorso di un file .img/.bin"
			[[ -f "${ARG_TARGET}" ]] || die 2 "immagine inesistente: ${ARG_TARGET}"
			;;
	esac

	[[ -n "${ARG_JOBS}" ]] || ARG_JOBS="$(nproc 2>/dev/null || echo 4)"
}

# =============================================================================
# SCANSIONE (motore python in due fasi)
# =============================================================================
run_scanner() {
	local file_list="$1"

	PRISMOS_ISA_CHECKS="${ARG_ISA_CHECKS}" \
	PRISMOS_ISA_JOBS="${ARG_JOBS}" \
	PRISMOS_ISA_MAX_BYTES="${ARG_MAX_BYTES}" \
	PRISMOS_ISA_VERBOSE="${ARG_VERBOSE}" \
	PRISMOS_ISA_ROOT="${SCAN_ROOT_PREFIX:-}" \
	python3 - "${file_list}" <<'PY'
import concurrent.futures as futures
import json
import os
import re
import subprocess
import sys

file_list_path = sys.argv[1]
checks = {c.strip().lower().replace("sse42", "sse4.2")
          for c in os.environ.get("PRISMOS_ISA_CHECKS", "").split(",") if c.strip()}
jobs = max(1, int(os.environ.get("PRISMOS_ISA_JOBS", "4") or 4))
max_bytes = int(os.environ.get("PRISMOS_ISA_MAX_BYTES", str(512 * 1024 * 1024)))
verbose = os.environ.get("PRISMOS_ISA_VERBOSE") == "1"
root_prefix = os.environ.get("PRISMOS_ISA_ROOT", "")

# ---------------------------------------------------------------------------
# Codifiche byte delle istruzioni proibite (x86-64).
# Ogni voce: (famiglia, [prefissi byte]). Le varianti REX (0x40-0x4F) sono
# generate esplicitamente per evitare falsi negativi.
# ---------------------------------------------------------------------------
REX = [bytes([r]) for r in range(0x40, 0x50)]


def with_rex(core):
    """Ritorna core e le sue varianti precedute da un byte REX."""
    out = [bytes(core)]
    for r in REX:
        out.append(r + bytes(core))
    return out


BYTE_SIGNATURES = {
    # POPCNT r,r/m  : F3 [REX] 0F 38 B8
    "popcnt": with_rex(b"\x0f\x38\xb8"),
    # CRC32 r,r/m   : F2 [REX] 0F 38 F0 | F1
    "crc32": with_rex(b"\x0f\x38\xf0") + with_rex(b"\x0f\x38\xf1"),
    # PCMPISTRI/PCMPISTRM/PCMPESTRI/PCMPESTRM : 66 0F 3A 60..63
    "sse4.2": [b"\x66\x0f\x3a\x60", b"\x66\x0f\x3a\x61",
               b"\x66\x0f\x3a\x62", b"\x66\x0f\x3a\x63"],
    # AESENC/AESDEC/... : 66 [REX] 0F 38 DB..DF
    "aes": with_rex(b"\x0f\x38\xdb") + with_rex(b"\x0f\x38\xdc")
           + with_rex(b"\x0f\x38\xdd") + with_rex(b"\x0f\x38\xde")
           + with_rex(b"\x0f\x38\xdf"),
    # PCLMULQDQ : 66 [REX] 0F 3A 44
    "pclmul": with_rex(b"\x0f\x3a\x44"),
}
# POPCNT e CRC32 appartengono all'insieme SSE4.2: se viene richiesto sse4.2 si
# includono anche le loro firme.
if "sse4.2" in checks:
    BYTE_SIGNATURES["sse4.2"] = (BYTE_SIGNATURES["sse4.2"]
                                 + BYTE_SIGNATURES["popcnt"]
                                 + BYTE_SIGNATURES["crc32"])

# Mnemonici cercati nella fase 2 (disassemblatore).
MNEMONICS = {
    "popcnt": re.compile(r"\b(popcnt[lwq]?|popcnt)\b"),
    "crc32": re.compile(r"\b(crc32[lwq]?)\b"),
    "sse4.2": re.compile(r"\b(pcmpistri|pcmpistrm|pcmpestri|pcmpestrm|pcmpgtq)\b"),
    "aes": re.compile(r"\b(aesenc|aesenclast|aesdec|aesdeclast|aesimc|aeskeygenassist)\b"),
    "pclmul": re.compile(r"\b(pclmul[lh]?qdq)\b"),
    "avx": re.compile(r"\b(v[a-z]{2,}[sp][sd]|vzeroupper|vzeroall|vex)\b"),
    "bmi": re.compile(r"\b(andn[lwq]?|blsr[lwq]?|blsmsk[lwq]?|blsi[lwq]?|bzhi[lwq]?|"
                      r"mulx[lwq]?|pdep[lwq]?|pext[lwq]?|rorx[lwq]?|shlx[lwq]?|"
                      r"shrx[lwq]?|sarx[lwq]?|tzcnt[lwq]?|lzcnt[lwq]?)\b"),
    "f16c": re.compile(r"\b(vcvtph2ps|vcvtps2ph)\b"),
}

# Librerie con selezione a runtime del percorso ISA (IFUNC/CPUID).
DISPATCHED_RE = re.compile(
    r"(^|/)(libc(-[\d.]+)?\.so|libm(-[\d.]+)?\.so|libpthread|libdl|"
    r"libcrypto\.so|libssl\.so|libz\.so|libsqlite3|"
    r"libLLVM[^/]*\.so|libgallium|libcrocus|libiris|libi965|"
    r"libswrast|libdrm|libstdc\+\+\.so|libgcc_s\.so)"
)

ELF_MAGIC = b"\x7fELF"
PE_MAGIC = b"MZ"


def classify(path):
    """Ritorna 'dispatched' per le librerie con IFUNC, 'critical' altrimenti."""
    return "dispatched" if DISPATCHED_RE.search(path) else "critical"


def read_head(path, limit):
    try:
        size = os.path.getsize(path)
    except OSError:
        return None, 0
    if size == 0 or size > limit:
        return None, size
    try:
        with open(path, "rb") as fh:
            return fh.read(), size
    except (OSError, PermissionError):
        return None, size


def is_binary(data):
    return data[:4] == ELF_MAGIC or data[:2] == PE_MAGIC


def phase1(path, data):
    """Prefilter sulle codifiche byte: ritorna le famiglie candidate."""
    found = []
    for family in sorted(checks):
        signatures = BYTE_SIGNATURES.get(family)
        if not signatures:
            continue
        for sig in signatures:
            if data.find(sig) != -1:
                found.append(family)
                break
    # AVX/BMI/F16C non hanno una firma byte affidabile (i prefissi VEX C4/C5
    # compaiono frequentemente nei dati): la verifica e' solo di fase 2.
    if checks & {"avx", "bmi", "f16c"} and not found:
        found.append("__phase2_only__")
    return found


def phase2(path, families):
    """Conferma con objdump: ritorna {famiglia: [mnemonico, ...]}."""
    confirmed = {}
    try:
        proc = subprocess.run(
            ["objdump", "-d", "--no-show-raw-insn", "--", path],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=600)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode not in (0, 1) or not proc.stdout:
        return None
    text = proc.stdout.decode("utf-8", "replace")
    wanted = {f for f in families if f in checks} | (checks & {"avx", "bmi", "f16c"})
    for family in sorted(wanted):
        rx = MNEMONICS.get(family)
        if rx is None:
            continue
        hits = []
        for line in text.splitlines():
            # Le righe di disassemblatore hanno la forma "  addr:\tmnemonic ops"
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            mnemonic = parts[1].strip().split(" ")[0]
            if rx.search(mnemonic):
                hits.append(mnemonic)
                if len(hits) >= 8:
                    break
        if hits:
            confirmed[family] = sorted(set(hits))
    return confirmed


def scan(path):
    data, size = read_head(path, max_bytes)
    result = {"path": path, "size": size, "class": classify(path),
              "status": "skipped", "families": {}, "candidates": []}
    if data is None:
        result["status"] = "unreadable-or-oversized"
        return result
    if not is_binary(data):
        result["status"] = "not-binary"
        return result

    candidates = phase1(path, data)
    result["candidates"] = [c for c in candidates if c != "__phase2_only__"]
    need_phase2 = bool(candidates)

    if not need_phase2:
        result["status"] = "clean"
        return result

    confirmed = phase2(path, candidates)
    if confirmed is None:
        # Disassemblatore non utilizzabile: si riporta l'evidenza byte come
        # "sospetta" senza poterla confermare.
        if result["candidates"]:
            result["status"] = "suspected"
            for fam in result["candidates"]:
                result["families"][fam] = ["<verifica byte, objdump non disponibile>"]
        else:
            result["status"] = "clean"
        return result

    if confirmed:
        result["status"] = "hit"
        result["families"] = confirmed
    else:
        result["status"] = "clean"
    return result


def rel(path):
    if root_prefix and path.startswith(root_prefix):
        return path[len(root_prefix):].lstrip("/") or "/"
    return path


with open(file_list_path, encoding="utf-8") as fh:
    files = [line.rstrip("\n") for line in fh if line.strip()]

results = []
with futures.ThreadPoolExecutor(max_workers=jobs) as pool:
    for res in pool.map(scan, files):
        results.append(res)

scanned = [r for r in results if r["status"] in ("clean", "hit", "suspected")]
hits = [r for r in results if r["status"] == "hit"]
suspected = [r for r in results if r["status"] == "suspected"]
critical_hits = [r for r in hits if r["class"] == "critical"]
critical_suspected = [r for r in suspected if r["class"] == "critical"]
dispatched_hits = [r for r in hits if r["class"] == "dispatched"]

for r in critical_hits + critical_suspected:
    sys.stderr.write("PROIBITO  %s [%s] -> %s\n" % (
        rel(r["path"]), r["class"],
        ", ".join("%s: %s" % (fam, "/".join(mn)) for fam, mn in sorted(r["families"].items()))))
if verbose:
    for r in dispatched_hits:
        sys.stderr.write("DISPATCH  %s -> %s\n" % (
            rel(r["path"]),
            ", ".join("%s: %s" % (fam, "/".join(mn)) for fam, mn in sorted(r["families"].items()))))

summary = {
    "files_listed": len(files),
    "files_scanned": len(scanned),
    "files_skipped": len(files) - len(scanned),
    "critical_hits": len(critical_hits),
    "critical_suspected": len(critical_suspected),
    "dispatched_hits": len(dispatched_hits),
    "isa_checks": sorted(checks),
    "jobs": jobs,
}
print(json.dumps({"summary": summary,
                  "results": [{**r, "path": rel(r["path"])} for r in results
                              if r["status"] in ("hit", "suspected")]},
                 indent=2, ensure_ascii=False))

sys.exit(1 if (critical_hits or critical_suspected) else 0)
PY
}

# Costruisce l'elenco dei file da scansionare in un albero rootfs.
collect_files() {
	local root="$1" out="$2"

	: > "${out}"
	if (( ARG_FULL == 1 )); then
		log_info "scansione completa di ${root} (tutti i file regolari)"
		find "${root}" -xdev -type f \
			\( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) \
			-print >> "${out}" 2>/dev/null || true
	else
		local p found=0
		for p in "${CRITICAL_PATHS[@]}"; do
			local full="${root}${p}"
			if [[ -d "${full}" ]]; then
				find "${full}" -xdev -type f >> "${out}" 2>/dev/null || true
				(( ++found )) || true
			elif [[ -f "${full}" ]]; then
				printf '%s\n' "${full}" >> "${out}"
				(( ++found )) || true
			fi
		done
		if (( found == 0 )); then
			log_warn "nessun percorso critico trovato in ${root}: uso la scansione completa"
			find "${root}" -xdev -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) \
				-print >> "${out}" 2>/dev/null || true
		else
			log_info "percorsi critici individuati: ${found} su ${#CRITICAL_PATHS[@]}"
		fi
	fi

	local count
	count="$(grep -c '' "${out}" 2>/dev/null || echo 0)"
	log_info "file candidati: ${count}"
	if (( count == 0 )); then
		log_warn "nessun file da analizzare"
	fi
}

# =============================================================================
# MODALITA' --image
# =============================================================================
mount_image() {
	local image="$1"
	local mnt="${WORK_DIR}/mnt"
	ensure_dir "${mnt}"

	if have_cmd mount_image.sh && [[ -d /mnt/host/source ]]; then
		log_info "uso mount_image.sh (ambiente cros_sdk)"
		if mount_image.sh --image "${image}" --mount_rootfs_only -m "${mnt}" >/dev/null 2>&1; then
			MOUNT_CREATED="${mnt}"
			printf '%s' "${mnt}"
			return 0
		fi
		log_warn "mount_image.sh non riuscito: provo con losetup"
	fi

	require_cmds losetup
	local sfdisk_bin="sfdisk"
	have_cmd "${sfdisk_bin}" || die 2 "sfdisk non disponibile: montare l'immagine manualmente e usare --rootfs"

	# Individua la partizione ROOT-A (tipo ChromeOS rootfs, GUID
	# 3CB8E202-3B7E-47DD-8A5C-334F78AE7C5C) oppure la seconda partizione.
	local part_line offset size start sectors
	part_line="$(${sfdisk_bin} -J "${image}" 2>/dev/null |
		python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
parts = data.get("partitiontable", [])
root_a = None
for p in parts:
    if p.get("type") == "3CB8E202-3B7E-47DD-8A5C-334F78AE7C5C" or p.get("name") == "ROOT-A":
        root_a = p
        break
if root_a is None and len(parts) >= 3:
    root_a = parts[2]
if root_a is None:
    sys.exit(1)
print("%d %d" % (root_a["start"], root_a["size"]))
')" || die 2 "impossibile leggere la tabella delle partizioni di ${image}"

	read -r start sectors <<< "${part_line}"
	local sector_size=512
	offset=$(( start * sector_size ))
	size=$(( sectors * sector_size ))

	local loop
	if [[ "$(id -u)" -eq 0 ]]; then
		loop="$(losetup --find --show --offset "${offset}" --sizelimit "${size}" "${image}")" || \
			die 2 "losetup fallito su ${image}"
	else
		have_cmd sudo || die 2 "servono privilegi di root per montare l'immagine (sudo assente)"
		loop="$(sudo losetup --find --show --offset "${offset}" --sizelimit "${size}" "${image}")" || \
			die 2 "losetup fallito su ${image}"
	fi
	log_info "loop device: ${loop} (offset ${offset}, ${size} byte)"

	local mount_cmd=(mount -o ro "${loop}" "${mnt}")
	if [[ -n "$(have_cmd sudo && echo yes)" && "$(id -u)" -ne 0 ]]; then
		mount_cmd=(sudo mount -o ro "${loop}" "${mnt}")
	fi
	if ! "${mount_cmd[@]}" 2>/dev/null; then
		# Le rootfs ChromiumOS sono ext4 con feature che richiedono il driver
		# corretto: si riprova esplicitamente.
		if ! "${mount_cmd[@]% "${mnt}"}" -t ext4 "${mnt}" 2>/dev/null; then
			losetup -d "${loop}" 2>/dev/null || true
			die 2 "mount della partizione ROOT-A fallito su ${mnt}"
		fi
	fi
	MOUNT_CREATED="${mnt}"
	LOOP_DEVICE="${loop}"
	log_ok "immagine montata in lettura sola: ${mnt}"
	printf '%s' "${mnt}"
}

unmount_image() {
	[[ -n "${MOUNT_CREATED}" ]] || return 0
	if [[ -n "${LOOP_DEVICE:-}" ]]; then
		if [[ "$(id -u)" -eq 0 ]]; then
			umount "${MOUNT_CREATED}" 2>/dev/null || true
			losetup -d "${LOOP_DEVICE}" 2>/dev/null || true
		else
			sudo umount "${MOUNT_CREATED}" 2>/dev/null || true
			sudo losetup -d "${LOOP_DEVICE}" 2>/dev/null || true
		fi
	else
		umount_image.sh -m "${MOUNT_CREATED}" >/dev/null 2>&1 || \
			umount "${MOUNT_CREATED}" 2>/dev/null || true
	fi
	MOUNT_CREATED=""
	log_debug "immagine smontata"
}

# =============================================================================
# MODALITA' --host
# =============================================================================
report_host() {
	log_banner "Capacita' ISA della CPU corrente"

	local flags model
	model="$(awk -F: '/^model name/ { gsub(/^ +/,"",$2); print $2; exit }' /proc/cpuinfo 2>/dev/null || echo 'n/d')"
	flags="$(awk -F: '/^flags/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || echo '')"

	printf '  Modello      : %s\n' "${model}" >&2
	printf '  Core logici  : %s\n' "$(nproc 2>/dev/null || echo 'n/d')" >&2

	local f present req
	printf '\n  %-10s %-12s %s\n' "FEATURE" "PRESENTE" "RICHIESTA TARGET" >&2
	printf '  %s\n' "-------------------------------------------------------------" >&2
	for f in sse4_1 sse4_2 popcnt avx avx2 aes pclmulqdq bmi1 bmi2 f16c; do
		if [[ " ${flags} " == *" ${f} "* ]]; then
			present="${PRISMOS_C_GREEN}si${PRISMOS_C_RESET}"
		else
			present="${PRISMOS_C_RED}no${PRISMOS_C_RESET}"
		fi
		case "${f}" in
			sse4_1)
				req="${PRISMOS_C_GREEN}obbligatoria (floor ISA)${PRISMOS_C_RESET}" ;;
			sse4_2|popcnt)
				req="${PRISMOS_C_YELLOW}VIETATA sul target (SIGILL)${PRISMOS_C_RESET}" ;;
			*)
				req="${PRISMOS_C_DIM}non usata sul target${PRISMOS_C_RESET}" ;;
		esac
		# Il padding va calcolato sul testo privo di sequenze di escape.
		local present_plain="no"
		[[ " ${flags} " == *" ${f} "* ]] && present_plain="si"
		printf '  %-10s %b%*s %b\n' "${f}" "${present}" $(( 10 - ${#present_plain} )) "" "${req}" >&2
	done

	printf '\n' >&2
	if [[ " ${flags} " == *" sse4_2 "* ]]; then
		log_warn "la macchina corrente HA SSE4.2: e' adatta alla compilazione ma NON"
		log_warn "rappresenta il target. La verifica dei binari va fatta con questo"
		log_warn "script, non eseguendoli qui (QEMU senza SSE4.2 oppure hardware reale)."
	else
		log_ok "la macchina corrente non ha SSE4.2: rappresentativa del target"
	fi
	return 0
}

# =============================================================================
# MODALITA' --config
# =============================================================================
report_config() {
	log_banner "Verifica della configurazione della repository"

	local rc=0
	local common_make="${PRISMOS_OVERLAYS_DIR}/overlay-prismos-common/make.conf"

	# 1. CFLAGS obbligatori. Il make.conf compone CFLAGS a partire da variabili
	#    intermedie (COMMON_FLAGS, HARDENING_FLAGS, ...): il file va quindi
	#    eseguito in una subshell per ottenerne il valore espanso.
	if [[ -f "${common_make}" ]]; then
		local cflags
		cflags="$(bash -c 'set +u; CFLAGS=""; source "$1" >/dev/null 2>&1; printf "%s" "${CFLAGS}"' \
			_prismos_cflags_probe "${common_make}" 2>/dev/null || true)"
		if [[ -z "${cflags}" ]]; then
			# Ripiego testuale: almeno la riga grezza per l'ispezione umana.
			cflags="$(sed -n 's/^CFLAGS="\(.*\)"$/\1/p' "${common_make}" | head -1)"
			log_warn "espansione di CFLAGS non riuscita: mostro la definizione grezza"
		fi
		local required=( "-O2" "-pipe" "-march=nehalem" "-mno-sse4.2" "-msse4.1" )
		local flag
		printf '\n  CFLAGS: %s\n' "${cflags:-<non rilevati>}" >&2
		for flag in "${required[@]}"; do
			if [[ " ${cflags} " == *" ${flag} "* ]]; then
				log_ok "CFLAGS contiene ${flag}"
			else
				log_error "CFLAGS NON contiene ${flag} (flag obbligatorio)"
				rc=1
			fi
		done
		if [[ " ${cflags} " == *" -mno-popcnt "* ]]; then
			log_ok "CFLAGS contiene -mno-popcnt (POPCNT e' indipendente da SSE4.2)"
		else
			log_error "CFLAGS NON contiene -mno-popcnt: -march=nehalem abilita POPCNT"
			rc=1
		fi
	else
		log_error "make.conf comune mancante: ${common_make}"
		rc=1
	fi

	# 2. CPU_FLAGS_X86 coerenti con il floor ISA.
	local cpu_flags
	cpu_flags="$(grep -h '^CPU_FLAGS_X86=' "${PRISMOS_OVERLAYS_DIR}"/overlay-prismos-*/profiles/base/make.defaults \
		"${PRISMOS_OVERLAYS_DIR}"/overlay-prismos-common/profiles/base/make.defaults 2>/dev/null | head -1)"
	if [[ -n "${cpu_flags}" ]]; then
		printf '  %s\n' "${cpu_flags}" >&2
		local bad
		for bad in sse4_2 avx avx2 aes pclmul f16c popcnt; do
			if [[ "${cpu_flags}" == *" ${bad} "* || "${cpu_flags}" == *"${bad}"* ]]; then
				log_error "CPU_FLAGS_X86 contiene '${bad}': incompatibile con il target"
				rc=1
			fi
		done
		if [[ "${cpu_flags}" == *"sse4_1"* ]]; then
			log_ok "CPU_FLAGS_X86 include sse4_1 (floor ISA)"
		else
			log_warn "CPU_FLAGS_X86 non menziona sse4_1"
		fi
	else
		log_warn "CPU_FLAGS_X86 non trovato nei profili"
	fi

	# 3. Rimozione di ARC.
	local use_mask="${PRISMOS_OVERLAYS_DIR}/overlay-prismos-common/profiles/base/use.mask"
	if [[ -f "${use_mask}" ]] && grep -q '^arc' "${use_mask}"; then
		log_ok "use.mask blocca le USE di ARC"
	else
		log_error "use.mask non blocca ARC: ${use_mask}"
		rc=1
	fi
	# Una USE negativa (-arc) presenta un word boundary ingannevole per grep: il
	# controllo dei token ARC positivi e' demandato a python.
	local arc_report arc_line
	arc_report="$(python3 "${PRISMOS_LIB_DIR}/isa_arc_probe.py" "${PRISMOS_OVERLAYS_DIR}" 2>/dev/null || true)"
	if [[ -n "${arc_report//[[:space:]]/}" ]]; then
		log_error "una make.defaults abilita una USE di ARC:"
		while IFS= read -r arc_line; do
			[[ -n "${arc_line}" ]] && printf '    %s\n' "${arc_line}" >&2
		done <<< "${arc_report}"
		rc=1
	else
		log_ok "nessuna make.defaults abilita USE di ARC (arc, arc-plus, arcplusplus, arcvm)"
	fi
	if grep -Rsq -- '-arc' "${PRISMOS_OVERLAYS_DIR}/overlay-prismos-common/profiles/base/make.defaults"; then
		log_ok "make.defaults comune nega esplicitamente arc/arc-plus"
	else
		log_error "make.defaults comune non nega arc/arc-plus"
		rc=1
	fi

	# 4. Pool applicazioni: nessuna app dichiara sse42_required.
	if [[ -f "${PRISMOS_APP_POOL}" ]]; then
		if PRISMOS_JSON_FILE="${PRISMOS_APP_POOL}" python3 - <<'PY'
import json, os, sys

with open(os.environ["PRISMOS_JSON_FILE"], encoding="utf-8") as fh:
    pool = json.load(fh)

bad = [a.get("id") for a in pool.get("applications", []) if a.get("sse42_required")]
arm = [a.get("id") for a in pool.get("applications", [])
       if a.get("arm_translation_required")]
for app_id in bad:
    sys.stderr.write("ERROR app con sse42_required=true: %s\n" % app_id)
for app_id in arm:
    sys.stderr.write("ERROR app con arm_translation_required=true: %s\n" % app_id)
sys.exit(1 if (bad or arm) else 0)
PY
		then
			log_ok "app_pool.json: nessuna applicazione richiede SSE4.2 o ARM translation"
		else
			log_error "app_pool.json contiene applicazioni incompatibili"
			rc=1
		fi
	fi

	# 5. Frammenti di splitconfig del kernel.
	local frag_dir="${PRISMOS_KERNEL_DIR}/chromeos/config/chromiumos-x86_64/prismos_legacy"
	if [[ -d "${frag_dir}" ]]; then
		local frag
		for frag in base.config fragment.config legacy-cpu.config android.config wine.config slim.config; do
			if [[ -f "${frag_dir}/${frag}" ]]; then
				log_ok "frammento kernel presente: ${frag}"
			else
				log_warn "frammento kernel mancante: ${frag}"
			fi
		done
		if grep -q 'CONFIG_ANDROID_BINDER_IPC=y' "${frag_dir}/android.config" 2>/dev/null; then
			log_ok "android.config abilita il binder IPC (Waydroid)"
		else
			log_error "android.config non abilita CONFIG_ANDROID_BINDER_IPC"
			rc=1
		fi
		if grep -q 'CONFIG_BINFMT_MISC=y' "${frag_dir}/wine.config" 2>/dev/null; then
			log_ok "wine.config abilita BINFMT_MISC (esecuzione diretta dei .exe)"
		else
			log_error "wine.config non abilita CONFIG_BINFMT_MISC"
			rc=1
		fi
	else
		log_error "splitconfig del kernel mancante: ${frag_dir}"
		rc=1
	fi

	# 6. Coerenza dei profili di edizione.
	local ed
	for ed in "${PRISMOS_EDITIONS[@]}"; do
		local prof="${PRISMOS_PROFILES_DIR}/${ed}.conf"
		if [[ -f "${prof}" ]]; then
			bash -n "${prof}" && log_ok "profilo ${ed}.conf sintatticamente valido" || {
				log_error "profilo ${ed}.conf non valido"; rc=1; }
		else
			log_error "profilo mancante: ${prof}"
			rc=1
		fi
	done

	printf '\n' >&2
	if (( rc == 0 )); then
		log_ok "configurazione della repository coerente con il target SSE4.1"
	else
		log_error "configurazione della repository con incongruenze"
	fi
	return "${rc}"
}

# =============================================================================
# RAPPORTO
# =============================================================================
write_report() {
	local scan_json="$1" target_label="$2"
	local rc="$3"

	if [[ -n "${ARG_JSON}" ]]; then
		ensure_dir "$(dirname "${ARG_JSON}")" 2>/dev/null || true
		PRISMOS_ISA_JSON_IN="${scan_json}" \
		PRISMOS_ISA_TARGET="${target_label}" \
		PRISMOS_ISA_RC="${rc}" \
		PRISMOS_ISA_STAMP="$(date -Is)" \
		PRISMOS_ISA_REV="$(prismos_git_revision)" \
		python3 - "${ARG_JSON}" <<'PY'
import json, os, sys

target = sys.argv[1]
with open(os.environ["PRISMOS_ISA_JSON_IN"], encoding="utf-8") as fh:
    scan = json.load(fh)

report = {
    "tool": "prismOS verify_legacy_cpu.sh",
    "version": "1.0.0",
    "timestamp": os.environ["PRISMOS_ISA_STAMP"],
    "git_revision": os.environ["PRISMOS_ISA_REV"],
    "target": os.environ["PRISMOS_ISA_TARGET"],
    "isa_floor": "x86-64 SSE4.1 (no SSE4.2, no POPCNT, no AVX)",
    "exit_code": int(os.environ["PRISMOS_ISA_RC"]),
    "verdict": "PASS" if os.environ["PRISMOS_ISA_RC"] == "0" else "FAIL",
    "summary": scan.get("summary", {}),
    "findings": scan.get("results", []),
}
with open(target, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
		log_ok "rapporto JSON: ${ARG_JSON}"
	fi

	if [[ -n "${ARG_REPORT}" ]]; then
		ensure_dir "$(dirname "${ARG_REPORT}")" 2>/dev/null || true
		{
			echo "prismOS - rapporto di verifica del floor ISA"
			echo "generato      : $(date -Is)"
			echo "revisione     : $(prismos_git_revision)"
			echo "bersaglio     : ${target_label}"
			echo "verifica ISA  : ${ARG_ISA_CHECKS}"
			echo "modalita'     : ${MODE}$([[ ${ARG_FULL} -eq 1 ]] && echo ' (full)')"
			echo "esito         : $([[ "${rc}" == "0" ]] && echo 'PASS' || echo 'FAIL')"
			echo "-------------------------------------------------------------------------"
			if [[ -f "${scan_json}" ]]; then
				python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
s = data.get("summary", {})
for key, value in s.items():
    print("%-20s: %s" % (key, value))
print("-" * 73)
for finding in data.get("results", []):
    print("%-10s %-60s" % (finding.get("class", "?"), finding.get("path", "?")))
    for family, mnemonics in sorted((finding.get("families") or {}).items()):
        print("             %s: %s" % (family, ", ".join(mnemonics)))
if not data.get("results"):
    print("nessuna evidenza: tutti i binari analizzati rispettano il floor ISA")
' "${scan_json}"
			fi
		} > "${ARG_REPORT}"
		log_ok "rapporto testuale: ${ARG_REPORT}"
	fi
}

print_summary() {
	local scan_json="$1" rc="$2" target_label="$3"

	(( ARG_QUIET == 1 )) && return 0

	log_banner "Esito della verifica ISA"
	printf '  %s\n' "bersaglio : ${target_label}" >&2
	printf '  %s\n' "ISA floor : x86-64 SSE4.1 (SSE4.2/POPCNT vietati)" >&2
	printf '  %s\n' "verifiche : ${ARG_ISA_CHECKS}" >&2

	if [[ -f "${scan_json}" ]]; then
		PRISMOS_ISA_JSON="${scan_json}" python3 - <<'PY'
import json, os

with open(os.environ["PRISMOS_ISA_JSON"], encoding="utf-8") as fh:
    data = json.load(fh)
s = data.get("summary", {})
print("  file      : %d elencati, %d binari analizzati, %d saltati"
      % (s.get("files_listed", 0), s.get("files_scanned", 0), s.get("files_skipped", 0)))
print("  evidenze  : %d critiche, %d sospette, %d dispatched (IFUNC)"
      % (s.get("critical_hits", 0), s.get("critical_suspected", 0),
         s.get("dispatched_hits", 0)))
PY
	fi

	printf '\n' >&2
	if (( rc == 0 )); then
		printf '  %s%sPASS%s - nessun binario richiede SSE4.2\n' \
			"${PRISMOS_C_GREEN}" "${PRISMOS_C_BOLD}" "${PRISMOS_C_RESET}" >&2
	else
		printf '  %s%sFAIL%s - trovati binari incompatibili con CPU senza SSE4.2\n' \
			"${PRISMOS_C_RED}" "${PRISMOS_C_BOLD}" "${PRISMOS_C_RESET}" >&2
		printf '  %s\n' "Rimedi:" >&2
		printf '  %s\n' "   1. verificare CFLAGS/CXXFLAGS in overlay-prismos-common/make.conf" >&2
		printf '  %s\n' "   2. per Chrome: x64_arch=\"generic\", use_thin_lto=false (GN args)" >&2
		printf '  %s\n' "   3. per Rust: target-cpu=x86-64 + target-feature=+sse4.1,-sse4.2,-popcnt" >&2
		printf '  %s\n' "   4. per Go: GOAMD64=v1" >&2
		printf '  %s\n' "   5. ricompilare il pacchetto con emerge --oneshot e ripetere la verifica" >&2
	fi
	printf '\n' >&2
}

# =============================================================================
# MAIN
# =============================================================================
main() {
	parse_args "$@"

	log_banner \
		"prismOS verify_legacy_cpu ${PROG_VERSION}" \
		"Floor ISA: x86-64 SSE4.1 - SSE4.2/POPCNT vietati" \
		"Target: Intel Pentium P6100 (Arrandale) e CPU equivalenti"

	case "${MODE}" in
		host)
			report_host
			exit 0
			;;
		config)
			rc=0
			report_config || rc=$?
			exit "${rc}"
			;;
	esac

	require_cmds python3 find
	if ! have_cmd objdump; then
		log_warn "objdump non disponibile: la conferma di fase 2 sara' saltata e le"
		log_warn "evidenze byte verranno riportate come 'sospette' (falsi positivi possibili)"
	fi

	WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prismos-isa.XXXXXXXX")"
	trap 'unmount_image; rm -rf "${WORK_DIR:-}"' EXIT

	local scan_root="${ARG_TARGET}"
	local target_label="${ARG_TARGET}"
	SCAN_ROOT_PREFIX="${ARG_TARGET}"

	if [[ "${MODE}" == "image" ]]; then
		log_step "Montaggio dell'immagine ${ARG_TARGET}"
		scan_root="$(mount_image "${ARG_TARGET}")"
		target_label="${ARG_TARGET} (rootfs montata)"
		log_ok "rootfs disponibile in ${scan_root}"
	fi

	if [[ "${MODE}" == "pe" ]]; then
		log_step "Verifica del binario ${ARG_TARGET}"
		printf '%s\n' "$(readlink -f "${ARG_TARGET}")" > "${WORK_DIR}/files.txt"
		target_label="${ARG_TARGET}"
		# Nessun prefisso da rimuovere: il percorso va mostrato per esteso.
		SCAN_ROOT_PREFIX=""
	else
		log_step "Scansione della rootfs ${scan_root}"
		collect_files "${scan_root}" "${WORK_DIR}/files.txt"
	fi

	log_step "Analisi ISA (fase 1 byte + fase 2 objdump, ${ARG_JOBS} thread)"
	local scan_json="${WORK_DIR}/scan.json"
	local rc=0
	run_scanner "${WORK_DIR}/files.txt" > "${scan_json}" || rc=$?

	print_summary "${scan_json}" "${rc}" "${target_label}"
	write_report "${scan_json}" "${target_label}" "${rc}"

	exit "${rc}"
}

main "$@"
