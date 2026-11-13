#!/bin/bash
# =============================================================================
# lib/mail.sh — Этап (опц.): почтовый стек Postfix + Dovecot.
# ПРИНЦИП: ставим пакеты и готовим их под управление ISPConfig. Конфигурацию
# (виртуальные домены/ящики через MySQL, TLS, SASL) генерирует ISPConfig при
# установке (autoinstall.ini → configure_mail=y). Здесь НЕ правим конфиги вручную,
# чтобы ISPConfig их не перезатёр и не возникло двух источников правды.
# =============================================================================

stage_mail() {
	local fqdn="${SERVER_FQDN:-server1.example.com}"
	ui_info "Почтовый стек: Postfix (SMTP) + Dovecot (IMAP/POP3/LMTP)"

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} preseed postfix (Internet Site, mailname=${fqdn})"
		ui_info "${UI_D}[dry-run]${UI_NC} apt install postfix postfix-mysql dovecot-{imapd,pop3d,mysql,lmtpd,sieve,managesieved} getmail6"
		ui_info "${UI_D}[dry-run]${UI_NC} конфигурацию почты выполнит ISPConfig (configure_mail=y)"
		ui_success "Почтовый стек (имитация) установлен."
		return 0
	fi

	# Неинтерактивный preseed Postfix: тип «Internet Site», system mail name = FQDN
	export DEBIAN_FRONTEND=noninteractive
	echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
	echo "postfix postfix/mailname string ${fqdn}"               | debconf-set-selections

	ui_step "Установка Postfix"
	apt_install postfix postfix-mysql postfix-doc

	ui_step "Установка Dovecot"
	apt_install dovecot-imapd dovecot-pop3d dovecot-mysql dovecot-lmtpd \
		dovecot-sieve dovecot-managesieved

	# getmail для забора почты с внешних ящиков (ISPConfig умеет им управлять).
	# На Debian 12/13 пакет называется getmail6; подстрахуемся старым именем.
	apt_install getmail6 || apt_install getmail || ui_warn "getmail не установлен (не критично)."

	# SASL-модули (Dovecot SASL используется Postfix'ом для SMTP-auth)
	apt_install libsasl2-modules

	# Включаем сервисы; детальный конфиг наложит ISPConfig
	sys_run "Автозагрузка Postfix" systemctl enable --now postfix
	sys_run "Автозагрузка Dovecot" systemctl enable --now dovecot

	ui_success "Postfix и Dovecot установлены и запущены (конфигурацию наложит ISPConfig)."
	log "mail: postfix+dovecot установлены, ожидают configure_mail в ISPConfig"
	return 0
}

stage_mail_summary() { echo "Mail: Postfix + Dovecot (конфиг через ISPConfig)"; }
