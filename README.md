# prismOS 💎✨

prismOS è una base Linux modulare ispirata al workflow di macOS, con un sistema di build che genera **4 ISO dedicate**:

1. **work** – ottimizzata per produttività, sviluppo e collaborazione.
2. **games** – ottimizzata per gaming desktop e supporto controller.
3. **edu** – pensata per scuole, con blocchi configurabili dall'istituto.
4. **slim** – leggera per PC datati o risorse limitate.

> Obiettivo: fornire una pipeline unica e ripetibile per creare varianti mirate senza mantenere quattro distro separate.

## Struttura repository

- `profiles/*.conf`: definizione completa delle 4 edizioni ISO.
- `scripts/build_iso.sh`: script principale per generare ISO per un profilo o per tutti.
- `scripts/set_edu_policy.sh`: utility per impostare i blocchi della versione EDU.
- `output/`: cartella di output degli artefatti (creata automaticamente).

## Requisiti minimi

- Bash 5+
- `xorriso` (opzionale ma consigliato per output `.iso`)

Se `xorriso` non è disponibile, la build produce un archivio `.tar.gz` dell'albero ISO come fallback.

## Build rapida

```bash
# Build di una sola edizione
./scripts/build_iso.sh work

# Build di tutte le edizioni
./scripts/build_iso.sh all
```

Gli artefatti vengono salvati in `output/`.

## Configurazione EDU (blocchi scolastici)

Esempio policy personalizzata:

```bash
./scripts/set_edu_policy.sh \
  --allow-apps "firefox,libreoffice,geogebra" \
  --deny-web "youtube.com,twitch.tv" \
  --disable-settings "network,vpn,usb-mount"
```

Lo script aggiorna `profiles/edu.policy.json`, inclusa automaticamente nella ISO EDU.

## Filosofia "macOS-like"

prismOS adotta alcune linee guida UX in stile macOS, pur restando Linux-based:

- Desktop pulito e coerente.
- Preferenze centralizzate.
- Workflow orientato a dock/launcher e scorciatoie globali.
- Setup iniziale rapido con profili predefiniti per caso d'uso.

