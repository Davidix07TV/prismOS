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
