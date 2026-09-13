# Building prismOS with no local Linux: GitHub-hosted limits, hourly cloud builders and VMs

<div align="center">

Answer to the most common question: **"can I build the image only with GitHub
Actions?"** — with verified numbers, plus the two routes that work when you
have no Linux machine (hourly cloud server, VM on Windows).

</div>

---

## 1. GitHub-hosted runners alone: what they can and cannot do

The `validate` job (syntax, schemas, ISA floor, the five-edition pre-compilation
pipeline against a stub `cros_sdk`) runs in minutes and is **free on public
repositories** — it always works on GitHub-hosted runners.

The full `build` job cannot, for hard platform limits:

| Limit | GitHub-hosted runners | What a ChromiumOS build needs |
|---|---|---|
| Disk (standard runner) | 14 GB | ≥ 150 GB (checkout ~100 GB + chroot + sysroots + images) |
| Max duration **per job** | **6 hours** (hard cap on hosted runners) | cold build: `repo sync` 1–3 h + `cros_sdk` chroot ~1 h + `build_packages` 4–10 h (it compiles the Chromium browser) + `build_image` |
| Persistence between runs | none; `actions/cache` is capped at **10 GB per repo** | a ~100 GB checkout must persist, otherwise every run restarts from zero and hits the 6-hour wall again |
| Larger runners (more disk/CPU) | billed **per minute even on public repos** ($0.012/min 4 vCPU … $0.252/min 96 vCPU, Linux x64) and require a **GitHub Team/Enterprise Cloud plan** — personal Free/Pro accounts cannot create them | — |

So even paying for larger runners, a cold from-source build does not fit into a
single 6-hour job and nothing persists to split it across runs. This is why the
workflow routes `build` to a self-hosted runner and fails fast with a clear
message when the host is inadequate.

> [!NOTE]
> The workflow's own preflight (disk/RAM check) exists exactly to make this
> fail in the first minute instead of after hours of downloading.

## 2. Hourly cloud builder (no local infrastructure, a few euros)

Rent an Ubuntu server by the hour, build, download the `.img`, destroy it.
Typical cost: **≈ €1–5 per build attempt** depending on size and duration.

**Minimum sizing**: 8 vCPU, 16 GB RAM, ≥ 240 GB NVMe, Ubuntu 22.04/24.04
(Hetzner Cloud, Contabo, OVH, DigitalOcean, Vultr and similar all work; pick
hourly billing).

### 2.1 Route A — direct build (simplest, no Actions involved)

From Windows PowerShell (OpenSSH is built into Windows 10):

```powershell
ssh root@SERVER_IP
```

On the server — `cros_sdk` must run as a **non-root** user with passwordless
sudo:

```bash
apt-get update
apt-get install -y --no-install-recommends git curl python3 xz-utils tmux
adduser --disabled-password --gecos '' prismos
usermod -aG sudo prismos
echo 'prismos ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/prismos
chmod 0440 /etc/sudoers.d/prismos
su - prismos
```

As the `prismos` user (inside `tmux`, the whole sequence takes hours):

```bash
tmux new -s build

# 1. prismOS
git clone https://github.com/Davidix07TV/prismOS.git && cd prismOS

# 2. ChromiumOS checkout (1-3 h)
git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git ~/depot_tools
export PATH=~/depot_tools:$PATH
mkdir -p ~/chromiumos && cd ~/chromiumos
repo init --depth=1 \
  -u https://chromium.googlesource.com/chromiumos/manifest.git \
  -b release-R126-15886.B --groups=all --repo-verify=none
repo sync -j"$(nproc)" --no-tags --no-clone-bundle --optimized-fetch

# 3. prismOS PRO build (2-6 h; detach with Ctrl+B then D, reattach with tmux attach -t build)
cd ~/prismOS
./scripts/build_iso.sh pro --bundle --sdk-dir ~/chromiumos --jobs "$(nproc)"
```

Artifacts: `~/prismOS/output/prismOS_pro_legacy.img` (+ `.info`, ISA reports,
`shelf.json`, `edition.conf`). Download from Windows:

```powershell
scp prismos@SERVER_IP:prismOS/output/prismOS_pro_legacy.img .
```

Then flash with balenaEtcher or Rufus in DD mode (see
[`build-runner.md` §8.4](build-runner.md)) and **destroy the server** from the
provider console so billing stops.

### 2.2 Route B — ephemeral self-hosted runner + workflow

Same server, but registered as runner so the build is dispatched from the
GitHub UI and published as an artifact:

```bash
# as the prismos user, with a registration token from
# GitHub -> Settings -> Actions -> Runners -> New self-hosted runner
cd ~/prismOS
./scripts/setup_runner_host.sh --token <TOKEN> --workdir /opt/actions-runner \
    --chromiumos-dir /home/prismos/chromiumos
```

then **Actions → build-prismos → Run workflow** with
`runner_label=prismos-builder`, `chromiumos_path=/home/prismos/chromiumos`,
`edition=pro`, `upload_image=true`. When the run finishes: download the
artifact, **remove the runner** from Settings → Actions → Runners and destroy
the server.

## 3. VM on Windows (zero cost — and it is *not* a dual boot)

A virtual machine does not touch partitions or the Windows installation: it is
an application window with Ubuntu inside. If the Windows 10/11 PC has
**≥ 16 GB RAM and ≥ 160 GB free disk** it is the cheapest serious option (no
6-hour wall, artifacts stay local).

Check the specs from PowerShell:

```powershell
systeminfo | findstr /C:"Total Physical Memory"
Get-PSDrive C | Select-Object Used,Free
```

Then: VirtualBox (free) → new VM → Ubuntu Server 24.04 → 8+ GB RAM, 160+ GB
VDI (dynamic), all available cores → install → follow
[`build-runner.md`](build-runner.md) sections 3–4 verbatim (`setup_runner_host.sh`
works unchanged), or route 2.1 directly inside the VM.

## 4. Routes at a glance

| Route | Cost | Setup effort | Constraints |
|---|---|---|---|
| GitHub-hosted only | free (`validate`) | none | **full build impossible**: 6 h/job, 14 GB disk, 10 GB cache; larger runners need a Team plan and are billed anyway |
| Hourly cloud server | ≈ €1–5 per attempt | medium (one SSH session) | provider account + payment method |
| VM on Windows | 0 | easy | PC with ≥ 16 GB RAM, ≥ 160 GB free; builds are slower than bare metal |
| Self-hosted on a real Linux PC | 0 | easy | a second machine always on |
