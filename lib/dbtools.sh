#!/bin/bash
# =============================================================================
# lib/dbtools.sh — Веб-админки БД (выбор зависит от веб-сервера).
#   nginx  → Adminer (один файл, MariaDB+PostgreSQL, под PHP-FPM, БЕЗ Apache)
#            ИЛИ phpMyAdmin (только MariaDB) — выбор в мастере (DBADMIN_TOOL).
#   apache → phpMyAdmin (MariaDB) + pgAdmin (PostgreSQL, ему нужен Apache).
# Запускаются после php (нужен PHP-FPM/веб-сервер).
# =============================================================================

# Какой инструмент админки БД ставить (с учётом веб-сервера).
# Apache → всегда phpMyAdmin (pgAdmin ставит этап postgresql). nginx → DBADMIN_TOOL.
_dbadmin_tool() {
	if [[ "${WEBSERVER:-nginx}" == "apache" ]]; then echo "phpmyadmin"; return; fi
	echo "${DBADMIN_TOOL:-adminer}"
}

# --- Adminer: один PHP-файл, MariaDB+PostgreSQL, работает под nginx+PHP-FPM ----
_install_adminer() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} Adminer → /var/www/html/adminer/index.php (+ php-pgsql)"
		return 0
	fi
	mkdir -p /var/www/html/adminer
	if [[ ! -f /var/www/html/adminer/index.php ]]; then
		ui_step "Установка Adminer (веб-админка БД, один файл)"
		if ! timeout 60 bash -c "wget -qO /var/www/html/adminer/index.php --timeout=30 --tries=2 https://www.adminer.org/latest.php" \
			|| [[ ! -s /var/www/html/adminer/index.php ]]; then
			ui_warn "Не удалось скачать Adminer (сеть/таймаут)."
			return 1
		fi
		chown -R www-data:www-data /var/www/html/adminer 2>/dev/null || true
	else
		ui_info "Adminer уже установлен."
	fi
	ui_success "Adminer → http://<server>/adminer/ (MariaDB + PostgreSQL)"
	log "adminer: /var/www/html/adminer/index.php"
	return 0
}

# Драйвер PostgreSQL для PHP версии по умолчанию (нужен Adminer'у для PostgreSQL)
_ensure_php_pgsql() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} php${PHP_DEFAULT:-8.3}-pgsql"; return 0; }
	local v="${PHP_DEFAULT:-8.3}"
	dpkg -l "php${v}-pgsql" 2>/dev/null | grep -q '^ii' && return 0
	apt_install "php${v}-pgsql"
	systemctl reload "php${v}-fpm" >>"$SETUP_LOG" 2>&1 || systemctl restart "php${v}-fpm" >>"$SETUP_LOG" 2>&1 || true
}

# --- phpMyAdmin (только MariaDB) ---------------------------------------------
_install_phpmyadmin() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt install phpmyadmin + dbconfig (служебная БД phpmyadmin) + симлинк"
		return 0
	fi
	export DEBIAN_FRONTEND=noninteractive
	# Служебная БД phpMyAdmin (pmadb) — для связей/закладок/истории (как в Perfect Server).
	# Создаём через dbconfig; admin-user/pass нужны явно: на MariaDB 11 debian.cnf-root
	# по сокету не проходит → ERROR 1045 (та же беда, что у Roundcube).
	local pma_pw; pma_pw="$(config_get_or_gen_password PHPMYADMIN_DB_PW 20)"
	echo "phpmyadmin phpmyadmin/dbconfig-install boolean true"               | debconf-set-selections
	echo "phpmyadmin phpmyadmin/mysql/admin-user string root"               | debconf-set-selections
	echo "phpmyadmin phpmyadmin/mysql/admin-pass password ${MARIADB_ROOT_PW:-}" | debconf-set-selections
	echo "phpmyadmin phpmyadmin/mysql/app-pass password ${pma_pw}"          | debconf-set-selections
	echo "phpmyadmin phpmyadmin/app-password-confirm password ${pma_pw}"    | debconf-set-selections
	echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect "         | debconf-set-selections
	ui_step "Установка phpMyAdmin"
	# Без рекомендуемых: цепочка php-tcpdf -> php-mcrypt из sury тянет самую новую PHP (8.5)
	# только ради CLI. Расширения gd/curl/zip/bz2 уже стоят у версий PHP из этапа PHP.
	APT_NO_RECOMMENDS=1 apt_install phpmyadmin php-tcpdf
	declare -F _php_drop_stray >/dev/null && _php_drop_stray
	mkdir -p /var/www/html
	ln -sfn /usr/share/phpmyadmin /var/www/html/phpmyadmin

	# Контроль: служебная БД создана? dbconfig на Debian 13 нередко рапортует успех,
	# но БД не создаёт — тогда поднимаем pmadb вручную (как для Roundcube).
	if ! mysql -NBe "USE phpmyadmin" >/dev/null 2>&1; then
		ui_warn "Служебная БД phpmyadmin не создана dbconfig — поднимаю вручную."
		_phpmyadmin_create_pmadb && \
			ui_success "Хранилище конфигурации phpMyAdmin (pmadb) настроено вручную." || \
			ui_warn "pmadb не настроено — расширенные функции phpMyAdmin будут отключены (см. $SETUP_LOG)."
	else
		ui_success "Хранилище конфигурации phpMyAdmin (pmadb) готово."
	fi

	ui_success "phpMyAdmin → http://<server>/phpmyadmin (вход по учётке MariaDB)"
	log "phpMyAdmin: симлинк + pmadb (служебная БД phpmyadmin)"
	return 0
}

# Ручное создание служебной БД phpMyAdmin (pmadb) в обход dbconfig: берём имя/юзера/
# пароль из /etc/dbconfig-common/phpmyadmin.conf (их уже знает config-db.php пакета),
# создаём БД/пользователя, грузим штатную схему create_tables.sql.
_phpmyadmin_create_pmadb() {
	local conf=/etc/dbconfig-common/phpmyadmin.conf
	local dbn dbu dbp schema
	if [[ -f "$conf" ]]; then
		dbn="$(grep -oP "dbc_dbname='\K[^']*" "$conf")"
		dbu="$(grep -oP "dbc_dbuser='\K[^']*" "$conf")"
		dbp="$(grep -oP "dbc_dbpass='\K[^']*" "$conf")"
	fi
	dbn="${dbn:-phpmyadmin}"; dbu="${dbu:-phpmyadmin}"
	[[ -n "$dbp" ]] || dbp="$(config_get_or_gen_password PHPMYADMIN_DB_PW 20)"
	schema=/usr/share/phpmyadmin/sql/create_tables.sql
	mysql --defaults-file=/root/.my.cnf <<SQL || return 1
CREATE DATABASE IF NOT EXISTS \`${dbn}\` CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '${dbu}'@'localhost' IDENTIFIED BY '${dbp}';
GRANT ALL PRIVILEGES ON \`${dbn}\`.* TO '${dbu}'@'localhost';
FLUSH PRIVILEGES;
SQL
	[[ -f "$schema" ]] && mysql --defaults-file=/root/.my.cnf "$dbn" < "$schema" 2>>"$SETUP_LOG"
	# config-db.php должен содержать креды — если dbconfig его не выложил, пишем сами,
	# иначе phpMyAdmin не подхватит pmadb даже при готовой БД.
	local cdb=/etc/phpmyadmin/config-db.php
	if [[ ! -f "$cdb" ]] || ! grep -q "dbpass" "$cdb" 2>/dev/null; then
		cat >"$cdb" <<PHP
<?php
\$dbuser='${dbu}';
\$dbpass='${dbp}';
\$basepath='';
\$dbname='${dbn}';
\$dbserver='localhost';
\$dbport='3306';
\$dbtype='mysql';
PHP
		chmod 640 "$cdb" 2>/dev/null || true
		chown root:www-data "$cdb" 2>/dev/null || true
	fi
	mysql -NBe "USE ${dbn}" >/dev/null 2>&1
}

# Поднять PHP-лимиты для веб-админок БД (импорт дампов): дефолт upload_max=2M мал.
# Пишем conf.d-ini для версии PHP по умолчанию (под ней работает стартовый пул, что
# обслуживает /phpmyadmin и /adminer). Пулы сайтов ISPConfig имеют свои настройки и
# НЕ затрагиваются. Идемпотентно.
_dbadmin_php_limits() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} PHP-лимиты импорта (upload/post 256M) для веб-админки БД"; return 0; }
	local v="${PHP_DEFAULT:-8.3}"
	local ini="/etc/php/${v}/fpm/conf.d/99-luckystack-dbadmin.ini"
	[[ -d "/etc/php/${v}/fpm/conf.d" ]] || return 0
	cat >"$ini" <<'INI'
; luckystack: лимиты импорта дампов для веб-админок БД (phpMyAdmin/Adminer)
upload_max_filesize = 256M
post_max_size = 256M
memory_limit = 512M
max_execution_time = 600
max_input_time = 600
INI
	systemctl reload "php${v}-fpm" >>"$SETUP_LOG" 2>&1 || systemctl restart "php${v}-fpm" >>"$SETUP_LOG" 2>&1 || true
	ui_success "Лимит импорта дампов поднят до 256M (php${v}-fpm)."
}

# --- Этап «веб-админка БД» (ключ phpmyadmin сохранён для совместимости) -------
stage_phpmyadmin() {
	local tool; tool="$(_dbadmin_tool)"
	ui_info "Веб-админка БД: ${UI_BOLD}${tool}${UI_NC} (веб-сервер: ${WEBSERVER:-nginx})"
	case "$tool" in
		adminer)    _install_adminer ;;
		phpmyadmin) _install_phpmyadmin ;;
		none|"")    ui_info "Веб-админка БД отключена — пропуск."; return 0 ;;
		*)          ui_warn "Неизвестный DBADMIN_TOOL='${tool}' — ставлю Adminer."; _install_adminer ;;
	esac
	# Поднять лимит импорта дампов (дефолтные 2M малы для бэкапов БД).
	_dbadmin_php_limits
	# Ограничение доступа (только по FQDN / только с IP) — если задано в мастере.
	_dbadmin_restrict
}

stage_phpmyadmin_summary() { echo "Веб-админка БД: $(_dbadmin_tool)"; }

# Ограничить доступ к веб-админкам БД (/phpmyadmin, /adminer): только по FQDN
# (DBADMIN_FQDN_ONLY=y, по умолчанию — закрыть по IP/чужому домену) и/или только с
# разрешённых IP (DBADMIN_ALLOW_IPS). nginx → сниппет default-locations; Apache →
# conf-drop-in. С проверкой конфига веб-сервера и откатом. Идемпотентно.
_dbadmin_restrict() {
	[[ -e /var/www/html/phpmyadmin || -e /var/www/html/adminer ]] || return 0
	local fqdn="${SERVER_FQDN:-}" fqonly="${DBADMIN_FQDN_ONLY:-y}" ips="${DBADMIN_ALLOW_IPS:-}"
	if [[ "$fqonly" != "y" && -z "$ips" ]]; then
		ui_info "Веб-админка БД: ограничения доступа не заданы (открыта по умолчанию)."; return 0
	fi
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} ограничение веб-админки БД (FQDN-only=${fqonly}, IP='${ips:-—}')"; return 0
	fi
	if [[ "${WEBSERVER:-nginx}" == "apache" ]]; then _dbadmin_restrict_apache "$fqdn" "$fqonly" "$ips"
	else _dbadmin_restrict_nginx "$fqdn" "$fqonly" "$ips"; fi
}

_dbadmin_restrict_nginx() {
	local fqdn="$1" fqonly="$2" ips="$3" path ip
	local dir=/etc/nginx/snippets/default-locations snip
	mkdir -p "$dir"; snip="$dir/dbadmin-restrict.conf"
	local host_check="" ; [[ "$fqonly" == "y" && -n "$fqdn" ]] && host_check="if (\$host != \"${fqdn}\") { return 403; }"
	local ip_acl="" ; if [[ -n "$ips" ]]; then for ip in $ips; do ip_acl+="        allow ${ip};"$'\n'; done; ip_acl+="        deny all;"; fi
	local tmp; tmp="$(mktemp)"
	{
		echo "# luckystack: dbadmin-restrict — доступ к веб-админкам БД (FQDN-only/IP)"
		for path in phpmyadmin adminer; do
			[[ -e "/var/www/html/${path}" ]] || continue
			echo "location ^~ /${path} {"
			[[ -n "$host_check" ]] && echo "        ${host_check}"
			[[ -n "$ip_acl" ]] && printf '%s\n' "$ip_acl"
			echo "        location ~ \\.php\$ {"
			[[ -n "$host_check" ]] && echo "            ${host_check}"
			echo "            include snippets/php-default.conf;"
			echo "        }"
			echo "}"
		done
	} >"$tmp"
	[[ -f "$snip" ]] && cp -a "$snip" "${snip}.bak"
	mv "$tmp" "$snip"
	chmod 644 "$snip"
	# vhost домена подключает default-locations (hostcert.sh), а apps-vhost ISPConfig (порт для
	# пользователей, webmail) — нет: там phpMyAdmin был открыт всем. Отдельный файл правил доступа
	# подключаем внутри его location /phpmyadmin. FQDN-only → на apps-vhost не пускаем никого.
	local acl=/etc/nginx/snippets/dbadmin-acl.conf
	{
		echo "# luckystack: доступ к phpMyAdmin на apps-vhost ISPConfig (подключается внутри location /phpmyadmin)"
		if [[ "$fqonly" == "y" ]]; then echo "deny all;   # phpMyAdmin только по FQDN ${fqdn}"
		elif [[ -n "$ips" ]]; then for ip in $ips; do echo "allow ${ip};"; done; echo "deny all;"; fi
	} >"$acl"
	chmod 644 "$acl"
	local apps_baks=(); _dbadmin_apps_acl_patch apps_baks
	if nginx -t >>"$SETUP_LOG" 2>&1; then
		systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
		rm -f "${snip}.bak"
		local b; for b in "${apps_baks[@]}"; do rm -f "$b.dbacl.bak"; done
		ui_success "Веб-админка БД ограничена$([[ "$fqonly" == y ]] && echo ": только по FQDN")$([[ -n "$ips" ]] && echo " · IP: ${ips}")."
	else
		if [[ -f "${snip}.bak" ]]; then mv -f "${snip}.bak" "$snip"; else rm -f "$snip"; fi
		local b; for b in "${apps_baks[@]}"; do [[ -f "$b.dbacl.bak" ]] && mv -f "$b.dbacl.bak" "$b"; done
		systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
		ui_warn "nginx -t не прошёл — ограничение веб-админки БД не применено (см. ${SETUP_LOG})."
	fi
}

# Подключить /etc/nginx/snippets/dbadmin-acl.conf внутри location /phpmyadmin apps-vhost ISPConfig:
# в живом файле и в шаблоне conf-custom (ISPConfig перегенерирует apps-vhost из него). Идемпотентно.
# $1 — имя массива, куда сложить пути изменённых файлов (их бэкапы — <файл>.dbacl.bak).
_dbadmin_apps_acl_patch() {
	local -n _out="$1"
	local f
	for f in /etc/nginx/sites-available/apps.vhost /usr/local/ispconfig/server/conf-custom/nginx_apps.vhost.master; do
		[[ -f "$f" ]] || continue
		grep -q 'dbadmin-acl.conf' "$f" && continue
		grep -q 'location /phpmyadmin {' "$f" || continue
		cp -a "$f" "$f.dbacl.bak"
		awk '/location \/phpmyadmin \{/ && !d { print; print "                include /etc/nginx/snippets/dbadmin-acl.conf;   # luckystack: доступ к phpMyAdmin"; d=1; next } { print }' \
			"$f" >"$f.tmp" && cat "$f.tmp" >"$f" && rm -f "$f.tmp"
		_out+=("$f")
	done
}

_dbadmin_restrict_apache() {
	local fqdn="$1" fqonly="$2" ips="$3" path
	local conf=/etc/apache2/conf-available/luckystack-dbadmin-restrict.conf
	{
		echo "# luckystack: dbadmin-restrict (FQDN-only/IP)"
		for path in phpmyadmin adminer; do
			[[ -e "/var/www/html/${path}" || -e "/usr/share/${path}" ]] || continue
			echo "<Location /${path}>"
			echo "    <RequireAll>"
			[[ -n "$ips" ]] && echo "        Require ip ${ips}"
			[[ "$fqonly" == "y" && -n "$fqdn" ]] && echo "        Require expr \"%{HTTP_HOST} == '${fqdn}'\""
			echo "    </RequireAll>"
			echo "</Location>"
		done
	} >"$conf"
	a2enconf luckystack-dbadmin-restrict >>"$SETUP_LOG" 2>&1 || true
	if apache2ctl configtest >>"$SETUP_LOG" 2>&1; then
		systemctl reload apache2 >>"$SETUP_LOG" 2>&1 || true
		ui_success "Веб-админка БД ограничена (Apache)$([[ "$fqonly" == y ]] && echo ": только по FQDN")$([[ -n "$ips" ]] && echo " · IP: ${ips}")."
	else
		a2disconf luckystack-dbadmin-restrict >>"$SETUP_LOG" 2>&1 || true
		rm -f "$conf"; systemctl reload apache2 >>"$SETUP_LOG" 2>&1 || true
		ui_warn "apache configtest не прошёл — ограничение веб-админки БД не применено."
	fi
}

# --- PostgreSQL (+ pgAdmin при Apache / Adminer при nginx) -------------------
stage_postgresql() {
	ui_info "PostgreSQL (доп. СУБД рядом с MariaDB)"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt install postgresql postgresql-contrib + enable"
		if [[ "${WEBSERVER:-nginx}" == "apache" ]]; then
			ui_info "${UI_D}[dry-run]${UI_NC} pgAdmin (Apache): репозиторий + pgadmin4-web + setup-web.sh"
		else
			ui_info "${UI_D}[dry-run]${UI_NC} админка PostgreSQL: Adminer (nginx, без Apache) + php-pgsql"
		fi
		ui_success "PostgreSQL (имитация) установлен."
		return 0
	fi

	# --- PostgreSQL server ---
	ui_step "Установка PostgreSQL"
	apt_install postgresql postgresql-contrib
	sys_run "Запуск и автозагрузка PostgreSQL" systemctl enable --now postgresql

	local pg_pw
	pg_pw="$(config_get_or_gen_password POSTGRES_PASSWORD 24)"
	sudo -u postgres psql -c "ALTER USER postgres PASSWORD '${pg_pw}';" >>"$SETUP_LOG" 2>&1 || \
		ui_warn "Не удалось задать пароль роли postgres."
	ui_success "PostgreSQL установлен (пароль роли postgres — в setup.conf: POSTGRES_PASSWORD)."

	# --- Админка PostgreSQL: pgAdmin (Apache) или Adminer (nginx) ---
	if [[ "${WEBSERVER:-nginx}" == "apache" ]]; then
		_pgadmin_install || ui_warn "pgAdmin не установлен (PostgreSQL при этом работает)."
	else
		# nginx: НЕ ставим pgAdmin (он тянет Apache). PostgreSQL администрируем
		# через Adminer (он уже стоит, если выбран; иначе ставим) + php-pgsql.
		ui_step "Админка PostgreSQL под nginx — Adminer (без Apache)"
		_install_adminer || ui_warn "Adminer не установлен — PostgreSQL без веб-админки."
		_ensure_php_pgsql
		_dbadmin_restrict   # переприменить ограничение (Adminer мог появиться только сейчас)
		ui_info "PostgreSQL администрируется через Adminer: http://<server>/adminer/ (System: PostgreSQL)"
	fi
	return 0
}

# pgAdmin 4 web (только для Apache-стека: пакет pgadmin4-web жёстко зависит от Apache)
_pgadmin_install() {
	ui_step "Подключение репозитория pgAdmin"
	local codename; codename="$(os_codename)"
	[[ -z "$codename" ]] && { ui_warn "Не определено кодовое имя релиза — pgAdmin-репозиторий не добавлен."; return 1; }
	# Ключ pgAdmin: ОБЯЗАТЕЛЬНО с таймаутом и в batch-режиме (иначе `curl | gpg
	# --dearmor` на свежей системе мог ВИСНУТЬ — gpg-agent/dirmngr, медленная сеть).
	if ! timeout 90 bash -c "curl -fsS --connect-timeout 15 --max-time 60 \
		https://www.pgadmin.org/static/packages_pgadmin_org.pub \
		| gpg --batch --yes --dearmor -o /usr/share/keyrings/packages-pgadmin-org.gpg" 2>>"$SETUP_LOG"; then
		ui_warn "Не удалось получить ключ pgAdmin (таймаут/сеть) — pgAdmin пропущен (PostgreSQL работает)."
		return 1
	fi
	echo "deb [signed-by=/usr/share/keyrings/packages-pgadmin-org.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/${codename} pgadmin4 main" \
		>/etc/apt/sources.list.d/pgadmin4.list
	if ! apt_update; then
		ui_warn "Репозиторий pgAdmin недоступен для '${codename}' (возможно, нет сборки под этот релиз)."
		return 1
	fi

	ui_step "Установка pgAdmin 4 (web)"
	apt_install pgadmin4-web || return 1

	local pga_email="${PGADMIN_EMAIL:-admin@${SERVER_FQDN:-localhost}}" pga_pw
	pga_pw="$(config_get_or_gen_password PGADMIN_PASSWORD 20)"
	config_set PGADMIN_EMAIL "$pga_email"

	ui_step "Веб-настройка pgAdmin (setup-web.sh)"
	# PGADMIN_PLATFORM_TYPE=debian ОБЯЗАТЕЛЕН на свежих версиях pgAdmin.
	PGADMIN_SETUP_EMAIL="$pga_email" PGADMIN_SETUP_PASSWORD="$pga_pw" PGADMIN_PLATFORM_TYPE=debian \
		/usr/pgadmin4/bin/setup-web.sh --yes >>"$SETUP_LOG" 2>&1 || true
	# Успех — по созданной БД pgAdmin, а не по коду возврата setup-web.sh.
	if [[ ! -f /var/lib/pgadmin/pgadmin4.db ]]; then
		ui_warn "pgAdmin не настроился (нет /var/lib/pgadmin/pgadmin4.db) — настройте вручную."
		return 1
	fi
	systemctl restart apache2 >>"$SETUP_LOG" 2>&1 || true
	ui_success "pgAdmin: http://<server>/pgadmin4 (логин: ${pga_email})"
	return 0
}

stage_postgresql_summary() {
	local adm="Adminer (/adminer)"
	[[ "${WEBSERVER:-nginx}" == "apache" ]] && adm="pgAdmin (/pgadmin4)"
	echo "PostgreSQL: postgres/${POSTGRES_PASSWORD:-<setup.conf>} · админка: ${adm}"
}
