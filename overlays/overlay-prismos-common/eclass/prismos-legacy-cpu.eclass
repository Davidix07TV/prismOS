# Copyright 2026 The prismOS Authors
# Distributed under the terms of the GNU General Public License v2

# @ECLASS: prismos-legacy-cpu.eclass
# @MAINTAINER: prismOS kernel & toolchain team
# @AUTHOR: prismOS
# @BLURB: enforcement del floor ISA SSE4.1 per CPU prive di SSE4.2/POPCNT
# @DESCRIPTION:
# prismOS gira su x86_64 che espongono al massimo SSE4.1 (Intel Pentium P6100,
# Celeron P4500, Core 2 Penryn/Wolfdale con SSSE3). L'eclass fornisce:
#
#   1. prismos-legacy-cpu_assert_isa_floor
#      verifica che CFLAGS/CXXFLAGS contengano la sequenza obbligatoria
#      -march=nehalem -mno-sse4.2 -msse4.1 e che non contengano -mavx/-mpopcnt;
#   2. prismos-legacy-cpu_sanitize_flags
#      rimuove da CFLAGS/CXXFLAGS/MAKEOPTS eventuali -march=haswell/-mavx2
#      introdotti da ebuild a monte e riapplica il floor;
#   3. prismos-legacy-cpu_gn_args / prismos-legacy-cpu_gn_env
#      esporta gli argomenti GN per chromeos-chrome (x64_arch="generic");
#   4. prismos-legacy-cpu_scan_installed
#      scansiona gli ELF appena installati con objdump alla ricerca dei soli
#      mnemonici introdotti da SSE4.2 e POPCNT (crc32, pcmpgtq, pcmpestri,
#      pcmpestrm, pcmpistri, pcmpistrm, popcnt) e segnala i binari non conformi;
#   5. prismos-legacy-cpu_runtime_check
#      controllo a runtime su /proc/cpuinfo, usato dai pkg_postinst.
#
# @EXAMPLE:
# @CODE
# inherit prismos-legacy-cpu
# src_prepare() {
#     default
#     prismos-legacy-cpu_sanitize_flags
#     prismos-legacy-cpu_assert_isa_floor || die
# }
# pkg_postinst() {
#     prismos-legacy-cpu_scan_installed "${ED}"
# }
# @CODE

case ${EAPI:-0} in
	8) ;;
	*) die "${ECLASS}: EAPI ${EAPI:-0} non supportato (richiesto EAPI 8)" ;;
esac

inherit flag-o-matic toolchain-funcs multiprocessing

if [[ -z ${_PRISMOS_LEGACY_CPU_ECLASS} ]]; then
_PRISMOS_LEGACY_CPU_ECLASS=1

# Sequenza obbligatoria, identica a overlay-prismos-common/make.conf.
PRISMOS_LEGACY_ISA_FLOOR="${PRISMOS_LEGACY_ISA_FLOOR:--march=nehalem -mno-sse4.2 -msse4.1 -mno-popcnt}"

# Mnemonici introdotti ESCLUSIVAMENTE da SSE4.2 / POPCNT (Intel SDM Vol.2).
# La loro presenza in un binario destinato a prismOS Legacy e' un bug di build.
PRISMOS_SSE42_MNEMONICS="crc32 pcmpgtq pcmpestri pcmpestrm pcmpistri pcmpistrm popcnt"

# Estensioni superiori al floor: vanno rimosse dai flag se un ebuild le aggiunge.
PRISMOS_FORBIDDEN_FLAG_RE='-(march=(nehalem|westmere|sandybridge|ivybridge|haswell|broadwell|skylake|skylake-avx512|cascadelake|icelake-client|native|znver[0-9]|core-avx[0-9]|x86-64-v[234])|msse4\.2|mpopcnt|mavx[0-9]?|mbmi[0-9]?|mfma|mf16c|maes|mpclmul|mabm|msha|madx|mrdrnd|mrtm|mtsx)'

# @FUNCTION: prismos-legacy-cpu_log
# @USAGE: <livello> <messaggio...>
# @DESCRIPTION: log uniforme su stderr con prefisso riconoscibile.
prismos-legacy-cpu_log() {
	local level="$1"; shift
	printf '%s [%s] %s\n' "${level}" "prismos-legacy-cpu" "$*" >&2
}

# @FUNCTION: prismos-legacy-cpu_cpuinfo_flags
# @USAGE:
# @DESCRIPTION: ritorna su stdout le flag ISA della CPU ospite (una per riga).
prismos-legacy-cpu_cpuinfo_flags() {
	if [[ -r /proc/cpuinfo ]]; then
		awk '/^flags[[:space:]]*:/ { for (i = 3; i <= NF; i++) print $i; exit }' /proc/cpuinfo
	elif [[ -x /usr/sbin/sysctl ]]; then
		sysctl -n hw.optional 2>/dev/null || true
	fi
}

# @FUNCTION: prismos-legacy-cpu_host_has_sse42
# @USAGE:
# @RETURN: 0 se la CPU di BUILD ha SSE4.2 e POPCNT, 1 altrimenti
# @DESCRIPTION:
# Il build host puo' avere SSE4.2 (ed e' la norma): la compilazione e'
# cross-compatibile perche' il floor e' imposto dai flag, non dall'hardware.
# La funzione serve solo per i messaggi diagnostici.
prismos-legacy-cpu_host_has_sse42() {
	local flags
	flags="$(prismos-legacy-cpu_cpuinfo_flags)"
	[[ "${flags}" == *sse4_2* && "${flags}" == *popcnt* ]]
}

# @FUNCTION: prismos-legacy-cpu_sanitize_flags
# @USAGE:
# @DESCRIPTION:
# Rimuove dai flag del compilatore qualsiasi -march/-m* che alzi il floor sopra
# SSE4.1 e riapplica la sequenza obbligatoria. Va chiamata in src_prepare()
# dagli ebuild che ricevono CFLAGS da ebuild genitori (tipicamente Chromium,
# mesa, ffmpeg, x264).
prismos-legacy-cpu_sanitize_flags() {
	local var cleaned
	for var in CFLAGS CXXFLAGS FFLAGS FCFLAGS; do
		cleaned="$(sed -E "s/${PRISMOS_FORBIDDEN_FLAG_RE}//g" <<<"${!var}")"
		# Collassa gli spazi multipli prodotti dalla rimozione.
		cleaned="$(tr -s ' ' <<<"${cleaned}")"
		export "${var}=${cleaned} ${PRISMOS_LEGACY_ISA_FLOOR}"
	done

	# -march puo' comparire anche dentro LDFLAGS (LTO) e nelle variabili Go/Rust.
	LDFLAGS="$(sed -E "s/${PRISMOS_FORBIDDEN_FLAG_RE}//g" <<<"${LDFLAGS}")"
	export LDFLAGS
	if [[ -n ${RUSTFLAGS:-} ]]; then
		RUSTFLAGS="${RUSTFLAGS//-C target-cpu=nehalem/-C target-cpu=x86-64}"
		RUSTFLAGS="${RUSTFLAGS//-Ctarget-cpu=nehalem/-C target-cpu=x86-64}"
		if [[ "${RUSTFLAGS}" != *"-sse4.2"* ]]; then
			RUSTFLAGS="${RUSTFLAGS} -C target-feature=-sse4.2,-popcnt,+sse4.1"
		fi
		export RUSTFLAGS
	fi
	if [[ -n ${GOFLAGS:-} || -n ${GOAMD64:-} ]]; then
		export GOAMD64="v1"
	fi

	prismos-legacy-cpu_log "INFO" "flag sanitizzati: CFLAGS=${CFLAGS}"
	return 0
}

# @FUNCTION: prismos-legacy-cpu_assert_isa_floor
# @USAGE:
# @RETURN: 0 se i flag rispettano il floor, 1 altrimenti
# @DESCRIPTION: asserzione dura, tipicamente seguita da `|| die`.
prismos-legacy-cpu_assert_isa_floor() {
	local var problems=0
	for var in CFLAGS CXXFLAGS; do
		local value="${!var}"
		if [[ "${value}" != *"-mno-sse4.2"* ]]; then
			prismos-legacy-cpu_log "ERRORE" "${var} non contiene -mno-sse4.2"
			(( ++problems )) || true
		fi
		if [[ "${value}" != *"-msse4.1"* ]]; then
			prismos-legacy-cpu_log "ERRORE" "${var} non contiene -msse4.1"
			(( ++problems )) || true
		fi
		if [[ "${value}" == *"-mavx"* || "${value}" == *"-mpopcnt"* || "${value}" == *"-msse4.2"* ]]; then
			prismos-legacy-cpu_log "ERRORE" "${var} contiene un flag ISA proibito: ${value}"
			(( ++problems )) || true
		fi
		if [[ "${value}" =~ -march=(haswell|broadwell|skylake|native|x86-64-v[234]) ]]; then
			prismos-legacy-cpu_log "ERRORE" "${var} contiene un -march superiore al floor: ${value}"
			(( ++problems )) || true
		fi
	done

	if (( problems > 0 )); then
		prismos-legacy-cpu_log "ERRORE" \
			"floor ISA SSE4.1 non rispettato in ${PN:-<pacchetto>}: ${problems} violazioni"
		prismos-legacy-cpu_log "ERRORE" \
			"chiamare prismos-legacy-cpu_sanitize_flags prima di compilare"
		return 1
	fi
	return 0
}

# @FUNCTION: prismos-legacy-cpu_gn_args
# @USAGE:
# @OUTPUT: argomenti GN da passare a `gn gen` per Chromium
# @DESCRIPTION:
# chromeos-chrome ignora i CFLAGS di Portage: il floor va imposto tramite GN.
# x64_arch="generic" e' l'argomento determinante (evita -march=haswell).
prismos-legacy-cpu_gn_args() {
	local extra="${PRISMOS_CHROME_GN_ARGS:-}"
	cat <<-GN
	x64_arch="generic" target_cpu="x64" is_official_build=true use_thin_lto=false is_cfi=false ${extra}
	GN
}

# @FUNCTION: prismos-legacy-cpu_gn_env
# @USAGE:
# @DESCRIPTION: esporta le variabili d'ambiente lette dagli script di build GN.
prismos-legacy-cpu_gn_env() {
	export CHROME_EXTRA_GN_ARGS="$(prismos-legacy-cpu_gn_args)"
	export CROS_GN_ARGS="${PRISMOS_CROS_GN_ARGS:-x64_arch=\"generic\" target_cpu=\"x64\"}"
	export CHROME_EXTRA_CFLAGS="${PRISMOS_LEGACY_ISA_FLOOR}"
	export CHROME_EXTRA_CXXFLAGS="${PRISMOS_LEGACY_ISA_FLOOR}"
	prismos-legacy-cpu_log "INFO" "CHROME_EXTRA_GN_ARGS=${CHROME_EXTRA_GN_ARGS}"
}

# @FUNCTION: prismos-legacy-cpu_scan_file
# @USAGE: <percorso-elf>
# @RETURN: 0 conforme, 1 contiene istruzioni SSE4.2/POPCNT
prismos-legacy-cpu_scan_file() {
	local f="$1"
	command -v objdump >/dev/null 2>&1 || return 0

	# Solo ELF: objdump su PE/Mach-O produce output inaffidabile.
	if ! head -c4 "${f}" 2>/dev/null | grep -q $'\x7fELF'; then
		return 0
	fi

	local re=""
	re="$(printf '%s|' ${PRISMOS_SSE42_MNEMONICS})"
	re="${re%|}"

	if objdump -d --no-show-raw-insn "${f}" 2>/dev/null \
	   | grep -Ewq "${re}"; then
		return 1
	fi
	return 0
}

# @FUNCTION: prismos-legacy-cpu_scan_installed
# @USAGE: [directory] [max-file]
# @DESCRIPTION:
# Scansiona ricorsivamente la directory (default ${ED}) alla ricerca di ELF
# non conformi. Stampa un report e ritorna 1 se trova almeno una violazione.
# In CI il valore di ritorno viene usato per fallire la build.
prismos-legacy-cpu_scan_installed() {
	local root="${1:-${ED:-/}}" scanned=0 bad=0
	local report="${T:-/tmp}/prismos-isa-report.txt"
	: > "${report}"

	[[ -d "${root}" ]] || return 0
	command -v objdump >/dev/null 2>&1 || {
		prismos-legacy-cpu_log "AVVISO" "objdump assente: scan ISA saltato"
		return 0
	}

	local f
	while IFS= read -r -d '' f; do
		(( ++scanned )) || true
		if ! prismos-legacy-cpu_scan_file "${f}"; then
			(( ++bad )) || true
			printf '%s\n' "${f}" >> "${report}"
		fi
	done < <(find "${root}" -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null)

	prismos-legacy-cpu_log "INFO" \
		"scan ISA completato: ${scanned} file esaminati, ${bad} non conformi"
	if (( bad > 0 )); then
		prismos-legacy-cpu_log "ERRORE" "binari con istruzioni SSE4.2/POPCNT:"
		while IFS= read -r f; do
			prismos-legacy-cpu_log "ERRORE" "  ${f}"
		done < "${report}"
		return 1
	fi
	return 0
}

# @FUNCTION: prismos-legacy-cpu_runtime_check
# @USAGE:
# @DESCRIPTION:
# Controllo a runtime: se la CPU ospite NON ha SSE4.2 conferma che l'immagine
# e' quella corretta; se la ha, avvisa che si sta usando un'immagine legacy su
# hardware piu' recente (funziona, ma rinuncia a SSE4.2/AVX).
prismos-legacy-cpu_runtime_check() {
	if prismos-legacy-cpu_host_has_sse42; then
		prismos-legacy-cpu_log "AVVISO" \
			"CPU con SSE4.2+POPCNT rilevata: l'immagine prismOS Legacy funziona"
		prismos-legacy-cpu_log "AVVISO" \
			"ma rinuncia volontariamente a SSE4.2/POPCNT/AVX (floor SSE4.1)"
	else
		local flags
		flags="$(prismos-legacy-cpu_cpuinfo_flags | tr '\n' ' ')"
		if [[ "${flags}" != *sse4_1* ]]; then
			prismos-legacy-cpu_log "ERRORE" \
				"CPU senza SSE4.1: prismOS Legacy richiede almeno SSE4.1"
			return 1
		fi
		prismos-legacy-cpu_log "INFO" \
			"CPU conforme al profilo prismOS Legacy (SSE4.1, senza SSE4.2)"
	fi
	return 0
}

fi
