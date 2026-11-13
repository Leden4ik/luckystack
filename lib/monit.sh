#!/bin/bash
# =============================================================================
# lib/monit.sh — Этап (опц.): мониторинг Monit с интеграцией в ISPConfig.
# Поднимает monit httpd на localhost:2812 с учёткой admin — её ISPConfig
# встраивает в раздел System → Server Config → Monitor (поле Monit URL).
# Проверки сервисов формируются по факту установленного (nginx/apache, mariadb,
# php-fpm, redis, postgresql, sshd, система/диск).
# =============================================================================

stage_monit() {
	ui_info "Monit — лёгкий мониторинг сервисов (+ интеграция с ISPConfig)"

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt install monit"
		ui_info "${UI_D}[dry-run]${UI_NC} httpd localhost:2812 (admin) + проверки сервисов"
		ui_info "${UI_D}[dry-run]${UI_NC} ISPConfig Monitor URL: http://localhost:2812"
		ui_success "Monit (имитация) установлен."
		return 0
	fi

	ui_step "Установка Monit"
	apt_install monit

	# Пароль для веб-интерфейса (его укажем в ISPConfig)
	local mon_pw
	mon_pw="$(config_get_or_gen_password MONIT_PASSWORD 20)"

	# --- Глобальные настройки + httpd (для встраивания в ISPConfig) ---
	# По умолчанию — localhost (безопасно, доступ через SSH-туннель). Если в мастере
	# выбрано «открыть наружу» (MONIT_EXPOSE=y) — биндим на 0.0.0.0 и пускаем ТОЛЬКО
	# с разрешённого IP (MONIT_ALLOW_IP, обычно IP из SSH-сессии админа).
	# ВНИМАНИЕ: НЕ задаём здесь 'set daemon' — он уже есть в /etc/monit/monitrc
	# (Debian), повторное определение ломает 'monit -t'. Задаём только httpd.
	local mon_addr="localhost" mon_where="localhost only" mon_scheme="http"
	if [[ "${MONIT_EXPOSE:-n}" == "y" && -n "${MONIT_ALLOW_IP:-}" ]]; then
		mon_addr="0.0.0.0"; mon_scheme="https"
		mon_where="наружу (0.0.0.0), HTTPS, доступ только с ${MONIT_ALLOW_IP}"
		# Снаружи логин/пароль НЕЛЬЗЯ слать открытым текстом → включаем TLS.
		# PEM: реальный LE-серт хоста, если уже выпущен (этап hostcert); иначе
		# self-signed (hostcert позже обновит на LE и перезагрузит monit).
		_monit_build_pem
	fi
	ui_step "Настройка Monit httpd (${mon_where})"
	{
		echo "# luckystack: веб-интерфейс Monit для ISPConfig (${mon_where})"
		echo "set httpd port 2812"
		echo "    use address ${mon_addr}"
		if [[ "$mon_scheme" == "https" ]]; then
			echo "    with ssl {"
			echo "        pemfile: /etc/monit/monit.pem"
			echo "    }"
		fi
		echo "    allow localhost"
		[[ "${MONIT_EXPOSE:-n}" == "y" && -n "${MONIT_ALLOW_IP:-}" ]] && echo "    allow ${MONIT_ALLOW_IP}"
		echo "    allow admin:'${mon_pw}'"
	} >/etc/monit/conf.d/00-luckystack.conf

	# Firewall (UFW): открыть 2812 только для разрешённого IP. CrowdSec порты не
	# режет — там доступ ограничивает сам monit (allow <IP>).
	if [[ "${MONIT_EXPOSE:-n}" == "y" && -n "${MONIT_ALLOW_IP:-}" ]] \
	   && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
		ufw allow from "${MONIT_ALLOW_IP}" to any port 2812 proto tcp >>"$SETUP_LOG" 2>&1 || true
	fi

	# --- Проверки сервисов (по факту установленного) ---
	_monit_write_checks

	# --- Запуск ---
	sys_run "Проверка конфигурации Monit" monit -t || ui_warn "monit -t сообщил о проблемах — см. вывод."
	sys_run "Включение и запуск Monit" systemctl enable --now monit
	monit reload >>"$SETUP_LOG" 2>&1 || true

	local mon_host="localhost"
	[[ "${MONIT_EXPOSE:-n}" == "y" && -n "${MONIT_ALLOW_IP:-}" ]] && mon_host="${SERVER_FQDN:-<server-ip>}"
	ui_success "Monit запущен. ISPConfig → System → Server Config → Monitor:"
	ui_info "  Monit URL: ${UI_C}${mon_scheme}://${mon_host}:2812${UI_NC} · логин: ${UI_W}admin${UI_NC} · пароль: ${UI_D}MONIT_PASSWORD в setup.conf${UI_NC}"
	[[ "${MONIT_EXPOSE:-n}" == "y" && -n "${MONIT_ALLOW_IP:-}" ]] \
		&& ui_info "  Доступ только с IP ${UI_W}${MONIT_ALLOW_IP}${UI_NC} по ${UI_W}HTTPS${UI_NC} (важно: укажи в ISPConfig URL со схемой ${UI_W}https://${UI_NC})." \
		|| ui_info "  Доступ только с localhost — снаружи через SSH-туннель: ${UI_D}ssh -L 2812:localhost:2812 ...${UI_NC}"
	log "Monit: httpd ${mon_addr}:2812 scheme=${mon_scheme} expose=${MONIT_EXPOSE:-n} allow_ip=${MONIT_ALLOW_IP:-} admin/MONIT_PASSWORD"

	# Если ISPConfig уже установлен — сразу впишем доступ в его Server Config → Monitor.
	# (При полном прогоне monit идёт раньше ISPConfig — там вызов делает stage_ispconfig.)
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] && _monit_apply_to_ispconfig
	return 0
}

# Вписать данные Monit в ISPConfig: System → Server Config → Monitor (monit_url,
# monit_user, monit_password в server.config, секция [monitor]). Правка серверного
# config-блоба — самое чувствительное место, поэтому: бэкап исходного, секция-aware
# awk, sanity-проверка и запись через FROM_BASE64 (без проблем экранирования).
_monit_apply_to_ispconfig() {
	[[ "${MONIT_ISPC_INTEGRATE:-y}" == "y" ]] || return 0
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || return 0
	declare -F _ispc_mysql >/dev/null || return 0
	command -v monit >/dev/null 2>&1 || return 0
	command -v base64 >/dev/null 2>&1 || return 0
	local pw="${MONIT_PASSWORD:-}"
	[[ -n "$pw" ]] || pw="$( [[ -f "${CONFIG_FILE:-}" ]] && . "$CONFIG_FILE" 2>/dev/null; printf '%s' "${MONIT_PASSWORD:-}" )"
	[[ -n "$pw" ]] || { ui_info "MONIT_PASSWORD не найден — интеграция Monit в ISPConfig пропущена."; return 0; }
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} ISPConfig → Server Config → Monitor: monit_url/user/password"
		return 0
	fi
	_ispc_mysql -e "SELECT 1;" >/dev/null 2>&1 || { ui_warn "dbispconfig недоступна — интеграция Monit в ISPConfig пропущена."; return 0; }

	local scheme=http host=localhost
	if [[ "${MONIT_EXPOSE:-n}" == "y" && -n "${MONIT_ALLOW_IP:-}" ]]; then scheme=https; host="${SERVER_FQDN:-localhost}"; fi
	local url="${scheme}://${host}:2812" user=admin
	local sid; sid="$(_ispc_mysql -N -B -e "SELECT server_id FROM server ORDER BY server_id LIMIT 1;" 2>/dev/null)"
	[[ "$sid" =~ ^[0-9]+$ ]] || sid=1

	ui_step "Интеграция Monit в ISPConfig (Server Config → Monitor)"
	local cur new; cur="$(mktemp)"; new="$(mktemp)"
	if ! _ispc_mysql -N -B -r -e "SELECT config FROM server WHERE server_id=${sid};" >"$cur" 2>/dev/null || [[ ! -s "$cur" ]]; then
		ui_warn "Не удалось прочитать server.config — пропуск."; rm -f "$cur" "$new"; return 0
	fi
	cp -a "$cur" /root/.ispconfig-server-config.pre-monit.bak 2>/dev/null || true

	# ВАЖНО: ISPConfig хранит monit_url/user/password в секции [server] (не [monitor]!).
	# Поэтому заменяем эти ключи ПО ИМЕНИ, где бы они ни были, и ДОПОЛНИТЕЛЬНО выкидываем
	# ошибочную секцию [monitor] (её у ISPConfig нет — могла остаться от старой версии
	# установщика, которая по ошибке дописывала её → дубликаты ключей, панель читала пустые).
	MURL="$url" MUSER="$user" MPW="$pw" awk '
		/^\[monitor\]$/ { inmon=1; next }     # секцию [monitor] выкидываем целиком
		/^\[.*\]$/      { inmon=0 }            # любая другая секция — выходим из режима выброса
		inmon { next }                         # строки внутри [monitor] пропускаем
		/^monit_url=/      { print "monit_url="ENVIRON["MURL"];     next }
		/^monit_user=/     { print "monit_user="ENVIRON["MUSER"];   next }
		/^monit_password=/ { print "monit_password="ENVIRON["MPW"]; next }
		{ print }
	' "$cur" >"$new"

	# Sanity: непусто, наш url проставлен, сохранились ключевые секции (на случай порчи).
	if [[ ! -s "$new" ]] || ! grep -Fxq "monit_url=${url}" "$new" || ! grep -qx '\[server\]' "$new"; then
		ui_warn "Проверка изменённого server.config не прошла — НЕ применяю (бэкап: /root/.ispconfig-server-config.pre-monit.bak)."
		rm -f "$cur" "$new"; return 0
	fi

	local b64; b64="$(base64 -w0 <"$new" 2>/dev/null)"
	if [[ -z "$b64" ]] || ! _ispc_mysql -e "UPDATE server SET config=FROM_BASE64('${b64}') WHERE server_id=${sid};" >>"$SETUP_LOG" 2>&1; then
		ui_warn "Запись server.config не удалась — конфиг не изменён."
		rm -f "$cur" "$new"; return 0
	fi
	rm -f "$cur" "$new"
	ui_success "Monit вписан в ISPConfig → System → Server Config → Monitor (URL ${url}, admin / MONIT_PASSWORD)."
	[[ "$scheme" == "http" && "$host" == "localhost" ]] && \
		ui_info "Monit на localhost — встроенный просмотр доступен с сервера/через SSH-туннель (наружу не открыт)."
	log "monit: вписан в ISPConfig server.config (url=${url}, server_id=${sid})"
}

# Собрать /etc/monit/monit.pem (ключ+цепочка) для HTTPS веб-интерфейса Monit.
# Приоритет — реальный LE-серт хоста (если этап hostcert уже отработал), иначе
# self-signed (его hostcert позже заменит на LE и перезагрузит monit). Monit
# требует pemfile с правами 0600 root — иначе 'monit -t' откажется стартовать.
_monit_build_pem() {
	local pem=/etc/monit/monit.pem fqdn="${SERVER_FQDN:-localhost}" d
	for d in "/root/.acme.sh/${fqdn}_ecc" "/root/.acme.sh/${fqdn}"; do
		if [[ -f "$d/fullchain.cer" && -f "$d/${fqdn}.key" ]]; then
			( umask 077; cat "$d/${fqdn}.key" "$d/fullchain.cer" >"$pem" )
			chmod 600 "$pem"
			ui_info "Monit HTTPS: использую LE-сертификат хоста (${fqdn})."
			return 0
		fi
	done
	# self-signed (на время, пока нет LE)
	local k="/etc/monit/.monit.key.$$" c="/etc/monit/.monit.crt.$$"
	if openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
		-keyout "$k" -out "$c" -subj "/CN=${fqdn}" >>"$SETUP_LOG" 2>&1; then
		( umask 077; cat "$k" "$c" >"$pem" ); chmod 600 "$pem"; rm -f "$k" "$c"
		ui_info "Monit HTTPS: временный self-signed сертификат (LE-серт хоста ещё не выпущен)."
	else
		rm -f "$k" "$c"
		ui_warn "Не удалось создать сертификат для Monit — HTTPS не включён, проверьте openssl."
	fi
}

# Сформировать /etc/monit/conf.d/10-services.conf из реально установленного
_monit_write_checks() {
	ui_step "Проверки сервисов Monit"
	local f=/etc/monit/conf.d/10-services.conf
	{
		echo "# luckystack: проверки сервисов (автогенерация)"
		echo ""
		# Система и корневая ФС
		cat <<'SYS'
check system $HOST
    if loadavg (5min) > 4 for 5 cycles then alert
    if memory usage > 85% for 5 cycles then alert
    if cpu usage (user) > 90% for 5 cycles then alert
    if swap usage > 50% for 5 cycles then alert

check filesystem rootfs with path /
    if space usage > 90% then alert
    if inode usage > 90% then alert
SYS
		echo ""
		# SSH (порт — с учётом возможной смены в конце установки)
		if [[ -x /usr/sbin/sshd ]]; then
			cat <<SSHD
check process sshd with pidfile /run/sshd.pid
    start program = "/bin/systemctl start ssh"
    stop  program = "/bin/systemctl stop ssh"
    if failed port ${SSH_PORT:-22} protocol ssh for 3 cycles then restart
SSHD
			echo ""
		fi
		# Веб-сервер
		if [[ "${WEBSERVER:-nginx}" == "nginx" ]]; then
			cat <<'NGINX'
check process nginx with pidfile /run/nginx.pid
    start program = "/bin/systemctl start nginx"
    stop  program = "/bin/systemctl stop nginx"
    if failed host 127.0.0.1 port 80 for 3 cycles then restart
NGINX
		else
			cat <<'APACHE'
check process apache with pidfile /run/apache2/apache2.pid
    start program = "/bin/systemctl start apache2"
    stop  program = "/bin/systemctl stop apache2"
    if failed host 127.0.0.1 port 80 for 3 cycles then restart
APACHE
		fi
		echo ""
		# MariaDB (всегда установлена)
		cat <<'MYSQL'
check process mariadb with pidfile /run/mysqld/mysqld.pid
    start program = "/bin/systemctl start mariadb"
    stop  program = "/bin/systemctl stop mariadb"
    if failed unixsocket /run/mysqld/mysqld.sock for 3 cycles then restart
MYSQL
		echo ""
		# PHP-FPM: мониторим ВСЕ установленные и активные версии, а не только дефолтную.
		# Панель ISPConfig обычно крутится на отдельной версии (php8.2-fpm), сайты — на
		# своих; падение любой важно. Идентификация по мастер-процессу (matching) —
		# pidfile под systemd не пишется, поэтому 'with pidfile' давал «Does not exist».
		local d ver
		for d in /etc/php/*/fpm; do
			[[ -d "$d" ]] || continue
			ver="$(basename "$(dirname "$d")")"          # /etc/php/8.3/fpm → 8.3
			systemctl is-active "php${ver}-fpm" >/dev/null 2>&1 || continue
			echo "check process php${ver}-fpm matching \"php/${ver}/fpm/php-fpm\""
			echo "    start program = \"/bin/systemctl start php${ver}-fpm\""
			echo "    stop  program = \"/bin/systemctl stop php${ver}-fpm\""
			# сокет www-пула проверяем только если он реально есть в /run/php
			[[ -S "/run/php/php${ver}-fpm.sock" ]] && \
				echo "    if failed unixsocket /run/php/php${ver}-fpm.sock for 3 cycles then restart"
			echo ""
		done
		# Redis
		if [[ "${INSTALL_REDIS:-y}" == "y" ]] && command -v redis-server >/dev/null 2>&1; then
			cat <<'REDIS'
check process redis with pidfile /run/redis/redis-server.pid
    start program = "/bin/systemctl start redis-server"
    stop  program = "/bin/systemctl stop redis-server"
    if failed host 127.0.0.1 port 6379 for 3 cycles then restart
REDIS
			echo ""
		fi
		# PostgreSQL (если ставился)
		if command -v psql >/dev/null 2>&1; then
			cat <<'PG'
check process postgresql matching "postgres"
    start program = "/bin/systemctl start postgresql"
    stop  program = "/bin/systemctl stop postgresql"
    if failed host 127.0.0.1 port 5432 type tcp for 3 cycles then restart
PG
			echo ""
		fi
	} >"$f"
}

stage_monit_summary() {
	echo "Monit: http://localhost:2812 (admin / MONIT_PASSWORD в setup.conf)"
}
