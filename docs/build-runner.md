# Building prismOS with a self-hosted GitHub Actions runner

<div align="center">

Complete guide to turning a Linux PC into the build machine used by the
[`build-prismos`](../.github/workflows/build-prismos.yml) workflow:
requirements, one-command setup, running a build, maintenance and security.

</div>

---

## 1. Why a self-hosted runner

Compiling ChromiumOS is impossible on GitHub-hosted standard runners:

| Resource | GitHub standard runner | ChromiumOS build | prismOS runner host |
|---|---|---|---|
| Disk | 14 GB | ~100 GiB checkout + ~50 GiB chroot/images | **≥ 150 GiB free** |
| RAM | 7 GB | 8 GiB minimum, 16 GiB comfortable | **≥ 8 GiB** |
| CPU | 2–4 cores | `build_packages` is hours on 2 cores | 4+ cores recommended |
| KVM | absent | not required to build, speeds up tests | optional |
| `cros_sdk` | cannot run (needs passwordless sudo + loop devices) | required | any x86_64 Linux with sudo |

The workflow therefore runs its `validate` job on free GitHub runners and the
`build` job on a runner with the `prismos-builder` label that you register once
with `scripts/setup_runner_host.sh`.

## 2. Requirements

* x86_64 Linux (Ubuntu 22.04/24.04 or Debian 12 recommended; Fedora/Arch work).
* ≥ 150 GiB free disk on the partition that will hold `/opt/chromiumos`,
  ≥ 8 GiB RAM, git/curl/python3/xz (the script installs whatever is missing).
* A GitHub account with access to `Davidix07TV/prismOS` (or your fork).
* Optional: `/dev/kvm` (VT-x/AMD-V enabled in BIOS) for faster test stages.

## 3. One-command setup

1. **Get the registration token** (valid one hour):
   GitHub → repository → **Settings → Actions → Runners → New self-hosted
   runner → Linux → x64**: copy the token shown in the `./config.sh --token …`
   line.

2. **Run the setup script on the PC** (inside `tmux`/`screen`: the ChromiumOS
   download lasts hours):

   ```bash
   git clone https://github.com/Davidix07TV/prismOS.git && cd prismOS
   ./scripts/setup_runner_host.sh --token <REGISTRATION_TOKEN>
   ```

   The script is idempotent and performs, in order:

   | Step | Action | Default path |
   |---|---|---|
   | 1 | preflight: arch, RAM, disk, KVM note, missing packages | — |
   | 2 | passwordless sudo via `/etc/sudoers.d/prismos-runner` (cros_sdk requirement) | — |
   | 3 | download latest `actions-runner`, register with labels `self-hosted,prismos-builder`, install the systemd service | `/opt/actions-runner` |
   | 4 | clone `depot_tools`, `repo init -b release-R126-15886.B` + `repo sync` of ChromiumOS | `/opt/chromiumos` |

   Useful options: `--dry-run` (print the plan without executing),
   `--skip-chromiumos` (runner only), `--branch <release-R…>` (different
   ChromiumOS release), `--workdir` / `--chromiumos-dir` (custom paths),
   `--runner-name`, `--labels`, `--no-service`. `./scripts/setup_runner_host.sh
   --help` lists everything.

3. **Check**: GitHub → Settings → Actions → Runners must show the machine
   **Idle** with the `prismos-builder` label.

## 4. Running a build

GitHub → **Actions → build-prismos → Run workflow**:

| Input | Value for the self-hosted host |
|---|---|
| `edition` | `pro` (default; all-in-one, chosen at first boot) or `edu`/`home`/`work`/`slim` |
| `runner_label` | `prismos-builder` (default) |
| `chromiumos_path` | `/opt/chromiumos` — skips the hours-long `repo sync` |
| `image_type` | `dev` (default, with `dev_install`) or `base` |
| `jobs` | e.g. `$(nproc)` of the host |
| `upload_image` | `true` to publish the `.img` as an artifact |
| `provision_waydroid` | `true` to also prepare the Android x86 image |

The first run creates the `cros_sdk` chroot (30–60 minutes, one-off); later
runs reuse it. Artifacts appear at the bottom of the run page:
`output/prismOS_<edition>_legacy.img` + `.info`, ISA report, `shelf.json`,
`edition.conf`; on failure, `build/logs/` is uploaded automatically.

## 5. Maintenance

```bash
cd /opt/actions-runner && sudo ./svc.sh status          # service state
cd /opt/actions-runner && ./bin/Runner.Listener run     # foreground debugging
cd /opt/chromiumos && /opt/depot_tools/repo sync -j$(nproc)   # update the checkout
cd /opt/actions-runner && sudo ./svc.sh stop && ./config.sh --unattended ... # re-register
```

* **Update the runner**: GitHub shows a banner when the runner version is old;
  re-running `setup_runner_host.sh` re-extracts the latest release.
* **Change branch**: re-run with `--branch release-R…` and delete
  `/opt/chromiumos/.repo/manifests` state only if the sync complains.
* **Remove**: `cd /opt/actions-runner && sudo ./svc.sh uninstall` and delete
  the runner from the GitHub UI.

## 6. Troubleshooting

| Symptom | Cause | Remedy |
|---|---|---|
| Runner never picks up the job | label mismatch | the workflow wants `prismos-builder`; check Settings → Runners |
| `RAM … < 8 GiB` at preflight | host too small | the build cannot run there: pick another machine |
| `repo sync` fails midway | network hiccup | just re-run the script: repo resumes where it stopped |
| Job fails immediately with the disk/RAM error | workflow preflight on the host | free ≥ 150 GiB or move `/opt/chromiumos` to a bigger disk (`--chromiumos-dir`) |
| `cros_sdk` asks for a password | sudoers step skipped | re-run the script; check `/etc/sudoers.d/prismos-runner` |
| Builds slow, qemu tests skipped | no KVM | enable VT-x/AMD-V in BIOS; builds still complete |

## 7. Security notes

* A self-hosted runner executes the code of the workflows it accepts. The
  `build-prismos` workflow only runs on **`workflow_dispatch`** (never on
  pull requests), which removes the classic attack vector of public repos.
* Keep **"Require approval for all outside collaborators"** enabled in
  Settings → Actions → General if the repository is public.
* The runner receives passwordless sudo **only for the registered user**; it
  is intended for a dedicated build machine, not for a daily-driver laptop.

## 8. Windows build host (WSL2, VM or dual-boot)

The runner and `cros_sdk` are Linux-only. A Windows PC can still be the build
host through one of three routes, in order of reliability:

### 8.1 Ubuntu VM (recommended, most predictable)

VirtualBox/VMware Workstation Player are both fine:

| Setting | Value |
|---|---|
| Guest | Ubuntu Server 24.04 LTS (no desktop needed) |
| RAM | ≥ 8 GiB allocated (host must have ≥ 16 GiB) |
| Disk | VDI/VMDK **≥ 160 GiB** (dynamic is fine, keep 150+ GiB free on the host drive) |
| CPU | all cores you can spare, VT-x/AMD-V enabled on the guest |
| Network | NAT is enough (the runner only dials out) |

Nested virtualization is **not** required: builds work without `/dev/kvm`
(only the optional qemu tests inside `cros_sdk` become slow or get skipped).
Inside the VM, follow sections 3–4 verbatim: `setup_runner_host.sh` detects
RAM/disk exactly as on bare metal.

### 8.2 WSL2 (Windows 11, or Windows 10 21H2+)

Viable and the fastest to set up, but not an officially supported `cros_sdk`
host — if `cros_sdk` complains about containers, switch to the VM route.

1. Install: `wsl --install -d Ubuntu-24.04`, then enable systemd inside WSL
   (`/etc/wsl.conf`):

   ```ini
   [boot]
   systemd=true
   ```

   and restart with `wsl --shutdown`.

2. Give WSL the resources: `%USERPROFILE%\.wslconfig`

   ```ini
   [wsl2]
   memory=10GB
   processors=6
   swap=8GB
   ```

3. Make sure the drive holding the WSL VHDX (`%LOCALAPPDATA%` by default) has
   ≥ 150 GiB free; recent WSL grows the VHDX automatically (`wsl --manage
   Ubuntu-24.04 --set-sparse true` helps on smaller drives).

4. **Keep the ChromiumOS checkout inside the WSL filesystem** (`~/chromiumos`
   via `--chromiumos-dir /opt/chromiumos` as usual): never on `/mnt/c`, whose
   9p performance and permission model break `repo sync` and Portage.

5. Run `setup_runner_host.sh` inside WSL. With systemd enabled the service
   installs normally; on Windows 10 without systemd, start the runner in the
   foreground instead: `cd /opt/actions-runner && ./run.sh` (keep a terminal
   open, or use `tmux`).

### 8.3 Dual-boot Ubuntu

Best raw performance (direct disk I/O, real KVM if the CPU has VT-x): install
Ubuntu 24.04 alongside Windows with a ≥ 160 GiB partition and follow
sections 3–4.

### 8.4 Writing the finished image from Windows

When the workflow publishes the artifact, download `prismOS_<edition>_legacy.img`
on Windows and flash it with **balenaEtcher** ("Flash from file") or **Rufus in
DD-image mode**. Never use Rufus "ISO mode" or tools that rewrite the partition
table: the image must land sector-by-sector.

> [!WARNING]
> Flashing erases the entire destination drive: double-check the disk letter
> before writing.
