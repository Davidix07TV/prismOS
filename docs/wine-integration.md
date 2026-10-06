# Wine, Proton and Bottles integration in prismOS

Execution of Windows applications (`.exe`, `.msi`, `.dll`, `.scr`, `.cpl`, `.com`) from
the ChromeOS file manager on legacy hardware: CPUs without SSE4.2 and first-generation
Intel HD Graphics (Ironlake, Gen5).

Reference documentation for the unit `prismos-wine-session@.service` and for the programs
`prismos-wine-prepare` and `prismos-wine-run`.

---

## 1. Hardware constraints and consequences

| Constraint | Consequence |
|---|---|
| CPU without SSE4.2/POPCNT/AVX | Wine must be compiled with `-march=nehalem -mno-sse4.2 -mno-popcnt`: the `wine-staging` package inherits the `CFLAGS` of `overlay-prismos-common/make.conf` |
| Gen5: OpenGL 2.1, **no Vulkan** | DXVK and VKD3D-Proton are unusable; the backend is `wined3d` with GLSL and Shader Model 3 |
| Gen5: Mesa driver `crocus` (not `iris`, not `zink`) | `MESA_LOADER_DRIVER_OVERRIDE=crocus`, `LIBGL_DRI3_DISABLE=1` (DRI3 incomplete on Gen5) |
| 2 logical cores, 1-3 GB of RAM | persistent per-session `wineserver`, memory limits on the units, prefixes on disk instead of RAM |
| No AES-NI | Wine's TLS ciphers use the software paths of OpenSSL/GnuTLS: higher handshake latencies are expected |

`prismos-wine-prepare` and `prismos-wine-run` **detect** these constraints at runtime
(`detect_vulkan`, `detect_legacy_intel_gpu`) instead of assuming them: on a machine with
available Vulkan the DXVK backend remains selectable.

## 2. Installed components

| Component | Path | Role |
|---|---|---|
| `prismos-wine-run` | `/usr/bin/prismos-wine-run` | user entry point: prepares the environment, initializes the prefix if needed, runs the PE |
| `prismos-wine-prepare` | `/usr/libexec/prismos/prismos-wine-prepare` | `ExecStartPre` of the session: prefix, Wayland socket, graphics backend, per-UID environment |
| `99prismos-wine` | `/etc/env.d/99prismos-wine` | default environment for all session users |
| `prismos-x-msi.xml` | `/usr/share/mime/packages/prismos-x-msi.xml` | MIME types `application/x-msi`, `application/x-ms-dos-executable`, `application/vnd.android.package-archive` |
| `prismos-wine-runner.desktop` | `/usr/share/applications/` | "Run with Wine" entry of the file manager |
| `prismos-android-runner.desktop` | `/usr/share/applications/` | "Run with Waydroid" entry |
| `prismos-slim-mimeapps.list` | `/etc/xdg/` (Slim) | associates Windows and Android extensions with `prismos-slim-launcher` |
| `prismos-wine-session@.service` | template unit per UID | persistent `wineserver`, `StopWhenUnneeded`, memory limits |

USE flags enabled in `overlay-prismos-common/profiles/base/make.defaults`:

```
wine proton bottles wow64 mingw run-exes win32codecs d3d9 d3d11 fsync esync
opengl gstreamer openal sdl truetype fontconfig cups udisks v4l
```

`run-exes` is the USE that makes `.exe` files directly executable (BINFMT_MISC
registration); editions shrink the set (EDU masks Wine, Slim excludes Bottles, Home and
Work include Proton and Bottles; PRO includes everything).

## 3. Environment

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

* `mscoree=d;mshtml=d` disables Mono and Gecko: they are not downloaded at first start
  (no network prompt, no .NET Framework dependency);
* `WINEFSYNC`/`WINEESYNC` use kernel 6.1 `futex_waitv` to reduce the synchronization
  latency of Windows threads — a measurable benefit on 2 cores;
* `PROTON_USE_WINED3D=1` forces Proton onto the OpenGL path;
* values are overridden per UID by `/run/prismos/wine-<uid>.env`, written by
  `prismos-wine-prepare`, which knows the real Wayland socket and Vulkan availability.

## 4. Lifecycle of a session

### 4.1 `prismos-wine-prepare <uid>`

1. normalizes the UID (default 1000, user `chronos`);
2. `detect_wayland_socket` — locates the Exo socket (`wayland-0`/`wayland-exo`) in the
   user's `XDG_RUNTIME_DIR`;
3. `detect_vulkan` — verifies the presence of a working Vulkan ICD; on Gen5 the outcome is
   negative and the backend becomes `wined3d`;
4. `ensure_prefix` — creates the prefix with `wineboot -u` if missing (`WINEARCH=win64`,
   which on an x86-64 host hosts both 32-bit and 64-bit applications), otherwise reuses it;
5. `write_env` — writes `/run/prismos/wine-<uid>.env` with `WINEPREFIX`,
   `WAYLAND_DISPLAY`, the `wined3d_*` variables and the library paths;
6. `prewarm` — preloads Wine modules into the page cache to reduce first-start latency;
7. `verify_isa` — confirms the CPU has no SSE4.2 and records the backend choice.

### 4.2 `prismos-wine-session@<uid>.service`

```
After=systemd-user-sessions.target ui.target
StopWhenUnneeded=yes            ConditionUser=!root
EnvironmentFile=-/run/prismos/wine-%i.env
ExecStartPre=/usr/libexec/prismos/prismos-wine-prepare %i
ExecStart=/usr/bin/wineserver -f
ExecStop=/usr/bin/wineserver -k
```

The foreground `wineserver` keeps Windows processes alive between launches;
`StopWhenUnneeded=yes` makes the unit stop when no application uses it any more, giving
memory back — essential behaviour on Slim, where the unit is started by
`prismos-slim-launcher` and terminated when the application closes.

### 4.3 `prismos-wine-run`

Sequence (`parse_args` → `detect_vulkan` → `detect_legacy_intel_gpu` → `build_env` →
`wine_binary` → `init_prefix` → `to_wine_path` → `run_target`):

1. chooses the correct Wine binary (`wine` or `wine64`) based on the executable
   architecture, inspecting the PE header;
2. composes the environment: `wined3d_VideoMemorySize=64`,
   `wined3d_MaxShaderModelPS=3`, `wined3d_MaxShaderModelVS=3`,
   `wined3d_Multisampling=disabled`, `wined3d_OffscreenRenderingMode=fbo`,
   `MESA_LOADER_DRIVER_OVERRIDE=crocus`, `LIBGL_DRI3_DISABLE=1`;
3. initializes the requested prefix (`--prefix NAME`) if it does not exist;
4. converts the POSIX path into a Windows path (`C:\...`);
5. on Slim delegates to `prismos-slim-launcher` (`maybe_delegate_slim`) so that the
   start/teardown cycle is managed by the on-demand launcher.

Usage:

```bash
prismos-wine-run ~/Downloads/npp.Installer.exe --prefix Default -- /S
prismos-wine-run "C:/Program Files/Notepad++/notepad++.exe" --verbose
prismos-wine-run --list-prefixes
```

## 5. Opening from the file manager

The MIME types `application/x-ms-dos-executable` (extensions `.exe`, `.dll`, `.scr`,
`.cpl`, `.com`) and `application/x-msi` (`.msi`, `.msp`, `.msm`) are associated with
`prismos-wine-runner.desktop`, which invokes `prismos-wine-run` with the selected file.
With `USE=run-exes` and `CONFIG_BINFMT_MISC=y` the kernel can also execute PEs directly:
prismOS nonetheless prefers the explicit passage through the runner, because it is the
only place where the correct graphics environment (crocus, DRI2, wined3d) is guaranteed.

The `Windows_Pkg` entries of `profiles/app_pool.json` declare everything needed for an
unattended installation:

| Field | Example (Notepad++) |
|---|---|
| `wine_prefix` | `Default` |
| `wine_arch` | `win32` |
| `installer_args` | `["/S"]` |
| `post_install_binary` | `C:/Program Files/Notepad++/notepad++.exe` |
| `wine_dependencies` | `["vcrun2019"]` |
| `mime_types` | `text/plain`, `application/xml`, `application/json` |
| `launch_url` | `wine://C:/Program Files/Notepad++/notepad++.exe` |

The four Windows entries of the pool are Notepad++, PuTTY, 7-Zip Console and Visual Studio
Code (Work and Slim editions according to `flavors`; all of them in PRO).

## 6. Proton and Bottles

* **Proton** is available on the Home, Work and PRO editions. With
  `PROTON_USE_WINED3D=1` Direct3D 9/10/11 titles go through `wined3d`; DXVK is used only
  if `detect_vulkan` finds a working ICD. On Gen5 performance is that of an OpenGL 2.1
  rasterizer with Shader Model 3: playable titles are 2D, isometric and early-2000s 3D.
* **Bottles** is the graphical prefix manager (Home, Work and PRO). Every "bottle"
  corresponds to a prefix under `PRISMOS_WINE_PREFIX_ROOT`; Slim excludes Bottles to
  reduce footprint while remaining compatible with manually created prefixes.
* **Gamepads**: `CONFIG_JOYSTICK_XPAD`, `HIDRAW`, `UHID`, `INPUT_FF_MEMLESS` in the
  `wine.config` fragment enable XInput support for Xbox controllers via Wine.

## 7. Kernel requirements

Fragment `kernel/chromeos/config/chromiumos-x86_64/prismos_legacy/wine.config`:

```
CONFIG_BINFMT_MISC=y            direct execution of PEs
CONFIG_FUTEX=y / FUTEX_PI=y     fsync/esync (futex_waitv in 6.1)
CONFIG_RT_MUTEXES=y / RT_GROUP_SCHED=y / PREEMPT_NOTIFIERS=y
CONFIG_TRANSPARENT_HUGEPAGE=y / ..._MADVISE=y   large prefixes
CONFIG_ZSWAP=y / ZSWAP_DEFAULT_ON=y / ZSWAP_COMPRESSOR_DEFAULT_ZSTD=y
CONFIG_IO_URING=y / AIO=y       asynchronous I/O of modern games
CONFIG_JOYSTICK_XPAD=y / HIDRAW=y / UHID=y / INPUT_FF_MEMLESS=y
CONFIG_PPTP=y / PPPOE=y / NET_IPGRE_DEMUX=y     legacy corporate VPNs
```

## 8. Diagnostics

| Symptom | Cause | Remedy |
|---|---|---|
| `SIGILL` at start of `wine` or of an `.exe` | Wine compiled with SSE4.2/POPCNT | check `CFLAGS` in `overlay-prismos-common/make.conf` and rebuild; `verify_legacy_cpu.sh --pe /usr/bin/wine` |
| Black screen or empty window | DXVK selected without Vulkan | `PROTON_USE_WINED3D=1`; check `detect_vulkan` in `prismos-wine-run --verbose` |
| Extremely slow rendering, missing `GLX_ARB` | Mesa driver `iris` or `zink` loaded | `MESA_LOADER_DRIVER_OVERRIDE=crocus`, `LIBGL_DRI3_DISABLE=1` |
| Mono/Gecko download prompt at first start | `WINEDLLOVERRIDES` not applied | check `/etc/env.d/99prismos-wine` and re-run `env-update` |
| No audio on Slim | `USE=-pulseaudio -pipewire` | expected behaviour: direct ALSA; `aplay -l` to verify the device |
| `.msi` opens with the text editor | MIME type not registered | `update-mime-database /usr/share/mime`; check `prismos-x-msi.xml` |
| Application keeps running after close | persistent `wineserver` | `wineserver -k` or `prismos-slim-launcher stop-all`; on Slim it is automatic |
| Prefix corrupted after an OOM | kill during write | `prismos-wine-run --reset-prefix Default` |

Useful logs: `journalctl -t prismos-wine`, `WINEDEBUG=+loaddll,+seh prismos-wine-run ...
--verbose`, `/var/log/prismos/`.
