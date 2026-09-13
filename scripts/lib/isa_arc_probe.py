#!/usr/bin/env python3
# =============================================================================
#  prismOS :: scripts/lib/isa_arc_probe.py
# -----------------------------------------------------------------------------
#  Ausiliario di scripts/verify_legacy_cpu.sh --config.
#
#  Esamina le make.defaults delle overlay prismOS e segnala ogni token USE che
#  ABILITA un sottosistema Android di Google (ARC, ARC++, ARCVM). I token
#  negativi ("-arc", "-arc-plus") sono ignorati: sono esattamente cio' che
#  prismOS richiede. La scansione testuale con grep produrrebbe falsi positivi
#  perche' "-arc" contiene un word boundary valido per \barc\b.
#
#  USO
#    isa_arc_probe.py <directory_delle_overlay> [<altre_directory> ...]
#
#  USCITA
#    una riga per ogni violazione, nel formato "<percorso relativo> :: <token>"
#    codice di uscita 0 se non vi sono violazioni, 1 altrimenti
# =============================================================================

import glob
import os
import re
import sys

ARC_TOKENS = {"arc", "arcplusplus", "arcvm", "arc-container", "arc-standalone"}
ARC_PREFIXES = ("arc-", "arcvm-", "arc++")
USE_ASSIGNMENT = re.compile(r'^\s*USE\s*\+?=\s*"([^"]*)"', re.MULTILINE)


def scan_make_defaults(path: str, root: str) -> list:
    violations = []
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return violations

    for match in USE_ASSIGNMENT.finditer(text):
        for token in match.group(1).split():
            # Le espansioni di variabile (${USE}, ${PRISMOS_USE}) non sono
            # token USE e vanno saltate.
            if token.startswith("-") or "$" in token or "{" in token:
                continue
            lowered = token.lower()
            if lowered in ARC_TOKENS or lowered.startswith(ARC_PREFIXES):
                relative = os.path.relpath(path, root) if root else path
                violations.append("%s :: %s" % (relative, token))
    return violations


def main(argv: list) -> int:
    if len(argv) < 2:
        sys.stderr.write("uso: isa_arc_probe.py <directory_overlay> [...]\n")
        return 2

    found = []
    for root in argv[1:]:
        if not os.path.isdir(root):
            sys.stderr.write("directory inesistente: %s\n" % root)
            continue
        pattern = os.path.join(root, "overlay-*", "profiles", "base", "make.defaults")
        for path in sorted(glob.glob(pattern)):
            found.extend(scan_make_defaults(path, root))
        # Anche il make.conf del board e delle edizioni puo' dichiarare USE.
        for extra in sorted(glob.glob(os.path.join(root, "overlay-*", "make.conf"))):
            found.extend(scan_make_defaults(extra, root))

    for line in found:
        print(line)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
