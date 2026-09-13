# Architettura di prismOS

Documento tecnico di riferimento. Descrive la stratificazione dei profili Portage, la
pipeline di build, il layout a runtime, il grafo delle unità systemd e i meccanismi con cui
il floor ISA **SSE4.1** viene imposto e verificato.

Per l'uso quotidiano vedere [`../README.md`](../README.md); per le differenze fra le
edizioni [`edizioni.md`](edizioni.md); per i sottosistemi di compatibilità
[`sottosistemi.md`](sottosistemi.md).

---

## 1. Principi di progetto

1. **Il floor ISA è un contratto esplicito.** Nessuna parte del sistema deduce le capacità
   della CPU a build time con `-march=native`; ogni livello di compilazione riceve flag
   scritti nero su bianco in `overlays/overlay-prismos-common/make.conf` e la conformità del
   risultato è misurata da `scripts/verify_legacy_cpu.sh` sui binari, non dichiarata.
2. **Separazione fra profilo e logica.** Le overlay di edizione contengono esclusivamente
   `make.conf`, `profiles/base/make.defaults` e l'albero rootfs in `files/`. Tutto ciò che è
   computazione (generazione di `shelf.json`, composizione del `make.conf` di board,
   politiche della Dock, stato dei sottosistemi) vive in `scripts/build_iso.sh`.
3. **Nessun demone superfluo.** Le unità dei sottosistemi vengono installate con
   `systemd_dounit` senza alcuna `systemd_enable_service`: Portage non le attiva mai e
   `systemctl preset` non le conosce. Dichiarano comunque `[Install]
   WantedBy=prismos-subsystems.target`, perché quello è il punto di aggancio usato da
   `prismos-firstboot` per abilitarle, disabilitarle o mascherarle secondo
   `/etc/prismos/edition.conf`.
4. **Un'unica fonte per le applicazioni.** `profiles/app_pool.json` alimenta il menu di
   build, `shelf.json`, le policy della Dock, il tema di icone e il catalogo runtime.
   Aggiungere un'applicazione significa modificare quel file, non cinque.
5. **Idempotenza.** Ogni script può essere rieseguito: le overlay vengono ricreate da zero,
   i file di configurazione rigenerati, le copie eseguite con `install` e non con `cp -a`.

## 2. Stratificazione dei profili Portage

ChromiumOS risolve il profilo di una board concatenando i profili dichiarati nel `parent`
della board stessa. prismOS sfrutta questo meccanismo per sommare tre strati:

```
chromiumos (profilo upstream)
   └── overlay-prismos-common/profiles/base        CFLAGS ISA, USE ARC off, Waydroid, Wine
          └── overlay-prismos-<edizione>/profiles/base   USE e pacchetti dell'edizione
                 └── overlay-amd64-prismos/profiles/base board amd64-prismos
```

Il `parent` è materializzato da `build_iso.sh` in
`overlays/overlay-amd64-prismos/profiles/base/parent` con la forma:

```
chromiumos
../prismos-common/base
../prismos-edu/base
```

### 2.1 Ordine di concatenazione dei `make.conf`

Il `make.conf` della board è generato (non copiato) e la sequenza di inclusione determina
chi vince in caso di conflitto:

| Ordine | File | Ruolo |
|---|---|---|
| 1 | `overlay-prismos-common/make.conf` | `COMMON_FLAGS`, `PRISMOS_ISA_FLOOR`, `CPU_FLAGS_X86`, `USE` di base |
| 2 | `overlay-prismos-<edizione>/make.conf` | negazioni e aggiunte USE dell'edizione, `PACKAGE_*` |
| 3 | `overlay-amd64-prismos/make.conf` (generato) | identità board, `CHROMEOS_KERNEL_SPLITCONFIG`, `CHROMEOS_IMAGE_NAME`, parallelismo |

**Regola vincolante:** lo strato 3 è concatenato *per ultimo*, quindi non deve mai
riabilitare una USE che l'edizione ha negato. Le sue assegnazioni si limitano a parametri di
board e a variabili informative (`PRISMOS_EDITION`, `PRISMOS_BUILD_STAMP`).

I flag ISA definitivi, ottenuti per composizione di variabili, sono:

```
PRISMOS_ISA_FLOOR="-march=nehalem -mno-sse4.2 -msse4.1 -mno-popcnt"
COMMON_FLAGS="-O2 -pipe ${PRISMOS_ISA_FLOOR} -fno-semantic-interposition"
HARDENING_FLAGS="-Wl,-z,relro -Wl,-z,now -fstack-protector-strong -fPIE"
CFLAGS="${COMMON_FLAGS} ${HARDENING_FLAGS}"
CXXFLAGS="${CFLAGS}"
LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,--hash-style=gnu"
CPU_FLAGS_X86="mmx mmxext sse sse2 sse3 ssse3 sse4_1 -sse4_2 -avx -avx2 -aes -f16c -popcnt"
```

> `-O2 -pipe -march=nehalem -mno-sse4.2 -msse4.1` è il nucleo richiesto; `-mno-popcnt`
> completa il floor, perché `-mno-sse4.2` non disattiva POPCNT.

### 2.2 `use.mask` e `package.use.mask`

`profiles/base/use.mask` maschera le USE di ARC a livello di profilo: anche un ebuild che le
dichiarasse non potrebbe attivarle. `package.use.mask` le maschera per i singoli pacchetti
(`www-client/chromeos-chrome`, `app-emulation/arc-*`), che sono la via attraverso cui ARC
rientra normalmente in una build ChromiumOS.

## 3. Pipeline di build

`scripts/build_iso.sh <edizione>` esegue la sequenza seguente (nomi di funzione reali):

| # | Funzione | Effetto |
|---|---|---|
| 1 | `parse_args`, `validate_environment` | risoluzione di `--sdk-dir`, verifica presenza di `cros_sdk`, `jq`, `python3`, spazio su disco, permessi |
| 2 | `load_edition_profile` | lettura di `profiles/<edizione>.conf` e validazione delle chiavi obbligatorie |
| 3 | `load_app_table` | caricamento e validazione di `profiles/app_pool.json` contro `app_pool.schema.json` |
| 4 | `print_app_menu` + `select_apps_interactive` (oppure `select_apps_from_bundle` / `select_apps_from_list`) | scelta delle applicazioni; con stdin non interattivo il bundle è automatico |
| 5 | `summarize_selection` | riepilogo a schermo con tipo e sottosistema di ogni voce |
| 6 | `generate_shelf_json` | scrittura di `build/<edizione>-<stamp>/etc/skel/.config/chromiumos/shelf.json` |
| 7 | `generate_edition_conf` | scrittura di `build/<edizione>-<stamp>/etc/prismos/edition.conf` |
| 8 | `sync_overlays` | pubblicazione delle overlay nel `cros_sdk` (link simbolici relativi o copie), ricreazione della board overlay, generazione di `parent` e `make.conf`, copia dei rootfs di edizione, installazione di `app_pool.json`, `ash-shelf.conf` e degli script in `/usr/share/prismos`, generazione delle icone se assenti |
| 9 | `install_edition_policy` | EDU Strada A/B, policy di Work, policy Dock `zz-prismos-dock.json` |
| 10 | `sync_kernel_splitconfig` | copia di `kernel/chromeos/config/chromiumos-x86_64/prismos_legacy` in `src/third_party/kernel/v6.1/chromeos/config/chromiumos-x86_64/` |
| — | *(con `--sync-only` la pipeline si ferma qui)* | |
| 11 | `apply_subsystem_boot_states` | maschera, abilita o lascia on-demand le unità di Waydroid/Wine secondo `WAYDROID_BOOT_STATE` e `WINE_BOOT_STATE` |
| 12 | `run_setup_board` | `setup_board --board=amd64-prismos --force` |
| 13 | `run_build_packages` | `build_packages --board=amd64-prismos --nowithautotest --skip_chroot_upgrade --jobs=N`, poi `emerge --noreplace` dei pacchetti aggiuntivi e `--unmerge` dei rimossi |
| 14 | `run_build_image` | `build_image --board=amd64-prismos --noenable_rootfs_verification dev` |
| 15 | `collect_image` | rinomina in `output/prismOS_<edizione>_legacy.img`, genera `.info`, `.shelf.json`, `.edition.conf`, SHA-256 |
| 16 | `verify_build` | `verify_legacy_cpu.sh --rootfs`/`--board`, verifica della rimozione di ARC, controllo policy |
| 17 | `cleanup_build` | rimozione dello staging se non è stato richiesto `--keep-build` |

Le edizioni multiple (`all`) vengono costruite in sequenza; un fallimento non interrompe le
successive e l'esito complessivo è riassunto con i codici di uscita `0`/`1`.

### 3.1 Pubblicazione delle overlay nel chroot

Il chroot vede il checkout ospite in `/mnt/host/source`. `sync_overlays` pubblica i cinque
overlay prismOS in `src/overlays/` con **link simbolici relativi** (perché la stessa
struttura funzioni dentro e fuori il chroot) oppure con copie reali se si passa
`--copy-overlays`. In aggiunta:

* `src/overlays/overlay-prismos-active` → link all'overlay di edizione corrente, usato da
  `scripts/sync_overlays.sh --check` per rilevare l'edizione attiva senza interrogare il
  build system;
* `src/overlays/overlay-amd64-prismos` → **ricreata da zero a ogni build**: non è mai
  modificata in modo incrementale, così un'edizione precedente non lascia residui.

## 4. Layout a runtime

```
/etc/prismos/
├── edition.conf              stato dei sottosistemi, RAM minima, tuning di edizione
├── slim-launcher.conf        soglie e comportamento on-demand (solo Slim)
└── edu.conf / home-tuning.conf / work.conf / slim-tuning.conf

/etc/chromium/policies/managed/
├── prismos_policy.json       policy di edizione (EDU Strada B, Work)
└── zz-prismos-dock.json      ShelfAlignment, ShelfAutoHideBehavior, PinnedLauncherApps,
                              WebAppInstallForceList (il prefisso zz- garantisce che
                              Chromium le carichi per ultime e quindi vinca sui conflitti)

/etc/skel/.config/chromiumos/shelf.json
                              preferenze della Dock per ogni nuovo profilo utente

/etc/env.d/50prismos-gpu      crocus, i965, LIBGL_DRI3_DISABLE, CHROMEOS_GPU_FLAGS
/etc/env.d/99prismos-wine     WINEARCH, WINEPREFIX, WINEDEBUG, backend wined3d
/etc/sysctl.d/99-prismos-legacy.sysctl   swappiness, dirty_ratio, THP, watchdog
/etc/default/chromium-browser switch di Chromium (enrollment EDU, ARC off)
/etc/default/earlyoom         soglie di kill (Slim)
/etc/zram-generator.conf      zram zstd dimensionato sulla RAM (Slim)

/usr/share/prismos/
├── app_pool.json             catalogo runtime delle applicazioni
├── ash-shelf.conf            parametri di aspetto della Dock
├── accelerators.json         mappa delle 12 scorciatoie globali
└── scripts/                  build_iso.sh, provision_waydroid_image.sh,
                              verify_legacy_cpu.sh, set_edu_policy.sh,
                              generate_app_icons.sh, sync_overlays.sh, lib/

/usr/share/icons/prismOS-Squircle/
├── index.theme               tema XDG con ereditarietà da Adwaita/hicolor
└── apps/scalable/*.svg       33 icone (25 applicazioni + 8 di sistema)

/usr/bin/
├── prismos-slim-launcher     punto di ingresso utente: avvio on-demand e teardown
├── prismos-wine-run          esegue un PE con i parametri corretti
└── prismos-accelerators      interrogazione delle scorciatoie registrate

/usr/libexec/prismos/
├── prismos-dock-apply        scrive le preferenze Ash e la policy della Dock
├── prismos-accelerator-daemon  cattura evdev → iniezione uinput (KEY_SEARCH)
├── prismos-firstboot         applica lo stato dei sottosistemi al primo avvio
├── prismos-waydroid-prepare  prepara rootfs, LXC, prop, verifica ISA_FLOOR
├── prismos-waydroid-cleanup  smonta, pulisce mount residui e cgroup
├── prismos-wine-prepare      crea o ripristina il prefisso Wine (wined3d/DXVK)
└── prismos-subsystem-idle-check  rileva i sottosistemi inattivi

/var/lib/waydroid/images/     system.img, vendor.img, waydroid_base.prop,
                              waydroid_mainline.prop, ISA_FLOOR
/var/lib/prismos/             stato runtime (marcatore state/firstboot.done, cache)
/home/chronos/user/WineBottles/Default   prefisso Wine predefinito (WINEARCH=win64)
/var/cache/prismos/mesa       cache degli shader (limitata a 128 MiB)
```

## 5. Grafo delle unità systemd

```
multi-user.target
   │
   ├── prismos-firstboot.service            (oneshot, RemainAfterExit=yes,
   │                                          ConditionPathExists=!/var/lib/prismos/state/firstboot.done
   │                                          ConditionPathExists=/etc/prismos/edition.conf)
   │        └── decide lo stato dei sottosistemi leggendo /etc/prismos/edition.conf
   │
   ├── prismos-dock-apply.service           (oneshot, After=prismos-firstboot.service,
   │                                          ConditionPathExists=/usr/libexec/prismos/prismos-dock-apply)
   ├── prismos-accelerator-daemon.service   (simple, SupplementaryGroups=input)
   │
   ├── prismos-subsystems.target            (contenitore logico dei sottosistemi: installato
   │                                          ma NON abilitato da Portage)
   │        ├── prismos-waydroid-container.service   (Type=notify, MemoryMax, CPUQuota)
   │        │        └── prismos-waydroid-session@<uid>.service
   │        ├── prismos-wine-session@<uid>.service   (StopWhenUnneeded, MemoryMax=512M)
   │        └── prismos-subsystem-idle.timer → prismos-subsystem-idle.service
   │                 └── dopo SUBSYSTEM_IDLE_TIMEOUT secondi di inattività arresta il sottosistema
   │
   └── prismos-subsystems.slice             (MemoryHigh=1G, MemoryMax=1536M, MemorySwapMax=256M,
                                              TasksMax=2048, CPUWeight=90, IOWeight=80)
```

Stato al boot per edizione, letto da `/etc/prismos/edition.conf`:

| Chiave | EDU | Home | Work | Slim |
|---|---|---|---|---|
| `WAYDROID_BOOT_STATE` | `enabled` | `enabled` | `on-demand` | `on-demand` |
| `WINE_BOOT_STATE` | `masked` | `enabled` | `enabled` | `on-demand` |
| `SUBSYSTEM_IDLE_TIMEOUT` | 600 | 1800 | 900 | 120 |
| `SUBSYSTEM_MAX_INSTANCES` | 1 | 2 | 1 | 1 |

* `enabled` → `prismos-firstboot` esegue `systemctl unmask` + `systemctl enable`, quindi il
  sottosistema parte al primo boot e a ogni avvio successivo;
* `on-demand` → `systemctl unmask` + `systemctl disable`: l'unità resta disponibile ma non
  viene trascinata al boot. Parte solo su apertura di un file di tipo compatibile
  (`.apk`/`.xapk` oppure `.exe`/`.msi`/`.dll`/`.scr`/`.cpl`/`.com`), avviata da
  `prismos-slim-launcher`, che la arresta alla chiusura dell'applicazione; il timer
  `prismos-subsystem-idle.timer` (attivo da 3 minuti dal boot, ogni 60 s) arresta comunque
  ogni sottosistema inattivo da `SUBSYSTEM_IDLE_TIMEOUT` secondi;
* `disabled` → `systemctl disable` senza maschera: avvio manuale consentito, nessun avvio
  automatico;
* `masked` → `systemctl mask`: il sottosistema non può partire nemmeno manualmente.

Le uniche unità abilitate da Portage sono quelle dell'interfaccia e del ciclo di vita:
`prismos-firstboot.service`, `prismos-accelerator-daemon.service` e
`prismos-dock-apply.service` su `multi-user.target`, `prismos-subsystem-idle.timer` su
`timers.target`. `prismos-dock-apply.service` è dichiarata `Before=ui.target
session_manager.service chrome.service`: scrive policy e preferenze **prima** che Ash
costruisca la shelf, così l'utente non vede mai il riposizionamento.

`prismos-firstboot` è anche il correttore di rotta: a ogni primo avvio rilegge
`edition.conf`, abilita o disabilita `prismos-subsystems.target` (aggregatore a cui le unità
dei sottosistemi sono agganciate via `WantedBy=`), applica lo stato di ogni sottosistema e
riabilita le unità di interfaccia. In Slim maschera `prismos-subsystem-idle.timer`, sostituita
dal teardown immediato di `prismos-slim-launcher`.

## 6. Rimozione di ARC

Tre livelli indipendenti, perché nessuno dei tre basta da solo:

| Livello | Meccanismo |
|---|---|
| USE | `USE="${USE} -arc -arc-plus -arcplusplus -arc-container -arcvm -arc-kernel-features -houdini -libhoudini"` in `overlay-prismos-common/profiles/base/make.defaults`, ripetuto con le negazioni specifiche nelle quattro edizioni |
| Profilo | `use.mask` globale + `package.use.mask` mirato su `www-client/chromeos-chrome` e `app-emulation/arc-*` |
| Runtime | policy di dispositivo `ArcEnabled=false`, `UnaffiliatedArcAllowed=false`, `UnaffiliatedDeviceArcAllowed=false`, `ArcPolicy` disabilitante, `VirtualMachinesAllowed=false`, `DeviceUnaffiliatedCrostiniAllowed=false`, `CrostiniAllowed=false`; switch `--arc-availability=none` in `/etc/default/chromium-browser` |

La verifica è affidata a `scripts/lib/isa_arc_probe.py`, che tokenizza la riga `USE=` invece
di usare espressioni regolari: `\barc\b` in grep corrisponde anche al token `-arc` (il
confine di parola cade fra `-` e `a`) e produrrebbe falsi positivi.

## 7. Imposizione e verifica del floor ISA

### 7.1 Livelli di imposizione

| Livello | Strumento |
|---|---|
| Portage | `CFLAGS`/`CXXFLAGS`/`LDFLAGS` + `CPU_FLAGS_X86` in `overlay-prismos-common/make.conf` |
| Chromium | argomenti GN: `x64_arch="generic"`, `target_cpu="x64"`, `use_thin_lto=false`, disabilitazione delle ottimizzazioni ISA-specifiche |
| Rust | `RUSTFLAGS="-C target-cpu=x86-64 -C target-feature=+sse4.1,-sse4.2,-popcnt"` |
| Go | `GOAMD64=v1` (baseline SSE2) |
| ART/Android | `dalvik.vm.isa.x86.variant=x86` con feature esplicite `-sse4_2,-popcnt,-avx,-avx2` e immagini x86 a 32 bit |
| Kernel | splitconfig senza `X86_INTEL_*` che abilitino AVX/SHA, con selezione esplicita dei cifrari SSE4.1 |
| Eclass | `prismos-legacy-cpu.eclass`: `pkg_pretend` che rifiuta l'emerge su host non conformi e `src_configure` con i flag ISA applicati automaticamente ai pacchetti prismOS |

### 7.2 Verifica

`scripts/verify_legacy_cpu.sh` opera in due fasi per contenere i tempi:

1. **Ricerca delle codifiche byte** su ogni file ELF/PE candidato (nessun disassemblatore
   invocato, lettura a blocchi con `--max-bytes` di sicurezza): CRC32 (`F2 [48] 0F 38 F1/F0`),
   POPCNT (`F3 [48] 0F B8`), `PCMPxSTRx` (`66 [48] 0F 3A 60-63`), AES-NI
   (`66 0F 38 DB/DD/DF/DC`, `66 0F 3A DF`), PCLMUL, AVX/AVX2 (prefisso VEX), BMI, F16C;
2. **Conferma con `objdump`** sui soli candidati, per mnemonico, così da scartare le
   corrispondenze casuali nei dati.

Le librerie con dispatch IFUNC — glibc, OpenSSL, zlib-ng, LLVM/Mesa e i driver DRI —
contengono legittimamente percorsi SSE4.2 selezionati a runtime dal risolutore IFUNC e sono
classificate `dispatched`: **non** costituiscono fallimento. Sono fatali le evidenze su
`chrome`, Wine, Waydroid e i pacchetti prismOS, che vengono compilati con `-march` fisso e
non hanno dispatch.

Modalità: `--host`, `--config`, `--pe FILE`, `--rootfs PATH [--full]`, `--board NOME`,
`--image FILE`; opzioni `--strict`, `--jobs`, `--max-bytes`, `--report`, `--json`,
`--check-isa`. Codici di uscita: `0` conforme, `1` non conforme, `2` errore d'uso.

## 8. Kernel

`CHROMEOS_KERNEL_SPLITCONFIG="chromiumos-x86_64/prismos_legacy"` seleziona la directory di
frammenti che `build_iso.sh` copia in
`src/third_party/kernel/v6.1/chromeos/config/chromiumos-x86_64/prismos_legacy/`. Il sistema
di configurazione di ChromiumOS concatena i frammenti elencati in `base.config`, applica
`prereq.config` per risolvere le dipendenze e genera il `.config` finale.

| Frammento | Ambito |
|---|---|
| `base.config` | elenco ordinato dei frammenti da concatenare |
| `prereq.config` | dipendenze di configurazione (cgroup, namespace, netfilter, crypto) |
| `fragment.config` | DRM_I915 e Gen5, HDA, rete, filesystem, SELinux |
| `legacy-cpu.config` | scheduler per 2 core, esclusione di AVX/AES-NI, `INTEL_IOMMU=y` con `DEFAULT_ON=n`, ITCO_WDT |
| `android.config` | `ANDROID_BINDER_IPC`, binderfs, ashmem/memfd, namespace, cgroup v2, DMA-BUF |
| `wine.config` | `BINFMT_MISC`, futex2/fsync, THP `madvise`, zswap, gamepad |
| `slim.config` | zram/zstd, PSI, memcg, tracer spenti ma `BPF_SYSCALL=y` (necessario alla sandbox di Chrome) |

Motivazioni puntuali di ogni voce: [`../kernel/README.md`](../kernel/README.md).

## 9. Estendere prismOS

| Obiettivo | Operazione |
|---|---|
| Aggiungere un'applicazione web | nuova voce in `profiles/app_pool.json` (tipo `Web_App`) + rigenerare le icone con `generate_app_icons.sh` |
| Aggiungere un'applicazione Android | voce `Android_Pkg` con `android_package`/`android_activity`, `arm_translation_required: false`, disponibile per x86 su F-Droid |
| Aggiungere un'applicazione Windows | voce `Windows_Pkg` con `wine_prefix`, `wine_arch` (`win32`/`win64`), `installer_args`, `post_install_binary` |
| Cambiare il bundle di un'edizione | `flavor_bundles.<edizione>` in `app_pool.json` (`preselected`, `default_pinned`, `max_pinned`, `blocked_by_policy`) |
| Nuova edizione | `profiles/<id>.conf`, `overlays/overlay-prismos-<id>/{make.conf,profiles/base/make.defaults,files/}`, estensione dell'array `PRISMOS_EDITIONS` in `scripts/lib/prismos_common.sh` |
| Nuova scorciatoia globale | voce in `accelerators.json` (`id`, `trigger`, `action`, `keys`\|`command`, `description`) |
| Nuovo tuning del kernel | nuovo frammento in `kernel/.../prismos_legacy/` elencato in `base.config`, oppure `KERNEL_FRAGMENTS` nel profilo di edizione |
| Nuova policy Chromium | template di edizione o `--allowlist`/`--blocklist` di `set_edu_policy.sh`; le chiavi vanno aggiunte anche a `overlay-prismos-edu/chrome_policy.json` |

Dopo ogni modifica degli overlay è sufficiente:

```bash
./scripts/sync_overlays.sh --check          # coerenza della repository
./scripts/build_iso.sh <edizione> --sync-only   # pubblicazione nel SDK senza compilare
```

## 10. Vincoli noti dell'hardware di riferimento

| Componente | Vincolo | Conseguenza progettuale |
|---|---|---|
| Intel Pentium P6100 / Celeron P4500 | SSE4.1, niente SSE4.2/POPCNT/AVX/AES-NI | floor ISA descritto sopra; cifrari AES software |
| Intel HD Graphics (Ironlake, Gen5) | OpenGL 2.1, nessun Vulkan, VA-API parziale (MPEG-2/VC-1; H.264 non affidabile) | Mesa `crocus` (mai `iris`/`zink`), `LIBGL_DRI3_DISABLE=1`, decodifica video software con SIMD SSE4.1, `wined3d` invece di DXVK |
| Widevine su piattaforma non certificata | livello L3 | streaming DRM limitato a 720p: comportamento atteso, non un difetto |
| 1–3 GB di RAM | nessun margine per ARC | Waydroid x86 a 32 bit, heap ART ridotto, `ro.config.low_ram=true`, zram zstd, earlyoom |
| 2 core logici | parallelismo minimo | `dex2oat-threads=1/2`, `cpuset.cpus=0-1`, `single-thread-link` in Slim |
| Chipset HM55/PM55 | IOMMU Intel VT-d assente o parziale | `INTEL_IOMMU=y` ma `DEFAULT_ON=n` per non perdere prestazioni senza guadagno |
