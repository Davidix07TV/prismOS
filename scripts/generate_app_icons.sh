#!/usr/bin/env bash
# =============================================================================
#  prismOS :: scripts/generate_app_icons.sh
# -----------------------------------------------------------------------------
#  Genera il tema di icone "prismOS-Squircle" a partire da profiles/app_pool.json.
#
#  Ogni applicazione del pool dichiara il proprio percorso icona nella forma
#      /usr/share/icons/prismOS-Squircle/apps/scalable/<id>.svg
#  Questo script produce quei file, piu' le icone di sistema della Dock (launcher
#  Spotlight-like, Waydroid, Wine, impostazioni, file, terminale) e il file
#  index.theme che registra il tema presso GTK/Ash.
#
#  FORMA "SQUIRCLE"
#    Il contorno e' una superellisse |x/a|^n + |y/a|^n = 1 campionata su 128
#    punti, con esponente n configurabile (default 5.0, il valore impiegato da
#    macOS Big Sur per le icone del Dock). Con --shape rounded-rect si ottiene
#    invece un rettangolo arrotondato di raggio --radius * lato.
#    Nessuna bitmap, nessun filtro SVG: le icone restano vettoriali e il
#    compositore Ash le ridimensiona senza costi su Intel HD Gen5.
#
#  USO
#    generate_app_icons.sh [opzioni]
#
#  ESEMPI
#    generate_app_icons.sh                              # tema completo nella board overlay
#    generate_app_icons.sh --only netflix,spotify -v    # due icone, log dettagliato
#    generate_app_icons.sh --preview build/preview.svg  # contact sheet di verifica
#    generate_app_icons.sh --validate                   # coerenza con app_pool.json
# =============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit extglob nullglob

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
# shellcheck source=scripts/lib/prismos_common.sh
source "$(dirname "${SCRIPT_PATH}")/lib/prismos_common.sh"
prismos_install_error_trap

readonly PROG="$(basename "${SCRIPT_PATH}")"
readonly PROG_VERSION="1.0.0"

# Destinazione predefinita: l'albero rootfs della board overlay, cosi' che
# build_iso.sh includa il tema nell'immagine senza passaggi aggiuntivi.
readonly DEFAULT_OUT="overlays/overlay-amd64-prismos/board/usr/share/icons/prismOS-Squircle"
readonly THEME_NAME="prismOS-Squircle"

# Icone di sistema generate oltre a quelle delle applicazioni.
# Formato: "nome|glifo|colore|descrizione"
SYSTEM_ICONS=(
	"prismos-launcher|Pr|#5B6CFF|Pulsante centrale della Dock: launcher stile Spotlight"
	"prismos-web-search|W|#3B82F6|Ricerca web globale (super+shift+space)"
	"prismos-waydroid|A|#3DDC84|Sottosistema Android (Waydroid / LineageOS 16.0 x86)"
	"prismos-wine|E|#8C2F39|Sottosistema Windows (Wine + Proton, backend wined3d)"
	"prismos-settings|S|#6B7280|Impostazioni di prismOS"
	"prismos-files|F|#F59E0B|Gestore dei file (apertura di .apk/.exe/.msi)"
	"prismos-terminal|>|#111827|Terminale (crosh e shell di sviluppo)"
	"prismos-lock|L|#374151|Blocco della sessione (super+l)"
)

# --- opzioni ----------------------------------------------------------------------------
ARG_OUT=""
ARG_SIZE="128"
ARG_EXPONENT="5.0"
ARG_RADIUS="0.28"
ARG_SHAPE="squircle"
ARG_ONLY=""
ARG_SKIP_SYSTEM=0
ARG_FORCE=0
ARG_PREVIEW=""
ARG_VALIDATE=0
ARG_LIST=0
ARG_DRY_RUN=0
ARG_QUIET=0
ARG_THEME_INHERIT="hicolor"

usage() {
	cat <<USAGE
${PRISMOS_C_BOLD}prismOS ${PROG_VERSION} - generatore del tema di icone squircle${PRISMOS_C_RESET}

USO
  ${PROG} [opzioni]

OPZIONI
  --out DIR            directory del tema
                       (default: ${DEFAULT_OUT})
  --size N             lato della viewBox in unita' SVG (default: 128)
  --shape FORMA        squircle | rounded-rect (default: squircle)
  --exponent N         esponente della superellisse, solo con --shape squircle
                       (default: 5.0; 2 = ellisse, 4-6 = squircle macOS,
                       valori alti tendono al quadrato)
  --radius N           raggio d'angolo come frazione del lato, solo con
                       --shape rounded-rect (default: 0.28)
  --only ID1,ID2       genera soltanto le icone indicate (id di app_pool.json
                       oppure nomi di icone di sistema)
  --no-system          non genera le icone di sistema della Dock
  --inherit NOME       tema ereditato da index.theme (default: hicolor)
  --force              sovrascrive le icone esistenti
  --preview FILE       genera anche un contact sheet SVG di anteprima
  --validate           verifica che ogni icona dichiarata in app_pool.json esista
  --list               elenca le icone che verrebbero generate ed esce
  --dry-run            non scrive alcun file
  -v, --verbose        log dettagliato
  -q, --quiet          solo gli errori
  -h, --help           questo messaggio
  -V, --version        versione

FILE GENERATI
  <out>/index.theme
  <out>/apps/scalable/<id>.svg              una per ogni applicazione del pool
  <out>/apps/scalable/prismos-*.svg         icone di sistema della Dock
  <out>/AUTHORS, <out>/LICENSE              attribuzione del tema

NOTE
  I colori provengono dal campo "color" di ogni applicazione in
  profiles/app_pool.json; il glifo proviene dal campo "glyph". Le icone sono
  vettoriali pure (nessun filtro, nessun raster incorporato) per non gravare sul
  compositore Ash delle macchine con Intel HD Graphics di prima generazione.
USAGE
}

parse_args() {
	while (( $# > 0 )); do
		case "$1" in
			--out)        ARG_OUT="${2:-}"; shift 2 ;;
			--out=*)      ARG_OUT="${1#*=}"; shift ;;
			--size)       ARG_SIZE="${2:-}"; shift 2 ;;
			--size=*)     ARG_SIZE="${1#*=}"; shift ;;
			--shape)      ARG_SHAPE="${2:-}"; shift 2 ;;
			--shape=*)    ARG_SHAPE="${1#*=}"; shift ;;
			--exponent)   ARG_EXPONENT="${2:-}"; shift 2 ;;
			--exponent=*) ARG_EXPONENT="${1#*=}"; shift ;;
			--radius)     ARG_RADIUS="${2:-}"; shift 2 ;;
			--radius=*)   ARG_RADIUS="${1#*=}"; shift ;;
			--only)       ARG_ONLY="${2:-}"; shift 2 ;;
			--only=*)     ARG_ONLY="${1#*=}"; shift ;;
			--no-system)  ARG_SKIP_SYSTEM=1; shift ;;
			--inherit)    ARG_THEME_INHERIT="${2:-}"; shift 2 ;;
			--inherit=*)  ARG_THEME_INHERIT="${1#*=}"; shift ;;
			--force)      ARG_FORCE=1; shift ;;
			--preview)    ARG_PREVIEW="${2:-}"; shift 2 ;;
			--preview=*)  ARG_PREVIEW="${1#*=}"; shift ;;
			--validate)   ARG_VALIDATE=1; shift ;;
			--list)       ARG_LIST=1; shift ;;
			--dry-run)    ARG_DRY_RUN=1; shift ;;
			-v|--verbose) PRISMOS_LOG_LEVEL="debug"; shift ;;
			-q|--quiet)   ARG_QUIET=1; PRISMOS_LOG_LEVEL="error"; shift ;;
			-h|--help)    usage; exit 0 ;;
			-V|--version) echo "${PROG} ${PROG_VERSION}"; exit 0 ;;
			--)           shift; break ;;
			-*)           usage >&2; die 2 "opzione sconosciuta: $1" ;;
			*)            usage >&2; die 2 "argomento inatteso: $1" ;;
		esac
	done

	[[ -n "${ARG_OUT}" ]] || ARG_OUT="${PRISMOS_ROOT}/${DEFAULT_OUT}"
	case "${ARG_SHAPE}" in
		squircle|rounded-rect|rounded) ;;
		*) die 2 "--shape accetta solo squircle o rounded-rect: '${ARG_SHAPE}'" ;;
	esac
	[[ "${ARG_SHAPE}" == "rounded" ]] && ARG_SHAPE="rounded-rect"
	[[ "${ARG_SIZE}" =~ ^[0-9]+$ ]] || die 2 "--size richiede un intero: '${ARG_SIZE}'"
	(( ARG_SIZE >= 16 && ARG_SIZE <= 1024 )) || die 2 "--size fuori range (16-1024): ${ARG_SIZE}"
	[[ "${ARG_EXPONENT}" =~ ^[0-9]+([.,][0-9]+)?$ ]] || die 2 "--exponent richiede un numero: '${ARG_EXPONENT}'"
	[[ "${ARG_RADIUS}" =~ ^[0-9]*[.,]?[0-9]+$ ]] || die 2 "--radius richiede un numero: '${ARG_RADIUS}'"
	ARG_EXPONENT="${ARG_EXPONENT/,/.}"
	ARG_RADIUS="${ARG_RADIUS/,/.}"
	[[ -f "${PRISMOS_APP_POOL}" ]] || die 2 "pool applicazioni mancante: ${PRISMOS_APP_POOL}"
}

# =============================================================================
# VALIDAZIONE
# =============================================================================
validate_icons() {
	log_banner "Verifica della coerenza fra app_pool.json e tema ${THEME_NAME}"
	local rc=0

	if PRISMOS_JSON_FILE="${PRISMOS_APP_POOL}" \
	   PRISMOS_ICON_ROOT="${ARG_OUT}" python3 - <<'PY'
import json, os, sys

pool_path = os.environ["PRISMOS_JSON_FILE"]
icon_root = os.environ["PRISMOS_ICON_ROOT"]

with open(pool_path, encoding="utf-8") as fh:
    pool = json.load(fh)

missing = []
for app in pool.get("applications", []):
    declared = app.get("icon", "")
    if not declared:
        continue
    # Il percorso dichiarato e' assoluto (/usr/share/icons/...): lo si confronta
    # con la radice del tema sostituendo il prefisso di sistema.
    relative = declared.split("/prismOS-Squircle/", 1)[-1]
    candidate = os.path.join(icon_root, relative)
    if not os.path.isfile(candidate):
        missing.append("%s -> %s" % (app.get("id"), candidate))

for line in missing:
    sys.stderr.write("MANCANTE %s\n" % line)
print("applicazioni verificate: %d, icone mancanti: %d"
      % (len(pool.get("applications", [])), len(missing)))
sys.exit(1 if missing else 0)
PY
	then
		log_ok "tutte le icone dichiarate nel pool sono presenti"
	else
		log_error "icone mancanti: eseguire ${PROG} senza --only per generarle tutte"
		rc=1
	fi

	local index="${ARG_OUT}/index.theme"
	if [[ -f "${index}" ]]; then
		if grep -q "^\[Icon Theme\]" "${index}" && grep -q "^Name=${THEME_NAME}" "${index}"; then
			log_ok "index.theme valido: ${index}"
		else
			log_error "index.theme malformato: ${index}"
			rc=1
		fi
	else
		log_warn "index.theme assente: ${index}"
	fi

	local count=0 svg
	while IFS= read -r svg; do
		[[ -n "${svg}" ]] || continue
		(( ++count )) || true
		if ! head -c 512 "${svg}" | grep -q '<svg'; then
			log_error "file non SVG: ${svg}"
			rc=1
		fi
	done < <(find "${ARG_OUT}" -name '*.svg' -type f 2>/dev/null | sort)
	log_info "file SVG nel tema: ${count}"

	if (( rc == 0 )); then
		log_ok "tema ${THEME_NAME} coerente"
	else
		log_error "tema ${THEME_NAME} con incongruenze"
	fi
	return "${rc}"
}

# =============================================================================
# GENERAZIONE
# =============================================================================
list_icons() {
	log_step "Icone che verrebbero generate in ${ARG_OUT}"
	local id name color
	while IFS=$'\t' read -r id name color; do
		[[ -n "${id}" ]] || continue
		printf '  apps/scalable/%-24s %s (%s)\n' "${id}.svg" "${name}" "${color}" >&2
	done < <(
		PRISMOS_JSON_FILE="${PRISMOS_APP_POOL}" python3 - <<'PY'
import json, os

with open(os.environ["PRISMOS_JSON_FILE"], encoding="utf-8") as fh:
    pool = json.load(fh)
for app in pool.get("applications", []):
    print("\t".join([str(app.get("id", "")), str(app.get("name", "")),
                     str(app.get("color", "#5B6CFF"))]))
PY
	)
	if (( ARG_SKIP_SYSTEM == 0 )); then
		local entry sysid
		for entry in "${SYSTEM_ICONS[@]}"; do
			sysid="${entry%%|*}"
			printf '  apps/scalable/%-24s %s\n' "${sysid}.svg" "${entry##*|}" >&2
		done
	fi
}

generate_icons() {
	local apps_dir="${ARG_OUT}/apps/scalable"

	log_step "Generazione del tema ${THEME_NAME} in ${ARG_OUT}"

	if (( ARG_DRY_RUN == 0 )); then
		ensure_dir "${apps_dir}"
	fi

	PRISMOS_JSON_FILE="${PRISMOS_APP_POOL}" \
	PRISMOS_ICON_OUT="${apps_dir}" \
	PRISMOS_ICON_SIZE="${ARG_SIZE}" \
	PRISMOS_ICON_SHAPE="${ARG_SHAPE}" \
	PRISMOS_ICON_EXPONENT="${ARG_EXPONENT}" \
	PRISMOS_ICON_RADIUS="${ARG_RADIUS}" \
	PRISMOS_ICON_ONLY="${ARG_ONLY}" \
	PRISMOS_ICON_SYSTEM="$( (( ARG_SKIP_SYSTEM == 0 )) && printf '%s\n' "${SYSTEM_ICONS[@]}" || true )" \
	PRISMOS_ICON_FORCE="${ARG_FORCE}" \
	PRISMOS_ICON_DRYRUN="${ARG_DRY_RUN}" \
	PRISMOS_ICON_THEME="${THEME_NAME}" \
	PRISMOS_ICON_VERBOSE="$([[ "${PRISMOS_LOG_LEVEL}" == "debug" ]] && echo 1 || echo 0)" \
	python3 - <<'PY'
import json
import math
import os
import sys

pool_path = os.environ["PRISMOS_JSON_FILE"]
out_dir = os.environ["PRISMOS_ICON_OUT"]
size = int(os.environ["PRISMOS_ICON_SIZE"])
shape = os.environ["PRISMOS_ICON_SHAPE"]
exponent = float(os.environ["PRISMOS_ICON_EXPONENT"])
radius = float(os.environ["PRISMOS_ICON_RADIUS"])
only = {t.strip() for t in os.environ.get("PRISMOS_ICON_ONLY", "").split(",") if t.strip()}
force = os.environ.get("PRISMOS_ICON_FORCE") == "1"
dry_run = os.environ.get("PRISMOS_ICON_DRYRUN") == "1"
theme = os.environ.get("PRISMOS_ICON_THEME", "prismOS-Squircle")
verbose = os.environ.get("PRISMOS_ICON_VERBOSE") == "1"

system_icons = []
for line in os.environ.get("PRISMOS_ICON_SYSTEM", "").splitlines():
    if not line.strip():
        continue
    parts = line.split("|")
    if len(parts) >= 3:
        system_icons.append({
            "id": parts[0],
            "glyph": parts[1],
            "color": parts[2],
            "name": parts[3] if len(parts) > 3 else parts[0],
        })

with open(pool_path, encoding="utf-8") as fh:
    pool = json.load(fh)


# ---------------------------------------------------------------------------
# Geometria del contorno
# ---------------------------------------------------------------------------
def squircle_path(canvas, n, margin_ratio=0.02, samples=128):
    """Superellisse |x/a|^n + |y/a|^n = 1 centrata nella viewBox."""
    margin = canvas * margin_ratio
    half = (canvas - 2 * margin) / 2.0
    center = canvas / 2.0
    exp = 2.0 / n
    points = []
    for i in range(samples):
        t = 2 * math.pi * i / samples
        cos_t = math.cos(t)
        sin_t = math.sin(t)
        x = center + math.copysign(abs(cos_t) ** exp, cos_t) * half
        y = center + math.copysign(abs(sin_t) ** exp, sin_t) * half
        points.append((x, y))
    d = ["M %.2f %.2f" % points[0]]
    d += ["L %.2f %.2f" % (x, y) for x, y in points[1:]]
    d.append("Z")
    return " ".join(d)


def rounded_rect_path(canvas, r_ratio, margin_ratio=0.02):
    """Rettangolo arrotondato con raggio pari a r_ratio * lato."""
    margin = canvas * margin_ratio
    x0 = margin
    y0 = margin
    side = canvas - 2 * margin
    r = max(1.0, min(side / 2.0, side * r_ratio))
    x1 = x0 + side
    y1 = y0 + side
    return ("M %.2f %.2f H %.2f A %.2f %.2f 0 0 1 %.2f %.2f V %.2f "
            "A %.2f %.2f 0 0 1 %.2f %.2f H %.2f A %.2f %.2f 0 0 1 %.2f %.2f "
            "V %.2f A %.2f %.2f 0 0 1 %.2f %.2f Z"
            % (x0 + r, y0, x1 - r, r, r, x1, y0 + r, y1 - r, r, r, x1, y1,
               x1 - r, r, r, x0 + r, y1, x0, y1 - r, y0 + r, r, r, x0, y0 + r))


def contour(canvas):
    if shape == "rounded-rect":
        return rounded_rect_path(canvas, radius)
    return squircle_path(canvas, exponent)


# ---------------------------------------------------------------------------
# Colore
# ---------------------------------------------------------------------------
def parse_color(value):
    text = (value or "").strip()
    if text.startswith("#") and len(text) in (4, 7):
        if len(text) == 4:
            text = "#" + "".join(c * 2 for c in text[1:])
        try:
            return (int(text[1:3], 16), int(text[3:5], 16), int(text[5:7], 16))
        except ValueError:
            pass
    return (0x5B, 0x6C, 0xFF)


def mix(rgb, factor):
    """Schiarisce (factor > 1) o scurisce (factor < 1) mantenendo il gamut."""
    return tuple(max(0, min(255, int(round(c * factor)))) for c in rgb)


def to_hex(rgb):
    return "#%02X%02X%02X" % rgb


def glyph_font_size(canvas, glyph):
    length = len(glyph or "")
    if length <= 1:
        return canvas * 0.52
    if length == 2:
        return canvas * 0.40
    if length == 3:
        return canvas * 0.30
    return canvas * 0.24


def build_svg(entry):
    glyph = entry.get("glyph") or (entry.get("name", "?")[:1] or "?")
    base = parse_color(entry.get("color"))
    light = to_hex(mix(base, 1.22))
    plain = to_hex(base)
    dark = to_hex(mix(base, 0.72))
    edge = to_hex(mix(base, 0.58))
    uid = entry["id"].replace(".", "-").replace("/", "-")
    path = contour(size)
    font_size = glyph_font_size(size, glyph)
    glyph_escaped = (glyph.replace("&", "&amp;").replace("<", "&lt;")
                          .replace(">", "&gt;"))

    # Il contorno e' dichiarato UNA sola volta in <defs> e riusato con <use>:
    # si evita di triplicare la stringa del path (128 punti) e il file resta
    # sotto i 3 KiB. Sono presenti sia href sia xlink:href per la compatibilita'
    # con librsvg delle distribuzioni datate.
    return """<?xml version="1.0" encoding="UTF-8"?>
<!--
  %(name)s - tema %(theme)s
  Generata da scripts/generate_app_icons.sh; NON modificare a mano.
  Forma: %(shape)s (esponente %(exponent)s, raggio %(radius)s), lato %(size)s.
-->
<svg xmlns="http://www.w3.org/2000/svg"
     xmlns:xlink="http://www.w3.org/1999/xlink"
     width="%(size)d" height="%(size)d" viewBox="0 0 %(size)d %(size)d"
     version="1.1" role="img" aria-label="%(name)s">
  <title>%(name)s</title>
  <defs>
    <path id="shape-%(uid)s" d="%(path)s"/>
    <linearGradient id="bg-%(uid)s" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="%(light)s"/>
      <stop offset="0.55" stop-color="%(plain)s"/>
      <stop offset="1" stop-color="%(dark)s"/>
    </linearGradient>
    <linearGradient id="gloss-%(uid)s" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.34"/>
      <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.05"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <use href="#shape-%(uid)s" xlink:href="#shape-%(uid)s" fill="url(#bg-%(uid)s)"
       stroke="%(edge)s" stroke-opacity="0.45" stroke-width="%(stroke)s"/>
  <use href="#shape-%(uid)s" xlink:href="#shape-%(uid)s" fill="url(#gloss-%(uid)s)"/>
  <text x="%(half)d" y="%(half)d" text-anchor="middle" dominant-baseline="central"
        font-family="Roboto, Cantarell, 'DejaVu Sans', sans-serif"
        font-size="%(font).2f" font-weight="600" fill="#FFFFFF"
        fill-opacity="0.96" letter-spacing="%(letter).2f">%(glyph)s</text>
</svg>
""" % {
        "name": entry.get("name", entry["id"]),
        "theme": theme,
        "shape": shape,
        "exponent": exponent,
        "radius": radius,
        "size": size,
        "half": size // 2,
        "uid": uid,
        "light": light,
        "plain": plain,
        "dark": dark,
        "edge": edge,
        "path": path,
        "stroke": "%.2f" % max(0.5, size / 128.0),
        "font": font_size,
        "letter": font_size * 0.02,
        "glyph": glyph_escaped,
    }


def write_icon(entry):
    target = os.path.join(out_dir, "%s.svg" % entry["id"])
    if os.path.exists(target) and not force and not dry_run:
        if verbose:
            sys.stderr.write("esistente, saltata: %s\n" % target)
        return "skipped"
    content = build_svg(entry)
    if dry_run:
        sys.stderr.write("[dry-run] %s (%d byte)\n" % (target, len(content)))
        return "planned"
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.chmod(target, 0o644)
    if verbose:
        sys.stderr.write("scritta: %s\n" % target)
    return "written"


entries = []
for app in pool.get("applications", []):
    app_id = app.get("id")
    if not app_id:
        continue
    if only and app_id not in only:
        continue
    entries.append({
        "id": app_id,
        "name": app.get("name", app_id),
        "glyph": app.get("glyph", app_id[:1].upper()),
        "color": app.get("color", "#5B6CFF"),
    })

for icon in system_icons:
    if only and icon["id"] not in only:
        continue
    entries.append(icon)

if only:
    known = {e["id"] for e in entries}
    unknown = sorted(only - known)
    if unknown:
        sys.stderr.write("id sconosciuti (non presenti nel pool ne' fra le icone di "
                         "sistema): %s\n" % ", ".join(unknown))

counters = {"written": 0, "skipped": 0, "planned": 0}
for entry in entries:
    counters[write_icon(entry)] += 1

print("icone applicazioni+system: %d | scritte: %d | esistenti: %d | pianificate: %d"
      % (len(entries), counters["written"], counters["skipped"], counters["planned"]))
PY

	write_theme_metadata

	if [[ -n "${ARG_PREVIEW}" ]]; then
		write_preview
	fi
}

write_theme_metadata() {
	local index="${ARG_OUT}/index.theme"
	local sub_size=$(( ARG_SIZE / 4 ))

	log_step "Scrittura dei metadati del tema"

	if (( ARG_DRY_RUN == 1 )); then
		log_info "[dry-run] ${index}"
		log_info "[dry-run] ${ARG_OUT}/AUTHORS, ${ARG_OUT}/LICENSE"
		return 0
	fi

	ensure_dir "${ARG_OUT}"

	cat > "${index}" <<INDEX
# =============================================================================
#  ${THEME_NAME} :: index.theme
#  Generato da scripts/generate_app_icons.sh - NON modificare a mano.
#  Tema vettoriale interamente scalabile: le icone sono superellissi (squircle)
#  con esponente ${ARG_EXPONENT} e lato ${ARG_SIZE}.
# =============================================================================
[Icon Theme]
Name=${THEME_NAME}
Name[it]=prismOS Squircle
Comment=macOS-like squircle icon theme for the prismOS Ash shelf
Comment[it]=Tema di icone squircle in stile macOS per la Dock di prismOS
Inherits=${ARG_THEME_INHERIT}
Directories=apps/scalable

# Ash e GTK richiedono almeno una directory dichiarata; il tema e' interamente
# scalabile, quindi MinSize e MaxSize coprono l'intero intervallo di rendering
# della Dock (da 16 a 512 px, con icone a ${sub_size} px nominali).
[apps/scalable]
Size=${sub_size}
MinSize=16
MaxSize=512
Context=Applications
Type=Scalable
INDEX

	cat > "${ARG_OUT}/AUTHORS" <<AUTHORS
Tema di icone ${THEME_NAME} per prismOS
Generato automaticamente da scripts/generate_app_icons.sh a partire da
profiles/app_pool.json (campi "glyph" e "color" di ciascuna applicazione).

Forma: superellisse |x/a|^n + |y/a|^n = 1 con n=${ARG_EXPONENT}, lato ${ARG_SIZE}.
Le icone di sistema della Dock (prismos-launcher, prismos-waydroid,
prismos-wine, ...) sono definite in SYSTEM_ICONS nello stesso script.

I marchi e i nomi delle applicazioni appartengono ai rispettivi titolari; le
icone qui generate sono segnaposto vettoriali originali (glifo su fondo
squircle) e non riproducono i loghi ufficiali.
AUTHORS

	cat > "${ARG_OUT}/LICENSE" <<'LICENSE'
Copyright (c) prismOS contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LICENSE

	chmod 0644 "${index}" "${ARG_OUT}/AUTHORS" "${ARG_OUT}/LICENSE"
	log_ok "index.theme, AUTHORS e LICENSE scritti in ${ARG_OUT}"
}

# Contact sheet di anteprima: una griglia con tutte le icone generate, utile per
# una verifica visiva senza installare il tema.
write_preview() {
	log_step "Generazione dell'anteprima ${ARG_PREVIEW}"

	if (( ARG_DRY_RUN == 1 )); then
		log_info "[dry-run] anteprima non generata"
		return 0
	fi

	ensure_dir "$(dirname "${ARG_PREVIEW}")"

	PRISMOS_JSON_FILE="${PRISMOS_APP_POOL}" \
	PRISMOS_ICON_OUT="${ARG_OUT}/apps/scalable" \
	PRISMOS_ICON_PREVIEW="${ARG_PREVIEW}" \
	PRISMOS_ICON_SIZE="${ARG_SIZE}" \
	python3 - <<'PY'
import json, os

pool_path = os.environ["PRISMOS_JSON_FILE"]
icon_dir = os.environ["PRISMOS_ICON_OUT"]
preview = os.environ["PRISMOS_ICON_PREVIEW"]
size = int(os.environ["PRISMOS_ICON_SIZE"])

with open(pool_path, encoding="utf-8") as fh:
    pool = json.load(fh)

names = [a.get("id") for a in pool.get("applications", []) if a.get("id")]
names += sorted(f[:-4] for f in os.listdir(icon_dir)
                if f.startswith("prismos-") and f.endswith(".svg"))

cell = size + 40
columns = 6
rows = (len(names) + columns - 1) // columns
width = columns * cell + 40
height = rows * cell + 60

parts = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"',
    '     width="%d" height="%d" viewBox="0 0 %d %d">' % (width, height, width, height),
    '  <rect width="%d" height="%d" fill="#F5F6FA"/>' % (width, height),
    '  <text x="20" y="32" font-family="Roboto, sans-serif" font-size="20"',
    '        font-weight="600" fill="#111827">prismOS Squircle - anteprima del tema</text>',
]

for index, name in enumerate(names):
    row = index // columns
    col = index % columns
    x = 20 + col * cell
    y = 60 + row * cell
    href = os.path.join(icon_dir, "%s.svg" % name)
    if not os.path.isfile(href):
        continue
    parts.append('  <image x="%d" y="%d" width="%d" height="%d" xlink:href="%s"/>'
                 % (x, y, size, size, href))
    parts.append('  <text x="%d" y="%d" font-family="Roboto, sans-serif" font-size="11"'
                 % (x, y + size + 16))
    parts.append('        fill="#374151">%s</text>' % name)

parts.append("</svg>")
with open(preview, "w", encoding="utf-8") as fh:
    fh.write("\n".join(parts) + "\n")
print("anteprima: %d icone in %s" % (len(names), preview))
PY

	log_ok "anteprima scritta: ${ARG_PREVIEW}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
	parse_args "$@"

	log_banner \
		"prismOS ${THEME_NAME} - generatore di icone ${PROG_VERSION}" \
		"Forma: ${ARG_SHAPE} (esponente ${ARG_EXPONENT}, raggio ${ARG_RADIUS})" \
		"Destinazione: ${ARG_OUT}"

	require_cmds python3 find sed head grep

	if (( ARG_LIST == 1 )); then
		list_icons
		exit 0
	fi
	if (( ARG_VALIDATE == 1 )); then
		local rc=0
		validate_icons || rc=$?
		exit "${rc}"
	fi

	json_validate_pool || die 2 "app_pool.json non valido"

	local rc=0
	generate_icons || rc=$?

	if (( ARG_DRY_RUN == 1 )); then
		log_warn "esecuzione in --dry-run: nessun file scritto"
	elif (( rc == 0 )); then
		log_ok "tema ${THEME_NAME} generato in ${ARG_OUT}"
		log_info "registrazione a runtime: prismos-dock-apply scrive index.theme e"
		log_info "  gtk-icon-theme-name in /etc/xdg/gtk-3.0/settings.ini"
	fi
	exit "${rc}"
}

main "$@"
