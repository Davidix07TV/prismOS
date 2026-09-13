# Copyright 2026 The prismOS Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

PYTHON_COMPAT=( python3_{10..12} )

inherit prismos-legacy-cpu systemd python-single-r1

DESCRIPTION="prismOS global keyboard accelerators: Spotlight-like launcher via evdev/uinput"
HOMEPAGE="https://github.com/Davidix07TV/prismOS"
SRC_URI=""

LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"
IUSE=""
REQUIRED_USE="${PYTHON_REQUIRED_USE}"

DEPEND=""
RDEPEND="
	${PYTHON_DEPS}
	$(python_gen_cond_dep 'dev-python/evdev[${PYTHON_USEDEP}]')
	sys-apps/systemd
	virtual/udev
"
BDEPEND="
	${PYTHON_DEPS}
	sys-apps/coreutils
"

S="${WORKDIR}"

src_prepare() {
	default
	python_fix_shebang "${FILESDIR}"/prismos-accelerator-daemon
	prismos-legacy-cpu_assert_isa_floor || die "floor ISA SSE4.1 non rispettato"
}

src_install() {
	exeinto /usr/libexec/prismos
	newexe "${FILESDIR}"/prismos-accelerator-daemon prismos-accelerator-daemon
	fperms 0750 /usr/libexec/prismos/prismos-accelerator-daemon
	python_fix_shebang "${ED}"/usr/libexec/prismos/prismos-accelerator-daemon

	insinto /usr/share/prismos
	newins "${FILESDIR}"/accelerators.json accelerators.json
	fperms 0644 /usr/share/prismos/accelerators.json

	systemd_dounit "${FILESDIR}"/prismos-accelerator-daemon.service

	# CLI di diagnostica per l'utente (--list / --list-devices / avvio manuale).
	exeinto /usr/bin
	newexe "${FILESDIR}"/prismos-accelerators prismos-accelerators
	fperms 0755 /usr/bin/prismos-accelerators
}

pkg_postinst() {
	systemd_enable_service multi-user.target prismos-accelerator-daemon.service

	elog ""
	elog "Scorciatoie globali prismOS (stile macOS):"
	elog "  Super+Space          launcher centralizzato di Ash (Spotlight-like)"
	elog "  Super+Shift+Space    ricerca web diretta"
	elog "  Super+L              blocco schermo"
	elog "  Super+D              mostra desktop"
	elog "  Super+1..4           passa all'app bloccata N sulla Dock"
	elog "  Super+Ctrl+S         stato dei sottosistemi Waydroid/Wine"
	elog "  Super+Ctrl+Q         spegne subito i sottosistemi (libera RAM)"
	elog ""
	elog "Configurazione: /usr/share/prismos/accelerators.json"
	elog "Ispezione     : prismos-accelerators --list"
	elog ""
	ewarn "Il demone cattura le tastiere con EVIOCGRAB. In caso di tastiera muta:"
	ewarn "  systemctl restart prismos-accelerator-daemon.service"
	ewarn "  oppure PRISMOS_ACCEL_GRAB=0 per la modalita' observe (nessuna cattura)."

	if [[ -d "${EROOT}/run/systemd/system" ]]; then
		systemctl --root="${EROOT}" daemon-reload || true
	fi
}
