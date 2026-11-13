#!/bin/bash
# =============================================================================
# lib/preflight.sh — Этап 1: подготовка системы.
# По статье Perfect Server §1–5: hostname/FQDN, /etc/hosts, timezone, NTP,
# dash→bash, обновление системы, базовые пакеты.
# =============================================================================

# =============================================================================
# Часовой пояс — один для всего сервера: система, PHP (все версии, FPM и CLI), MariaDB, cron,
# журналы. Раньше пояс выставлялся только системе, а PHP оставался в UTC (date.timezone не
# задан): время, посчитанное в PHP, расходилось с базой и системой.
# =============================================================================
_tz_valid() { [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f "/usr/share/zoneinfo/$1" ]]; }
_tz_current() { timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC; }

_tz_set_system() {
	local tz="$1"
	if sys_run "Установка часового пояса ${tz}" timedatectl set-timezone "$tz"; then
		# timedatectl меняет только /etc/localtime, а старый /etc/timezone Debian остаётся
		# (на тесте после смены пояса там висел пояс из образа хостера). Его читают tzdata,
		# Java и часть скриптов — держим в согласии.
		[[ "${DRY_RUN:-0}" != "1" && -f /etc/timezone ]] && { echo "$tz" >/etc/timezone; } 2>/dev/null
		return 0
	else
		# Нет systemd-шины: timedatectl падает «Failed to connect to bus». Задаём
		# зону классическим способом (symlink + /etc/timezone) — не фатально.
		if [[ "${DRY_RUN:-0}" != "1" && -f "/usr/share/zoneinfo/${tz}" ]]; then
			ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime 2>/dev/null || true
			echo "$tz" >/etc/timezone 2>/dev/null || true
			ui_info "timedatectl недоступен (нет systemd-шины) — зона задана вручную (/etc/localtime + /etc/timezone)."
		fi
	fi
}

# date.timezone для каждой установленной версии PHP (fpm, cli, cgi) + reload PHP-FPM.
# $1 — зона (по умолчанию текущая системная).
_tz_php_ini() {
	local tz="${1:-$(_tz_current)}" d n=0 v
	_tz_valid "$tz" || { ui_warn "Часовой пояс '${tz}' не найден — date.timezone для PHP не задан."; return 0; }
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} date.timezone = ${tz} для всех версий PHP"; return 0; }
	shopt -s nullglob
	for d in /etc/php/*/fpm/conf.d /etc/php/*/cli/conf.d /etc/php/*/cgi/conf.d; do
		printf '; LuckyStack: часовой пояс сервера (меняется: luckyctl timezone)\ndate.timezone = "%s"\n' "$tz" >"$d/99-luckystack-timezone.ini"
		chmod 644 "$d/99-luckystack-timezone.ini"; n=$((n + 1))
	done
	for v in /etc/php/*/fpm; do
		v="${v#/etc/php/}"; v="${v%/fpm}"
		systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && systemctl reload "php${v}-fpm" >>"$SETUP_LOG" 2>&1
	done
	shopt -u nullglob
	((n)) && ui_success "PHP: date.timezone = ${tz} (${n} конфигов, PHP-FPM перезагружен)."
	return 0
}
# У ISPConfig свой пояс в config.inc.php, он задаётся при установке и может не совпасть с системным.
# От него зависят время в панели и плановые задания ISPConfig.
_tz_ispconfig() {
	local tz="${1:-$(_tz_current)}" x f n=0
	_tz_valid "$tz" || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	for x in server interface; do
		f="/usr/local/ispconfig/${x}/lib/config.inc.php"
		[[ -f "$f" ]] || continue
		grep -qE "^\\\$conf\['timezone'\] = '" "$f" || continue
		grep -qF "\$conf['timezone'] = '${tz}';" "$f" && continue
		cp -a "$f" "$f.tzbak"
		sed -i -E "s|^(\\\$conf\['timezone'\] = ')[^']*(';)|\1${tz}\2|" "$f"
		if php -l "$f" >/dev/null 2>&1; then
			rm -f "$f.tzbak"; n=$((n + 1))
		else
			mv -f "$f.tzbak" "$f"; ui_warn "ISPConfig: не удалось сменить часовой пояс в ${f}, откатил."
		fi
	done
	if ((n)); then
		declare -F _ispc_interface_php_reload >/dev/null && _ispc_interface_php_reload
		ui_success "ISPConfig: часовой пояс ${tz}."
	fi
	return 0
}

# для --update: PHP приводится к текущему поясу системы
_tz_php_sync() {
	local tz; tz="$(_tz_current)"
	if [[ "${DRY_RUN:-0}" != "1" && -f /etc/timezone ]] && _tz_valid "$tz" \
	   && [[ "$(tr -d '[:space:]' </etc/timezone)" != "$tz" ]]; then
		echo "$tz" >/etc/timezone && ui_info "/etc/timezone приведён к поясу системы: ${tz}"
	fi
	_tz_php_ini "$tz"
	_tz_ispconfig "$tz"
}

# Сменить пояс везде. $1 — зона, $2 — перезапускать MariaDB (y/n).
apply_timezone_everywhere() {
	local tz="$1" restart_db="${2:-y}"
	_tz_valid "$tz" || { ui_error "Часовой пояс '${tz}' не найден (пример: Europe/Moscow, UTC; список: timedatectl list-timezones)."; return 1; }
	ui_step "Часовой пояс ${tz}: система, PHP, MariaDB, cron, журналы"
	_tz_set_system "$tz"
	_tz_php_ini "$tz"
	_tz_ispconfig "$tz"
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	local s
	for s in cron rsyslog; do systemctl is-active --quiet "$s" 2>/dev/null && systemctl restart "$s" >>"$SETUP_LOG" 2>&1; done
	systemctl is-active --quiet nginx 2>/dev/null && systemctl reload nginx >>"$SETUP_LOG" 2>&1
	systemctl is-active --quiet apache2 2>/dev/null && systemctl reload apache2 >>"$SETUP_LOG" 2>&1
	# MariaDB запоминает системный пояс при старте (time_zone=SYSTEM) — без перезапуска NOW() в базе
	# останется в старом поясе
	if systemctl is-active --quiet mariadb 2>/dev/null; then
		if [[ "$restart_db" == "y" ]]; then
			systemctl restart mariadb >>"$SETUP_LOG" 2>&1 && ui_success "MariaDB перезапущена, пояс в базе: $(mariadb -N -e 'SELECT @@system_time_zone' 2>/dev/null)." \
				|| ui_warn "MariaDB не перезапустилась — проверьте: systemctl status mariadb"
		else
			ui_warn "MariaDB не перезапущена: пока не перезапустите (systemctl restart mariadb), время в базе остаётся в старом поясе."
		fi
	fi
	declare -F config_set >/dev/null && [[ -f "${CONFIG_FILE:-}" ]] && config_set TIMEZONE "$tz"
	ui_success "Часовой пояс ${tz} применён. Сейчас: $(date '+%F %T %Z')."
}

# Режим --timezone [Зона]: показать текущий пояс, спросить новый (если не передан), применить.
run_timezone_mode() {
	require_root
	local cur tz="${TZ_ARG:-}"
	cur="$(_tz_current)"
	ui_header "Часовой пояс сервера"
	ui_info "Сейчас: ${UI_W}${cur}${UI_NC} (система $(date '+%H:%M'), PHP: $(php -r 'echo date_default_timezone_get();' 2>/dev/null || echo '?'), MariaDB: $(mariadb -N -e 'SELECT @@system_time_zone' 2>/dev/null || echo '?'))"
	if [[ -z "$tz" ]]; then
		[[ -t 0 ]] || { ui_error "Укажите пояс: $(ls_hint --timezone Europe/Moscow)"; return 1; }
		while :; do
			ui_input "Новый часовой пояс (например Europe/Moscow, Asia/Yekaterinburg, UTC)" "$cur"
			tz="$UI_INPUT"
			_tz_valid "$tz" && break
			ui_warn "Пояс '${tz}' не найден. Список: timedatectl list-timezones"
		done
	fi
	local rdb=y
	if [[ -t 0 ]] && systemctl is-active --quiet mariadb 2>/dev/null; then
		ui_confirm "Перезапустить MariaDB, чтобы пояс применился и в базе (сайты будут недоступны несколько секунд)?" y || rdb=n
	fi
	apply_timezone_everywhere "$tz" "$rdb"
}

stage_preflight() {
	local fqdn="${SERVER_FQDN:-}" tz="${TIMEZONE:-UTC}"
	local short="${fqdn%%.*}"

	# --- Swap (рано: до тяжёлых этапов вроде ClamAV) — защита от OOM на малых VPS ---
	declare -F _ensure_swap >/dev/null && _ensure_swap
	# --- Перф-sysctl (swappiness персистентно + TCP BBR) — независимо от swap ---
	declare -F _tune_kernel_perf >/dev/null && _tune_kernel_perf
	# --- IPv6 у хостера не ходит наружу → IPv4 первым (до любых загрузок) ---
	declare -F _ipv6_egress_fix >/dev/null && _ipv6_egress_fix

	# --- Hostname / FQDN ---
	if [[ -n "$fqdn" && "$fqdn" == *.* ]]; then
		ui_step "Настройка hostname: ${fqdn} (короткое: ${short})"
		if ! sys_run "Установка hostname ${short}" hostnamectl set-hostname "$short"; then
			# Нет systemd-шины (минимальный контейнер/WSL до полного старта systemd):
			# hostnamectl падает «Failed to connect to bus». Ставим hostname вручную —
			# и это не фатально для дальнейшей установки.
			if [[ "${DRY_RUN:-0}" != "1" ]]; then
				echo "$short" >/etc/hostname 2>/dev/null || true
				hostname "$short" >/dev/null 2>&1 || true
				ui_info "hostnamectl недоступен (нет systemd-шины) — hostname задан вручную через /etc/hostname."
			fi
		fi

		# /etc/hosts: гарантируем строку «IP FQDN short»
		if [[ "${DRY_RUN:-0}" != "1" ]]; then
			local main_ip
			main_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
			[[ -z "$main_ip" ]] && main_ip="127.0.1.1"
			# Строки, где наше короткое имя привязано к другому полному (шаблон хостера, опечатка
			# при заказе), перебивали бы нашу: hostname -f берёт первую, и почта получала чужое имя.
			# Комментируем их, копия файла рядом.
			local bad_lines
			bad_lines="$(awk -v s="$short" -v f="$fqdn" '/^[[:space:]]*#/ || NF < 2 {next}
				{ hs = 0; hf = 0; for (i = 2; i <= NF; i++) { if ($i == s) hs = 1; if ($i == f) hf = 1 }
				  if (hs && !hf) print NR }' /etc/hosts 2>/dev/null)"
			if [[ -n "$bad_lines" ]]; then
				[[ -f /etc/hosts.luckystack.bak ]] || cp -a /etc/hosts /etc/hosts.luckystack.bak
				local n
				for n in $bad_lines; do
					ui_warn "/etc/hosts: строка «$(sed -n "${n}p" /etc/hosts)» даёт серверу другое имя, закомментирована."
					sed -i "${n}s/^/# luckystack: другое имя сервера, заменено на ${fqdn}: /" /etc/hosts
				done
			fi
			# Нужна строка, где есть и полное, и короткое имя: hostname -f ищет короткое и берёт
			# первое имя этой строки. Шаблоны хостеров пишут полное имя с чужим коротким
			# («ad-srb.example.net d-srb») или без него, тогда hostname -f не работает вовсе,
			# а Postfix и make-ssl-cert при установке получают короткое имя.
			if ! awk -v f="$fqdn" -v s="$short" '/^[[:space:]]*#/ {next}
					{ hf = 0; hs = 0; for (i = 2; i <= NF; i++) { if ($i == f) hf = 1; if ($i == s) hs = 1 } if (hf && hs) found = 1 }
					END { exit !found }' /etc/hosts 2>/dev/null; then
				[[ -f /etc/hosts.luckystack.bak ]] || cp -a /etc/hosts /etc/hosts.luckystack.bak
				printf '%s %s %s\n' "$main_ip" "$fqdn" "$short" >>/etc/hosts
				ui_success "В /etc/hosts добавлено: ${main_ip} ${fqdn} ${short}"
			else
				ui_info "/etc/hosts уже содержит ${fqdn} ${short}"
			fi
			local got; got="$(hostname -f 2>/dev/null)"
			[[ "$got" == "$fqdn" ]] || ui_warn "hostname -f отвечает «${got}», а должно быть ${fqdn}: проверьте /etc/hosts."
		else
			ui_info "${UI_D}[dry-run]${UI_NC} обновление /etc/hosts для ${fqdn}"
		fi
	else
		ui_warn "FQDN не задан или без домена ('${fqdn}') — пропускаю настройку hostname."
	fi

	# --- Часовой пояс ---
	ui_step "Часовой пояс: ${tz}"
	_tz_set_system "$tz"

	# --- Синхронизация времени (chrony по умолчанию, либо классический ntp) ---
	local time_sync="${TIME_SYNC:-chrony}"
	if [[ "$time_sync" == "ntp" ]]; then
		ui_step "Синхронизация времени (ntp)"
		apt_install ntp
		sys_run "Включение ntp" systemctl enable --now ntp || \
			sys_run "Включение ntpsec" systemctl enable --now ntpsec
	else
		ui_step "Синхронизация времени (chrony)"
		apt_install chrony
		sys_run "Включение chrony" systemctl enable --now chrony
	fi

	# --- dash → bash (для совместимости скриптов ISPConfig) ---
	ui_step "Системная оболочка /bin/sh → bash"
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		echo "dash dash/sh boolean false" | debconf-set-selections 2>/dev/null
		ui_spin "Переключение /bin/sh на bash" dpkg-reconfigure -f noninteractive dash || \
			ui_warn "Не удалось переключить dash (не критично)"
	else
		ui_info "${UI_D}[dry-run]${UI_NC} dpkg-reconfigure dash → bash"
	fi

	# --- Обновление системы ---
	ui_step "Обновление системы"
	apt_update
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		ui_spin "Обновление установленных пакетов (apt upgrade)" \
			apt-get -y -qq -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef upgrade
	else
		ui_info "${UI_D}[dry-run]${UI_NC} apt-get upgrade"
	fi

	# --- Обязательные зависимости установщика (нужны для репозиториев/сборки) ---
	# Ставятся ВСЕГДА, независимо от выбора утилит в мастере.
	ui_step "Базовые зависимости установщика"
	# ВНИМАНИЕ: без software-properties-common — его нет в Debian 13 (trixie),
	# а add-apt-repository в установщике не используется (репозитории добавляются
	# вручную). apt атомарен, и этот пакет ронял всю установку базовых зависимостей.
	# rsyslog ОБЯЗАТЕЛЕН: Debian 12+ minimal пишет только в journald, без /var/log/
	# auth.log|mail.log|syslog. Без них fail2ban (jail sshd) не стартует, а ISPConfig/
	# mailsni/healthcheck ожидают файловые логи. rsyslog создаёт их.
	# Базовый фундамент: сеть/ключи/репозитории (wget/curl/gnupg/ca-certs/...), журналы
	# (rsyslog), и утилиты, на которые ОПИРАЕТСЯ сам установщик и последующие этапы:
	#   sudo      — dbtools (sudo -u postgres), security;
	#   cron      — acme.sh auto-renew, ISPConfig cron;
	#   bind9-dnsutils — dig: hostcert/maildeliver/healthcheck (без него LE-проверки слепы);
	#               старого имени dnsutils в Debian 13 уже нет;
	#   openssl   — серты (ftp/hostcert), healthcheck;
    #   iproute2  — ss: healthcheck (порты);
	#   unzip/tar/xz-utils/bzip2 — распаковка (ISPConfig/плагины/архивы);
	#   ca-certificates — TLS к репозиториям/acme.
	apt_install wget curl gnupg2 ca-certificates apt-transport-https dirmngr lsb-release \
		rsyslog sudo cron bind9-dnsutils openssl iproute2 unzip tar xz-utils bzip2
	# Гарантируем, что rsyslog/cron запущены (логи + расписания сразу доступны).
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		systemctl enable --now rsyslog >>"$SETUP_LOG" 2>&1 || true
		systemctl enable --now cron    >>"$SETUP_LOG" 2>&1 || true
	fi

	# --- Выбранные администратором утилиты ---
	# Список формируется в мастере (UTILS). Если не задан (старый конфиг/
	# unattended) — ставим разумный набор по умолчанию. 'ntp' тут не фигурирует:
	# синхронизацию времени делает chrony (выше), 'ntp' с ним конфликтует
	# (TIME_SYNC=ntp переключает на классический ntp).
	local utils="${UTILS:-nano vim mc htop git sudo rsync unzip tar bzip2 perl net-tools bash-completion}"
	if [[ -n "$utils" ]]; then
		ui_step "Утилиты администратора"
		# shellcheck disable=SC2086
		apt_install $utils
		# Жёстко помечаем как вручную установленные: админ-утилиты НИКОГДА не удаляются
		# при uninstall/purge (их не трогает ни одна uninstall_*, а `apt autoremove`
		# чистит только осиротевшие зависимости). apt-mark гарантирует это даже если
		# какой-то пакет ранее был подтянут как зависимость другого.
		# shellcheck disable=SC2086
		[[ "${DRY_RUN:-0}" == "1" ]] || apt-mark manual $utils >>"$SETUP_LOG" 2>&1 || true
	else
		ui_info "Утилиты администратора не выбраны — пропуск."
	fi

	# Факт IPv6 на сервере → SERVER_HAS_IPV6 в setup.conf (единая истина для IPv6-зависимых
	# фиксов: named -4, проверки портов и пр.). Переопределяемо вручную в setup.conf.
	declare -F _detect_ipv6 >/dev/null && _detect_ipv6

	ui_success "Система подготовлена."
	return 0
}

stage_preflight_summary() {
	echo "Hostname: ${SERVER_FQDN:-—} · Timezone: ${TIMEZONE:-—}"
}
