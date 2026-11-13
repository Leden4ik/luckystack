#!/bin/bash
# =============================================================================
# lib/php.sh — Native мульти-PHP-FPM (без обёрток).
# Sury repo (packages.sury.org) + установка выбранных версий PHP-FPM с
# nginx-совместимыми модулями + версия по умолчанию + nginx-сниппеты.
# =============================================================================

# Модули (только nginx/FPM, без Apache-специфичных)
PHP_MODULES_CORE="cli fpm gd mysql imap curl intl pspell sqlite3 tidy xsl zip mbstring soap opcache common readline xml bcmath bz2"
PHP_MODULES_EXTRA="imagick redis memcached apcu"
PHP_MODULES_LEGACY="xmlrpc json"   # только PHP < 8.0

# --- Репозиторий PHP-версий Ondřej Surý --------------------------------------
# Debian → packages.sury.org/php (deb.sury.org). Ubuntu → PPA ppa:ondrej/php
# на Launchpad (это РАЗНЫЕ репозитории; deb.sury.org только для Debian).
_php_install_sury() {
	ui_step "Подключение репозитория PHP (Ondřej Surý)"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		if [[ "${OS_ID:-debian}" == "ubuntu" ]]; then
			ui_info "${UI_D}[dry-run]${UI_NC} add-apt-repository ppa:ondrej/php (Ubuntu)"
		else
			ui_info "${UI_D}[dry-run]${UI_NC} ключ sury + deb packages.sury.org/php (Debian)"
		fi
		return 0
	fi
	apt_install lsb-release ca-certificates apt-transport-https gnupg2 curl wget

	# --- Ubuntu: PPA Ondřej Surý ---
	if [[ "${OS_ID:-debian}" == "ubuntu" ]]; then
		# add-apt-repository живёт в software-properties-common (на Ubuntu доступен).
		apt_install software-properties-common
		if grep -rqs "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
			ui_info "PPA ppa:ondrej/php уже подключён."
		elif ! ui_spin "Добавление PPA ppa:ondrej/php" \
			env DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:ondrej/php; then
			ui_error "Не удалось добавить ppa:ondrej/php (Ubuntu)."
			return 1
		fi
		apt_update
		return 0
	fi

	# --- Debian: packages.sury.org ---
	# Ключ качаем во временный файл и ставим только проверенный: сорвавшаяся загрузка раньше
	# оставляла пустой php.gpg, повторный запуск его уже не трогал, и apt ругался на подпись.
	local key=/etc/apt/trusted.gpg.d/php.gpg
	if ! _php_sury_key_ok "$key"; then
		local tmp; tmp="$(mktemp)" || return 1
		if ui_spin "Загрузка GPG-ключа Sury" curl -fsSL --retry 3 --retry-delay 5 --max-time 60 \
				-o "$tmp" https://packages.sury.org/php/apt.gpg && _php_sury_key_ok "$tmp"; then
			install -m 644 -o root -g root "$tmp" "$key"
			rm -f "$tmp"
		else
			rm -f "$tmp"
			ui_error "Не удалось скачать ключ репозитория PHP (https://packages.sury.org/php/apt.gpg). Проверьте сеть и повторите этап."
			return 1
		fi
	fi
	# Codename БЕЗ lsb_release: пустое значение давало «deb …/php/  main»
	# (Malformed entry) и ломало весь apt. Не пишем репозиторий, если не определили.
	local codename; codename="$(os_codename)"
	if [[ -z "$codename" ]]; then
		ui_error "Не удалось определить кодовое имя релиза — Sury-репозиторий не добавлен."
		return 1
	fi
	echo "deb https://packages.sury.org/php/ ${codename} main" \
		>/etc/apt/sources.list.d/php.list
	apt_update
}

# Файл ключа Sury не пустой и читается как ключ OpenPGP.
_php_sury_key_ok() {
	[[ -s "$1" ]] && gpg --batch --show-keys "$1" >/dev/null 2>&1
}

# Установлена ли версия PHP?
_php_installed() { command -v "php$1" >/dev/null 2>&1 || dpkg -l "php$1-fpm" 2>/dev/null | grep -q "^ii"; }

# Есть ли пакет в индексе apt? (например, php8.5-opcache в Sury не существует —
# apt атомарен, и один несуществующий пакет валит ВЕСЬ вызов установки)
# ВАЖНО: НЕ через `... | grep -q`. При set -o pipefail (включён глобально) grep -q
# закрывает пайп на первом совпадении → apt-cache получает SIGPIPE (141) → пайплайн
# возвращает ненулевой код, и СУЩЕСТВУЮЩИЙ пакет ложно считается отсутствующим
# (интермиттентно вылетали целые версии PHP — особенно под нагрузкой). Командная
# подстановка читает весь вывод целиком — без SIGPIPE и без влияния pipefail.
_php_pkg_available() { [[ -n "$(apt-cache show "$1" 2>/dev/null)" ]]; }

# Отфильтровать список пакетов: оставить только существующие в репозитории.
# Отсутствующие перечисляются в ui_info (не warn — это норма для свежих версий).
_php_filter_available() {
	local p avail="" missing=""
	# намеренный word-split списка имён пакетов (пробелов в них нет)
	# shellcheck disable=SC2048,SC2086
	for p in $*; do
		if _php_pkg_available "$p"; then avail+=" $p"; else missing+=" $p"; fi
	done
	[[ -n "$missing" ]] && ui_info "Нет в репозитории (пропуск):${missing}" >&2
	echo "${avail# }"
}

# Список ОБЯЗАТЕЛЬНЫХ пакетов версии (ядро — должно встать целиком)
_php_core_list() {
	local v="$1" m list="php${v}"
	for m in $PHP_MODULES_CORE; do list+=" php${v}-${m}"; done
	echo "$list"
}

# Установка одной версии PHP-FPM.
# Списки пакетов предварительно фильтруются по индексу apt (несуществующий пакет
# валит ВЕСЬ atomic-вызов apt — так php8.5-opcache ронял установку всего 8.5).
# Ядро и extras ставятся ДВУМЯ вызовами apt, не по одному: каждый отдельный вызов
# триггерит restart php-fpm, и 4+ рестарта за 10 секунд упирались в systemd
# start-limit-hit (postinst падал, dpkg оставлял php-fpm недонастроенным).
_php_install_version() {
	local v="$1" vn m
	vn="${v//./}"
	ui_step "Установка PHP ${v} (FPM + модули)"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt install $(_php_core_list "$v" | cut -c1-60)…"
		ui_info "${UI_D}[dry-run]${UI_NC} extras одним вызовом: ${PHP_MODULES_EXTRA}; пул + сниппет"
		return 0
	fi

	# Ядро — единым вызовом (только существующие пакеты)
	local core; core="$(_php_filter_available "$(_php_core_list "$v")")"
	# shellcheck disable=SC2086
	if ! apt_install $core; then
		ui_warn "PHP ${v}: ядро установилось не полностью — см. $SETUP_LOG."
	fi

	# Extra-модули — тоже одним вызовом (отфильтрованы по доступности)
	local extra=""
	for m in $PHP_MODULES_EXTRA; do extra+=" php${v}-${m}"; done
	if ((vn < 80)); then
		for m in $PHP_MODULES_LEGACY; do extra+=" php${v}-${m}"; done
	fi
	extra="$(_php_filter_available "$extra")"
	if [[ -n "$extra" ]]; then
		# shellcheck disable=SC2086
		apt_install $extra || ui_warn "PHP ${v}: часть extra-модулей не установилась."
	fi

	_php_tune_fpm_pool "$v"
	_php_deploy_opcache "$v"
	_php_create_snippet "$v"
	# Сбросить возможный start-limit-hit от рестартов из postinst-триггеров
	systemctl reset-failed "php${v}-fpm" >/dev/null 2>&1 || true
	sys_run "Запуск php${v}-fpm" systemctl restart "php${v}-fpm"
	sys_run "Автозагрузка php${v}-fpm" systemctl enable "php${v}-fpm"
}

# Удалить лишнюю версию PHP, которую притянули зависимости. Так приходит PHP 8.5: пакет phpmyadmin
# рекомендует php-mcrypt, а он из репозитория sury тянет самую новую версию PHP (CLI-пакеты).
# Удаляем версию, только если: её нет в PHP_VERSIONS, для неё нет PHP-FPM (сайтов на ней быть не
# может) и команда php указывает не на неё. Сначала php-mcrypt, потом пакеты версии и autoremove.
_php_drop_stray() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	[[ -n "${PHP_VERSIONS:-}" ]] || return 0
	local d v cli removed=()
	local pkgs extra
	cli="$(readlink -f /usr/bin/php 2>/dev/null)"
	for d in /etc/php/*/; do
		v="$(basename "$d")"
		[[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] || continue
		[[ " ${PHP_VERSIONS} " == *" $v "* ]] && continue
		dpkg -l "php${v}-fpm" 2>/dev/null | grep -q '^ii' && continue
		[[ "$cli" == *"php${v}" ]] && continue
		pkgs="$(dpkg -l "php${v}-*" 2>/dev/null | awk '/^ii/{print $2}' | tr '\n' ' ')"
		[[ -n "$pkgs" ]] || continue
		dpkg -l 'php-mcrypt' 2>/dev/null | grep -q '^ii' && pkgs="php-mcrypt $pkgs"
		# Сначала симуляция: если вместе с версией apt снесёт что-то ещё (phpmyadmin, метапакет
		# php-* с зависимостью от неё) — не трогаем, только предупреждаем.
		# shellcheck disable=SC2086
		extra="$(apt-get -s purge $pkgs 2>/dev/null | awk '/^(Purg|Remv) /{print $2}' \
			| grep -vE "^(php-mcrypt|php${v//./\\.}-.*)$" | tr '\n' ' ')"
		if [[ -n "$extra" ]]; then
			ui_warn "PHP ${v} не входит в PHP_VERSIONS, но удалить её нельзя без: ${extra}— оставляю."
			continue
		fi
		# shellcheck disable=SC2086
		apt-get purge -y -qq $pkgs >>"$SETUP_LOG" 2>&1 && removed+=("$v")
		rm -rf "/etc/php/${v}" 2>/dev/null
	done
	((${#removed[@]})) || return 0
	apt-get autoremove -y -qq >>"$SETUP_LOG" 2>&1 || true
	ui_success "Удалена лишняя версия PHP ${removed[*]} (её притянули зависимости; сайтов и PHP-FPM на ней не было)."
}

# Деплой OPcache+JIT (assets/php/opcache.ini) в conf.d FPM конкретной версии
_php_deploy_opcache() {
	local v="$1" src="${ASSETS_DIR:-$SCRIPT_DIR/assets}/php/opcache.ini"
	[[ -f "$src" ]] || return 0
	local dst="/etc/php/${v}/fpm/conf.d/99-opcache-jit.ini"
	[[ -d "/etc/php/${v}/fpm/conf.d" ]] || return 0
	install -m 644 "$src" "$dst" 2>/dev/null && \
		ui_info "OPcache+JIT профиль установлен: ${dst}" || true
}

# Безопасные значения PHP (assets/php/security.ini) во все версии: FPM и CLI.
# Перезаписывает только свой файл 98-luckystack-security.ini; FPM перечитывается,
# только если файл реально изменился.
_php_security_ini() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	local src="${ASSETS_DIR:-$SCRIPT_DIR/assets}/php/security.ini" d v sapi dst changed n=0
	[[ -f "$src" ]] || return 0
	for d in /etc/php/*/; do
		v="$(basename "$d")"
		[[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] || continue
		changed=0
		for sapi in fpm cli cgi; do
			[[ -d "/etc/php/$v/$sapi/conf.d" ]] || continue
			dst="/etc/php/$v/$sapi/conf.d/98-luckystack-security.ini"
			cmp -s "$src" "$dst" && continue
			install -m 644 "$src" "$dst" && changed=1
		done
		((changed)) || continue
		n=$((n + 1))
		systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && \
			{ systemctl reload "php${v}-fpm" >>"$SETUP_LOG" 2>&1 || systemctl restart "php${v}-fpm" >>"$SETUP_LOG" 2>&1; }
	done
	((n)) && ui_success "Безопасные настройки PHP применены (версий: ${n}): httponly/strict-сессии, без upload_progress, проверка прав OPcache."
	return 0
}

# Базовый тюнинг FPM-пула www
_php_tune_fpm_pool() {
	local v="$1" pool="/etc/php/${v}/fpm/pool.d/www.conf"
	[[ -f "$pool" ]] || return 0
	# Без агрессивных правок: гарантируем unix-сокет и разумные pm-значения.
	sed -i \
		-e "s|^listen = .*|listen = /run/php/php${v}-fpm.sock|" \
		-e "s|^;*pm.max_children = .*|pm.max_children = 20|" \
		-e "s|^;*pm.start_servers = .*|pm.start_servers = 4|" \
		-e "s|^;*pm.min_spare_servers = .*|pm.min_spare_servers = 2|" \
		-e "s|^;*pm.max_spare_servers = .*|pm.max_spare_servers = 8|" \
		"$pool" 2>/dev/null || true
}

# nginx-сниппет для подключения FPM-сокета конкретной версии
_php_create_snippet() {
	local v="$1" dir=/etc/nginx/snippets
	mkdir -p "$dir"
	cat >"$dir/php${v}-fpm.conf" <<SNIP
# PHP ${v} FPM — include внутри location ~ \.php\$
fastcgi_pass unix:/run/php/php${v}-fpm.sock;
fastcgi_index index.php;
include fastcgi_params;
fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
fastcgi_param PATH_INFO \$fastcgi_path_info;
SNIP
}

# Системный php в консоли/cron (update-alternatives). Версия — PHP_CLI_DEFAULT:
#   <версия> → переключаем `php`/phar на неё;  'system' → не трогаем дефолт Debian;
#   (пусто)  → = PHP_DEFAULT (привычное поведение). Веб-версию сайтов это НЕ меняет.
_php_set_cli_default() {
	local cli="${PHP_CLI_DEFAULT:-${PHP_DEFAULT:-}}"
	if [[ "$cli" == "system" ]]; then
		ui_info "Системный php (CLI/cron) оставлен как есть (дефолт Debian)."
		return 0
	fi
	[[ -n "$cli" ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} update-alternatives --set php → /usr/bin/php${cli} (+phar)"
		return 0
	fi
	[[ -x "/usr/bin/php${cli}" ]] || { ui_warn "php${cli} не установлен — системный php (CLI) не меняю."; return 0; }
	ui_step "Системный php (CLI/cron) → PHP ${cli}"
	local b
	for b in php phar phar.phar; do
		[[ -x "/usr/bin/${b}${cli}" ]] || continue
		update-alternatives --install "/usr/bin/${b}" "$b" "/usr/bin/${b}${cli}" 100 >/dev/null 2>&1 || true
		update-alternatives --set "$b" "/usr/bin/${b}${cli}" >/dev/null 2>&1 || true
	done
	ui_success "php (CLI) → $(php -v 2>/dev/null | head -n1)"
}

# Версия по умолчанию: системный CLI (выше) + обработчик .php по умолчанию для
# САЙТОВ/стартовой страницы (nginx-сниппет php-default / Apache). $v = PHP_DEFAULT.
_php_set_default() {
	local v="$1"
	[[ -n "$v" ]] || return 0

	# 1) Системный php в консоли/cron (отдельно настраиваемая версия)
	_php_set_cli_default

	# 2) Обработчик .php по умолчанию (сайты/стартовая страница) → php${v}-fpm
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} php-default сниппет → php${v}-fpm.sock"
		return 0
	fi
	[[ -f "/usr/bin/php${v}" ]] || { ui_warn "php${v} не найден — пропуск обработчика по умолчанию."; return 0; }
	ui_step "Обработчик .php по умолчанию → PHP ${v}-FPM (сайты/стартовая страница)"

	# Заполняем сниппет дефолтного FPM-сокета — его include'ит default-сервер nginx
	# (создаётся в nginx-этапе). Благодаря этому .php в /var/www/html (включая
	# симлинки /phpmyadmin и /roundcube) исполняются через FPM версии по умолчанию.
	if [[ "${WEBSERVER:-nginx}" == "nginx" ]]; then
		mkdir -p /etc/nginx/snippets
		cat >/etc/nginx/snippets/php-default.conf <<SNIP
fastcgi_pass unix:/run/php/php${v}-fpm.sock;
fastcgi_index index.php;
include fastcgi_params;
fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
fastcgi_param PATH_INFO \$fastcgi_path_info;
SNIP
		if command -v nginx >/dev/null 2>&1; then
			nginx -t >>"$SETUP_LOG" 2>&1 && systemctl reload nginx >>"$SETUP_LOG" 2>&1 || \
				ui_warn "nginx reload после настройки php-default не удался — проверьте конфиг."
		fi
	elif [[ "${WEBSERVER:-}" == "apache" ]] && command -v a2enconf >/dev/null 2>&1; then
		# Apache + PHP-FPM (mod_proxy_fcgi) для дефолтной версии: default-сайт Apache
		# обслуживает .php через FPM. mod_php несовместим с FPM/mpm_event — выключаем.
		# ISPConfig дальше создаёт собственные per-site FPM-пулы.
		a2dismod "php${v}" >/dev/null 2>&1 || true
		a2enmod proxy_fcgi setenvif >/dev/null 2>&1 || true
		a2enconf "php${v}-fpm" >/dev/null 2>&1 || true
		if command -v apache2ctl >/dev/null 2>&1 && apache2ctl configtest >>"$SETUP_LOG" 2>&1; then
			systemctl reload apache2 >>"$SETUP_LOG" 2>&1 || true
			ui_info "Apache: дефолтный обработчик .php → php${v}-fpm (mod_proxy_fcgi)."
		else
			ui_warn "apache configtest не прошёл после php-default — проверьте конфиг."
		fi
	fi
}

# --- Точка входа этапа -------------------------------------------------------
stage_php() {
	local versions="${PHP_VERSIONS:-}" default="${PHP_DEFAULT:-}"
	if [[ -z "$versions" ]]; then
		ui_warn "Не выбрано ни одной версии PHP — пропуск."
		return 0
	fi
	ui_info "PHP: ${UI_BOLD}${versions}${UI_NC} (по умолчанию ${default:-—})"

	_php_install_sury || return 1
	local v
	for v in $versions; do
		_php_install_version "$v"
	done

	# Долечить пакеты, которые dpkg оставил недонастроенными (postinst мог упасть
	# на start-limit-hit) — к этому моменту рестарты редкие и configure проходит.
	ui_spin "Проверка целостности dpkg (configure -a)" dpkg --configure -a || \
		ui_warn "dpkg --configure -a завершился с ошибкой — см. $SETUP_LOG."

	# Контроль: все выбранные FPM-службы реально работают
	for v in $versions; do
		if ! systemctl is-active --quiet "php${v}-fpm" 2>/dev/null; then
			systemctl reset-failed "php${v}-fpm" >/dev/null 2>&1 || true
			systemctl restart "php${v}-fpm" >>"$SETUP_LOG" 2>&1 || \
				ui_warn "php${v}-fpm не запустился — проверьте: systemctl status php${v}-fpm"
		fi
	done
	_php_set_default "$default"
	# часовой пояс сервера и для PHP (иначе PHP в UTC, а система и MariaDB — в поясе сервера)
	declare -F _tz_php_ini >/dev/null && _tz_php_ini "${TIMEZONE:-}"
	_php_security_ini

	ui_success "PHP установлен."
	return 0
}

stage_php_summary() { echo "PHP: ${PHP_VERSIONS:-—} (по умолчанию ${PHP_DEFAULT:-—})"; }

# =============================================================================
# Удаление ВЫБРАННЫХ версий PHP (интерактивно). Режим: server-setup.sh --remove-php
# или пункт меню. Полностью чистит: apt purge phpX.Y-*, останов/выключение fpm,
# /etc/php/X.Y, запись в ISPConfig (server_php — выпадашка «PHP Version» у сайтов).
# ЗАЩИТА: нельзя снести версию, на которой работает панель ISPConfig, системный CLI
# по умолчанию (/usr/bin/php), и версии, реально используемые сайтами (fastcgi_php_version).
# =============================================================================
# --add-php [версия]: доустановить версию PHP на работающий сервер (парный к --remove-php).
# Ставит так же, как этап PHP (FPM + модули, пул, OPcache, сниппет), применяет часовой пояс и
# безопасные настройки, добавляет версию в PHP_VERSIONS (чтобы _php_drop_stray её не трогал)
# и регистрирует в ISPConfig — версия появляется в выпадашке «PHP Version» у сайтов.

run_php_add() {
	command -v dpkg >/dev/null 2>&1 || { ui_error "dpkg не найден."; return 1; }
	declare -F ui_header >/dev/null && ui_header "Добавление версии PHP" || ui_step "Добавление версии PHP"
	_php_install_sury || { ui_error "Репозиторий PHP (sury) недоступен."; return 1; }
	apt-get update -qq >>"$SETUP_LOG" 2>&1 || true

	local v cand=() args=() have=""
	for v in 8.5 8.4 8.3 8.2 8.1 8.0 7.4; do
		if dpkg -l "php${v}-fpm" 2>/dev/null | grep -q '^ii'; then have+=" $v"; continue; fi
		_php_pkg_available "php${v}-fpm" || continue
		cand+=("$v")
		args+=("v${v//./_}" "PHP ${v}$([[ "$v" == 7.4 ]] && echo '  (устаревшая, без исправлений безопасности)')")
	done
	ui_info "Уже стоят:${have:- —}"
	((${#cand[@]})) || { ui_warn "Все доступные версии уже установлены."; return 0; }

	local sel=""
	if [[ -n "${PHP_ADD_ARG:-}" ]]; then
		[[ " ${cand[*]} " == *" ${PHP_ADD_ARG} "* ]] || {
			ui_error "PHP ${PHP_ADD_ARG}: уже стоит или нет в репозитории. Можно: ${cand[*]}"; return 1; }
		sel=" v${PHP_ADD_ARG//./_} "
	else
		ui_checklist "Отметьте версии PHP для установки (пробел — отметить, Enter — далее)" "" "${args[@]}"
		sel=" ${UI_CHECK_RESULT//,/ } "
		[[ "$sel" =~ v[0-9] ]] || { ui_info "Ничего не выбрано — отмена."; return 0; }
	fi

	local added=""
	for v in "${cand[@]}"; do
		[[ "$sel" == *" v${v//./_} "* ]] || continue
		_php_install_version "$v"
		added+=" $v"
	done
	ui_spin "Проверка целостности dpkg (configure -a)" dpkg --configure -a || true
	declare -F _tz_php_sync >/dev/null && _tz_php_sync
	_php_security_ini

	# PHP_VERSIONS в setup.conf: добавить новые
	local list="${PHP_VERSIONS:-}"
	for v in $added; do [[ " $list " == *" $v "* ]] || list="${list:+$list }$v"; done
	declare -F config_set >/dev/null && config_set PHP_VERSIONS "$list"
	PHP_VERSIONS="$list"

	if [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] && declare -F _ispconfig_register_php_versions >/dev/null; then
		_ispconfig_register_php_versions
	fi
	systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true

	local ok="" bad=""
	for v in $added; do
		if systemctl is-active --quiet "php${v}-fpm"; then ok+=" $v"; else bad+=" $v"; fi
	done
	[[ -n "$ok" ]] && ui_success "Добавлено:${ok}. Версия выбирается у сайта в ISPConfig: Sites → сайт → PHP Version."
	[[ -n "$bad" ]] && ui_warn "Не запустились:${bad} — проверьте: systemctl status php<версия>-fpm"
	ls /etc/php/*/fpm/conf.d/99-zz-luckystack-tuning.ini >/dev/null 2>&1 && \
		ui_info "Тюнинг памяти под новую версию: $(ls_hint --update tuning)."
	log "php-add:${added}"
	[[ -z "$bad" ]]
}

run_php_remove() {
	command -v dpkg >/dev/null 2>&1 || { ui_error "dpkg не найден."; return 1; }
	clear 2>/dev/null || true
	declare -F ui_header >/dev/null && ui_header "Удаление версий PHP" || ui_step "Удаление версий PHP"

	# установленные версии (по каталогам /etc/php/X.Y/fpm)
	local vers=() v d
	for d in /etc/php/*/fpm; do
		[[ -d "$d" ]] || continue
		v="$(basename "$(dirname "$d")")"
		[[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] && vers+=("$v")
	done
	((${#vers[@]})) || { ui_warn "Установленных версий PHP-FPM не найдено."; return 0; }

	# защищённые версии: панель ISPConfig + системный CLI по умолчанию
	local panel_php cli_php
	panel_php="$(grep -rhoP 'fastcgi_pass unix:/var/lib/php\K[0-9.]+' /etc/nginx/sites-enabled/000-ispconfig.vhost /etc/nginx/sites-available/ispconfig.vhost 2>/dev/null | head -1)"
	cli_php="$(readlink -f /usr/bin/php 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
	[[ -n "$cli_php" ]] || cli_php="$(php -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"

	local haveispc=0
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] && declare -F _ispc_mysql >/dev/null && haveispc=1

	# checklist только из удаляемых; защищённые — как инфо
	local args=() cnt reason
	for v in "${vers[@]}"; do
		reason=""
		[[ "$v" == "$panel_php" ]] && reason="панель"
		[[ "$v" == "$cli_php"   ]] && reason="${reason:+$reason, }CLI по умолчанию"
		cnt=0
		((haveispc)) && cnt="$(_ispc_mysql -N -B -e "SELECT COUNT(*) FROM web_domain WHERE fastcgi_php_version='PHP ${v}';" 2>/dev/null | tr -dc '0-9')"
		[[ "${cnt:-0}" -gt 0 ]] && reason="${reason:+$reason, }используют ${cnt} сайт(ов)"
		if [[ -n "$reason" ]]; then
			ui_info "PHP ${v} — оставляем (${reason})."
		else
			args+=("v${v//./_}" "PHP ${v}  (удалить полностью)")
		fi
	done
	((${#args[@]})) || { ui_warn "Нет версий, которые можно удалить (все защищены/используются)."; return 0; }

	ui_checklist "Отметьте версии PHP для УДАЛЕНИЯ (пробел — отметить, Enter — далее)" "" "${args[@]}"
	local sel=" ${UI_CHECK_RESULT//,/ } "
	[[ "$sel" =~ v[0-9] ]] || { ui_info "Ничего не выбрано — отмена."; return 0; }

	echo ""
	ui_warn "Отмеченные версии будут ПОЛНОСТЬЮ удалены (apt purge phpX.Y-*) и убраны из ISPConfig."
	if declare -F ui_confirm >/dev/null; then ui_confirm "Продолжить удаление?" n || { ui_info "Отменено."; return 0; }; fi

	local removed=""
	for v in "${vers[@]}"; do
		[[ "$sel" == *" v${v//./_} "* ]] || continue
		ui_step "Удаление PHP ${v}"
		systemctl stop "php${v}-fpm"    >>"$SETUP_LOG" 2>&1 || true
		systemctl disable "php${v}-fpm" >>"$SETUP_LOG" 2>&1 || true
		# точный список пакетов версии (не apt-glob, чтобы не задеть лишнее)
		local pkgs
		pkgs="$(dpkg -l "php${v}-*" "php${v}" 2>/dev/null | awk '/^ii/{print $2}' | tr '\n' ' ')"
		if [[ -n "${pkgs// }" ]]; then
			DEBIAN_FRONTEND=noninteractive apt-get purge -y -q $pkgs >>"$SETUP_LOG" 2>&1 || ui_warn "apt purge PHP ${v} завершился с замечаниями."
			DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q >>"$SETUP_LOG" 2>&1 || true
		fi
		rm -rf "/etc/php/${v}" 2>/dev/null || true
		((haveispc)) && _ispc_mysql -e "DELETE FROM server_php WHERE name='PHP ${v}';" >>"$SETUP_LOG" 2>&1 || true
		ui_success "PHP ${v} удалён (пакеты + запись в ISPConfig)."
		log "php-remove: PHP ${v} purged"
		removed="${removed} ${v}"
	done
	systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
	local left; left="$(ls -d /etc/php/*/ 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | tr '\n' ' ')"
	ui_success "Готово. Удалено:${removed:- —}. Осталось: ${left:-—}"
	return 0
}
