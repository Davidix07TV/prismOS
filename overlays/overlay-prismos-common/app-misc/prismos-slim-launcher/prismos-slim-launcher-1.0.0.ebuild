# Copyright 2026 The prismOS Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit prismos-legacy-cpu systemd

DESCRIPTION="prismOS Slim on-demand supervisor for Waydroid (.apk) and Wine (.exe/.msi)"
HOMEPAGE="https://github.com/Davidix07TV/prismOS"
SRC_URI=""

LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"
IUSE="slim-ondemand +waydroid +wine"

# L'helper e' Bash puro: nessun legame con librerie. Le dipendenze runtime sono
# i binari dei sottosistemi, richiamati solo quando il file viene aperto.
DEPEND=""
RDEPEND="
	>=app-shells/bash-5.1[readline]
	sys-apps/systemd
	sys-apps/util-linux
	sys-process/procps
	sys-apps/coreutils
	waydroid? (
		app-emulation/waydroid
		app-emulation/prismos-waydroid-config
		app-emulation/lxc
	)
	wine? (
		|| ( app-emulation/wine-staging app-emulation/wine-vanilla )
		app-emulation/prismos-wine-config
	)
"
BDEPEND="
	sys-apps/sed
	sys-devel/gettext
"

S="${WORKDIR}"

src_prepare() {
	default
	prismos-legacy-cpu_assert_isa_floor || die "floor ISA non rispettato"
}

src_install() {
	# --- helper principale: /usr/bin/prismos-slim-launcher -------------------
	exeinto /usr/bin
	newexe "${FILESDIR}"/prismos-slim-launcher prismos-slim-launcher
	fperms 0755 /usr/bin/prismos-slim-launcher

	# --- configurazione -------------------------------------------------------
	insinto /etc/prismos
	newins "${FILESDIR}"/prismos-slim-launcher.conf slim-launcher.conf
	fperms 0644 /etc/prismos/slim-launcher.conf

	# --- regole sudo minime per l'avvio delle unita' --------------------------
	insinto /etc/sudoers.d
	newins "${FILESDIR}"/prismos-slim-launcher.sudoers prismos-slim-launcher
	fperms 0440 /etc/sudoers.d/prismos-slim-launcher

	# --- drop-in systemd on-demand (solo USE=slim-ondemand) -------------------
	if use slim-ondemand; then
		insinto /etc/systemd/system/prismos-waydroid-container.service.d
		newins "${FILESDIR}"/systemd/prismos-waydroid-container.service.d/10-slim-ondemand.conf \
			10-slim-ondemand.conf

		insinto /etc/systemd/system/prismos-waydroid-session@.service.d
		newins "${FILESDIR}"/systemd/prismos-waydroid-session@.service.d/10-slim-ondemand.conf \
			10-slim-ondemand.conf

		insinto /etc/systemd/system/prismos-wine-session@.service.d
		newins "${FILESDIR}"/systemd/prismos-wine-session@.service.d/10-slim-ondemand.conf \
			10-slim-ondemand.conf
	fi

	# --- registrazione MIME / integrazione col file manager -------------------
	# .apk  -> application/vnd.android.package-archive (gia' in shared-mime-info)
	# .exe  -> application/x-ms-dos-executable         (gia' in shared-mime-info)
	# .msi  -> application/x-msi                       (XML fornito da
	#          app-emulation/prismos-wine-config)
	insinto /usr/share/applications
	newins "${FILESDIR}"/prismos-slim-launcher.desktop prismos-slim-launcher.desktop

	insinto /etc/xdg
	newins "${FILESDIR}"/prismos-slim-mimeapps.list mimeapps.list

	# Directory di runtime e di log.
	dodir /run/prismos/slim-launcher
	fperms 1777 /run/prismos/slim-launcher
	dodir /var/log/prismos
	keepdir /var/log/prismos

	# Documentazione di bordo.
	dodoc "${FILESDIR}"/prismos-slim-launcher.conf
}

pkg_preinst() {
	if use slim-ondemand; then
		elog "prismOS Slim: i sottosistemi Waydroid e Wine NON partiranno al boot."
		elog "Verranno avviati da /usr/bin/prismos-slim-launcher all'apertura di"
		elog "un file .apk/.exe/.msi e terminati alla chiusura dell'applicazione."
	fi
}

pkg_postinst() {
	systemd_reenable prismos-waydroid-container.service 2>/dev/null || true

	if use slim-ondemand; then
		# In modalita' Slim si garantisce che nessun target trascini i
		# sottosistemi al boot: il target prismos-subsystems viene disabilitato.
		if [[ -d "${EROOT}/run/systemd/system" ]]; then
			systemctl --root="${EROOT}" disable prismos-subsystems.target 2>/dev/null || true
			systemctl --root="${EROOT}" daemon-reload 2>/dev/null || true
		fi
		ewarn "Verificare con: systemctl list-dependencies multi-user.target | grep prismos"
	fi

	# Controllo di coerenza ISA sul binario installato (nessuna istruzione
	# SSE4.2/POPCNT deve essere presente negli artefatti dell'immagine).
	prismos-legacy-cpu_scan_installed "${ED}" || ewarn "scan ISA non completato"
}
