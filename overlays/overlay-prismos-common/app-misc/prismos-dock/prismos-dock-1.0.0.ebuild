# Copyright 2026 The prismOS Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

PYTHON_COMPAT=( python3_{10..12} )

inherit prismos-legacy-cpu systemd python-any-r1

DESCRIPTION="prismOS macOS-like dock: bottom centered autohiding Ash shelf with squircle icon mask"
HOMEPAGE="https://github.com/Davidix07TV/prismOS"
SRC_URI=""

LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"
IUSE="+ash-dock +spotlight-launcher"

DEPEND=""
RDEPEND="
	${PYTHON_DEPS}
	sys-apps/systemd
	x11-themes/hicolor-icon-theme
	x11-themes/adwaita-icon-theme
	dev-libs/glib:2
	spotlight-launcher? ( >=app-misc/prismos-accelerator-daemon-1.0.0 )
"
BDEPEND="
	${PYTHON_DEPS}
	sys-apps/coreutils
"

S="${WORKDIR}"

src_prepare() {
	default
	prismos-legacy-cpu_assert_isa_floor || die "floor ISA SSE4.1 non rispettato"
}

src_install() {
	# --- applicatore della Dock ------------------------------------------------
	# Installato in /usr/libexec: e' un helper di sistema, non un comando utente.
	exeinto /usr/libexec/prismos
	newexe "${FILESDIR}"/prismos-dock-apply prismos-dock-apply
	fperms 0750 /usr/libexec/prismos/prismos-dock-apply

	# Wrapper utente (rieseguire la configurazione o verificarla a mano).
	exeinto /usr/bin
	newexe "${FILESDIR}"/prismos-dock-wrapper prismos-dock
	fperms 0755 /usr/bin/prismos-dock

	# --- configurazione dichiarativa --------------------------------------------
	insinto /usr/share/prismos
	newins "${FILESDIR}"/ash-shelf.conf ash-shelf.conf
	fperms 0644 /usr/share/prismos/ash-shelf.conf

	# --- unita' systemd ----------------------------------------------------------
	# Attivata in fase di installazione (e non solo al primo avvio da
	# prismos-firstboot): l'aspetto della Dock e' un requisito trasversale a tutte
	# le edizioni, quindi deve valere anche su un'immagine ri-sincronizzata o su un
	# profilo utente ricreato. L'unita' e' Type=oneshot con RemainAfterExit=yes e si
	# colloca Before=ui.target, cosi' le preferenze sono gia' su disco quando Ash
	# costruisce la shelf.
	systemd_dounit "${FILESDIR}"/prismos-dock-apply.service
	systemd_enable_service multi-user.target prismos-dock-apply.service

	# --- root del tema icone -------------------------------------------------------
	keepdir /usr/share/icons/prismOS-Squircle/apps/scalable
	keepdir /etc/xdg/gtk-3.0
}

pkg_postinst() {
	if use ash-dock; then
		elog ""
		elog "Dock macOS-like prismOS"
		elog "  posizione      : Bottom (policy ShelfAlignment, vincolante)"
		elog "  autohide       : Always (policy ShelfAutoHideBehavior)"
		elog "  allineamento   : icone centrate, launcher a sinistra, tray a destra"
		elog "  maschera icone : squircle (superellisse n=5, raggio 28% del lato)"
		elog "  policy         : /etc/chromium/policies/managed/zz-prismos-dock.json"
		elog "  configurazione : /usr/share/prismos/ash-shelf.conf"
		elog ""
		elog "Verifica: prismos-dock --verify"
	fi

	if use spotlight-launcher; then
		elog "Launcher centralizzato: Super+Space (app-misc/prismos-accelerator-daemon)"
	fi

	if [[ -d "${EROOT}/run/systemd/system" ]]; then
		systemctl --root="${EROOT}" daemon-reload || true
	fi
}
