# Splitconfig del kernel prismOS Legacy

Questa directory contiene lo splitconfig `chromiumos-x86_64/prismos_legacy` del
kernel ChromeOS usato da tutte le edizioni prismOS.

## Destinazione nel cros_sdk

I file vanno copiati nell'albero del kernel, mantenendo la struttura:

```bash
CROS_SDK=/home/prismos/chromiumos/cros_sdk
KERNEL=src/third_party/kernel/v6.1

cp -a kernel/chromeos/config/chromiumos-x86_64/prismos_legacy \
      "${CROS_SDK}/${KERNEL}/chromeos/config/chromiumos-x86_64/"
```

`scripts/sync_overlays.sh` esegue automaticamente questa copia (con la versione
del kernel letta da `CHROMEOS_KERNEL_VERSION` in
`overlays/overlay-prismos-common/make.conf`).

## Attivazione

La selezione dello splitconfig avviene tramite la variabile di overlay:

```
CHROMEOS_KERNEL_SPLITCONFIG="chromiumos-x86_64/prismos_legacy"
```

definita in `overlays/overlay-amd64-prismos/make.conf` e quindi disponibile a
`setup_board`/`build_packages` come parte del make.conf di board.

## Contenuto dei frammenti

| File                | Contenuto                                                       |
| ------------------- | --------------------------------------------------------------- |
| `base.config`       | elenco ordinato dei frammenti da concatenare                     |
| `prereq.config`     | prerequisiti Kconfig che rendono visibili le opzioni dei frammenti |
| `fragment.config`   | driver Intel Gen5, HDA, rete, filesystem, sicurezza ChromeOS      |
| `legacy-cpu.config` | scheduler a 2 core, niente AVX/AES-NI/SHA-NI, niente VT-x/TXT     |
| `android.config`    | binder, binderfs, namespaces, cgroup v2, DMA-BUF per Waydroid     |
| `wine.config`       | binfmt_misc (.exe), fsync/esync, THP, zswap, input/gamepad        |
| `slim.config`       | zram/zstd, PSI, memcg con tetti, kernel debugging ridotto         |

## Vincolo ISA

Il kernel viene compilato con i `CFLAGS` di
`overlays/overlay-prismos-common/make.conf`, che impongono
`-march=nehalem -mno-sse4.2 -msse4.1 -mno-popcnt`. Nessuna opzione di questo
splitconfig abilita codice che richieda SSE4.2: le opzioni `*_NI` o `*_PCLMUL`
che presuppongono ISA superiore sono disattivate in `legacy-cpu.config`.

La verifica a posteriori dei binari prodotti (kernel, moduli, userspace) e'
demandata a `scripts/verify_legacy_cpu.sh`.
