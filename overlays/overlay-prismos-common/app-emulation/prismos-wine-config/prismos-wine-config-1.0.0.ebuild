# Copyright 2026 The prismOS Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit prismos-legacy-cpu systemd xdg

DESCRIPTION="prismOS Wine/Proton integration: on-demand sessions, .exe/.msi handlers, Gen5 GPU tuning"
HOMEPAGE="https://github.com/Davidix07TV/prismOS"
SRC_URI=""

LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"
IUSE="+proton +wow64 +run-exes slim-ondemand"

DEPEND=""
RDEPEND="
	|| ( >=app-emulation/wine-staging-8.0 app-emulation/wine-vanilla )
	app-emulation/winetricks
	sys-apps/util-linux
	sys-process/procps
	sys-process/psmisc
	x11-misc/shared-mime-info
	>=dev-libs/glib-2.60:2
	proton? (
		app-emulation/dxvk
		app-emulation/vkd3d-proton
	)
	wow64? ( app-emulation/wine-staging[abi_x86_32(-),abi_x86_64(-)] )
"
BDEPEND="
	sys-apps/coreutils
	sys-apps/sed
"

# Il pacchetto non compila nulla: installa script, unita' e registrazioni MIME.
S="${WORKDIR}"

src_prepare() {
	default
	prismos-legacy-cpu_assert_isa_floor || die "floor ISA SSE4.1 non rispettato"
}

src_install() {
	# --- eseguibili utente ---------------------------------------------------
	exeinto /usr/bin
	newexe "${FILESDIR}"/prismos-wine-run prismos-wine-run
	fperms 0755 /usr/bin/prismos-wine-run

	# --- helper di sessione (root) -------------------------------------------
	exeinto /usr/libexec/prismos
	newexe "${FILESDIR}"/prismos-wine-prepare prismos-wine-prepare
	fperms 0750 /usr/libexec/prismos/prismos-wine-prepare

	# --- unita' systemd on-demand ---------------------------------------------
	systemd_dounit "${FILESDIR}"/prismos-wine-session@.service

	# --- registrazione MIME (.msi non presente in shared-mime-info) ------------
	insinto /usr/share/mime/packages
	newins "${FILESDIR}"/prismos-x-msi.xml prismos-x-msi.xml

	# --- voci "Apri con" per il file manager di Ash ----------------------------
	insinto /usr/share/applications
	newins "${FILESDIR}"/prismos-wine-runner.desktop prismos-wine-runner.desktop
	newins "${FILESDIR}"/prismos-android-runner.desktop prismos-android-runner.desktop

	# --- ambiente globale -------------------------------------------------------
	insinto /etc/env.d
	newins "${FILESDIR}"/99prismos-wine.envd 99prismos-wine

	# --- root dei prefix ----------------------------------------------------------
	dodir /home/chronos/user/WineBottles
	fperms 0700 /home/chronos/user/WineBottles

	if use run-exes; then
		elog "USE=run-exes: i file .exe/.msi sono eseguibili direttamente dal file manager"
	fi
}

pkg_postinst() {
	xdg_pkg_postinst

	# Aggiorna il database MIME e le associazioni.
	if [[ -x "${EROOT}/usr/bin/update-mime-database" ]]; then
		update-mime-database "${EROOT}/usr/share/mime" >/dev/null 2>&1 || \
			ewarn "update-mime-database non riuscito"
	fi
	if [[ -x "${EROOT}/usr/bin/update-desktop-database" ]]; then
		update-desktop-database "${EROOT}/usr/share/applications" >/dev/null 2>&1 || true
	fi

	if use slim-ondemand; then
		elog "prismOS Slim: prismos-wine-session@.service NON parte al boot."
		elog "Viene avviata da /usr/bin/prismos-slim-launcher all'apertura di un"
		elog ".exe/.msi e fermata (wineserver -k) alla chiusura dell'applicazione."
	fi

	if use proton; then
		ewarn "DXVK e VKD3D-Proton sono installati ma vengono DISATTIVATI a runtime"
		ewarn "su Intel HD Graphics Gen5 (nessun driver Vulkan per Ironlake)."
		ewarn "prismos-wine-prepare imposta automaticamente PROTON_USE_WINED3D=1."
	fi

	prismos-legacy-cpu_runtime_check || true
	prismos-legacy-cpu_scan_installed "${ED}" || ewarn "scan ISA non completato"
}

pkg_postrm() {
	xdg_pkg_postrm
	if [[ -x "${EROOT}/usr/bin/update-mime-database" ]]; then
		update-mime-database "${EROOT}/usr/share/mime" >/dev/null 2>&1 || true
	fi
}
