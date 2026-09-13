# Integrazione Wine, Proton e Bottles in prismOS

Esecuzione di applicazioni Windows (`.exe`, `.msi`, `.dll`, `.scr`, `.cpl`, `.com`) dal
gestore dei file di ChromeOS su hardware legacy: CPU senza SSE4.2 e Intel HD Graphics di
prima generazione (Ironlake, Gen5).

Documentazione di riferimento per l'unità `prismos-wine-session@.service` e per i programmi
`prismos-wine-prepare` e `prismos-wine-run`.

---

## 1. Vincoli dell'hardware e conseguenze

| Vincolo | Conseguenza |
|---|---|
| CPU senza SSE4.2/POPCNT/AVX | Wine deve essere compilato con `-march=nehalem -mno-sse4.2 -mno-popcnt`: il pacchetto `wine-staging` eredita i `CFLAGS` di `overlay-prismos-common/make.conf` |
| Gen5: OpenGL 2.1, **nessun Vulkan** | DXVK e VKD3D-Proton sono inutilizzabili; il backend è `wined3d` con GLSL e Shader Model 3 |
| Gen5: driver Mesa `crocus` (non `iris`, non `zink`) | `MESA_LOADER_DRIVER_OVERRIDE=crocus`, `LIBGL_DRI3_DISABLE=1` (DRI3 incompleto su Gen5) |
| 2 core logici, 1-3 GB di RAM | `wineserver` persistente per sessione, limiti di memoria sulle unità, prefix su disco invece che in RAM |
| Nessun AES-NI | le cifrature TLS di Wine usano i percorsi software di OpenSSL/GnuTLS: attese latenze maggiori nell'handshake |

`prismos-wine-prepare` e `prismos-wine-run` **rilevano** questi vincoli a runtime
(`detect_vulkan`, `detect_legacy_intel_gpu`) invece di assumerli: su una macchina con Vulkan
disponibile il backend DXVK resta selezionabile.

## 2. Componenti installati

| Componente | Percorso | Ruolo |
|---|---|---|
| `prismos-wine-run` | `/usr/bin/prismos-wine-run` | punto d'ingresso utente: prepara l'ambiente, inizializza il prefix se necessario, esegue il PE |
| `prismos-wine-prepare` | `/usr/libexec/prismos/prismos-wine-prepare` | `ExecStartPre` della sessione: prefix, socket Wayland, backend grafico, ambiente per UID |
| `99prismos-wine` | `/etc/env.d/99prismos-wine` | ambiente predefinito per tutti gli utenti di sessione |
| `prismos-x-msi.xml` | `/usr/share/mime/packages/prismos-x-msi.xml` | tipi MIME `application/x-msi`, `application/x-ms-dos-executable`, `application/vnd.android.package-archive` |
| `prismos-wine-runner.desktop` | `/usr/share/applications/` | voce «Esegui con Wine» del gestore dei file |
| `prismos-android-runner.desktop` | `/usr/share/applications/` | voce «Esegui con Waydroid» |
| `prismos-slim-mimeapps.list` | `/etc/xdg/` (Slim) | associa le estensioni Windows e Android a `prismos-slim-launcher` |
| `prismos-wine-session@.service` | unità template per UID | `wineserver` persistente, `StopWhenUnneeded`, limiti di memoria |

USE attivate in `overlay-prismos-common/profiles/base/make.defaults`:

```
wine proton bottles wow64 mingw run-exes win32codecs d3d9 d3d11 fsync esync
opengl gstreamer openal sdl truetype fontconfig cups udisks v4l
```

`run-exes` è la USE che rende i file `.exe` direttamente eseguibili (registrazione
BINFMT_MISC); le edizioni riducono l'insieme (EDU maschera Wine, Slim esclude Bottles,
Home e Work includono Proton e Bottles).

## 3. Ambiente

`/etc/env.d/99prismos-wine`:

```
WINEPREFIX="/home/chronos/user/WineBottles/Default"
WINEARCH="win64"
WINEDEBUG="-all"
WINEDLLOVERRIDES="mscoree=d;mshtml=d"
WINEESYNC="1"
WINEFSYNC="1"
PROTON_USE_WINED3D="1"
PRISMOS_WINE_PREFIX_ROOT="/home/chronos/user/WineBottles"
PRISMOS_WINE_PREFIX="Default"
LDPATH="/usr/lib64/wine:/usr/lib/wine"
```

* `mscoree=d;mshtml=d` disattiva Mono e Gecko: non vengono scaricati al primo avvio (nessun
  prompt di rete, nessuna dipendenza da .NET Framework);
* `WINEFSYNC`/`WINEESYNC` usano `futex_waitv` del kernel 6.1 per ridurre la latenza di
  sincronizzazione dei thread Windows — beneficio misurabile su 2 core;
* `PROTON_USE_WINED3D=1` impone a Proton il percorso OpenGL;
* i valori vengono sovrascritti per UID da `/run/prismos/wine-<uid>.env`, scritto da
  `prismos-wine-prepare`, che conosce il socket Wayland reale e la disponibilità di Vulkan.

## 4. Ciclo di vita di una sessione

### 4.1 `prismos-wine-prepare <uid>`

1. normalizza l'UID (default 1000, utente `chronos`);
2. `detect_wayland_socket` — individua il socket di Exo (`wayland-0`/`wayland-exo`) nel
   `XDG_RUNTIME_DIR` dell'utente;
3. `detect_vulkan` — verifica la presenza di un ICD Vulkan funzionante; su Gen5 l'esito è
   negativo e il backend diventa `wined3d`;
4. `ensure_prefix` — crea il prefix con `wineboot -u` se mancante (`WINEARCH=win64`, che su
   ospite x86-64 ospita sia applicazioni a 32 sia a 64 bit), altrimenti lo riusa;
5. `write_env` — scrive `/run/prismos/wine-<uid>.env` con `WINEPREFIX`, `WAYLAND_DISPLAY`,
   le variabili `wined3d_*` e i percorsi delle librerie;
6. `prewarm` — precarica i moduli Wine nella page cache per ridurre la latenza del primo
   avvio;
7. `verify_isa` — conferma che la CPU non abbia SSE4.2 e registra la scelta del backend.

### 4.2 `prismos-wine-session@<uid>.service`

```
After=systemd-user-sessions.target ui.target
StopWhenUnneeded=yes            ConditionUser=!root
EnvironmentFile=-/run/prismos/wine-%i.env
ExecStartPre=/usr/libexec/prismos/prismos-wine-prepare %i
ExecStart=/usr/bin/wineserver -f
ExecStop=/usr/bin/wineserver -k
```

Il `wineserver` in foreground mantiene vivi i processi Windows fra un lancio e l'altro;
`StopWhenUnneeded=yes` fa sì che l'unità si arresti quando nessuna applicazione la usa più,
restituendo la memoria — comportamento essenziale in Slim, dove l'unità è avviata da
`prismos-slim-launcher` e terminata alla chiusura dell'applicazione.

### 4.3 `prismos-wine-run`

Sequenza (`parse_args` → `detect_vulkan` → `detect_legacy_intel_gpu` → `build_env` →
`wine_binary` → `init_prefix` → `to_wine_path` → `run_target`):

1. sceglie il binario Wine corretto (`wine` o `wine64`) in base all'architettura
   dell'eseguibile, ispezionando l'intestazione PE;
2. compone l'ambiente: `wined3d_VideoMemorySize=64`, `wined3d_MaxShaderModelPS=3`,
   `wined3d_MaxShaderModelVS=3`, `wined3d_Multisampling=disabled`,
   `wined3d_OffscreenRenderingMode=fbo`, `MESA_LOADER_DRIVER_OVERRIDE=crocus`,
   `LIBGL_DRI3_DISABLE=1`;
3. inizializza il prefix richiesto (`--prefix NOME`) se non esiste;
4. converte il percorso POSIX in percorso Windows (`C:\...`);
5. in Slim delega a `prismos-slim-launcher` (`maybe_delegate_slim`) perché il ciclo
   avvio/teardown sia gestito dal launcher on-demand.

Uso:

```bash
prismos-wine-run ~/Downloads/npp.Installer.exe --prefix Default -- /S
prismos-wine-run "C:/Program Files/Notepad++/notepad++.exe" --verbose
prismos-wine-run --list-prefixes
```

## 5. Apertura dal gestore dei file

Il tipo MIME `application/x-ms-dos-executable` (estensioni `.exe`, `.dll`, `.scr`, `.cpl`,
`.com`) e `application/x-msi` (`.msi`, `.msp`, `.msm`) sono associati a
`prismos-wine-runner.desktop`, che invoca `prismos-wine-run` con il file selezionato. Con
`USE=run-exes` e `CONFIG_BINFMT_MISC=y` il kernel può anche eseguire direttamente i PE:
prismOS preferisce comunque il passaggio esplicito dal runner, perché è l'unico punto in cui
l'ambiente grafico corretto (crocus, DRI2, wined3d) viene garantito.

Le voci di `profiles/app_pool.json` di tipo `Windows_Pkg` dichiarano tutto il necessario per
un'installazione non presidiata:

| Campo | Esempio (Notepad++) |
|---|---|
| `wine_prefix` | `Default` |
| `wine_arch` | `win32` |
| `installer_args` | `["/S"]` |
| `post_install_binary` | `C:/Program Files/Notepad++/notepad++.exe` |
| `wine_dependencies` | `["vcrun2019"]` |
| `mime_types` | `text/plain`, `application/xml`, `application/json` |
| `launch_url` | `wine://C:/Program Files/Notepad++/notepad++.exe` |

Le quattro voci Windows del pool sono Notepad++, PuTTY, 7-Zip Console e Visual Studio Code
(edizioni Work e Slim secondo `flavors`).

## 6. Proton e Bottles

* **Proton** è disponibile nelle edizioni Home e Work. Con `PROTON_USE_WINED3D=1` i titoli
  Direct3D 9/10/11 passano da `wined3d`; DXVK viene usato solo se `detect_vulkan` trova un
  ICD funzionante. Su Gen5 le prestazioni sono quelle di un rasterizzatore OpenGL 2.1 con
  Shader Model 3: sono giocabili titoli 2D, isometrici e i primi 3D degli anni 2000.
* **Bottles** è il gestore grafico dei prefissi (Home e Work). Ogni «bottiglia» corrisponde
  a un prefisso sotto `PRISMOS_WINE_PREFIX_ROOT`; Slim esclude Bottles per ridurre
  l'ingombro, restando però compatibile con i prefissi creati manualmente.
* **Gamepad**: `CONFIG_JOYSTICK_XPAD`, `HIDRAW`, `UHID`, `INPUT_FF_MEMLESS` nel frammento
  `wine.config` abilitano il supporto XInput per i controller Xbox via Wine.

## 7. Requisiti del kernel

Frammento `kernel/chromeos/config/chromiumos-x86_64/prismos_legacy/wine.config`:

```
CONFIG_BINFMT_MISC=y            esecuzione diretta dei PE
CONFIG_FUTEX=y / FUTEX_PI=y     fsync/esync (futex_waitv in 6.1)
CONFIG_RT_MUTEXES=y / RT_GROUP_SCHED=y / PREEMPT_NOTIFIERS=y
CONFIG_TRANSPARENT_HUGEPAGE=y / ..._MADVISE=y   prefissi di grandi dimensioni
CONFIG_ZSWAP=y / ZSWAP_DEFAULT_ON=y / ZSWAP_COMPRESSOR_DEFAULT_ZSTD=y
CONFIG_IO_URING=y / AIO=y       I/O asincrono dei giochi moderni
CONFIG_JOYSTICK_XPAD=y / HIDRAW=y / UHID=y / INPUT_FF_MEMLESS=y
CONFIG_PPTP=y / PPPOE=y / NET_IPGRE_DEMUX=y     VPN legacy aziendali
```

## 8. Diagnosi

| Sintomo | Causa | Rimedio |
|---|---|---|
| `SIGILL` all'avvio di `wine` o di un `.exe` | Wine compilato con SSE4.2/POPCNT | verificare `CFLAGS` in `overlay-prismos-common/make.conf` e ricompilare; `verify_legacy_cpu.sh --pe /usr/bin/wine` |
| Schermo nero o finestra vuota | DXVK selezionato senza Vulkan | `PROTON_USE_WINED3D=1`; controllare `detect_vulkan` in `prismos-wine-run --verbose` |
| Rendering lentissimo, `GLX_ARB` mancante | driver Mesa `iris` o `zink` caricato | `MESA_LOADER_DRIVER_OVERRIDE=crocus`, `LIBGL_DRI3_DISABLE=1` |
| Prompt di download Mono/Gecko al primo avvio | `WINEDLLOVERRIDES` non applicato | verificare `/etc/env.d/99prismos-wine` e rieseguire `env-update` |
| Audio assente in Slim | `USE=-pulseaudio -pipewire` | comportamento atteso: ALSA diretto; `aplay -l` per verificare il device |
| `.msi` si apre con l'editor di testo | tipo MIME non registrato | `update-mime-database /usr/share/mime`; verificare `prismos-x-msi.xml` |
| L'applicazione resta in esecuzione dopo la chiusura | `wineserver` persistente | `wineserver -k` oppure `prismos-slim-launcher stop-all`; in Slim è automatico |
| Prefisso corrotto dopo un OOM | kill durante la scrittura | `prismos-wine-run --reset-prefix Default` |

Log utili: `journalctl -t prismos-wine`, `WINEDEBUG=+loaddll,+seh prismos-wine-run ...
--verbose`, `/var/log/prismos/`.
