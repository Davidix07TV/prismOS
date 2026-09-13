# prismOS architecture

Technical reference document. It describes the Portage profile layering, the build
pipeline, the runtime layout, the systemd unit graph and the mechanisms by which the
**SSE4.1** ISA floor is imposed and verified.

For everyday usage see [`../README.md`](../README.md); for the differences between
editions see [`edizioni.md`](edizioni.md); for the compatibility subsystems see
[`waydroid-integration.md`](waydroid-integration.md) and
[`wine-integration.md`](wine-integration.md).

---

## 1. Design principles

1. **The ISA floor is an explicit contract.** No part of the system deduces CPU
   capabilities at build time with `-march=native`; every compilation level receives flags
   written down in `overlays/overlay-prismos-common/make.conf`, and conformity of the
   result is measured by `scripts/verify_legacy_cpu.sh` on the binaries, not declared.
2. **Separation between profile and logic.** Edition overlays contain exclusively
   `make.conf`, `profiles/base/make.defaults` and the rootfs tree in `files/`. Everything
   that is computation (generation of `shelf.json`, composition of the board `make.conf`,
   dock policies, subsystem state) lives in `scripts/build_iso.sh`.
3. **No superfluous daemons.** Subsystem units are installed with `systemd_dounit` without
   any `systemd_enable_service`: Portage never enables them and `systemctl preset` does
   not know them. They nonetheless declare `[Install] WantedBy=prismos-subsystems.target`,
   because that is the attachment point used by `prismos-firstboot` to enable, disable or
   mask them according to `/etc/prismos/edition.conf`.
4. **A single source for applications.** `profiles/app_pool.json` feeds the build menu,
   `shelf.json`, the dock policy, the icon theme and the runtime catalogue. Adding an
   application means editing that file, not five.
5. **Idempotence.** Every script can be re-run: overlays are recreated from scratch,
   configuration files regenerated, copies performed with `install` rather than `cp -a`.

## 2. Portage profile layering

ChromiumOS resolves a board profile by concatenating the profiles declared in the board's
own `parent`. prismOS exploits this mechanism to sum three layers:

```
chromiumos (upstream profile)
   └── overlay-prismos-common/profiles/base        ISA CFLAGS, ARC USE off, Waydroid, Wine
          └── overlay-prismos-<edition>/profiles/base   edition USE and packages
                 └── overlay-amd64-prismos/profiles/base amd64-prismos board
```

The `parent` is materialized by `build_iso.sh` in
`overlays/overlay-amd64-prismos/profiles/base/parent` with the form:

```
chromiumos
../prismos-common/base
../prismos-edu/base
```

### 2.1 `make.conf` concatenation order

The board `make.conf` is generated (not copied) and the inclusion sequence determines who
wins on conflict:

| Order | File | Role |
|---|---|---|
| 1 | `overlay-prismos-common/make.conf` | `COMMON_FLAGS`, `PRISMOS_ISA_FLOOR`, `CPU_FLAGS_X86`, base `USE` |
| 2 | `overlay-prismos-<edition>/make.conf` | edition USE negations and additions, `PACKAGE_*` |
| 3 | `overlay-amd64-prismos/make.conf` (generated) | board identity, `CHROMEOS_KERNEL_SPLITCONFIG`, `CHROMEOS_IMAGE_NAME`, parallelism |

**Binding rule:** layer 3 is concatenated *last*, therefore it must never re-enable a USE
flag that the edition negated. Its assignments are limited to board parameters and
informative variables (`PRISMOS_EDITION`, `PRISMOS_BUILD_STAMP`).

The definitive ISA flags, obtained by variable composition, are:

```
PRISMOS_ISA_FLOOR="-march=nehalem -mno-sse4.2 -msse4.1 -mno-popcnt"
COMMON_FLAGS="-O2 -pipe ${PRISMOS_ISA_FLOOR} -fno-semantic-interposition"
HARDENING_FLAGS="-Wl,-z,relro -Wl,-z,now -fstack-protector-strong -fPIE"
CFLAGS="${COMMON_FLAGS} ${HARDENING_FLAGS}"
CXXFLAGS="${CFLAGS}"
LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,--hash-style=gnu"
CPU_FLAGS_X86="mmx mmxext sse sse2 sse3 ssse3 sse4_1 -sse4_2 -avx -avx2 -aes -f16c -popcnt"
```

> `-O2 -pipe -march=nehalem -mno-sse4.2 -msse4.1` is the required core; `-mno-popcnt`
> completes the floor, because `-mno-sse4.2` does not disable POPCNT.

### 2.2 `use.mask` and `package.use.mask`

`profiles/base/use.mask` masks the ARC USE flags at profile level: even an ebuild
declaring them could not enable them. `package.use.mask` masks them for specific packages
(`www-client/chromeos-chrome`, `app-emulation/arc-*`), which is the way ARC normally
re-enters a ChromiumOS build.

## 3. Build pipeline

`scripts/build_iso.sh <edition>` executes the following sequence (real function names):

| # | Function | Effect |
|---|---|---|
| 1 | `parse_args`, `validate_environment` | resolution of `--sdk-dir`, presence check of `cros_sdk`, `jq`, `python3`, disk space, permissions |
| 2 | `load_edition_profile` | reading of `profiles/<edition>.conf` and validation of mandatory keys |
| 3 | `load_app_table` | loading and validation of `profiles/app_pool.json` against `app_pool.schema.json` |
| 4 | `print_app_menu` + `select_apps_interactive` (or `select_apps_from_bundle` / `select_apps_from_list`) | application selection; with non-interactive stdin the bundle is automatic |
| 5 | `summarize_selection` | on-screen summary with type and subsystem of each entry |
| 6 | `generate_shelf_json` | writing of `build/<edition>-<stamp>/etc/skel/.config/chromiumos/shelf.json` |
| 7 | `generate_edition_conf` | writing of `build/<edition>-<stamp>/etc/prismos/edition.conf` |
| 8 | `sync_overlays` | publication of the overlays into the `cros_sdk` (relative symlinks or copies), recreation of the board overlay, generation of `parent` and `make.conf`, copy of edition rootfs, installation of `app_pool.json`, `ash-shelf.conf` and scripts into `/usr/share/prismos`, icon generation if missing |
| 9 | `install_edition_policy` | EDU Route A/B, Work policy, dock policy `zz-prismos-dock.json` |
| 10 | `sync_kernel_splitconfig` | copy of `kernel/chromeos/config/chromiumos-x86_64/prismos_legacy` into `src/third_party/kernel/v6.1/chromeos/config/chromiumos-x86_64/` |
| — | *(with `--sync-only` the pipeline stops here)* | |
| 11 | `apply_subsystem_boot_states` | masks, enables or leaves on-demand the Waydroid/Wine units according to `WAYDROID_BOOT_STATE` and `WINE_BOOT_STATE` |
| 12 | `run_setup_board` | `setup_board --board=amd64-prismos --force` |
| 13 | `run_build_packages` | `build_packages --board=amd64-prismos --nowithautotest --skip_chroot_upgrade --jobs=N`, then `emerge --noreplace` of extra packages and `--unmerge` of removed ones |
| 14 | `run_build_image` | `build_image --board=amd64-prismos --noenable_rootfs_verification dev` |
| 15 | `collect_image` | rename into `output/prismOS_<edition>_legacy.img`, generation of `.info`, `.shelf.json`, `.edition.conf`, SHA-256 |
| 16 | `verify_build` | `verify_legacy_cpu.sh --rootfs`/`--board`, ARC removal verification, policy check |
| 17 | `cleanup_build` | removal of staging unless `--keep-build` was requested |

Multiple editions (`all`) are built in sequence; a failure does not interrupt the
following ones and the overall outcome is summarized with exit codes `0`/`1`.

### 3.1 Publishing the overlays into the chroot

The chroot sees the host checkout at `/mnt/host/source`. `sync_overlays` publishes the
prismOS overlays into `src/overlays/` with **relative symlinks** (so the same structure
works inside and outside the chroot) or with real copies when `--copy-overlays` is passed.
In addition:

* `src/overlays/overlay-prismos-active` → link to the current edition overlay, used by
  `scripts/sync_overlays.sh --check` to detect the active edition without querying the
  build system;
* `src/overlays/overlay-amd64-prismos` → **recreated from scratch at every build**: it is
  never modified incrementally, so a previous edition leaves no residue.

## 4. Runtime layout

```
/etc/prismos/
├── edition.conf              subsystem state, minimum RAM, edition tuning
├── slim-launcher.conf        on-demand thresholds and behaviour (Slim only)
└── edu.conf / home-tuning.conf / work.conf / slim-tuning.conf

/etc/chromium/policies/managed/
├── prismos_policy.json       edition policy (EDU Route B, Work)
└── zz-prismos-dock.json      ShelfAlignment, ShelfAutoHideBehavior, PinnedLauncherApps,
                              WebAppInstallForceList (the zz- prefix guarantees that
                              Chromium loads them last and therefore wins conflicts)

/etc/skel/.config/chromiumos/shelf.json
                              dock preferences for every new user profile

/etc/env.d/50prismos-gpu      crocus, i965, LIBGL_DRI3_DISABLE, CHROMEOS_GPU_FLAGS
/etc/env.d/99prismos-wine     WINEARCH, WINEPREFIX, WINEDEBUG, wined3d backend
/etc/sysctl.d/99-prismos-legacy.sysctl   swappiness, dirty_ratio, THP, watchdog
/etc/default/chromium-browser Chromium switches (EDU enrollment, ARC off)
/etc/default/earlyoom         kill thresholds (Slim)
/etc/zram-generator.conf      zram zstd sized on RAM (Slim)

/usr/share/prismos/
├── app_pool.json             runtime catalogue of applications
├── ash-shelf.conf            dock appearance parameters
├── accelerators.json         map of the 12 global shortcuts
├── editions/<edition>/       PRO: configuration templates selectable at first setup
└── scripts/                  build_iso.sh, provision_waydroid_image.sh,
                              verify_legacy_cpu.sh, set_edu_policy.sh,
                              generate_app_icons.sh, sync_overlays.sh, lib/

/usr/share/icons/prismOS-Squircle/
├── index.theme               XDG theme inheriting from hicolor
└── apps/scalable/*.svg       33 icons (25 applications + 8 system)

/usr/bin/
├── prismos-slim-launcher     user entry point: on-demand start and teardown
├── prismos-wine-run          runs a PE with the correct parameters
└── prismos-accelerators      query of registered shortcuts

/usr/libexec/prismos/
├── prismos-dock-apply        writes Ash preferences and the dock policy
├── prismos-accelerator-daemon  evdev grab → uinput injection (KEY_SEARCH)
├── prismos-firstboot         applies subsystem state at first boot
├── prismos-edition-setup     PRO: edition chooser at first setup (before firstboot)
├── prismos-waydroid-prepare  prepares rootfs, LXC, props, verifies ISA_FLOOR
├── prismos-waydroid-cleanup  unmounts, cleans residual mounts and cgroups
├── prismos-wine-prepare      creates or restores the Wine prefix (wined3d/DXVK)
└── prismos-subsystem-idle-check  detects idle subsystems

/var/lib/waydroid/images/     system.img, vendor.img, waydroid_base.prop,
                              waydroid_mainline.prop, ISA_FLOOR
/var/lib/prismos/             runtime state (state/firstboot.done marker, caches)
/home/chronos/user/WineBottles/Default   default Wine prefix (WINEARCH=win64)
/var/cache/prismos/mesa       shader cache (capped at 128 MiB)
```

## 5. systemd unit graph

```
multi-user.target
   │
   ├── prismos-edition-setup.service        (PRO only; oneshot, Before=prismos-firstboot,
   │                                         ConditionPathExists=!…/edition-choice.done)
   │        └── writes /etc/prismos/edition.conf from the chosen template
   │
   ├── prismos-firstboot.service            (oneshot, RemainAfterExit=yes,
   │                                          ConditionPathExists=!/var/lib/prismos/state/firstboot.done
   │                                          ConditionPathExists=/etc/prismos/edition.conf)
   │        └── decides subsystem state reading /etc/prismos/edition.conf
   │
   ├── prismos-dock-apply.service           (oneshot, After=prismos-firstboot.service,
   │                                          ConditionPathExists=/usr/libexec/prismos/prismos-dock-apply)
   ├── prismos-accelerator-daemon.service   (simple, SupplementaryGroups=input)
   │
   ├── prismos-subsystems.target            (logical container of subsystems: installed
   │                                          but NOT enabled by Portage)
   │        ├── prismos-waydroid-container.service   (Type=simple, MemoryMax, CPUQuota)
   │        │        └── prismos-waydroid-session@<uid>.service
   │        ├── prismos-wine-session@<uid>.service   (StopWhenUnneeded, MemoryMax=512M)
   │        └── prismos-subsystem-idle.timer → prismos-subsystem-idle.service
   │                 └── after SUBSYSTEM_IDLE_TIMEOUT seconds of inactivity stops the subsystem
   │
   └── prismos-subsystems.slice             (MemoryHigh=1G, MemoryMax=1536M, MemorySwapMax=256M,
                                              TasksMax=2048, CPUWeight=90, IOWeight=80)
```

Boot state per edition, read from `/etc/prismos/edition.conf`:

| Key | EDU | Home | Work | Slim | PRO (after setup) |
|---|---|---|---|---|---|
| `WAYDROID_BOOT_STATE` | `enabled` | `enabled` | `on-demand` | `on-demand` | the chosen edition's |
| `WINE_BOOT_STATE` | `masked` | `enabled` | `enabled` | `on-demand` | the chosen edition's |
| `SUBSYSTEM_IDLE_TIMEOUT` | 600 | 1800 | 900 | 120 | the chosen edition's |
| `SUBSYSTEM_MAX_INSTANCES` | 1 | 2 | 1 | 1 | the chosen edition's |

* `enabled` → `prismos-firstboot` runs `systemctl unmask` + `systemctl enable`, so the
  subsystem starts at first boot and at every subsequent boot;
* `on-demand` → `systemctl unmask` + `systemctl disable`: the unit stays available but is
  not dragged at boot. It starts only upon opening a compatible file type
  (`.apk`/`.xapk` or `.exe`/`.msi`/`.dll`/`.scr`/`.cpl`/`.com`), started by
  `prismos-slim-launcher`, which stops it when the application closes; the timer
  `prismos-subsystem-idle.timer` (active from 3 minutes after boot, every 60 s) stops
  anyway any subsystem idle for `SUBSYSTEM_IDLE_TIMEOUT` seconds;
* `disabled` → `systemctl disable` without mask: manual start allowed, no automatic start;
* `masked` → `systemctl mask`: the subsystem cannot start even manually.

The only units enabled by Portage are the interface and lifecycle ones:
`prismos-firstboot.service`, `prismos-accelerator-daemon.service` and
`prismos-dock-apply.service` on `multi-user.target`, `prismos-subsystem-idle.timer` on
`timers.target`. `prismos-dock-apply.service` is declared `Before=ui.target
session_manager.service chrome.service`: it writes policy and preferences **before** Ash
builds the shelf, so the user never sees the repositioning.

`prismos-firstboot` is also the course corrector: at every first boot it re-reads
`edition.conf`, enables or disables `prismos-subsystems.target` (the aggregator to which
subsystem units are attached via `WantedBy=`), applies the state of each subsystem and
re-enables the interface units. On Slim it masks `prismos-subsystem-idle.timer`, replaced
by the immediate teardown of `prismos-slim-launcher`.

## 6. ARC removal

Three independent levels, because none of the three is sufficient alone:

| Level | Mechanism |
|---|---|
| USE | `USE="${USE} -arc -arc-plus -arcplusplus -arc-container -arcvm -arc-kernel-features -houdini -libhoudini"` in `overlay-prismos-common/profiles/base/make.defaults`, repeated with edition-specific negations in the editions |
| Profile | global `use.mask` + targeted `package.use.mask` on `www-client/chromeos-chrome` and `app-emulation/arc-*` |
| Runtime | device policies `ArcEnabled=false`, `UnaffiliatedArcAllowed=false`, `UnaffiliatedDeviceArcAllowed=false`, disabling `ArcPolicy`, `VirtualMachinesAllowed=false`, `DeviceUnaffiliatedCrostiniAllowed=false`, `CrostiniAllowed=false`; switch `--arc-availability=none` in `/etc/default/chromium-browser` |

Verification is entrusted to `scripts/lib/isa_arc_probe.py`, which tokenizes the `USE=`
line instead of using regular expressions: `\barc\b` in grep also matches the token `-arc`
(the word boundary falls between `-` and `a`) and would produce false positives.

## 7. Imposition and verification of the ISA floor

### 7.1 Imposition levels

| Level | Tool |
|---|---|
| Portage | `CFLAGS`/`CXXFLAGS`/`LDFLAGS` + `CPU_FLAGS_X86` in `overlay-prismos-common/make.conf` |
| Chromium | GN arguments: `x64_arch="generic"`, `target_cpu="x64"`, `use_thin_lto=false`, disabling of ISA-specific optimizations |
| Rust | `RUSTFLAGS="-C target-cpu=x86-64 -C target-feature=+sse4.1,-sse4.2,-popcnt"` |
| Go | `GOAMD64=v1` (SSE2 baseline) |
| ART/Android | `dalvik.vm.isa.x86.variant=x86` with explicit features `-sse4_2,-popcnt,-avx,-avx2` and 32-bit x86 images |
| Kernel | splitconfig without `X86_INTEL_*` enabling AVX/SHA, with explicit selection of SSE4.1 ciphers |
| Eclass | `prismos-legacy-cpu.eclass`: `pkg_pretend` refusing emerge on non-conforming hosts and `src_configure` applying ISA flags automatically to prismOS packages |

### 7.2 Verification

`scripts/verify_legacy_cpu.sh` operates in two phases to contain execution time:

1. **byte-pattern search** on every candidate ELF/PE file (no disassembler invoked, block
   reads with a safety `--max-bytes`): CRC32 (`F2 [48] 0F 38 F1/F0`), POPCNT
   (`F3 [48] 0F B8`), `PCMPxSTRx` (`66 [48] 0F 3A 60-63`), AES-NI
   (`66 0F 38 DB/DD/DF/DC`, `66 0F 3A DF`), PCLMUL, AVX/AVX2 (VEX prefix), BMI, F16C;
2. **confirmation with `objdump`** on candidates only, by mnemonic, so as to discard
   accidental matches in data.

Libraries with IFUNC dispatch — glibc, OpenSSL, zlib-ng, LLVM/Mesa and DRI drivers —
legitimately contain SSE4.2 paths selected at runtime by the IFUNC resolver and are
classified `dispatched`: they are **not** failures. Evidence on `chrome`, Wine, Waydroid
and the prismOS packages is fatal instead, since those are compiled with a fixed `-march`
and have no dispatch.

Modes: `--host`, `--config`, `--pe FILE`, `--rootfs PATH [--full]`, `--board NAME`,
`--image FILE`; options `--strict`, `--jobs`, `--max-bytes`, `--report`, `--json`,
`--check-isa`. Exit codes: `0` conforming, `1` non-conforming, `2` usage error.

## 8. Kernel

`CHROMEOS_KERNEL_SPLITCONFIG="chromiumos-x86_64/prismos_legacy"` selects the fragment
directory that `build_iso.sh` copies into
`src/third_party/kernel/v6.1/chromeos/config/chromiumos-x86_64/prismos_legacy/`. The
ChromiumOS configuration system concatenates the fragments listed in `base.config`,
applies `prereq.config` to resolve dependencies and generates the final `.config`.

| Fragment | Scope |
|---|---|
| `base.config` | ordered list of fragments to concatenate |
| `prereq.config` | configuration dependencies (cgroups, namespaces, netfilter, crypto) |
| `fragment.config` | DRM_I915 and Gen5, HDA, networking, filesystems, SELinux |
| `legacy-cpu.config` | 2-core scheduler, exclusion of AVX/AES-NI, `INTEL_IOMMU=y` with `DEFAULT_ON=n`, ITCO_WDT |
| `android.config` | `ANDROID_BINDER_IPC`, binderfs, ashmem/memfd, namespaces, cgroup v2, DMA-BUF |
| `wine.config` | `BINFMT_MISC`, futex2/fsync, THP `madvise`, zswap, gamepads |
| `slim.config` | zram/zstd, PSI, memcg, tracers off but `BPF_SYSCALL=y` (required by Chrome's sandbox) |

Point-by-point rationale of every entry: [`../kernel/README.md`](../kernel/README.md).

## 9. Extending prismOS

| Goal | Operation |
|---|---|
| Add a web application | new entry in `profiles/app_pool.json` (type `Web_App`) + regenerate icons with `generate_app_icons.sh` |
| Add an Android application | `Android_Pkg` entry with `android_package`/`android_activity`, `arm_translation_required: false`, available for x86 on F-Droid |
| Add a Windows application | `Windows_Pkg` entry with `wine_prefix`, `wine_arch` (`win32`/`win64`), `installer_args`, `post_install_binary` |
| Change an edition bundle | `flavor_bundles.<edition>` in `app_pool.json` (`preselected`, `default_pinned`, `max_pinned`, `blocked_by_policy`) |
| New edition | `profiles/<id>.conf`, `overlays/overlay-prismos-<id>/{make.conf,profiles/base/make.defaults,files/}`, extension of the `PRISMOS_EDITIONS` array in `scripts/lib/prismos_common.sh` |
| New global shortcut | entry in `accelerators.json` (`id`, `trigger`, `action`, `keys`\|`command`, `description`) |
| New kernel tuning | new fragment in `kernel/.../prismos_legacy/` listed in `base.config`, or `KERNEL_FRAGMENTS` in the edition profile |
| New Chromium policy | edition template or `--allowlist`/`--blocklist` of `set_edu_policy.sh`; keys must also be added to `overlay-prismos-edu/chrome_policy.json` |

After every overlay modification it is sufficient to run:

```bash
./scripts/sync_overlays.sh --check          # repository consistency
./scripts/build_iso.sh <edition> --sync-only   # publication into the SDK without compiling
```

## 10. Known constraints of the reference hardware

| Component | Constraint | Design consequence |
|---|---|---|
| Intel Pentium P6100 / Celeron P4500 | SSE4.1, no SSE4.2/POPCNT/AVX/AES-NI | ISA floor described above; software AES ciphers |
| Intel HD Graphics (Ironlake, Gen5) | OpenGL 2.1, no Vulkan, VA-API partial (MPEG-2/VC-1; H.264 not reliable) | Mesa `crocus` (never `iris`/`zink`), `LIBGL_DRI3_DISABLE=1`, software video decoding with SSE4.1 SIMD, `wined3d` instead of DXVK |
| Widevine on uncertified platform | level L3 | DRM streaming limited to 720p: expected behaviour, not a defect |
| 1-3 GB of RAM | no margin for ARC | 32-bit x86 Waydroid, reduced ART heap, `ro.config.low_ram=true`, zram zstd, earlyoom |
| 2 logical cores | minimal parallelism | `dex2oat-threads=1/2`, `cpuset.cpus=0-1`, `single-thread-link` on Slim |
| HM55/PM55 chipset | Intel VT-d IOMMU absent or partial | `INTEL_IOMMU=y` but `DEFAULT_ON=n` to avoid losing performance without gain |
