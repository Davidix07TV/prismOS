# prismOS

`prismOS` è un sistema Linux-based ispirato all'esperienza macOS, costruito con una pipeline **multi-edizione** che genera 4 ISO:

- `work` → produttività/sviluppo
- `games` → gaming/performance
- `edu` → scuole con policy configurabili
- `slim` → macchine datate

## Obiettivo

Gestire un'unica codebase e produrre release dedicate per scenari diversi, senza mantenere quattro distro separate.

## Struttura progetto

- `profiles/common.conf` + `profiles/*.conf`: configurazione edizioni.
- `profiles/edu.policy.json`: policy scolastica per la versione EDU.
- `scripts/build_iso.sh`: build di una ISO o matrix completa (`all`).
- `scripts/set_edu_policy.sh`: modifica policy EDU da CLI.
- `scripts/validate_profiles.sh`: validazione profili e JSON policy.
- `templates/grub.cfg`: template boot menu.
- `overlays/`: file overlay comuni o specifici profilo.
- `output/`: release artifacts e checksum (ignorata da git).

## Build

```bash
# valida configurazioni
./scripts/validate_profiles.sh

# build singolo profilo
./scripts/build_iso.sh work

# build di tutte le edizioni, release nominata e clean
./scripts/build_iso.sh all --name v0.1.0 --clean
```

Output release:

- `prismOS-<profile>-<release>.iso` (o fallback `.iso.tar.gz`)
- checksum `.sha256`
- `manifest.json` con lista artefatti e hash

> Se `xorriso` non è installato, lo script usa fallback `.tar.gz` mantenendo la pipeline operativa.

## Configurazione EDU

```bash
./scripts/set_edu_policy.sh \
  --allow-apps "firefox-esr,libreoffice,geogebra" \
  --deny-web "youtube.com,twitch.tv" \
  --disable-settings "network,vpn,usb-mount" \
  --allow-guest false \
  --max-idle 20
```

La policy viene salvata in `profiles/edu.policy.json` e inclusa nella ISO EDU.

## Stato attuale

Questa repository implementa una **pipeline reale di composizione artefatti** (metadati, overlay, template boot, checksum, manifest). La parte di root filesystem completo/installer può essere integrata su questa base in uno step successivo.
