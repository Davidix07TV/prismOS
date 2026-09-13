# Dock macOS-like e launcher centralizzato

Come prismOS impone l'aspetto della shelf di Ash — **posizione bassa, icone centrate,
autohide sempre attivo, maschera squircle** — e come funziona il launcher globale in stile
Spotlight.

Documentazione di riferimento per `prismos-dock-apply.service`,
`prismos-accelerator-daemon.service` e i comandi `prismos-dock` e `prismos-accelerators`.

---

## 1. I tre meccanismi, in ordine di autorità

ChromiumOS offre tre livelli diversi per configurare la shelf, con precedenze differenti.
prismOS li usa tutti e tre, perché nessuno basta da solo:

| # | Meccanismo | Percorso | Autorità |
|---|---|---|---|
| 1 | **Policy di dispositivo** | `/etc/chromium/policies/managed/zz-prismos-dock.json` | vincolante: l'utente non può spostare la shelf né disattivare l'autohide |
| 2 | **Preferenze Ash** | `/home/chronos/u-*/Local State` (`ash.shelf.*`) | applicate all'avvio della sessione; rendono coerente il primo accesso anche dove la policy non arriva (dimensione icone, centratura) |
| 3 | **`shelf.json` di skel** | `/etc/skel/.config/chromiumos/shelf.json` | modello per i nuovi profili: elenco delle icone bloccate e parametri di aspetto |

Il prefisso `zz-` sul file di policy non è decorativo: Chromium carica i file della directory
`managed` in ordine lessicografico e, a parità di chiave, vince l'ultimo. Con `zz-` la policy
della Dock prevale su eventuali policy di edizione scritte in `prismos_policy.json`.

### 1.1 Chiavi di policy generate

```json
{
  "ShelfAlignment": "Bottom",
  "ShelfAutoHideBehavior": "Always",
  "PinnedLauncherApps": ["https://classroom.google.com/", "..."],
  "WebAppInstallForceList": [
    { "url": "https://classroom.google.com/", "create_url": "https://classroom.google.com/" }
  ]
}
```

* `ShelfAlignment` e `ShelfAutoHideBehavior` sono le uniche due chiavi realmente vincolanti
  per l'aspetto; tutto il resto è derivato;
* `PinnedLauncherApps` accetta URL (oltre agli ID delle applicazioni del Web Store): è il
  motivo per cui il pool usa **PWA installate** (`WebAppInstallForceList`) invece di ID di
  applicazioni esterne. Gli ID del Web Store non sono inventabili e cambiano nel tempo,
  mentre l'URL di installazione è stabile e verificabile;
* `WebAppInstallForceList` forza l'installazione delle PWA selezionate, così le icone
  esistono al primo accesso anche senza rete di gestione.

`PinnedLauncherApps` accetta **solo** riferimenti ad applicazioni web (URL o ID del Web
Store): le voci del pool di tipo `Android_Pkg` e `Windows_Pkg` non possono quindi comparire
nella policy e restano confinate a `shelf.json`, da cui Ash le aggiunge alla shelf come
voci di launcher con il proprio sottosistema di appartenenza. Nella pratica, per l'edizione
Work la policy fissa 6 PWA mentre `shelf.json` dichiara 8 icone bloccate (le due aggiuntive
sono PuTTY e Notepad++ via Wine). Il conteggio dei pin massimi (`SHELF_PIN_MAX`) si riferisce
perciò a `shelf.json`, non alla policy.

## 2. Flusso di generazione

```
profiles/app_pool.json                 profiles/<edizione>.conf
        │                                        │
        │  build_iso.sh: load_app_table          │  load_edition_profile
        │  select_apps_* (menu / bundle / lista) │
        └───────────────┬────────────────────────┘
                        │  generate_shelf_json
                        ▼
        build/<edizione>-<stamp>/etc/skel/.config/chromiumos/shelf.json
                        │  sync_overlays → board overlay → immagine
                        ▼
        /etc/skel/.config/chromiumos/shelf.json
                        │
      install_edition_policy: policy_mapping → zz-prismos-dock.json
                        │
                        ▼
   avvio: prismos-dock-apply.service (Before=ui.target)
             ├── scrive/aggiorna zz-prismos-dock.json
             ├── applica i pref ash.shelf.* nei profili esistenti
             └── rigenera il tema di icone se mancante
```

### 2.1 Struttura di `shelf.json`

| Chiave | Contenuto |
|---|---|
| `schema_version`, `generated_by`, `edition`, `edition_name` | tracciabilità della build |
| `target_path` | `/etc/skel/.config/chromiumos/shelf.json` |
| `shelf` | `alignment`, `autohide`, `centered`, `icon_size`, `icon_spacing`, `squircle_radius`, `squircle_exponent`, `launcher_button_position`, `launcher_accelerator`, `web_search_accelerator`, `show_window_indicators`, `magnification_on_hover`, `background_blur`, `background_opacity`, `animations_enabled`, `animation_duration_ms`, `max_visible_windows`, `max_pinned` |
| `policy_mapping` | traduzione in chiavi di policy Chromium (`ShelfAlignment`, `ShelfAutoHideBehavior`, `PinnedLauncherApps`, `WebAppInstallForceList`) |
| `pinned_apps` | icone bloccate, con tipo, sottosistema di appartenenza e unità systemd da attivare per le applicazioni non web |
| `unselected_apps` | voci del pool disponibili ma non installate, per il launcher |
| `subsystems` | stato di Waydroid e Wine nell'edizione (`enabled`, `on-demand`, `masked`) |

`shelf.json` è al tempo stesso configurazione e documentazione: chi apre il file capisce
perché la Dock è fatta in quel modo e quali applicazioni erano candidate.

### 2.2 Parametri per edizione

| Parametro | EDU | Home | Work | Slim |
|---|---|---|---|---|
| `SHELF_ALIGNMENT` | Bottom | Bottom | Bottom | Bottom |
| `SHELF_AUTOHIDE` | Always | Always | Always | Always |
| `SHELF_CENTERED` | true | true | true | true |
| `SHELF_ICON_SIZE` | 48 | 56 | 48 | 40 |
| `SHELF_SQUIRCLE_RADIUS` | 0.28 | 0.28 | 0.28 | 0.28 |
| `SHELF_SQUIRCLE_EXPONENT` | 5.0 | 5.0 | 5.0 | 5.0 |
| `SHELF_PIN_MAX` | 8 | 10 | 8 | 6 |
| animazioni / blur | sì | sì | sì | **no** |
| `SHELF_BACKGROUND_OPACITY` | 0.86 | 0.86 | 0.86 | **1.00** |
| `SHELF_MAX_VISIBLE_WINDOWS` | 8 | 8 | 8 | **4** |

Le tre costanti invariate fra le edizioni (`Bottom`, `Always`, centratura) sono il requisito
di prodotto; tutto il resto scala con la RAM e con la GPU.

## 3. `prismos-dock-apply`

Helper di sistema in Python 3, installato in `/usr/libexec/prismos/prismos-dock-apply` e
eseguito da `prismos-dock-apply.service`:

```
After=local-fs.target systemd-tmpfiles-setup.service prismos-firstboot.service
Before=ui.target session_manager.service chrome.service
Type=oneshot / RemainAfterExit=yes / TimeoutStartSec=90
PrivateTmp=yes, NoNewPrivileges=yes, ProtectKernelTunables=yes,
ProtectKernelModules=yes, ProtectControlGroups=yes, RestrictSUIDSGID=yes
ReadWritePaths=/etc/chromium /etc/xdg /usr/share/icons/prismOS-Squircle /home/chronos
```

`Before=ui.target` è la parte essenziale: policy e preferenze sono già su disco quando Ash
costruisce la shelf, quindi l'utente non vede mai il riposizionamento né un'icona non
mascherata.

Le preferenze `ash.shelf.*` vengono scritte nei profili esistenti
(`/home/chronos/u-*/Local State`) **solo se il processo Chrome della sessione non è in
esecuzione**: modificare `Local State` a caldo verrebbe sovrascritto all'uscita. In quel caso
l'helper lascia il lavoro alla policy, che è comunque vincolante.

Opzioni:

```
--conf FILE            file INI della Dock (default /usr/share/prismos/ash-shelf.conf)
--shelf-json PATH      shelf.json da usare (ripetibile)
--alignment Bottom|Left|Right
--autohide Always|Never|OnFullScreen
--icon-size N          24-96 px
--squircle F           0.00-0.50
--pin-max N            massimo numero di icone bloccate
--policy-only          scrive solo la policy
--prefs-only           scrive solo i pref Ash
--icons-only           rigenera solo il tema di icone
--verify               verifica la policy installata ed esce (0 conforme, 1 no)
```

## 4. `prismos-dock`, il comando utente

`/usr/bin/prismos-dock` è il wrapper interattivo (bash) dell'helper:

```bash
prismos-dock show                       # configurazione effettiva e provenienza
prismos-dock verify                     # esito 0/1, utilizzabile negli script
prismos-dock status                     # unità, policy, tema icone, daemon acceleratori
prismos-dock apply                      # riapplica policy + pref + icone
prismos-dock apply --icon-size 40 --pin-max 6
prismos-dock policy --alignment Bottom --autohide Always
prismos-dock prefs
prismos-dock icons
```

Il wrapper valida gli argomenti prima di invocare l'helper (`--alignment` accetta solo
`Bottom|Left|Right`, `--icon-size` solo interi 24-96, `--squircle` solo decimali 0.00-0.50,
`--pin-max` solo interi 1-24) e gestisce i privilegi: se `POLICY_DIR` non è scrivibile usa
`sudo -n` quando le credenziali sono già in cache, altrimenti `sudo` interattivo, e avverte
esplicitamente se nessuno dei due è possibile invece di produrre una scrittura parziale.

## 5. `ash-shelf.conf`

Configurazione dichiarativa in formato INI, `/usr/share/prismos/ash-shelf.conf`:

```ini
[dock]
alignment = Bottom
autohide = Always
centered = True
dock_offset_bottom = 0
icon_size = 48
icon_spacing = 8
squircle_radius = 0.28
squircle_exponent = 5.0
pin_max = 8
show_window_indicators = True
magnification_on_hover = False
magnification_factor = 1.35
animation_duration_ms = 180
background_blur = True
background_opacity = 0.86
hotseat_collapsible = True
launcher_button_position = center
launcher_accelerator = super+space
web_search_accelerator = super+shift+space
lock_accelerator = super+l
```

`magnification_on_hover = False` è una scelta deliberata: l'ingrandimento al passaggio del
mouse è l'effetto più riconoscibile di macOS, ma su Intel HD Gen5 impone la ricomposizione
dell'intera shelf a ogni movimento del puntatore. È disponibile come parametro, non come
comportamento predefinito.

## 6. Tema di icone squircle

`scripts/generate_app_icons.sh` genera 33 icone vettoriali (25 applicazioni del pool + 8 di
sistema) in `overlays/overlay-amd64-prismos/board/usr/share/icons/prismOS-Squircle/`:

```
apps/scalable/<id>.svg     icona dell'applicazione
index.theme                tema XDG con Inherits=hicolor
AUTHORS, LICENSE           attribuzione e licenza MIT del tema
```

Geometria di ogni icona:

* **maschera**: superellisse |x/a|ⁿ + |y/a|ⁿ = 1 campionata su 128 punti, con n = 5.0
  (`squircle_exponent`) e raggio di arrotondamento pari al 28% del lato
  (`squircle_radius`): è la forma introdotta da macOS Big Sur, intermedia fra il quadrato e
  il cerchio;
* **fondo**: gradiente verticale derivato dal colore del marchio dichiarato in
  `app_pool.json` (`color`), con schiarimento superiore del 12% e scurimento inferiore del
  18%;
* **lucidatura**: ellisse superiore bianca al 18% di opacità, senza filtri SVG (i filtri
  `feGaussianBlur` costerebbero rasterizzazione su Gen5);
* **glifo**: due caratteri (`glyph` in `app_pool.json`) centrati, in bianco con leggera
  ombra, perché i loghi ufficiali non sono ridistribuibili.

Il tracciato è definito una sola volta e riusato con `<use href>`: il file resta sotto i
2 KiB e il compositore Ash lo ridimensiona senza costi misurabili. Nessuna bitmap viene
generata, quindi nessuna dipendenza da librerie di rasterizzazione in fase di build.

```bash
./scripts/generate_app_icons.sh                        # tema completo
./scripts/generate_app_icons.sh --list                 # elenco delle icone previste
./scripts/generate_app_icons.sh --shape rounded-rect --radius 0.22
./scripts/generate_app_icons.sh --exponent 4.0 --size 256
./scripts/generate_app_icons.sh --only netflix,spotify
./scripts/generate_app_icons.sh --preview build/preview.svg
./scripts/generate_app_icons.sh --validate             # coerenza con app_pool.json
./scripts/generate_app_icons.sh --force                # sovrascrive anche icone esistenti
```

`build_iso.sh` genera il tema automaticamente se la board overlay ne è sprovvista, così una
repository clonata da zero produce comunque immagini con le icone corrette.

## 7. Launcher centralizzato e scorciatoie globali

Ash riconosce nativamente il tasto **Search** (`KEY_SEARCH`) dei Chromebook per aprire il
launcher. prismOS non applica patch a Chromium: intercetta la tastiera a livello evdev e
**iniezione via uinput** le combinazioni che Ash già comprende.

`prismos-accelerator-daemon` (`/usr/libexec/prismos/`):

* apre i dispositivi `/dev/input/event*` con `EVIOCGRAB` (cattura esclusiva, così la
  combinazione non arriva due volte), filtrati da `device_filter` in
  `/usr/share/prismos/accelerators.json`;
* ricostruisce le combinazioni da `keys`/`command` e le traduce in eventi uinput con un
  ritardo di `inject_delay_ms = 8` ms fra i tasti, sufficiente perché Ash riconosca la
  sequenza come combinazione e non come due pressioni distinte;
* richiede `SupplementaryGroups=input` e accesso a `/dev/uinput`.

Le dodici combinazioni di `/usr/share/prismos/accelerators.json`:

| `id` | Combinazione | Azione | Effetto |
|---|---|---|---|
| `app_launcher_primary` | `super+space` | `inject_keys KEY_SEARCH` | launcher in stile Spotlight |
| `app_launcher` | `super+shift+space` | `inject_keys KEY_LEFTMETA KEY_SEARCH` | ricerca web diretta |
| `lock_screen` | `super+l` | `inject_combo KEY_SEARCH KEY_L` | blocca lo schermo |
| `show_desktop` | `super+d` | `inject_combo KEY_SEARCH KEY_D` | riduce tutte le finestre |
| `window_overview` | `super+w` | `inject_keys KEY_WWW` | panoramica delle finestre |
| `screenshot_full` | `super+print` | `inject_combo Ctrl+Meta+SysRq` | cattura schermo intero |
| `switch_app_1..4` | `super+1..4` | `inject_combo Meta+N` | passa all'N-esima icona bloccata |
| `subsystem_status` | `super+ctrl+s` | `exec prismos-slim-launcher status` | stato dei sottosistemi e RAM libera |
| `subsystem_stop_all` | `super+ctrl+q` | `exec prismos-slim-launcher stop-all` | spegne Waydroid e Wine |

Le ultime due non iniettano tasti: eseguono direttamente un comando, e sono il ponte fra
l'interfaccia e il meccanismo on-demand di Slim.

```bash
prismos-accelerators --list          # combinazioni registrate
prismos-accelerators --list-devices  # dispositivi di input individuati
prismos-accelerators --config /usr/share/prismos/accelerators.json
prismos-accelerators --no-grab       # ascolto senza cattura esclusiva (diagnosi)
systemctl status prismos-accelerator-daemon
journalctl -t prismos-accelerators
```

Per aggiungere una scorciatoia è sufficiente una nuova voce nel JSON (`id`, `trigger`,
`action`, `keys` oppure `command`, `description`) e un riavvio del daemon: nessuna
ricompilazione.

## 8. Verifica e diagnosi

```bash
prismos-dock status && prismos-dock verify
cat /etc/chromium/policies/managed/zz-prismos-dock.json | python3 -m json.tool
grep -o '"ash.shelf[^,]*' /home/chronos/u-*/Local\ State
gtk-query-icon-theme 2>/dev/null || ls /usr/share/icons/prismOS-Squircle/apps/scalable | wc -l
```

| Sintomo | Causa | Rimedio |
|---|---|---|
| Shelf a sinistra o visibile | policy assente o sovrascritta da un'altra policy caricata dopo | `prismos-dock verify`; controllare il prefisso `zz-` e l'ordine lessicografico in `managed/` |
| Le icone non sono quadrate arrotondate | tema non selezionato | verificare `index.theme`, `Inherits=` e la presenza degli SVG; `prismos-dock icons` |
| Le PWA non compaiono al primo accesso | `WebAppInstallForceList` senza rete | le voci richiedono connettività al primo avvio; in aula precaricare la policy con `--sync-only` e un avvio con rete |
| `super+space` non fa nulla | daemon arrestato o senza accesso a `/dev/input` | `systemctl status prismos-accelerator-daemon`, gruppo `input`, permessi su `/dev/uinput` |
| `super+space` apre due volte il launcher | cattura evdev non esclusiva (un altro processo legge la tastiera) | verificare `grab_devices: true` in `accelerators.json` |
| Le preferenze cambiano ma tornano indietro | `Local State` riscritto da Chrome a fine sessione | atteso: la policy è l'unico livello persistente; `prismos-dock policy` |
| Animazioni a scatti in Slim | blur e animazioni attive su Gen5 | `SHELF_ANIMATIONS=0`, `SHELF_BACKGROUND_BLUR=0` in `profiles/slim.conf` |
