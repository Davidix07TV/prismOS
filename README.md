# prismOS

**Sistema operativo web-centrico derivato da ChromiumOS per hardware legacy privo di SSE4.2.**

prismOS trasforma portatili e desktop ricondizionati del periodo 2010-2012 — tipicamente
equipaggiati con Intel Pentium P6100, Celeron P4xxx o Core i3/i5/i7 di prima generazione
(Arrandale), cioè CPU x86-64 che si fermano a **SSE4.1** e non implementano **SSE4.2** né
**POPCNT** — in postazioni di lavoro, aula o intrattenimento basate sul browser Chromium,
con una interfaccia Ash/Aura in stile macOS e due sottosistemi di compatibilità
(**Waydroid** per le applicazioni Android e **Wine/Proton** per quelle Windows).

Il progetto rimuove integralmente ARC, ARC++ e ARCVM: su queste CPU il container Android di
Google entra in un **loop infinito di riavvio**, perché `zygote` viene compilato con
`-msse4.2 -mpopcnt` e termina con `SIGILL` al primo avvio.

---

## Indice

1. [Perché SSE4.2 è il problema](#1-perché-sse42-è-il-problema)
2. [Architettura in sintesi](#2-architettura-in-sintesi)
3. [Le quattro edizioni](#3-le-quattro-edizioni)
4. [Struttura della repository](#4-struttura-della-repository)
5. [Prerequisiti](#5-prerequisiti)
6. [Costruzione di un'immagine](#6-costruzione-di-unimmagine)
7. [Pool delle applicazioni e Dock](#7-pool-delle-applicazioni-e-dock)
8. [Gestione delle policy scolastiche (EDU)](#8-gestione-delle-policy-scolastiche-edu)
9. [Sottosistemi di compatibilità](#9-sottosistemi-di-compatibilità)
10. [Kernel e splitconfig](#10-kernel-e-splitconfig)
11. [Verifica del floor ISA](#11-verifica-del-floor-isa)
12. [Installazione su hardware reale](#12-installazione-su-hardware-reale)
13. [Risoluzione dei problemi](#13-risoluzione-dei-problemi)
14. [Documentazione di approfondimento](#14-documentazione-di-approfondimento)
15. [Licenza](#15-licenza)

---

## 1. Perché SSE4.2 è il problema

SSE4.2 introduce sette istruzioni (`PCMPISTRI`, `PCMPISTRM`, `PCMPESTRI`, `PCMPESTRM`,
`PCMPGTQ`, `CRC32`) e, come bit ISA **indipendente**, `POPCNT`. Una CPU che non le
implementa esegue comunque il binario fino all'istruzione incriminata, quindi genera
`#UD` (invalid opcode) e il kernel consegna `SIGILL` al processo. Non esiste fallback:
l'unico rimedio è non generare quelle istruzioni.

Nei fatti il problema si presenta a quattro livelli diversi, e prismOS li presidia tutti:

| Livello | Rischio | Contromisura prismOS |
|---|---|---|
| Toolchain di sistema | `-march=native` o `-march=nehalem` sul build host abilita SSE4.2 **e** POPCNT | `CFLAGS`/`CXXFLAGS` fissi in `overlays/overlay-prismos-common/make.conf` con `-march=nehalem -mno-sse4.2 -msse4.1 -mno-popcnt` |
| Chromium (`chromeos-chrome`) | GN seleziona `-march=x86-64-v2/v3` in base al toolchain | Argomenti GN forzati: `x64_arch="generic"`, `use_thin_lto=false`, `target_cpu="x64"` |
| Linguaggi non C (Rust, Go) | `target-cpu=nehalem` riattiva `+sse4.2,+popcnt` | Rust: `target-cpu=x86-64` con `target-feature=+sse4.1,-sse4.2,-popcnt`; Go: `GOAMD64=v1` |
| Runtime Android | ART/dex2oat generano codice per la variante CPU rilevata | Immagini Waydroid **x86 a 32 bit** (baseline SSE3) e `dalvik.vm.isa.x86.variant=x86` con feature esplicite `-sse4_2,-popcnt` |

> **Nota tecnica su GCC.** `-march=nehalem` è il modello ISA più vicino ad Arrandale che GCC
> sappia esprimere, ma abilita anche SSE4.2 e POPCNT. `-mno-sse4.2` **non** disattiva POPCNT,
> che va negato esplicitamente con `-mno-popcnt`. Omettere quest'ultimo flag è l'errore più
> frequente e produce un sistema che si avvia ma va in `SIGILL` dentro Chrome o glibc.

## 2. Architettura in sintesi

```
                    ┌────────────────────────────────────────────────┐
                    │  Board amd64-prismos  (overlay-amd64-prismos)  │
                    │  make.conf = common → edizione → board         │
                    │  profiles/base/parent = chromiumos + common    │
                    │                            + prismos-<edizione>│
                    └───────────────┬────────────────────────────────┘
                                    │
      ┌─────────────────────────────┼─────────────────────────────┐
      │                             │                             │
┌─────▼──────────────┐   ┌──────────▼───────────┐   ┌─────────────▼─────────────┐
│ overlay-prismos-   │   │ overlay-prismos-     │   │ kernel/…/prismos_legacy   │
│ common             │   │ {edu,home,work,slim} │   │ splitconfig: binder,      │
│ CFLAGS/CXXFLAGS    │   │ USE di edizione,     │   │ binderfs, BINFMT_MISC,    │
│ USE negativi ARC   │   │ pacchetti, rootfs    │   │ zram/zstd, PSI, memcg,    │
│ use.mask           │   │ (/etc/prismos/*.conf)│   │ legacy-cpu, wine, slim    │
└─────┬──────────────┘   └──────────┬───────────┘   └───────────────────────────┘
      │                             │
      │   pacchetti prismOS (app-misc, app-emulation)
      ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ prismos-runtime-config  prima avvio, env.d GPU, sysctl, target sottosistemi  │
│ prismos-dock            shelf bassa/centrata/autohide + policy + icone       │
│ prismos-accelerator-…   scorciatoie globali evdev→uinput (super+space, …)    │
│ prismos-slim-launcher   avvio on-demand e teardown dei sottosistemi          │
│ prismos-waydroid-config container LineageOS 16.0 x86, prop ART, MIME .apk    │
│ prismos-wine-config     prefissi Wine, wined3d, MIME .exe/.msi, wrapper      │
└──────────────────────────────────────────────────────────────────────────────┘
```

Tre decisioni progettuali governano tutto il resto:

1. **Il floor ISA è dichiarato, non dedotto.** Ogni livello di compilazione riceve flag
   espliciti e `scripts/verify_legacy_cpu.sh` li verifica sui binari prodotti, cercando le
   codifiche byte di `CRC32`, `POPCNT`, `PCMPxSTRx`, AES-NI, PCLMUL, AVX, BMI e F16C e
   confermando i candidati con `objdump`.
2. **Le overlay di edizione contengono solo profilo e rootfs.** La logica di build vive in
   `scripts/build_iso.sh`, che concatena i `make.conf` e materializza la board overlay.
3. **Nessun sottosistema parte se non serve.** Le unità di Waydroid e Wine vengono
   installate senza attivazione predefinita (`systemd_dounit`, mai
   `systemd_enable_service`); dichiarano `[Install] WantedBy=prismos-subsystems.target` così
   che `prismos-firstboot` possa abilitarle, disabilitarle o mascherarle secondo lo stato
   letto da `/etc/prismos/edition.conf` (`enabled`, `on-demand`, `disabled`, `masked`).

## 3. Le quattro edizioni

| | **EDU** | **Home** | **Work** | **Slim** |
|---|---|---|---|---|
| Destinatario | laboratori e aule | uso domestico | flotta aziendale | macchine sotto 2 GB di RAM |
| RAM minima | 2048 MiB | 3072 MiB | 3072 MiB | 1024 MiB |
| Waydroid al boot | `enabled` | `enabled` | `on-demand` | **`on-demand` (spento)** |
| Wine al boot | `masked` | `enabled` | `enabled` | **`on-demand` (spento)** |
| Policy Chromium | Strada A o B | nessuna | dispositivo (VPN/antianonimato) | nessuna |
| Dock (pin max / predefiniti) | 8 / 6, 48 px | 10 / 8, 56 px, blur | 8 / 8, 48 px, opaca | 6 / 6, 40 px, senza animazioni |
| Peculiarità | profili effimeri, guest disabilitato, blocco social | Widevine L3 (tetto 720p), decodifica video via SIMD SSE4.1, cloud gaming | M365 fissato, VPN con kill-switch, vault LUKS per i Download | zram zstd, zswap, earlyoom, idle reaper a 120 s |

Il contratto funzionale di **Slim** merita una precisazione: Waydroid e Wine sono
*installati* (USE attive, pacchetti presenti, MIME type registrati, voci `.desktop`
disponibili) ma i loro demoni sono **completamente spenti all'avvio**. L'apertura di un file
`.apk`/`.xapk` oppure `.exe`/`.msi`/`.dll`/`.scr`/`.cpl`/`.com` attiva
`/usr/bin/prismos-slim-launcher`, che esegue `systemctl start` sul sottosistema richiesto,
attende la readiness, lancia l'applicazione e — alla chiusura — la termina con `SIGTERM` e
poi `SIGKILL`, ripulendo mount, cgroup e prefissi temporanei. È ammesso un solo sottosistema
alla volta.

Le configurazioni di edizione vivono in due posti complementari:

* `profiles/<edizione>.conf` — parametri letti da `build_iso.sh` (stato dei sottosistemi,
  aspetto della Dock, policy, requisiti hardware, frammenti di kernel);
* `overlays/overlay-prismos-<edizione>/make.conf` — flag USE e pacchetti visti da Portage;
* `overlays/overlay-prismos-<edizione>/files/` — albero rootfs copiato nell'immagine.

## 4. Struttura della repository

```
prismOS/
├── README.md                     questo documento
├── docs/
│   ├── architecture.md           architettura dettagliata e flussi di build
│   ├── edizioni.md               confronto esteso delle quattro edizioni
│   ├── waydroid-integration.md   container Android x86 a floor ISA SSE4.1
│   ├── wine-integration.md       Wine/Proton/Bottles su GPU Gen5 senza Vulkan
│   └── dock-and-launcher.md      shelf macOS-like, icone squircle, acceleratori
├── kernel/
│   ├── README.md                 come viene applicato lo splitconfig
│   └── chromeos/config/chromiumos-x86_64/prismos_legacy/
│       ├── base.config           elenco dei frammenti da concatenare
│       ├── prereq.config         dipendenze di configurazione
│       ├── fragment.config       Intel Gen5, HDA, rete, filesystem, sicurezza
│       ├── legacy-cpu.config     scheduler a 2 core, niente AVX/AES-NI, IOMMU
│       ├── android.config        binder, binderfs, namespace, cgroup v2, DMA-BUF
│       ├── wine.config           BINFMT_MISC, fsync/esync, THP, zswap, gamepad
│       └── slim.config           zram/zstd, PSI, memcg, tracer spenti
├── overlays/
│   ├── overlay-amd64-prismos/    board: identità, bootloader, naming immagine
│   │   └── board/                albero rootfs di partenza + icone squircle
│   ├── overlay-prismos-common/   CFLAGS/USE di base, eclass, pacchetti prismOS
│   │   ├── eclass/prismos-legacy-cpu.eclass
│   │   └── app-{misc,emulation}/prismos-*   sei pacchetti di sistema
│   ├── overlay-prismos-edu/      chrome_policy.json, flag di enrollment
│   ├── overlay-prismos-home/     home-tuning.conf
│   ├── overlay-prismos-work/     work.conf, policy VPN, chromium-browser
│   └── overlay-prismos-slim/     slim-tuning.conf, zram, earlyoom
├── profiles/
│   ├── app_pool.json             25 applicazioni, 4 bundle di edizione
│   ├── app_pool.schema.json      schema JSON draft-07 con validazione per tipo
│   ├── edu.conf home.conf work.conf slim.conf
└── scripts/
    ├── build_iso.sh              build interattiva (deliverable principale)
    ├── set_edu_policy.sh         Strada A / Strada B per l'edizione EDU
    ├── sync_overlays.sh          sincronia, verifica e pulizia degli overlay
    ├── verify_legacy_cpu.sh      verifica del floor ISA su binari e rootfs
    ├── generate_app_icons.sh     tema di icone squircle da app_pool.json
    ├── provision_waydroid_image.sh  immagini Android x86 a floor ISA
    └── lib/
        ├── prismos_common.sh     libreria condivisa (log, JSON, cros_sdk)
        └── isa_arc_probe.py      sonda dei token USE di ARC
```

## 5. Prerequisiti

**Host di build**

* GNU/Linux x86-64, kernel ≥ 5.10, **almeno 150 GB liberi** (una build completa di
  ChromiumOS con `chromeos-chrome` supera i 120 GB) e 8 GB di RAM consigliati;
* `git`, `curl`, `python3` (≥ 3.8), `tar`, `xz`, `unzip`, `sudo` con accesso a
  `mount`/`losetup` per la verifica delle immagini;
* il depot_tools di ChromiumOS e un checkout `chromiumos` completo
  (`repo init -u https://chromium.googlesource.com/chromiumos/manifest.git -b <release>`),
  con `cros_sdk` funzionante. La branch supportata è quella con kernel **6.1**
  (`CHROMEOS_KERNEL_VERSION="6.1"` in `overlay-prismos-common/make.conf`).

**Posizione della repository**

Clonare prismOS dentro il checkout, in modo che il chroot la veda:

```bash
cd ~/chromiumos/src/overlays
git clone <url-di-prismOS> prismOS
```

Se la repository si trova altrove, `build_iso.sh` crea automaticamente il link simbolico
`src/overlays/prismOS`; il percorso visto dal chroot si può forzare con `--repo-mount`.

**Target**

* CPU x86-64 senza SSE4.2 (Intel Pentium P6100/P6200, Celeron P4500, Core i3-330M,
  i5-430M, i7-620M e simili Arrandale);
* Intel HD Graphics di prima generazione (Ironlake, Gen5): OpenGL 2.1, **nessun Vulkan**,
  VA-API parziale (decodifica MPEG-2/VC-1; H.264 non utilizzabile in modo affidabile);
* ≥ 1 GB di RAM per l'edizione Slim, ≥ 2 GB per EDU, ≥ 3 GB per Home e Work;
* firmware in modalità Legacy BIOS oppure UEFI (l'immagine include entrambi i percorsi GRUB).

## 6. Costruzione di un'immagine

### 6.1 Build interattiva

```bash
cd ~/chromiumos/src/overlays/prismOS
./scripts/build_iso.sh slim --sdk-dir ~/chromiumos/cros_sdk
```

Lo script mostra il menu numerato delle applicazioni disponibili per l'edizione, con il
tipo (`Web_App`, `Android_Pkg`, `Windows_Pkg`) e il contrassegno di quelle già previste dal
bundle; la selezione accetta elenchi e intervalli:

```
  N.   APPLICAZIONE               TIPO          DEF.
  -----------------------------------------------------------------------
  1.   Google Drive               Web_App       *
  2.   YouTube                    Web_App       *
  3.   Spotify                    Web_App       *
  ...
Seleziona le applicazioni da installare [es. 1,3,5 | 2-7 | all | none]
(default: 1,2,3,4,5,12,16):
```

Le fasi successive sono: generazione di `shelf.json` e `edition.conf`, sincronizzazione
degli overlay nel `cros_sdk`, `setup_board --board=amd64-prismos`,
`build_packages --board=amd64-prismos`, `build_image --board=amd64-prismos
--noenable_rootfs_verification dev`, raccolta in `output/prismOS_<edizione>_legacy.img`,
verifica del floor ISA sui binari critici del sysroot.

### 6.2 Build non interattiva

```bash
# bundle predefinito dell'edizione
./scripts/build_iso.sh home --bundle --jobs 8

# selezione esplicita
./scripts/build_iso.sh edu --apps 1,3,5-7

# tutte e quattro le edizioni in sequenza
./scripts/build_iso.sh all --bundle

# sola preparazione degli overlay, senza compilare
./scripts/build_iso.sh work --sync-only
```

Opzioni principali: `--sdk-dir`, `--board`, `--jobs`, `--apps`, `--bundle`,
`--image-type dev|base|test`, `--policy-mode local|cloud|none`, `--copy-overlays`,
`--no-sync`, `--sync-only`, `--skip-verify`, `--keep-build`, `--dry-run`, `--verbose`.
`./scripts/build_iso.sh --help` le elenca tutte.

### 6.3 Artefatti prodotti

| Percorso | Contenuto |
|---|---|
| `output/prismOS_<edizione>_legacy.img` | immagine disco avviabile |
| `output/prismOS_<edizione>_legacy.img.info` | metadati: board, kernel, ISA, app selezionate, SHA-256 |
| `output/prismOS_<edizione>_legacy.shelf.json` | configurazione della Dock usata nella build |
| `output/prismOS_<edizione>_legacy.edition.conf` | stato dei sottosistemi incorporato |
| `output/prismOS_<edizione>_legacy.isa-report.{txt,json}` | esito della verifica del floor ISA |
| `build/<edizione>-<timestamp>/` | staging rigenerabile (`etc/skel`, `etc/prismos`) |
| `build/logs/build-<edizione>-<timestamp>.log` | log completo della build |

### 6.4 Sincronizzazione degli overlay

Dopo la modifica di una overlay non è necessario ricompilare per aggiornare l'albero di
build:

```bash
./scripts/sync_overlays.sh --edition home        # sincronizza senza compilare
./scripts/sync_overlays.sh --check               # verifica coerenza di link, parent,
                                                 # make.conf, splitconfig, policy, icone
./scripts/sync_overlays.sh --list                # stato degli overlay nel SDK
./scripts/sync_overlays.sh --diff --edition edu  # divergenze fra SDK e repository
./scripts/sync_overlays.sh --clean --yes         # rimuove ogni riferimento prismOS
```

## 7. Pool delle applicazioni e Dock

`profiles/app_pool.json` è la fonte unica di verità per le applicazioni: 25 voci (15
`Web_App`, 6 `Android_Pkg` da F-Droid, 4 `Windows_Pkg`) e 4 bundle di edizione con
`preselected`, `default_pinned`, `max_pinned` e `blocked_by_policy`. Ogni voce dichiara
`launch_url`, `install_url`, `scope`, `icon`, `glyph`, `color`, `category`, i requisiti
(`min_ram_mb`, `sse42_required`, `arm_translation_required`) e, per i tipi non web, i dati
di sottosistema (`android_package`/`android_activity`, `wine_prefix`/`wine_arch`/
`installer_args`/`post_install_binary`/`wine_dependencies`).

Da quel file `build_iso.sh` genera tre artefatti:

1. `/etc/skel/.config/chromiumos/shelf.json` — Dock centrata con allineamento basso,
   autohide, maschera squircle (superellisse con esponente 5.0), raggio, dimensione icona,
   acceleratore del launcher e l'elenco delle icone bloccate, ciascuna con il sottosistema
   di appartenenza e l'unità systemd da attivare;
2. `/etc/chromium/policies/managed/zz-prismos-dock.json` — `ShelfAlignment=Bottom`,
   `ShelfAutoHideBehavior=Always`, `PinnedLauncherApps` e `WebAppInstallForceList`;
3. `/usr/share/prismos/app_pool.json` — copia consultata a runtime dal launcher.

Le icone sono vettoriali e generate da `scripts/generate_app_icons.sh`:

```bash
./scripts/generate_app_icons.sh                      # tema completo nella board overlay
./scripts/generate_app_icons.sh --list               # anteprima dell'elenco
./scripts/generate_app_icons.sh --shape rounded-rect --radius 0.22
./scripts/generate_app_icons.sh --preview build/preview.svg
./scripts/generate_app_icons.sh --validate           # coerenza con app_pool.json
```

Ogni icona è una superellisse |x/a|ⁿ + |y/a|ⁿ = 1 campionata su 128 punti (n = 5.0,
l'aspetto delle icone di macOS Big Sur), con gradiente verticale derivato dal colore del
marchio, lucidatura superiore e glifo centrale. Nessun filtro SVG e nessuna bitmap: il
compositore Ash le ridimensiona senza costi misurabili su Gen5.

Le scorciatoie globali sono gestite da `prismos-accelerator-daemon`
(`/usr/libexec/prismos/`), che cattura la tastiera via evdev e inietta `KEY_SEARCH`
attraverso uinput; la mappa delle dodici combinazioni è dichiarata in
`/usr/share/prismos/accelerators.json`: `super+space` (launcher in stile
Spotlight), `super+shift+space` (ricerca web), `super+l` (blocco), `super+d` (desktop),
`super+w` (overview), `super+print` (screenshot), `super+1..4` (cambio applicazione),
`super+ctrl+s`/`super+ctrl+q` (avvio dei sottosistemi).

## 8. Gestione delle policy scolastiche (EDU)

L'edizione EDU supporta due strade alternative, selezionabili in build con
`--policy-mode` oppure a posteriori con `scripts/set_edu_policy.sh`.

### Strada A — Cloud-Managed

Il dispositivo si iscrive alla Google Admin Console dell'istituto. Vengono scritti in
`/etc/default/chromium-browser` **solo** gli switch di Enterprise Enrollment effettivamente
riconosciuti da Chromium:

```
--enterprise-enable-zero-touch-enrollment
--enterprise-enrollment-initial-modulus=<base64>          # opzionale, DM server proprio
--enterprise-enrollment-initial-modulus-length=<n>
--arc-availability=none
```

Nessuna policy JSON locale viene installata (le policy di dispositivo avrebbero precedenza
su quelle cloud). Con `--with-domain-policy` si aggiunge una policy minima — `UserAllowlist`
sul dominio, `ArcEnabled=false`, guest e VM disabilitati — utile nel periodo che precede il
completamento dell'iscrizione.

```bash
./scripts/set_edu_policy.sh --strada a --domain liceo-fermi.edu \
    --rootfs /build/amd64-prismos
./scripts/set_edu_policy.sh --strada a --domain liceo-fermi.edu \
    --dm-modulus <base64> --dm-modulus-length 2048 --with-domain-policy
```

### Strada B — Local-Policy

Nessuna infrastruttura Google: la policy di dispositivo viene scritta in
`/etc/chromium/policies/managed/prismos_policy.json` a partire dal template
`overlays/overlay-prismos-edu/chrome_policy.json` (81 chiavi), sostituendo il dominio
segnaposto e componendo:

* **URLBlocklist** — TikTok, YouTube e Twitch con CDN, shortener e domini correlati
  (`*.tiktokcdn.com`, `*.musical.ly`, `*.googlevideo.com`, `*.ytimg.com`, `*.ttvnw.net`,
  `*.jtvnw.net`), più i social, il gaming, i proxy anonimi e i contenuti per adulti già
  presenti nel template;
* **URLAllowlist** — dominio dell'istituto e sottodomini (`*://*.ic-manzi.edu/*`), servizi
  ministeriali, Google Workspace for Education, Geogebra, Canva, Wikipedia, Khan Academy,
  Scratch, F-Droid;
* **UserAllowlist** — `*@<dominio>`, disattivabile con `--all-users`.

Poiché in Chromium la URLAllowlist ha precedenza sulla URLBlocklist, lo script rimuove
automaticamente ogni voce consentita che ricada in un dominio bloccato e lo registra nel log.

```bash
./scripts/set_edu_policy.sh --strada b --domain ic-manzi.edu \
    --allowlist "*://web.spaggiari.eu/* *://*.indire.it/*"
./scripts/set_edu_policy.sh --strada b --domain ic-manzi.edu \
    --blocklist "*://*.roblox.com/*" --all-users
./scripts/set_edu_policy.sh --show      # riepilogo della configurazione installata
./scripts/set_edu_policy.sh --validate  # sintassi, conflitti, chiavi ARC
./scripts/set_edu_policy.sh --remove    # ritorno alla Strada A pura
```

Tutti i comandi accettano `--rootfs <albero>` per agire su una overlay, su una rootfs
montata o su `/build/<board>`; senza quell'opzione operano dal vivo sul dispositivo, con
`sudo`, e supportano `--dry-run`, `--no-backup` e `--restart-ui`.

## 9. Sottosistemi di compatibilità

### 9.1 Waydroid (Android)

LineageOS 16.0 (Android 9), **variante x86 a 32 bit**, vendor `MAINLINE` (kernel ospite con
binderfs, niente secondo kernel Halium), gralloc `minigbm`, EGL SwiftShader. Le immagini
x86_64 pubblicate a monte sono rifiutate: sono compilate con SSE4.2 e POPCNT.

```bash
sudo ./scripts/provision_waydroid_image.sh --edition slim
./scripts/provision_waydroid_image.sh --edition home --query-latest --source upstream
sudo ./scripts/provision_waydroid_image.sh --edition work --build \
     --source-dir ~/lineageos-16.0 --jobs 8
sudo ./scripts/provision_waydroid_image.sh --edition edu \
     --archive ~/lineage-16.0-waydroid_x86.zip --deep-verify
```

Lo script scarica (con ripresa e verifica SHA-256), estrae `system.img`/`vendor.img` in
`/var/lib/waydroid/images`, installa `waydroid_base.prop` e `waydroid_mainline.prop` con le
proprietà ART del floor ISA e il budget di memoria dell'edizione, verifica che nessuna ABI a
64 bit sia esposta e scrive il marcatore `ISA_FLOOR`: se il marcatore manca,
oppure dichiara un ISA superiore a SSE4.1, `prismos-waydroid-prepare` **rifiuta** di avviare
il container (l'eccezione si dichiara con `PRISMOS_ALLOW_UNVERIFIED_IMAGES=1`). Con `--deep-verify` monta
`system.img` in sola lettura e scandisce le librerie native.

La traduzione ARM (houdini, libndk_translation) è disattivata: richiede SSE4.2. Sono
esposte solo le ABI `x86,armeabi-v7a,armeabi` e le applicazioni ARM-only non sono
installabili; `profiles/app_pool.json` seleziona pertanto pacchetti F-Droid disponibili per
x86 (`arm_translation_required: false`).

### 9.2 Wine e Proton (Windows)

Wine con USE `run-exes`, prefisso predefinito `~/WineBottles/Default`
(`/home/chronos/user/WineBottles/Default`, `WINEARCH=win64`), `wineserver` persistente per
sessione, esecuzione diretta di `.exe`/`.msi` dal gestore dei file grazie ai MIME type e a
`BINFMT_MISC`. `prismos-wine-prepare` sceglie il backend verificando la presenza reale di un
ICD Vulkan: su Gen5 non ne esiste alcuno, quindi viene sempre selezionato `wined3d`.

Su Intel HD Gen5 **DXVK e VKD3D-Proton sono inutilizzabili** (manca Vulkan): il backend è
`wined3d` con GLSL e Shader Model 3, driver Mesa `crocus`, 64 MB di VRAM dichiarati. Proton
e Bottles restano disponibili nelle edizioni con RAM sufficiente (Home, Work), mentre EDU
maschera Wine e Slim esclude Bottles.

Il flusso on-demand è `prismos-wine-prepare` → `prismos-wine-run` → `wineserver -k`,
orchestrato dall'unità template `prismos-wine-session@<uid>.service` con `StopWhenUnneeded`
e `MemoryMax=512M`.

### 9.3 Rimozione di ARC

Tre livelli indipendenti: USE negativi (`-arc -arc-plus`), `profiles/base/use.mask` e
`package.use.mask`, policy di dispositivo (`ArcEnabled=false`, `UnaffiliatedArcAllowed=false`,
`UnaffiliatedDeviceArcAllowed=false`, `VirtualMachinesAllowed=false`,
`DeviceUnaffiliatedCrostiniAllowed=false`, `CrostiniAllowed=false`) più lo switch
`--arc-availability=none`. `scripts/verify_legacy_cpu.sh --config` verifica che nessuna
`make.defaults` riattivi un token ARC.

## 10. Kernel e splitconfig

Lo splitconfig `chromiumos-x86_64/prismos_legacy` vive in
`kernel/chromeos/config/chromiumos-x86_64/prismos_legacy/` e viene copiato in
`src/third_party/kernel/v6.1/chromeos/config/chromiumos-x86_64/` da `build_iso.sh`
(o da `sync_overlays.sh`). È selezionato da `CHROMEOS_KERNEL_SPLITCONFIG` nella board
`make.conf`.

| Frammento | Contenuto essenziale |
|---|---|
| `base.config` | elenco dei frammenti da concatenare |
| `prereq.config` | dipendenze di configurazione (cgroup, namespace, netfilter) |
| `fragment.config` | Intel Gen5 (DRM_I915, crocus/i965), HDA, rete, filesystem, LSM SELinux |
| `legacy-cpu.config` | scheduler per 2 core, niente AVX/AES-NI, `INTEL_IOMMU=y` con `DEFAULT_ON=n`, ITCO_WDT |
| `android.config` | `ANDROID_BINDER_IPC`, binderfs, namespace, cgroup v2, DMA-BUF |
| `wine.config` | `BINFMT_MISC`, fsync/esync, THP `madvise`, zswap, gamepad |
| `slim.config` | zram/zstd, PSI, memcg, tracer spenti (con `BPF_SYSCALL=y` per la sandbox di Chrome) |

Dettagli e motivazioni delle singole voci: [`kernel/README.md`](kernel/README.md).

## 11. Verifica del floor ISA

```bash
./scripts/verify_legacy_cpu.sh --host            # capacità ISA della macchina corrente
./scripts/verify_legacy_cpu.sh --config          # coerenza della repository
./scripts/verify_legacy_cpu.sh --pe ~/setup.exe  # singolo binario (ELF o PE)
./scripts/verify_legacy_cpu.sh --board amd64-prismos --full
./scripts/verify_legacy_cpu.sh --image output/prismOS_slim_legacy.img \
    --report output/isa.txt --json output/isa.json
```

Il metodo è in due fasi: ricerca delle codifiche byte (veloce, nessun disassemblatore) e
conferma con `objdump` sui soli candidati, per mnemonico. Le librerie con dispatch IFUNC —
glibc, OpenSSL, zlib, LLVM/Mesa e i driver DRI — contengono legittimamente percorsi SSE4.2
selezionati a runtime e sono classificate `dispatched`: non costituiscono fallimento. Sono
invece fatali le evidenze su `chrome`, Wine, Waydroid e i pacchetti prismOS, compilati con
`-march` fisso. Codici di uscita: `0` conforme, `1` non conforme, `2` errore d'uso.

## 12. Installazione su hardware reale

```bash
# dentro il chroot, con la chiavetta USB collegata
cros flash usb:// ~/chromiumos/src/overlays/prismOS/output/prismOS_slim_legacy.img
```

In alternativa, da un sistema Linux avviato, `dd if=prismOS_<edizione>_legacy.img
of=/dev/sdX bs=8M status=progress conv=fsync`. Sul target è necessario:

1. disattivare il **Verified Boot** (le immagini `dev` nascono con
   `--noenable_rootfs_verification`; su hardware con firmware ChromeOS serve impostare
   il flag GBB con `make_dev_ssd.sh --remove_rootfs_verification`);
2. avviare la OOBE e creare l'account locale (EDU Strada A: il dispositivo si iscrive da
   solo se il seriale è censito nella Admin Console);
3. per Waydroid, eseguire `provision_waydroid_image.sh` una tantum (richiede rete).

Le immagini sono `dev`: includono `dev_install`, sudo e shell di sviluppo. Per una
variante priva di strumenti di sviluppo usare `--image-type base`, tenendo presente che la
scrittura di `/etc` a runtime (policy, preferenze di Ash, vault dei Download) richiede
rootfs verification disattivata.

## 13. Risoluzione dei problemi

| Sintomo | Causa probabile | Rimedio |
|---|---|---|
| `SIGILL` all'avvio di Chrome | POPCNT abilitato da `-march=nehalem` | aggiungere `-mno-popcnt` in `overlay-prismos-common/make.conf` e ricompilare `chromeos-chrome` |
| Il container Waydroid si riavvia in loop | immagini x86_64 o `dalvik.vm.isa.x86.variant=nehalem` | `provision_waydroid_image.sh --force` con sorgente x86 a 32 bit; controllare `ISA_FLOOR` |
| `binder: failed to open` | binderfs non abilitato | verificare `android.config` e `mount -t binder none /dev/binderfs` |
| Schermo nero o rendering software | driver Mesa errato (`iris`/`zink`) | `MESA_LOADER_DRIVER_OVERRIDE=crocus`, `LIBVA_DRIVER_NAME=i965`, `LIBGL_DRI3_DISABLE=1` |
| Video DRM a 480p o 720p | Widevine L3 su piattaforma non certificata | comportamento atteso: il livello L1 non è disponibile e i servizi limitano la risoluzione |
| La Dock non è centrata o non si nasconde | policy della Dock assente | `systemctl status prismos-dock-apply` e controllare `zz-prismos-dock.json` |
| `super+space` non apre il launcher | daemon accelerator senza accesso a evdev | `systemctl status prismos-accelerator-daemon`, gruppo `input`, `/dev/uinput` |
| Slim: `.exe` non si apre | sottosistema Wine non installato o mascherato | `prismos-slim-launcher doctor`; verificare `WINE_BOOT_STATE` in `/etc/prismos/edition.conf` |
| `setup_board` fallisce | overlay non sincronizzata o `parent` errato | `sync_overlays.sh --check` |
| Build lentissima o OOM sul build host | parallelismo eccessivo con 2 GB | `--jobs 2`; l'edizione Slim attiva `single-thread-link` |

## 14. Documentazione di approfondimento

* [`docs/architecture.md`](docs/architecture.md) — flussi di build, concatenazione dei
  profili, unità systemd, percorsi a runtime, estensione del progetto;
* [`docs/edizioni.md`](docs/edizioni.md) — confronto esteso e matrici di configurazione;
* [`docs/waydroid-integration.md`](docs/waydroid-integration.md) — container Android x86,
  proprietà ART, marcatore `ISA_FLOOR`, ciclo di vita delle unità;
* [`docs/wine-integration.md`](docs/wine-integration.md) — Wine, Proton e Bottles su Intel
  HD Gen5 senza Vulkan, MIME type, prefissi;
* [`docs/dock-and-launcher.md`](docs/dock-and-launcher.md) — shelf macOS-like, policy,
  `shelf.json`, tema di icone squircle, acceleratori globali;
* [`kernel/README.md`](kernel/README.md) — splitconfig del kernel;
* `./scripts/<nome>.sh --help` — riferimento completo di ogni strumento.

## 15. Licenza

Il codice originale di prismOS — script, overlay, configurazioni, unità systemd, profili e
tema di icone — è rilasciato con licenza **MIT**: vedere [`LICENSE`](LICENSE) e
`overlays/overlay-amd64-prismos/board/usr/share/icons/prismOS-Squircle/LICENSE`. I sei
ebuild dichiarano `LICENSE="MIT"` per coerenza.

prismOS deriva da ChromiumOS e incorpora componenti di terze parti — Chromium, Gentoo,
Waydroid, LineageOS, Wine, Proton, Mesa, LXC — ciascuno soggetto alla propria licenza. Le
icone generate sono segnaposto vettoriali originali (glifo su fondo squircle) e **non**
riproducono i loghi ufficiali delle applicazioni; i marchi citati appartengono ai rispettivi
titolari. Widevine è un modulo DRM di Google soggetto a termini di licenza specifici e viene
distribuito unicamente attraverso i canali previsti da ChromiumOS.
