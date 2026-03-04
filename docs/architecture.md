# Architettura prismOS

## 1) Config layer

La configurazione è divisa in due livelli:

1. `profiles/common.conf`: variabili globali distro/release.
2. `profiles/<edition>.conf`: differenze per singola edizione (`work`, `games`, `edu`, `slim`).

Questo modello consente di gestire facilmente nuove edizioni senza duplicazioni massive.

## 2) Build layer

Lo script `scripts/build_iso.sh` implementa una pipeline in fasi:

1. load profilo + validazione variabili richieste;
2. creazione albero `iso-root`;
3. merge overlay (`overlays/common` + `overlays/<profile>`);
4. rendering metadati (`.meta/profile.env`, package/service manifests);
5. rendering template `templates/grub.cfg`;
6. generazione artefatto (`.iso` con `xorriso` o fallback `.tar.gz`);
7. generazione checksum + `manifest.json` release.

## 3) EDU policy layer

Per il profilo `edu` la policy scolastica è un JSON separato (`profiles/edu.policy.json`) e viene copiata in:

- `etc/prismos/edu.policy.json`

La policy supporta:

- allowlist applicazioni (`allow_apps`)
- denylist domini (`deny_web`)
- sezioni settings bloccate (`disable_settings`)
- parametri sessione (`session.allow_guest`, `session.max_idle_minutes`)

## 4) Validazione

`scripts/validate_profiles.sh` verifica:

- variabili obbligatorie per ogni profilo
- validità JSON della policy EDU

È consigliato eseguirlo in CI prima della build artefatti.
