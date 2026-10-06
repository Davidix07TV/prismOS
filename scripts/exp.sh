#!/usr/bin/env bash
# =============================================================================
# exp.sh - prismOS browser experiment (DistroSea and similar live sessions).
#
# One command, everything included, nothing to do by hand:
#   * checks the tools and the internet BEFORE starting, with a clear verdict;
#   * fetches the repository with a fallback chain: existing clone -> git
#     clone (3 attempts) -> GitHub tarball via curl or wget;
#   * installs missing dependencies when possible, degrades gracefully when
#     not (git missing is fine: the tarball path replaces it);
#   * runs the full validation: syntax of every script, ISA floor, the
#     five-edition pre-compilation pipeline on a stub cros_sdk, sync check;
#   * runs the PRO edition chooser: the live session becomes "prismOS WORK";
#   * prints a final summary with the exact fix for every [KO].
#
# Usage (live session terminal, no clipboard needed):
#   curl -fsSL https://raw.githubusercontent.com/Davidix07TV/prismOS/arena/01a09a0e-prismos/scripts/exp.sh | bash
# or from an existing prismOS clone:   bash scripts/exp.sh
# Test hooks: EXP_FORCE_FETCH=tarball (skip git), EXP_SKIP_NET=1 (offline dev).
# =============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
	echo "Questo script richiede bash. Rilancia con '| bash' in fondo al comando."
	exit 1
fi
set -uo pipefail

readonly BRANCH="arena/01a09a0e-prismos"
readonly REPO_URL="https://github.com/Davidix07TV/prismOS.git"
readonly TARBALL_URL="https://codeload.github.com/Davidix07TV/prismOS/tar.gz/refs/heads/${BRANCH}"
SRC="/tmp/prismOS-exp"
STUB="/tmp/ds-stub"

C_G=$'\033[1;32m'; C_R=$'\033[1;31m'; C_Y=$'\033[1;33m'; C_B=$'\033[1;36m'; C_0=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "${C_Y}" "${C_0}" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "${C_G}" "${C_0}" "$*"; }
ko()   { printf '%s[KO]%s %s\n' "${C_R}" "${C_0}" "$*"; }
info() { printf '%s[..]%s %s\n' "${C_B}" "${C_0}" "$*"; }

PROBLEM_LINES=()
note_problem() { PROBLEM_LINES+=("$*"); }

SUDO="sudo"
if [[ ${EUID} -eq 0 ]]; then
	SUDO=""
elif ! command -v sudo >/dev/null 2>&1; then
	SUDO=""
fi

# Downloader available: curl, wget, or none.
DOWNLOADER=""
command -v curl >/dev/null 2>&1 && DOWNLOADER="curl"
[[ -z "${DOWNLOADER}" ]] && command -v wget >/dev/null 2>&1 && DOWNLOADER="wget"

fetch() { # fetch URL DEST
	local url="$1" dest="$2"
	case "${DOWNLOADER}" in
		curl) curl -fsSL --retry 3 --retry-delay 3 -o "${dest}" "${url}" ;;
		wget) wget -q --tries=3 -O "${dest}" "${url}" ;;
		*)    return 1 ;;
	esac
}

net_up() { # net_up: 0 = internet reachable
	[[ "${EXP_SKIP_NET:-0}" == "1" ]] && return 0
	if [[ -n "${DOWNLOADER}" ]]; then
		case "${DOWNLOADER}" in
			curl) curl -fsS --max-time 15 -o /dev/null "https://github.com" 2>/dev/null && return 0 ;;
			wget) wget -q --timeout=15 --tries=1 -O /dev/null "https://github.com" 2>/dev/null && return 0 ;;
		esac
	fi
	ping -c 1 -W 5 github.com >/dev/null 2>&1 && return 0
	return 1
}

# -----------------------------------------------------------------------------
step "0/7 strumenti e internet"
if [[ -z "${DOWNLOADER}" ]]; then
	ko "ne' curl ne' wget presenti: impossibile scaricare alcunché"
	note_problem "Servono curl o wget: sessione live troppo minimale, provane un'altra (es. Ubuntu 24.04)."
else
	ok "downloader disponibile: ${DOWNLOADER}"
fi
if net_up; then
	ok "internet raggiungibile (github.com risponde)"
else
	ko "NESSUN INTERNET nella sessione"
	cat >&2 <<'NONET'

  La sessione non ha connettivita': senza rete il repository non si puo'
  scaricare e l'esperimento non puo' partire. Su DistroSea e servizi simili:

    1. crea/l'account gratuito sul sito (solo email, niente carta) e fai LOGIN;
    2. CHIUDI questa sessione e riaprila da loggato (le sessioni anonime
       spesso non hanno rete);
    3. rilancia la stessa riga di prima.

NONET
	note_problem "Internet assente: account gratuito + sessione riaperta, poi rilancia."
	printf '%sRiepilogo: %d problemi — %s%s\n' "${C_R}" "${#PROBLEM_LINES[@]}" "${PROBLEM_LINES[0]}" "${C_0}"
	exit 1
fi

# -----------------------------------------------------------------------------
step "1/7 dipendenze (git, python3)"
need=()
command -v git >/dev/null 2>&1 || need+=(git)
command -v python3 >/dev/null 2>&1 || need+=(python3)
if (( ${#need[@]} )); then
	info "installo: ${need[*]} (puo' richiedere un minuto)"
	${SUDO} apt-get update -y -qq >/dev/null 2>&1
	${SUDO} apt-get install -y -qq "${need[@]}" >/dev/null 2>&1
fi
command -v python3 >/dev/null 2>&1 && ok "python3 presente" || {
	ko "python3 mancante e non installabile"
	note_problem "python3 mancante: alcuni controlli risulteranno [KO], il resto gira comunque."
}
if command -v git >/dev/null 2>&1; then
	ok "git presente"
else
	info "git mancante: usero' il fallback tarball (curl/wget), va bene uguale"
fi

# -----------------------------------------------------------------------------
step "2/7 repository prismOS (catena di fallback)"
fetch_done=0
# Fallback 0: eseguito da un clone gia' presente.
if [[ "${EXP_FORCE_FETCH:-}" == "" && "${BASH_SOURCE[0]:-}" == */* ]]; then
	candidate="$(cd "$(dirname "${BASH_SOURCE[0]:-}")/.." 2>/dev/null && pwd)"
	if [[ -d "${candidate}/scripts" && -f "${candidate}/profiles/app_pool.json" ]]; then
		SRC="${candidate}"
		ok "clone esistente riutilizzato: ${SRC}"
		fetch_done=1
	fi
fi
# Fallback 1: git clone (3 tentativi).
if (( ! fetch_done )) && command -v git >/dev/null 2>&1 && [[ "${EXP_FORCE_FETCH:-}" != "tarball" ]]; then
	rm -rf "${SRC}"
	for attempt in 1 2 3; do
		info "git clone, tentativo ${attempt}/3"
		if git clone --depth=1 -b "${BRANCH}" "${REPO_URL}" "${SRC}" >/dev/null 2>&1; then
			ok "git clone riuscito in ${SRC}"
			fetch_done=1
			break
		fi
		sleep 3
	done
fi
# Fallback 2: tarball GitHub via curl/wget.
if (( ! fetch_done )) && [[ -n "${DOWNLOADER}" ]]; then
	info "fallback: scarico il tarball del branch"
	rm -rf "${SRC}" "${SRC}.tar.gz"
	mkdir -p "${SRC}"
	if fetch "${TARBALL_URL}" "${SRC}.tar.gz" && tar -C "${SRC}" --strip-components=1 -xzf "${SRC}.tar.gz"; then
		rm -f "${SRC}.tar.gz"
		ok "tarball scaricato ed estratto in ${SRC}"
		fetch_done=1
	else
		rm -f "${SRC}.tar.gz"
	fi
fi
if (( ! fetch_done )); then
	ko "repository non recuperato con nessun metodo"
	note_problem "Clone e tarball falliti: rete instabile, rilancia lo script (i tentativi sono gia' con retry)."
	exit 1
fi
cd "${SRC}" || { ko "cd ${SRC} fallito"; exit 1; }

# -----------------------------------------------------------------------------
step "3/7 sintassi di tutti gli script"
fail=0
for f in scripts/*.sh scripts/lib/*.sh; do
	bash -n "${f}" || { ko "sintassi: ${f}"; fail=1; }
done
if (( fail )); then
	note_problem "Sintassi KO: scrivi quale file e incolla l'errore in chat."
else
	ok "sintassi OK (tutti gli script)"
fi

# -----------------------------------------------------------------------------
step "4/7 floor ISA e profili delle edizioni"
if ./scripts/verify_legacy_cpu.sh --config >/dev/null 2>&1; then
	ok "config ISA OK (edu home work slim pro)"
else
	ko "verify_legacy_cpu.sh --config fallito"
	note_problem "ISA config KO: probabile python3 mancante (vedi passo 1)."
fi

# -----------------------------------------------------------------------------
step "5/7 pipeline pre-compilazione delle 5 edizioni (stub cros_sdk)"
rm -rf "${STUB}"
mkdir -p "${STUB}/cros_sdk" "${STUB}/src/overlays" "${STUB}/src/third_party/kernel"
printf '#!/bin/sh\nexit 0\n' > "${STUB}/cros_sdk/cros_sdk"
chmod +x "${STUB}/cros_sdk/cros_sdk"
for ed in edu home work slim pro; do
	if ./scripts/build_iso.sh "${ed}" --bundle --sync-only --sdk-dir "${STUB}/cros_sdk" >/dev/null 2>&1; then
		ok "PIPELINE OK: ${ed}"
	else
		ko "PIPELINE FALLITA: ${ed}"
		note_problem "Pipeline ${ed} KO: incolla in chat l'output di  bash scripts/build_iso.sh ${ed} --bundle --sync-only --sdk-dir ${STUB}/cros_sdk"
	fi
done

step "6/7 verifica sync edizione PRO"
if ./scripts/sync_overlays.sh --check --edition pro --sdk-dir "${STUB}/cros_sdk" >/dev/null 2>&1; then
	ok "SYNC CHECK PRO OK"
else
	ko "sync check pro fallito: rigenero gli overlay e riprovo"
	./scripts/sync_overlays.sh --edition pro --sdk-dir "${STUB}/cros_sdk" >/dev/null 2>&1
	if ./scripts/sync_overlays.sh --check --edition pro --sdk-dir "${STUB}/cros_sdk" >/dev/null 2>&1; then
		ok "SYNC CHECK PRO OK (al secondo tentativo)"
	else
		note_problem "Sync PRO KO anche al retry: incolla l'output di  bash scripts/sync_overlays.sh --check --edition pro --sdk-dir ${STUB}/cros_sdk"
	fi
fi

# -----------------------------------------------------------------------------
step "7/7 il chooser PRO trasforma questa macchina"
${SUDO} mkdir -p /usr/share/prismos/editions /etc/prismos
if [[ ! -d "${STUB}/src/overlays/overlay-amd64-prismos/board/usr/share/prismos/editions" ]]; then
	ko "template edizioni assenti nel board: rigenero con una sync PRO"
	./scripts/build_iso.sh pro --bundle --sync-only --sdk-dir "${STUB}/cros_sdk" >/dev/null 2>&1
fi
${SUDO} cp -a "${STUB}/src/overlays/overlay-amd64-prismos/board/usr/share/prismos/editions/." \
	/usr/share/prismos/editions/ 2>/dev/null
${SUDO} cp overlays/overlay-prismos-pro/files/etc/prismos/pro.conf /etc/prismos/ 2>/dev/null
${SUDO} cp profiles/pro.conf /etc/prismos/edition.conf 2>/dev/null
echo work | ${SUDO} tee /etc/prismos/edition-choice >/dev/null
# The chooser is idempotent by design (stamp file): remove the stamp so the
# experiment can be re-run any number of times in the same session.
${SUDO} rm -f /var/lib/prismos/state/edition-choice.done 2>/dev/null
${SUDO} bash overlays/overlay-prismos-pro/files/usr/libexec/prismos/prismos-edition-setup
if grep -q '^PRISMOS_EDITION_ID="work"' /etc/prismos/edition.conf 2>/dev/null; then
	ok "QUESTA MACCHINA ORA E' prismOS WORK"
else
	ko "chooser non applicato"
	note_problem "Chooser KO: incolla in chat le righe 'prismos-edition-setup:' qui sopra."
fi

# -----------------------------------------------------------------------------
printf '\n%s========================================================%s\n' "${C_G}" "${C_0}"
if (( ${#PROBLEM_LINES[@]} == 0 )); then
	printf '%s ESPERIMENTO COMPLETATO: tutto [OK], nessun problema      %s\n' "${C_G}" "${C_0}"
else
	printf '%s Esperimento terminato con %d problemi:                    %s\n' "${C_R}" "${#PROBLEM_LINES[@]}" "${C_0}"
	for line in "${PROBLEM_LINES[@]}"; do
		printf '%s  - %s%s\n' "${C_R}" "${line}" "${C_0}"
	done
fi
printf '%s========================================================%s\n' "${C_G}" "${C_0}"
exit 0
