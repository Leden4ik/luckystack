#!/bin/bash
# =============================================================================
# lib/apache.sh — Native установка Apache (вариант статьи Perfect Server).
# apache2 + suExec + FCGID + mpm_event + проксирование в PHP-FPM.
# PHP-FPM ставится отдельным этапом (lib/php.sh) — одинаков для nginx и Apache.
# =============================================================================

stage_apache() {
	ui_step "Установка Apache + suExec + FCGID"
	# БЕЗ libapache2-mod-php: используем PHP-FPM (mod_proxy_fcgi), как и ISPConfig.
	# mod_php несовместим с mpm_event и тянет лишнюю «системную» версию PHP.
	# Обработчик .php для дефолтной версии включает php-этап (a2enconf phpX.Y-fpm).
	apt_install apache2 apache2-utils libapache2-mod-fcgid apache2-suexec-pristine

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} a2enmod (suexec rewrite ssl actions include dav headers proxy_fcgi setenvif http2 mpm_event)"
		ui_info "${UI_D}[dry-run]${UI_NC} systemctl enable --now apache2"
		ui_success "Apache (имитация) установлен."
		return 0
	fi

	ui_step "Включение модулей Apache"
	ui_spin "a2enmod (suexec, rewrite, ssl, actions, fcgid, dav, headers, proxy_fcgi, http2)" \
		a2enmod suexec rewrite ssl actions include dav_fs dav auth_digest headers \
			proxy_fcgi setenvif http2 || ui_warn "Часть модулей не включилась."

	# MPM event лучше для FPM-проксирования: отключаем prefork, включаем event
	a2dismod php8.* mpm_prefork >/dev/null 2>&1 || true
	a2enmod mpm_event >/dev/null 2>&1 || true

	sys_run "Перезапуск Apache" systemctl restart apache2
	sys_run "Автозагрузка Apache" systemctl enable apache2
	ui_success "Apache установлен и настроен."
	return 0
}

stage_apache_summary() { echo "Apache: установлен (FPM через mod_proxy_fcgi)"; }
