# The editions of prismOS

Extended comparison of **EDU**, **Home**, **Work**, **Slim** and **PRO**: hardware
parameters, USE flags, packages, subsystem state, dock appearance, Chromium policies and
edition rootfs content.

For the overall picture see [`architecture.md`](architecture.md); for the subsystems see
[`waydroid-integration.md`](waydroid-integration.md) and
[`wine-integration.md`](wine-integration.md).

---

## 1. Where the configuration of an edition lives

Each edition is described by three sets of files, with distinct responsibilities and no
duplication:

| File | Read by | Content |
|---|---|---|
| `profiles/<edition>.conf` | `scripts/build_iso.sh` | identity, hardware requirements, subsystem state, dock parameters, policy, kernel fragments, added/removed packages |
| `overlays/overlay-prismos-<edition>/make.conf` | Portage | informative `PRISMOS_*` variables, edition USE, `PRISMOS_POLICY_SOURCE`, `PRISMOS_ROOTFS_FILES`, `PRISMOS_EXTRA_PACKAGES` |
| `overlays/overlay-prismos-<edition>/profiles/base/make.defaults` | Portage (profile) | USE resolved in the profile, `PROFILE_ONLY_VARIABLES`, `SYSTEM_PACKAGES`, `PRISMOS_SUBSYSTEM` |
| `overlays/overlay-prismos-<edition>/files/` | `build_iso.sh` → rootfs | `/etc` tree copied into the image: detailed `edition.conf`, tuning, policies, Chromium switches |

`profiles/<edition>.conf` is the source of `build/<edition>-<stamp>/etc/prismos/edition.conf`,
which is the contract read at runtime by `prismos-firstboot`, `prismos-dock-apply` and
`prismos-slim-launcher`.

## 2. Summary matrix

| Parameter | EDU | Home | Work | Slim | PRO |
|---|---|---|---|---|---|
| `PROFILE_ID` | `edu` | `home` | `work` | `slim` | `pro` |
| Audience | labs, classrooms, exams | household, streaming | corporate fleet, remote work | refurbished under 2 GB | one image, edition chosen at setup |
| `MIN_RAM_MB` | 2048 | 3072 | 3072 | 1024 | 3072 |
| `CRITICAL_RAM_MB` | 1536 | 2048 | 2048 | 768 | 2048 |
| Waydroid at boot | `enabled` | `enabled` | `on-demand` | `on-demand` | per the chosen edition |
| Wine at boot | `masked` | `enabled` | `enabled` | `on-demand` | per the chosen edition |
| `SUBSYSTEM_IDLE_TIMEOUT` (s) | 600 | 1800 | 900 | 120 | per the chosen edition |
| `SUBSYSTEM_MAX_INSTANCES` | 1 | 2 | 1 | 1 | per the chosen edition |
| Chromium policy | Route A or Route B | none | device policy | none | template of the chosen edition |
| Crostini (Linux) | off | off | **on** | off | on |
| Bottles/Proton | off | **on** | **on** | Proton yes, Bottles no | on |
| PipeWire/PulseAudio | on | **on** | on | off (direct ALSA) | on |
| VA-API | on | on | on | off | on |
| CUPS/printing | on | on | on | off | on |
| zram/zswap/earlyoom | zswap | zswap | zswap | **zram zstd + zswap + earlyoom** | zswap + earlyoom |
| `single-thread-link` | no | no | no | **yes** (2 cores) | no |
| Kernel fragments | `legacy-cpu`, `android` | `legacy-cpu`, `android`, `wine` | `legacy-cpu`, `android`, `wine` | `legacy-cpu`, `android`, `wine`, **`slim`** | `legacy-cpu`, `android`, `wine` |
| Max dock pins | 8 | 10 | 8 | 6 | 10 |
| `SHELF_ICON_SIZE` | 48 | 56 | 48 | 40 | 52 |
| Dock animations/blur | yes | yes | yes | **no** | yes |
| `SHELF_BACKGROUND_OPACITY` | 0.86 | 0.86 | 0.86 | 1.00 | 0.86 |

## 3. EDU — Cloud-Managed and Local-Policy

**Goal.** A school fleet manageable without dedicated infrastructure and resistant to
misuse: ephemeral profiles, no guest, no social, no gaming.

### 3.1 USE flags

```
prismos_edition_edu cloud-enrollment local-policy device-restrict school-lab kiosk-exam
waydroid wine -proton -bottles -crostini -virtio-gpu -developer-tools
-arc -arc-plus -arcplusplus -arcvm
```

* `cloud-enrollment` brings `chromeos-base/prismos-edu-enrollment`, which installs the
  Route A script and the files in `/etc/default/chromium-browser`;
* `local-policy` brings `app-admin/chromeos-policy-tool` and the management of
  `prismos_policy.json`;
* `kiosk-exam` enables exam mode (full screen, navigation limited to the allowed domain);
* Wine is present as a common USE but its boot state is `masked`: in labs it is unneeded
  and occupies prefixes on disk.

### 3.2 Policy

Two alternative routes, never both:

* **Route A — Cloud-Managed.** Only Enterprise Enrollment switches in
  `/etc/default/chromium-browser`:
  `--enterprise-enable-zero-touch-enrollment`, optionally
  `--enterprise-enrollment-initial-modulus`/`-initial-modulus-length` for a proprietary DM
  server, and `--arc-availability=none`. No local JSON policy, which would take precedence
  over the cloud one.
* **Route B — Local-Policy.**
  `/etc/chromium/policies/managed/prismos_policy.json` (mirrored to
  `/etc/opt/chrome/policies/managed/` for branded builds) derived from the template
  `overlays/overlay-prismos-edu/chrome_policy.json` (81 keys): URLBlocklist on TikTok,
  YouTube, Twitch, social networks, gaming, anonymous proxies and adult content;
  URLAllowlist on the school domain, ministerial services, Workspace for Education,
  Geogebra, Canva, Wikipedia, Khan Academy, Scratch, F-Droid; `UserAllowlist` on
  `*@<domain>`; guest, incognito and developer tools disabled; ARC and VMs forbidden.

The management tool is `scripts/set_edu_policy.sh` (see the
[School policy (EDU)](../README.md#edu-policy) section of the README).

### 3.3 Edition rootfs

```
etc/default/chromium-browser     enrollment switches and ARC off
etc/prismos/edu.conf             classroom parameters (domain, ephemeral session, app block)
```

### 3.4 Typical applications

Google Classroom, Drive, Meet, Canva, GeoGebra, VS Code Web, AnkiDroid (Android), VLC for
Android, F-Droid, OsmAnd.

## 4. Home — entertainment and light gaming

**Goal.** Make the most of a Gen5 GPU and 3 GB of RAM for video, music, cloud gaming and a
few local titles, without compromising stability.

### 4.1 USE flags

```
prismos_edition_home media-stack cloud-gaming android-gaming windows-gaming drm-l3
waydroid wine proton bottles gstreamer pipewire pulseaudio vaapi widevine h264 aac mp3
proprietary-codecs -crostini -device-restrict -kiosk-exam
-arc -arc-plus -arcplusplus -arcvm
```

### 4.2 Multimedia on Intel HD Gen5

| Aspect | Choice | Reason |
|---|---|---|
| Codecs | `h264 aac mp3 proprietary-codecs widevine` | commercial streaming |
| Widevine | level L3, 720p ceiling | the platform is uncertified: L1 is not available |
| VA-API | `LIBVA_DRIVER_NAME=i965`, `--disable-features=VaapiVideoDecoder` | on Ironlake the H.264 path is not reliable; decoding happens in software with SSE4.1 SIMD (dav1d/ffmpeg), which is the expected behaviour |
| Compositing | `--use-gl=angle --use-angle=gl`, GPU rasterization disabled | OpenGL 2.1, no Vulkan |
| Audio | PipeWire + PulseAudio | Bluetooth/HDMI device management |

### 4.3 Gaming

* **Cloud gaming** (GeForce NOW, Xbox Cloud, Amazon Luna) via browser: no local instance,
  no ISA constraint;
* **Proton/Bottles** for light Windows titles: `wined3d` on Shader Model 3, no DXVK
  (Vulkan missing), `wined3d_VideoMemorySize=64`, `wined3d_Multisampling=disabled`;
* **Android** via Waydroid: `android-gaming` enables gamepad support in the kernel
  (`wine.config`) and the 1366×768 container resolution;
* `SUBSYSTEM_MAX_INSTANCES=2` allows simultaneous Android container and Wine prefix, with
  `SUBSYSTEM_IDLE_TIMEOUT=1800` so as not to interrupt long sessions.

### 4.4 Edition rootfs

```
etc/prismos/home-tuning.conf     multimedia caches, prefetch, video quality thresholds
```

### 4.5 Typical applications

YouTube, Netflix, Spotify, WhatsApp Web, GeForce NOW, NewPipe, VLC, OsmAnd, 7-Zip.

## 5. Work — business productivity and remote work

**Goal.** Microsoft 365, always-verifiable VPN, encrypted documents, audit, and the
possibility to use Linux containers (Crostini) for development.

### 5.1 USE flags

```
prismos_edition_work m365-suite vpn-advanced encrypted-dl kerberos tpm2-seal audit-logging
waydroid wine proton bottles crostini virtio-gpu
-device-restrict -kiosk-exam -school-lab -cloud-gaming
-arc -arc-plus -arcplusplus -arcvm
```

### 5.2 Packages and configurations

| Area | Components |
|---|---|
| VPN | `net-vpn/openvpn`, `net-vpn/strongswan` with kill-switch: `IPTablesLockdown` and default route through the tunnel, verified by `prismos_policy.json` |
| Encryption | `sys-fs/cryptsetup` for the LUKS vault of Downloads, `app-crypt/tpm2-tools` for TPM 2.0 sealing, `app-crypt/gnupg` |
| Identity | `kerberos` for domain SSO, `audit-logging` for the persistent journal |
| Linux containers | `crostini` + `virtio-gpu`: the only edition where VMs are allowed by policy |
| Windows | Wine `enabled` at boot, `Default` prefix, `win32` applications (Notepad++, PuTTY, 7-Zip, VS Code) |

### 5.3 Device policy

`overlays/overlay-prismos-work/files/etc/chromium/policies/managed/prismos_policy.json`:

* `ArcEnabled=false`, `VirtualMachinesAllowed=true` (Crostini only, with
  `DeviceUnaffiliatedCrostiniAllowed=false`);
* `ProxyMode`/`ProxySettings` aligned to the VPN tunnel, `IncognitoModeAvailability=1`,
  limited `DeveloperToolsAvailability`;
* non-removable `UserDataDir`, `DownloadRestrictions` on the encrypted vault;
* `SSLErrorOverrideAllowed=false`, `SafeBrowsingProtectionLevel=2`.

### 5.4 Edition rootfs

```
etc/chromium/policies/managed/prismos_policy.json    device policy
etc/default/chromium-browser                         switches: ARC off, audit, profile
etc/prismos/work.conf                                VPN, vault, M365 parameters
```

### 5.5 Typical applications

Microsoft 365, Outlook, Zoom, Slack, VS Code Web, PuTTY, Notepad++, K-9 Mail, OsmAnd.

## 6. Slim — on-demand subsystems under 2 GB

**Goal.** Make a machine with 1024-2048 MB of RAM usable: Chromium and Ash have absolute
priority; Waydroid and Wine exist but do not consume a byte until the user opens a
compatible file.

### 6.1 USE flags

```
prismos_edition_slim slim-ondemand low-ram no-extras single-thread-link
waydroid wine proton zram zswap earlyoom
-bottles -crostini -virtio-gpu -cloud-gaming -media-stack
-pipewire -pulseaudio -cups -bluetooth-printers -gstreamer -vaapi
-kiosk-exam -school-lab -m365-suite -vpn-advanced -encrypted-dl
-arc -arc-plus -arcplusplus -arcvm
```

`single-thread-link` prevents Chromium's linker from saturating both logical cores;
`low-ram` shrinks caches; `no-extras` excludes non-essential packages.

### 6.2 Memory

| Tool | Configuration | Effect |
|---|---|---|
| zram | `/etc/zram-generator.conf`, zstd, 50% of RAM | compressed swap at minimal CPU cost on 2 cores |
| zswap | zbud/zsmalloc pool | compression of writeback before disk |
| earlyoom | `/etc/default/earlyoom`: 8% free memory, 3% swap | preventive kill protecting the Ash session from the kernel OOM killer |
| sysctl | `99-prismos-legacy.sysctl` | swappiness, dirty_ratio, THP `madvise`, reduced watchdog |
| Drop caches | `SLIM_DROP_CACHES_ON_START=1` | frees page cache before starting a subsystem |
| Launcher thresholds | `SLIM_LAUNCH_MIN_FREE_MB=256` | below this threshold on-demand start is refused with an explanation |

### 6.3 On-demand contract

1. At boot `prismos-firstboot` reads `WAYDROID_BOOT_STATE=on-demand` and
   `WINE_BOOT_STATE=on-demand`: it runs `systemctl unmask` + `systemctl disable` on the
   units, disables `prismos-subsystems.target` and masks `prismos-subsystem-idle.timer`
   (replaced by immediate teardown);
2. the MIME types `application/vnd.android.package-archive`, `application/x-msi`,
   `application/x-msdownload`, `application/x-msdos-program` and the extensions `.apk`,
   `.xapk`, `.exe`, `.msi`, `.dll`, `.scr`, `.cpl`, `.com` are associated with
   `prismos-slim-launcher`;
3. upon opening a file the launcher checks free RAM, runs `systemctl start` on the unit of
   the requested subsystem, waits for readiness, launches the application and follows its
   PID;
4. on close it sends `SIGTERM`, waits `SUBSYSTEM_TEARDOWN_GRACE_SEC=3` s, sends `SIGKILL`,
   stops the unit, unmounts residual mounts and cleans cgroups and temporary prefixes.
   **One subsystem at a time** is allowed (`SUBSYSTEM_MAX_INSTANCES=1`).

Useful commands: `prismos-slim-launcher status`, `... start waydroid|wine`,
`... stop-all`, `... doctor` (complete diagnostics), `... watch` (follow the lifecycle).

### 6.4 systemd drop-ins

With `USE=slim-ondemand` the ebuild installs three drop-ins in
`/etc/systemd/system/<unit>.service.d/10-slim-ondemand.conf`:

* `prismos-waydroid-container.service`: `DefaultDependencies=no`, `RemainAfterExit=no`,
  `TimeoutStartSec=90`, `TimeoutStopSec=8`, `KillMode=mixed`, `FinalKillSignal=SIGKILL`,
  `OOMPolicy=kill`, `MemoryHigh=768M`, `MemoryMax=1024M`, `MemorySwapMax=256M`,
  `CPUWeight=90`, `TasksMax=512`;
* `prismos-waydroid-session@.service` and `prismos-wine-session@.service`: same principles,
  with `StopWhenUnneeded=yes` and proportioned memory limits.

A drop-in cannot remove the base unit's `[Install]` section: for this reason the Slim
mechanism acts on `enable`/`disable`/`mask` and not on declarative dependencies.

### 6.5 Edition rootfs

```
etc/prismos/slim-tuning.conf        thresholds and priorities
etc/prismos/slim-launcher.conf      on-demand launcher behaviour
etc/zram-generator.conf             zram zstd device
etc/default/earlyoom                preventive kill thresholds
```

### 6.6 Typical applications

Six pins: Drive, YouTube, WhatsApp Web, Microsoft 365, F-Droid, K-9 Mail. The complete
bundle remains selectable at build time with `--apps`.

## 7. PRO — one image, edition chosen at setup

**Goal.** A single all-in-one image for fleets with heterogeneous destinations: the
operator (or the unattended installer) chooses the edition during first setup, and the
machine becomes indistinguishable from a native build of that edition.

### 7.1 How the choice works

1. The image ships `EDITION_ID=pro` in `/etc/prismos/edition.conf` plus, under
   `/usr/share/prismos/editions/<edition>/`, the configuration templates of all four
   targeted editions (`edition.conf`, tuning files, and where present the Chromium
   policy);
2. at first boot, before `prismos-firstboot`, the oneshot unit
   `prismos-edition-setup.service` runs `/usr/libexec/prismos/prismos-edition-setup`,
   which determines the choice in order of precedence:
   * kernel command line `prismos.edition=<edu|home|work|slim>` (for unattended
     installations and imaging);
   * preseed file `/etc/prismos/edition-choice`;
   * interactive prompt on the system console, with a 60 s timeout falling back to
     `home`;
3. the chooser copies the template of the chosen edition over
   `/etc/prismos/edition.conf`, installs its policy into
   `/etc/chromium/policies/managed/` when present, and writes the stamp
   `/var/lib/prismos/state/edition-choice.done`;
4. `prismos-firstboot` then proceeds exactly as on a native edition: subsystem states,
   dock parameters, target aggregation, interface units.

Re-running the choice is possible with `prismos-edition-setup --rechoose` (it removes the
stamp and re-applies on next boot); the operation is logged to the journal with
ident `prismos-edition-setup`.

### 7.2 USE flags

Union of the positive flags of the four editions, minus what conflicts with a generalist
destination:

```
prismos_edition_pro all-in-one edition-chooser media-stack cloud-gaming android-gaming
windows-gaming drm-l3 m365-suite vpn-advanced encrypted-dl kerberos tpm2-seal
audit-logging waydroid wine proton bottles crostini virtio-gpu
gstreamer pipewire pulseaudio vaapi widevine h264 aac mp3 proprietary-codecs
zswap earlyoom -device-restrict -kiosk-exam -school-lab -slim-ondemand -low-ram
-arc -arc-plus -arcplusplus -arcvm
```

`slim-ondemand` and `low-ram` are deliberately excluded: PRO targets machines with at
least 3 GB of RAM. A Slim-like behaviour remains obtainable by choosing `slim` at setup
only on images built for that purpose, because the USE-level reductions (zram, ALSA
direct, no PipeWire) are compile-time decisions.

### 7.3 Edition rootfs

```
etc/prismos/pro.conf                 PRO identity and defaults before the choice
usr/share/prismos/editions/…         templates of the four editions (installed at build)
```

### 7.4 Typical applications

The PRO bundle preselects the union of the four bundles (21 entries) and pins eight:
Drive, YouTube, Microsoft 365, Meet, Spotify, F-Droid, Notepad++, VLC.

## 8. Building and verifying an edition

```bash
./scripts/build_iso.sh edu  --bundle                 # EDU with default bundle
./scripts/build_iso.sh home --apps 1,3,5-7 --jobs 4
./scripts/build_iso.sh work --sync-only              # overlay synchronization only
./scripts/build_iso.sh slim --bundle --image-type base
./scripts/build_iso.sh pro  --bundle                 # all-in-one, choice at setup
./scripts/build_iso.sh all  --bundle                 # all editions, in sequence

./scripts/sync_overlays.sh --check --edition work    # overlay consistency
./scripts/set_edu_policy.sh --strada b --domain ic-manzi.edu --rootfs /build/amd64-prismos
./scripts/verify_legacy_cpu.sh --board amd64-prismos --full
```

The outcome of each build is described by `output/prismOS_<edition>_legacy.img.info`,
which reports board, kernel version, splitconfig, ISA floor, subsystem state, selected
applications and SHA-256 of the image.
