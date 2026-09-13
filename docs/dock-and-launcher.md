# macOS-like dock and central launcher

How prismOS imposes the look of the Ash shelf — **bottom position, centred icons,
autohide always on, squircle mask** — and how the global Spotlight-style launcher works.

Reference documentation for `prismos-dock-apply.service`,
`prismos-accelerator-daemon.service` and the commands `prismos-dock` and
`prismos-accelerators`.

---

## 1. The three mechanisms, in order of authority

ChromiumOS offers three different levels to configure the shelf, with different
precedence. prismOS uses all three, because none is sufficient alone:

| # | Mechanism | Path | Authority |
|---|---|---|---|
| 1 | **Device policy** | `/etc/chromium/policies/managed/zz-prismos-dock.json` | binding: the user cannot move the shelf nor disable autohide |
| 2 | **Ash preferences** | `/home/chronos/u-*/Local State` (`ash.shelf.*`) | applied at session start; keep the first login coherent even where policy does not reach (icon size, centring) |
| 3 | **skel `shelf.json`** | `/etc/skel/.config/chromiumos/shelf.json` | template for new profiles: list of pinned icons and appearance parameters |

The `zz-` prefix on the policy file is not decorative: Chromium loads the files of the
`managed` directory in lexicographic order and, on equal keys, the last one wins. With
`zz-` the dock policy prevails over any edition policy written in `prismos_policy.json`.

### 1.1 Generated policy keys

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

* `ShelfAlignment` and `ShelfAutoHideBehavior` are the only two keys really binding for
  the look; everything else is derived;
* `PinnedLauncherApps` accepts URLs (in addition to Web Store application IDs): this is
  why the pool uses **installed PWAs** (`WebAppInstallForceList`) instead of external
  application IDs. Web Store IDs cannot be invented and change over time, while the
  installation URL is stable and verifiable;
* `WebAppInstallForceList` forces installation of the selected PWAs, so the icons exist at
  first login even without a management network.

`PinnedLauncherApps` accepts **only** references to web applications (URLs or Web Store
IDs): `Android_Pkg` and `Windows_Pkg` entries of the pool cannot therefore appear in the
policy and remain confined to `shelf.json`, from which Ash adds them to the shelf as
launcher entries with their own subsystem. In practice, for the Work edition the policy
pins 6 PWAs while `shelf.json` declares 8 pinned icons (the two extra ones are PuTTY and
Notepad++ via Wine). The maximum pin count (`SHELF_PIN_MAX`) therefore refers to
`shelf.json`, not to the policy.

## 2. Generation flow

```
profiles/app_pool.json                 profiles/<edition>.conf
        │                                        │
        │  build_iso.sh: load_app_table          │  load_edition_profile
        │  select_apps_* (menu / bundle / list)  │
        └───────────────┬────────────────────────┘
                        │  generate_shelf_json
                        ▼
        build/<edition>-<stamp>/etc/skel/.config/chromiumos/shelf.json
                        │  sync_overlays → board overlay → image
                        ▼
        /etc/skel/.config/chromiumos/shelf.json
                        │
      install_edition_policy: policy_mapping → zz-prismos-dock.json
                        │
                        ▼
   boot: prismos-dock-apply.service (Before=ui.target)
             ├── writes/updates zz-prismos-dock.json
             ├── applies ash.shelf.* prefs in existing profiles
             └── regenerates the icon theme if missing
```

### 2.1 Structure of `shelf.json`

| Key | Content |
|---|---|
| `schema_version`, `generated_by`, `edition`, `edition_name` | build traceability |
| `target_path` | `/etc/skel/.config/chromiumos/shelf.json` |
| `shelf` | `alignment`, `autohide`, `centered`, `icon_size`, `icon_spacing`, `squircle_radius`, `squircle_exponent`, `launcher_button_position`, `launcher_accelerator`, `web_search_accelerator`, `show_window_indicators`, `magnification_on_hover`, `background_blur`, `background_opacity`, `animations_enabled`, `animation_duration_ms`, `max_visible_windows`, `max_pinned` |
| `policy_mapping` | translation into Chromium policy keys (`ShelfAlignment`, `ShelfAutoHideBehavior`, `PinnedLauncherApps`, `WebAppInstallForceList`) |
| `pinned_apps` | pinned icons, with type, owning subsystem and systemd unit to start for non-web applications |
| `unselected_apps` | pool entries available but not installed, for the launcher |
| `subsystems` | state of Waydroid and Wine in the edition (`enabled`, `on-demand`, `masked`) |

`shelf.json` is at the same time configuration and documentation: whoever opens the file
understands why the dock looks that way and which applications were candidates.

### 2.2 Parameters per edition

| Parameter | EDU | Home | Work | Slim | PRO |
|---|---|---|---|---|---|
| `SHELF_ALIGNMENT` | Bottom | Bottom | Bottom | Bottom | Bottom |
| `SHELF_AUTOHIDE` | Always | Always | Always | Always | Always |
| `SHELF_CENTERED` | true | true | true | true | true |
| `SHELF_ICON_SIZE` | 48 | 56 | 48 | 40 | 52 |
| `SHELF_SQUIRCLE_RADIUS` | 0.28 | 0.28 | 0.28 | 0.28 | 0.28 |
| `SHELF_SQUIRCLE_EXPONENT` | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 |
| `SHELF_PIN_MAX` | 8 | 10 | 8 | 6 | 10 |
| animations / blur | yes | yes | yes | **no** | yes |
| `SHELF_BACKGROUND_OPACITY` | 0.86 | 0.86 | 0.86 | **1.00** | 0.86 |
| `SHELF_MAX_VISIBLE_WINDOWS` | 8 | 8 | 8 | **4** | 8 |

The three constants invariant across editions (`Bottom`, `Always`, centring) are the
product requirement; everything else scales with RAM and GPU.

## 3. `prismos-dock-apply`

System helper in Python 3, installed at `/usr/libexec/prismos/prismos-dock-apply` and
executed by `prismos-dock-apply.service`:

```
After=local-fs.target systemd-tmpfiles-setup.service prismos-firstboot.service
Before=ui.target session_manager.service chrome.service
Type=oneshot / RemainAfterExit=yes / TimeoutStartSec=90
PrivateTmp=yes, NoNewPrivileges=yes, ProtectKernelTunables=yes,
ProtectKernelModules=yes, ProtectControlGroups=yes, RestrictSUIDSGID=yes
ReadWritePaths=/etc/chromium /etc/xdg /usr/share/icons/prismOS-Squircle /home/chronos
```

`Before=ui.target` is the essential part: policy and preferences are already on disk when
Ash builds the shelf, therefore the user never sees the repositioning nor an unmasked
icon.

The `ash.shelf.*` preferences are written into existing profiles
(`/home/chronos/u-*/Local State`) **only if the Chrome process of the session is not
running**: modifying `Local State` while hot would be overwritten on exit. In that case
the helper leaves the job to the policy, which is binding anyway.

Options:

```
--conf FILE            INI file of the dock (default /usr/share/prismos/ash-shelf.conf)
--shelf-json PATH      shelf.json to use (repeatable)
--alignment Bottom|Left|Right
--autohide Always|Never|OnFullScreen
--icon-size N          24-96 px
--squircle F           0.00-0.50
--pin-max N            maximum number of pinned icons
--policy-only          writes only the device policy
--prefs-only           writes only the Ash prefs
--icons-only           regenerates only the icon theme
--verify               verifies the installed policy and exits (0 conforming, 1 not)
```

## 4. `prismos-dock`, the user command

`/usr/bin/prismos-dock` is the interactive (bash) wrapper of the helper:

```bash
prismos-dock show                       # effective configuration and provenance
prismos-dock verify                     # exit code 0/1, usable in scripts
prismos-dock status                     # unit, policy, icon theme, accelerator daemon
prismos-dock apply                      # re-apply policy + prefs + icons
prismos-dock apply --icon-size 40 --pin-max 6
prismos-dock policy --alignment Bottom --autohide Always
prismos-dock prefs
prismos-dock icons
```

The wrapper validates arguments before invoking the helper (`--alignment` accepts only
`Bottom|Left|Right`, `--icon-size` only integers 24-96, `--squircle` only decimals
0.00-0.50, `--pin-max` only integers 1-24) and handles privileges: if `POLICY_DIR` is not
writable it uses `sudo -n` when credentials are already cached, otherwise interactive
`sudo`, and explicitly warns when neither is possible instead of producing a partial
write.

## 5. `ash-shelf.conf`

Declarative configuration in INI format, `/usr/share/prismos/ash-shelf.conf`:

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

`magnification_on_hover = False` is a deliberate choice: hover magnification is the most
recognizable macOS effect, but on Intel HD Gen5 it forces recomposition of the whole
shelf at every pointer movement. It is available as a parameter, not as default
behaviour.

## 6. Squircle icon theme

`scripts/generate_app_icons.sh` generates 33 vector icons (25 pool applications + 8
system ones) in `overlays/overlay-amd64-prismos/board/usr/share/icons/prismOS-Squircle/`:

```
apps/scalable/<id>.svg     application icon
index.theme                XDG theme with Inherits=hicolor
AUTHORS, LICENSE           attribution and MIT license of the theme
```

Geometry of each icon:

* **mask**: superellipse |x/a|ⁿ + |y/a|ⁿ = 1 sampled on 128 points, with n = 5.0
  (`squircle_exponent`) and rounding radius equal to 28% of the side
  (`squircle_radius`): the shape introduced by macOS Big Sur, intermediate between
  square and circle;
* **background**: vertical gradient derived from the brand colour declared in
  `app_pool.json` (`color`), with 12% top lightening and 18% bottom darkening;
* **gloss**: top white ellipse at 18% opacity, without SVG filters (`feGaussianBlur`
  filters would cost rasterization on Gen5);
* **glyph**: two characters (`glyph` in `app_pool.json`) centred, in white with a slight
  shadow, because official logos are not redistributable.

The path is defined once and reused with `<use href>`: the file stays under 2 KiB and the
Ash compositor resizes it without measurable cost. No bitmap is generated, therefore no
dependency on rasterization libraries at build time.

```bash
./scripts/generate_app_icons.sh                        # complete theme
./scripts/generate_app_icons.sh --list                 # list of planned icons
./scripts/generate_app_icons.sh --shape rounded-rect --radius 0.22
./scripts/generate_app_icons.sh --exponent 4.0 --size 256
./scripts/generate_app_icons.sh --only netflix,spotify
./scripts/generate_app_icons.sh --preview build/preview.svg
./scripts/generate_app_icons.sh --validate             # consistency with app_pool.json
./scripts/generate_app_icons.sh --force                # overwrites existing icons too
```

`build_iso.sh` generates the theme automatically if the board overlay lacks it, so a
freshly cloned repository still produces images with the correct icons.

## 7. Central launcher and global shortcuts

Ash natively recognizes the Chromebook **Search** key (`KEY_SEARCH`) to open the launcher.
prismOS applies no patches to Chromium: it grabs the keyboard at evdev level and
**injects via uinput** the combinations Ash already understands.

`prismos-accelerator-daemon` (`/usr/libexec/prismos/`):

* opens `/dev/input/event*` devices with `EVIOCGRAB` (exclusive grab, so the combination
  does not arrive twice), filtered by `device_filter` in
  `/usr/share/prismos/accelerators.json`;
* rebuilds combinations from `keys`/`command` and translates them into uinput events with
  a delay of `inject_delay_ms = 8` ms between keys, sufficient for Ash to recognize the
  sequence as a combination and not as two separate presses;
* requires `SupplementaryGroups=input` and access to `/dev/uinput`.

The twelve combinations of `/usr/share/prismos/accelerators.json`:

| `id` | Combination | Action | Effect |
|---|---|---|---|
| `app_launcher_primary` | `super+space` | `inject_keys KEY_SEARCH` | Spotlight-style launcher |
| `app_launcher` | `super+shift+space` | `inject_keys KEY_LEFTMETA KEY_SEARCH` | direct web search |
| `lock_screen` | `super+l` | `inject_combo KEY_SEARCH KEY_L` | locks the screen |
| `show_desktop` | `super+d` | `inject_combo KEY_SEARCH KEY_D` | minimizes all windows |
| `window_overview` | `super+w` | `inject_keys KEY_WWW` | window overview |
| `screenshot_full` | `super+print` | `inject_combo Ctrl+Meta+SysRq` | full screen capture |
| `switch_app_1..4` | `super+1..4` | `inject_combo Meta+N` | switches to the Nth pinned icon |
| `subsystem_status` | `super+ctrl+s` | `exec prismos-slim-launcher status` | subsystem state and free RAM |
| `subsystem_stop_all` | `super+ctrl+q` | `exec prismos-slim-launcher stop-all` | turns off Waydroid and Wine |

The last two do not inject keys: they execute a command directly, and they are the bridge
between the interface and Slim's on-demand mechanism.

```bash
prismos-accelerators --list          # registered combinations
prismos-accelerators --list-devices  # detected input devices
prismos-accelerators --config /usr/share/prismos/accelerators.json
prismos-accelerators --no-grab       # listening without exclusive grab (diagnostics)
systemctl status prismos-accelerator-daemon
journalctl -t prismos-accelerators
```

Adding a shortcut only requires a new entry in the JSON (`id`, `trigger`, `action`,
`keys` or `command`, `description`) and a daemon restart: no recompilation.

## 8. Verification and diagnostics

```bash
prismos-dock status && prismos-dock verify
cat /etc/chromium/policies/managed/zz-prismos-dock.json | python3 -m json.tool
grep -o '"ash.shelf[^,]*' /home/chronos/u-*/Local\ State
ls /usr/share/icons/prismOS-Squircle/apps/scalable | wc -l
```

| Symptom | Cause | Remedy |
|---|---|---|
| Shelf on the left or visible | policy missing or overwritten by a policy loaded later | `prismos-dock verify`; check the `zz-` prefix and lexicographic order in `managed/` |
| Icons are not rounded squares | theme not selected | check `index.theme`, `Inherits=` and SVG presence; `prismos-dock icons` |
| PWAs do not appear at first login | `WebAppInstallForceList` without network | entries require connectivity at first boot; preload the policy with `--sync-only` and a networked boot |
| `super+space` does nothing | daemon stopped or without access to `/dev/input` | `systemctl status prismos-accelerator-daemon`, `input` group, `/dev/uinput` permissions |
| `super+space` opens the launcher twice | non-exclusive evdev grab (another process reads the keyboard) | check `grab_devices: true` in `accelerators.json` |
| Preferences change but revert | `Local State` rewritten by Chrome at session end | expected: policy is the only persistent level; `prismos-dock policy` |
| Jerky animations on Slim | blur and animations active on Gen5 | `SHELF_ANIMATIONS=0`, `SHELF_BACKGROUND_BLUR=0` in `profiles/slim.conf` |
