#!/usr/bin/env bash
# =============================================================================
# exp.sh - prismOS browser experiment (DistroSea and similar live sessions).
#
# One command, everything included: dependencies, clone, the full validation
# pipeline of the five editions against a stub cros_sdk, and the PRO edition
# chooser turning the live session into "prismOS WORK".
#
# Usage (from the live session terminal, no clipboard needed):
#   curl -fsSL https://raw.githubusercontent.com/Davidix07TV/prismOS/arena/01a09a0e-prismos/scripts/exp.sh | bash
# or, from an existing prismOS clone:
#   bash scripts/exp.sh
#
# Every result is printed as a colored [OK]/[KO] line plus a final summary.
# [KO] lines almost always mean "no internet in this session": log in to the
# service (free account) and restart it.
# =============================================================================
set -uo pipefail

C_G=$'\033[1;32m'; C_R=$'\033[1;31m'; C_Y=$'\033[1;33m'; C_0=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "${C_Y}" "${C_0}" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "${C_G}" "${C_0}" "$*"; }
ko()   { printf '%s[KO]%s %s\n' "${C_R}" "${C_0}" "$*"; }

SUDO="sudo"
command -v sudo >/dev/null 2>&1 || SUDO=""

step "1/6 dipendenze (git, python3)"
need=()
command -v git >/dev/null 2>&1 || need+=(git)
command -v python3 >/dev/null 2>&1 || need+=(python3)
if (( ${#need[@]} )); then
	${SUDO} apt-get update -y -qq >/dev/null 2>&1
	${SUDO} apt-get install -y -qq "${need[@]}" >/dev/null 2>&1 || \
		ko "apt-get fallito: la sessione ha internet?"
fi
if command -v git >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
	ok "git e python3 presenti"
else
	ko "git/python3 mancanti: senza non si continua"
	exit 1
fi

step "2/6 repository prismOS"
SRC="/tmp/prismOS-exp"
if [[ "${BASH_SOURCE[0]}" == */* && -d "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/scripts" ]]; then
	SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	ok "uso il clone esistente: ${SRC}"
else
	rm -rf "${SRC}"
	if git clone --depth=1 -b arena/01a09a0e-prismos \
	     https://github.com/Davidix07TV/prismOS.git "${SRC}" >/dev/null 2>&1; then
		ok "clone completato in ${SRC}"
	else
		ko "clone fallito: niente internet nella sessione (serve account gratuito)"
		exit 1
	fi
fi
cd "${SRC}" || exit 1

step "3/6 sintassi di tutti gli script"
fail=0
for f in scripts/*.sh scripts/lib/*.sh; do
	bash -n "${f}" || { ko "sintassi: ${f}"; fail=1; }
done
(( fail )) || ok "sintassi OK (tutti gli script)"

step "4/6 floor ISA e profili delle edizioni"
if ./scripts/verify_legacy_cpu.sh --config >/dev/null 2>&1; then
	ok "config ISA OK (edu home work slim pro)"
else
	ko "verify_legacy_cpu.sh --config fallito"
fi

step "5/6 pipeline pre-compilazione delle 5 edizioni (stub cros_sdk)"
STUB="/tmp/ds-stub"
rm -rf "${STUB}"
mkdir -p "${STUB}/cros_sdk" "${STUB}/src/overlays" "${STUB}/src/third_party/kernel"
printf '#!/bin/sh\nexit 0\n' > "${STUB}/cros_sdk/cros_sdk"
chmod +x "${STUB}/cros_sdk/cros_sdk"
for ed in edu home work slim pro; do
	if ./scripts/build_iso.sh "${ed}" --bundle --sync-only --sdk-dir "${STUB}/cros_sdk" >/dev/null 2>&1; then
		ok "PIPELINE OK: ${ed}"
	else
		ko "PIPELINE FALLITA: ${ed}"
	fi
done
if ./scripts/sync_overlays.sh --check --edition pro --sdk-dir "${STUB}/cros_sdk" >/dev/null 2>&1; then
	ok "SYNC CHECK PRO OK"
else
	ko "sync check pro fallito"
fi

step "6/6 il chooser PRO trasforma questa macchina"
${SUDO} mkdir -p /usr/share/prismos/editions /etc/prismos
${SUDO} cp -a "${STUB}/src/overlays/overlay-amd64-prismos/board/usr/share/prismos/editions/." \
	/usr/share/prismos/editions/ 2>/dev/null
${SUDO} cp overlays/overlay-prismos-pro/files/etc/prismos/pro.conf /etc/prismos/ 2>/dev/null
${SUDO} cp profiles/pro.conf /etc/prismos/edition.conf 2>/dev/null
echo work | ${SUDO} tee /etc/prismos/edition-choice >/dev/null
${SUDO} bash overlays/overlay-prismos-pro/files/usr/libexec/prismos/prismos-edition-setup
if grep -q '^PRISMOS_EDITION_ID="work"' /etc/prismos/edition.conf 2>/dev/null; then
	ok "QUESTA MACCHINA ORA E' prismOS WORK"
else
	ko "chooser non applicato (controlla le righe qui sopra)"
fi

printf '\n%s========================================================%s\n' "${C_G}" "${C_0}"
printf '%s esperimento completato: conta le righe [OK] qui sopra   %s\n' "${C_G}" "${C_0}"
printf '%s [KO]? quasi sempre = sessione senza internet/account    %s\n' "${C_G}" "${C_0}"
printf '%s========================================================%s\n' "${C_G}" "${C_0}"
