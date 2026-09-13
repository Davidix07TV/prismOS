<div align="center">

<img src="assets/prismos-logo.svg" alt="prismOS — lettera P isometrica a facce piegate" width="200" />

# prismOS

### Sistema operativo web-centrico derivato da ChromiumOS per hardware legacy senza SSE4.2

[![Ultima release](https://img.shields.io/github/v/release/Davidix07TV/prismOS?style=for-the-badge&labelColor=0d1117)](https://github.com/Davidix07TV/prismOS/releases)
[![Licenza](https://img.shields.io/github/license/Davidix07TV/prismOS?style=for-the-badge&labelColor=0d1117)](https://github.com/Davidix07TV/prismOS/blob/main/LICENSE)
[![Attività commit](https://img.shields.io/github/commit-activity/m/Davidix07TV/prismOS?style=for-the-badge&labelColor=0d1117)](https://github.com/Davidix07TV/prismOS/commits)
[![Dimensione repo](https://img.shields.io/github/repo-size/Davidix07TV/prismOS?style=for-the-badge&labelColor=0d1117)](https://github.com/Davidix07TV/prismOS)

<br/>

[![Bash](https://img.shields.io/badge/Bash-5.2%2B-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white&labelColor=0d1117)](https://www.gnu.org/software/bash/)
[![Kernel ChromiumOS](https://img.shields.io/badge/Kernel%20ChromiumOS-6.1-0b6ec4?style=for-the-badge&logo=linux&logoColor=white&labelColor=0d1117)](kernel/README.md)
[![Floor ISA](https://img.shields.io/badge/Floor%20ISA-SSE4.1%20%7C%20no%20SSE4.2%2FPOPCNT-c2410c?style=for-the-badge&labelColor=0d1117)](#floor-isa)
[![Waydroid](https://img.shields.io/badge/Waydroid-LineageOS%2016.0%20x86-3ddc84?style=for-the-badge&logo=android&logoColor=white&labelColor=0d1117)](docs/waydroid-integration.md)

<br/>

[**Funzionalità**](#funzionalit) · [**Edizioni**](#edizioni) · [**Build**](#build) · [**Policy EDU**](#policy-scolastiche-edu) · [**Verifica ISA**](#verifica-isa) · [**FAQ**](#faq) · [**Documentazione**](#documentazione) · [**Supporto**](#supporta-il-progetto)

</div>

> [!NOTE]
> **prismOS** trasforma portatili e desktop ricondizionati del periodo 2010-2012 — Intel
> Pentium P6100, Celeron P4500, Core i3/i5/i7 di prima generazione (Arrandale) — in
> postazioni di lavoro, aula o intrattenimento basate sul browser Chromium, con
> interfaccia Ash/Aura in stile macOS e due sottosistemi di compatibilità: **Waydroid** per
> le applicazioni Android e **Wine/Proton** per quelle Windows.

> [!WARNING]
> **Floor ISA vincolante** — ARC, ARC++ e ARCVM sono rimossi integralmente: su CPU prive di
> SSE4.2 il container Android di Google entra in un **loop infinito di riavvio** (`zygote` è
> compilato con `-msse4.2 -mpopcnt` e termina con `SIGILL`). Per lo stesso motivo le
> immagini Waydroid **x86_64 ufficiali non devono mai essere usate**: prismOS installa
> soltanto immagini LineageOS 16.0 **x86 a 32 bit** con floor SSE4.1, marcate dal file
> `ISA_FLOOR` che `prismos-waydroid-prepare` verifica a ogni avvio.

<div align="center">

<h1><a id="funzionalit"></a>Funzionalità</h1>

<table>
  <tr>
    <td width="50%" valign="top">

#### Floor ISA SSE4.1, dichiarato e verificato
- `CFLAGS`/`CXXFLAGS` `-O2 -pipe -march=nehalem -mno-sse4.2 -msse4.1 -mno-popcnt`
- `CPU_FLAGS_X86` con negazioni esplicite di `sse4_2`, `avx`, `aes`, `popcnt`
- Argomenti GN di Chromium (`x64_arch="generic"`), Rust `target-cpu=x86-64`, Go `GOAMD64=v1`
- `scripts/verify_legacy_cpu.sh` scandisce i binari prodotti (byte + `objdump`)

</td>
    <td width="50%" valign="top">

#### ARC rimosso a tre livelli
- USE negativi: `-arc -arc-plus -arcplusplus -arcvm -arc-kernel-features -houdini`
- `use.mask` e `package.use.mask` sul profilo e su `chromeos-chrome`
- Policy `ArcEnabled=false`, `UnaffiliatedArcAllowed=false` e switch `--arc-availability=none`

</td>
  </tr>
  <tr>
    <td width="50%" valign="top">

#### Waydroid (Android 9, x86)
- LineageOS 16.0 x86 a 32 bit, vendor `MAINLINE`, gralloc `minigbm`, binderfs
- Proprietà ART `dalvik.vm.isa.x86.variant=x86` con feature `-sse4_2,-popcnt,-avx,-avx2`
- Marcatore `ISA_FLOOR`: senza di esso il container **non parte**
- Budget di memoria e `dex2oat` tarati per edizione (da 128 MiB/1 thread in Slim)

</td>
    <td width="50%" valign="top">

#### Wine, Proton e Bottles
- Esecuzione di `.exe`/`.msi`/`.dll`/`.scr`/`.cpl`/`.com` dal gestore dei file (MIME + BINFMT_MISC)
- Prefisso `~/WineBottles/Default` (`WINEARCH=win64`), `wineserver` persistente per sessione
- Su Intel HD Gen5 nessun Vulkan: backend `wined3d` con Shader Model 3, mai DXVK
- fsync/esync su `futex_waitv` del kernel 6.1

</td>
  </tr>
  <tr>
    <td width="50%" valign="top">

#### Dock in stile macOS
- Shelf **in basso, centrata, autohide sempre attivo** — vincolata da policy di dispositivo
- Maschera delle icone **squircle** (superellisse n = 5.0), tema vettoriale da 33 SVG
- `ShelfAlignment`, `ShelfAutoHideBehavior`, `PinnedLauncherApps`, `WebAppInstallForceList`
- `prismos-dock apply|verify|show|status` per gestire e verificare l'aspetto

</td>
    <td width="50%" valign="top">

#### Launcher centralizzato (Spotlight)
- `super+space` apre il launcher di Ash in modalità ricerca, senza patch a Chromium
- Daemon evdev con cattura esclusiva e iniezione uinput di `KEY_SEARCH`
- 12 acceleratori dichiarativi in `/usr/share/prismos/accelerators.json`
- `super+ctrl+s` / `super+ctrl+q`: stato e spegnimento immediato dei sottosistemi

</td>
  </tr>
  <tr>
    <td width="50%" valign="top">

#### Quattro edizioni
- **EDU**: cloud-managed (Strada A) o local-policy (Strada B) con URLBlocklist
- **Home**: streaming, Widevine L3, cloud gaming, Proton e Bottles
- **Work**: M365, VPN con kill-switch, vault LUKS dei Download, Crostini
- **Slim**: sotto 2 GB di RAM, sottosistemi installati ma **spenti al boot**, avvio on-demand

</td>
    <td width="50%" valign="top">

#### Kernel e verifica continua
- Splitconfig `chromiumos-x86_64/prismos_legacy` in 7 frammenti (binderfs, BINFMT_MISC, zram/zstd, PSI)
- Scheduler per 2 core, `INTEL_IOMMU=y` con `DEFAULT_ON=n`, ITCO_WDT
- `verify_legacy_cpu.sh` in pipeline: le librerie con dispatch IFUNC sono classificate, non bocciate
- `sync_overlays.sh --check`: 26 verifiche di coerenza prima di ogni build

</td>
  </tr>
</table>

</div>

---

<div align="center">

<h1><a id="floor-isa"></a>Perché SSE4.2 è il problema</h1>

</div>

SSE4.2 introduce sette istruzioni (`PCMPISTRI`, `PCMPISTRM`, `PCMPESTRI`, `PCMPESTRM`,
`PCMPGTQ`, `CRC32`) e, come bit ISA indipendente, `POPCNT`. Una CPU che non le implementa
esegue il binario fino all'istruzione incriminata, genera `#UD` e riceve `SIGILL`: **non
esiste fallback**. Il problema si presenta a quattro livelli e prismOS li presidia tutti:

| Livello | Rischio | Contromisura prismOS |
|---|---|---|
| Toolchain di sistema | `-march=native` o `nehalem` sul build host abilita SSE4.2 **e** POPCNT | `CFLAGS` fissi in `overlay-prismos-common/make.conf` |
| Chromium | GN seleziona `-march=x86-64-v2/v3` | `x64_arch="generic"`, `use_thin_lto=false` |
| Rust e Go | `target-cpu=nehalem` riattiva `+sse4.2,+popcnt` | `target-cpu=x86-64` con `target-feature=+sse4.1,-sse4.2,-popcnt`; `GOAMD64=v1` |
| Runtime Android | ART compila per la variante CPU rilevata | immagini x86 a 32 bit e `dalvik.vm.isa.x86.variant=x86` con feature esplicite |

> [!IMPORTANT]
> `-march=nehalem` è il modello ISA più vicino ad Arrandale che GCC sappia esprimere, ma
> abilita anche SSE4.2 e POPCNT. **`-mno-sse4.2` non disattiva POPCNT**: va negato
> esplicitamente con `-mno-popcnt`. Ometterlo produce un sistema che si avvia e va in
> `SIGILL` dentro Chrome o glibc.

---

<div align="center">

<h1><a id="edizioni"></a>Edizioni</h1>

</div>

| | **EDU** | **Home** | **Work** | **Slim** |
|---|---|---|---|---|
| Destinatario | laboratori e aule | uso domestico | flotta aziendale | macchine sotto 2 GB di RAM |
| RAM minima | 2048 MiB | 3072 MiB | 3072 MiB | 1024 MiB |
| Waydroid al boot | `enabled` | `enabled` | `on-demand` | **`on-demand` (spento)** |
| Wine al boot | `masked` | `enabled` | `enabled` | **`on-demand` (spento)** |
| Policy Chromium | Strada A o B | nessuna | dispositivo (VPN/antianonimato) | nessuna |
| Dock (pin max / predefiniti) | 8 / 6, 48 px | 10 / 8, 56 px, blur | 8 / 8, 48 px, opaca | 6 / 6, 40 px, senza animazioni |
| Peculiarità | profili effimeri, guest disabilitato, blocco social | Widevine L3 (tetto 720p), decodifica via SIMD SSE4.1, cloud gaming | M365 fissato, VPN con kill-switch, vault LUKS | zram zstd, zswap, earlyoom, idle reaper a 120 s |

Il contratto funzionale di **Slim**: Waydroid e Wine sono *installati* (USE attive, MIME
type registrati, voci `.desktop` presenti) ma i demoni sono **completamente spenti
all'avvio**. L'apertura di un `.apk`/`.xapk` oppure di un `.exe`/`.msi` attiva
`/usr/bin/prismos-slim-launcher`, che avvia il sottosistema, attende la readiness, lancia
l'applicazione e — alla chiusura — la termina con `SIGTERM` e poi `SIGKILL`, ripulendo
mount, cgroup e prefissi temporanei. È ammesso un solo sottosistema alla volta.

Confronto esteso, flag USE e rootfs di edizione: [`docs/edizioni.md`](docs/edizioni.md).

---

<div align="center">

<h1><a id="struttura"></a>Struttura della repository</h1>

</div>

```
prismOS/
├── README.md                     questo documento
├── LICENSE                       MIT, con delimitazione dell'ambito rispetto ai terzi
├── assets/prismos-logo.svg       marchio vettoriale
├── docs/
│   ├── architecture.md           stratificazione Portage, pipeline, unita' systemd, runtime
│   ├── edizioni.md               confronto esteso delle quattro edizioni
│   ├── waydroid-integration.md   container Android x86, prop ART, ISA_FLOOR, ciclo di vita
│   ├── wine-integration.md       Wine/Proton/Bottles su Gen5 senza Vulkan, MIME, prefissi
│   └── dock-and-launcher.md      shelf macOS-like, shelf.json, icone squircle, acceleratori
├── kernel/chromeos/config/chromiumos-x86_64/prismos_legacy/
│   ├── base.config  prereq.config  fragment.config
│   ├── legacy-cpu.config  android.config  wine.config  slim.config
├── overlays/
│   ├── overlay-amd64-prismos/    board amd64-prismos + rootfs + tema icone squircle
│   ├── overlay-prismos-common/   CFLAGS/USE, eclass, 6 pacchetti, 10 unita' systemd
│   └── overlay-prismos-{edu,home,work,slim}/   profilo e rootfs di edizione
├── profiles/
│   ├── app_pool.json             25 applicazioni, 4 bundle, requisiti ISA e RAM
│   ├── app_pool.schema.json      schema draft-07 con validazione per tipo
│   └── {edu,home,work,slim}.conf contratto letto da build_iso.sh
└── scripts/
    ├── build_iso.sh              build interattiva e non delle quattro edizioni
    ├── set_edu_policy.sh         Strada A / Strada B
    ├── sync_overlays.sh          --edition --check --list --diff --clean
    ├── verify_legacy_cpu.sh      floor ISA su ELF/PE, rootfs, board, immagine
    ├── generate_app_icons.sh     tema squircle da app_pool.json
    ├── provision_waydroid_image.sh   immagini Android x86 conformi
    └── lib/                      prismos_common.sh, isa_arc_probe.py
```

---

<div align="center">

<h1><a id="requisiti"></a>Requisiti</h1>

**Host di build**

- GNU/Linux x86-64, kernel ≥ 5.10, **almeno 150 GB liberi** e 8 GB di RAM consigliati
- `git`, `curl`, `python3` ≥ 3.8, `tar`, `xz`, `unzip`, `sudo` con accesso a `mount`/`losetup`
- depot_tools e checkout ChromiumOS completo con `cros_sdk` funzionante (branch kernel **6.1**)
- Repository clonata in `~/chromiumos/src/overlays/prismOS` (o linkata con `--repo-mount`)

**Hardware target**

- CPU x86-64 **senza SSE4.2**: Pentium P6100/P6200, Celeron P4500, Core i3-330M, i5-430M, i7-620M
- Intel HD Graphics di prima generazione (Ironlake, Gen5): OpenGL 2.1, **nessun Vulkan**, VA-API parziale
- ≥ 1 GB di RAM per Slim, ≥ 2 GB per EDU, ≥ 3 GB per Home e Work
- Firmware Legacy BIOS oppure UEFI (entrambi i percorsi GRUB sono nell'immagine)

</div>

---

<div align="center">

<h1><a id="build"></a>Build</h1>

<table>
  <tr>
    <th align="center">Build interattiva</th>
    <th align="center">Build non interattiva</th>
  </tr>
  <tr>
    <td align="center">
      <pre><code>cd ~/chromiumos/src/overlays/prismOS
./scripts/build_iso.sh slim \
    --sdk-dir ~/chromiumos/cros_sdk</code></pre>
    </td>
    <td align="center">
      <pre><code># bundle predefinito dell'edizione
./scripts/build_iso.sh home --bundle --jobs 8

# selezione esplicita dal pool
./scripts/build_iso.sh edu --apps 1,3,5-7

# tutte e quattro le edizioni
./scripts/build_iso.sh all --bundle

# sola sincronizzazione degli overlay
./scripts/build_iso.sh work --sync-only</code></pre>
    </td>
  </tr>
</table>

Il menu interattivo elenca le applicazioni del pool con tipo (`Web_App`, `Android_Pkg`,
`Windows_Pkg`) e contrassegno di quelle già previste dal bundle; la selezione accetta
elenchi e intervalli (`1,3,5-7`, `all`, `none`).

Le fasi: generazione di `shelf.json` ed `edition.conf` → sincronizzazione degli overlay nel
`cros_sdk` → `setup_board` → `build_packages` → `build_image
--noenable_rootfs_verification dev` → raccolta in `output/prismOS_<edizione>_legacy.img` →
verifica del floor ISA sui binari critici del sysroot.

**Artefatti prodotti**

| Percorso | Contenuto |
|---|---|
| `output/prismOS_<edizione>_legacy.img` | immagine disco avviabile |
| `output/prismOS_<edizione>_legacy.img.info` | board, kernel, ISA, app selezionate, SHA-256 |
| `output/prismOS_<edizione>_legacy.shelf.json` | configurazione della Dock usata |
| `output/prismOS_<edizione>_legacy.edition.conf` | stato dei sottosistemi incorporato |
| `output/prismOS_<edizione>_legacy.isa-report.{txt,json}` | esito della verifica del floor ISA |
| `build/logs/build-<edizione>-<timestamp>.log` | log completo della build |

Opzioni principali: `--sdk-dir`, `--board`, `--jobs`, `--apps`, `--bundle`,
`--image-type dev|base|test`, `--policy-mode local|cloud|none`, `--copy-overlays`,
`--no-sync`, `--sync-only`, `--skip-verify`, `--keep-build`, `--dry-run`, `--verbose`.
`./scripts/build_iso.sh --help` le elenca tutte.

</div>

---

<div align="center">

<h1><a id="policy-scolastiche-edu"></a>Policy scolastiche (EDU)</h1>

</div>

#### Strada A — Cloud-Managed

Il dispositivo si iscrive alla Google Admin Console dell'istituto. In
`/etc/default/chromium-browser` vengono scritti **solo** switch di Enterprise Enrollment
realmente riconosciuti da Chromium:

```bash
./scripts/set_edu_policy.sh --strada a --domain liceo-fermi.edu \
    --rootfs /build/amd64-prismos
./scripts/set_edu_policy.sh --strada a --domain liceo-fermi.edu \
    --dm-modulus <base64> --dm-modulus-length 2048 --with-domain-policy
```

Nessuna policy JSON locale viene installata: le policy di dispositivo avrebbero precedenza
su quelle cloud.

#### Strada B — Local-Policy

Nessuna infrastruttura Google: la policy viene scritta in
`/etc/chromium/policies/managed/prismos_policy.json` dal template
`overlays/overlay-prismos-edu/chrome_policy.json` (81 chiavi), con **URLBlocklist** su
TikTok, YouTube e Twitch (CDN, shortener e domini correlati), **URLAllowlist** su dominio
scolastico, servizi ministeriali, Workspace for Education, Geogebra, Canva, Wikipedia, Khan
Academy, Scratch e F-Droid, e `UserAllowlist` su `*@<dominio>`.

```bash
./scripts/set_edu_policy.sh --strada b --domain ic-manzi.edu \
    --allowlist "*://web.spaggiari.eu/* *://*.indire.it/*"
./scripts/set_edu_policy.sh --strada b --domain ic-manzi.edu \
    --blocklist "*://*.roblox.com/*" --all-users
./scripts/set_edu_policy.sh --show        # riepilogo installato
./scripts/set_edu_policy.sh --validate    # sintassi, conflitti, chiavi ARC
./scripts/set_edu_policy.sh --remove      # ritorno alla Strada A pura
```

Poiché in Chromium la URLAllowlist ha precedenza sulla URLBlocklist, lo script rimuove
automaticamente ogni voce consentita che ricada in un dominio bloccato e lo registra nel log.

---

<div align="center">

<h1><a id="sottosistemi"></a>Sottosistemi di compatibilità</h1>

<table>
  <tr>
    <th align="center">Waydroid — Android 9 x86</th>
    <th align="center">Wine — applicazioni Windows</th>
  </tr>
  <tr>
    <td>
      <pre><code>sudo ./scripts/provision_waydroid_image.sh \
     --edition slim

sudo ./scripts/provision_waydroid_image.sh \
     --edition edu \
     --archive ~/lineage-16.0-x86.zip \
     --deep-verify

sudo ./scripts/provision_waydroid_image.sh \
     --edition work --build \
     --source-dir ~/lineageos-16.0</code></pre>
    </td>
    <td>
      <pre><code>prismos-wine-run \
    ~/Downloads/npp.Installer.exe \
    --prefix Default -- /S

prismos-wine-run --list-prefixes
wineserver -k

# in Slim e' tutto mediato da:
prismos-slim-launcher start wine
prismos-slim-launcher stop-all
prismos-slim-launcher doctor</code></pre>
    </td>
  </tr>
</table>

Waydroid scarica (con ripresa e SHA-256), estrae `system.img`/`vendor.img` in
`/var/lib/waydroid/images`, installa le proprietà ART del floor ISA, verifica che nessuna
ABI a 64 bit sia esposta e scrive il marcatore `ISA_FLOOR`; con `--deep-verify` monta
l'immagine in sola lettura e la scandisce con `verify_legacy_cpu.sh --rootfs --full`. La
traduzione ARM è disattivata (richiede SSE4.2): il pool seleziona perciò pacchetti F-Droid
con ABI x86 nativa.

Wine rileva a runtime la presenza di un ICD Vulkan: su Gen5 non ne esiste alcuno, quindi il
backend è sempre `wined3d` (OpenGL 2.1 via `crocus`, Shader Model 3, 64 MiB di VRAM
dichiarati, multisampling disattivato). Proton e Bottles restano disponibili nelle edizioni
con RAM sufficiente; EDU maschera Wine, Slim esclude Bottles.

Approfondimenti: [`docs/waydroid-integration.md`](docs/waydroid-integration.md) e
[`docs/wine-integration.md`](docs/wine-integration.md).

</div>

---

<div align="center">

<h1><a id="kernel"></a>Kernel</h1>

</div>

Lo splitconfig `chromiumos-x86_64/prismos_legacy` viene copiato da `build_iso.sh` in
`src/third_party/kernel/v6.1/chromeos/config/chromiumos-x86_64/` ed è selezionato da
`CHROMEOS_KERNEL_SPLITCONFIG` nella board `make.conf`.

| Frammento | Contenuto essenziale |
|---|---|
| `base.config` | elenco ordinato dei frammenti da concatenare |
| `prereq.config` | dipendenze di configurazione (cgroup, namespace, netfilter, crypto) |
| `fragment.config` | DRM_I915 e Gen5 (crocus/i965), HDA, rete, filesystem, SELinux |
| `legacy-cpu.config` | scheduler per 2 core, niente AVX/AES-NI, `INTEL_IOMMU=y` con `DEFAULT_ON=n`, ITCO_WDT |
| `android.config` | `ANDROID_BINDER_IPC`, binderfs, namespace, cgroup v2, DMA-BUF |
| `wine.config` | `BINFMT_MISC`, fsync/esync, THP `madvise`, zswap, gamepad |
| `slim.config` | zram/zstd, PSI, memcg, tracer spenti ma `BPF_SYSCALL=y` (sandbox di Chrome) |

Dettagli e motivazioni: [`kernel/README.md`](kernel/README.md).

---

<div align="center">

<h1><a id="verifica-isa"></a>Verifica ISA</h1>

```bash
./scripts/verify_legacy_cpu.sh --host              # capacita' ISA della macchina corrente
./scripts/verify_legacy_cpu.sh --config            # coerenza della repository
./scripts/verify_legacy_cpu.sh --pe ~/setup.exe    # singolo binario (ELF o PE)
./scripts/verify_legacy_cpu.sh --board amd64-prismos --full
./scripts/verify_legacy_cpu.sh --image output/prismOS_slim_legacy.img \
    --report output/isa.txt --json output/isa.json
```

Il metodo è in due fasi: ricerca delle codifiche byte (veloce, senza disassemblatore) e
conferma con `objdump` sui soli candidati. Le librerie con dispatch IFUNC — glibc, OpenSSL,
zlib, LLVM/Mesa, driver DRI — contengono legittimamente percorsi SSE4.2 selezionati a
runtime e sono classificate `dispatched`: **non** costituiscono fallimento. Sono fatali le
evidenze su `chrome`, Wine, Waydroid e i pacchetti prismOS, compilati con `-march` fisso.

Codici di uscita: `0` conforme · `1` non conforme · `2` errore d'uso.

</div>

---

<div align="center">

<h1><a id="installazione"></a>Installazione su hardware reale</h1>

```bash
# dentro il chroot, con la chiavetta USB collegata
cros flash usb:// ~/chromiumos/src/overlays/prismOS/output/prismOS_slim_legacy.img

# oppure, da un sistema Linux avviato
sudo dd if=prismOS_slim_legacy.img of=/dev/sdX bs=8M status=progress conv=fsync
```

Sul target: disattivare il Verified Boot (le immagini `dev` nascono con
`--noenable_rootfs_verification`; su firmware ChromeOS serve
`make_dev_ssd.sh --remove_rootfs_verification`), completare la OOBE e, per Waydroid,
eseguire una tantum `provision_waydroid_image.sh`. Le immagini includono `dev_install`,
sudo e shell di sviluppo; per una variante senza strumenti di sviluppo usare
`--image-type base`.

</div>

---

<div align="center">

<h1><a id="troubleshooting"></a>Risoluzione dei problemi</h1>

| Sintomo | Causa probabile | Rimedio |
|---|---|---|
| `SIGILL` all'avvio di Chrome | POPCNT abilitato da `-march=nehalem` | aggiungere `-mno-popcnt` in `overlay-prismos-common/make.conf` e ricompilare `chromeos-chrome` |
| Container Waydroid in riavvio continuo | immagini x86_64 o `isa.x86.variant=nehalem` | `provision_waydroid_image.sh --force` con sorgente x86; controllare `ISA_FLOOR` |
| `binder: failed to open` | binderfs non abilitato | verificare `android.config`; `mount -t binder none /dev/binderfs` |
| Schermo nero o rendering software | driver Mesa errato (`iris`/`zink`) | `MESA_LOADER_DRIVER_OVERRIDE=crocus`, `LIBVA_DRIVER_NAME=i965`, `LIBGL_DRI3_DISABLE=1` |
| Video DRM a 480p o 720p | Widevine L3 su piattaforma non certificata | comportamento atteso: il livello L1 non è disponibile |
| Dock non centrata o visibile | policy della Dock assente | `prismos-dock status && prismos-dock verify` |
| `super+space` non apre il launcher | daemon senza accesso a evdev | `systemctl status prismos-accelerator-daemon`, gruppo `input`, `/dev/uinput` |
| Slim: `.exe` non si apre | sottosistema non installato o mascherato | `prismos-slim-launcher doctor`; verificare `WINE_BOOT_STATE` in `/etc/prismos/edition.conf` |
| `setup_board` fallisce | overlay non sincronizzata o `parent` errato | `sync_overlays.sh --check` |
| Build lentissima o OOM sul build host | parallelismo eccessivo | `--jobs 2`; l'edizione Slim attiva `single-thread-link` |

</div>

---

<div align="center">

<h1><a id="faq"></a>FAQ</h1>

### Perché non basta disattivare ARC dalle impostazioni?
Perché il codice è già compilato con SSE4.2: `zygote` muore con `SIGILL` prima che qualsiasi
policy venga letta. ARC va rimosso dai pacchetti, dal profilo e dalle policy, come fa
prismOS a tre livelli indipendenti.

### Posso installare applicazioni Android ARM?
No. La traduzione ARM (houdini, libndk_translation) richiede SSE4.2/POPCNT. Il pool
seleziona pacchetti F-Droid con ABI x86 nativa o pure-Java; le applicazioni ARM-only non
sono installabili e `app_pool.json` lo dichiara con `arm_translation_required: false`.

### I giochi Windows funzionano?
Quelli leggeri sì, tramite `wined3d` su OpenGL 2.1 con Shader Model 3: titoli 2D,
isometrici e i primi 3D degli anni 2000. DXVK e VKD3D-Proton richiedono Vulkan, assente su
Intel HD Gen5. Per i titoli moderni il percorso consigliato è il cloud gaming (GeForce NOW,
Xbox Cloud) via browser.

### Quale edizione scelgo per un netbook con 1 GB di RAM?
**Slim**: Chromium e Ash hanno priorità assoluta, Waydroid e Wine esistono ma non consumano
memoria finché non apri un file compatibile, e zram zstd + earlyoom proteggono la sessione
dall'OOM killer.

### La scuola non ha una Google Admin Console: posso usare EDU?
Sì, con la **Strada B**: la policy di dispositivo viene scritta localmente in
`/etc/chromium/policies/managed/prismos_policy.json`, con blocco di TikTok/YouTube/Twitch e
allowlist del dominio scolastico, senza alcuna infrastruttura Google.

### Lo streaming video in 4K è possibile?
No: su piattaforma non certificata Widevine opera a livello L3 (tetto 720p) e la decodifica
avviene in software con SIMD SSE4.1, perché su Ironlake il percorso VA-API H.264 non è
affidabile. È un limite dell'hardware, non una configurazione correggibile.

</div>

---

<div align="center">

<h1><a id="documentazione"></a>Documentazione</h1>

| Documento | Contenuto |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | stratificazione Portage, pipeline di build, unità systemd, layout a runtime, estensione del progetto |
| [`docs/edizioni.md`](docs/edizioni.md) | confronto esteso delle quattro edizioni: USE, pacchetti, rootfs, Dock, memoria |
| [`docs/waydroid-integration.md`](docs/waydroid-integration.md) | container Android x86, proprietà ART, marcatore `ISA_FLOOR`, ciclo di vita delle unità |
| [`docs/wine-integration.md`](docs/wine-integration.md) | Wine/Proton/Bottles su Gen5 senza Vulkan, MIME type, prefissi, kernel |
| [`docs/dock-and-launcher.md`](docs/dock-and-launcher.md) | shelf macOS-like, `shelf.json`, policy, tema squircle, acceleratori globali |
| [`kernel/README.md`](kernel/README.md) | splitconfig del kernel e motivazione di ogni frammento |
| `./scripts/<nome>.sh --help` | riferimento completo di ogni strumento |

</div>

---

<div align="center">

<h1><a id="supporta-il-progetto"></a>Supporta il progetto</h1>

<h3>prismOS è software libero. Se ti è utile, considera di contribuire!</h3>

#### Metti una stella alla repository ⭐
Se prismOS dà una seconda vita a un macchina che avevi accantonato, una stella su GitHub aiuta il progetto a farsi trovare.

#### Segnala problemi e proponi miglioramenti 🐛
Hardware non coperto, build fallita, policy da aggiungere? [Apri una issue](https://github.com/Davidix07TV/prismOS/issues).

#### Contribuisci con codice e configurazioni 💻
Le pull request sono benvenute: script bash 5 completi (niente segnaposto), flag ISA
espliciti a ogni livello di compilazione e documentazione in italiano tecnico sono i tre
criteri con cui vengono valutate.

</div>

---

<div align="center">

<h1>Crediti e attribuzioni</h1>

<h3>prismOS esiste grazie al lavoro dei progetti seguenti.</h3>

<table>
  <thead>
    <tr>
      <th align="center">Progetto</th>
      <th align="center">Ruolo in prismOS</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="center"><a href="https://www.chromium.org/chromium-os"><strong>ChromiumOS</strong></a></td>
      <td>sistema di base: kernel, Ash/Aura, toolchain di build, politiche di dispositivo</td>
    </tr>
    <tr>
      <td align="center"><a href="https://www.gentoo.org"><strong>Gentoo / Portage</strong></a></td>
      <td>profili, overlay, eclass e risoluzione delle dipendenze</td>
    </tr>
    <tr>
      <td align="center"><a href="https://waydro.id"><strong>Waydroid</strong></a></td>
      <td>container Android su kernel mainline con binderfs</td>
    </tr>
    <tr>
      <td align="center"><a href="https://lineageos.org"><strong>LineageOS</strong></a></td>
      <td>base delle immagini Android 9 x86 ricostruite a floor SSE4.1</td>
    </tr>
    <tr>
      <td align="center"><a href="https://www.winehq.org"><strong>Wine</strong></a> e <a href="https://github.com/ValveSoftware/Proton"><strong>Proton</strong></a></td>
      <td>esecuzione delle applicazioni Windows e dei prefissi gestiti da Bottles</td>
    </tr>
    <tr>
      <td align="center"><a href="https://mesa3d.org"><strong>Mesa</strong></a></td>
      <td>driver `crocus` e `i965` per Intel HD Graphics di prima generazione</td>
    </tr>
    <tr>
      <td align="center"><a href="https://linuxcontainers.org"><strong>LXC</strong></a></td>
      <td>isolamento del container Android con namespace parziali</td>
    </tr>
    <tr>
      <td align="center"><a href="https://f-droid.org"><strong>F-Droid</strong></a></td>
      <td>canale delle applicazioni Android con ABI x86 nativa selezionate nel pool</td>
    </tr>
  </tbody>
</table>

Le icone generate da `scripts/generate_app_icons.sh` sono segnaposto vettoriali originali
(glifo testuale su fondo squircle) e **non** riproducono i loghi ufficiali delle
applicazioni citate. Tutti i marchi appartengono ai rispettivi titolari.

</div>

---

<div align="center">

## Licenza

Il codice e le configurazioni originali di prismOS — script, overlay, profili, unità
systemd, splitconfig del kernel, tema di icone e documentazione — sono rilasciati con
licenza [MIT](LICENSE), che delimita esplicitamente il proprio ambito rispetto ai
componenti di terze parti incorporati da un'immagine (ChromiumOS, Gentoo, kernel Linux,
Waydroid, LineageOS, Wine, Mesa, LXC), ciascuno soggetto alla propria licenza. Widevine è un
modulo DRM di Google distribuito unicamente attraverso i canali previsti da ChromiumOS.

### Disclaimer
Questo progetto non è affiliato a Google, ChromiumOS, Intel, Microsoft o ai titolari dei
marchi citati. L'uso su hardware specifico è a rischio dell'utilizzatore: verificare sempre
il floor ISA con `verify_legacy_cpu.sh` prima della messa in produzione.

---

**Repository**: https://github.com/Davidix07TV/prismOS

**Ultimo aggiornamento**: settembre 2026

</div>
