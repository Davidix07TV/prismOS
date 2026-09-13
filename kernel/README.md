# prismOS Legacy kernel splitconfig

This directory contains the `chromiumos-x86_64/prismos_legacy` splitconfig of the
ChromeOS kernel used by all prismOS editions.

## Destination inside the cros_sdk

The files must be copied into the kernel tree, preserving the structure:

```bash
CROS_SDK=/home/prismos/chromiumos/cros_sdk
KERNEL=src/third_party/kernel/v6.1

cp -a kernel/chromeos/config/chromiumos-x86_64/prismos_legacy \
      "${CROS_SDK}/${KERNEL}/chromeos/config/chromiumos-x86_64/"
```

`scripts/sync_overlays.sh` performs this copy automatically (with the kernel version
read from `CHROMEOS_KERNEL_VERSION` in `overlays/overlay-prismos-common/make.conf`).

## Activation

The splitconfig selection happens through the overlay variable:

```
CHROMEOS_KERNEL_SPLITCONFIG="chromiumos-x86_64/prismos_legacy"
```

defined in `overlays/overlay-amd64-prismos/make.conf` and therefore available to
`setup_board`/`build_packages` as part of the board make.conf.

## Fragment content

| File                | Content                                                              |
| ------------------- | -------------------------------------------------------------------- |
| `base.config`       | ordered list of fragments to concatenate                              |
| `prereq.config`     | Kconfig prerequisites that make the fragment options visible          |
| `fragment.config`   | Intel Gen5 drivers, HDA, networking, filesystems, ChromeOS security   |
| `legacy-cpu.config` | 2-core scheduler, no AVX/AES-NI/SHA-NI, no VT-x/TXT                   |
| `android.config`    | binder, binderfs, namespaces, cgroup v2, DMA-BUF for Waydroid         |
| `wine.config`       | binfmt_misc (.exe), fsync/esync, THP, zswap, input/gamepad            |
| `slim.config`       | zram/zstd, PSI, capped memcg, reduced kernel debugging                |

## ISA constraint

The kernel is compiled with the `CFLAGS` of `overlays/overlay-prismos-common/make.conf`,
which impose `-march=nehalem -mno-sse4.2 -msse4.1 -mno-popcnt`. No option of this
splitconfig enables code requiring SSE4.2: the `*_NI` or `*_PCLMUL` options that presume a
higher ISA are disabled in `legacy-cpu.config`.

A-posteriori verification of the produced binaries (kernel, modules, userspace) is
entrusted to `scripts/verify_legacy_cpu.sh`.
