# Copyright 2026 The prismOS Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit prismos-legacy-cpu systemd

DESCRIPTION="prismOS configuration for Waydroid running LineageOS 16.0 (Android 9) x86 without SSE4.2"
HOMEPAGE="https://github.com/Davidix07TV/prismOS"
SRC_URI=""

LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"
IUSE="+binderfs +ashmem"

DEPEND=""
RDEPEND="
	>=app-emulation/lxc-4.0.11
	>=app-emulation/waydroid-1.3.4
	sys-apps/iproute2
	net-firewall/iptables
	sys-apps/util-linux
	sys-process/procps
	virtual/udev
	>=app-misc/prismos-runtime-config-1.0.0
"
BDEPEND="sys-apps/coreutils"

# ARC/ARC++ di Google NON e' una dipendenza e non deve esserlo: vedere
# profiles/base/use.mask. Chi aggiunge arc* alle dipendenze rompe la build.
PDEPEND=""

S="${WORKDIR}"

src_prepare() {
	default
	prismos-legacy-cpu_assert_isa_floor || die "floor ISA SSE4.1 non rispettato"
}

src_install() {
	# --- configurazione Waydroid -------------------------------------------
	# /var/lib/waydroid e' il percorso hardcoded da waydroid (tools/__init__.py:
	# WAYDROID_ROOT = "/var/lib/waydroid").
	insinto /var/lib/waydroid
	newins "${FILESDIR}"/waydroid.cfg waydroid.cfg
	fperms 0644 /var/lib/waydroid/waydroid.cfg

	# Proprieta' Android: sostituiscono quelle scaricate da `waydroid init`,
	# che dichiarano abilist ARM+houdini e features ISA non disponibili.
	newins "${FILESDIR}"/waydroid_base.prop waydroid_base.prop
	newins "${FILESDIR}"/waydroid_mainline.prop waydroid_mainline.prop
	fperms 0644 /var/lib/waydroid/waydroid_base.prop
	fperms 0644 /var/lib/waydroid/waydroid_mainline.prop

	keepdir /var/lib/waydroid/images
	keepdir /var/lib/waydroid/lxc/waydroid
	keepdir /var/lib/waydroid/overlay
	keepdir /var/lib/waydroid/rootfs
	keepdir /var/lib/waydroid/data
	keepdir /var/lib/waydroid/cache

	# --- helper di preparazione/teardown ------------------------------------
	exeinto /usr/libexec/prismos
	newexe "${FILESDIR}"/prismos-waydroid-prepare prismos-waydroid-prepare
	newexe "${FILESDIR}"/prismos-waydroid-cleanup prismos-waydroid-cleanup
	fperms 0750 /usr/libexec/prismos/prismos-waydroid-prepare
	fperms 0750 /usr/libexec/prismos/prismos-waydroid-cleanup

	# --- unita' systemd -------------------------------------------------------
	systemd_dounit "${FILESDIR}"/prismos-waydroid-container.service
	systemd_dounit "${FILESDIR}"/prismos-waydroid-session@.service

	# --- log ------------------------------------------------------------------
	dodir /var/log/prismos
	keepdir /var/log/prismos

	dodoc "${FILESDIR}"/waydroid.cfg
}

pkg_postinst() {
	elog ""
	elog "Sottosistema Android prismOS (Waydroid + LineageOS 16.0 x86)"
	elog ""
	elog "1) Provisioning delle immagini (una tantum, richiede rete):"
	elog "     /usr/share/prismos/scripts/provision_waydroid_image.sh \\"
	elog "         --edition \${PRISMOS_EDITION_ID:-slim}"
	elog "   Lo script scarica system.img/vendor.img LineageOS 16.0 x86 ricostruite"
	elog "   con floor ISA SSE4.1 e scrive il marcatore /var/lib/waydroid/images/ISA_FLOOR."
	elog ""
	elog "2) Stato di avvio per edizione:"
	elog "     EDU  -> container attivo al boot       (systemctl enable prismos-waydroid-container)"
	elog "     Home -> container attivo al boot + idle timeout 900 s"
	elog "     Work -> on-demand (idle timeout 300 s)"
	elog "     Slim -> SPENTO: solo /usr/bin/prismos-slim-launcher lo avvia, e lo"
	elog "             termina alla chiusura dell'app Android"
	elog ""
	ewarn "Traduzione ARM (libhoudini/libndk_translation) NON disponibile: richiede"
	ewarn "SSE4.2/POPCNT. Usare app Android con ABI x86 o le web app equivalenti."

	if use binderfs; then
		if [[ -d "${EROOT}/run/systemd/system" ]]; then
			systemctl --root="${EROOT}" daemon-reload || true
		fi
	fi

	prismos-legacy-cpu_runtime_check || true
}

pkg_postrm() {
	if [[ -d "${EROOT}/run/systemd/system" ]]; then
		systemctl --root="${EROOT}" daemon-reload || true
	fi
}
