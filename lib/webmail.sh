#!/bin/bash
# =============================================================================
# lib/webmail.sh — Этап (опц.): RoundCube webmail + статистика сайтов.
# RoundCube ставится из пакетов (БД в MariaDB через dbconfig), доступ — симлинк
# в корень сайта. Статистика (AWStats/Webalizer/GoAccess) — пакеты, которые
# ISPConfig использует для пер-сайтовой статистики.
# =============================================================================

# Надёжное создание БД RoundCube в обход dbconfig-common: на Debian 13 dbconfig
# пишет состояние «installed», но саму БД НЕ создаёт. Берём имя/пользователя/пароль
# из /etc/dbconfig-common/roundcube.conf (их уже знает конфиг RoundCube) и грузим
# штатную схему — так пароль совпадает с тем, что прописан в debian-db.php.
_roundcube_create_db_manual() {
	local conf=/etc/dbconfig-common/roundcube.conf
	[[ -f "$conf" ]] || return 1
	local dbn dbu dbp schema
	dbn="$(grep -oP "dbc_dbname='\K[^']*" "$conf")"; dbn="${dbn:-roundcube}"
	dbu="$(grep -oP "dbc_dbuser='\K[^']*" "$conf")"; dbu="${dbu:-roundcube}"
	dbp="$(grep -oP "dbc_dbpass='\K[^']*" "$conf")"
	[[ -n "$dbp" ]] || dbp="$(gen_password 20)"
	schema=/usr/share/dbconfig-common/data/roundcube/install/mysql
	[[ -f "$schema" ]] || schema=/usr/share/roundcube/SQL/mysql.initial.sql
	ui_step "Создание БД RoundCube вручную (обход dbconfig)"
	mysql --defaults-file=/root/.my.cnf <<SQL || return 1
CREATE DATABASE IF NOT EXISTS \`${dbn}\` CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '${dbu}'@'localhost' IDENTIFIED BY '${dbp}';
GRANT ALL PRIVILEGES ON \`${dbn}\`.* TO '${dbu}'@'localhost';
FLUSH PRIVILEGES;
SQL
	[[ -f "$schema" ]] && mysql --defaults-file=/root/.my.cnf "$dbn" < "$schema"
	# на случай, если пароль был пуст и мы сгенерировали новый — синхронизируем конфиг
	sed -i "s/^dbc_dbpass=.*/dbc_dbpass='${dbp}'/" "$conf" 2>/dev/null || true
	mysql -NBe "USE ${dbn}" >/dev/null 2>&1
}

# Roundcube в nginx (vhost домена; сниппеты в snippets/default-locations/, их подключает hostcert.sh).
#  • С сайта разработчиков: /var/www/html/roundcube → /opt/roundcube/public_html, то есть наружу
#    видна только public_html (конфиги, журналы, SQL лежат вне веб-корня). Свой location нужен
#    ради 1.7: там картинки и стили идут через static.php/<путь> (PATH_INFO), а общий
#    «location ~ \.php$» такие адреса не пропускает. Работает и для 1.6.
#  • Пакет Debian раздаётся целым каталогом /var/lib/roundcube — закрываем служебные папки:
#    раньше наружу отдавались logs/errors.log (неудачные входы с адресами и IP), SQL-схема и
#    PHP-файлы program/include. program/ целиком закрывать нельзя: там program/js страницы входа.
# В старых vhost include ещё нет — добавляем перед location \.php$ (nginx -t + откат).
RC_NGINX_DENY=/etc/nginx/snippets/default-locations/roundcube-deny.conf
RC_NGINX_LOC=/etc/nginx/snippets/default-locations/roundcube.conf
_webmail_nginx_deny() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	command -v nginx >/dev/null 2>&1 || return 0
	[[ -e /var/www/html/roundcube || -d /var/lib/roundcube ]] || return 0
	local tmp vh=/etc/nginx/conf.d/10-host-fqdn.conf bak="" changed=0 want drop sock
	mkdir -p "${RC_NGINX_DENY%/*}"
	tmp="$(mktemp)" || return 0
	if [[ "$(readlink -f /var/www/html/roundcube)" == "${RC_DIR}"/* ]]; then
		want="$RC_NGINX_LOC"; drop="$RC_NGINX_DENY"
		sock="$(grep -m1 -oE 'unix:[^;]+' /etc/nginx/snippets/php-default.conf 2>/dev/null)"
		[[ -n "$sock" ]] || sock="unix:/run/php/php$(_rcu_php_ver)-fpm.sock"
		cat >"$tmp" <<NGX
# luckystack: Roundcube с сайта разработчиков — веб-корень ${RC_DIR}/public_html
location = /roundcube { return 301 /roundcube/; }
location ^~ /roundcube/ {
    alias ${RC_DIR}/public_html/;
    index index.php;
    location ~ /\. { deny all; }
    # только PHP-файлы самого public_html (index.php, static.php), с PATH_INFO
    location ~ ^/roundcube/(?<rc_script>[^/]+\.php)(?<rc_pinfo>/.*)?\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME ${RC_DIR}/public_html/\$rc_script;
        fastcgi_param SCRIPT_NAME /roundcube/\$rc_script;
        fastcgi_param PATH_INFO \$rc_pinfo;
        fastcgi_param HTTPS \$https if_not_empty;
        fastcgi_pass ${sock};
        fastcgi_read_timeout 300;
    }
    # статика: в 1.6 public_html/skins, plugins, program/js — симлинки на каталоги с кодом,
    # поэтому отдаём только файлы ресурсов по расширению, а остальное в подкаталогах закрыто
    # (иначе nginx отдал бы исходник plugins/*/config/config.inc.php с паролем API)
    location ~ ^/roundcube/(skins|plugins|program/js|program/resources)/.+\.(js|css|less|map|png|gif|jpe?g|svg|ico|webp|avif|woff2?|ttf|eot|otf|html?|mp3|wav)\$ {
        access_log off;
        expires 30d;
    }
    location ~ ^/roundcube/.+/ { deny all; }
}
NGX
	else
		want="$RC_NGINX_DENY"; drop="$RC_NGINX_LOC"
		cat >"$tmp" <<'NGX'
# luckystack: служебные каталоги и файлы Roundcube недоступны снаружи
location ~ ^/roundcube/(bin|SQL|config|temp|logs|installer|vendor)(/|$) { deny all; }
location ~ ^/roundcube/program/(include|lib|localization|steps|actions)/ { deny all; }
location ~ ^/roundcube/plugins/[^/]+/(config|SQL|bin)/ { deny all; }
location ~ ^/roundcube/(README|INSTALL|LICENSE|CHANGELOG|UPGRADING|SECURITY|composer\.) { deny all; }
NGX
	fi
	local prev_want="" prev_drop=""
	[[ -f "$want" ]] && { prev_want="$(mktemp)"; cp -a "$want" "$prev_want"; }
	[[ -f "$drop" ]] && { prev_drop="$(mktemp)"; cp -a "$drop" "$prev_drop"; rm -f "$drop"; changed=1; }
	if ! cmp -s "$tmp" "$want"; then
		install -m 644 "$tmp" "$want"; changed=1
	fi
	rm -f "$tmp"
	if [[ -f "$vh" ]] && ! grep -q 'snippets/default-locations/\*\.conf' "$vh" \
	   && grep -qE '^[[:space:]]*location ~ \\\.php\$' "$vh"; then
		bak="$(mktemp)"; cp -a "$vh" "$bak"
		# только перед первым location \.php$ в 443-блоке (в 80-м его нет)
		awk '!done && /^[[:space:]]*location ~ \\\.php\$/ {
				print "    include /etc/nginx/snippets/default-locations/*.conf;"; done = 1 }
			{ print }' "$bak" >"$vh"
		changed=1
	fi
	if ((changed)); then
		if nginx -t >>"$SETUP_LOG" 2>&1; then
			systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
			if [[ "$want" == "$RC_NGINX_LOC" ]]; then
				ui_success "Roundcube в nginx: наружу только ${RC_DIR}/public_html (конфиги и журналы вне веб-корня)."
			else
				ui_success "Roundcube: служебные каталоги (logs, SQL, config, program/include…) закрыты снаружи."
			fi
		else
			[[ -n "$bak" ]] && cp -a "$bak" "$vh"
			if [[ -n "$prev_want" ]]; then cp -a "$prev_want" "$want"; else rm -f "$want"; fi
			[[ -n "$prev_drop" ]] && cp -a "$prev_drop" "$drop"
			nginx -t >>"$SETUP_LOG" 2>&1 && systemctl reload nginx >>"$SETUP_LOG" 2>&1
			ui_warn "nginx -t не прошёл с правилами Roundcube — откат, см. ${SETUP_LOG}."
		fi
	fi
	rm -f "$bak" "$prev_want" "$prev_drop" 2>/dev/null
	return 0
}

stage_webmail() {
	ui_info "RoundCube webmail + статистика (AWStats/Webalizer/GoAccess)"

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		if [[ "${RC_SOURCE:-upstream}" == "debian" ]]; then
			ui_info "${UI_D}[dry-run]${UI_NC} apt install roundcube roundcube-mysql (dbconfig в MariaDB)"
			ui_info "${UI_D}[dry-run]${UI_NC} симлинк /var/www/html/roundcube → /var/lib/roundcube"
		else
			ui_info "${UI_D}[dry-run]${UI_NC} Roundcube ${RC_BRANCH:-1.6}.x с сайта разработчиков (подпись GPG) → ${RC_DIR}"
			ui_info "${UI_D}[dry-run]${UI_NC} симлинк /var/www/html/roundcube → ${RC_DIR}"
		fi
		ui_info "${UI_D}[dry-run]${UI_NC} apt install awstats webalizer goaccess (для ISPConfig-статистики)"
		ui_success "Webmail + статистика (имитация) установлены."
		return 0
	fi

	if [[ "${RC_SOURCE:-upstream}" == "debian" ]]; then
		_webmail_install_debian
	elif dpkg -l roundcube-core 2>/dev/null | grep -q '^ii' && [[ ! -f "$RC_DIR/program/include/iniset.php" ]]; then
		_rcu_migrate_debian
	else
		_rcu_install_or_update
	fi

	_webmail_stats
	ui_success "Webmail и статистика установлены."
	log "webmail: roundcube (${RC_SOURCE:-upstream}) + awstats/webalizer/goaccess"
	return 0
}

# Roundcube из пакетов Debian (RC_SOURCE=debian) — прежняя схема.
_webmail_install_debian() {
	# БД RoundCube создаём через dbconfig в MariaDB; веб-сервер не трогаем
	# (доступ дадим симлинком — подходит и для nginx, и для apache).
	export DEBIAN_FRONTEND=noninteractive
	local rc_pw; rc_pw="$(config_get_or_gen_password ROUNDCUBE_DB_PW 20)"
	echo "roundcube-core roundcube/dbconfig-install boolean true"          | debconf-set-selections
	echo "roundcube-core roundcube/database-type select mysql"             | debconf-set-selections
	echo "roundcube-core roundcube/mysql/app-pass password ${rc_pw}"       | debconf-set-selections
	echo "roundcube-core roundcube/app-password-confirm password ${rc_pw}" | debconf-set-selections
	echo "roundcube-core roundcube/reconfigure-webserver multiselect "     | debconf-set-selections
	# Админ-доступ для создания БД: без этого dbconfig идёт в MariaDB как
	# root БЕЗ пароля (debian.cnf не работает в MariaDB 11) → ERROR 1045.
	echo "roundcube-core roundcube/mysql/admin-user string root"           | debconf-set-selections
	echo "roundcube-core roundcube/mysql/admin-pass password ${MARIADB_ROOT_PW:-}" | debconf-set-selections

	ui_step "Установка RoundCube"
	# --no-install-recommends чтобы не тянуть apache2 при nginx-стеке
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		# shellcheck disable=SC2086
		ui_spin "apt install roundcube" apt-get install -y -qq --no-install-recommends \
			roundcube roundcube-core roundcube-mysql roundcube-plugins || \
			ui_warn "RoundCube установился частично — проверьте $SETUP_LOG."
	fi

	# Самолечение (Apache): postinst пакета javascript-common делает a2enconf и ПАДАЕТ,
	# если его файл /etc/apache2/conf-available/javascript-common.conf не выложился (баг
	# выкладки dpkg) → libjs-*/roundcube-core застревают half-configured (iU/iF), вебмейл
	# отдаёт 500. На nginx этого нет (postinst трогает apache только если он установлен).
	if [[ "${DRY_RUN:-0}" != "1" ]] && ! dpkg -l roundcube-core 2>/dev/null | grep -q '^ii'; then
		if [[ "${WEBSERVER:-nginx}" == "apache" && ! -f /etc/apache2/conf-available/javascript-common.conf ]]; then
			ui_warn "javascript-common.conf отсутствует (сбой выкладки) — восстанавливаю, иначе RoundCube не настроится."
			cat >/etc/apache2/conf-available/javascript-common.conf <<'JSC'
Alias /javascript /usr/share/javascript/
<Directory "/usr/share/javascript/">
    AllowOverride None
    Require all granted
</Directory>
JSC
			a2enconf javascript-common >>"$SETUP_LOG" 2>&1 || true
		fi
		DEBIAN_FRONTEND=noninteractive dpkg --configure -a >>"$SETUP_LOG" 2>&1 || true
		dpkg -l roundcube-core 2>/dev/null | grep -q '^ii' \
			&& ui_success "RoundCube доконфигурирован (цепочка javascript-common починена)." \
			|| ui_warn "RoundCube всё ещё не сконфигурирован — см. $SETUP_LOG."
	fi

	# Контроль: БД создана? Если dbconfig провалился (или RoundCube стоял с
	# прошлой неудачной попытки) — повторяем конфигурацию с засеянным debconf.
	if ! mysql -NBe "USE roundcube" >/dev/null 2>&1; then
		ui_warn "БД roundcube не создана — повторная конфигурация (dpkg-reconfigure)."
		dpkg-reconfigure -fnoninteractive roundcube-core >>"$SETUP_LOG" 2>&1 || true
	fi
	# dbconfig на Debian 13 нередко рапортует успех, но БД не создаёт — финальный
	# надёжный фолбэк: создаём БД/пользователя/схему вручную.
	if ! mysql -NBe "USE roundcube" >/dev/null 2>&1; then
		_roundcube_create_db_manual && \
			ui_success "БД roundcube создана вручную (обход dbconfig)." || \
			ui_warn "БД roundcube так и не создана — см. $SETUP_LOG (RoundCube не будет работать)."
	else
		ui_success "БД roundcube готова."
	fi

	# Доступ через текущий веб-сервер
	if [[ -d /var/lib/roundcube ]]; then
		mkdir -p /var/www/html
		ln -sfn /var/lib/roundcube /var/www/html/roundcube
		_webmail_nginx_deny
		_rcu_fix_smtp
		ui_success "RoundCube доступен → http://<server>/roundcube"
	else
		ui_warn "Каталог /var/lib/roundcube не найден — проверьте установку RoundCube."
	fi
	return 0
}

# --- Статистика сайтов (используется ISPConfig) ---
_webmail_stats() {
	ui_step "Установка пакетов статистики (AWStats, Webalizer, GoAccess)"
	# Webalizer из Debian 13 убран: там ставим без него, ISPConfig обойдётся AWStats/GoAccess
	local pk=(awstats goaccess)
	if apt_available webalizer; then pk+=(webalizer)
	else ui_info "Webalizer в этой системе нет (из Debian 13 его убрали), статистика сайтов через AWStats и GoAccess."; fi
	apt_install "${pk[@]}" || \
		ui_warn "Часть пакетов статистики не установилась."

	# Отключаем дефолтный cron awstats: статистику генерит САМ ISPConfig (per-site),
	# а пакетный /etc/cron.d/awstats гоняет /usr/share/awstats/tools/update.sh по всем
	# конфигам и сыпет ошибками/лишней нагрузкой. Идемпотентно (комментируем активные строки).
	if [[ -f /etc/cron.d/awstats ]] && grep -qE '^[^#]' /etc/cron.d/awstats 2>/dev/null; then
		cp -a /etc/cron.d/awstats /etc/cron.d/awstats.luckystack.bak 2>/dev/null || true
		sed -i -E 's/^([^#].*)$/#\1/' /etc/cron.d/awstats 2>/dev/null || true
		ui_info "Дефолтный cron awstats отключён (статистику ведёт ISPConfig)."
	fi
	return 0
}

stage_webmail_summary() {
	local v; v="$(_rcu_version "$RC_DIR")"
	if [[ -n "$v" ]]; then echo "Webmail: Roundcube ${v} с сайта разработчиков (/roundcube) + статистика"
	else echo "Webmail: RoundCube (/roundcube) + статистика"; fi
}

# =============================================================================
# Roundcube с сайта разработчиков (RC_SOURCE=upstream, по умолчанию)
#   Ставится в RC_DIR (/opt/roundcube), раздаётся тем же симлинком /var/www/html/roundcube.
#   Архив «complete» с GitHub-релизов, подпись .asc проверяется ключом из
#   assets/roundcube/signing-key.asc с закреплённым отпечатком (ключ сверен по roundcube.net,
#   keyserver.ubuntu.com и debian/upstream/signing-key.asc пакета Debian).
#   Обновление: копия каталога → штатный bin/installto.sh -y (файлы + схема БД) → подмена
#   каталога; если страница входа не открылась — возврат прежнего каталога.
#   Журналы в /var/log/roundcube (вне веб-каталога; их читает jail fail2ban roundcube-auth).
# =============================================================================
RC_DIR=/opt/roundcube
RC_LOG_DIR=/var/log/roundcube
RC_KEY_FPR=F3E4C04BB3DB5D4215C45F7F5AB2BAA141C4F7D5
RC_FALLBACK_1_6=1.6.20   # если GitHub API недоступен (на 2026-11-05)
RC_FALLBACK_1_7=1.7.5
RC_BACKUP_DIR=/var/backups/roundcube

_rcu_version() {  # $1 — каталог Roundcube → версия или пусто
	grep -oE "RCMAIL_VERSION'?,[[:space:]]*'[0-9]+\.[0-9]+\.[0-9]+" "$1/program/include/iniset.php" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$'
}

# Последняя версия ветки RC_BRANCH (1.6 / 1.7) по релизам GitHub; без сети — пин из шапки.
_rcu_latest() {
	local br="${RC_BRANCH:-1.6}" v=""
	v="$(curl -fsSL --connect-timeout 10 --max-time 30 \
		"https://api.github.com/repos/roundcube/roundcubemail/releases?per_page=40" 2>/dev/null \
		| php -r '$b=$argv[1]; $r=json_decode(stream_get_contents(STDIN), true);
			foreach ((array)$r as $x) { if (empty($x["prerelease"]) && empty($x["draft"])
				&& preg_match("/^".preg_quote($b)."\\.[0-9]+$/", $x["tag_name"] ?? "")) { echo $x["tag_name"]; break; } }' "$br" 2>/dev/null)"
	if [[ -z "$v" ]]; then
		case "$br" in 1.7) v="$RC_FALLBACK_1_7" ;; *) v="$RC_FALLBACK_1_6" ;; esac
		log "roundcube: GitHub API недоступен, беру пин ${v}"
	fi
	echo "$v"
}

# Скачать и проверить подпись. $1 — версия, $2 — каталог распаковки. → путь к распакованному
_rcu_fetch() {
	local ver="$1" work="$2" base url key fpr
	base="roundcubemail-${ver}-complete.tar.gz"
	url="https://github.com/roundcube/roundcubemail/releases/download/${ver}/${base}"
	key="${ASSETS_DIR:-$SCRIPT_DIR/assets}/roundcube/signing-key.asc"
	[[ -f "$key" ]] || { ui_warn "Нет ключа подписи ${key} — Roundcube не ставлю."; return 1; }
	command -v gpgv >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1 || apt_install gpgv gnupg >/dev/null
	fpr="$(gpg --show-keys --with-colons "$key" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
	[[ "$fpr" == "$RC_KEY_FPR" ]] || { ui_warn "Ключ подписи Roundcube не тот (${fpr:-?}) — не ставлю."; return 1; }
	gpg --dearmor <"$key" >"$work/rc.gpg" 2>/dev/null || return 1
	if ! curl -fsSL --retry 4 --retry-delay 5 --retry-all-errors --connect-timeout 15 --max-time 300 "$url" -o "$work/$base" 2>>"$SETUP_LOG" \
	   || ! curl -fsSL --retry 4 --retry-delay 5 --retry-all-errors --connect-timeout 15 --max-time 60 "${url}.asc" -o "$work/${base}.asc" 2>>"$SETUP_LOG"; then
		ui_warn "Не удалось скачать Roundcube ${ver} с GitHub."; return 1
	fi
	if ! gpgv --keyring "$work/rc.gpg" "$work/${base}.asc" "$work/$base" >>"$SETUP_LOG" 2>&1; then
		ui_warn "Подпись архива Roundcube ${ver} НЕ прошла проверку — не ставлю."; return 1
	fi
	tar xzf "$work/$base" -C "$work" --no-same-owner --no-same-permissions 2>>"$SETUP_LOG" || return 1
	[[ -f "$work/roundcubemail-${ver}/program/include/iniset.php" ]] || return 1
	echo "$work/roundcubemail-${ver}"
}

# Версия PHP, которой исполняется /roundcube (сниппет php-default.conf), и её расширения.
_rcu_php_ver() {
	local v
	v="$(grep -oE 'php[0-9]+\.[0-9]+-fpm\.sock' /etc/nginx/snippets/php-default.conf 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+')"
	[[ -n "$v" ]] || v="${PHP_DEFAULT:-$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)}"
	echo "$v"
}
_rcu_deps() {
	local v; v="$(_rcu_php_ver)"
	local pk=(rsync) e
	if [[ -n "$v" ]]; then
		for e in intl mbstring xml mysql zip gd curl; do pk+=("php${v}-${e}"); done
	fi
	apt_install "${pk[@]}"
	# расширения могли прийти зависимостями пакета Debian — после его удаления autoremove их бы снёс
	# shellcheck disable=SC2046
	apt-mark manual $(dpkg -l "${pk[@]}" 2>/dev/null | awk '/^ii/{print $2}') >/dev/null 2>&1 || true
}

# Права: код root (веб-процесс не может его менять), temp — www-data, конфиги с паролями 640.
_rcu_perms() {
	local d="$1"
	chown -R root:root "$d"
	find "$d" -type d -exec chmod 755 {} + ; find "$d" -type f -exec chmod 644 {} +
	chmod 755 "$d"/bin/*.sh 2>/dev/null || true
	rm -rf "${d:?}/installer" "${d:?}/public_html/installer.php"; rm -f "$d"/public_html/.htaccess.new "$d"/.htaccess.new
	mkdir -p "$d/temp" "$d/logs" "$RC_LOG_DIR"
	chown www-data:www-data "$d/temp" "$d/logs"; chmod 750 "$d/temp" "$d/logs"
	chown www-data:adm "$RC_LOG_DIR"; chmod 750 "$RC_LOG_DIR"
	local f
	for f in "$d/config/config.inc.php" "$d"/plugins/*/config.inc.php "$d"/plugins/*/config/config.inc.php; do
		[[ -f "$f" ]] && { chown root:www-data "$f"; chmod 640 "$f"; }
	done
	return 0
}

_rcu_mysql() { "$(command -v mariadb || echo mysql)" --defaults-file=/root/.my.cnf "$@"; }
_rcu_dump()  { "$(command -v mariadb-dump || echo mysqldump)" --defaults-file=/root/.my.cnf --single-transaction "$@"; }

# Страница входа открывается? Через vhost домена (как пользователи), иначе через localhost.
_rcu_check_page() {
	local fqdn="${SERVER_FQDN:-$(hostname -f 2>/dev/null)}" body=""
	body="$(curl -sk --max-time 20 --resolve "${fqdn}:443:127.0.0.1" "https://${fqdn}/roundcube/" 2>/dev/null)"
	[[ "$body" == *rcmloginuser* ]] && return 0
	body="$(curl -s --max-time 20 "http://127.0.0.1/roundcube/" 2>/dev/null)"
	[[ "$body" == *rcmloginuser* ]]
}

_rcu_reload_php() {
	local v; v="$(_rcu_php_ver)"
	[[ -n "$v" ]] && systemctl reload "php${v}-fpm" >>"$SETUP_LOG" 2>&1
	return 0
}

# Свежая установка (или обновление, если уже стоит с сайта разработчиков)
_rcu_install_or_update() {
	if [[ -f "$RC_DIR/program/include/iniset.php" ]]; then
		_rcu_update
		_rcu_link
		return 0
	fi
	ui_step "Roundcube ${RC_BRANCH:-1.6}.x с сайта разработчиков"
	_rcu_deps
	local ver work src
	ver="$(_rcu_latest)"
	work="$(mktemp -d)"
	if ! src="$(_rcu_fetch "$ver" "$work")"; then rm -rf "$work"; ui_warn "Roundcube не установлен."; return 0; fi
	rm -rf "${RC_DIR}.new"; cp -a "$src" "${RC_DIR}.new"; rm -rf "$work"

	# БД и пользователь (пароль — ROUNDCUBE_DB_PW из setup.conf)
	local pw; pw="$(config_get_or_gen_password ROUNDCUBE_DB_PW 20)"
	_rcu_mysql <<SQL || { ui_warn "Не удалось создать БД roundcube — см. ${SETUP_LOG}."; return 0; }
CREATE DATABASE IF NOT EXISTS \`roundcube\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'roundcube'@'localhost' IDENTIFIED BY '${pw}';
ALTER USER 'roundcube'@'localhost' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON \`roundcube\`.* TO 'roundcube'@'localhost';
FLUSH PRIVILEGES;
SQL
	if [[ -z "$(_rcu_mysql -NBe "SHOW TABLES LIKE 'users'" roundcube 2>/dev/null)" ]]; then
		_rcu_mysql roundcube <"${RC_DIR}.new/SQL/mysql.initial.sql" 2>>"$SETUP_LOG" \
			|| { ui_warn "Схема БД Roundcube не загрузилась — см. ${SETUP_LOG}."; return 0; }
	fi

	local des fqdn="${SERVER_FQDN:-$(hostname -f 2>/dev/null)}"
	des="$(gen_password 24)"
	cat >"${RC_DIR}.new/config/config.inc.php" <<PHP
<?php
// luckystack: Roundcube с сайта разработчиков. Остальные настройки — config/defaults.inc.php.
\$config = [];
\$config['db_dsnw'] = 'mysql://roundcube:${pw}@localhost/roundcube';
\$config['imap_host'] = 'localhost:143';
\$config['smtp_host'] = 'tls://${fqdn}:587';
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['support_url'] = '';
\$config['product_name'] = 'Roundcube Webmail';
\$config['des_key'] = '${des}';
\$config['plugins'] = ['archive', 'zipdownload', 'managesieve'];
\$config['skin'] = 'elastic';
\$config['enable_spellcheck'] = false;
\$config['log_dir'] = '${RC_LOG_DIR}/';
PHP
	_rcu_perms "${RC_DIR}.new"
	mv "${RC_DIR}.new" "$RC_DIR"
	_rcu_link
	_rcu_reload_php
	if _rcu_check_page; then
		ui_success "Roundcube ${ver} установлен (${RC_DIR}), подпись разработчиков проверена."
	elif _rcu_page_not_served_yet; then
		ui_success "Roundcube ${ver} установлен (${RC_DIR}), подпись разработчиков проверена."
		ui_info "Страницу входа проверю после этапа сертификата хоста: до него сайта по имени сервера ещё нет."
	else
		ui_warn "Roundcube ${ver} установлен, но страница входа не открылась — проверьте ${RC_LOG_DIR}/errors.log."
	fi
}

# На свежей установке открыть страницу пока негде: сайт по имени сервера создаёт этап hostcert
# (он позже), а по IP nginx соединение рвёт (HTTP_IP_POLICY=deny). Оба запроса тогда без ответа (000).
# Если же хоть один ответил кодом, сайт есть и неправильная страница — это настоящая ошибка.
_rcu_page_not_served_yet() {
	local fqdn="${SERVER_FQDN:-$(hostname -f 2>/dev/null)}" c1 c2
	c1="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${fqdn}:443:127.0.0.1" "https://${fqdn}/roundcube/" 2>/dev/null)"
	c2="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1/roundcube/" 2>/dev/null)"
	[[ "${c1:-000}" == 000 && "${c2:-000}" == 000 ]]
}

_rcu_link() {
	mkdir -p /var/www/html
	ln -sfn "$RC_DIR/public_html" /var/www/html/roundcube
	_webmail_nginx_deny
}

# SMTP Roundcube: пакет Debian ставит smtp_host = 'localhost:587' без шифрования, а порт 587
# (submission) требует STARTTLS — отправка писем из вебмейла не работала («Authentication failed»).
# Меняем на tls://<FQDN>:587 (сертификат хоста выписан на FQDN). Если сертификат на FQDN не
# проходит проверку (самоподписанный) — отключаем проверку для этого соединения: оно локальное.
_rcu_fix_smtp() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	local f fqdn="${SERVER_FQDN:-$(hostname -f 2>/dev/null)}" cur
	[[ -n "$fqdn" ]] || return 0
	for f in "$RC_DIR/config/config.inc.php" /etc/roundcube/config.inc.php; do
		[[ -f "$f" ]] || continue
		# конфиг пакета Debian — только если Roundcube работает из пакета
		[[ "$f" == /etc/roundcube/* ]] && { [[ -f "$RC_DIR/config/config.inc.php" ]] 			|| ! dpkg -l roundcube-core 2>/dev/null | grep -q '^ii'; } && continue
		cur="$(php -r '$config=[]; include $argv[1]; echo $config["smtp_host"] ?? "";' "$f" 2>/dev/null)"
		# только адрес без схемы на порт 587 (localhost:587, 127.0.0.1:587, <имя>:587)
		[[ "$cur" =~ ^[A-Za-z0-9.-]+:587$ ]] || continue
		{
			printf '\n// luckystack: отправка через submission (587) только с STARTTLS — было %s\n' "$cur"
			printf "\$config['smtp_host'] = 'tls://%s:587';\n" "$fqdn"
			if ! timeout 15 openssl s_client -starttls smtp -connect "${fqdn}:587" -verify_hostname "$fqdn" \
					-verify_return_error </dev/null >/dev/null 2>&1; then
				printf "\$config['smtp_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];\n"
			fi
		} >>"$f"
		ui_success "Roundcube: SMTP ${cur} → tls://${fqdn}:587 (без STARTTLS отправка писем не работала)."
	done
	return 0
}

# Обновление в пределах ветки (и смена ветки 1.6 → 1.7, если RC_BRANCH поменяли).
_rcu_update() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	[[ -f "$RC_DIR/program/include/iniset.php" ]] || return 0
	local cur ver work src
	cur="$(_rcu_version "$RC_DIR")"; ver="$(_rcu_latest)"
	[[ -n "$cur" && -n "$ver" ]] || return 0
	if ! dpkg --compare-versions "$cur" lt "$ver"; then
		ui_info "Roundcube ${cur} — актуальная версия ветки ${RC_BRANCH:-1.6}."
		return 0
	fi
	ui_step "Обновление Roundcube ${cur} → ${ver}"
	_rcu_deps
	work="$(mktemp -d)"
	if ! src="$(_rcu_fetch "$ver" "$work")"; then rm -rf "$work"; ui_warn "Roundcube не обновлён, остаётся ${cur}."; return 0; fi
	# бэкап БД (схему меняет update.sh), храним 3 последних
	mkdir -p "$RC_BACKUP_DIR"; chmod 700 "$RC_BACKUP_DIR"
	local dump; dump="${RC_BACKUP_DIR}/roundcube-${cur}-$(date +%Y%m%d-%H%M%S).sql.gz"
	if ! _rcu_dump roundcube 2>>"$SETUP_LOG" | gzip >"$dump"; then
		rm -rf "$work"; ui_warn "Не удалось сделать дамп БД roundcube — обновление отменено."; return 0
	fi
	# shellcheck disable=SC2012
	ls -1t "$RC_BACKUP_DIR"/roundcube-*.sql.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
	local schema0 out; schema0="$(_rcu_schema_ver)"
	rm -rf "${RC_DIR}.new"
	cp -a "$RC_DIR" "${RC_DIR}.new"
	# installto.sh завершается успехом, даже если обновление схемы БД упало — смотрим вывод
	out="$(cd "$src" && php bin/installto.sh -y "${RC_DIR}.new" 2>&1)"; local rc=$?
	printf '%s\n' "$out" >>"$SETUP_LOG"
	if ((rc != 0)) || grep -qE '\[FAILED\]|^ERROR' <<<"$out" \
	   || [[ "$(_rcu_version "${RC_DIR}.new")" != "$ver" ]]; then
		rm -rf "${RC_DIR}.new" "$work"
		_rcu_restore_schema "$schema0" "$dump"
		ui_warn "Обновление до ${ver} не прошло ($(grep -m1 -E '\[FAILED\]|^ERROR' <<<"$out" | cut -c1-160)) — Roundcube остаётся ${cur}. Подробности: ${SETUP_LOG}"
		return 0
	fi
	rm -rf "$work"
	_rcu_perms "${RC_DIR}.new"
	rm -rf "${RC_DIR}.prev"
	mv "$RC_DIR" "${RC_DIR}.prev" && mv "${RC_DIR}.new" "$RC_DIR"
	_rcu_reload_php
	if _rcu_check_page; then
		# для отката: какая схема и какой дамп соответствуют прежней версии
		printf '%s\n' "$schema0" >"$RC_BACKUP_DIR/prev.schema"
		printf '%s\n' "$dump" >"$RC_BACKUP_DIR/prev.dump"
		chmod 600 "$RC_BACKUP_DIR/prev.schema" "$RC_BACKUP_DIR/prev.dump"
		ui_success "Roundcube обновлён: ${cur} → ${ver}. Прежний каталог: ${RC_DIR}.prev, дамп БД: ${dump}"
	else
		rm -rf "${RC_DIR}.bad"; mv "$RC_DIR" "${RC_DIR}.bad" && mv "${RC_DIR}.prev" "$RC_DIR"
		_rcu_restore_schema "$schema0" "$dump"
		_rcu_reload_php
		ui_warn "После обновления до ${ver} страница входа не открылась — вернул ${cur} (новый каталог: ${RC_DIR}.bad, журнал: ${RC_LOG_DIR}/errors.log)."
	fi
	return 0
}

# Откат на прежнюю версию (--rollback roundcube). Каталоги меняются местами, поэтому откат можно
# отменить таким же повтором. БД возвращается из дампа только если схема менялась: письма не в БД,
# но контакты и настройки, изменённые после обновления, в этом случае вернутся к дампу.
_rcu_rollback() {
	local prev="${RC_DIR}.prev" cur_v prev_v schema="" dump="" now_schema now_dump
	if [[ ! -f "$prev/program/include/iniset.php" || ! -f "$RC_DIR/program/include/iniset.php" ]]; then
		ui_error "Прежней версии Roundcube нет: откат возможен только после обновления с сайта разработчиков."
		return 1
	fi
	cur_v="$(_rcu_version "$RC_DIR")"; prev_v="$(_rcu_version "$prev")"
	[[ -f "$RC_BACKUP_DIR/prev.schema" ]] && schema="$(cat "$RC_BACKUP_DIR/prev.schema")"
	[[ -f "$RC_BACKUP_DIR/prev.dump" ]] && dump="$(cat "$RC_BACKUP_DIR/prev.dump")"
	now_schema="$(_rcu_schema_ver)"
	if [[ "$schema" != "$now_schema" && ( -z "$schema" || ! -s "$dump" ) ]]; then
		ui_error "Схема БД менялась, а дампа прежней версии нет (${dump:-не записан}). Откат отменён, ничего не тронуто."
		return 1
	fi
	mkdir -p "$RC_BACKUP_DIR"; chmod 700 "$RC_BACKUP_DIR"
	now_dump="${RC_BACKUP_DIR}/roundcube-${cur_v}-$(date +%Y%m%d-%H%M%S).sql.gz"
	if ! _rcu_dump roundcube 2>>"$SETUP_LOG" | gzip >"$now_dump"; then
		ui_error "Не удалось сделать дамп БД roundcube. Откат отменён, ничего не тронуто."
		return 1
	fi
	ui_step "Откат Roundcube ${cur_v} → ${prev_v}"
	rm -rf "${RC_DIR}.bad"
	mv "$RC_DIR" "${RC_DIR}.bad" && mv "$prev" "$RC_DIR"
	_rcu_restore_schema "$schema" "$dump"
	declare -F _webmail_nginx_deny >/dev/null && _webmail_nginx_deny
	systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
	_rcu_reload_php
	if _rcu_check_page; then
		mv "${RC_DIR}.bad" "$prev"
		printf '%s\n' "$now_schema" >"$RC_BACKUP_DIR/prev.schema"
		printf '%s\n' "$now_dump" >"$RC_BACKUP_DIR/prev.dump"
		chmod 600 "$RC_BACKUP_DIR/prev.schema" "$RC_BACKUP_DIR/prev.dump"
		# иначе следующий --update сразу вернул бы ветку, от которой только что откатились
		declare -F config_set >/dev/null && [[ -f "${CONFIG_FILE:-}" ]] && config_set RC_BRANCH "${prev_v%.*}"
		ui_success "Roundcube: откат на ${prev_v} выполнен. Следующее обновление ($(ls_hint --update)) снова предложит новую версию этой ветки."
		return 0
	fi
	mv "$RC_DIR" "$prev" && mv "${RC_DIR}.bad" "$RC_DIR"
	_rcu_restore_schema "$now_schema" "$now_dump"
	declare -F _webmail_nginx_deny >/dev/null && _webmail_nginx_deny
	systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
	_rcu_reload_php
	ui_error "После отката страница входа не открылась, вернул ${cur_v}."
	return 1
}

# Отпечаток схемы БД Roundcube: версия из таблицы system (её ведёт bin/update.sh) + таблицы и
# число колонок. Одной версии мало: упавшее обновление успевает создать таблицу, не меняя версию.
_rcu_schema_ver() {
	_rcu_mysql -NBe "SELECT value FROM system WHERE name='roundcube-version'" roundcube 2>/dev/null
	_rcu_mysql -NBe "SELECT CONCAT(table_name,':',COUNT(*)) FROM information_schema.columns
		WHERE table_schema='roundcube' GROUP BY table_name ORDER BY table_name" 2>/dev/null | tr '\n' ' '
}
# Откат: если схема изменилась — вернуть БД из дампа, сделанного перед обновлением.
# Сначала удаляем все таблицы: дамп пересоздаёт только свои, а новые (uploads из 1.7) остались бы
# и сломали следующую попытку обновления («Table 'uploads' already exists»).
_rcu_restore_schema() {
	local was="$1" dump="$2" t drop=""
	[[ "$(_rcu_schema_ver)" == "$was" ]] && return 0
	for t in $(_rcu_mysql -NBe "SHOW TABLES" roundcube 2>/dev/null); do drop+="DROP TABLE IF EXISTS \`${t}\`;"; done
	if _rcu_mysql roundcube -e "SET FOREIGN_KEY_CHECKS=0; ${drop} SET FOREIGN_KEY_CHECKS=1;" 2>>"$SETUP_LOG" \
	   && gunzip -c "$dump" | _rcu_mysql roundcube 2>>"$SETUP_LOG"; then
		ui_info "Схема БД Roundcube успела измениться — БД возвращена из дампа ${dump}."
	else
		ui_warn "Не удалось вернуть БД Roundcube из ${dump} — восстановите вручную: gunzip -c ${dump} | mariadb roundcube"
	fi
}

# Переезд с пакета Debian: та же БД, тот же des_key (сессии и сохранённые пароли не ломаются),
# те же настройки IMAP/SMTP и плагины. Пакеты Debian удаляются (без удаления БД) только после
# того, как новая установка открыла страницу входа; иначе симлинк возвращается на пакет.
_rcu_migrate_debian() {
	local old ver work src
	old="$(_rcu_version /usr/share/roundcube)"
	ui_step "Перевод Roundcube ${old:-?} (пакет Debian) на версию с сайта разработчиков"
	[[ -f /etc/roundcube/config.inc.php ]] || { ui_warn "Нет /etc/roundcube/config.inc.php — переезд невозможен."; return 0; }
	_rcu_deps
	ver="$(_rcu_latest)"
	work="$(mktemp -d)"
	if ! src="$(_rcu_fetch "$ver" "$work")"; then rm -rf "$work"; ui_warn "Переезд отменён, остаётся пакет Debian."; return 0; fi
	rm -rf "${RC_DIR}.new"; cp -a "$src" "${RC_DIR}.new"; rm -rf "$work"

	# Конфиг: вычисляем итоговый \$config пакета (с подключёнными debian-db*.php) и выгружаем
	# в один файл. Пути Debian (log_dir/temp_dir) заменяем на свои.
	if ! php -r '
		$config = [];
		include "/etc/roundcube/config.inc.php";
		if (empty($config["db_dsnw"]) || empty($config["des_key"])) { fwrite(STDERR, "нет db_dsnw/des_key\n"); exit(1); }
		unset($config["temp_dir"]);
		$config["log_dir"] = $argv[1] . "/";
		echo "<?php\n// luckystack: перенесено из пакета Debian (/etc/roundcube) " . date("Y-m-d") . "\n";
		echo "// luckystack: плагины ISPConfig для Roundcube — уже в общем списке plugins\n";
		echo "\$config = " . var_export($config, true) . ";\n";
	' "$RC_LOG_DIR" >"${RC_DIR}.new/config/config.inc.php" 2>>"$SETUP_LOG"; then
		rm -rf "${RC_DIR}.new"; ui_warn "Не удалось перенести конфиг Debian — переезд отменён."; return 0
	fi

	# Плагины, которых нет в архиве (ispconfig3_* и т.п.), — копией с разыменованием симлинков
	local d p
	for d in /var/lib/roundcube/plugins/*/; do
		p="$(basename "$d")"
		[[ -e "${RC_DIR}.new/plugins/$p" ]] && continue
		cp -RL --no-preserve=ownership "$d" "${RC_DIR}.new/plugins/$p" 2>>"$SETUP_LOG" \
			&& ui_info "Плагин ${p} перенесён."
	done
	for p in $(php -r '$config=[]; include $argv[1]; echo implode(" ", (array)($config["plugins"] ?? []));' "${RC_DIR}.new/config/config.inc.php" 2>/dev/null); do
		[[ -d "${RC_DIR}.new/plugins/$p" ]] || ui_warn "Плагин ${p} включён в конфиге, но его нет — Roundcube его пропустит."
	done
	_rcu_perms "${RC_DIR}.new"

	# Схема БД: с версии пакета до новой (обычно в пределах 1.6 изменений нет)
	local dump
	mkdir -p "$RC_BACKUP_DIR"; chmod 700 "$RC_BACKUP_DIR"
	dump="${RC_BACKUP_DIR}/roundcube-debian-${old:-old}-$(date +%Y%m%d-%H%M%S).sql.gz"
	if ! _rcu_dump roundcube 2>>"$SETUP_LOG" | gzip >"$dump"; then
		rm -rf "${RC_DIR}.new"; ui_warn "Не удалось сделать дамп БД roundcube — переезд отменён."; return 0
	fi
	local schema0 out rc; schema0="$(_rcu_schema_ver)"
	out="$(cd "${RC_DIR}.new" && php bin/update.sh --version="${old:-1.6.0}" -y 2>&1)"; rc=$?
	printf '%s\n' "$out" >>"$SETUP_LOG"
	if ((rc != 0)) || grep -qE '\[FAILED\]|^ERROR' <<<"$out"; then
		rm -rf "${RC_DIR}.new"
		_rcu_restore_schema "$schema0" "$dump"
		ui_warn "Обновление схемы БД не прошло ($(grep -m1 -E '\[FAILED\]|^ERROR' <<<"$out" | cut -c1-160)) — переезд отменён, остаётся пакет Debian."
		return 0
	fi

	rm -rf "$RC_DIR"; mv "${RC_DIR}.new" "$RC_DIR"
	_rcu_link
	_rcu_fix_smtp
	_rcu_reload_php
	if ! _rcu_check_page; then
		ln -sfn /var/lib/roundcube /var/www/html/roundcube; _webmail_nginx_deny
		_rcu_reload_php
		ui_warn "Roundcube ${ver} не открыл страницу входа — вернул пакет Debian. Новая установка: ${RC_DIR}, журнал: ${RC_LOG_DIR}/errors.log, дамп БД: ${dump}"
		return 0
	fi

	# Пакеты Debian больше не нужны. remove (не purge): /etc/roundcube остаётся как образец,
	# dbconfig не трогает БД (ответ «не удалять БД» задан заранее).
	echo "roundcube-core roundcube/dbconfig-remove boolean false" | debconf-set-selections
	echo "roundcube-core roundcube/purge boolean false" | debconf-set-selections
	DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq roundcube roundcube-core roundcube-mysql roundcube-plugins >>"$SETUP_LOG" 2>&1 \
		|| ui_warn "Пакеты Roundcube Debian удалить не удалось — они не используются, можно удалить вручную."
	_rcu_mysql -NBe "USE roundcube" >/dev/null 2>&1 || ui_warn "БД roundcube недоступна после удаления пакетов — проверьте! Дамп: ${dump}"
	config_set RC_SOURCE upstream
	config_set RC_BRANCH "${RC_BRANCH:-1.6}"
	ui_success "Roundcube переведён: ${old:-?} (Debian) → ${ver} (${RC_DIR}). Настройки, плагины и сессии сохранены, дамп БД: ${dump}"
}

# --update: обновить Roundcube с сайта разработчиков; на пакете Debian — предложить переезд.
_rcu_update_mode() {
	if [[ -f "$RC_DIR/program/include/iniset.php" ]]; then
		_rcu_update; return 0
	fi
	dpkg -l roundcube-core 2>/dev/null | grep -q '^ii' || return 0
	[[ "${RC_SOURCE:-}" == "debian" ]] && return 0
	if [[ "${RC_SOURCE:-}" != "upstream" ]]; then
		if [[ ! -t 0 ]]; then
			ui_info "Roundcube из пакета Debian. Перевести на версию разработчиков: RC_SOURCE=upstream в setup.conf и $(ls_hint --update)."
			return 0
		fi
		ui_info "Roundcube стоит из пакета Debian: исправления безопасности там приходят с задержкой."
		if ! ui_confirm "Перевести Roundcube на версию с сайта разработчиков (ветка ${RC_BRANCH:-1.6}, с сохранением настроек и писем)?" y; then
			config_set RC_SOURCE debian; return 0
		fi
	fi
	_rcu_migrate_debian
}
