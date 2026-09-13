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
| Disk (standard runner) | ~90 GB free — **87 GiB measured** by the workflow's own preflight on a GitHub-hosted run ([run 34760595919](https://github.com/Davidix07TV/prismOS/actions/runs/34760595919), 2026-09-13) | ≥ 150 GB (checkout ~100 GB + chroot + sysroots + images) |
| Max duration **per job** | **6 hours** (hard cap on hosted runners) | cold build: `repo sync` 1–3 h + `cros_sdk` chroot ~1 h + `build_packages` 4–10 h (it compiles the Chromium browser) + `build_image` |
| Persistence between runs | none; `actions/cache` is capped at **10 GB per repo** | a ~100 GB checkout must persist, otherwise every run restarts from zero and hits the 6-hour wall again |
| Larger runners (more disk/CPU) | billed **per minute even on public repos** ($0.012/min 4 vCPU … $0.252/min 96 vCPU, Linux x64) and require a **GitHub Team/Enterprise Cloud plan** — personal Free/Pro accounts cannot create them | — |

So even paying for larger runners, a cold from-source build does not fit into a
single 6-hour job and nothing persists to split it across runs. This is why the
workflow routes `build` to a self-hosted runner and fails fast with a clear
message when the host is inadequate.

> [!NOTE]
> The workflow's own preflight (disk/RAM check) exists exactly to make this
> fail in the first minute instead of after hours of downloading. Measured
> evidence: run [34760595919](https://github.com/Davidix07TV/prismOS/actions/runs/34760595919)
> executed the real build job on GitHub-hosted `ubuntu-latest` and its
> preflight refused it with *"ChromiumOS builds need >= 150 GiB free (found 87)"*.

### 1.1 "Can't we just optimize the disk usage or split the build into stages?"

This suggestion comes up often (including from AI assistants). Checked against
the measured numbers, it does not survive:

* **The disk floor is the product, not our scripts.** The pipeline already
  uses every legitimate reduction (`--depth=1`, `--no-clone-bundle`, no test
  images). What remains: sources ~50–70 GB + `cros_sdk` chroot ~25–30 GB +
  board sysroot and Chromium build output ~30–45 GB + final images ~10–15 GB
  = a **~120–160 GB peak in which everything coexists simultaneously** during
  `build_packages`. Cleaning *between* steps lowers the average, not the peak,
  and the peak is what must fit next to the 87 GiB a hosted runner provides.
* **Splitting across workflow runs needs persistence that does not exist.**
  `actions/cache` is capped at 10 GB against ~100 GB of state (checkout +
  chroot + binary-package cache). The only conceivable variant — checkpointing
  the state through multi-tens-of-GB workflow artifacts between 4–6 manually
  dispatched runs and resuming `build_packages` from Portage's binary package
  cache — is fragile unsupported territory (chroot mount state, hardlinks,
  artifact-storage fair use), would take days to engineer and would most
  likely die mid-Chromium anyway. The 6-hour per-job cap and the 4 hosted
  cores (Chromium alone: 6–12 h) kill the remaining variants.
* **What splitting *is* good for**: the workflow already splits validation
  (free, hosted, minutes) from compilation (persistent runner, hours). The
  split that matters is between machines, not between stages.

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
| GitHub-hosted only | free (`validate`) | none | **full build impossible**: 6 h/job, 87 GiB measured disk (run 34760595919), 10 GB cache; larger runners need a Team plan and are billed anyway |
| **Cloud free trial** (§5) | **€0** (card required for identity check) | medium (one SSH session) | 30–90 day window, one account per person |
| Hourly cloud server | ≈ €1–5 per attempt | medium (one SSH session) | provider account + payment method |
| VM on Windows | 0 | easy | PC with ≥ 16 GB RAM, ≥ 160 GB free; builds are slower than bare metal |
| Self-hosted on a real Linux PC | 0 | easy | a second machine always on |

## 5. The genuinely free online route: cloud trial credits

No free *tier* anywhere can host this build — GitHub-hosted runners measure 87 GiB
of free disk against a ≥150 GiB floor and cap every job at 6 hours, GitHub
Codespaces gives 15 GB of storage, GitLab.com
SaaS runners are smaller still, Google Cloud's always-free e2-micro has 1 GB
RAM / 30 GB disk, and Oracle's always-free tier is either 1 GB x86 or ARM
Ampere (ChromiumOS cannot cross-build an amd64 image from an arm64 host).
Google also no longer publishes official pre-built ChromiumOS images to
download (the public `chromiumos-image` bucket and the `build_artifacts`
documentation were retired), so there is no "download someone else's build"
shortcut either.

What *is* free, with a card used only for identity verification:

| Provider | Trial credit | Window | Right-sized machine |
|---|---|---|---|
| Google Cloud | $300 | 90 days | `e2-standard-8` (8 vCPU / 32 GB) + 300 GB pd-balanced, Ubuntu 24.04 |
| Oracle Cloud | $300 | 30 days | `VM.Standard3.Flex` 8 OCPU / 32 GB (x86, **not** Ampere ARM) + 300 GB boot volume, Ubuntu 24.04 |
| Azure | $200 | 30 days | `D8s_v5` (8 vCPU / 32 GB) + 300 GB Premium SSD |

A full prismOS build consumes roughly **$3–8** of credit (≈ 8–12 hours on
8 vCPU including `repo sync`, plus ~300 GB of disk for a few hours), so one
trial covers dozens of attempts.

### 5.1 Google Cloud, entirely from the browser (no local installs)

1. <https://console.cloud.google.com> → *Start free* (card = identity check,
   spending stays at $0 unless you manually upgrade the account).
2. **Compute Engine → VM instances → Create**:
   region `us-central1`, machine `e2-standard-8`, boot disk **Ubuntu 24.04
   LTS, 300 GB balanced persistent disk**, no public HTTP(S) needed.
3. Click **SSH** (browser terminal) and follow **§2.1 route A** verbatim
   (create the `prismos` user, `repo sync`, `build_iso.sh pro --bundle`).
4. When the build finishes, open **Cloud Shell** (icon `>_` in the top bar):

   ```bash
   gcloud compute scp prismos@INSTANCE_NAME:prismOS/output/prismOS_pro_legacy.img . \
       --zone=us-central1-a
   ```

   then download the file to your Windows PC from Cloud Shell's ⋮ menu →
   *Download*.
5. **Delete the VM and its disk** (Compute Engine → VM instances → Delete,
   including boot disk) so the credit stops being consumed.

### 5.2 Oracle Cloud

1. <https://signup.cloud.oracle.com> → free trial ($300 / 30 days).
2. **Compute → Instances → Create instance**: Ubuntu 24.04, shape
   **VM.Standard3.Flex (x86) with 8 OCPU / 32 GB** — do *not* pick an Ampere
   (ARM) shape; boot volume 300 GB; save the generated SSH key.
3. `ssh ubuntu@PUBLIC_IP` and follow **§2.1 route A** (the `ubuntu` user
   already has sudo: you may skip the user-creation block and run it directly,
   but keep the build out of `/home` root-owned paths).
4. `scp ubuntu@PUBLIC_IP:prismOS/output/prismOS_pro_legacy.img .` from
   Windows PowerShell, then **Terminate** the instance (and its boot volume).

> [!WARNING]
> Trial accounts sometimes hit "out of capacity" on Flex/standard shapes in
> the home region: pick another availability domain or region and retry.
> Destroy the machine as soon as the `.img` is downloaded — leaving a 300 GB
> VM idle burns credit for nothing.


## 6. No credit card at all

Every trial in section 5 asks for a card as identity check. If that is a hard
no, exactly two routes remain:

### 6.1 Azure for Students — $100 of credit, **no card** (verified 2026)

* **Who**: students enrolled at an accredited school/university (18+ for the
  full offer; a Student Starter variant exists for younger students), plus
  educators through the Microsoft education programs.
* **How**: <https://azure.microsoft.com/free/students> → sign in with a
  Microsoft account → verify with the **school/university email**; if the
  domain is not recognized, the flow accepts a **student ID upload** or an
  existing **GitHub Student Developer Pack** verification.
* **What you get**: $100 of credit valid 12 months, renewable yearly while
  enrolled, with a spending limit — when the credit ends the services simply
  stop; there is no card on file, so no bill can ever arrive.
* **Build math**: `D8s_v5` (8 vCPU / 32 GB) + a 300–512 GB SSD cost roughly
  $0.30/hour combined → a full prismOS build (8–12 h) burns **$3–4 of the
  $100**: enough for 20+ attempts.
* **Flow**: identical to §5.1 — create the VM in the portal, SSH from the
  browser terminal, follow §2.1 route A, copy the image out with Azure Cloud
  Shell (`scp`), delete VM + disk.

> [!WARNING]
> Only legitimate verification: the "temporary .edu email" generators that
> surface in search results violate Microsoft's terms and get the account
> banned together with everything built on it.

### 6.2 Local VM on the Windows PC — €0, no card, no accounts

The VirtualBox route of §3 needs nothing but hardware: if the PC has ≥ 16 GB
of RAM and ≥ 160 GB of free disk it is the simplest no-card option in
absolute terms (check with `systeminfo` and `Get-PSDrive C` from PowerShell).
No time limits, no credits, the `.img` never leaves the machine.

If neither applies — no suitable PC and no school email — then there is no
free online way to compile ChromiumOS today: the honest options become "wait
for access to a suitable machine" or the paid hourly cloud of §2 (a few euros,
one build, server destroyed immediately afterwards).

### 6.3 Browser Linux sandboxes (DistroSea and similar): not usable

Services like DistroSea run a real distro in the browser for free and with no
card, but they are designed for *test-driving* distributions, not building:

| Constraint | Consequence for a ChromiumOS build |
|---|---|
| Sessions are live and ephemeral: everything is lost at close | a build takes 8–15 h; even `repo sync` alone (50–100 GB) cannot survive a session |
| Free VMs are small (paid accounts advertise "increased VM resources, longer sessions") | far below the 8 GiB RAM / 150 GB disk floor |
| Free sessions frequently lack internet connectivity (an account perk) | the sources cannot even be downloaded |

Same verdict for comparable offerings (online VM trials, distro playgrounds):
none provides the persistence, size and uninterrupted runtime this build needs.