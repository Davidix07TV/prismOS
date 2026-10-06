# Waydroid integration in prismOS

Complete replacement of ARC/ARC++/ARCVM with an Android container based on **Waydroid**
and **LineageOS 16.0 (Android 9) 32-bit x86** images rebuilt with an SSE4.1 ISA floor.

Reference documentation for the units `prismos-waydroid-container.service` and
`prismos-waydroid-session@.service`.

---

## 1. Why ARC is unusable on CPUs without SSE4.2

ARC compiles `zygote`, the ART library and the system services with
`-msse4.2 -mpopcnt`. On Intel Pentium P6100, Celeron P4500 or first-generation Core
(Arrandale) the first `PCMPISTRI` or `CRC32` instruction raises `#UD`, the kernel delivers
`SIGILL` and `zygote` dies. Since `zygote` is the parent process of every Android
application, the framework restarts the container forever: the observed cycle is
`arc-start → zygote crash → restart → arc-stop`, with CPU saturation and logs full of
`Fatal signal 4 (SIGILL)`.

No countermeasure exists at policy or ARC configuration level: the problem is in the
already-compiled code. The only solution is an Android container compiled for a lower ISA
— that is, Waydroid with x86 images at SSE4.1 floor — plus the complete removal of ARC
from the system (negative USE, `use.mask`, policies, `--arc-availability=none`).

## 2. Image selection

| Parameter | Value | Reason |
|---|---|---|
| Distribution | LineageOS 16.0 (Android 9, API 28) | last release for which Waydroid **32-bit x86** images exist; newer releases are published x86_64 only |
| Architecture | **x86 (32-bit)** | official x86_64 images are compiled with SSE4.2 and POPCNT |
| `vendor_type` | `MAINLINE` | the host kernel (6.1) provides binderfs and ashmem: no second Halium kernel needed |
| `gralloc` | `minigbm` | buffer allocation compatible with ChromeOS's Exo compositor |
| Variant | `VANILLA` | no GApps: on a school fleet Google services must be distributed as web applications, not as an Android framework |
| ARM translation | **disabled** | libhoudini and libndk_translation require SSE4.2/POPCNT |
| Exposed ABI | `x86,armeabi-v7a,armeabi` | empty `abilist64`: no 64-bit application can be installed |

Practical consequence: only Android applications shipped with native x86 libraries or
pure Java/Kotlin are installable. For this reason `profiles/app_pool.json` selects F-Droid
packages (F-Droid, VLC, NewPipe, AnkiDroid, OsmAnd, K-9 Mail) and declares for each of them
`arm_translation_required: false` and the actually available `abi` list.

## 3. Provisioning

`scripts/provision_waydroid_image.sh` is the single tool to obtain conforming images.

```bash
# prismOS mirror (recommended: 16.0 x86 images rebuilt at SSE4.1 floor)
sudo ./scripts/provision_waydroid_image.sh --edition slim

# upstream SourceForge (requires --date or --query-latest; always use --deep-verify)
./scripts/provision_waydroid_image.sh --edition home --source upstream --query-latest --deep-verify

# already downloaded archive
sudo ./scripts/provision_waydroid_image.sh --edition work \
     --source local --archive ~/lineage-16.0-waydroid_x86.zip

# compilation from a LineageOS checkout
sudo ./scripts/provision_waydroid_image.sh --edition edu --build \
     --source-dir ~/lineageos-16.0 --jobs 4
```

The phases are: download with resume and SHA-256 verification (curl/wget), extraction
(zip/tar/xz/img), installation of `system.img` and `vendor.img` into
`/var/lib/waydroid/images`, installation of the ART properties, ABI verification, writing
of the `ISA_FLOOR` marker. With `--deep-verify` the system image is mounted read-only via
`losetup` and scanned by `scripts/verify_legacy_cpu.sh --rootfs --full`.

Upstream URL scheme (SourceForge, project `waydroid`):

```
https://sourceforge.net/projects/waydroid/files/images/system/lineage/waydroid_x86/
    lineage-<version>-<YYYYMMDD>-<VANILLA|GAPPS>-waydroid_x86-system.zip/download
https://sourceforge.net/projects/waydroid/files/images/vendor/waydroid_x86/
    lineage-<version>-<YYYYMMDD>-MAINLINE-waydroid_x86-vendor.zip/download
```

The prismOS mirror (`--source prismos`, default) hosts the 16.0 x86 rebuild with
`.img.xz` extensions and the related `.sha256`; the address can be overridden with
`--mirror`.

### 3.1 ART properties of the ISA floor

Properties are generated from the templates of the package
`app-emulation/prismos-waydroid-config` and overridden per edition:

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
ro.config.low_ram=true            (Slim and EDU)
ro.zygote=zygote32
```

`variant` selects the ISA subset that `dex2oat` assumes as baseline for AOT-generated
code: the values `nehalem`, `sandybridge`, `ivybridge` and `haswell` imply SSE4.2 and
POPCNT and **must never be used**. The explicit feature list adds SSE4.1 and negates
everything else, so behaviour does not depend on the CPUID visible to the container
(which on some Arrandale dies reports SSE4.2 anyway).

### 3.2 Memory budget per edition

| Edition | `heapgrowthlimit` | `heapsize` | `dex2oat-threads` | `dex2oat-filter` |
|---|---|---|---|---|
| EDU | 192 MiB | 384 MiB | 1 | `verify` |
| Home | 256 MiB | 512 MiB | 2 | `speed-profile` |
| Work | 192 MiB | 384 MiB | 2 | `speed-profile` |
| Slim | 128 MiB | 256 MiB | 1 | `verify` |

The `verify` filter renounces AOT compilation of application code: `dex2oat` produces only
verified metadata and execution stays interpreted/JIT. On 2 cores and 1 GB this is the
choice that keeps the host system responsive; the cost is a slower first start of
applications.

### 3.3 The `ISA_FLOOR` marker

`/var/lib/waydroid/images/ISA_FLOOR` declares the floor of the installed images:

```
PRISMOS_ISA_FLOOR="x86-SSE4.1"
PRISMOS_ISA_FORBIDDEN="sse4_2 popcnt avx avx2"
```

`prismos-waydroid-prepare` reads it before starting the container: if it declares an ISA
above SSE4.1 the start is **refused**; if it is missing the start is refused unless
`PRISMOS_ALLOW_UNVERIFIED_IMAGES=1`. It is the protection against the most frequent
regression: an update reinstalling the official Waydroid images.

## 4. Container configuration

`/var/lib/waydroid/waydroid.cfg`, installed by the package:

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

`system_ota = 0` disables OTA updates: images are managed exclusively by
`provision_waydroid_image.sh`, which is the only place where the ISA floor is guaranteed.

The LXC configuration generated by `prismos-waydroid-prepare` clones **only** the `ipc`,
`uts`, `net` and `mount` namespaces:

```ini
lxc.namespace.clone = ipc uts net mount
lxc.cgroup2.memory.high = 768M
lxc.cgroup2.memory.max = 1024M
lxc.cgroup2.cpuset.cpus = 0-1
```

The PID namespace is deliberately not cloned: Android processes remain visible from the
host, and that is what allows `prismos-slim-launcher` to follow their PID and terminate
them when the application closes.

## 5. Lifecycle

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

`Delegate=yes` is necessary for LXC to manage its own cgroup hierarchy inside the slice;
`StartLimitBurst=3` in 180 s prevents a defective container from entering a reboot cycle.

### 5.2 `prismos-waydroid-prepare`

Sequence executed as root before start:

1. `setup_binder` — loads `binder_linux`, mounts binderfs at `/dev/binderfs`, creates the
   `binder`, `vndbinder`, `hwbinder` nodes; if binderfs is unavailable it falls back to the
   static node `/dev/binder`, otherwise it terminates with a message pointing to
   `android.config`;
2. `setup_ashmem` — loads `ashmem_linux` if present, otherwise registers the `memfd`
   fallback (kernel ≥ 5.18 no longer requires ashmem);
3. `setup_network` — creates the `waydroid0` bridge, assigns `192.168.240.1/24`, enables
   `ip_forward`, installs NAT rules when `iptables` is available (on ChromeOS it may be
   restricted: the container then uses the host's DNS and proxy);
4. `setup_dirs` — verifies `system.img`, `vendor.img` and the `ISA_FLOOR` marker;
5. generates `/var/lib/waydroid/lxc/waydroid/config` if missing (never overwrites an
   existing configuration);
6. `write_session_env` — locates the Exo Wayland socket and writes
   `/run/prismos/waydroid-<uid>.env`; without a socket the Ash session is not active and
   the start is refused with an explanation;
7. `verify_host_isa` — confirms the host CPU has at least SSE4.1 and records in the log
   the deliberate choice of using SSE4.1-floor images even on newer CPUs.

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

`BindsTo` guarantees that stopping the container also stops the session, and
`StopWhenUnneeded` that the session turns off when no client requires it: it is the
mechanism on which Slim's on-demand teardown relies.

### 5.4 Manual and per-edition start

| Edition | Behaviour |
|---|---|
| EDU, Home | `prismos-firstboot` enables `prismos-subsystems.target` and the container: Waydroid starts at boot |
| Work, Slim | the container is installed but disabled; it starts upon opening an `.apk`/`.xapk` |
| PRO | follows the edition chosen at first setup |
| All | `systemctl start prismos-waydroid-container.service` remains available; on Slim it is mediated by `prismos-slim-launcher` |

Launching a specific application:

```bash
waydroid app launch org.fdroid.fdroid/org.fdroid.fdroid.views.main.MainActivity
/usr/bin/prismos-slim-launcher start waydroid --apk /home/chronos/Downloads/app.apk
```

## 6. Kernel requirements

Fragment `kernel/chromeos/config/chromiumos-x86_64/prismos_legacy/android.config`:

```
CONFIG_ANDROID=y
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDERFS=y
CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"
CONFIG_ASHMEM=y                     (or memfd fallback on kernel >= 5.18)
CONFIG_NAMESPACES=y
CONFIG_CGROUPS=y / CONFIG_CGROUP_SCHED=y / CONFIG_MEMCG=y
CONFIG_DMA_SHARED_BUFFER=y
CONFIG_NETFILTER / NF_NAT           (bridge and NAT for waydroid0)
CONFIG_TUN=y
```

Verification on a booted system:

```bash
zcat /proc/config.gz | grep -E 'ANDROID_BINDER|BINDERFS|ASHMEM'
mount | grep binderfs
ls -l /dev/binderfs
```

## 7. Diagnostics

| Symptom | Cause | Remedy |
|---|---|---|
| `SIGILL` in `zygote`, container rebooting continuously | x86_64 images or `dalvik.vm.isa.x86.variant=nehalem` | `provision_waydroid_image.sh --force` with an x86 source; check `ISA_FLOOR` and the ART properties |
| `binder: failed to open binder driver` | binderfs not enabled or not mounted | check `android.config`; `modprobe binder_linux`; `mount -t binder binder /dev/binderfs` |
| `no wayland socket` | Ash session not yet active | the session requires `ui.target`; restart after login or use `prismos-slim-launcher start waydroid` |
| ARM-only application does not install | `arm_translation_required` | expected behaviour: ARM translation requires SSE4.2; use the web equivalent or an x86 F-Droid package |
| Container slow at first start | `dex2oat` with `verify` filter on 2 cores | expected wait at first start of applications; do not raise `dex2oat-threads` above 2 |
| Video fluid only at 720p inside the container | SwiftShader on Gen5 | `gralloc=minigbm` + software rendering: the container does not use the host GPU for 3D |
| `MemoryMax` reached, applications killed | container budget | raise `MemoryMax` only with ≥ 3 GB of RAM; on Slim it is deliberately 1024M |
| OTA updates the images and the container stops starting | `system_ota` re-enabled | reset `system_ota = 0` in `waydroid.cfg` and re-run provisioning |

Useful logs: `journalctl -t prismos-waydroid`, `/var/log/prismos/waydroid-lxc.log`,
internal `logcat` (`waydroid shell -- logcat`).
