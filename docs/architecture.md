# Architettura prismOS

## Obiettivo
Un'unica codebase con varianti ISO orientate a contesti diversi, mantenendo:

- coerenza UX (stile macOS-like)
- differenziazione per scenario (lavoro, gaming, scuola, hardware legacy)
- facilità di personalizzazione (soprattutto nel profilo EDU)

## Pipeline di build

1. Caricamento profilo (`profiles/*.conf`).
2. Rendering metadati in `iso-root/.meta/profile.txt`.
3. Inclusione policy (`edu.policy.json`) per il profilo EDU.
4. Packaging ISO (`xorriso`) o fallback `.tar.gz`.

## Profili disponibili

- **work**: tool office/dev/collaboration.
- **games**: stack gaming Linux + ottimizzazioni performance.
- **edu**: software didattico + policy scolastiche configurabili.
- **slim**: desktop leggero e tuning per macchine datate.

## Policy EDU

La policy EDU espone tre blocchi gestibili dalla scuola:

- `allow_apps`: applicazioni consentite.
- `deny_web`: domini web bloccati.
- `disable_settings`: sezioni impostazioni disabilitate.

