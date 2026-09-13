# Le quattro edizioni di prismOS

Confronto esteso di **EDU**, **Home**, **Work** e **Slim**: parametri hardware, flag USE,
pacchetti, stato dei sottosistemi, aspetto della Dock, policy di Chromium e contenuto della
rootfs di edizione.

Per la visione d'insieme vedere [`architecture.md`](architecture.md); per i sottosistemi
[`waydroid-integration.md`](waydroid-integration.md) e
[`wine-integration.md`](wine-integration.md).

---

## 1. Dove vive la configurazione di un'edizione

Ogni edizione è descritta da tre insiemi di file, con responsabilità distinte e senza
duplicazioni:

| File | Letto da | Contenuto |
|---|---|---|
| `profiles/<edizione>.conf` | `scripts/build_iso.sh` | identità, requisiti hardware, stato dei sottosistemi, parametri della Dock, politica, frammenti di kernel, pacchetti aggiuntivi/rimossi |
| `overlays/overlay-prismos-<edizione>/make.conf` | Portage | variabili informative `PRISMOS_*`, USE di edizione, `PRISMOS_POLICY_SOURCE`, `PRISMOS_ROOTFS_FILES`, `PRISMOS_EXTRA_PACKAGES` |
| `overlays/overlay-prismos-<edizione>/profiles/base/make.defaults` | Portage (profilo) | USE risolte nel profilo, `PROFILE_ONLY_VARIABLES`, `SYSTEM_PACKAGES`, `PRISMOS_SUBSYSTEM` |
| `overlays/overlay-prismos-<edizione>/files/` | `build_iso.sh` → rootfs | albero `/etc` copiato nell'immagine: `edition.conf` di dettaglio, tuning, policy, switch di Chromium |

`profiles/<edizione>.conf` è la fonte di `build/<edizione>-<stamp>/etc/prismos/edition.conf`,
che è il contratto letto a runtime da `prismos-firstboot`, `prismos-dock-apply` e
`prismos-slim-launcher`.

## 2. Matrice riassuntiva

| Parametro | EDU | Home | Work | Slim |
|---|---|---|---|---|
| `PROFILE_ID` | `edu` | `home` | `work` | `slim` |
| Destinatario | laboratori, aule, esami | uso domestico, streaming | flotta aziendale, smart working | ricondizionati sotto 2 GB |
| `MIN_RAM_MB` | 2048 | 3072 | 3072 | 1024 |
| `CRITICAL_RAM_MB` | 1536 | 2048 | 2048 | 768 |
| Waydroid al boot | `enabled` | `enabled` | `on-demand` | `on-demand` |
| Wine al boot | `masked` | `enabled` | `enabled` | `on-demand` |
| `SUBSYSTEM_IDLE_TIMEOUT` (s) | 600 | 1800 | 900 | 120 |
| `SUBSYSTEM_MAX_INSTANCES` | 1 | 2 | 1 | 1 |
| Policy Chromium | Strada A o Strada B | nessuna | policy di dispositivo | nessuna |
| Crostini (Linux) | disattivato | disattivato | **attivato** | disattivato |
| Bottles/Proton | disattivati | **attivati** | **attivati** | Proton sì, Bottles no |
| PipeWire/PulseAudio | attivati | **attivati** | attivati | disattivati (ALSA diretto) |
| VA-API | attivata | attivata | attivata | disattivata |
| CUPS/stampa | attivata | attivata | attivata | disattivata |
| zram/zswap/earlyoom | zswap | zswap | zswap | **zram zstd + zswap + earlyoom** |
| `single-thread-link` | no | no | no | **sì** (2 core) |
| Frammenti kernel | `legacy-cpu`, `android` | `legacy-cpu`, `android`, `wine` | `legacy-cpu`, `android`, `wine` | `legacy-cpu`, `android`, `wine`, **`slim`** |
| Pin massimi sulla Dock | 8 | 10 | 8 | 6 |
| `SHELF_ICON_SIZE` | 48 | 56 | 48 | 40 |
| Animazioni/blur Dock | sì | sì | sì | **no** |
| `SHELF_BACKGROUND_OPACITY` | 0.86 | 0.86 | 0.86 | 1.00 |

## 3. EDU — Cloud-Managed e Local-Policy

**Obiettivo.** Una flotta scolastica gestibile senza infrastruttura dedicata e resistente
all'uso improprio: profili effimeri, niente guest, niente social, niente gaming.

### 3.1 Flag USE

```
prismos_edition_edu cloud-enrollment local-policy device-restrict school-lab kiosk-exam
waydroid wine -proton -bottles -crostini -virtio-gpu -developer-tools
-arc -arc-plus -arcplusplus -arcvm
```

* `cloud-enrollment` porta con sé `chromeos-base/prismos-edu-enrollment`, che installa lo
  script di Strada A e i file in `/etc/default/chromium-browser`;
* `local-policy` porta `app-admin/chromeos-policy-tool` e la gestione di
  `prismos_policy.json`;
* `kiosk-exam` attiva la modalità d'esame (schermo intero, navigazione limitata al dominio
  consentito);
* Wine è presente come USE comune ma lo stato al boot è `masked`: nei laboratori non serve e
  occupa prefissi su disco.

### 3.2 Policy

Due strade alternative, mai entrambe:

* **Strada A — Cloud-Managed.** Solo switch di Enterprise Enrollment in
  `/etc/default/chromium-browser`:
  `--enterprise-enable-zero-touch-enrollment`, eventualmente
  `--enterprise-enrollment-initial-modulus`/`-initial-modulus-length` per un server DM
  proprio, e `--arc-availability=none`. Nessuna policy JSON locale, che avrebbe precedenza
  su quella cloud.
* **Strada B — Local-Policy.**
  `/etc/chromium/policies/managed/prismos_policy.json` derivato dal template
  `overlays/overlay-prismos-edu/chrome_policy.json` (81 chiavi): URLBlocklist su TikTok,
  YouTube, Twitch, social, gaming, proxy anonimi e contenuti per adulti; URLAllowlist su
  dominio scolastico, servizi ministeriali, Workspace for Education, Geogebra, Canva,
  Wikipedia, Khan Academy, Scratch, F-Droid; `UserAllowlist` su `*@<dominio>`; guest,
  incognito e developer tools disabilitati; ARC e VM vietati.

Lo strumento di gestione è `scripts/set_edu_policy.sh` (sezione
[School policy (EDU)](../README.md#edu-policy) del README).

### 3.3 Rootfs di edizione

```
etc/default/chromium-browser     switch di enrollment e ARC off
etc/prismos/edu.conf             parametri d'aula (dominio, sessione effimera, blocco app)
```

### 3.4 Applicazioni tipiche

Google Classroom, Drive, Meet, Canva, GeoGebra, VS Code Web, AnkiDroid (Android), VLC for
Android, F-Droid, OsmAnd.

## 4. Home — intrattenimento e gaming leggero

**Obiettivo.** Sfruttare al massimo una GPU Gen5 e 3 GB di RAM per video, musica, cloud
gaming e qualche titolo locale, senza compromettere la stabilità.

### 4.1 Flag USE

```
prismos_edition_home media-stack cloud-gaming android-gaming windows-gaming drm-l3
waydroid wine proton bottles gstreamer pipewire pulseaudio vaapi widevine h264 aac mp3
proprietary-codecs -crostini -device-restrict -kiosk-exam
-arc -arc-plus -arcplusplus -arcvm
```

### 4.2 Multimedia su Intel HD Gen5

| Aspetto | Scelta | Motivo |
|---|---|---|
| Codec | `h264 aac mp3 proprietary-codecs widevine` | streaming commerciale |
| Widevine | livello L3, tetto 720p | la piattaforma non è certificata: L1 non è disponibile |
| VA-API | `LIBVA_DRIVER_NAME=i965`, `--disable-features=VaapiVideoDecoder` | su Ironlake il percorso H.264 non è affidabile; la decodifica avviene in software con SIMD SSE4.1 (dav1d/ffmpeg), che è il comportamento atteso |
| Compositing | `--use-gl=angle --use-angle=gl`, raster GPU disattivata | OpenGL 2.1, nessun Vulkan |
| Audio | PipeWire + PulseAudio | gestione dei device Bluetooth/HDMI |

### 4.3 Gaming

* **Cloud gaming** (GeForce NOW, Xbox Cloud, Amazon Luna) via browser: nessuna istanza
  locale, nessun vincolo ISA;
* **Proton/Bottles** per titoli Windows leggeri: `wined3d` su Shader Model 3, niente DXVK
  (mancando Vulkan), `wined3d_VideoMemorySize=64`, `wined3d_Multisampling=disabled`;
* **Android** via Waydroid: `android-gaming` abilita il supporto gamepad nel kernel
  (`wine.config`) e la risoluzione 1366×768 del container;
* `SUBSYSTEM_MAX_INSTANCES=2` consente container Android e prefisso Wine simultanei, con
  `SUBSYSTEM_IDLE_TIMEOUT=1800` per non interrompere sessioni lunghe.

### 4.4 Rootfs di edizione

```
etc/prismos/home-tuning.conf     cache multimediale, prefetch, soglie di qualità video
```

### 4.5 Applicazioni tipiche

YouTube, Netflix, Spotify, WhatsApp Web, GeForce NOW, NewPipe, VLC, OsmAnd, 7-Zip.

## 5. Work — produttività aziendale e lavoro remoto

**Obiettivo.** Microsoft 365, VPN sempre verificabile, documenti cifrati, audit, e la
possibilità di usare container Linux (Crostini) per lo sviluppo.

### 5.1 Flag USE

```
prismos_edition_work m365-suite vpn-advanced encrypted-dl kerberos tpm2-seal audit-logging
waydroid wine proton bottles crostini virtio-gpu
-device-restrict -kiosk-exam -school-lab -cloud-gaming
-arc -arc-plus -arcplusplus -arcvm
```

### 5.2 Pacchetti e configurazioni

| Ambito | Componenti |
|---|---|
| VPN | `net-vpn/openvpn`, `net-vpn/strongswan` con kill-switch: `IPTablesLockdown` e rotta di default via tunnel, verificata da `prismos_policy.json` |
| Cifratura | `sys-fs/cryptsetup` per il vault LUKS dei Download, `app-crypt/tpm2-tools` per il sealing TPM 2.0, `app-crypt/gnupg` |
| Identità | `kerberos` per l'SSO di dominio, `audit-logging` per il journal persistente |
| Container Linux | `crostini` + `virtio-gpu`: unica edizione in cui le VM sono consentite dalla policy |
| Windows | Wine `enabled` al boot, prefisso `Default`, applicazioni `win32` (Notepad++, PuTTY, 7-Zip, VS Code) |

### 5.3 Policy di dispositivo

`overlays/overlay-prismos-work/files/etc/chromium/policies/managed/prismos_policy.json`:

* `ArcEnabled=false`, `VirtualMachinesAllowed=true` (solo Crostini, con
  `DeviceUnaffiliatedCrostiniAllowed=false`);
* `ProxyMode`/`ProxySettings` allineati al tunnel VPN, `IncognitoModeAvailability=1`,
  `DeveloperToolsAvailability` limitato;
* `UserDataDir` non removibile, `DownloadRestrictions` sul vault cifrato;
* `SSLErrorOverrideAllowed=false`, `SafeBrowsingProtectionLevel=2`.

### 5.4 Rootfs di edizione

```
etc/chromium/policies/managed/prismos_policy.json    policy di dispositivo
etc/default/chromium-browser                         switch: ARC off, audit, profilo
etc/prismos/work.conf                                parametri VPN, vault, M365
```

### 5.5 Applicazioni tipiche

Microsoft 365, Outlook, Zoom, Slack, VS Code Web, PuTTY, Notepad++, K-9 Mail, OsmAnd.

## 6. Slim — sottosistemi su richiesta sotto 2 GB

**Obiettivo.** Rendere utilizzabile una macchina con 1024-2048 MB di RAM: Chromium e Ash
hanno priorità assoluta, Waydroid e Wine esistono ma non consumano un byte finché l'utente
non apre un file compatibile.

### 6.1 Flag USE

```
prismos_edition_slim slim-ondemand low-ram no-extras single-thread-link
waydroid wine proton zram zswap earlyoom
-bottles -crostini -virtio-gpu -cloud-gaming -media-stack
-pipewire -pulseaudio -cups -bluetooth-printers -gstreamer -vaapi
-kiosk-exam -school-lab -m365-suite -vpn-advanced -encrypted-dl
-arc -arc-plus -arcplusplus -arcvm
```

`single-thread-link` evita che il linker di Chromium saturi entrambi i core logici;
`low-ram` riduce le cache; `no-extras` esclude pacchetti non essenziali.

### 6.2 Memoria

| Strumento | Configurazione | Effetto |
|---|---|---|
| zram | `/etc/zram-generator.conf`, zstd, 50% della RAM | swap compressa a costo CPU minimo su 2 core |
| zswap | pool zbud/zsmalloc | compressione del writeback prima del disco |
| earlyoom | `/etc/default/earlyoom`: 8% di memoria libera, 3% di swap | kill preventivo per proteggere la sessione Ash dall'OOM killer del kernel |
| sysctl | `99-prismos-legacy.sysctl` | swappiness, dirty_ratio, THP `madvise`, watchdog ridotto |
| Drop caches | `SLIM_DROP_CACHES_ON_START=1` | libera la page cache prima di avviare un sottosistema |
| Soglie launcher | `SLIM_LAUNCH_MIN_FREE_MB=256` | sotto questa soglia l'avvio on-demand è rifiutato con spiegazione |

### 6.3 Contratto on-demand

1. All'avvio `prismos-firstboot` legge `WAYDROID_BOOT_STATE=on-demand` e
   `WINE_BOOT_STATE=on-demand`: esegue `systemctl unmask` + `systemctl disable` sulle unità,
   disabilita `prismos-subsystems.target` e maschera `prismos-subsystem-idle.timer`
   (sostituito dal teardown immediato);
2. i MIME type `application/vnd.android.package-archive`, `application/x-msi`,
   `application/x-msdownload`, `application/x-msdos-program` e le estensioni `.apk`,
   `.xapk`, `.exe`, `.msi`, `.dll`, `.scr`, `.cpl`, `.com` sono associati a
   `prismos-slim-launcher`;
3. all'apertura di un file il launcher verifica la RAM libera, esegue
   `systemctl start` sull'unità del sottosistema richiesto, attende la readiness, lancia
   l'applicazione e ne segue il PID;
4. alla chiusura invia `SIGTERM`, attende `SUBSYSTEM_TEARDOWN_GRACE_SEC=3` s, invia
   `SIGKILL`, arresta l'unità, smonta i mount residui e ripulisce cgroup e prefissi
   temporanei. È ammesso **un solo sottosistema alla volta**
   (`SUBSYSTEM_MAX_INSTANCES=1`).

Comandi utili: `prismos-slim-launcher status`, `... start waydroid|wine`,
`... stop-all`, `... doctor` (diagnostica completa), `... watch` (seguire il ciclo di vita).

### 6.4 Drop-in systemd

Con `USE=slim-ondemand` l'ebuild installa tre drop-in in
`/etc/systemd/system/<unità>.service.d/10-slim-ondemand.conf`:

* `prismos-waydroid-container.service`: `DefaultDependencies=no`, `RemainAfterExit=no`,
  `TimeoutStartSec=90`, `TimeoutStopSec=8`, `KillMode=mixed`, `FinalKillSignal=SIGKILL`,
  `OOMPolicy=kill`, `MemoryHigh=768M`, `MemoryMax=1024M`, `MemorySwapMax=256M`,
  `CPUWeight=90`, `TasksMax=512`;
* `prismos-waydroid-session@.service` e `prismos-wine-session@.service`: stessi principi,
  con `StopWhenUnneeded=yes` e limiti di memoria proporzionati.

Un drop-in non può rimuovere la sezione `[Install]` dell'unità base: per questo il
meccanismo di Slim agisce su `enable`/`disable`/`mask` e non sulle dipendenze dichiarative.

### 6.5 Rootfs di edizione

```
etc/prismos/slim-tuning.conf        soglie e priorità
etc/prismos/slim-launcher.conf      comportamento del launcher on-demand
etc/zram-generator.conf             device zram zstd
etc/default/earlyoom                soglie di kill preventivo
```

### 6.6 Applicazioni tipiche

Sei pin: Drive, YouTube, WhatsApp Web, Microsoft 365, F-Droid, K-9 Mail. Il bundle completo
resta selezionabile in build con `--apps`.

## 7. Costruire e verificare un'edizione

```bash
./scripts/build_iso.sh edu  --bundle                 # EDU con bundle predefinito
./scripts/build_iso.sh home --apps 1,3,5-7 --jobs 4
./scripts/build_iso.sh work --sync-only              # solo sincronia degli overlay
./scripts/build_iso.sh slim --bundle --image-type base
./scripts/build_iso.sh all  --bundle                 # tutte e quattro, in sequenza

./scripts/sync_overlays.sh --check --edition work    # coerenza degli overlay
./scripts/set_edu_policy.sh --strada b --domain ic-manzi.edu --rootfs /build/amd64-prismos
./scripts/verify_legacy_cpu.sh --board amd64-prismos --full
```

L'esito di ogni build è descritto da `output/prismOS_<edizione>_legacy.img.info`, che
riporta board, versione del kernel, splitconfig, floor ISA, stato dei sottosistemi,
applicazioni selezionate e SHA-256 dell'immagine.
