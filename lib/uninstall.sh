#!/bin/bash
# =============================================================================
# lib/uninstall.sh — Удаление установленных компонентов (полное / частичное).
# DESTRUCTIVE. Запускается через `server-setup.sh --uninstall`.
#
# Два уровня:
#   • пакеты+конфиги — apt purge + удаление /etc/<svc> (по умолчанию)
#   • данные (БД, почта, сайты) — только если выбран явный «purge data»
# Порядок удаления — ОБРАТНЫЙ установке (ISPConfig → … → MariaDB).
# =============================================================================

# Компоненты, доступные для удаления (обратный порядок установки; preflight не трогаем)
UNINSTALL_ORDER="malware backup tuning mailsni maildeliver rcplugins hostcert ispconfig webmail monit security ssl ftp dns rspamd mail postgresql phpmyadmin nodejs php webserver database"

declare -gA UNINSTALL_LABEL=(
	[malware]="Анти-malware (скан по расписанию + LMD)"
	[backup]="Резервное копирование (таймер + скрипт)"
	[tuning]="Авто-тюнинг (drop-in MariaDB/PHP)"
	[mailsni]="Per-domain TLS почты (SNI)"
	[maildeliver]="Доставляемость почты (файлы DNS-записей)"
	[rcplugins]="Плагины ISPConfig для Roundcube"
	[hostcert]="LE-сертификат хоста (deploy-скрипт/dovecot-ssl)"
	[ispconfig]="ISPConfig (панель)"
	[webmail]="RoundCube + статистика"
	[monit]="Monit"
	[security]="fail2ban / UFW / Lynis / rkhunter / jailkit"
	[ssl]="ACME-клиент (acme.sh/certbot)"
	[ftp]="PureFTPd + квоты"
	[dns]="BIND9"
	[rspamd]="Rspamd + ClamAV"
	[mail]="Postfix + Dovecot"
	[postgresql]="PostgreSQL + pgAdmin/Adminer"
	[phpmyadmin]="Веб-админка БД (phpMyAdmin/Adminer)"
	[nodejs]="Node.js"
	[php]="PHP (все версии)"
	[webserver]="nginx / Apache"
	[database]="MariaDB + Redis"
)

# --- Низкоуровневые помощники ------------------------------------------------
# apt purge пакетов, шаблоны вида 'php*' можно. Сначала спрашиваем dpkg, что из этого реально стоит:
# apt отказывает во всей команде, если хоть одно имя ему незнакомо (getmail на Debian 13),
# а шаблон без кавычек раскрывала оболочка по файлам текущего каталога ('php*' → php-x.php).
_un_purge() {
	[[ $# -gt 0 ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then ui_info "${UI_D}[dry-run]${UI_NC} apt purge $*"; return 0; fi
	export DEBIAN_FRONTEND=noninteractive
	apt_lock_wait_conf
	local p st n pkgs=()
	for p in "$@"; do
		while read -r st n; do
			[[ -n "$n" && "${st:1:1}" != n ]] && pkgs+=("$n")   # второй символ n — не установлен
		done < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "$p" 2>/dev/null)
	done
	((${#pkgs[@]})) || return 0
	if ! apt-get purge -y -qq "${pkgs[@]}" >>"$SETUP_LOG" 2>&1; then
		ui_warn "  apt не удалил пакеты: ${pkgs[*]} (подробно в ${SETUP_LOG})"
		return 1
	fi
	return 0
}
_un_autoremove() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	apt-get autoremove -y -qq >>"$SETUP_LOG" 2>&1 || true
}
_un_stop() {  # disable+stop сервисов (молча, если нет)
	local s
	for s in "$@"; do
		if [[ "${DRY_RUN:-0}" == "1" ]]; then ui_info "${UI_D}[dry-run]${UI_NC} stop ${s}"; continue; fi
		systemctl disable --now "$s" >>"$SETUP_LOG" 2>&1 || true
	done
}
_un_rm() {  # удалить пути (конфиги). Для данных — отдельно через _un_rm_data
	local p
	for p in "$@"; do
		[[ -z "$p" || "$p" == "/" ]] && continue
		if [[ "${DRY_RUN:-0}" == "1" ]]; then ui_info "${UI_D}[dry-run]${UI_NC} rm -rf ${p}"; continue; fi
		rm -rf "$p" 2>/dev/null || true
	done
}
_un_rm_data() {  # удалить данные — ТОЛЬКО при PURGE_DATA=y
	[[ "${PURGE_DATA:-n}" == "y" ]] || { ui_info "  (данные сохранены: $* — для удаления используйте purge data)"; return 0; }
	_un_rm "$@"
}
# Снять swap, СОЗДАННЫЙ установщиком (только если в fstab есть наш маркер — чтобы не
# тронуть чужой /swapfile). Плюс снять наш перф-sysctl (swappiness + BBR) — он пишется
# в /etc/sysctl.d независимо от swap, поэтому чистим его безусловно.
_un_remove_swap() {
	if [[ "${DRY_RUN:-0}" != "1" && -f /etc/sysctl.d/99-luckystack-perf.conf ]]; then
		rm -f /etc/sysctl.d/99-luckystack-perf.conf
		sysctl --system >>"$SETUP_LOG" 2>&1 || true
		ui_info "  перф-sysctl (swappiness/BBR) снят (/etc/sysctl.d/99-luckystack-perf.conf)."
	fi
	if [[ "${DRY_RUN:-0}" != "1" ]] && grep -qsx '# luckystack: ipv4-first' /etc/gai.conf; then
		sed -i '/^# luckystack: ipv4-first$/{N;d}' /etc/gai.conf
		ui_info "  строка ipv4-first убрана из /etc/gai.conf."
	fi
	grep -q '^# luckystack-swap' /etc/fstab 2>/dev/null || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then ui_info "${UI_D}[dry-run]${UI_NC} снять /swapfile + запись fstab (наш маркер)"; return 0; fi
	swapoff /swapfile 2>/dev/null || true
	rm -f /swapfile
	sed -i '/^# luckystack-swap$/d; \|^/swapfile[[:space:]]|d' /etc/fstab 2>/dev/null || true
	ui_info "  swap, созданный установщиком, удалён (/swapfile + запись fstab)."
}

# --- Удаление по компонентам -------------------------------------------------
uninstall_malware() {
	_un_stop ss-malware-scan.timer ss-malware-scan.service maldet.service
	_un_rm /etc/systemd/system/ss-malware-scan.timer /etc/systemd/system/ss-malware-scan.service \
	       /usr/local/sbin/ss-malware-scan /var/log/ss-malware-scan.log /etc/rkhunter.conf.local
	# LMD ставится своим install.sh из архива, пакета у него нет
	_un_rm /usr/local/maldetect /usr/local/sbin/maldet /usr/local/sbin/lmd /etc/cron.daily/maldet \
	       /etc/cron.d/maldet_pub /etc/default/maldet /usr/lib/systemd/system/maldet.service
	[[ "${DRY_RUN:-0}" == "1" ]] || systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
	return 0   # rkhunter снимается вместе с security
}
uninstall_backup() {
	_un_stop server-backup.timer server-backup.service
	_un_rm /etc/systemd/system/server-backup.timer /etc/systemd/system/server-backup.service \
	       /usr/local/sbin/server-backup.sh /etc/server-backup.conf
	[[ "${DRY_RUN:-0}" == "1" ]] || systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
	# Сами снимки бэкапов — это данные: удаляем только при purge.
	_un_rm_data /var/backups/server
}
uninstall_maildeliver() {
	# Только сгенерированные шпаргалки; TLS-харденинг Postfix НЕ откатываем
	# (он полезен и безопасен; бэкап main.cf лежит рядом с *.luckystack.bak.*).
	_un_rm /root/mail-dns-records.txt /root/mta-sts-policy.txt
	ui_info "  (TLS-настройки Postfix оставлены; откат — из /etc/postfix/main.cf.luckystack.bak.*)"
	ui_info "  (запрет пароля без TLS в Dovecot — блок «luckystack: auth-tls» в ${MAIL_DVC_CUSTOM:-/etc/dovecot/conf.d/99-ispconfig-custom-config.conf})"
}
uninstall_hostcert() {
	# Снимаем deploy-скрипт, dovecot-ssl drop-in, FQDN-сайт, аварийный скрипт.
	# Сам LE-серт в ispserver.* и acme.sh-конфиг оставляем (переустановит hostcert).
	_un_rm /usr/local/sbin/ispconfig-hostcert-deploy.sh /etc/dovecot/conf.d/99-luckystack-ssl.conf \
	       /usr/local/sbin/ispconfig-panel-allow-ip.sh \
	       /etc/nginx/conf.d/10-host-fqdn.conf /etc/nginx/conf.d/10-host-fqdn.conf.bak
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		systemctl reload dovecot >>"$SETUP_LOG" 2>&1 || true
		# nginx: снять блок panel-fqdn-only (маркер + строка 'if return 444').
		if [[ -f /etc/nginx/sites-available/ispconfig.vhost ]]; then
			sed -i '/luckystack: panel-fqdn-only/{N;/return 444/d}' /etc/nginx/sites-available/ispconfig.vhost 2>/dev/null || true
		fi
		command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1 && systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
		# apache: снять FQDN-сайт и блок panel-fqdn-only (маркер … </If>).
		if command -v apache2ctl >/dev/null 2>&1; then
			a2dissite luckystack-host-fqdn >>"$SETUP_LOG" 2>&1 || true
			rm -f /etc/apache2/sites-available/luckystack-host-fqdn.conf /etc/apache2/sites-available/luckystack-host-fqdn.conf.bak
			[[ -f /etc/apache2/sites-available/ispconfig.vhost ]] && \
				sed -i '/luckystack: panel-fqdn-only/,/<\/If>/d' /etc/apache2/sites-available/ispconfig.vhost 2>/dev/null || true
			apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 >>"$SETUP_LOG" 2>&1 || true
		fi
	fi
	ui_info "  (сертификат в ispserver.* и подписка acme.sh не тронуты)"
}
uninstall_rcplugins() {
	# Удаляем плагины из всех возможных каталогов Roundcube и remote API-юзера.
	local d
	for d in /opt/roundcube/plugins /var/lib/roundcube/plugins /usr/share/roundcube/plugins /var/www/html/roundcube/plugins; do
		[[ -d "$d" ]] && _un_rm "$d"/ispconfig3_*
	done
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		# Снять merge-блок плагинов из конфига Roundcube (восстановить из бэкапа).
		local cfg
		for cfg in /opt/roundcube/config/config.inc.php /etc/roundcube/config.inc.php /var/lib/roundcube/config/config.inc.php; do
			[[ -f "${cfg}.luckystack.bak" ]] && mv -f "${cfg}.luckystack.bak" "$cfg" 2>/dev/null || true
		done
		# Удалить remote API-пользователя.
		local apiu="${RCPLUGINS_API_USER:-roundcube}"
		if [[ -f /root/.my.cnf ]]; then
			mysql --defaults-file=/root/.my.cnf dbispconfig -e "DELETE FROM remote_user WHERE remote_username='${apiu}';" >>"$SETUP_LOG" 2>&1 || true
		fi
	else
		ui_info "${UI_D}[dry-run]${UI_NC} удалить плагины ispconfig3_* + remote_user 'roundcube'"
	fi
}
uninstall_ispconfig() {
	_un_stop ispconfig_server ispconfig_agent
	_un_rm /etc/cron.d/ispconfig /usr/local/ispconfig /tmp/ispconfig3_install
	# Задания, которые без панели каждую минуту падали бы с ошибкой: строки ISPConfig в crontab root
	# и наши /etc/cron.d/ss-* (синхронизация разделов панели, гео-фильтр firewall)
	_un_rm /etc/cron.d/ss-*-panel /etc/cron.d/ss-fail2ban /etc/cron.d/ss-nodecomposer /etc/cron.d/ss-firewall-geo \
	       /usr/local/sbin/ss-firewall-geo-refresh /etc/ss-firewall /etc/fail2ban/jail.d/zz-luckystack-trusted.local
	_un_rm /usr/local/bin/ispconfig_update.sh /usr/local/bin/ispconfig_update_from_dev.sh /usr/local/bin/ispc \
	       /usr/local/bin/ispconfig_patch /usr/local/bin/letsencrypt_pre_hook.sh /usr/local/bin/letsencrypt_post_hook.sh \
	       /usr/local/bin/letsencrypt_renew_hook.sh /usr/local/bin/run-getmail.sh
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} убрать строки /usr/local/ispconfig из crontab root"
	elif crontab -l 2>/dev/null | grep -q '/usr/local/ispconfig/'; then
		local cr; cr="$(crontab -l 2>/dev/null | grep -v '/usr/local/ispconfig/')"
		if [[ -n "$(grep -v '^[[:space:]]*\(#\|$\)' <<<"$cr")" ]]; then printf '%s\n' "$cr" | crontab -; else crontab -r 2>/dev/null; fi
		ui_info "  строки ISPConfig убраны из crontab root."
	fi
	# БД панели — это данные
	if [[ "${PURGE_DATA:-n}" == "y" ]]; then
		if [[ "${DRY_RUN:-0}" == "1" ]]; then ui_info "${UI_D}[dry-run]${UI_NC} DROP DATABASE dbispconfig";
		else mysql --defaults-file=/root/.my.cnf -e "DROP DATABASE IF EXISTS dbispconfig;" >>"$SETUP_LOG" 2>&1 || true; fi
	else
		ui_info "  (БД dbispconfig сохранена)"
	fi
	ui_info "  (сайты клиентов в /var/www/clients сохранены)"
}
uninstall_webmail() {
	_un_purge 'roundcube*' awstats webalizer goaccess
	_un_rm /var/www/html/roundcube /etc/roundcube /opt/roundcube /opt/roundcube.prev /opt/roundcube.new \
	       /etc/nginx/snippets/default-locations/roundcube-deny.conf
	# БД и пользователь roundcube — это ДАННЫЕ: дропаем только при purge.
	if [[ "${PURGE_DATA:-n}" == "y" && "${DRY_RUN:-0}" != "1" && -f /root/.my.cnf ]]; then
		mysql --defaults-file=/root/.my.cnf -e \
			"DROP DATABASE IF EXISTS roundcube; DROP USER IF EXISTS 'roundcube'@'localhost';" >>"$SETUP_LOG" 2>&1 || true
	fi
}
uninstall_monit()    { _un_stop monit;     _un_purge monit;     _un_rm /etc/monit; }
uninstall_security() {
	_un_stop fail2ban
	_un_purge fail2ban rkhunter lynis jailkit
	# UFW: сбрасываем правила, но пакет можно оставить
	if [[ "${DRY_RUN:-0}" != "1" ]] && command -v ufw >/dev/null 2>&1; then
		# снять наш блок жёстких IP-ограничений из before.rules (переживал ISPConfig-firewall)
		local _bf
		for _bf in /etc/ufw/before.rules /etc/ufw/before6.rules; do
			[[ -f "$_bf" ]] && sed -i '\|# luckystack: restrict START|,\|# luckystack: restrict END|d' "$_bf" 2>/dev/null || true
		done
		ufw --force reset >>"$SETUP_LOG" 2>&1 || true
		ufw --force disable >>"$SETUP_LOG" 2>&1 || true
	else
		ui_info "${UI_D}[dry-run]${UI_NC} ufw reset/disable"
	fi
	_un_rm /etc/fail2ban/jail.local /var/log/lynis.log /var/log/lynis-report.dat /var/log/rkhunter.log
	# Автообновления безопасности и отчёт world-writable, добавленные установщиком
	_un_purge unattended-upgrades
	_un_rm /etc/apt/apt.conf.d/52luckystack-unattended /etc/apt/apt.conf.d/53luckystack-unattended-3rd /etc/needrestart/conf.d/50-luckystack.conf /etc/systemd/journald.conf.d/50-luckystack.conf /etc/aide/aide.conf.d/99_luckystack /etc/apt/apt.conf.d/20auto-upgrades /root/world-writable-files.txt
	# sysctl-харденинг и доп. jail'ы fail2ban
	_un_rm /etc/sysctl.d/90-luckystack-hardening.conf /etc/sysctl.d/91-luckystack-userns.conf /etc/sysctl.d/99-protect-links.conf /etc/fail2ban/filter.d/roundcube-auth.local /etc/fail2ban/filter.d/dovecot.local /etc/fail2ban/jail.d/luckystack-ispconfig.conf /etc/fail2ban/jail.d/00-luckystack.conf /etc/fail2ban/filter.d/luckystack-ispconfig-auth.conf /etc/fail2ban/jail.d/zz-luckystack-trusted.local
	[[ "${DRY_RUN:-0}" == "1" ]] || rmdir /etc/fail2ban/filter.d /etc/fail2ban/jail.d /etc/fail2ban 2>/dev/null || true
	[[ "${DRY_RUN:-0}" != "1" ]] && sysctl --system >>"$SETUP_LOG" 2>&1 || true

	# Снять наши SSH-артефакты: drop-in со сменой порта + Match-блок ограничения по IP.
	# (Без них sshd слушает порт по умолчанию 22; Match убираем, чтобы не ограничивать вход.)
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		local _ssh_chg=0
		[[ -f /etc/ssh/sshd_config.d/00-luckystack-ssh.conf ]] && \
			{ rm -f /etc/ssh/sshd_config.d/00-luckystack-ssh.conf; _ssh_chg=1; }
		[[ -f /etc/ssh/sshd_config.d/10-luckystack-harden.conf ]] && \
			{ rm -f /etc/ssh/sshd_config.d/10-luckystack-harden.conf; _ssh_chg=1; }
		if grep -q 'luckystack: ssh-allow-ips START' /etc/ssh/sshd_config 2>/dev/null; then
			sed -i '/# luckystack: ssh-allow-ips START/,/# luckystack: ssh-allow-ips END/d' /etc/ssh/sshd_config 2>/dev/null && _ssh_chg=1
		fi
		# Перезапуск только если harden-revert ниже не сработает (там свой рестарт)
		if (( _ssh_chg )) && [[ ! -f /etc/ssh/sshd_config.harden.bak ]]; then
			sshd -t 2>/dev/null && { systemctl restart ssh >>"$SETUP_LOG" 2>&1 || systemctl restart sshd >>"$SETUP_LOG" 2>&1 || true; }
			ui_info "  SSH-артефакты сняты (drop-in порта + ограничение по IP) — SSH на порту по умолчанию."
		fi
	fi

	# Откат SSH-харденинга: если он применялся (есть бэкап ДО харденинга), предлагаем
	# вернуть прежний sshd_config. Иначе после удаления стека вход по паролю остаётся
	# отключённым — частый тупик «не пускает по паролю» уже без установщика.
	if [[ -f /etc/ssh/sshd_config.harden.bak ]]; then
		if [[ "${DRY_RUN:-0}" == "1" ]]; then
			ui_info "${UI_D}[dry-run]${UI_NC} откат SSH-харденинга (восстановить sshd_config.harden.bak)"
		elif ui_confirm "Откатить SSH-харденинг (вернуть вход по паролю)? Иначе останется вход ТОЛЬКО по ключу." y; then
			cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.pre-unharden.bak 2>/dev/null || true
			if cp -a /etc/ssh/sshd_config.harden.bak /etc/ssh/sshd_config && sshd -t 2>>"$SETUP_LOG"; then
				systemctl restart ssh >>"$SETUP_LOG" 2>&1 || systemctl restart sshd >>"$SETUP_LOG" 2>&1 || true
				rm -f /etc/ssh/sshd_config.harden.bak
				ui_info "  SSH-харденинг откатан — sshd_config до харденинга восстановлен (вход по паролю как раньше)."
			else
				cp -a /etc/ssh/sshd_config.pre-unharden.bak /etc/ssh/sshd_config 2>/dev/null || true
				ui_warn "  Откат SSH не прошёл sshd -t — оставляю текущий sshd_config без изменений."
			fi
		else
			ui_info "  SSH-харденинг оставлен (вход только по ключу)."
		fi
	fi
}
uninstall_tuning() {
	# Снимаем drop-in тюнинга и возвращаем дефолты служб.
	_un_rm /etc/mysql/mariadb.conf.d/90-luckystack-tuning.cnf /etc/mysql/conf.d/90-luckystack-tuning.cnf
	# systemd-override LimitNOFILE (_tune_limits)
	_un_rm /etc/systemd/system/mariadb.service.d/limits.conf \
	       /etc/systemd/system/postfix.service.d/limits.conf \
	       /etc/systemd/system/dovecot.service.d/limits.conf
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		local v
		for v in /etc/php/*/; do
			[[ -d "$v" ]] || continue
			v="$(basename "$v")"
			rm -f "/etc/php/$v"/fpm/conf.d/99-zz-luckystack-tuning.ini "/etc/php/$v"/cli/conf.d/99-zz-luckystack-tuning.ini 2>/dev/null || true
			systemctl reload "php${v}-fpm" >>"$SETUP_LOG" 2>&1 || true
		done
		# чистим наш блок nofile в limits.conf (по маркеру) + пустые override-каталоги
		sed -i '/# luckystack: nofile/,+4d' /etc/security/limits.conf 2>/dev/null || true
		rmdir /etc/systemd/system/mariadb.service.d /etc/systemd/system/postfix.service.d \
		      /etc/systemd/system/dovecot.service.d 2>/dev/null || true
		systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
		command -v mysql >/dev/null 2>&1 && systemctl restart mariadb >>"$SETUP_LOG" 2>&1 || true
	else
		ui_info "${UI_D}[dry-run]${UI_NC} удалить drop-in тюнинга MariaDB/PHP + LimitNOFILE-override + reload"
	fi
}
uninstall_mailsni() {
	_un_stop ispconfig-mail-sni.timer ispconfig-mail-sni.service
	_un_rm /etc/systemd/system/ispconfig-mail-sni.timer /etc/systemd/system/ispconfig-mail-sni.service \
	       /usr/local/sbin/ispconfig-mail-sni.sh /etc/dovecot/sni.conf /etc/postfix/sni
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
		# Убрать !include из dovecot.conf и SNI-карту из Postfix.
		[[ -f /etc/dovecot/dovecot.conf ]] && sed -i '\|!include /etc/dovecot/sni.conf|d' /etc/dovecot/dovecot.conf 2>/dev/null || true
		command -v postconf >/dev/null 2>&1 && postconf -X tls_server_sni_maps >>"$SETUP_LOG" 2>&1 || true
		systemctl reload dovecot >>"$SETUP_LOG" 2>&1 || true
		systemctl reload postfix >>"$SETUP_LOG" 2>&1 || true
	fi
}
uninstall_ssl() {
	_un_purge certbot
	# if/then, а не '[[ -x ]] && {...}': при ПОВТОРНОМ удалении acme.sh уже нет, и
	# тест-как-последняя-инструкция возвращал 1 → ложная «Ошибки при удалении ssl».
	if [[ -x /root/.acme.sh/acme.sh ]]; then
		if [[ "${DRY_RUN:-0}" == "1" ]]; then ui_info "${UI_D}[dry-run]${UI_NC} acme.sh --uninstall + rm /root/.acme.sh"
		else
			/root/.acme.sh/acme.sh --uninstall >>"$SETUP_LOG" 2>&1 || true
			# Выпущенные сертификаты и учётка LE — данные. Без них новая установка выпускает всё заново
			# и легко упирается в лимит Let's Encrypt (5 сертификатов на имя в неделю).
			if [[ "${PURGE_DATA:-n}" == "y" ]]; then rm -rf /root/.acme.sh
			else ui_info "  (сертификаты Let's Encrypt оставлены в /root/.acme.sh, новая установка возьмёт их)"; fi
		fi
	fi
	return 0
}
uninstall_ftp() {
	_un_stop pure-ftpd-mysql
	# Снимаем наши journaled-квоты с fstab ДО удаления пакета quota (иначе quotaoff недоступен)
	if [[ "${DRY_RUN:-0}" != "1" ]] && grep -E '^\S+\s+/\s+\S+\s+\S*usrjquota' /etc/fstab >/dev/null 2>&1; then
		quotaoff -avug >>"$SETUP_LOG" 2>&1 || true
		cp -a /etc/fstab /etc/fstab.luckystack-uninstall.bak 2>/dev/null || true
		# убираем три наших токена из опций корня (ведущую запятую снимает ,?)
		sed -i -E 's/,?(usrjquota=quota\.user|grpjquota=quota\.group|jqfmt=vfsv0)//g' /etc/fstab 2>/dev/null || true
		rm -f /quota.user /quota.group 2>/dev/null || true
		mount -o remount / >>"$SETUP_LOG" 2>&1 || true
		ui_info "  FTP: journaled-квоты сняты с /etc/fstab (бэкап: /etc/fstab.luckystack-uninstall.bak)."
	else
		ui_info "  FTP: записей квот в /etc/fstab не найдено — fstab не тронут."
	fi
	_un_purge 'pure-ftpd*' quota quotatool
	_un_rm /etc/pure-ftpd /etc/ssl/private/pure-ftpd.pem
}
uninstall_dns()  { _un_stop named bind9; _un_purge bind9 bind9-utils bind9-dnsutils haveged; _un_rm_data /etc/bind; }
uninstall_rspamd() {
	_un_stop rspamd clamav-daemon clamav-freshclam
	_un_purge rspamd clamav clamav-daemon
	_un_rm /etc/rspamd /etc/apt/sources.list.d/rspamd.list /etc/apt/keyrings/rspamd.gpg
}
uninstall_mail() {
	_un_stop postfix dovecot
	_un_purge 'postfix*' 'dovecot*' getmail6 getmail
	_un_rm /etc/postfix /etc/dovecot
	_un_rm_data /var/mail /var/vmail
}
uninstall_postgresql() {
	_un_stop postgresql 'pgadmin4*'
	_un_purge 'postgresql*' 'pgadmin4*'
	# Adminer (под nginx им администрируется PostgreSQL) — один файл в корне сайта
	_un_rm /etc/apt/sources.list.d/pgadmin4.list /usr/share/keyrings/packages-pgadmin-org.gpg /var/www/html/adminer
	_un_rm_data /var/lib/postgresql
}
# Веб-админка БД: phpMyAdmin (пакет) и/или Adminer (один файл в /var/www/html/adminer)
uninstall_phpmyadmin() {
	# Служебная БД phpmyadmin (pmadb) — снести до purge пакета (пока есть креды в /root/.my.cnf)
	if [[ "${DRY_RUN:-0}" != "1" ]] && command -v mysql >/dev/null 2>&1; then
		mysql --defaults-file=/root/.my.cnf <<'SQL' >>"$SETUP_LOG" 2>&1 || true
DROP DATABASE IF EXISTS `phpmyadmin`;
DROP USER IF EXISTS 'phpmyadmin'@'localhost';
FLUSH PRIVILEGES;
SQL
	fi
	_un_purge phpmyadmin
	_un_rm /var/www/html/phpmyadmin /etc/phpmyadmin /var/www/html/adminer
	# PHP-ini лимитов импорта (для всех версий — на всякий) + reload активных пулов
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		local v
		for v in /etc/php/*/; do
			[[ -d "$v" ]] || continue; v="$(basename "$v")"
			rm -f "/etc/php/$v/fpm/conf.d/99-luckystack-dbadmin.ini" 2>/dev/null || true
			systemctl reload "php${v}-fpm" >>"$SETUP_LOG" 2>&1 || true
		done
	fi
	# Снять правила ограничения доступа (FQDN-only/IP) для обоих веб-серверов.
	_un_rm /etc/nginx/snippets/default-locations/dbadmin-restrict.conf
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		if [[ -f /etc/apache2/conf-available/luckystack-dbadmin-restrict.conf ]]; then
			a2disconf luckystack-dbadmin-restrict >>"$SETUP_LOG" 2>&1 || true
			rm -f /etc/apache2/conf-available/luckystack-dbadmin-restrict.conf
		fi
		command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1 && systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
	fi
}
uninstall_nodejs() {
	_un_purge nodejs
	_un_rm /etc/apt/sources.list.d/nodesource.list /etc/apt/sources.list.d/nodesource.sources \
	       /etc/apt/keyrings/nodesource.gpg /usr/share/keyrings/nodesource.gpg
}
uninstall_php() {
	# Остановить все php*-fpm и удалить пакеты php*
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		systemctl list-units --type=service 2>/dev/null | awk '/php[0-9.]+-fpm/{print $1}' \
			| xargs -r systemctl disable --now >>"$SETUP_LOG" 2>&1 || true
	fi
	_un_purge 'php*'
	# Сброс update-alternatives php/phar — иначе после purge остаётся битый симлинк
	# /etc/alternatives/php на удалённый бинарь (PHP_CLI_DEFAULT).
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		local b
		for b in php phar phar.phar; do update-alternatives --remove-all "$b" >>"$SETUP_LOG" 2>&1 || true; done
	fi
	_un_rm /etc/php /etc/apt/sources.list.d/php.list /etc/apt/trusted.gpg.d/php.gpg
	# systemd-дропины ReadWritePaths=/usr/local/ispconfig (наш ispconfig-rw.conf и ispconfig.conf от самой панели)
	_un_rm /etc/systemd/system/php*-fpm.service.d
	# Ubuntu: PPA Ondřej Surý (на Debian этих файлов нет — глоб просто не раскроется)
	_un_rm /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list /etc/apt/sources.list.d/ondrej-ubuntu-php-*.sources
	[[ "${DRY_RUN:-0}" != "1" ]] && systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
}
uninstall_webserver() {
	# Не доверяем WEBSERVER из setup.conf вслепую (конфиг может отсутствовать/быть
	# рассинхронизирован). Удаляем то, что РЕАЛЬНО установлено; setup.conf — лишь подсказка.
	local ws="${WEBSERVER:-}"
	local have_apache=0 have_nginx=0
	{ dpkg -l apache2 2>/dev/null | grep -q '^ii' || [[ -d /etc/apache2 ]]; } && have_apache=1
	{ [[ -x /usr/sbin/nginx ]] || [[ -d /etc/nginx ]] || command -v nginx >/dev/null 2>&1; } && have_nginx=1
	# Если ничего не детектится — опираемся на заявленный в конфиге.
	if [[ $have_apache -eq 0 && $have_nginx -eq 0 ]]; then
		[[ "$ws" == "apache" ]] && have_apache=1 || have_nginx=1
	fi

	if [[ $have_apache -eq 1 ]]; then
		_un_stop apache2; _un_purge 'apache2*' 'libapache2-mod-*'; _un_rm /etc/apache2
	fi
	if [[ $have_nginx -eq 1 ]]; then
		# nginx — кастомная сборка: сервис, бинарь, equivs-пакет, исходники
		_un_stop nginx
		_un_purge nginx   # удаляет equivs-обёртку nginx
		_un_rm /lib/systemd/system/nginx.service /etc/logrotate.d/nginx /etc/systemd/system/nginx.service.d
		_un_rm /usr/sbin/nginx /usr/sbin/nginx.backup
		_un_rm /etc/nginx /var/cache/nginx /usr/local/src/nginx
		_un_rm_data /var/www/html
	fi

	# CrowdSec — это FIREWALL, не веб-сервер: чистим независимо от выбранного сервера
	# (раньше сидело только в nginx-ветке → на apache оставался мусор). Плюс apt-репозиторий
	# и ключ от install.crowdsec.net, иначе `apt update` будет ругаться на отсутствующий источник.
	if dpkg -l crowdsec 2>/dev/null | grep -q '^ii' || [[ -e /etc/crowdsec ]]; then
		_un_stop crowdsec crowdsec-firewall-bouncer crowdsec-hubupdate.timer; _un_purge 'crowdsec*'; _un_rm /etc/crowdsec
		_un_rm /etc/apt/sources.list.d/crowdsec_crowdsec.list /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg \
		       /usr/share/keyrings/crowdsec_crowdsec-archive-keyring.gpg
		# Остаточная nft-таблица бунсера
		[[ "${DRY_RUN:-0}" != "1" ]] && command -v nft >/dev/null 2>&1 && {
			nft delete table inet crowdsec >>"$SETUP_LOG" 2>&1 || true
			nft delete table ip crowdsec   >>"$SETUP_LOG" 2>&1 || true
		}
	fi
	# еженедельное обновление сценариев CrowdSec: снимаем, даже если сам CrowdSec уже удалён
	_un_rm /etc/cron.d/ss-crowdsec-hub /usr/local/sbin/ss-crowdsec-hub-upgrade
	[[ "${DRY_RUN:-0}" != "1" ]] && systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
}
uninstall_database() {
	_un_stop mariadb redis-server
	_un_purge 'mariadb-server*' 'mariadb-client*' mariadb-common 'redis*'
	_un_rm /etc/apt/sources.list.d/mariadb.list /etc/apt/sources.list.d/mariadb.sources /etc/apt/keyrings/mariadb-keyring*.gpg
	_un_rm /etc/mysql/mariadb.conf.d/99-luckystack.cnf /etc/redis /etc/systemd/system/mariadb.service.d
	# /root/.my.cnf — ключ к сохранённым базам: без него новая установка в них не попадёт
	# (пароль root в /var/lib/mysql остаётся старым). Удаляем только вместе с данными.
	if [[ "${PURGE_DATA:-n}" == "y" ]]; then _un_rm /root/.my.cnf
	else ui_info "  (пароль root MariaDB оставлен в /root/.my.cnf: он нужен, чтобы новая установка открыла сохранённые базы)"; fi
	_un_rm_data /var/lib/mysql /var/lib/redis
}

# --- Оркестратор -------------------------------------------------------------
run_uninstall() {
	require_root
	[[ "${DRY_RUN:-0}" != "1" ]] && check_os

	clear 2>/dev/null || true
	ui_header "Удаление компонентов сервера"
	ui_warn "ЭТО НЕОБРАТИМАЯ ОПЕРАЦИЯ. Будут удалены пакеты и конфиги выбранных компонентов."
	config_load || true

	local un_full=0
	# Режим: полное / частичное
	ui_menu "Что удалить?" 3 \
		"Полное удаление (все компоненты)" \
		"Частичное (выбрать компоненты)" \
		"Отмена"
	case "$UI_MENU_CHOICE" in
		3) ui_info "Отменено."; return 0 ;;
		1) UN_SELECTED="$UNINSTALL_ORDER"; un_full=1 ;;
		2)
			# Чеклист в порядке установки (читабельнее), удалять будем в обратном
			local args=() key
			for key in php webserver database nodejs phpmyadmin postgresql mail rspamd dns ftp ssl security monit webmail ispconfig malware; do
				args+=("$key" "${UNINSTALL_LABEL[$key]}")
			done
			ui_checklist "Компоненты для удаления" "" "${args[@]}"
			UN_SELECTED="$UI_CHECK_RESULT"
			;;
	esac
	[[ -z "${UN_SELECTED// }" ]] && { ui_info "Ничего не выбрано — выход."; return 0; }

	# Удалять ли ДАННЫЕ (БД, почта, сайты)? --purge задаёт это заранее.
	echo ""
	if [[ "${PURGE_DATA:-n}" == "y" ]]; then
		ui_warn "Флаг --purge: ДАННЫЕ (БД/почта/сайты) будут УДАЛЕНЫ."
	else
		ui_warn "Данные (БД MariaDB/PostgreSQL, почта /var/mail, сайты /var/www) по умолчанию СОХРАНЯЮТСЯ."
		if ui_confirm "Удалить также ДАННЫЕ (НЕОБРАТИМО, потеря БД/писем/сайтов)?" n; then
			PURGE_DATA=y
		else
			PURGE_DATA=n
		fi
	fi

	# Финальное подтверждение
	echo ""
	ui_box_top "Будет удалено"
	local k
	for k in $UNINSTALL_ORDER; do
		[[ " $UN_SELECTED " == *" $k "* ]] && ui_box_line "  ${UI_R}✗${UI_NC} ${UNINSTALL_LABEL[$k]}"
	done
	ui_box_line "Данные: ${UI_W}$([[ "$PURGE_DATA" == "y" ]] && echo "УДАЛИТЬ (purge)" || echo "сохранить")${UI_NC}"
	ui_box_bottom
	echo ""
	local ans
	read -rp "$(echo -e "${UI_R}Для подтверждения введите${UI_NC} ${UI_W}REMOVE${UI_NC}: ")" ans
	[[ "$ans" == "REMOVE" ]] || { ui_info "Не подтверждено — выход."; return 0; }

	log_init; log "=== UNINSTALL: [$UN_SELECTED] purge_data=$PURGE_DATA ==="

	# Удаление в ОБРАТНОМ порядке
	for k in $UNINSTALL_ORDER; do
		[[ " $UN_SELECTED " == *" $k "* ]] || continue
		ui_step "Удаление: ${UNINSTALL_LABEL[$k]}"
		"uninstall_${k}" || ui_warn "Ошибки при удалении ${k} — см. $SETUP_LOG."
		# сбросить статус этапа, чтобы повторная установка прошла заново
		state_set "$k" pending 2>/dev/null || true
		[[ "$k" == "webserver" ]] && { state_set nginx pending 2>/dev/null; state_set apache pending 2>/dev/null; }
	done
	# Swap (создан в preflight) снимаем при удалении ядра — когда сносится БД (это
	# фактически разбор стека). Только наш swap (по маркеру в fstab).
	[[ " $UN_SELECTED " == *" database "* ]] && _un_remove_swap
	# Уведомления (helper+монитор+таймер) — кросс-компонентны, чистим всегда (по факту наличия)
	declare -F _un_remove_notify >/dev/null && _un_remove_notify
	_un_autoremove
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		# ссылки на юниты удалённых пакетов (crowdsec-hubupdate.timer и т.п.) и их статус failed
		find /etc/systemd/system -xtype l -name 'crowdsec*' -delete 2>/dev/null || true
		systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
		systemctl reset-failed >>"$SETUP_LOG" 2>&1 || true
	fi

	# Полное удаление → чистим конфиг и состояние установщика (они устаревают: старый
	# выбор веб-сервера/компонентов, прогресс этапов), чтобы следующая установка шла
	# с чистого листа. Лог оставляем как историю.
	if ((un_full)); then
		if [[ "${DRY_RUN:-0}" == "1" ]]; then
			ui_info "${UI_D}[dry-run]${UI_NC} удалить setup.conf + setup.state (полное удаление)"
		else
			[[ -n "${CONFIG_FILE:-}" ]] && rm -f "$CONFIG_FILE"
			[[ -n "${STATE_FILE:-}" ]] && rm -f "$STATE_FILE"
			rm -f "${APT_LOCK_CONF:-/etc/apt/apt.conf.d/50luckystack-lock}"
			ui_info "setup.conf и setup.state удалены — следующая установка начнётся с чистого листа (лог сохранён)."
		fi
	fi

	echo ""
	ui_success "Удаление завершено. Данные: $([[ "$PURGE_DATA" == "y" ]] && echo "удалены" || echo "сохранены")."
	ui_info "Лог: ${SETUP_LOG}"
	if ((un_full)) && [[ -e "${LS_OPT_DIR:-/opt/luckystack}/current" ]]; then
		ui_info "Сам LuckyStack остался: код в ${LS_OPT_DIR}, команда luckyctl. Убрать совсем:"
		ui_info "  rm -rf ${LS_OPT_DIR} ${LS_ETC_DIR} ${LS_VAR_DIR} ${LS_LOG_DIR} ${LS_BIN:-/usr/local/sbin/luckyctl}"
	fi
}
