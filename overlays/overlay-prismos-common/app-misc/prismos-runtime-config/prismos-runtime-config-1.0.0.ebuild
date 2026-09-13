# Copyright 2026 The prismOS Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit prismos-legacy-cpu systemd

DESCRIPTION="prismOS runtime configuration: legacy GPU environment, kernel tuning, subsystem lifecycle"
HOMEPAGE="https://github.com/Davidix07TV/prismOS"
SRC_URI=""

LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"
IUSE="+zram +zswap earlyoom slim-ondemand"

DEPEND=""
RDEPEND="
	sys-apps/systemd
	sys-apps/util-linux
	sys-process/procps
	sys-apps/iproute2
	>=app-misc/prismos-dock-1.0.0
	zram? ( sys-block/zram-generator sys-apps/zstd )
	earlyoom? ( sys-process/earlyoom )
"
BDEPEND="sys-apps/coreutils"

S="${WORKDIR}"

src_prepare() {
	default
	prismos-legacy-cpu_assert_isa_floor || die "floor ISA SSE4.1 non rispettato"
}

src_install() {
	# --- ambiente GPU legacy (Intel HD Graphics Gen5) -------------------------
	insinto /etc/env.d
	newins "${FILESDIR}"/50prismos-gpu.envd 50prismos-gpu

	# --- tuning del kernel per 1-2 GB di RAM ----------------------------------
	insinto /etc/sysctl.d
	newins "${FILESDIR}"/99-prismos-legacy.sysctl 99-prismos-legacy.conf

	# --- directory di runtime ----------------------------------------------------
	insinto /usr/lib/tmpfiles.d
	newins "${FILESDIR}"/prismos.tmpfiles prismos.conf

	# --- unita' di coordinamento dei sottosistemi --------------------------------
	systemd_dounit "${FILESDIR}"/prismos-subsystems.target
	systemd_dounit "${FILESDIR}"/prismos-subsystems.slice
	systemd_dounit "${FILESDIR}"/prismos-firstboot.service
	systemd_dounit "${FILESDIR}"/prismos-subsystem-idle.service
	systemd_dounit "${FILESDIR}"/prismos-subsystem-idle.timer

	# --- helper ---------------------------------------------------------------------
	exeinto /usr/libexec/prismos
	newexe "${FILESDIR}"/prismos-firstboot prismos-firstboot
	newexe "${FILESDIR}"/prismos-subsystem-idle-check prismos-subsystem-idle-check
	fperms 0750 /usr/libexec/prismos/prismos-firstboot
	fperms 0750 /usr/libexec/prismos/prismos-subsystem-idle-check

	keepdir /var/lib/prismos/state
	keepdir /var/log/prismos
	keepdir /var/cache/prismos/mesa
	keepdir /run/prismos/idle
}

pkg_postinst() {
	systemd_enable_service multi-user.target prismos-firstboot.service
	systemd_enable_service timers.target prismos-subsystem-idle.timer

	if use zram; then
		elog "zram: il generatore crea un device di swap compresso pari al 50% della RAM"
		elog "      con algoritmo zstd (basso costo CPU sui 2 core di Arrandale)."
	fi
	if use earlyoom; then
		elog "earlyoom: soglia 8% di memoria libera / 3% di swap, intervento prima"
		elog "          dell'OOM killer del kernel per proteggere la sessione Ash."
	fi
	if use slim-ondemand; then
		ewarn "Edizione Slim: prismos-subsystem-idle.timer viene MASCHERATA da"
		ewarn "app-misc/prismos-slim-launcher (teardown immediato on-demand)."
	fi

	if [[ -d "${EROOT}/run/systemd/system" ]]; then
		systemctl --root="${EROOT}" daemon-reload || true
	fi

	prismos-legacy-cpu_runtime_check || true
}
