# Architettura prismOS

## 1) Config layer

La configurazione è divisa in due livelli:

1. `profiles/common.conf`: variabili globali distro/release.
2. `profiles/<edition>.conf`: differenze per singola edizione (`work`, `games`, `edu`, `slim`).

## 2) OS creation layer (rootfs reale)

`scripts/create_os.sh` crea il sistema operativo vero e proprio per ogni profilo:

1. bootstrap Debian (`mmdebstrap` o fallback `debootstrap`);
2. installazione pacchetti da `BASE_PACKAGES + PACKAGES` del profilo;
3. applicazione metadata prismOS e overlay;
4. inclusione policy EDU per il profilo scuola;
5. packaging rootfs (`filesystem.squashfs` o fallback `filesystem.tar.gz`) + `SHA256SUMS`.

Output:

- `build/rootfs/<profile>/` root filesystem completo
- `build/artifacts/<profile>/` artifact per pipeline live/installer

## 3) Release/ISO layer

`scripts/build_iso.sh` compone artefatti release:

1. merge overlay comuni e profilo;
2. rendering metadati `.meta/profile.env`;
3. template boot (`templates/grub.cfg`);
4. build `.iso` (`xorriso`) o fallback `.iso.tar.gz`;
5. checksum per artifact + `manifest.json`.

## 4) EDU policy layer

`profiles/edu.policy.json` viene gestita da `scripts/set_edu_policy.sh` e supporta:

- `allow_apps`
- `deny_web`
- `disable_settings`
- `session.allow_guest`
- `session.max_idle_minutes`

## 5) Quality/PR layer

- `scripts/validate_profiles.sh`: validazione profili e policy JSON.
- `scripts/resolve_pr_conflicts.sh`: check marker git (`<<<<<<<`, `=======`, `>>>>>>>`) per prevenire merge rotti in PR.
