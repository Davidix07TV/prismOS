# Integrazione Waydroid in prismOS

Sostituzione integrale di ARC/ARC++/ARCVM con un container Android basato su **Waydroid** e
immagini **LineageOS 16.0 (Android 9) x86 a 32 bit**, ricostruite con floor ISA SSE4.1.

Documentazione di riferimento per le unità `prismos-waydroid-container.service` e
`prismos-waydroid-session@.service`.

---

## 1. Perché ARC non è utilizzabile su CPU senza SSE4.2

ARC compila `zygote`, la libreria ART e i servizi di sistema con
`-msse4.2 -mpopcnt`. Su Intel Pentium P6100, Celeron P4500 o Core di prima generazione
(Arrandale) la prima istruzione `PCMPISTRI` o `CRC32` genera `#UD`, il kernel consegna
`SIGILL` e `zygote` muore. Poiché `zygote` è il processo padre di ogni applicazione Android,
il framework riavvia il container all'infinito: il ciclo osservato è
`arc-start → zygote crash → restart → arc-stop`, con saturazione della CPU e log pieni di
`Fatal signal 4 (SIGILL)`.

Non esiste alcuna contromisura a livello di policy o di configurazione di ARC: il problema è
nel codice già compilato. L'unica soluzione è un container Android compilato per un ISA
inferiore — cioè Waydroid con immagini x86 a floor SSE4.1 — più la rimozione completa di ARC
dal sistema (USE negativi, `use.mask`, policy, `--arc-availability=none`).

## 2. Scelta delle immagini

| Parametro | Valore | Motivazione |
|---|---|---|
| Distribuzione | LineageOS 16.0 (Android 9, API 28) | ultima release per cui esistono immagini Waydroid **x86 a 32 bit**; le release più recenti sono pubblicate solo x86_64 |
| Architettura | **x86 (32 bit)** | le immagini x86_64 ufficiali sono compilate con SSE4.2 e POPCNT |
| `vendor_type` | `MAINLINE` | il kernel ospite (6.1) fornisce binderfs e ashmem: non serve il secondo kernel Halium |
| `gralloc` | `minigbm` | allocazione buffer compatibile con il compositore Exo di ChromeOS |
| Variante | `VANILLA` | niente GApps: su una flotta scolastica i servizi Google vanno distribuiti come applicazioni web, non come framework Android |
| Traduzione ARM | **disattivata** | libhoudini e libndk_translation richiedono SSE4.2/POPCNT |
| ABI esposte | `x86,armeabi-v7a,armeabi` | `abilist64` vuota: nessuna applicazione a 64 bit può essere installata |

Conseguenza pratica: sono installabili solo le applicazioni Android distribuite con librerie
native x86 oppure pure-Java/Kotlin. Per questo `profiles/app_pool.json` seleziona pacchetti
F-Droid (F-Droid, VLC, NewPipe, AnkiDroid, OsmAnd, K-9 Mail) e dichiara per ciascuno
`arm_translation_required: false` e l'elenco `abi` realmente disponibile.

## 3. Provisioning

`scripts/provision_waydroid_image.sh` è lo strumento unico per ottenere immagini conformi.

```bash
# mirror prismOS (raccomandato: immagini 16.0 x86 ricostruite a floor SSE4.1)
sudo ./scripts/provision_waydroid_image.sh --edition slim

# SourceForge upstream (richiede --date o --query-latest; usare sempre --deep-verify)
./scripts/provision_waydroid_image.sh --edition home --source upstream --query-latest --deep-verify

# archivio già scaricato
sudo ./scripts/provision_waydroid_image.sh --edition work \
     --source local --archive ~/lineage-16.0-waydroid_x86.zip

# compilazione da un checkout LineageOS
sudo ./scripts/provision_waydroid_image.sh --edition edu --build \
     --source-dir ~/lineageos-16.0 --jobs 4
```

Le fasi sono: scaricamento con ripresa e verifica SHA-256 (curl/wget), estrazione
(zip/tar/xz/img), installazione di `system.img` e `vendor.img` in `/var/lib/waydroid/images`,
installazione delle proprietà ART, verifica dell'ABI, scrittura del marcatore `ISA_FLOOR`.
Con `--deep-verify` l'immagine di sistema viene montata in sola lettura via `losetup` e
scandita da `scripts/verify_legacy_cpu.sh --rootfs --full`.

Schema degli URL upstream (SourceForge, progetto `waydroid`):

```
https://sourceforge.net/projects/waydroid/files/images/system/lineage/waydroid_x86/
    lineage-<versione>-<AAAAMMGG>-<VANILLA|GAPPS>-waydroid_x86-system.zip/download
https://sourceforge.net/projects/waydroid/files/images/vendor/waydroid_x86/
    lineage-<versione>-<AAAAMMGG>-MAINLINE-waydroid_x86-vendor.zip/download
```

Il mirror prismOS (`--source prismos`, predefinito) ospita la ricostruzione 16.0 x86 con
estensioni `.img.xz` e i relativi `.sha256`; l'indirizzo si sovrascrive con `--mirror`.

### 3.1 Proprietà ART del floor ISA

Le proprietà sono generate a partire dai template del pacchetto
`app-emulation/prismos-waydroid-config` e sovrascritte per l'edizione:

```
ro.product.cpu.abilist=x86,armeabi-v7a,armeabi
ro.product.cpu.abilist32=x86,armeabi-v7a,armeabi
ro.product.cpu.abilist64=
dalvik.vm.isa.x86.variant=x86
dalvik.vm.isa.x86.features=+sse3,+ssse3,+sse4_1,-sse4_2,-popcnt,-avx,-avx2
dalvik.vm.isa.x86_64.variant=x86_64
dalvik.vm.isa.x86_64.features=
ro.dalvik.vm.native.bridge=0
ro.enable.native.bridge.exec=0
ro.config.low_ram=true            (Slim ed EDU)
ro.zygote=zygote32
```

`variant` seleziona il sottoinsieme ISA che `dex2oat` assume come baseline per il codice
generato AOT: i valori `nehalem`, `sandybridge`, `ivybridge` e `haswell` implicano SSE4.2 e
POPCNT e **non devono mai essere usati**. La lista esplicita delle feature aggiunge SSE4.1 e
nega tutto il resto, così il comportamento non dipende dal CPUID visibile al container (che
su alcuni die Arrandale riporta comunque SSE4.2).

### 3.2 Budget di memoria per edizione

| Edizione | `heapgrowthlimit` | `heapsize` | `dex2oat-threads` | `dex2oat-filter` |
|---|---|---|---|---|
| EDU | 192 MiB | 384 MiB | 1 | `verify` |
| Home | 256 MiB | 512 MiB | 2 | `speed-profile` |
| Work | 192 MiB | 384 MiB | 2 | `speed-profile` |
| Slim | 128 MiB | 256 MiB | 1 | `verify` |

Il filtro `verify` rinuncia alla compilazione AOT del codice applicativo: `dex2oat` produce
solo metadati verificati e l'esecuzione resta interpretata/JIT. Su 2 core e 1 GB è la scelta
che mantiene reattivo il sistema ospite; il costo è un avvio più lento delle applicazioni.

### 3.3 Marcatore `ISA_FLOOR`

`/var/lib/waydroid/images/ISA_FLOOR` dichiara il floor delle immagini installate:

```
PRISMOS_ISA_FLOOR="x86-SSE4.1"
PRISMOS_ISA_FORBIDDEN="sse4_2 popcnt avx avx2"
```

`prismos-waydroid-prepare` lo legge prima di avviare il container: se dichiara un ISA
superiore a SSE4.1 l'avvio è **rifiutato**; se è assente l'avvio è rifiutato a meno di
`PRISMOS_ALLOW_UNVERIFIED_IMAGES=1`. È la protezione contro il caso più frequente di
regressione: un aggiornamento che reinstalla le immagini ufficiali Waydroid.

## 4. Configurazione del container

`/var/lib/waydroid/waydroid.cfg`, installato dal pacchetto:

```ini
[properties]
arch = x86
images_path = /var/lib/waydroid/images
vendor_type = MAINLINE
gralloc = minigbm
binder = binderfs
width = 1366
height = 768
scale = 1.0
no_touch = False
multi_windows = True
system_ota = 0
system_datetime = 1
system_halium = 0
mount_overlays = True

[lxc]
nic = waydroid0
protocol = static
ip = 192.168.240.112/24
gateway = 192.168.240.1
dns = 192.168.240.1
macaddr = 00:16:3e:0a:d0:53
no_overlay = False
```

`system_ota = 0` disattiva gli aggiornamenti OTA: le immagini sono gestite esclusivamente da
`provision_waydroid_image.sh`, che è l'unico punto in cui il floor ISA viene garantito.

La configurazione LXC generata da `prismos-waydroid-prepare` clona **solo** i namespace
`ipc`, `uts`, `net` e `mount`:

```ini
lxc.namespace.clone = ipc uts net mount
lxc.cgroup2.memory.high = 768M
lxc.cgroup2.memory.max = 1024M
lxc.cgroup2.cpuset.cpus = 0-1
```

Il PID namespace non è clonato deliberatamente: i processi Android restano visibili
dall'ospite, ed è ciò che permette a `prismos-slim-launcher` di seguirne il PID e di
terminarli alla chiusura dell'applicazione.

## 5. Ciclo di vita

### 5.1 `prismos-waydroid-container.service`

```
ConditionPathExists=/var/lib/waydroid/images/system.img
ConditionPathExists=/var/lib/waydroid/images/vendor.img
ConditionCapability=CAP_SYS_ADMIN
StartLimitIntervalSec=180 / StartLimitBurst=3
ExecStartPre=/usr/libexec/prismos/prismos-waydroid-prepare
ExecStart=/usr/bin/lxc-start --rcfile=/var/lib/waydroid/lxc/waydroid/config \
          --name=waydroid --nodaemon
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/usr/bin/lxc-stop --name=waydroid --rcfile=... --kill
ExecStopPost=-/usr/libexec/prismos/prismos-waydroid-cleanup
Delegate=yes
MemoryHigh=768M  MemoryMax=1024M  MemorySwapMax=256M  TasksMax=1024
```

`Delegate=yes` è necessario perché LXC gestisca la propria gerarchia di cgroup all'interno
dello slice; `StartLimitBurst=3` in 180 s impedisce che un container difettoso entri in un
ciclo di riavvio.

### 5.2 `prismos-waydroid-prepare`

Sequenza eseguita come root prima dell'avvio:

1. `setup_binder` — carica `binder_linux`, monta binderfs in `/dev/binderfs`, crea i nodi
   `binder`, `vndbinder`, `hwbinder`; se binderfs non è disponibile ripiega sul nodo statico
   `/dev/binder`, altrimenti termina con un messaggio che rimanda ad `android.config`;
2. `setup_ashmem` — carica `ashmem_linux` se presente, altrimenti registra il fallback
   `memfd` (kernel ≥ 5.18 non richiede più ashmem);
3. `setup_network` — crea il bridge `waydroid0`, assegna `192.168.240.1/24`, abilita
   `ip_forward`, installa le regole NAT quando `iptables` è disponibile (in ChromeOS può
   essere limitato: il container usa allora DNS e proxy dell'ospite);
4. `setup_dirs` — verifica `system.img`, `vendor.img` e il marcatore `ISA_FLOOR`;
5. genera `/var/lib/waydroid/lxc/waydroid/config` se assente (non sovrascrive mai una
   configurazione esistente);
6. `write_session_env` — individua il socket Wayland di Exo e scrive
   `/run/prismos/waydroid-<uid>.env`; senza socket la sessione Ash non è attiva e l'avvio
   viene rifiutato con spiegazione;
7. `verify_host_isa` — conferma che la CPU ospite abbia almeno SSE4.1 e registra nel log la
   scelta deliberata di usare immagini a floor SSE4.1 anche su CPU più recenti.

### 5.3 `prismos-waydroid-session@<uid>.service`

```
Requires=prismos-waydroid-container.service
BindsTo=prismos-waydroid-container.service
StopWhenUnneeded=yes
ConditionPathExists=/run/prismos/waydroid-%i.env
Environment=WAYLAND_DISPLAY=wayland-exo
ExecStartPre=/bin/sh -c 'test -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"'
ExecStart=/usr/bin/waydroid session start
ExecStop=/usr/bin/waydroid session stop
Restart=on-failure  RestartSec=5  TimeoutStartSec=90  OOMPolicy=stop
```

`BindsTo` garantisce che l'arresto del container arresti anche la sessione, e
`StopWhenUnneeded` che la sessione si spenga quando nessun client la richiede: è il
meccanismo su cui si basa il teardown on-demand di Slim.

### 5.4 Avvio manuale e per edizione

| Edizione | Comportamento |
|---|---|
| EDU, Home | `prismos-firstboot` abilita `prismos-subsystems.target` e il container: Waydroid parte al boot |
| Work, Slim | il container è installato ma disabilitato; parte su apertura di un `.apk`/`.xapk` |
| Tutte | `systemctl start prismos-waydroid-container.service` resta disponibile; in Slim è mediato da `prismos-slim-launcher` |

Lancio di un'applicazione specifica:

```bash
waydroid app launch org.fdroid.fdroid/org.fdroid.fdroid.views.main.MainActivity
/usr/bin/prismos-slim-launcher start waydroid --apk /home/chronos/Downloads/app.apk
```

## 6. Requisiti del kernel

Frammento `kernel/chromeos/config/chromiumos-x86_64/prismos_legacy/android.config`:

```
CONFIG_ANDROID=y
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDERFS=y
CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"
CONFIG_ASHMEM=y                     (o fallback memfd su kernel >= 5.18)
CONFIG_NAMESPACES=y
CONFIG_CGROUPS=y / CONFIG_CGROUP_SCHED=y / CONFIG_MEMCG=y
CONFIG_DMA_SHARED_BUFFER=y
CONFIG_NETFILTER / NF_NAT           (bridge e NAT per waydroid0)
CONFIG_TUN=y
```

Verifica a sistema avviato:

```bash
zcat /proc/config.gz | grep -E 'ANDROID_BINDER|BINDERFS|ASHMEM'
mount | grep binderfs
ls -l /dev/binderfs
```

## 7. Diagnosi

| Sintomo | Causa | Rimedio |
|---|---|---|
| `SIGILL` in `zygote`, container in riavvio continuo | immagini x86_64 o `dalvik.vm.isa.x86.variant=nehalem` | `provision_waydroid_image.sh --force` con sorgente x86; controllare `ISA_FLOOR` e le proprietà ART |
| `binder: failed to open binder driver` | binderfs non abilitato o non montato | verificare `android.config`; `modprobe binder_linux`; `mount -t binder binder /dev/binderfs` |
| `no wayland socket` | sessione Ash non ancora attiva | la sessione richiede `ui.target`; riavviare dopo l'accesso o usare `prismos-slim-launcher start waydroid` |
| Applicazione ARM-only non si installa | `arm_translation_required` | comportamento atteso: la traduzione ARM richiede SSE4.2; usare l'equivalente web o un pacchetto F-Droid x86 |
| Container lento al primo avvio | `dex2oat` con filtro `verify` su 2 core | attesa prevista al primo avvio delle applicazioni; non aumentare `dex2oat-threads` oltre 2 |
| Video fluido solo a 720p dentro il container | SwiftShader su Gen5 | `gralloc=minigbm` + rendering software: il container non usa la GPU ospite per il 3D |
| `MemoryMax` raggiunto, applicazioni uccise | budget del container | alzare `MemoryMax` solo con ≥ 3 GB di RAM; in Slim è volutamente 1024M |
| OTA aggiorna le immagini e il container smette di avviarsi | `system_ota` riattivato | reimpostare `system_ota = 0` in `waydroid.cfg` e rieseguire il provisioning |

Log utili: `journalctl -t prismos-waydroid`, `/var/log/prismos/waydroid-lxc.log`,
`logcat` interno al container (`waydroid shell -- logcat`).
