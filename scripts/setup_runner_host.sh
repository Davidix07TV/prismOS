#!/usr/bin/env bash
# =============================================================================
# setup_runner_host.sh - Turn a Linux PC into a prismOS GitHub Actions
#                        self-hosted build runner.
#
# What it does (idempotent, each step is skipped if already satisfied):
#   1. Preflight: x86_64, >= 8 GiB RAM, >= 150 GiB free disk on the work
#      partition, required tools installed (git curl tar python3 xz repo).
#   2. Passwordless sudo for the invoking user (cros_sdk requirement) via
#      /etc/sudoers.d/prismos-runner, validated with visudo -c.
#   3. Download the latest actions-runner release, extract into --workdir,
#      register against the repository with --token and labels
#      "self-hosted,prismos-builder", install and start the systemd service.
#   4. Bootstrap a persistent ChromiumOS checkout in --chromiumos-dir with
#      depot_tools + repo init/sync (same branch as the workflow fallback).
#      Hours-long on a cold disk: run inside tmux/screen or with nohup.
#
# Afterwards: GitHub -> Actions -> "build-prismos" -> Run workflow,
# with runner_label=prismos-builder and chromiumos_path=<chromiumos-dir>.
#
# Usage:
#   ./scripts/setup_runner_host.sh --token <REGISTRATION_TOKEN> [options]
#   ./scripts/setup_runner_host.sh --dry-run          # print the plan only
#
# The registration token comes from:
#   GitHub repo -> Settings -> Actions -> Runners -> New self-hosted runner
# and expires after one hour.
#
# Requirements: bash 5+, curl, root rights via sudo, >=150 GiB free disk.
# =============================================================================
set -euo pipefail

readonly PROG="setup_runner_host"
readonly VERSION="1.0.0"
readonly RUNNER_API="https://api.github.com/repos/actions/runner/releases/latest"
readonly MANIFEST_URL="https://chromium.googlesource.com/chromiumos/manifest.git"
readonly DEFAULT_BRANCH="release-R126-15886.B"   # keep in sync with the workflow
readonly DEFAULT_LABELS="self-hosted,prismos-builder"

ARG_TOKEN=""
ARG_REPO_URL=""
ARG_RUNNER_NAME=""
ARG_LABELS="${DEFAULT_LABELS}"
ARG_WORKDIR="/opt/actions-runner"
ARG_CHROMEOS_DIR="/opt/chromiumos"
ARG_DEPOT_DIR="/opt/depot_tools"
ARG_BRANCH="${DEFAULT_BRANCH}"
ARG_SKIP_CHROMEOS=0
ARG_NO_SERVICE=0
ARG_DRY_RUN=0

C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RESET=$'\033[0m'
RUNNER_USER="$(id -un)"
RUNNER_GROUP="$(id -gn)"
ok()   { printf '%s[ OK ]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
info() { printf '%s[INFO]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()  { printf '%s[FAIL]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
die()  { err "$*"; exit 1; }
# fail MSG : hard error normally, warning under --dry-run (the plan still
# prints on machines that would not pass the checks).
fail() {
	if (( ARG_DRY_RUN )); then err "$* (dry-run: continuing anyway)"; return 0; fi
	die "$*"
}

# run CMD... : execute (or just print under --dry-run).
run() {
	if (( ARG_DRY_RUN )); then
		printf '%s[dry ]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
		return 0
	fi
	"$@"
}

usage() {
	cat >&2 <<USAGE
${PROG} ${VERSION} - prepare this PC as a prismOS self-hosted build runner

Usage:
  ${PROG} --token TOKEN [options]
  ${PROG} --dry-run [options]

Options:
  --token TOKEN            Runner registration token (GitHub -> Settings ->
                           Actions -> Runners -> New self-hosted runner).
                           Required unless the runner is already registered.
  --repo-url URL           Repository to attach (default: git remote 'origin'
                           of this checkout, else Davidix07TV/prismOS).
  --runner-name NAME       Runner name (default: hostname)
  --labels LIST            Comma-separated labels (default: ${DEFAULT_LABELS})
  --workdir DIR            actions-runner directory (default: ${ARG_WORKDIR})
  --chromiumos-dir DIR     Persistent ChromiumOS checkout (default: ${ARG_CHROMEOS_DIR})
  --branch BRANCH          ChromiumOS manifest branch (default: ${DEFAULT_BRANCH})
  --skip-chromiumos        Do not bootstrap the ChromiumOS checkout
  --no-service             Configure the runner without installing the service
  --dry-run                Print every action without executing it
  --help                   This help
USAGE
}

parse_args() {
	while (( $# )); do
		case "$1" in
			--token)           ARG_TOKEN="${2:-}"; shift 2 ;;
			--repo-url)        ARG_REPO_URL="${2:-}"; shift 2 ;;
			--runner-name)     ARG_RUNNER_NAME="${2:-}"; shift 2 ;;
			--labels)          ARG_LABELS="${2:-}"; shift 2 ;;
			--workdir)         ARG_WORKDIR="${2:-}"; shift 2 ;;
			--chromiumos-dir)  ARG_CHROMEOS_DIR="${2:-}"; shift 2 ;;
			--branch)          ARG_BRANCH="${2:-}"; shift 2 ;;
			--skip-chromiumos) ARG_SKIP_CHROMEOS=1; shift ;;
			--no-service)      ARG_NO_SERVICE=1; shift ;;
			--dry-run)         ARG_DRY_RUN=1; shift ;;
			-h|--help)         usage; exit 0 ;;
			*)                 usage; die "unknown option: $1" ;;
		esac
	done
	ARG_RUNNER_NAME="${ARG_RUNNER_NAME:-$(hostname)}"
	if [[ -z "${ARG_REPO_URL}" ]]; then
		ARG_REPO_URL="$(git -C "$(dirname "$0")/.." remote get-url origin 2>/dev/null || true)"
		ARG_REPO_URL="${ARG_REPO_URL%.git}"
	fi
	ARG_REPO_URL="${ARG_REPO_URL:-https://github.com/Davidix07TV/prismOS}"
}

# -----------------------------------------------------------------------------
# Step 1 - preflight
# -----------------------------------------------------------------------------
step_preflight() {
	info "=== 1/4 preflight ==="
	[[ "$(uname -m)" == "x86_64" ]] || fail "architecture $(uname -m) not supported (x86_64 required)"

	local mem_kb mem_gb
	mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
	mem_gb=$(( mem_kb / 1048576 ))
	if (( mem_gb < 8 )); then
		fail "RAM ${mem_gb} GiB < 8 GiB minimum (cros_sdk + build_packages)"
	fi
	ok "RAM: ${mem_gb} GiB"

	local probe_dir="/opt"
	[[ -d "${ARG_WORKDIR}" ]] && probe_dir="${ARG_WORKDIR}"
	local free_gb
	free_gb=$(df -BG --output=avail "${probe_dir}" 2>/dev/null | tail -1 | tr -dc '0-9')
	free_gb="${free_gb:-0}"
	if (( free_gb < 150 )); then
		err "free disk on ${probe_dir}: ${free_gb} GiB < 150 GiB"
		fail "ChromiumOS checkout + cros_sdk chroot + build output need >=150 GiB"
	fi
	ok "free disk: ${free_gb} GiB on ${probe_dir}"

	if [[ ! -e /dev/kvm ]]; then
		info "/dev/kvm missing: builds work, but qemu-based tests inside cros_sdk"
		info "will be slow or skipped (enable VT-x in BIOS if available)"
	fi

	local missing=() tool
	for tool in git curl tar gzip xz python3 awk; do
		command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
	done
	if (( ${#missing[@]} )); then
		info "installing missing tools: ${missing[*]}"
		if command -v apt-get >/dev/null 2>&1; then
			run sudo apt-get update -qq
			run sudo apt-get install -y --no-install-recommends "${missing[@]}"
		elif command -v dnf >/dev/null 2>&1; then
			run sudo dnf install -y "${missing[@]}"
		elif command -v pacman >/dev/null 2>&1; then
			run sudo pacman -Sy --noconfirm "${missing[@]}"
		else
			fail "cannot install ${missing[*]}: unsupported package manager"
		fi
	fi
	ok "required tools present"
}

# -----------------------------------------------------------------------------
# Step 2 - passwordless sudo (cros_sdk requirement)
# -----------------------------------------------------------------------------
step_sudoers() {
	info "=== 2/4 passwordless sudo for ${USER} ==="
	local sudoers_file="/etc/sudoers.d/prismos-runner"
	if sudo -n true 2>/dev/null; then
		ok "passwordless sudo already active"
		return 0
	fi
	if grep -q "^${RUNNER_USER} " /etc/sudoers.d/* 2>/dev/null; then
		ok "sudoers entry for ${USER} already present"
		return 0
	fi
	run sudo bash -c "printf '%s ALL=(ALL) NOPASSWD: ALL\n' '${RUNNER_USER}' > '${sudoers_file}' && chmod 0440 '${sudoers_file}' && visudo -cf '${sudoers_file}'" \
		&& ok "created ${sudoers_file}" \
		|| die "cannot configure passwordless sudo: run this script with working sudo"
}

# -----------------------------------------------------------------------------
# Step 3 - actions-runner: download, register, service
# -----------------------------------------------------------------------------
step_runner() {
	info "=== 3/4 GitHub Actions runner in ${ARG_WORKDIR} ==="
	run sudo mkdir -p "${ARG_WORKDIR}"
	run sudo chown "${RUNNER_USER}:${RUNNER_GROUP}" "${ARG_WORKDIR}"

	if [[ ! -f "${ARG_WORKDIR}/config.sh" ]] || (( ARG_DRY_RUN )); then
		local tag version url archive
		if (( ARG_DRY_RUN )); then
			tag="vX.Y.Z"; version="X.Y.Z"
		else
			tag="$(curl -fsSL "${RUNNER_API}" | grep -m1 '"tag_name"' | cut -d'"' -f4)"
			[[ -n "${tag}" ]] || die "cannot query the latest actions-runner release (${RUNNER_API})"
			version="${tag#v}"
		fi
		url="https://github.com/actions/runner/releases/download/${tag}/actions-runner-linux-x64-${version}.tar.gz"
		archive="/tmp/actions-runner-${version}.tar.gz"
		info "actions-runner ${tag}: ${url}"
		run curl -fsSL -o "${archive}" "${url}"
		run tar -C "${ARG_WORKDIR}" -xzf "${archive}"
		(( ARG_DRY_RUN )) || rm -f "${archive}"
		ok "runner ${tag} extracted"
	else
		ok "runner already extracted in ${ARG_WORKDIR}"
	fi

	if [[ ! -f "${ARG_WORKDIR}/.runner" ]] || (( ARG_DRY_RUN )); then
		[[ -n "${ARG_TOKEN}" || ${ARG_DRY_RUN} -eq 1 ]] || \
			die "runner not registered and no --token given (GitHub -> Settings -> Actions -> Runners)"
		run bash -c "cd '${ARG_WORKDIR}' && ./config.sh --unattended \
			--url '${ARG_REPO_URL}' \
			--token '${ARG_TOKEN}' \
			--name '${ARG_RUNNER_NAME}' \
			--labels '${ARG_LABELS}' \
			--work '_work' \
			--replace"
		ok "runner registered: ${ARG_RUNNER_NAME} [${ARG_LABELS}] on ${ARG_REPO_URL}"
	else
		ok "runner already registered ($(cat "${ARG_WORKDIR}/.runner" 2>/dev/null | head -c 120)...)"
	fi

	if (( ARG_NO_SERVICE )); then
		info "--no-service: start it manually with: cd ${ARG_WORKDIR} && sudo ./svc.sh install && sudo ./svc.sh start"
		return 0
	fi
	if sudo test -f /etc/systemd/system/actions.runner.*.service 2>/dev/null; then
		ok "runner service already installed"
		run sudo bash -c "cd '${ARG_WORKDIR}' && ./svc.sh status" || \
			run sudo bash -c "cd '${ARG_WORKDIR}' && ./svc.sh start"
	else
		run sudo bash -c "cd '${ARG_WORKDIR}' && ./svc.sh install && ./svc.sh start"
		ok "runner service installed and started"
	fi
}

# -----------------------------------------------------------------------------
# Step 4 - persistent ChromiumOS checkout
# -----------------------------------------------------------------------------
step_chromiumos() {
	if (( ARG_SKIP_CHROMEOS )); then
		info "=== 4/4 ChromiumOS checkout skipped (--skip-chromiumos) ==="
		return 0
	fi
	info "=== 4/4 ChromiumOS checkout in ${ARG_CHROMEOS_DIR} ==="
	if [[ -x "${ARG_CHROMEOS_DIR}/cros_sdk" ]]; then
		ok "checkout already present: ${ARG_CHROMEOS_DIR}/cros_sdk"
		info "refresh it later with: cd ${ARG_CHROMEOS_DIR} && repo sync -j\$(nproc)"
		return 0
	fi
	run sudo mkdir -p "${ARG_CHROMEOS_DIR}" "${ARG_DEPOT_DIR%/*}"
	run sudo chown "${RUNNER_USER}:${RUNNER_GROUP}" "${ARG_CHROMEOS_DIR}"

	if [[ ! -x "${ARG_DEPOT_DIR}/repo" ]]; then
		info "cloning depot_tools into ${ARG_DEPOT_DIR}"
		run sudo rm -rf "${ARG_DEPOT_DIR}"
		run git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "${ARG_DEPOT_DIR}"
	fi
	export PATH="${ARG_DEPOT_DIR}:${PATH}"
	run git config --global user.email "prismos-builder@localhost"
	run git config --global user.name  "prismOS builder"

	info "repo init (branch ${ARG_BRANCH}) + repo sync: hours-long on a cold disk."
	info "Prefer running this script inside tmux/screen so it survives SSH drops."
	run bash -c "cd '${ARG_CHROMEOS_DIR}' && '${ARG_DEPOT_DIR}/repo' init --depth=1 \
		-u '${MANIFEST_URL}' -b '${ARG_BRANCH}' --groups=all --repo-verify=none"
	run bash -c "cd '${ARG_CHROMEOS_DIR}' && '${ARG_DEPOT_DIR}/repo' sync -j\$(nproc) --no-tags --no-clone-bundle --optimized-fetch"

	if (( ARG_DRY_RUN )) || [[ -x "${ARG_CHROMEOS_DIR}/cros_sdk" ]]; then
		ok "ChromiumOS checkout ready: ${ARG_CHROMEOS_DIR}"
	else
		err "repo sync finished but ${ARG_CHROMEOS_DIR}/cros_sdk is missing: check network/disk"
		return 1
	fi
}

summary() {
	cat >&2 <<SUMMARY

==============================================================================
 ${PROG} finished
------------------------------------------------------------------------------
 Runner name      : ${ARG_RUNNER_NAME}
 Runner labels    : ${ARG_LABELS}
 Runner directory : ${ARG_WORKDIR}
 Repository       : ${ARG_REPO_URL}
 ChromiumOS       : ${ARG_CHROMEOS_DIR} (branch ${ARG_BRANCH})

 Build an image:
   GitHub -> Actions -> "build-prismos" -> Run workflow
     runner_label    = prismos-builder
     chromiumos_path = ${ARG_CHROMEOS_DIR}
     edition         = pro   (all-in-one, edition chosen at first boot)

 The first cros_sdk invocation downloads/creates the chroot (~30-60 min).
 Service management:  cd ${ARG_WORKDIR} && sudo ./svc.sh {status|stop|start}
==============================================================================
SUMMARY
}

main() {
	parse_args "$@"
	local_mode=""
	(( ARG_DRY_RUN )) && local_mode=" [DRY-RUN]"
	info "${PROG} ${VERSION} - repo ${ARG_REPO_URL}, runner '${ARG_RUNNER_NAME}'${local_mode}"
	step_preflight
	step_sudoers
	step_runner
	step_chromiumos
	summary
}

main "$@"
