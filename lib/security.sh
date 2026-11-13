#!/bin/bash
# =============================================================================
# lib/security.sh — Этап (опц.): базовая защита сервера.
#   fail2ban — бан брутфорса (sshd и др.; ISPConfig добавит свои jail'ы)
#   firewall — UFW или CrowdSec (по FIREWALL; CrowdSec ставится в nginx-этапе)
#   rkhunter — детектор руткитов
#   jailkit  — chroot для SSH-пользователей (нужен ISPConfig, configure_jailkit=y)
# =============================================================================

stage_security() {
	local _audit="Lynis=${SEC_LYNIS:-y} rkhunter=${SEC_RKHUNTER:-n}"
	ui_info "Безопасность: fail2ban + firewall(${FIREWALL:-—}) + jailkit · аудит: ${_audit}"

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt install fail2ban + базовый jail sshd"
		ui_info "${UI_D}[dry-run]${UI_NC} firewall: ${FIREWALL:-none} (ufw → правила+IPv6; crowdsec → в nginx-этапе)"
		ui_info "${UI_D}[dry-run]${UI_NC} jail'ы fail2ban под стек ISPConfig (postfix/dovecot/ftp/панель)"
		[[ "${SEC_SYSCTL:-y}" == "y" ]] && ui_info "${UI_D}[dry-run]${UI_NC} sysctl-харденинг (анти-спуфинг, SYN cookies, ASLR)"
		[[ -n "${ISPCONFIG_ADMIN_IPS:-}" ]] && \
			ui_info "${UI_D}[dry-run]${UI_NC} панель ограничена админ-IP: ${ISPCONFIG_ADMIN_IPS}"
		[[ "${SEC_AUTO_UPDATES:-y}" == "y" ]] && ui_info "${UI_D}[dry-run]${UI_NC} apt install unattended-upgrades + авто security-обновления"
		[[ "${SEC_WORLDWRITABLE:-report}" != "off" ]] && ui_info "${UI_D}[dry-run]${UI_NC} аудит world-writable (${SEC_WORLDWRITABLE:-report})"
		[[ "${SEC_LYNIS:-y}" == "y" ]]    && ui_info "${UI_D}[dry-run]${UI_NC} apt install lynis + стартовый аудит (только отчёт)"
		[[ "${SEC_RKHUNTER:-n}" == "y" ]] && ui_info "${UI_D}[dry-run]${UI_NC} apt install rkhunter + --propupd"
		ui_info "${UI_D}[dry-run]${UI_NC} apt install jailkit"
		ui_success "Безопасность (имитация) настроена."
		return 0
	fi

	# --- fail2ban ---
	ui_step "Установка fail2ban"
	# python3-systemd — для backend=systemd (Debian 12+ journald-only: без него jail
	# sshd ищет /var/log/auth.log, которого нет → fail2ban не стартует).
	apt_install fail2ban python3-systemd
	# Базовый jail пишем в jail.d/ (а НЕ условно в jail.local): раньше было
	# `if [[ ! -f jail.local ]]` — если файл уже существовал (даже пустой), наш [DEFAULT]/[sshd]
	# НЕ применялся, и брутфорс по SSH не банился. jail.d/*.conf читается всегда и переопределяет
	# дефолты jail.conf; пустой jail.local его не перебивает.
	mkdir -p /etc/fail2ban/jail.d
	cat >/etc/fail2ban/jail.d/00-luckystack.conf <<'F2B'
# luckystack: базовые настройки fail2ban (default + sshd)
[DEFAULT]
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
F2B
	sys_run "Запуск fail2ban" systemctl enable --now fail2ban

	# --- Расширенные jail'ы под стек ISPConfig (почта/FTP/панель) ---
	_security_fail2ban_jails

	# --- Firewall ---
	_security_firewall

	# --- Сетевой/ядровый харденинг (sysctl) ---
	_security_sysctl_hardening

	# --- Ограничения служб и таймауты клиентов ---
	_security_service_hardening
	declare -F _nginx_tight_timeouts >/dev/null && _nginx_tight_timeouts

	# --- Автообновления безопасности (unattended-upgrades) ---
	_security_auto_updates

	# --- Предел журнала systemd ---
	_security_journald

	# --- Lynis (аудит безопасности; РЕКОМЕНДУЕТСЯ, активно поддерживается) ---
	# Только READ-ONLY аудит: ставит пакет и делает стартовый отчёт, НИЧЕГО не меняет
	# в системе. С ISPConfig уживается (не демон, не трогает конфиги/порты).
	if [[ "${SEC_LYNIS:-y}" == "y" ]]; then
		ui_step "Установка Lynis (аудит безопасности)"
		apt_install lynis
		if command -v lynis >/dev/null 2>&1; then
			ui_spin "Стартовый аудит Lynis (только отчёт, ~1-2 мин)" bash -c \
				"lynis audit system --quick --no-colors </dev/null >>'$SETUP_LOG' 2>&1"
			local hi; hi="$(grep -a '^hardening_index=' /var/log/lynis-report.dat 2>/dev/null | tail -1 | cut -d= -f2)"
			ui_success "Lynis установлен${hi:+ (hardening index: ${hi}/100)}. Отчёт: /var/log/lynis.log"
			ui_info "Повторный аудит: ${UI_W}lynis audit system${UI_NC}. Рекомендации применяйте с оглядкой на ISPConfig."
		fi
	fi

	# --- rkhunter (ОПЦИЯ, по умолчанию ВЫКЛ) ---
	# Сигнатурный сканер руткитов. Upstream практически не развивается (1.4.6, 2018),
	# базы устарели → ценность невысокая, особенно при работающем CrowdSec. Ставится
	# только если явно включён (SEC_RKHUNTER=y).
	if [[ "${SEC_RKHUNTER:-n}" == "y" ]]; then
		ui_step "Установка rkhunter (по запросу)"
		apt_install rkhunter binutils
		# Debian-пакет ставит WEB_CMD="/bin/false" → rkhunter считает невалидным; фикс — пусто.
		sed -i 's|^WEB_CMD=.*|WEB_CMD=""|' /etc/rkhunter.conf 2>/dev/null || true
		# В grep ≥3.8 удалены egrep/fgrep, а дефолтный rkhunter.conf держит их в
		# SCRIPTWHITELIST → «Invalid SCRIPTWHITELIST». Комментируем несуществующие пути.
		local _b
		for _b in egrep fgrep; do
			command -v "$_b" >/dev/null 2>&1 || \
				sed -i -E "\|^[[:space:]]*SCRIPTWHITELIST=/(usr/)?bin/${_b}[[:space:]]*\$|s|^|#|" /etc/rkhunter.conf 2>/dev/null || true
		done
		# Обновление баз — необязательно (зеркала часто недоступны), не пугаем «ошибкой».
		if rkhunter --update >>"$SETUP_LOG" 2>&1; then
			ui_success "rkhunter: базы детекта обновлены."
		else
			ui_info "rkhunter: обновление баз пропущено (зеркала недоступны — не критично)."
		fi
		ui_spin "rkhunter --propupd (базовый снимок свойств файлов)" rkhunter --propupd || \
			ui_warn "rkhunter --propupd завершился с замечаниями (не критично) — см. $SETUP_LOG."
	fi

	_security_rkhunter_apt

	# --- AIDE (ОПЦИЯ, SEC_AIDE=y) ---
	_security_aide

	# --- jailkit (нужен ISPConfig для chroot SSH) ---
	ui_step "Установка jailkit"
	apt_install jailkit || ui_warn "jailkit недоступен в репозитории — ISPConfig соберёт его сам при необходимости."

	# --- Конфиги стека: снять запись для «других» (всегда, это наши каталоги) ---
	_security_fix_stack_perms

	# --- Аудит файлов, доступных на запись всем (world-writable) ---
	_security_world_writable

	ui_success "Безопасность настроена."
	log "security: fail2ban, firewall=${FIREWALL}, jailkit, lynis=${SEC_LYNIS:-y}, rkhunter=${SEC_RKHUNTER:-n}, auto_updates=${SEC_AUTO_UPDATES:-y}, ww=${SEC_WORLDWRITABLE:-report}"
	return 0
}

# --- Автообновления безопасности (unattended-upgrades) -----------------------
# Ставит только обновления безопасности (origin -security), без авто-перезагрузки.
# Источники берём из дефолтного 50unattended-upgrades (он корректно настроен и для
# Debian, и для Ubuntu) — мы лишь включаем периодический запуск и безопасные опции.
_security_auto_updates() {
	[[ "${SEC_AUTO_UPDATES:-y}" == "y" ]] || { ui_info "Автообновления безопасности отключены (SEC_AUTO_UPDATES=n)."; return 0; }
	ui_step "Автообновления безопасности (unattended-upgrades)"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt install unattended-upgrades + периодический запуск (только security)"
		return 0
	fi
	apt_install unattended-upgrades || { ui_warn "unattended-upgrades недоступен — пропуск."; return 0; }
	cat >/etc/apt/apt.conf.d/20auto-upgrades <<'AU'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AU
	# Отчёт на почту — только при ошибках, на первый адрес уведомлений (иначе root).
	local mail="${NOTIFY_EMAIL:-}"; mail="${mail%%,*}"; mail="${mail// /}"
	cat >/etc/apt/apt.conf.d/52luckystack-unattended <<UU
// LuckyStack — параметры авто-обновлений.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Mail "${mail:-root}";
Unattended-Upgrade::MailReport "only-on-error";
UU
	# Сторонние репозитории стека (SEC_AUTO_UPDATES_3RD=y по умолчанию): PHP (sury), MariaDB,
	# Rspamd, CrowdSec, Node.js. В Debian-security их нет, а дыры в них закрываются именно там.
	# Неверсионные метапакеты php-* (php-mysql, php-curl…) не обновляем автоматически: когда sury
	# меняет версию PHP по умолчанию, их обновление притянуло бы целую новую версию PHP
	# (так на сервер попадала лишняя 8.5). Версионные php8.x-* обновляются как обычно.
	if [[ "${SEC_AUTO_UPDATES_3RD:-y}" == "y" ]]; then
		cat >/etc/apt/apt.conf.d/53luckystack-unattended-3rd <<'UU'
// LuckyStack — автообновления из сторонних репозиториев стека (SEC_AUTO_UPDATES_3RD=y)
Unattended-Upgrade::Origins-Pattern {
	"origin=deb.sury.org,codename=${distro_codename}";
	"origin=MariaDB,codename=${distro_codename},label=MariaDB";
	"origin=Rspamd,codename=${distro_codename}";
	"origin=packagecloud.io/crowdsec/crowdsec";
	"site=deb.nodesource.com";
};
Unattended-Upgrade::Package-Blacklist {
	"^php$";
	"^php-(cli|fpm|cgi|mysql|pgsql|sqlite3|mbstring|xml|json|curl|gd|zip|bz2|intl|ldap|soap|bcmath|gmp|imap|readline|opcache|tidy|xmlrpc|xsl|apcu|igbinary|imagick|memcached|msgpack|redis|mcrypt|mongodb|yaml|uuid|ssh2|xdebug|pcov|ast|ds|grpc|protobuf|raphf|http|oauth|smbclient|zmq|amqp|gnupg|lz4|zstd|maxminddb|mailparse|psr|solr|swoole|uploadprogress|vips|inotify|rrd|excimer|libvirt-php|geoip)$";
};
UU
	else
		rm -f /etc/apt/apt.conf.d/53luckystack-unattended-3rd
	fi
	# needrestart: после обновления библиотек (openssl, libc…) перезапускает службы, которые
	# держат старую копию в памяти — без этого обновление безопасности не действует до ребута.
	apt_install needrestart >/dev/null 2>&1 || true
	if [[ -d /etc/needrestart ]]; then
		mkdir -p /etc/needrestart/conf.d
		cat >/etc/needrestart/conf.d/50-luckystack.conf <<'NR'
# luckystack: без вопросов перезапускать службы после обновлений (в т.ч. из unattended-upgrades)
$nrconf{restart} = 'a';
# о новом ядре сообщает монитор (reboot-required), здесь не дёргаем
$nrconf{kernelhints} = 0;
# обновление, запущенное из панели, не перезапускать на середине
$nrconf{override_rc}{qr(^ss-maint-job-)} = 0;
NR
	fi
	# Таймеры apt-daily включены по умолчанию; на всякий случай не глушим их.
	systemctl enable unattended-upgrades >>"$SETUP_LOG" 2>&1 || true
	ui_success "Автообновления включены: security Debian$([[ "${SEC_AUTO_UPDATES_3RD:-y}" == y ]] && echo ' + PHP (sury), MariaDB, Rspamd, CrowdSec, Node.js') (без авто-перезагрузки, службы перезапускает needrestart, ошибки — на ${mail:-root})."
	ui_info "Проверка вручную: ${UI_W}unattended-upgrade --dry-run -d${UI_NC}"
}

# Ограничения служб через systemd (SEC_SERVICE_HARDEN=y). Если служба с ними не поднимается,
# ограничения снимаются сами. Только nginx и MariaDB: PHP-FPM не трогаем, сайтам нужен sendmail
# с setgid, а NoNewPrivileges его ломает. MemoryDenyWriteExecute несовместим с PCRE JIT.
_svc_harden_write() {   # служба, текст drop-in
	local svc="$1" body="$2" dir="/etc/systemd/system/$1.service.d" prev=""
	local f="$dir/50-luckystack-harden.conf"
	systemctl cat "$svc.service" >/dev/null 2>&1 || return 0
	[[ -f "$f" && "$(cat "$f")" == "$body" ]] && return 0
	[[ -f "$f" ]] && prev="$(cat "$f")"
	mkdir -p "$dir"
	printf '%s\n' "$body" >"$f"; chmod 644 "$f"
	systemctl daemon-reload >>"$SETUP_LOG" 2>&1
	if systemctl restart "$svc" >>"$SETUP_LOG" 2>&1 && sleep 2 && systemctl is-active --quiet "$svc"; then
		ui_success "${svc}: ограничения systemd применены."
		return 0
	fi
	if [[ -n "$prev" ]]; then printf '%s\n' "$prev" >"$f"; else rm -f "$f"; fi
	systemctl daemon-reload >>"$SETUP_LOG" 2>&1
	systemctl restart "$svc" >>"$SETUP_LOG" 2>&1
	ui_warn "${svc}: с ограничениями служба не запустилась, откатил. См. journalctl -u ${svc}"
	return 1
}

_svc_harden_remove() {
	local svc="$1" f="/etc/systemd/system/$1.service.d/50-luckystack-harden.conf"
	[[ -f "$f" ]] || return 0
	rm -f "$f"
	systemctl daemon-reload >>"$SETUP_LOG" 2>&1
	systemctl restart "$svc" >>"$SETUP_LOG" 2>&1
	ui_info "${svc}: ограничения systemd сняты."
}

_security_service_hardening() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	if [[ "${SEC_SERVICE_HARDEN:-n}" != "y" ]]; then
		_svc_harden_remove nginx
		_svc_harden_remove mariadb
		return 0
	fi
	local rc=0 common
	common='NoNewPrivileges=yes
ProtectSystem=full
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native'
	if command -v nginx >/dev/null 2>&1; then
		_svc_harden_write nginx "# luckystack: SEC_SERVICE_HARDEN=y
[Service]
${common}
ProtectHome=read-only
PrivateDevices=yes
RestrictRealtime=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID CAP_CHOWN CAP_DAC_OVERRIDE CAP_DAC_READ_SEARCH CAP_FOWNER CAP_KILL CAP_SYS_RESOURCE CAP_BPF CAP_NET_ADMIN CAP_SYS_ADMIN" || rc=1
	fi
	if command -v mariadbd >/dev/null 2>&1; then
		_svc_harden_write mariadb "# luckystack: SEC_SERVICE_HARDEN=y
[Service]
${common}
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" || rc=1
	fi
	return "$rc"
}

# Журнал systemd: без лимита дорастал до 4 ГБ (прод). SystemMaxUse по умолчанию 500M (JOURNAL_MAX).
_security_journald() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	local max="${JOURNAL_MAX:-500M}" f=/etc/systemd/journald.conf.d/50-luckystack.conf tmp
	mkdir -p "${f%/*}"
	tmp="$(mktemp)"
	printf '# luckystack: предел журнала systemd (JOURNAL_MAX)\n[Journal]\nSystemMaxUse=%s\n' "$max" >"$tmp"
	if [[ -f "$f" ]] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
	install -m 644 "$tmp" "$f"; rm -f "$tmp"
	local before; before="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1)"
	systemctl restart systemd-journald >>"$SETUP_LOG" 2>&1 || true
	journalctl --vacuum-size="$max" >>"$SETUP_LOG" 2>&1 || true
	ui_success "Журнал systemd ограничен ${max} (было ${before:-?}, стало $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1))."
}

# rkhunter (если стоит): после каждого apt обновлять базу свойств файлов — иначе после обновлений
# пакетов rkhunter сыплет ложными тревогами «файл изменён» (на проде так и было: curl, perl).
_security_rkhunter_apt() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	[[ -f /etc/default/rkhunter ]] || return 0
	grep -qE '^APT_AUTOGEN="?true"?' /etc/default/rkhunter && return 0
	if grep -qE '^APT_AUTOGEN=' /etc/default/rkhunter; then
		sed -i -E 's/^APT_AUTOGEN=.*/APT_AUTOGEN="true"/' /etc/default/rkhunter
	else
		echo 'APT_AUTOGEN="true"' >>/etc/default/rkhunter
	fi
	rkhunter --propupd >>"$SETUP_LOG" 2>&1 || true
	ui_success "rkhunter: база свойств файлов обновляется после каждого apt (APT_AUTOGEN), снимок обновлён."
}

# AIDE — контроль целостности системных файлов (SEC_AIDE=y, по умолчанию выкл.). Сайты, почта,
# базы и журналы исключены: они меняются постоянно и дали бы шум. Отчёт — ежедневным cron пакета.
_security_aide() {
	[[ "${SEC_AIDE:-n}" == "y" ]] || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} AIDE + исключения /var/www, почты, БД"; return 0; }
	apt_install aide aide-common || { ui_warn "AIDE не установился."; return 0; }
	mkdir -p /etc/aide/aide.conf.d
	cat >/etc/aide/aide.conf.d/99_luckystack <<'AIDE'
# luckystack: меняющиеся данные не контролируем
!/var/www
!/var/vmail
!/var/lib/mysql
!/var/lib/php
!/var/lib/rspamd
!/var/lib/clamav
!/var/lib/crowdsec
!/var/log
!/var/backups
!/var/cache
!/var/tmp
!/tmp
!/usr/local/ispconfig/server/temp
!/usr/local/ispconfig/interface/temp
!/quota\.(user|group)$
!/run/pure-ftpd(/|$)
!/run/user/
AIDE
	if [[ ! -f /var/lib/aide/aide.db ]]; then
		# первая база строится несколько минут — в фоне, чтобы не держать установку
		nohup sh -c 'aideinit -y -f >/var/log/aide-init.log 2>&1' >/dev/null 2>&1 &
		ui_success "AIDE установлен; первая база строится в фоне (журнал /var/log/aide-init.log), дальше — ежедневная проверка."
	else
		ui_info "AIDE уже настроен (база /var/lib/aide/aide.db)."
	fi
}

# --- Конфиги стека без записи для «других» ------------------------------------
# В отличие от аудита ниже (он про весь /etc, /usr/local, /var/www и по умолчанию только
# отчёт), здесь чиним всегда: это каталоги, которые читают от root nginx, php-fpm,
# postfix/dovecot и cron ISPConfig. Запись для всех там бывает только по ошибке.
_security_fix_stack_perms() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} снять запись для всех с конфигов стека"; return 0; }
	local n; n="$(perm_fix_stack_conf)"
	# Сниппеты nginx целиком наши: выравниваем полностью (777 → 755/644, а не 775).
	perm_conf_tree /etc/nginx/snippets
	if ((n > 0)); then
		ui_warn "Конфиги стека: снята запись для всех с ${n} файлов/каталогов (список в ${SETUP_LOG})."
	else
		ui_success "Конфиги стека: открытых на запись всем файлов нет."
	fi
}

# --- Аудит world-writable файлов ---------------------------------------------
# Сканируем чувствительные пути (не весь диск — иначе медленно и шумно из-за /tmp,
# /proc и т.п.). Режим из SEC_WORLDWRITABLE: report (по умолч.), fix, off.
_security_world_writable() {
	local mode="${SEC_WORLDWRITABLE:-report}"
	[[ "$mode" == "off" ]] && return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} аудит world-writable (${mode})"; return 0; }
	ui_step "Аудит файлов, доступных на запись всем (world-writable)"
	local list rep=/root/world-writable-files.txt
	# -xdev: не пересекать ФС; -type f: только файлы; -perm -0002: бит записи для «других».
	list="$(find /etc /usr/local /var/www -xdev -type f -perm -0002 ! -type l 2>/dev/null)"
	if [[ -z "$list" ]]; then
		ui_success "World-writable файлов в /etc, /usr/local, /var/www не найдено."
		return 0
	fi
	local n; n="$(printf '%s\n' "$list" | grep -c .)"
	printf '%s\n' "$list" >"$rep"
	ui_warn "Найдено world-writable файлов: ${n} (список: ${rep})"
	printf '%s\n' "$list" | head -20 | sed 's/^/    /'
	((n > 20)) && ui_info "    … ещё $((n - 20)) — см. ${rep}"
	if [[ "$mode" == "fix" ]]; then
		printf '%s\n' "$list" | while IFS= read -r f; do [[ -n "$f" ]] && chmod o-w "$f" 2>/dev/null; done
		ui_success "Права исправлены (снят бит записи для «других»). Отчёт: ${rep}"
	else
		ui_info "Только отчёт (исправление выключено). Чтобы исправить: chmod o-w <файл> или SEC_WORLDWRITABLE=fix."
	fi
}

# Открыть SSH-порт в UFW: только с разрешённых IP (SSH_ALLOW_IPS) либо со всех.
# rc=0, если текущий SSH-адрес есть в SSH_ALLOW_IPS, ИЛИ список пуст, ИЛИ адрес нельзя
# определить (запуск из консоли/cron — не мешаем). rc=1 — текущий адрес НЕ в списке
# (применение ограничения отрезало бы админа). Единая самозащита для ufw и sshd.
_ssh_current_ip_allowed() {
	[[ -n "${SSH_ALLOW_IPS:-}" ]] || return 0
	local cur ip; cur="$(_detect_ssh_ip 2>/dev/null)"
	# НЕ смогли определить текущий IP (напр. запуск не по SSH) → НЕ подтверждаем «в списке»:
	# возвращаем 1, чтобы вызывающий открыл порт СО ВСЕХ (анти-локаут), а не ограничил вслепую.
	[[ -z "$cur" ]] && return 1
	for ip in $SSH_ALLOW_IPS; do [[ "$cur" == "$ip" ]] && return 0; done
	return 1
}

# ufw должен быть включён, но ENABLED=no: штатный firewall_plugin ISPConfig при установке вызывает
# «ufw --force disable». Коварство в том, что правила остаются в ядре и «ufw status» пишет active,
# но «ufw reload» молча пропускается («Firewall not enabled»), новые правила не применяются, а
# после перезагрузки фаервола нет вообще. Включаем, если наш адрес не окажется отрезан.
_ufw_is_enabled() { grep -qE '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; }
_ufw_ensure_enabled() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	command -v ufw >/dev/null 2>&1 || return 0
	[[ "${FIREWALL:-none}" == "ufw" || "${CROWDSEC_WITH_UFW:-n}" == "y" ]] || return 0
	_ufw_is_enabled && return 0
	local cur; cur="$(_detect_ssh_ip 2>/dev/null)"
	if [[ -n "$cur" && -n "${SSH_ALLOW_IPS:-}" && " ${SSH_ALLOW_IPS} " != *" ${cur} "* ]]; then
		ui_warn "ufw выключен (ENABLED=no), но ваш адрес ${cur} не в SSH_ALLOW_IPS — не включаю, чтобы не отрезать доступ. Добавьте адрес и повторите."
		return 0
	fi
	if ufw --force enable >>"$SETUP_LOG" 2>&1 && _ufw_is_enabled; then
		ui_success "ufw был выключен (ENABLED=no): правила не обновлялись, после перезагрузки фаервола не было бы. Включён."
	else
		ui_warn "Не удалось включить ufw — см. ${SETUP_LOG}. Проверьте: ufw status verbose; grep ENABLED /etc/ufw/ufw.conf"
	fi
	return 0
}

_ufw_allow_ssh() {
	local port="$1" ip
	[[ -n "$port" ]] || return 0
	# Самозащита от лок-аута: если текущий адрес не в SSH_ALLOW_IPS — открываем СО ВСЕХ
	# (не ограничиваем), иначе firewall отрежет админа.
	if [[ -n "${SSH_ALLOW_IPS:-}" ]] && _ssh_current_ip_allowed; then
		for ip in $SSH_ALLOW_IPS; do
			ufw allow from "$ip" to any port "$port" proto tcp >>"$SETUP_LOG" 2>&1
		done
	else
		[[ -n "${SSH_ALLOW_IPS:-}" ]] && ui_warn "SSH-порт ${port}: текущий адрес не в SSH_ALLOW_IPS — открыл со ВСЕХ, чтобы не отрезать доступ."
		ufw allow "${port}/tcp" >>"$SETUP_LOG" 2>&1
	fi
}

# Настройка UFW: открыть нужные порты + включить. Вынесено в helper, чтобы
# crowdsec-фоллбэк (в т.ч. на Apache) мог переиспользовать и не оставить сервер без firewall.
_security_firewall_ufw() {
	ui_step "Настройка UFW"
	# Если на сервере остался CrowdSec firewall-bouncer (от прошлой установки или
	# неудавшегося выбора FIREWALL=crowdsec), он ВЛАДЕЕТ nftables и конфликтует с UFW:
	# «ufw enable» проходит, но правила не применяются / firewall не поднимается.
	# Раз активный firewall теперь UFW — глушим бунсер (детектор crowdsec можно оставить,
	# он nftables не трогает, но без бунсера он бесполезен → тоже стопаем).
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		# ВАЖНО: НЕ проверяем наличие юнита через `systemctl list-unit-files | grep` —
		# под `set -o pipefail` grep закрывает pipe после первого совпадения, systemctl
		# падает с SIGPIPE (exit 141), и весь блок молча пропускается. Просто пытаемся
		# остановить безусловно: на отсутствующем юните `disable --now` безвредно (|| true).
		local _csvc
		for _csvc in crowdsec-firewall-bouncer crowdsec; do
			if systemctl is-active --quiet "$_csvc" 2>/dev/null; then
				ui_info "Останавливаю остаточный ${_csvc} (конфликтует с UFW за nftables)."
			fi
			systemctl disable --now "$_csvc" >>"$SETUP_LOG" 2>&1 || true
		done
		# nft-таблица бунсера могла остаться и держать правила — сносим, чтобы UFW начал с чистого.
		if command -v nft >/dev/null 2>&1; then
			nft delete table inet crowdsec >>"$SETUP_LOG" 2>&1 || true
			nft delete table ip   crowdsec >>"$SETUP_LOG" 2>&1 || true
		fi
	fi
	_security_ufw_ports
}

# Правила портов UFW + включение. БЕЗ гашения crowdsec — поэтому переиспользуется и
# в crowdsec-режиме (ufw фильтрует ПОРТЫ default-deny, crowdsec банит IP — правильная связка).
_security_ufw_ports() {
	apt_install ufw
	# Включаем поддержку IPv6 в UFW (по умолчанию бывает выключена).
	[[ -f /etc/default/ufw ]] && sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw 2>/dev/null || true
	# SSH: текущий порт 22 + целевой SSH_PORT (меняется в конце) — оба держим
	# открытыми, чтобы смена порта не отрезала доступ. С ограничением по IP,
	# если выбрано (SSH_ALLOW_IPS), иначе со всех.
	_ufw_allow_ssh 22
	[[ -n "${SSH_PORT:-}" && "${SSH_PORT}" != "22" ]] && _ufw_allow_ssh "${SSH_PORT}"
	[[ -n "${SSH_ALLOW_IPS:-}" ]] && ui_success "SSH (порты 22${SSH_PORT:+,$SSH_PORT}) ограничен IP: ${SSH_ALLOW_IPS}"
	ufw allow 80,443/tcp >>"$SETUP_LOG" 2>&1
	# HTTP/3 (QUIC) работает по UDP/443. Без этого правила браузер видит анонс
	# Alt-Svc: h3, стучится по UDP, ответа нет — и МОЛЧА откатывается на HTTP/2,
	# т.е. собранный HTTP/3 фактически не работает под default-deny ufw.
	local _http3="${NGX_HTTP3:-${HTTP3:-n}}"
	if [[ "${WEBSERVER:-nginx}" == "nginx" && "$_http3" == "y" ]]; then
		ufw allow 443/udp >>"$SETUP_LOG" 2>&1
		ui_info "HTTP/3: открыт UDP/443 (QUIC)."
	fi
	# B2: панель ISPConfig — если заданы админ-IP, пускаем ТОЛЬКО с них
	# (tcp + udp для HTTP/3), иначе со всех. Default deny закроет остальных.
	local _pp="${ISPCONFIG_PANEL_PORT:-8080}" _ip
	if [[ -n "${ISPCONFIG_ADMIN_IPS:-}" ]]; then
		for _ip in $ISPCONFIG_ADMIN_IPS; do
			ufw allow from "$_ip" to any port "$_pp" proto tcp >>"$SETUP_LOG" 2>&1
			ufw allow from "$_ip" to any port "$_pp" proto udp >>"$SETUP_LOG" 2>&1
		done
		ui_success "Панель ISPConfig (порт ${_pp}) ограничена IP: ${ISPCONFIG_ADMIN_IPS}"
	else
		ufw allow "${_pp}/tcp" >>"$SETUP_LOG" 2>&1
		# UDP для HTTP/3 панели (conf-custom добавляет quic-listen при PANEL_HTTP3=y)
		[[ "$_http3" == "y" && "${PANEL_HTTP3:-n}" == "y" ]] && ufw allow "${_pp}/udp" >>"$SETUP_LOG" 2>&1
	fi
	# Apps-vhost ISPConfig (webmail/phpMyAdmin через apps.<домен>) — открываем его порт
	# (доступен пользователям, не только админам) + UDP для HTTP/3 при PANEL_HTTP3.
	local _ap="${ISPCONFIG_APPS_PORT:-8081}"
	if [[ "$_ap" =~ ^[0-9]+$ ]]; then
		ufw allow "${_ap}/tcp" >>"$SETUP_LOG" 2>&1
		[[ "$_http3" == "y" && "${PANEL_HTTP3:-n}" == "y" ]] && ufw allow "${_ap}/udp" >>"$SETUP_LOG" 2>&1
	fi
	if [[ " ${COMPONENTS:-} " == *" mail "* ]]; then
		ufw allow 25,465,587,143,993,110,995/tcp >>"$SETUP_LOG" 2>&1
	fi
	[[ " ${COMPONENTS:-} " == *" dns "* ]] && ufw allow 53 >>"$SETUP_LOG" 2>&1
	[[ " ${COMPONENTS:-} " == *" ftp "* ]] && ufw allow 21/tcp >>"$SETUP_LOG" 2>&1
	# Удалённый доступ к MariaDB (3306) для галочки «Remote Access» в ISPConfig — ТОЛЬКО
	# если включён (MARIADB_REMOTE=y) и ТОЛЬКО с разрешённых IP (MARIADB_REMOTE_IPS).
	# Без списка IP открывать 3306 всему интернету ОПАСНО — предупреждаем.
	if [[ "${MARIADB_REMOTE:-n}" == "y" ]]; then
		if [[ -n "${MARIADB_REMOTE_IPS:-}" ]]; then
			local _mip
			for _mip in $MARIADB_REMOTE_IPS; do
				ufw allow from "$_mip" to any port 3306 proto tcp >>"$SETUP_LOG" 2>&1
			done
			ui_success "MariaDB 3306 открыт для удалённого доступа с IP: ${MARIADB_REMOTE_IPS}"
		else
			ufw allow 3306/tcp >>"$SETUP_LOG" 2>&1
			ui_warn "MariaDB 3306 открыт ВСЕМ (MARIADB_REMOTE_IPS пуст) — небезопасно, лучше задать список IP."
		fi
	fi
	# ufw enable в WSL/контейнерах иногда падает в under_ssh() с
	# «Couldn't find parent pid» (рваное дерево процессов в /proc) — на
	# реальном VDS работает штатно. Сообщаем ЧЕСТНО по факту результата.
	if ui_spin "Включение UFW" bash -c "echo y | ufw enable" && ufw status 2>/dev/null | grep -q "Status: active"; then
		ui_success "UFW настроен и включён (default-deny по портам)."
	else
		ui_warn "Правила UFW записаны, но firewall НЕ активирован."
		ui_info "Частая причина — контейнер/WSL (ufw не может прочитать дерево процессов)."
		ui_info "На боевом сервере включите вручную: ${UI_W}ufw enable${UI_NC} (проверка: ${UI_W}ufw status${UI_NC})."
	fi
	# Жёсткие IP-ограничения, ПЕРЕЖИВАЮЩИЕ ISPConfig-firewall (см. ниже).
	_security_ufw_restrict_persist
}

# Записать наши IP-ограничения в /etc/ufw/before.rules → они срабатывают в цепочке
# ufw-before-input ДО перехода в ufw-user-input (где живут «открытые всем» правила
# ISPConfig-firewall). ufw перечитывает before.rules при каждом reload, а ISPConfig его
# НЕ трогает — значит SSH/панель/3306 остаются только для доверенных IP, даже когда
# ISPConfig открыл эти порты всем. Источник IP — setup.conf. Идемпотентно, IPv4+IPv6,
# с авто-добавлением текущего SSH-IP (анти-локаут) и откатом при сбое ufw reload.
_security_ufw_restrict_persist() {
	command -v ufw >/dev/null 2>&1 || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} жёсткие IP-ограничения в before.rules (переживут ISPConfig-firewall)"; return 0; }
	[[ -f /etc/ufw/before.rules ]] || return 0

	# Текущий IP SSH-сессии — чтобы тот, кто применяет патч, не отрезал себя.
	local cur_ip; declare -F _detect_ssh_ip >/dev/null && cur_ip="$(_detect_ssh_ip 2>/dev/null)"

	# Пары «порт:список_IP» из setup.conf (только где список НЕ пуст).
	local -a specs=()
	# SSH-ограничение по IP (DROP 22 кроме списка) пишем ТОЛЬКО если пользователь его ЗАДАЛ
	# (SSH_ALLOW_IPS непусто) И мы смогли определить текущий IP (добавляем его — анти-локаут).
	# Если IP не определён (напр. sudo вырезал SSH_*) — НЕ пишем DROP-22, иначе можно отрезать
	# админа. Раньше блок создавался даже при пустом SSH_ALLOW_IPS (по cur_ip) → был риск лок-аута.
	if [[ -n "${SSH_ALLOW_IPS:-}" ]]; then
		if [[ -n "$cur_ip" ]]; then
			local ssh_ips="$SSH_ALLOW_IPS"
			[[ " $ssh_ips " != *" $cur_ip "* ]] && ssh_ips="$ssh_ips $cur_ip"
			specs+=("22:${ssh_ips}")
			[[ -n "${SSH_PORT:-}" && "$SSH_PORT" != "22" ]] && specs+=("${SSH_PORT}:${ssh_ips}")
		else
			ui_warn "SSH-ограничение по IP НЕ вшито (не удалось определить ваш текущий IP — риск лок-аута). SSH оставлен доступным; ограничьте вручную после проверки доступа."
		fi
	fi
	if [[ -n "${ISPCONFIG_ADMIN_IPS:-}" ]]; then
		local _pips="$ISPCONFIG_ADMIN_IPS"
		[[ -n "$cur_ip" && " $_pips " != *" $cur_ip "* ]] && _pips+=" $cur_ip"
		specs+=("${ISPCONFIG_PANEL_PORT:-8080}:${_pips}")
	fi
	[[ "${MARIADB_REMOTE:-n}" == "y" && -n "${MARIADB_REMOTE_IPS:-}" ]] && specs+=("3306:${MARIADB_REMOTE_IPS}")
	# HTTP/3 идёт по UDP — открываем его в before.rules (переживёт ISPConfig-firewall, у
	# которого 443/udp в списке нет). Префикс 'u' = udp-открытие всем. spec вида "u<port>:".
	if [[ "${NGX_HTTP3:-${HTTP3:-n}}" == "y" && "${WEBSERVER:-nginx}" == "nginx" ]]; then
		specs+=("u443:")
		[[ "${PANEL_HTTP3:-n}" == "y" ]] && specs+=("u${ISPCONFIG_PANEL_PORT:-8080}:" "u${ISPCONFIG_APPS_PORT:-8081}:")
	fi

	# Если развёрнут модуль панели «Firewall IP-rules» (таблица firewall_restrict), то ВСЕ
	# правила — и публичные порты, и IP-ограничения, и UDP/HTTP/3 — ведёт панель (плагин
	# пишет блок restrict-isp). Тогда базовый слой здесь не пишет ничего (его блок restrict
	# снимается), чтобы не было двух конкурирующих источников.
	# Снимаем базовый блок только когда блок панели (restrict-isp) уже записан: иначе какое-то время
	# не было бы ни того, ни другого. Раньше базовый блок, записанный на этапе security (до установки
	# панели), оставался навсегда и перехватывал правила панели — например его «udp <порт панели>
	# ACCEPT всем» срабатывал раньше ограничения панели по IP.
	if declare -F _ispc_mysql >/dev/null 2>&1 && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] \
		&& _ispc_mysql -N -B -e "SELECT 1 FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='firewall_restrict' LIMIT 1;" 2>/dev/null | grep -q 1; then
		if grep -q '# luckystack: restrict-isp START' /etc/ufw/before.rules 2>/dev/null; then
			specs=()
			ui_info "Модуль «Firewall IP-rules» активен — все правила firewall ведёт панель (before.rules/restrict-isp); базовый блок restrict снимается."
		else
			ui_info "Модуль «Firewall IP-rules» есть, но его правила ещё не записаны — базовый блок restrict пока оставляю."
		fi
	fi

	if ((${#specs[@]} == 0)); then
		ui_info "Базовый restrict-блок не нужен (правила в панели либо списки IP пусты) — снимаю прежний, если был."
		# снять прежний base-блок, чтобы не остался устаревший
		_ufw_restrict_write /etc/ufw/before.rules  4 ufw-before-input  '-A ufw-before-input -j ufw-user-input'
		[[ -f /etc/ufw/before6.rules ]] && _ufw_restrict_write /etc/ufw/before6.rules 6 ufw6-before-input '-A ufw6-before-input -j ufw6-user-input'
		ufw reload >>"$SETUP_LOG" 2>&1 || true
		return 0
	fi

	cp -a /etc/ufw/before.rules /etc/ufw/before.rules.ss.bak 2>/dev/null || true
	[[ -f /etc/ufw/before6.rules ]] && cp -a /etc/ufw/before6.rules /etc/ufw/before6.rules.ss.bak 2>/dev/null || true
	_ufw_restrict_write /etc/ufw/before.rules  4 ufw-before-input  '-A ufw-before-input -j ufw-user-input'   "${specs[@]}"
	[[ -f /etc/ufw/before6.rules ]] && _ufw_restrict_write /etc/ufw/before6.rules 6 ufw6-before-input '-A ufw6-before-input -j ufw6-user-input' "${specs[@]}"

	if ufw reload >>"$SETUP_LOG" 2>&1; then
		rm -f /etc/ufw/before.rules.ss.bak /etc/ufw/before6.rules.ss.bak
		ui_success "Жёсткие IP-ограничения вшиты в before.rules — переживут ISPConfig-firewall (порты: $(printf '%s ' "${specs[@]%%:*}"))."
		ui_info "Их источник — setup.conf; ISPConfig-firewall их НЕ перезатрёт. Менять — через luckyctl."
	else
		mv -f /etc/ufw/before.rules.ss.bak  /etc/ufw/before.rules  2>/dev/null || true
		mv -f /etc/ufw/before6.rules.ss.bak /etc/ufw/before6.rules 2>/dev/null || true
		ufw reload >>"$SETUP_LOG" 2>&1 || true
		ui_warn "ufw reload отверг новый before.rules — откатил (см. ${SETUP_LOG}). Ограничения не применены."
	fi
}

# Вписать маркированный блок ACCEPT-по-IP + DROP в указанную цепочку before-rules,
# ПЕРЕД строкой перехода в user-input. $1=файл $2=4|6 $3=цепочка $4=строка-перехода, далее specs.
_ufw_restrict_write() {
	local file="$1" fam="$2" chain="$3" jump="$4"; shift 4
	[[ -f "$file" ]] || return 0
	local START='# luckystack: restrict START' END='# luckystack: restrict END'
	# снять прежний блок (по маркерам)
	sed -i "\|${START}|,\|${END}|d" "$file"
	# правил нет — блок просто снят, пустую рамку из маркеров не пишем
	(( $# == 0 )) && return 0
	# собрать новый блок (только IP нужного семейства)
	local block spec port ips ip any
	block="${START}"$'\n'"# жёсткие IP-ограничения (переживают ISPConfig-firewall); правит LuckyStack, не редактируйте вручную"$'\n'
	for spec in "$@"; do
		port="${spec%%:*}"; ips="${spec#*:}"; any=0
		# udp-открытие всем (HTTP/3): spec вида "u<port>:" — порт с префиксом 'u', без IP/DROP.
		if [[ "$port" == u* ]]; then
			block+="-A ${chain} -p udp --dport ${port#u} -j ACCEPT"$'\n'
			continue
		fi
		for ip in $ips; do
			if [[ "$fam" == 6 ]]; then [[ "$ip" == *:* ]] || continue; else [[ "$ip" == *:* ]] && continue; fi
			block+="-A ${chain} -p tcp --dport ${port} -s ${ip} -j ACCEPT"$'\n'; any=1
		done
		((any)) && block+="-A ${chain} -p tcp --dport ${port} -j DROP"$'\n'
	done
	block+="${END}"
	# Вставить блок В КОНЕЦ цепочки ufw-before-input — перед COMMIT. ufw дописывает переход
	# в ufw-user-input в рантайме ПОСЛЕ загрузки before.rules, поэтому наши правила (последние
	# в before-input) срабатывают РАНЬШЕ user-input (где «открытые всем» правила ISPConfig).
	# (Строки `-A ... -j ufw-user-input` в самом before.rules нет — она добавляется ufw.)
	awk -v blk="$block" '/^COMMIT/ && !d { print blk; d=1 } { print }' "$file" >"$file.tmp" && mv_keep "$file.tmp" "$file"
}

_security_firewall() {
	case "${FIREWALL:-}" in
		ufw)
			_security_firewall_ufw
			;;
		crowdsec)
			# CrowdSec ставится на этапе веб-сервера (install_crowdsec в nginx.sh). На
			# Apache этого этапа НЕТ → cscli отсутствует, и сервер остался бы без firewall.
			# Поэтому: если cscli нет — пробуем поставить здесь, не вышло (CDN недоступен
			# и т.п.) → честный фоллбэк на UFW.
			if command -v cscli >/dev/null 2>&1; then
				ui_info "Firewall = CrowdSec (уже установлен на этапе веб-сервера)."
			elif declare -F install_crowdsec >/dev/null; then
				install_crowdsec
				# install_crowdsec мог ВНУТРЕННЕ уйти в фоллбэк (_crowdsec_fallback_ufw →
				# FIREWALL=ufw) при недоступном CDN, при этом cscli мог остаться от частичной
				# установки. Поэтому судим по ИТОГОВОМУ FIREWALL, а не только по наличию cscli:
				# если crowdsec реально встал И не было фоллбэка — успех; иначе поднимаем UFW
				# (раньше тут рапортовался «успех», а ufw не включался → сервер без firewall).
				if [[ "${FIREWALL:-}" == "crowdsec" ]] && command -v cscli >/dev/null 2>&1; then
					ui_success "CrowdSec установлен (веб-сервер ${WEBSERVER:-nginx})."
				else
					ui_warn "CrowdSec недоступен/фоллбэк — настраиваю UFW, чтобы сервер не остался без firewall."
					config_set FIREWALL ufw 2>/dev/null || true
					_security_firewall_ufw
				fi
			else
				ui_warn "CrowdSec недоступен — переключаюсь на UFW, чтобы сервер не остался без firewall."
				config_set FIREWALL ufw 2>/dev/null || true
				_security_firewall_ufw
			fi
			# CrowdSec банит IP, но ПОРТЫ не закрывает — публичные сервисы остаются доступны.
			# Secure-by-default: добавляем ufw (default-deny по портам) ПОВЕРХ crowdsec
			# (ufw=порты, crowdsec=IP-баны — правильная связка). Отключаемо CROWDSEC_WITH_UFW=n.
			if [[ "${FIREWALL:-}" == "crowdsec" ]]; then
				if [[ "${CROWDSEC_WITH_UFW:-y}" == "y" ]]; then
					ui_info "CrowdSec не фильтрует порты — добавляю ufw (default-deny) поверх, чтобы закрыть лишнее."
					_security_ufw_ports
				else
					ui_warn "CROWDSEC_WITH_UFW=n: порты НЕ фильтруются — публичные сервисы доступны из интернета (CrowdSec только банит IP)."
					ui_info "Тогда обязательно: чувствительные сервисы (БД/кэш) должны слушать только localhost."
				fi
			fi
			;;
		*)
			ui_info "Firewall не выбран (FIREWALL=${FIREWALL:-none}) — пропуск."
			;;
	esac
}

# --- Сетевой/ядровый харденинг через sysctl ----------------------------------
# Безопасные параметры (рекомендованы Lynis/CIS): анти-спуфинг, SYN cookies,
# запрет редиректов/source-route, ASLR, защита hard/symlink. IPv6 НЕ выключаем.
_security_sysctl_hardening() {
	[[ "${SEC_SYSCTL:-y}" == "y" ]] || { ui_info "sysctl-харденинг отключён (SEC_SYSCTL=n)."; return 0; }
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} sysctl-харденинг (анти-спуфинг, SYN cookies, ASLR)"; return 0; }
	ui_step "Сетевой/ядровый харденинг (sysctl)"
	# log_martians сюда не пишем: ufw при старте ставит свой (0) из /etc/ufw/sysctl.conf, наш всё равно не действовал
	cat >/etc/sysctl.d/90-luckystack-hardening.conf <<'SYS'
# LuckyStack — безопасные сетевые/ядровые параметры. Можно править/удалить.
# IPv4
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# IPv6 (редиректы/source-route; сам IPv6 НЕ выключаем)
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
# Ядро/ФС
kernel.randomize_va_space = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
# чужие FIFO и файлы в общих каталогах с липким битом (/tmp) — не открывать (подмены в /tmp)
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
# адреса ядра и журнал ядра — только root (их используют эксплойты ядра)
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
# процесс может отлаживать (ptrace) только своих потомков; root — по-прежнему всех
kernel.yama.ptrace_scope = 1
# JIT eBPF с защитой от JIT-spray; модули line discipline не грузятся по запросу
net.core.bpf_jit_harden = 2
dev.tty.ldisc_autoload = 0
# SysRq с клавиатуры/консоли выключен (на VPS не нужен)
kernel.sysrq = 0
SYS
	# systemd кладёт /usr/lib/sysctl.d/99-protect-links.conf (protected_fifos = 1); файлы
	# применяются по алфавиту имён, и он перебивал наш 90-*. Одноимённый файл в /etc/sysctl.d
	# заменяет его целиком — кладём те же параметры со своими значениями.
	if [[ -f /usr/lib/sysctl.d/99-protect-links.conf ]]; then
		cat >/etc/sysctl.d/99-protect-links.conf <<'SYS'
# luckystack: заменяет /usr/lib/sysctl.d/99-protect-links.conf (там protected_fifos = 1)
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
SYS
	fi
	# Непривилегированные user namespaces: на них построена большая часть свежих эксплойтов ядра.
	# Запрет ломает песочницу браузеров и rootless-контейнеры, поэтому отдельной опцией (по умолч. выкл.).
	if [[ "${SEC_USERNS_OFF:-n}" == "y" ]]; then
		cat >/etc/sysctl.d/91-luckystack-userns.conf <<'SYS'
# luckystack (SEC_USERNS_OFF=y): запрет непривилегированных user namespaces
kernel.unprivileged_userns_clone = 0
SYS
	elif [[ -f /etc/sysctl.d/91-luckystack-userns.conf ]]; then
		rm -f /etc/sysctl.d/91-luckystack-userns.conf
		sysctl -qw kernel.unprivileged_userns_clone=1 >>"$SETUP_LOG" 2>&1 || true
	fi
	# /etc/sysctl.conf читается systemd-sysctl ПОСЛЕДНИМ и перебивает наш drop-in
	# (образы части хостеров кладут туда, напр., net.ipv4.tcp_syncookies=0 — наш =1 проигрывает).
	# Нейтрализуем там активные строки по ключам, которыми управляем мы, и переприменяем.
	if [[ -f /etc/sysctl.conf ]]; then
		local _k _key _neutralized=0
		[[ -f /etc/sysctl.conf.luckystack.bak ]] || cp -a /etc/sysctl.conf /etc/sysctl.conf.luckystack.bak 2>/dev/null || true
		# ключи берём из нашего же файла (имя = до '=')
		while IFS= read -r _k; do
			_key="$(printf '%s' "$_k" | sed -E 's/[[:space:]]*=.*//; s/^[[:space:]]+//')"
			[[ -n "$_key" ]] || continue
			if grep -qE "^[[:space:]]*${_key//./\\.}[[:space:]]*=" /etc/sysctl.conf; then
				sed -i -E "s|^([[:space:]]*${_key//./\\.}[[:space:]]*=)|# luckystack neutralized: \1|" /etc/sysctl.conf
				_neutralized=1
			fi
		done < <(grep -E '^[a-z]' /etc/sysctl.d/90-luckystack-hardening.conf)
		(( _neutralized )) && ui_info "В /etc/sysctl.conf нейтрализованы строки, перебивавшие наш харденинг (бэкап: /etc/sysctl.conf.luckystack.bak)."
	fi

	# --system применяет все drop-in; отсутствующие ключи (напр. при выкл. IPv6)
	# дают предупреждение, но не валят процесс.
	if sysctl --system >>"$SETUP_LOG" 2>&1; then
		ui_success "sysctl-харденинг применён (/etc/sysctl.d/90-luckystack-hardening.conf)."
	else
		ui_warn "Часть sysctl-параметров не применилась (вероятно, отсутствуют ключи) — см. ${SETUP_LOG}."
	fi
}

# --- Расширенные jail'ы fail2ban под стек ISPConfig --------------------------
# Пишем drop-in /etc/fail2ban/jail.d/ — НЕ трогаем основной jail.local ([sshd]).
# Включаем jail ТОЛЬКО если есть его фильтр (иначе fail2ban не стартует) и
# установлен соответствующий сервис.
_security_fail2ban_jails() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} jail'ы fail2ban: postfix/dovecot/pure-ftpd/панель"; return 0; }
	command -v fail2ban-client >/dev/null 2>&1 || return 0
	ui_step "Настройка jail'ов fail2ban под стек ISPConfig"
	local jd=/etc/fail2ban/jail.d/luckystack-ispconfig.conf fd=/etc/fail2ban/filter.d
	: >"$jd"
	local added=() wrote=()   # wrote: наши .local-фильтры, при откате убираются вместе с jail
	# backend=systemd: читаем journald (Debian 12+ journald-only, файловых логов нет).
	# Включаем jail при наличии его фильтра + соответствующего сервиса (logpath не нужен).
	_f2b_add() {  # _f2b_add jail filter "доп.строки"
		[[ -f "${fd}/${2}.conf" ]] || return 0
		# backend по умолчанию systemd; если в доп.строках свой backend (файловый журнал) — без дубля ключа
		{ printf '[%s]\nenabled = true\n' "$1"; [[ "${3:-}" == *backend* ]] || printf 'backend = systemd\n'
		  [[ -n "${3:-}" ]] && printf '%b\n' "$3"; printf '\n'; } >>"$jd"
		added+=("$1")
	}
	if command -v postfix >/dev/null 2>&1; then
		_f2b_add postfix      postfix      "mode = aggressive"
		_f2b_add postfix-sasl postfix-sasl
	fi
	if command -v dovecot >/dev/null 2>&1; then
		# Dovecot 2.4 (Debian 13) пишет неудачный вход строкой «Login aborted: … (auth failed, N attempts …)
		# (auth_failed): … rip=IP», штатный фильтр её не узнаёт и подбор паролей не банится.
		# Дополняем правило, прежние строки 2.3 ловятся как раньше.
		[[ -f "${fd}/dovecot.conf" ]] && cat >"${fd}/dovecot.local" <<'F2B' && wrote+=("${fd}/dovecot.local")
# luckystack: + формат Dovecot 2.4 («Login aborted: …»), иначе подбор паролей на Debian 13 не банится
[Definition]
failregex = %(known/failregex)s
            ^Login aborted%(_bypass_reject_reason)s \((?:auth failed, \d+ attempts(?: in \d+ secs)?|tried to use (?:disabled|disallowed) \S+ auth|proxy dest auth failed)\)(?: \(\w+\))?:(?: user=<<F-USER>[^>]*</F-USER>>,)?(?: method=\S+,)? rip=<HOST>(?:[^>]*(?:, session=<\S+>)?)\s*$
F2B
		_f2b_add dovecot dovecot
	fi
	dpkg -l pure-ftpd-mysql 2>/dev/null | grep -q '^ii' && _f2b_add pure-ftpd pure-ftpd
	# Панель ISPConfig: фильтр появляется, если его настроил сам ISPConfig.
	_f2b_add ispconfig ispconfig
	# Roundcube пишет неудачные входы в файл, не в журнал: с backend=systemd jail не видел ничего
	if [[ -e /var/www/html/roundcube || -d /var/lib/roundcube ]]; then
		mkdir -p /var/log/roundcube; touch /var/log/roundcube/errors.log
		chown www-data:adm /var/log/roundcube /var/log/roundcube/errors.log 2>/dev/null; chmod 640 /var/log/roundcube/errors.log
		# Штатный фильтр не ловит строку, если клиент прислал X-Forwarded-For (Roundcube дописывает
		# его в скобках) — заголовок ставит сам атакующий, и бан обходился. Дополняем правило;
		# IP берётся из адреса соединения (первый «from» после «against <imap-хост>»).
		[[ -f "${fd}/roundcube-auth.conf" ]] && cat >"${fd}/roundcube-auth.local" <<'F2B' && wrote+=("${fd}/roundcube-auth.local")
# luckystack: + вариант строки с X-Forwarded-For (иначе бан обходится этим заголовком)
[Definition]
failregex = ^(?:FAILED login|Login failed) for <F-USER>.*</F-USER> from <HOST>(?:(?:\([^\)]*\))?\. (?:(?! from ).)*(?: user=(?P=user))? in \S+\.php on line \d+ \(\S+ \S+\))?$
            ^(?:<[\w]+> )?Failed login for <F-USER>.*</F-USER> from <HOST> in session \w+( \(error: \d\))?$
            ^Login failed for <F-USER>.*?</F-USER> against \S+ from <HOST> \(X-Forwarded-For: [^)]*\)\.
F2B
		_f2b_add roundcube-auth roundcube-auth "backend = auto\nlogpath = /var/log/roundcube/errors.log"
	fi
	# MariaDB: подбор пароля. Лог MariaDB 12 идёт в журнал systemd, а встроенные разборщики
	# CrowdSec его формат не понимают, поэтому ловит fail2ban (фильтр mysqld-auth совпадает,
	# имя хоста в строке он сам переводит в IP).
	systemctl list-unit-files mariadb.service >/dev/null 2>&1 && systemctl is-enabled --quiet mariadb 2>/dev/null && \
		_f2b_add mysqld-auth mysqld-auth "journalmatch = _SYSTEMD_UNIT=mariadb.service\nport = 3306"
	# Панель ISPConfig: свой фильтр по /var/log/ispconfig/auth.log («Failed login for user … from IP»).
	# Штатного фильтра нет; лог появляется после установки ISPConfig — до этого jail не включаем.
	if [[ -f /var/log/ispconfig/auth.log ]]; then
		cat >"${fd}/luckystack-ispconfig-auth.conf" <<'F2B'
# luckystack: неудачные входы в панель ISPConfig
[Definition]
failregex = ^Failed login for user '.*' from <HOST> at
ignoreregex =
F2B
		{ printf '[ispconfig-auth]\nenabled = true\nfilter = luckystack-ispconfig-auth\nbackend = auto\nlogpath = /var/log/ispconfig/auth.log\nport = %s\nmaxretry = 5\nfindtime = 10m\n\n' "${ISPCONFIG_PANEL_PORT:-8080}"; } >>"$jd"
		added+=("ispconfig-auth")
	fi

	if ((${#added[@]} == 0)); then
		rm -f "$jd"
		ui_info "Доп. jail'ы fail2ban не добавлены (нет фильтров/логов) — активен базовый [sshd]."
		return 0
	fi
	# Валидация ДО перезапуска: если конфиг невалиден — откатываем drop-in, чтобы
	# НИКОГДА не оставить fail2ban в сломанном состоянии.
	if fail2ban-client -t >>"$SETUP_LOG" 2>&1; then
		systemctl reload fail2ban >>"$SETUP_LOG" 2>&1 || systemctl restart fail2ban >>"$SETUP_LOG" 2>&1 || true
		if systemctl is-active fail2ban >/dev/null 2>&1; then
			ui_success "fail2ban jail'ы включены: ${added[*]}"
		else
			rm -f "$jd" "${wrote[@]}"; systemctl restart fail2ban >>"$SETUP_LOG" 2>&1 || true
			ui_warn "fail2ban не поднялся с доп. jail'ами — откат (активен только [sshd])."
		fi
	else
		rm -f "$jd" "${wrote[@]}"; systemctl restart fail2ban >>"$SETUP_LOG" 2>&1 || true
		ui_warn "Конфигурация доп. jail'ов невалидна — откат (активен только [sshd])."
	fi
}

stage_security_summary() {
	local t="fail2ban + ${FIREWALL:-none} + jailkit"
	[[ "${SEC_LYNIS:-y}" == "y" ]] && t+=" + lynis"
	[[ "${SEC_RKHUNTER:-n}" == "y" ]] && t+=" + rkhunter"
	echo "Security: $t"
}

# =============================================================================
# Смена SSH-порта — вызывается В САМОМ КОНЦЕ установки (из main, перед summary).
# Безопасность: sshd -t перед рестартом (откат при ошибке), старый порт 22 в
# firewall НЕ закрывается автоматически — закройте сами после проверки входа.
# =============================================================================
# Эффективный(е) порт(ы) sshd. `sshd -T` учитывает Include, закомментированные
# строки и дефолт — надёжнее, чем grep по sshd_config. Фолбэк — явные Port в
# конфиге, иначе дефолт 22.
_ssh_effective_ports() {
	local p
	p="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2}')"
	[[ -z "$p" ]] && p="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')"
	[[ -z "$p" ]] && p=22
	printf '%s\n' "$p"
}

apply_ssh_port() {
	local port="${SSH_PORT:-22}"
	[[ -z "$port" || "$port" == "22" ]] && return 0
	if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
		ui_warn "SSH_PORT='${port}' некорректен — порт SSH не изменён."
		return 0
	fi

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_step "Смена порта SSH → ${port} (финальный шаг)"
		ui_info "${UI_D}[dry-run]${UI_NC} проверка текущего порта (sshd -T) + Port ${port} + sshd -t + ufw allow + restart"
		return 0
	fi

	local cfg=/etc/ssh/sshd_config
	[[ -f "$cfg" ]] || { ui_warn "$cfg не найден — порт SSH не изменён."; return 0; }

	# Уже на нужном порту? Берём ЭФФЕКТИВНЫЙ порт sshd — если SSH уже слушает целевой
	# порт, НЕ трогаем (в т.ч. когда он задан через Include или уже менялся ранее).
	local cur; cur="$(_ssh_effective_ports)"
	if printf '%s\n' "$cur" | grep -qx "$port"; then
		ui_info "SSH уже слушает порт ${port} — изменение не требуется."
		return 0
	fi
	ui_step "Смена порта SSH: $(printf '%s' "$cur" | head -1) → ${port} (финальный шаг)"

	cp -a "$cfg" "${cfg}.luckystack.bak"
	# Пишем Port в ПРИОРИТЕТНЫЙ drop-in. sshd берёт ПЕРВОЕ значение Port, а
	# `Include /etc/ssh/sshd_config.d/*.conf` стоит вверху основного конфига — значит
	# 00-* drop-in читается РАНЬШЕ cloud-init/провайдерских и побеждает. Иначе наш Port
	# в конце основного конфига перебивался бы drop-in'ом (симптом: config=NNN, демон=22).
	local dropdir=/etc/ssh/sshd_config.d dropf=/etc/ssh/sshd_config.d/00-luckystack-ssh.conf
	if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$cfg" 2>/dev/null; then
		mkdir -p "$dropdir" 2>/dev/null || true
		# нейтрализуем конфликтующий Port в основном конфиге и в ДРУГИХ drop-in'ах
		sed -i -E 's/^([[:space:]]*Port[[:space:]]+[0-9]+)/#&/' "$cfg" 2>/dev/null || true
		local _df
		for _df in "$dropdir"/*.conf; do
			[[ -f "$_df" && "$_df" != "$dropf" ]] || continue
			sed -i -E 's/^([[:space:]]*Port[[:space:]]+[0-9]+)/#&/' "$_df" 2>/dev/null || true
		done
		printf '# luckystack: SSH-порт (приоритетный drop-in, побеждает cloud-init)\nPort %s\n' "$port" > "$dropf"
	else
		# Нет Include — правим основной конфиг (старый способ)
		if grep -qE "^[#[:space:]]*Port[[:space:]]" "$cfg"; then
			sed -i -E "0,/^[#[:space:]]*Port[[:space:]].*/s//Port ${port}/" "$cfg"
		else
			printf 'Port %s\n' "$port" >>"$cfg"
		fi
	fi

	# Валидация конфига ДО рестарта — иначе можно отрезать себе доступ
	if ! sshd -t 2>>"$SETUP_LOG"; then
		ui_error "sshd -t отверг новый конфиг — откатываю изменения."
		mv "${cfg}.luckystack.bak" "$cfg"; rm -f "$dropf"
		return 0
	fi
	# КЛЮЧЕВОЕ: убеждаемся, что ЭФФЕКТИВНЫЙ порт реально стал нашим (не перебит drop-in/Include)
	local _eff; _eff="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}')"
	if [[ -n "$_eff" ]] && ! printf '%s\n' "$_eff" | grep -qx "$port"; then
		ui_warn "sshd всё ещё на порту ${_eff} (не ${port}) — есть конфликтующий Port в Include/drop-in. Проверь: ${UI_W}sshd -T | grep -i '^port'${UI_NC} и закомментируй лишний."
	fi

	# Firewall: открыть новый порт (22 оставляем до ручной проверки!) — с тем же
	# ограничением по IP, что и базовые правила (SSH_ALLOW_IPS) или со всех.
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
		_ufw_allow_ssh "${port}" || true
	else
		# Нет управляемого firewall — порт мы НЕ открываем. За внешним фаерволом
		# провайдера новый порт может быть недоступен → предупреждаем ДО рестарта SSH.
		ui_warn "UFW неактивен — порт ${port} установщиком НЕ открыт. Убедись, что он доступен (фаервол провайдера/панель VPS), иначе после рестарта SSH потеряешь доступ."
		ui_info "Проверь из ДРУГОЙ сессии: ${UI_W}ssh -p ${port} root@<ip>${UI_NC} — и только потом закрывай текущую."
	fi
	# fail2ban: следить за новым портом (якорим номер по границе слова — иначе порт
	# 22 «находится» в 2222/12222 и идемпотентность ломается).
	if [[ -f /etc/fail2ban/jail.local ]] && ! grep -qE "^[[:space:]]*port[[:space:]]*=.*\b${port}\b" /etc/fail2ban/jail.local; then
		sed -i "/^\[sshd\]/a port = ssh,${port}" /etc/fail2ban/jail.local 2>/dev/null || true
		systemctl reload fail2ban >>"$SETUP_LOG" 2>&1 || true
	fi

	sys_run "Перезапуск SSH" systemctl restart ssh || \
		sys_run "Перезапуск sshd" systemctl restart sshd

	ui_success "SSH переведён на порт ${port}."
	ui_warn "НЕ ЗАКРЫВАЙТЕ эту сессию! Проверьте в НОВОМ окне: ssh -p ${port} root@${SERVER_FQDN:-<server>}"
	ui_warn "Порт 22 в firewall оставлен открытым — закройте после успешной проверки: ufw deny 22/tcp"
	log "ssh: порт изменён на ${port} (бэкап ${cfg}.luckystack.bak)"
	return 0
}

# ПРИМЕЧАНИЕ: sshd-уровневое IP-ограничение (Match Address) УБРАНО — конструкция
# `Match Address *,!IP` на практике блокировала ДАЖЕ разрешённый адрес (смешение glob `*`
# с IP в Match ломает разбор → лок-аут). SSH_ALLOW_IPS применяется НАДЁЖНО через firewall
# (ufw allow from IP …, см. _ufw_allow_ssh), а ufw поднимается и при crowdsec
# (CROWDSEC_WITH_UFW=y). Поддерживается НЕСКОЛЬКО IP (список через пробел). Самозащита от
# лок-аута — в _ufw_allow_ssh (если текущий адрес не в списке, порт открывается со всех).

# =============================================================================
# SSH-харденинг — вызывается в КОНЦЕ установки (из main, рядом с apply_ssh_port).
#   • X11Forwarding off + умеренные лимиты входа — БЕЗОПАСНО всегда.
#   • PasswordAuthentication off — ТОЛЬКО если есть рабочий ключ для входа
#     (иначе можно отрезать себе доступ). Если ключ не настроен, но задан
#     SSH_PUBKEY — сначала добавляем его в authorized_keys, потом отключаем пароль.
# =============================================================================

# Есть ли непустой authorized_keys с реальным ключом (root или sudo-юзеры)?
# Ключ может стоять не в начале строки: перед ним бывают опции (from="…",no-pty …).
_has_authorized_key() {
	local f
	for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
		[[ -f "$f" ]] && grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null \
			| grep -qE '(^|[[:space:],"])(ssh-(rsa|ed25519|dss)|ecdsa-sha2-[a-z0-9]+|sk-(ssh-ed25519|ecdsa-sha2-[a-z0-9]+)@openssh\.com)[[:space:]]+AAAA' \
			&& return 0
	done
	return 1
}

# Безопасные настройки SSH отдельным drop-in-файлом (SSH_SAFE=y по умолчанию; при установке и в
# --update). sshd берёт ПЕРВОЕ значение параметра, а Include sshd_config.d/*.conf стоит в начале
# основного конфига, поэтому 10-* читается раньше 50-cloud-init и правок в основном конфиге.
# Вход по паролю не трогаем: его отключает только SSH_HARDEN=y и только при наличии ключа.
#   X11Forwarding, AllowAgentForwarding — off; AllowTcpForwarding — SSH_TCP_FORWARD (по умолч. n;
#   y — если нужны SSH-туннели, например к базе); ClientAlive — мёртвые сессии закрываются за 10 мин.
#   MaxAuthTries не уменьшаем: при многих ключах в агенте клиент не дошёл бы до пароля.
SSH_HARDEN_DROPIN=/etc/ssh/sshd_config.d/10-luckystack-harden.conf
_ssh_harden_content() {
	local pw_off="${1:-0}"
	echo "# luckystack: безопасные настройки SSH (вход по паролю: $([[ $pw_off == 1 ]] && echo 'выключен, только ключ' || echo 'оставлен'))"
	echo "X11Forwarding no"
	echo "AllowAgentForwarding no"
	echo "AllowTcpForwarding $([[ "${SSH_TCP_FORWARD:-n}" == "y" ]] && echo yes || echo no)"
	echo "PermitEmptyPasswords no"
	echo "LoginGraceTime 30"
	echo "ClientAliveInterval 300"
	echo "ClientAliveCountMax 2"
	echo "MaxStartups 10:30:60"
	if [[ "$pw_off" == 1 ]]; then
		echo "PasswordAuthentication no"
		echo "KbdInteractiveAuthentication no"
		echo "PermitRootLogin prohibit-password"
	fi
}

# Записать drop-in и проверить, что sshd его принял и значения реально действуют (sshd -T).
# $1 — 1, если отключать пароль. rc=0 — применено.
_ssh_apply_dropin() {
	local pw_off="${1:-0}" cfg=/etc/ssh/sshd_config f="$SSH_HARDEN_DROPIN" prev="" tmp
	command -v sshd >/dev/null 2>&1 && [[ -f "$cfg" ]] || return 1
	if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$cfg"; then
		# старый sshd_config без Include: дописываем Include в начало (так делает и Debian 12)
		cp -a "$cfg" "${cfg}.harden.bak"
		sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$cfg"
	fi
	mkdir -p "${f%/*}"
	tmp="$(mktemp)"; _ssh_harden_content "$pw_off" >"$tmp"
	if [[ -f "$f" ]] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
	[[ -f "$f" ]] && { prev="$(mktemp)"; cp -a "$f" "$prev"; }
	install -m 644 "$tmp" "$f"; rm -f "$tmp"
	local bad=""
	if ! sshd -t 2>>"$SETUP_LOG"; then
		bad="sshd -t отверг конфиг"
	else
		# действуют ли значения (их мог перебить более ранний drop-in, например 00-*)
		local eff k v
		eff="$(sshd -T 2>/dev/null)"
		while read -r k v; do
			[[ -z "$k" || "$k" == "#"* ]] && continue
			k="${k,,}"; v="${v,,}"
			[[ "$k" == permitrootlogin && "$v" == prohibit-password ]] && v="without-password"
			grep -qiE "^${k} ${v}\$" <<<"$eff" || { bad="${k} не применился (действует: $(grep -i "^${k} " <<<"$eff"))"; break; }
		done < <(_ssh_harden_content "$pw_off")
	fi
	if [[ -n "$bad" ]]; then
		if [[ -n "$prev" ]]; then cp -a "$prev" "$f"; else rm -f "$f"; fi
		rm -f "$prev"
		ui_warn "SSH: ${bad} — изменения откатил, sshd не трогал."
		return 1
	fi
	rm -f "$prev"
	# reload: текущие сессии не рвутся
	systemctl reload ssh >>"$SETUP_LOG" 2>&1 || systemctl reload sshd >>"$SETUP_LOG" 2>&1 \
		|| systemctl restart ssh >>"$SETUP_LOG" 2>&1 || systemctl restart sshd >>"$SETUP_LOG" 2>&1
	return 0
}

# --update и конец установки: безопасные настройки без отключения пароля (если SSH_HARDEN=y —
# с отключением, при наличии ключа).
apply_ssh_safe() {
	[[ "${SSH_SAFE:-y}" == "y" ]] || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} SSH: X11/агент/TCP-проброс off, ClientAlive, ${SSH_HARDEN_DROPIN}"; return 0; }
	local pw_off=0
	[[ "${SSH_HARDEN:-n}" == "y" ]] && _has_authorized_key && pw_off=1
	local before; before="$(cat "$SSH_HARDEN_DROPIN" 2>/dev/null)"
	if _ssh_apply_dropin "$pw_off"; then
		[[ "$before" == "$(cat "$SSH_HARDEN_DROPIN" 2>/dev/null)" ]] && return 0
		ui_success "SSH: X11 и проброс агента выключены, TCP-проброс $([[ "${SSH_TCP_FORWARD:-n}" == y ]] && echo оставлен || echo выключен), мёртвые сессии закрываются за 10 мин$([[ $pw_off == 1 ]] && echo ', вход только по ключу' || echo '; вход по паролю оставлен')."
		((pw_off)) && ui_warn "НЕ ЗАКРЫВАЙТЕ сессию! Проверьте вход по ключу в НОВОМ окне."
		log "ssh-safe: ${SSH_HARDEN_DROPIN} pw_off=${pw_off} tcp_forward=${SSH_TCP_FORWARD:-n}"
	fi
	return 0
}

# Идемпотентно выставить параметр в sshd_config (заменить закомментированную/активную строку либо дописать).
_sshd_set() {
	local cfg=/etc/ssh/sshd_config key="$1" val="$2"
	if grep -qiE "^[#[:space:]]*${key}[[:space:]]" "$cfg" 2>/dev/null; then
		sed -i -E "0,/^[#[:space:]]*${key}[[:space:]].*/s||${key} ${val}|" "$cfg"
	else
		printf '%s %s\n' "$key" "$val" >>"$cfg"
	fi
}

apply_ssh_hardening() {
	[[ "${SSH_HARDEN:-n}" == "y" ]] || return 0
	local cfg=/etc/ssh/sshd_config
	[[ -f "$cfg" ]] || { ui_warn "$cfg не найден — SSH-харденинг пропущен."; return 0; }

	ui_step "SSH-харденинг (X11 off; вход по ключу — при наличии ключа)"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} X11Forwarding no, MaxAuthTries 4; PasswordAuthentication no — если есть ключ"
		return 0
	fi

	cp -a "$cfg" "${cfg}.harden.bak"

	# Если админ передал публичный ключ — кладём его до отключения пароля.
	if [[ -n "${SSH_PUBKEY:-}" ]]; then
		mkdir -p /root/.ssh && chmod 700 /root/.ssh
		touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
		if ! grep -qF "$SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
			printf '%s\n' "$SSH_PUBKEY" >>/root/.ssh/authorized_keys
			ui_success "Публичный ключ добавлен в /root/.ssh/authorized_keys"
		fi
	fi

	# Отключение пароля — только при наличии рабочего ключа. Всё пишется drop-in-файлом
	# (_ssh_apply_dropin): правки основного sshd_config перебивал любой drop-in выше по порядку.
	local pw_off=0
	if _has_authorized_key; then
		pw_off=1
	else
		ui_warn "Вход по ключу не настроен (нет authorized_keys) — пароль НЕ отключён, чтобы не потерять доступ."
		ui_info "Добавьте свой публичный ключ в /root/.ssh/authorized_keys и повторите харденинг."
	fi
	if ! _ssh_apply_dropin "$pw_off"; then
		ui_error "SSH-харденинг не применён (см. выше), sshd работает как раньше."
		return 0
	fi

	if ((pw_off)); then
		ui_success "SSH усилён: X11 off, вход ТОЛЬКО по ключу."
		ui_warn "НЕ ЗАКРЫВАЙТЕ сессию! Проверьте вход по ключу в НОВОМ окне до выхода."
	else
		ui_success "SSH частично усилён: X11 off, лимиты входа (пароль оставлен — нет ключа)."
	fi
	log "ssh-harden: X11=off pw_off=${pw_off} pubkey=$([[ -n "${SSH_PUBKEY:-}" ]] && echo set || echo none)"
	return 0
}

# =============================================================================
# Анти-лок-аут — страховка вокруг финальных SSH/firewall-изменений.
# Взводит детачнутый таймер отката: если за NETSAFE_MINUTES админ НЕ подтвердит доступ
# из НОВОГО соединения (создав sentinel-файл), таймер откатывает firewall (`ufw disable`)
# и SSH (восстановление sshd_config + порта из бэкапа) + перезапуск sshd.
# Почему «новое соединение»: текущая established-сессия переживает лок-аут (ufw пускает
# ESTABLISHED), поэтому подтверждать надо именно свежим коннектом — он и доказывает доступ.
# Только интерактив (есть кому подтвердить), не для UNATTENDED (там это сорвало бы автоматику).
# Управление: SSH_NETSAFE=y|n (по умолч. y), NETSAFE_MINUTES (по умолч. 5).
# =============================================================================
_NETSAFE_OK=/run/luckystack-net-ok
_NETSAFE_REVERT=/run/luckystack-net-revert.sh
_NETSAFE_DEADLINE=/run/luckystack-net-deadline   # срок (epoch), после которого откат
_NETSAFE_TOKEN=/run/luckystack-net-token         # ключ текущего взвода: таймер прошлого взвода не трогает новый
_NETSAFE_REVERTED=/run/luckystack-net-reverted   # откат сработал (не путать с подтверждением)

_net_safety_risky() {
	[[ "${SSH_NETSAFE:-y}" == "y" ]] || return 1
	[[ "${UNATTENDED:-0}" == "1" ]] && return 1   # автоматизация — без авто-отката
	[[ -t 1 ]] || return 1                         # только интерактив (есть кому подтвердить)
	[[ -n "${SSH_PORT:-}" && "${SSH_PORT}" != "22" ]] && return 0   # смена SSH-порта
	[[ "${FIREWALL:-}" == "ufw" ]] && return 0                       # активный firewall
	[[ "${CROWDSEC_WITH_UFW:-n}" == "y" ]] && return 0                # CrowdSec вместе с ufw — тоже ufw
	[[ "${SSH_HARDEN:-n}" == "y" ]] && return 0                      # харденинг (отключение пароля)
	[[ -n "${SSH_ALLOW_IPS:-}" ]] && return 0                        # SSH ограничен по IP
	return 1
}

# Взвести ДО рискованных правок (запоминает прежний sshd_config для отката).
_net_safety_arm() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	_net_safety_risky || return 0
	cp -a /etc/ssh/sshd_config "${_NETSAFE_REVERT}.sshd.bak" 2>/dev/null || true
	rm -f "$_NETSAFE_OK" "$_NETSAFE_REVERTED"
	local mins="${NETSAFE_MINUTES:-5}" tok
	tok="$(date +%s%N)-$$"
	printf '%s\n' "$tok" >"$_NETSAFE_TOKEN"
	printf '%s\n' "$(( $(date +%s) + mins * 60 ))" >"$_NETSAFE_DEADLINE"
	# Таймер ждёт срок из файла (его продлевает _net_safety_announce, когда человек видит инструкцию)
	# и откатывает, только если его ключ всё ещё текущий и подтверждения нет.
	cat > "$_NETSAFE_REVERT" <<REV
#!/bin/bash
tok="\$1"
while :; do
	[ "\$(cat "$_NETSAFE_TOKEN" 2>/dev/null)" = "\$tok" ] || exit 0   # уже взведён заново — этот таймер не нужен
	[ -e "$_NETSAFE_OK" ] && exit 0                                     # доступ подтверждён — откат не нужен
	[ "\$(date +%s)" -ge "\$(cat "$_NETSAFE_DEADLINE" 2>/dev/null || echo 0)" ] && break
	sleep 5
done
ufw --force disable >/dev/null 2>&1 || true
[ -f "${_NETSAFE_REVERT}.sshd.bak" ] && cp -a "${_NETSAFE_REVERT}.sshd.bak" /etc/ssh/sshd_config
rm -f /etc/ssh/sshd_config.d/00-luckystack-ssh.conf 2>/dev/null   # откатить и drop-in порта
rm -f /etc/ssh/sshd_config.d/10-luckystack-harden.conf 2>/dev/null   # и drop-in харденинга
sshd -t >/dev/null 2>&1 && { systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; }
logger -t luckystack "ANTI-LOCKOUT: доступ не подтверждён за окно — firewall/SSH откатаны к прежним"
touch "$_NETSAFE_REVERTED"
REV
	chmod +x "$_NETSAFE_REVERT"
	setsid bash "$_NETSAFE_REVERT" "$tok" >/dev/null 2>&1 </dev/null &
	disown 2>/dev/null || true
	NETSAFE_ARMED=1
	log "net-safety: armed (${mins}m) port=${SSH_PORT:-22} fw=${FIREWALL:-none} harden=${SSH_HARDEN:-n}"
}

# Объявить условие подтверждения И ДОЖДАТЬСЯ его (блокирующе, с обратным отсчётом).
# Раньше функция только печатала инструкцию и установщик завершался — пользователь
# не успевал/не замечал, таймер тихо откатывал SSH-порт (частый симптом: «порт не сменился»,
# drop-in исчезал). Теперь ждём появления файла-подтверждения (его создаёт `touch` из НОВОЙ
# сессии — именно новый коннект доказывает доступ) или истечения окна. Фоновый таймер из
# _net_safety_arm остаётся жёстким фолбэком (он уважает тот же файл-флаг).
_net_safety_announce() {
	[[ "${NETSAFE_ARMED:-0}" == "1" ]] || return 0
	local mins="${NETSAFE_MINUTES:-5}" total=$(( ${NETSAFE_MINUTES:-5} * 60 )) waited=0 left now dl
	# Окно считаем с этой минуты: сводка и проверка здоровья после взвода не должны его съедать.
	# Если откат уже успел сработать (ждали дольше окна), не продлеваем, а честно говорим ниже.
	[[ -e "$_NETSAFE_REVERTED" ]] || printf '%s\n' "$(( $(date +%s) + total ))" >"$_NETSAFE_DEADLINE"
	echo ""
	ui_warn "АНТИ-ЛОК-АУТ ВЗВЕДЁН (${mins} мин): SSH/firewall изменены — НУЖНО ПОДТВЕРДИТЬ ДОСТУП."
	ui_info "НЕ закрывайте это окно. В ${UI_W}ДРУГОМ${UI_NC} окне терминала:"
	ui_info "  1) подключитесь: ${UI_W}ssh -p ${SSH_PORT:-22} root@${SERVER_FQDN:-<ip-сервера>}${UI_NC}"
	ui_info "  2) выполните в нём: ${UI_W}touch ${_NETSAFE_OK}${UI_NC}"
	ui_info "Жду подтверждения здесь — без него через ${mins} мин SSH/firewall откатятся сами."
	# Неинтерактив (на всякий) — не блокируем, фоновый таймер решит сам.
	[[ -t 1 ]] || { ui_info "(неинтерактивный режим — ожидание пропущено, действует фоновый таймер)"; return 0; }
	while :; do
		# Откат проверяем первым: подтверждение после отката уже ничего не вернёт
		[[ -e "$_NETSAFE_REVERTED" ]] && break
		if [[ -e "$_NETSAFE_OK" ]]; then
			ui_success "Доступ подтверждён — изменения зафиксированы (SSH-порт ${UI_W}${SSH_PORT:-22}${UI_NC}, firewall)."
			return 0
		fi
		now=$(date +%s); dl="$(cat "$_NETSAFE_DEADLINE" 2>/dev/null || echo 0)"
		(( now > dl + 30 )) && break   # таймер почему-то не отработал — не висим вечно
		sleep 5; waited=$(( waited + 5 ))
		if (( waited % 30 == 0 && dl > now )); then
			left=$(( (dl - now + 59) / 60 ))
			ui_info "  …жду подтверждения (touch ${_NETSAFE_OK}), осталось ~${left} мин."
		fi
	done
	if [[ -e "$_NETSAFE_REVERTED" ]]; then
		ui_warn "Подтверждение не получено за ${mins} мин — SSH/firewall откатаны к прежним (firewall выключен)."
	else
		ui_warn "Подтверждение не получено, а таймер отката не отработал. Проверьте вручную: ufw status, sshd -T | grep port."
	fi
	ui_info "Если доступ на самом деле есть — повторите: ${UI_W}$(ls_hint --only ssh)${UI_NC} и подтвердите в этот раз."
	return 0
}
