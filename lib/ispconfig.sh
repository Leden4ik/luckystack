#!/bin/bash
# =============================================================================
# lib/ispconfig.sh — Этап: установка ISPConfig (с выбором ветки + проверкой).
# Ветка ISPCONFIG_BRANCH:
#   stable      → офиц. tarball ISPConfig-3-stable.tar.gz (production)
#   stable-3.2  → git-ветка стабильной линейки + свежие фиксы
#   develop     → git develop (НЕ для production)
#   <custom>    → произвольная git-ветка/тег
# Перед установкой ДОСТУПНОСТЬ источника проверяется (tarball валиден / git-ветка
# существует). Затем генерируется autoinstall.ini и запускается install.php
# в неинтерактивном режиме (--autoinstall).
# =============================================================================

ISPC_GIT="https://git.ispconfig.org/ispconfig/ispconfig3.git"
ISPC_TARBALL="https://www.ispconfig.org/downloads/ISPConfig-3-stable.tar.gz"
# Nightly = ветка git stable-3.2, собранная в готовый tarball. Качается надёжно
# (без капризного git.ispconfig.org) и СОДЕРЖИТ рабочий autoinstall под PHP 8.3/8.4:
# в старом release-tarball неинтерактивный install.php зацикливается на PHP 8.3+
# (проверено на Debian 13/trixie). Рекомендуется как источник по умолчанию.
ISPC_NIGHTLY_TARBALL="https://www.ispconfig.org/downloads/ISPConfig-3-nightly.tar.gz"
ISPC_SRC="/tmp/ispconfig3_install"

# Архив ISPConfig, который уже лежит на диске, используем только если ему можно доверять: обычный
# файл (не симлинк), владелец root, другие не могут его менять. В /tmp пишет кто угодно, и
# подложенный туда «архив ISPConfig» установщик распаковал бы и запустил от root. Путь, явно
# заданный через ISPC_LOCAL_TARBALL, — решение админа, его принимаем.
_ispc_tar_trusted() {
	local f="$1"
	[[ -n "${ISPC_LOCAL_TARBALL:-}" && "$f" == "$ISPC_LOCAL_TARBALL" ]] && return 0
	[[ -f "$f" && ! -L "$f" && "$(stat -c %u "$f" 2>/dev/null)" == 0 ]] || return 1
	[[ -z "$(find "$f" -maxdepth 0 -perm /022 2>/dev/null)" ]]
}
# Чужой /tmp/ispconfig.tar.gz убрать до скачивания (иначе wget писал бы в чужой файл).
_ispc_tar_drop_untrusted() {
	local f=/tmp/ispconfig.tar.gz
	if [[ -e "$f" || -L "$f" ]] && ! _ispc_tar_trusted "$f"; then
		rm -f "$f"
		ui_warn "Удалён /tmp/ispconfig.tar.gz: файл не принадлежал root или был открыт на запись другим."
	fi
}

# Источник — готовый tarball (stable/nightly) или git-клон (ветка/тег)?
_ispc_is_tarball() { [[ "${ISPCONFIG_BRANCH:-stable}" == "stable" || "${ISPCONFIG_BRANCH:-stable}" == "nightly" ]]; }
# URL tarball для текущего источника
_ispc_tarball_url() { [[ "${ISPCONFIG_BRANCH:-stable}" == "nightly" ]] && echo "$ISPC_NIGHTLY_TARBALL" || echo "$ISPC_TARBALL"; }

# Интерактивный обход блокировки загрузки ISPConfig (Cloudflare-челлендж и т.п.):
# просим человека скачать архив в браузере (он проходит JS-проверку) и положить в
# /tmp/ispconfig.tar.gz, ЖДЁМ здесь и проверяем. Возвращает 0 — валидный архив на
# месте (продолжаем), 1 — пользователь пропустил/прервал или неинтерактивный режим.
_ispconfig_await_local_tarball() {
	local turl="$1" localtar="${ISPC_LOCAL_TARBALL:-/tmp/ispconfig.tar.gz}" ans ip port
	[[ -t 0 || -e /dev/tty ]] || return 1   # есть кому подтвердить?
	ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
	port="${SSH_PORT:-22}"
	echo "" >/dev/tty 2>/dev/null || echo ""
	ui_warn "ISPConfig не качается автоматически (ispconfig.org за Cloudflare-челленджем / 403)."
	ui_info "Скачайте архив ВРУЧНУЮ — браузер проходит проверку Cloudflare, а wget/curl нет:"
	ui_info "  1) откройте в браузере: ${UI_W}${turl}${UI_NC}"
	ui_info "  2) залейте файл на сервер как ${UI_W}${localtar}${UI_NC}, например:"
	ui_info "     ${UI_W}scp -P ${port} ISPConfig-3-stable.tar.gz root@${ip:-<ip>}:${localtar}${UI_NC}"
	ui_info "Установка ПОСТАВЛЕНА НА ПАУЗУ — продолжу, как только архив будет на месте."
	while :; do
		printf '%s' "  Готово? [Enter] — проверить · s — пропустить ISPConfig · a — прервать: " >/dev/tty 2>/dev/null
		IFS= read -r ans </dev/tty 2>/dev/null || { ui_warn "Нет управляющего терминала — ожидание невозможно."; return 1; }
		case "${ans,,}" in
			s) ui_warn "ISPConfig пропущен по запросу (можно добрать позже: $(ls_hint --only ispconfig))."; return 1 ;;
			a) ui_error "Прервано пользователем."; return 1 ;;
			*)
				if [[ -f "$localtar" ]] && _ispc_tar_trusted "$localtar" && tar tzf "$localtar" >/dev/null 2>&1; then
					ui_success "Архив ${localtar} найден и валиден — продолжаю установку ISPConfig."
					return 0
				fi
				if [[ -f "$localtar" ]]; then
					ui_warn "${localtar} есть, но это НЕ валидный tar.gz (возможно, сохранилась HTML-страница Cloudflare). Перекачайте архив."
				else
					ui_warn "${localtar} ещё нет. Залейте файл и нажмите Enter."
				fi
				;;
		esac
	done
}

# --- Проверка доступности выбранной ветки ------------------------------------
_ispconfig_verify_source() {
	local branch="${ISPCONFIG_BRANCH:-stable}"
	ui_step "Проверка доступности источника ISPConfig: ${branch}"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		if _ispc_is_tarball; then
			ui_info "${UI_D}[dry-run]${UI_NC} HEAD $(_ispc_tarball_url)"
		else
			ui_info "${UI_D}[dry-run]${UI_NC} git ls-remote ${ISPC_GIT} ${branch}"
		fi
		ui_success "Источник доступен (имитация)."
		return 0
	fi

	# Жёсткие таймауты: git.ispconfig.org периодически отвечает очень медленно —
	# без timeout проверка «зависает навсегда» (наблюдалось на VDS).
	if _ispc_is_tarball; then
		# Локальный архив (обход Cloudflare-челленджа): если задан ISPC_LOCAL_TARBALL или
		# лежит ВАЛИДНЫЙ /tmp/ispconfig.tar.gz — онлайн-проверку источника пропускаем,
		# иначе HEAD к ispconfig.org вернёт 403 и этап упадёт ДО использования архива.
		local localtar="${ISPC_LOCAL_TARBALL:-/tmp/ispconfig.tar.gz}"
		if [[ -f "$localtar" ]] && _ispc_tar_trusted "$localtar" && tar tzf "$localtar" >/dev/null 2>&1; then
			ui_success "Локальный архив ${localtar} валиден — онлайн-проверка источника пропущена."
			return 0
		fi
		# tarball (stable/nightly): проверяем, что URL отдаёт файл (HTTP 200)
		local turl; turl="$(_ispc_tarball_url)"
		if curl -fsSL -I --connect-timeout 10 --max-time 30 "$turl" >>"$SETUP_LOG" 2>&1; then
			ui_success "Tarball (${branch}) доступен."
			return 0
		fi
		ui_warn "Tarball (${branch}) недоступен (или таймаут 30с): $turl — вероятно, Cloudflare-челлендж (403)."
		# Не падаем сразу: предлагаем человеку залить архив вручную и ЖДЁМ.
		_ispconfig_await_local_tarball "$turl" && return 0
		ui_error "Источник ISPConfig недоступен и локальный архив не предоставлен."
		ui_info "Позже: положите архив в ${UI_W}/tmp/ispconfig.tar.gz${UI_NC} и повторите ${UI_W}$(ls_hint --only ispconfig)${UI_NC}."
		return 1
	else
		# git: ветка/тег должны существовать в репозитории
		local out
		out="$(GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote --heads --tags "$ISPC_GIT" "$branch" 2>>"$SETUP_LOG")"
		local rc=$?
		if ((rc == 124)); then
			ui_error "git.ispconfig.org не ответил за 30с — проверьте сеть/доступность, попробуйте ветку 'stable' (tarball)."
			return 1
		fi
		if [[ -n "$out" ]]; then
			ui_success "Git-ветка/тег '${branch}' найдена в репозитории ISPConfig."
			return 0
		fi
		ui_error "Ветка/тег '${branch}' не найдена в ${ISPC_GIT}."
		ui_info "Доступные ветки: git ls-remote --heads ${ISPC_GIT}"
		return 1
	fi
}

# Fallback, когда git.ispconfig.org недоступен. Падаем на NIGHTLY-tarball (это та же
# git-ветка stable-3.2, но готовым архивом и с надёжной загрузки), а НЕ на release-
# stable: у stable неинтерактивный autoinstall зацикливается на PHP 8.3+.
# Интерактивно — спрашивает; в unattended — переключает автоматически с warn.
_ispconfig_offer_stable_fallback() {
	_ispc_is_tarball && return 1   # уже tarball-источник — некуда падать
	if [[ "${UNATTENDED:-0}" == "1" ]]; then
		ui_warn "Unattended: автоматически переключаюсь на nightly-tarball (git-версия, надёжная загрузка)."
	else
		ui_confirm "Скачать nightly-tarball (готовая git-версия) вместо git-клона '${ISPCONFIG_BRANCH}'?" y || return 1
	fi
	config_set ISPCONFIG_BRANCH nightly
	ui_info "Источник ISPConfig переключён на nightly (сохранено в setup.conf)."
	return 0
}

# --- Загрузка исходников ------------------------------------------------------
_ispconfig_fetch() {
	local branch="${ISPCONFIG_BRANCH:-stable}"
	ui_step "Загрузка исходников ISPConfig (${branch})"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} распаковка/клон в ${ISPC_SRC}, проверка install/install.php"
		return 0
	fi

	# Каталог распаковки создаём атомарно и только для root: mkdir без -p падает, если кто-то
	# успел создать его заново между rm и mkdir (иначе он мог бы подменить файлы установщика).
	rm -rf "$ISPC_SRC"
	if ! mkdir -m 700 "$ISPC_SRC" 2>/dev/null; then
		ui_error "Не удалось создать ${ISPC_SRC}: каталог уже существует (его создал кто-то другой). Прерываю установку ISPConfig."
		return 1
	fi
	if _ispc_is_tarball; then
		_ispc_tar_drop_untrusted
		local turl; turl="$(_ispc_tarball_url)"
		# Обход Cloudflare-челленджа на ispconfig.org: если задан ISPC_LOCAL_TARBALL или
		# уже лежит ВАЛИДНЫЙ /tmp/ispconfig.tar.gz — берём его, загрузку пропускаем.
		# (скачать архив можно в браузере, который проходит JS-проверку Cloudflare).
		local localtar="${ISPC_LOCAL_TARBALL:-/tmp/ispconfig.tar.gz}"
		if [[ -f "$localtar" ]] && _ispc_tar_trusted "$localtar" && tar tzf "$localtar" >/dev/null 2>&1; then
			# 1) Уже есть валидный локальный архив (обход Cloudflare) — используем его.
			ui_info "Использую локальный архив ${localtar} (загрузка с ispconfig.org пропущена)."
			[[ "$localtar" != /tmp/ispconfig.tar.gz ]] && cp -f "$localtar" /tmp/ispconfig.tar.gz
		elif ui_spin "Скачивание ${branch} tarball" bash -c \
				"wget -qO /tmp/ispconfig.tar.gz --timeout=30 --tries=3 '$turl'" \
			 && tar tzf /tmp/ispconfig.tar.gz >/dev/null 2>&1; then
			:   # 2) Скачали штатно и это валидный архив.
		else
			# 3) Загрузка не удалась или пришёл HTML-челлендж вместо архива — ставим
			#    на паузу и ждём, пока человек зальёт архив вручную.
			rm -f /tmp/ispconfig.tar.gz
			if _ispconfig_await_local_tarball "$turl"; then
				[[ "$localtar" != /tmp/ispconfig.tar.gz ]] && cp -f "$localtar" /tmp/ispconfig.tar.gz
			else
				ui_error "Источник ISPConfig недоступен и локальный архив не предоставлен."
				ui_info "Позже: положите архив в ${UI_W}/tmp/ispconfig.tar.gz${UI_NC} → ${UI_W}$(ls_hint --only ispconfig)${UI_NC}."
				return 1
			fi
		fi
		# Финальная проверка целостности перед распаковкой.
		if ! tar tzf /tmp/ispconfig.tar.gz >/dev/null 2>&1; then
			ui_error "/tmp/ispconfig.tar.gz — не валидный tar.gz. Повторите с корректным архивом."
			rm -f /tmp/ispconfig.tar.gz; return 1
		fi
		tar xzf /tmp/ispconfig.tar.gz -C "$ISPC_SRC" --strip-components=1 --no-same-owner --no-same-permissions
	else
		apt_install git
		# git.ispconfig.org хронически нестабилен (обрывы curl 56 посреди клона) —
		# жёсткий таймаут, затем fallback на stable tarball (надёжный хостинг).
		if ! ui_spin "git clone ISPConfig (${branch}, таймаут 5 мин)" \
			env GIT_TERMINAL_PROMPT=0 timeout 300 \
			git clone --depth 1 -b "$branch" "$ISPC_GIT" "$ISPC_SRC"; then
			ui_warn "git clone '${branch}' не удался (git.ispconfig.org нестабилен)."
			_ispconfig_offer_stable_fallback || return 1
			# повторный заход уже как stable
			_ispconfig_fetch; return $?
		fi
	fi

	# Верификация содержимого: установщик на месте
	if [[ ! -f "$ISPC_SRC/install/install.php" ]]; then
		ui_error "В исходниках нет install/install.php — структура неожиданная."
		return 1
	fi
	ui_success "Исходники ISPConfig получены и проверены."
	return 0
}

# --- Генерация autoinstall.ini ------------------------------------------------
_ispconfig_gen_autoinstall() {
	local http_server="${WEBSERVER:-nginx}"
	local ini="$ISPC_SRC/install/autoinstall.ini"
	local mysql_pw="${MARIADB_ROOT_PW:-}"

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} autoinstall.ini: http_server=${http_server}, port=${ISPCONFIG_PANEL_PORT:-8080}, ssl=y"
		return 0
	fi

	ui_step "Генерация autoinstall.ini"
	local admin_pw
	admin_pw="$(config_get_or_gen_password ISPCONFIG_ADMIN_PW 16)"
	( umask 077; : >"$ini" )   # сразу 600: в ini пароли — без окна с правами по umask
	cat >"$ini" <<INI
[install]
# ТОЛЬКО en/de: инсталлятор ISPConfig валидирует язык УСТАНОВКИ по списку en/de,
# и неизвестное значение (напр. ru) в --autoinstall зацикливает install.php
# НАВСЕГДА (вопрос языка спрашивается заново, EOF не помогает). Язык интерфейса
# панели каждый пользователь меняет уже в самой панели.
language=en
install_mode=standard
hostname=${SERVER_FQDN:-server1.example.com}
mysql_hostname=localhost
mysql_port=3306
mysql_root_user=root
mysql_root_password=${mysql_pw}
mysql_database=dbispconfig
mysql_charset=utf8
http_server=${http_server}
ispconfig_port=${ISPCONFIG_PANEL_PORT:-8080}
ispconfig_use_ssl=y
ispconfig_admin_password=${admin_pw}
create_ssl_certs=y
ssl_cert_country=RU
ssl_cert_state=State
ssl_cert_locality=City
ssl_cert_organisation=Org
ssl_cert_organisation_unit=IT
ssl_cert_common_name=${SERVER_FQDN:-server1.example.com}
ssl_cert_email=${ISPCONFIG_ADMIN_EMAIL:-admin@${SERVER_FQDN:-localhost}}

[ssl_cert]
ssl_cert_country=RU
ssl_cert_state=State
ssl_cert_locality=City
ssl_cert_organisation=Org
ssl_cert_organisation_unit=IT
ssl_cert_common_name=${SERVER_FQDN:-server1.example.com}

[expert]
mysql_ispconfig_user=ispconfig
mysql_ispconfig_password=$(config_get_or_gen_password ISPCONFIG_DB_PW 20)
join_multiserver_setup=n
mysql_master_hostname=
mysql_master_root_user=
mysql_master_root_password=
mysql_master_database=
configure_mail=$([[ " ${COMPONENTS:-} " == *" mail "* ]] && echo y || echo n)
configure_jailkit=y
configure_ftp=$([[ " ${COMPONENTS:-} " == *" ftp "* ]] && echo y || echo n)
configure_dns=$([[ " ${COMPONENTS:-} " == *" dns "* ]] && echo y || echo n)
configure_apache=$([[ "$http_server" == "apache" ]] && echo y || echo n)
configure_nginx=$([[ "$http_server" == "nginx" ]] && echo y || echo n)
configure_firewall=$([[ "${FIREWALL:-}" != "none" ]] && echo y || echo n)
install_ispconfig_web_interface=y
INI
	chmod 600 "$ini"
	ISPC_AUTOINSTALL_INI="$ini"
	ui_success "autoinstall.ini сформирован (http_server=${http_server})."
}

# На некоторых релизах (напр. Debian 13/trixie) ISPConfig вешает FPM-пул панели на
# PHP-версию ПО УМОЛЧАНИЮ дистрибутива (там это 8.4), а НЕ на выбранную нами в мастере.
# Если её -fpm не установлен — панель отдаёт 502/500 (сокета пула панели нет).
# Поэтому гарантируем наличие php{default}-fpm + модулей панели ДО запуска install.php.
# Версия PHP, на которой ISPConfig держит панель. НАДЁЖНЫЙ источник — сам vhost панели
# (появляется после install.php): fastcgi_pass unix:/var/lib/phpX.Y-fpm/ispconfig.sock.
# До install.php vhost'а ещё нет → предсказываем по релизу (_distro_native_php). Печатает X.Y.
_ispconfig_panel_php_version() {
	local v
	v="$(grep -rhoP 'fastcgi_pass[[:space:]]+unix:/var/lib/php\K[0-9]+\.[0-9]+(?=-fpm/ispconfig\.sock)' \
		/etc/nginx/sites-available/ispconfig.vhost /etc/nginx/sites-enabled/000-ispconfig.vhost 2>/dev/null | head -1)"
	[[ -z "$v" ]] && v="$(_distro_native_php)"
	printf '%s' "$v"
}

# Гарантировать наличие phpX.Y-fpm + модулей для версии, на которой ISPConfig держит панель.
# Вызывается ДВАЖДЫ: до install.php (предсказание по релизу — страховка) и ПОСЛЕ (по факту из
# vhost — точная гарантия). Идемпотентно. Иначе панель отдаёт 502 (нет сокета пула панели).
_ispconfig_ensure_panel_php() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} проверка/доустановка PHP панели ISPConfig (нативная версия дистрибутива + FPM)"
		return 0
	fi
	local def; def="$(_ispconfig_panel_php_version)"
	# запасной путь для неизвестных релизов ДО install.php (метапакет может быть перебит sury,
	# но пост-фактум по vhost всё равно уточнит после установки).
	[[ -z "$def" ]] && def="$(apt-cache depends php 2>/dev/null | grep -oE 'php[0-9]+\.[0-9]+' | head -n1 | sed 's/php//')"
	[[ -n "$def" ]] || return 0
	if dpkg -l "php${def}-fpm" 2>/dev/null | grep -q '^ii'; then
		# FPM установлен — просто убеждаемся, что запущен (пул панели мог не подняться).
		systemctl is-active --quiet "php${def}-fpm" 2>/dev/null || \
			systemctl enable --now "php${def}-fpm" >>"$SETUP_LOG" 2>&1 || true
		return 0
	fi
	ui_step "Доустановка PHP ${def} + FPM/модули (на этой версии работает панель ISPConfig)"
	local m list="php${def} php${def}-fpm php${def}-cli php${def}-common"
	for m in mysql curl gd mbstring xml zip intl bcmath opcache soap imap; do list+=" php${def}-${m}"; done
	# shellcheck disable=SC2086
	apt_install $list
	sys_run "Запуск php${def}-fpm" systemctl enable --now "php${def}-fpm" || \
		ui_warn "php${def}-fpm не запустился — панель ISPConfig может отдать 502/500."
}

# ISPConfig хранит temp/кэш интерфейса панели в /usr/local/ispconfig, НО юнит
# php-fpm на свежих Debian (≥13/trixie) идёт с ProtectSystem=full → каталог /usr
# монтируется ТОЛЬКО ДЛЯ ЧТЕНИЯ для процесса php-fpm. Из-за этого панель падает с
# HTTP 500: PHPIDS не может писать в interface/temp («Read-only file system»),
# хотя по правам всё ок. Лечится systemd-override ReadWritePaths=/usr/local/ispconfig
# для той php-fpm-версии, что обслуживает пул панели (pool.d/ispconfig.conf).
_ispconfig_fix_fpm_rw() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} ReadWritePaths=/usr/local/ispconfig для php-fpm панели (ProtectSystem)"
		return 0
	fi
	[[ -d /usr/local/ispconfig ]] || return 0
	local pool ver applied=0
	for pool in /etc/php/*/fpm/pool.d/ispconfig.conf; do
		[[ -f "$pool" ]] || continue
		ver="$(printf '%s' "$pool" | grep -oE '/php/[0-9]+\.[0-9]+/' | grep -oE '[0-9]+\.[0-9]+')"
		[[ -n "$ver" ]] || continue
		mkdir -p "/etc/systemd/system/php${ver}-fpm.service.d"
		cat >"/etc/systemd/system/php${ver}-fpm.service.d/ispconfig-rw.conf" <<EOF
[Service]
# ISPConfig пишет temp/кэш панели в /usr/local/ispconfig — открываем запись, т.к.
# ProtectSystem=full делает /usr только-для-чтения для php-fpm (иначе панель = 500).
ReadWritePaths=/usr/local/ispconfig
EOF
		applied=1
	done
	if ((applied)); then
		systemctl daemon-reload
		for pool in /etc/php/*/fpm/pool.d/ispconfig.conf; do
			ver="$(printf '%s' "$pool" | grep -oE '/php/[0-9]+\.[0-9]+/' | grep -oE '[0-9]+\.[0-9]+')"
			[[ -n "$ver" ]] && sys_run "Перезапуск php${ver}-fpm (ReadWritePaths)" systemctl restart "php${ver}-fpm"
		done
		ui_success "php-fpm панели: разрешена запись в /usr/local/ispconfig (обход ProtectSystem=full)."
	fi
}

# --- Установка ----------------------------------------------------------------

# Авто-очистка ЧАСТИЧНОЙ (незавершённой) установки ISPConfig. install.php НЕ
# идемпотентен над недоустановленным ISPConfig: висящие /usr/local/ispconfig,
# неполная БД dbispconfig и крон ломают повторный прогон (--resume после сбоя на
# этапе ispconfig). Признак НЕЗАВЕРШЁНКИ — следы есть, но НЕТ config.inc.php (его
# install.php пишет в самом конце). Рабочую установку (config.inc.php на месте) НЕ
# трогаем — она просто проходит мимо.
_ispconfig_clean_partial() {
	local cfg=/usr/local/ispconfig/server/lib/config.inc.php
	[[ -f "$cfg" ]] && return 0      # полная/рабочая установка — не трогаем

	local myargs=()
	if [[ -f /root/.my.cnf ]]; then myargs=(--defaults-file=/root/.my.cnf)
	elif [[ -n "${MARIADB_ROOT_PW:-}" ]]; then myargs=(-uroot -p"${MARIADB_ROOT_PW}"); fi
	local has_db=0
	if ((${#myargs[@]})) && mysql "${myargs[@]}" -N -e "SHOW DATABASES LIKE 'dbispconfig';" 2>/dev/null | grep -q dbispconfig; then has_db=1; fi

	# Никаких следов — чистить нечего (свежая установка).
	# ВАЖНО: /tmp/ispconfig3_install НЕ считаем следом — это каталог СКАЧАННЫХ исходников
	# (его создаёт _ispconfig_fetch перед этим вызовом). Артефакты частичной установки —
	# это /usr/local/ispconfig и БД dbispconfig.
	[[ -d /usr/local/ispconfig || $has_db -eq 1 ]] || return 0

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} очистка следов НЕЗАВЕРШЁННОЙ установки ISPConfig (каталог/БД/крон)"
		return 0
	fi
	ui_warn "Найдены следы НЕЗАВЕРШЁННОЙ установки ISPConfig (нет config.inc.php) — чищу, иначе install.php снова упадёт."
	systemctl disable --now ispconfig_server ispconfig_agent >>"$SETUP_LOG" 2>&1 || true
	# крон ISPConfig из root crontab + /etc/cron.d
	if crontab -l 2>/dev/null | grep -q '/usr/local/ispconfig/server/'; then
		crontab -l 2>/dev/null | grep -v '/usr/local/ispconfig/server/' | crontab - 2>/dev/null || true
	fi
	rm -f /etc/cron.d/ispconfig
	# НЕ трогаем /tmp/ispconfig3_install — это исходники для текущей установки.
	rm -rf /usr/local/ispconfig
	if ((has_db)); then
		# Сюда же попадает база, сохранённая при удалении без --purge: там клиенты, сайты, ящики.
		# Поэтому перед удалением всегда снимаем дамп и говорим, где он.
		local n dump
		n="$(mysql "${myargs[@]}" -N dbispconfig -e "SELECT (SELECT COUNT(*) FROM client)+(SELECT COUNT(*) FROM web_domain)+(SELECT COUNT(*) FROM mail_user)" 2>/dev/null)"
		dump="/var/backups/luckystack-dbispconfig-$(date +%Y%m%d-%H%M%S).sql.gz"
		mkdir -p /var/backups && chmod 700 /var/backups 2>/dev/null
		if ! (umask 077; mysqldump "${myargs[@]}" --single-transaction dbispconfig 2>>"$SETUP_LOG" | gzip >"$dump") \
				|| [[ ! -s "$dump" ]]; then
			rm -f "$dump"
			ui_error "Не удалось сохранить копию базы dbispconfig, удалять её не стану. Разберитесь с базой и повторите этап."
			return 1
		fi
		mysql "${myargs[@]}" -e "DROP DATABASE IF EXISTS dbispconfig;" >>"$SETUP_LOG" 2>&1 || true
		if [[ "${n:-0}" =~ ^[0-9]+$ ]] && ((n > 0)); then
			ui_warn "База панели от прошлой установки (клиентов, сайтов и ящиков: ${n}) сохранена в ${dump} и заменяется новой."
		else
			ui_info "Неполная БД dbispconfig удалена, копия: ${dump}"
		fi
	fi
	ui_success "Следы частичной установки ISPConfig очищены — ставлю начисто."
}

stage_ispconfig() {
	ui_info "ISPConfig — ветка: ${UI_BOLD}${ISPCONFIG_BRANCH:-stable}${UI_NC}, веб-сервер: ${WEBSERVER:-nginx}"

	# 1) проверка доступности ветки; при недоступном git — fallback на stable
	if ! _ispconfig_verify_source; then
		_ispconfig_offer_stable_fallback || return 1
		_ispconfig_verify_source || return 1
	fi
	# 2) загрузка + верификация исходников (внутри — свой fallback на clone-фейле)
	_ispconfig_fetch || return 1
	# 2.5) гарантируем PHP-версию по умолчанию дистрибутива (на ней ISPConfig
	#      поднимает FPM-пул панели; иначе 502/500 — особенно на Debian 13/trixie)
	_ispconfig_ensure_panel_php
	# 3) генерация неинтерактивного конфига
	_ispconfig_gen_autoinstall

	# 4) запуск установщика
	ui_step "Запуск установщика ISPConfig (неинтерактивно)"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} php -q install/install.php --autoinstall=autoinstall.ini"
		[[ "${HARDEN_CONF_CUSTOM:-n}" == "y" ]] && \
			ui_info "${UI_D}[dry-run]${UI_NC} conf-custom: deny-secrets/dotfiles + security-заголовки + server_tokens + HTTP/3${HARDEN_HSTS:+ + HSTS}"
		ui_success "ISPConfig (имитация) установлен."
		return 0
	fi

	# Пароль root MariaDB ОБЯЗАТЕЛЕН: install.php c пустым паролем получает
	# «Access denied (using password: NO)» и валится. Если в окружении пусто —
	# перечитываем из setup.conf (его пишет этап database).
	if [[ -z "${MARIADB_ROOT_PW:-}" && -f "$CONFIG_FILE" ]]; then
		# Через source (а не grep/sed) — корректно для %q-кодированных значений.
		MARIADB_ROOT_PW="$( . "$CONFIG_FILE" 2>/dev/null; printf '%s' "${MARIADB_ROOT_PW:-}" )"
	fi
	if [[ -z "${MARIADB_ROOT_PW:-}" ]]; then
		ui_error "Не найден пароль root MariaDB (MARIADB_ROOT_PW). Сначала выполните этап «database» (он генерирует и сохраняет пароль), затем повторите ISPConfig."
		return 1
	fi
	# Проверяем, что пароль действительно подходит к MariaDB — иначе install.php
	# всё равно упадёт на «Access denied», но уже после долгой распаковки.
	if command -v mysql >/dev/null 2>&1; then
		if ! mysql -uroot -p"$MARIADB_ROOT_PW" -e 'SELECT 1;' >/dev/null 2>&1; then
			ui_error "Пароль root MariaDB из setup.conf не подходит (Access denied). Проверьте этап «database» / /root/.my.cnf и повторите."
			return 1
		fi
	fi

	# Авто-очистка следов НЕЗАВЕРШЁННОЙ предыдущей установки (—resume после сбоя):
	# install.php не идемпотентен над частично установленным ISPConfig. Рабочую
	# установку не трогает (там есть config.inc.php).
	_ispconfig_clean_partial || return 1

	# ISPConfig 3.2 stable НЕ поддерживает самые свежие PHP (8.5 фаталит).
	# Запускаем install.php совместимой версией, а не системным дефолтом.
	local phpbin="" v
	for v in 8.3 8.2 8.4 8.1 8.0 7.4 8.5; do
		command -v "php${v}" >/dev/null 2>&1 && { phpbin="php${v}"; break; }
	done
	[[ -z "$phpbin" ]] && { apt_install php-cli php-mysql; phpbin="php"; }
	[[ "$phpbin" == "php8.5" ]] && ui_warn "Доступен только PHP 8.5 — ISPConfig может быть несовместим."
	ui_info "Инсталлер ISPConfig запускается через: ${UI_BOLD}${phpbin}${UI_NC}"

	local ilog=/tmp/ispconfig-install.log
	# stdin из /dev/null ОБЯЗАТЕЛЕН: даже в режиме --autoinstall install.php печатает
	# интерактивный баннер и для части вопросов всё равно делает чтение stdin —
	# без подключённого ввода это виснет «навсегда» (в неинтерактивном/фоновом
	# запуске). EOF из /dev/null заставляет взять значения из autoinstall.ini/дефолты.
	if ! ( cd "$ISPC_SRC/install" && \
		"$phpbin" -q install.php --autoinstall="$ISPC_AUTOINSTALL_INI" </dev/null ) >"$ilog" 2>&1; then
		cat "$ilog" >>"$SETUP_LOG"
		ui_error "Установщик ISPConfig завершился с ошибкой. Последние строки:"
		echo -e "${UI_D}-----------------------------------------------${UI_NC}"
		tail -n 15 "$ilog" | sed 's/^/  /'
		echo -e "${UI_D}--- полный вывод: ${ilog} и ${SETUP_LOG} ---${UI_NC}"
		return 1
	fi
	cat "$ilog" >>"$SETUP_LOG"
	rm -f "$ilog"   # вывод инсталлера (может содержать креды) в /tmp не оставляем

	# 5) пост-проверка
	if [[ -d /usr/local/ispconfig/interface ]]; then
		# Дата установки — для сверки свежести nightly-сборки в --status.
		config_set ISPCONFIG_INSTALL_DATE "$(date '+%Y-%m-%d' 2>/dev/null)"
		ui_success "ISPConfig установлен: /usr/local/ispconfig"
		ui_info "Панель: ${UI_C}https://${SERVER_FQDN:-<server>}:${ISPCONFIG_PANEL_PORT:-8080}${UI_NC} (admin / пароль в setup.conf: ISPCONFIG_ADMIN_PW)"
	else
		ui_warn "Каталог /usr/local/ispconfig/interface не найден — проверьте лог установки."
		return 1
	fi

	# 5.4) ГАРАНТИЯ PHP панели ПО ФАКТУ: vhost панели теперь есть → читаем из него РЕАЛЬНУЮ
	#      версию (её выбрала сама ISPConfig) и доустанавливаем её FPM+модули, если их нет.
	#      Закрывает случаи, когда предсказание до install.php не совпало (sury перебил `php`,
	#      Debian 13→8.4, версия не выбрана в мастере). Без этого — 502 (нет сокета пула панели).
	_ispconfig_ensure_panel_php

	# 5.5) ProtectSystem: разрешить php-fpm панели писать в /usr/local/ispconfig
	#      (иначе панель отдаёт 500 — temp/кэш под /usr, а /usr read-only для FPM)
	_ispconfig_fix_fpm_rw

	# 6) B3: кастомные шаблоны conf-custom (после установки — мастера уже есть)
	[[ "${HARDEN_CONF_CUSTOM:-n}" == "y" ]] && _ispconfig_apply_conf_custom

	# 7) Модернизация vhost панели/apps: убрать deprecated «listen … ssl http2;»
	#    (постоянное предупреждение nginx -t) → «listen … ssl; http2 on;».
	#    Чистый фикс — выполняется всегда; HTTP/3 — опционально (PANEL_HTTP3).
	_ispconfig_modernize_panel_vhosts

	# 8) Авто-регистрация установленных версий PHP в ISPConfig (Additional PHP Versions)
	[[ "${ISPC_REGISTER_PHP:-y}" == "y" ]] && _ispconfig_register_php_versions

	# 8.4) Composer глобально + jailkit-секции (composer/php/node) — чтобы SSH-деплой и
	#      jailed shell-юзеры получали composer/node «из коробки» (INSTALL_COMPOSER=y).
	_ispconfig_install_composer
	_ispconfig_jailkit_apps

	# 8.5) Кастомный шаблон зоны DNS (vanity-NS + SPF/DMARC/CAA) — если включён в мастере
	_ispconfig_dns_template

	# 8.6) Порт Apps-vhost (если задан нестандартный ISPCONFIG_APPS_PORT)
	_ispconfig_set_apps_port

	# 8.7) Расширение firewall ISPConfig — поле IP-ограничений по портам + плагин
	_ispconfig_deploy_firewall_ext

	# 8.8) Заморозка vhost — галочка «Не обновлять vhost» у сайта + плагин
	_ispconfig_deploy_vhost_freeze

	# 8.9) Тёмная тема панели — тумблер в шапке
	_ispconfig_deploy_theme_dark

	# 8.10) Панель Fail2ban — список банов/разбан + статус джейлов
	_ispconfig_deploy_fail2ban_panel

	# 8.11) Панель «Бэкап / Восстановление» — снимки + one-click restore
	_ispconfig_deploy_backup_panel

	# 8.12) Панель CrowdSec — активные баны + снятие (если FIREWALL=crowdsec)
	_ispconfig_deploy_crowdsec_panel

	# 8.13) Real-IP лог для CrowdSec в vhost-шаблон (единый /var/log/nginx/crowdsec.log; гейт по cscli)
	_ispconfig_crowdsec_vhost_log
	# 8.13.1) Перевести уже существующие сайты на единый crowdsec.log (без resync)
	_ispconfig_crowdsec_shared_migrate

	# 8.15) Панель Node.js / Composer — управление пакетами по сайтам (гейт по наличию node/composer)
	_ispconfig_deploy_nodecomposer_panel

	# 8.16) Панель «Уведомления» — настройки каналов (email/Telegram) + тест
	_ispconfig_deploy_notify_panel
	_ispconfig_deploy_maint_panel

	# 8.17) Панель «Firewall: блок-лист» — ручной ufw-deny IP/подсетей + подсказки-кластеры (гейт по ufw)
	_ispconfig_deploy_ufwblock_panel

	# 8.17b) Панель «Доверенные IP» — CrowdSec allowlist + fail2ban ignoreip (гейт по cscli/fail2ban)
	_ispconfig_deploy_trusted_panel

	# 8.17c) Ограничение phpMyAdmin ещё раз: на этапе phpmyadmin apps-vhost ISPConfig ещё не было,
	#        а правила доступа нужно подключить и в него (иначе phpMyAdmin на порту apps открыт всем)
	declare -F _dbadmin_restrict >/dev/null && _dbadmin_restrict

	# 8.17d) jail'ы fail2ban ещё раз: лог входов в панель (/var/log/ispconfig/auth.log) появился
	#        только сейчас, на этапе security его не было — jail ispconfig-auth тогда не включался
	declare -F _security_fail2ban_jails >/dev/null && _security_fail2ban_jails

	# 8.17e) FTP только по TLS ещё раз (установщик ISPConfig мог вернуть TLS=1)
	declare -F _ftp_tls_mode >/dev/null && _ftp_tls_mode

	# 8.17f) Настройки безопасности панели (тайм-аут сессии, длина пароля, IDS для admin)
	_ispconfig_security_settings

	# 8.17g) ufw: штатный firewall_plugin ISPConfig мог его выключить (ufw --force disable)
	declare -F _ufw_ensure_enabled >/dev/null && _ufw_ensure_enabled

	# 8.18) Сбросить opcache интерфейса — иначе новые пункты меню (module.conf.php) и страницы
	#       панелей не видны до перезапуска php-fpm (opcache отдаёт старый файл).
	_ispc_interface_php_reload

	# 9) Если Monit установлен — вписать его в Server Config → Monitor (monit раньше по
	#    порядку, поэтому интеграцию делаем здесь, когда ISPConfig уже на месте).
	if command -v monit >/dev/null 2>&1 && declare -F _monit_apply_to_ispconfig >/dev/null; then
		_monit_apply_to_ispconfig
	fi
	return 0
}

# B3 — кастомизация шаблонов ISPConfig по принципу из ispconfig/README.md:
# берём ЖИВОЙ мастер (а не репо-снимок, чтобы не потерять то, что добавила
# установленная версия ISPConfig), копируем в conf-custom и ИДЕМПОТЕНТНО
# вставляем добавки: запрет секретных файлов (безопасно) + HTTP/3 (если собран).
# .master содержит tmpl-токены и не парсится nginx'ом — проверка только после
# ISPConfig Resync (перегенерация vhost) + nginx -t. ОБЯЗАТЕЛЬНО проверить на VM.
_ispconfig_apply_conf_custom() {
	# conf-custom патчит nginx_vhost.conf.master (location-блоки, server_tokens, HTTP/3) —
	# это чисто nginx-овая механика. У Apache другой шаблон и синтаксис; здесь делать нечего.
	if [[ "${WEBSERVER:-nginx}" != "nginx" ]]; then
		ui_info "conf-custom пропущен: применимо только к nginx (выбран ${WEBSERVER:-nginx})."
		return 0
	fi
	ui_step "Кастомные шаблоны ISPConfig (conf-custom)"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} conf-custom: deny-secrets/dotfiles + security-заголовки + server_tokens + HTTP/3${HARDEN_HSTS:+ + HSTS}"
		return 0
	fi
	local cdir=/usr/local/ispconfig/server/conf
	local ccdir=/usr/local/ispconfig/server/conf-custom
	local master=nginx_vhost.conf.master
	if [[ ! -f "$cdir/$master" ]]; then
		ui_warn "Живой мастер $cdir/$master не найден — пропуск conf-custom."
		return 0
	fi
	install -d "$ccdir"
	# Стартовая точка = ЖИВОЙ мастер (если в conf-custom ещё нет нашей версии)
	if [[ ! -f "$ccdir/$master" ]]; then
		cp -a "$cdir/$master" "$ccdir/$master"
	fi
	local f="$ccdir/$master"
	cp -a "$f" "$f.luckystack.bak"

	# --- вставка 1: запрет секретных файлов (безопасно, location-независимо) ---
	if ! grep -qF 'luckystack: deny-secrets' "$f"; then
		local blk; blk="$(mktemp)"
		cat >"$blk" <<'DENY'
        ## luckystack: deny-secrets — запрет секретных файлов/дампов
        location ~* /(?:composer\.(?:json|lock)|package(?:-lock)?\.json|Dockerfile|yarn\.lock|.*\.(?:bak|old|sql|sql\.gz|ini|sh|log))$ {
            deny all; access_log off; log_not_found off; return 404;
        }
DENY
		_ispc_insert_after "$f" 'server_name <tmpl_var' "$blk"
		rm -f "$blk"
		ui_success "conf-custom: добавлен запрет секретных файлов."
	else
		ui_info "conf-custom: запрет секретных файлов уже присутствует."
	fi

	local anchor='server_name <tmpl_var'

	# --- вставка 2: запрет скрытых dotfiles (кроме .well-known для ACME) ---
	if _ispc_add_block "$f" 'luckystack: deny-dotfiles' "$anchor" <<'BLK'
        ## luckystack: deny-dotfiles — запрет скрытых файлов (кроме .well-known)
        location ~ /\.(?!well-known\/) {
            deny all; access_log off; log_not_found off; return 404;
        }
BLK
	then ui_success "conf-custom: добавлен запрет скрытых файлов (dotfiles)."
	else ui_info "conf-custom: запрет dotfiles уже присутствует."; fi

	# --- вставка 3: security-заголовки (БЕЗ дублей) ---
	# Источники дублей: заголовок уже задан (а) глобально через more_set_headers в nginx.conf
	# (частая headers-more-сборка, напр. nginx-autoinstall.sh), (б) другим add_header,
	# (в) самим PHP-аппом. add_header и more_set_headers НЕЗАВИСИМЫ → оба отдаются = дубль.
	# Поэтому: если заголовок уже активен в конфиге (по `nginx -T`: add_header ИЛИ
	# more_set_headers) — НЕ добавляем; для добавляемых снимаем копию апстрима (hide_header).
	# HSTS — отдельной опцией ниже.
	local _hblk _hname _hval _hadd=0 _ngxT
	_ngxT="$(nginx -T 2>/dev/null)"
	_hblk='        ## luckystack: security-headers — базовые заголовки безопасности'$'\n'
	while IFS='|' read -r _hname _hval; do
		[[ -n "$_hname" ]] || continue
		if [[ -n "$_ngxT" ]]; then
			# here-string вместо пайпа: nginx -T > 64 КБ → grep -q выходил первым → SIGPIPE(141) у printf →
			# под pipefail «не найдено» даже при совпадении → заголовок дублировался (SIGPIPE-футган).
			grep -qiE "^[[:space:]]*add_header[[:space:]]+${_hname}([[:space:];\"]|$)|^[[:space:]]*more_set_headers[[:space:]]+.?${_hname}:" <<<"$_ngxT" && continue
		else
			grep -qiE "^[[:space:]]*add_header[[:space:]]+${_hname}([[:space:];\"]|$)" "$f" 2>/dev/null && continue
		fi
		_hblk+="        fastcgi_hide_header ${_hname}; proxy_hide_header ${_hname};"$'\n'
		_hblk+="        add_header ${_hname} \"${_hval}\" always;"$'\n'
		_hadd=1
	done <<'HDRS'
X-Content-Type-Options|nosniff
X-Frame-Options|SAMEORIGIN
Referrer-Policy|strict-origin-when-cross-origin
HDRS
	if (( _hadd )) && printf '%s' "$_hblk" | _ispc_add_block "$f" 'luckystack: security-headers' "$anchor"; then
		ui_success "conf-custom: security-заголовки заданы без дублей (апстрим-копии скрыты)."
	else
		ui_info "conf-custom: security-заголовки уже заданы (другим источником/нами) — пропуск."
	fi

	# --- вставка 4: скрыть версию nginx ---
	if _ispc_add_block "$f" 'luckystack: server-tokens' "$anchor" <<'BLK'
        ## luckystack: server-tokens — скрыть версию nginx
        server_tokens off;
BLK
	then ui_success "conf-custom: server_tokens off."
	else ui_info "conf-custom: server_tokens уже задан."; fi

	# --- вставка 5: HSTS (ОТДЕЛЬНАЯ опция HARDEN_HSTS, по умолчанию ВЫКЛ) ---
	# Принудительный HTTPS на уровне браузера. ОПАСНО без валидного сертификата на
	# ВСЕХ поддоменах — поэтому только по явному запросу.
	if [[ "${HARDEN_HSTS:-n}" == "y" ]]; then
		if _ispc_add_block "$f" 'luckystack: hsts' "$anchor" <<'BLK'
        ## luckystack: hsts — принудительный HTTPS (HSTS, 180 дней)
        add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
BLK
		then ui_success "conf-custom: включён HSTS."
		else ui_info "conf-custom: HSTS уже присутствует."; fi
	fi

	# --- вставка 6: HTTP/3 (только если nginx собран с HTTP/3) ---
	if [[ "${NGX_HTTP3:-${HTTP3:-n}}" == "y" ]]; then
		if ! grep -qF 'luckystack: http3' "$f" && ! grep -qE '^\s*http3 on;' "$f"; then
			local blk3; blk3="$(mktemp)"
			cat >"$blk3" <<'H3'
	## luckystack: http3 — анонсируем h3 (reuseport НЕ здесь, а на default-сервере)
	http3 on;
	add_header Alt-Svc 'h3=":<tmpl_var name='https_port'>"; ma=86400' always;
H3
			_ispc_insert_after "$f" 'http2 on;' "$blk3"
			rm -f "$blk3"
			ui_success "conf-custom: добавлен HTTP/3 (http3 on + Alt-Svc)."
		else
			ui_info "conf-custom: HTTP/3 уже присутствует."
		fi
		# КРИТИЧНО: без quic-листенеров сайт ТОЛЬКО анонсирует h3 (Alt-Svc), но не принимает его
		# (browser пробует h3 → нет ответа → откат на h2). Добавляем listen ... quic (БЕЗ reuseport —
		# он на default-сервере) после основной ssl-listen строки. Идемпотентно (свой маркер).
		if ! grep -qF 'luckystack: http3-quic' "$f" && ! grep -qE 'listen[^;]*[[:space:]]quic' "$f"; then
			local blkq; blkq="$(mktemp)"
			cat >"$blkq" <<'H3Q'
        ## luckystack: http3-quic — quic-листенеры (reuseport на default-сервере)
        listen <tmpl_var name='ip_address'>:<tmpl_var name='https_port'> quic;
<tmpl_if name='ipv6_enabled'>
        listen [<tmpl_var name='ipv6_address'>]:<tmpl_var name='https_port'> quic;
</tmpl_if>
<tmpl_if name='ipv6_wildcard'>
        listen [::]:<tmpl_var name='https_port'> quic;
</tmpl_if>
H3Q
			_ispc_insert_after "$f" "name='https_port'> ssl" "$blkq"
			rm -f "$blkq"
			ui_success "conf-custom: добавлены quic-листенеры (сайты реально принимают h3, а не только анонсируют)."
		fi
	fi

	ui_warn "conf-custom применён к $master. Проверьте на VM: ISPConfig → Tools → Resync,"
	ui_warn "затем 'nginx -t && systemctl reload nginx'. Откат: rm $f"
	log "ispconfig: conf-custom $master обновлён (бэкап $f.luckystack.bak)"
}

# Модернизировать ОДИН nginx-vhost — ПОЛНОСТЬЮ идемпотентно по факту наличия, а НЕ
# по маркеру (ISPConfig мог сам перегенерить vhost уже с «http2 on;»):
#   • убрать устаревший токен http2 из listen-строк;
#   • схлопнуть дубли «http2 on;» / «http3 on;» (оставить по одному);
#   • добавить «http2 on;» после server_name ТОЛЬКО если его ещё нет (+ http3/Alt-Svc/
#     quic-listen при http3=y и если их ещё нет);
#   • ssl_protocols → дописать TLSv1.3; легаси ssl_ciphers (3DES/!DSS) → современный.
# Возвращает: 0 — файл изменён, 2 — изменений не потребовалось, 1 — ошибка.
_modernize_vhost_file() {
	local f="$1" http3="$2" port bf rc
	[[ -f "$f" ]] || return 1
	local ciphers="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384"
	port="$(grep -oE 'listen[[:space:]]+[0-9]+' "$f" | grep -oE '[0-9]+' | head -1)"
	[[ -n "$port" ]] || port="${ISPCONFIG_PANEL_PORT:-8080}"

	# Что УЖЕ есть в файле — чтобы не дублировать.
	local have_h2=0 have_h3=0 have_quic=0
	grep -qE '^[[:space:]]*http2[[:space:]]+on;' "$f" && have_h2=1
	grep -qE '^[[:space:]]*http3[[:space:]]+on;' "$f" && have_h3=1
	grep -qE 'listen[^;]*[[:space:]]quic' "$f"        && have_quic=1

	# Блок директив для вставки после server_name — ТОЛЬКО недостающее.
	bf="$(mktemp)"
	{
		((have_h2==0)) && echo '        http2 on;'
		if [[ "$http3" == "y" ]]; then
			((have_h3==0)) && echo '        http3 on;'
			((have_h3==0)) && printf "        add_header Alt-Svc 'h3=\":%s\"; ma=86400' always;\n" "$port"
		fi
	} >"$bf"
	# Маркер-комментарий — только если реально есть что вставлять.
	[[ -s "$bf" ]] && { { echo '        # luckystack: vhost-modernized'; cat "$bf"; } >"${bf}.2" && mv "${bf}.2" "$bf"; }

	local addquic=0
	[[ "$http3" == "y" && $have_quic -eq 0 ]] && addquic=1

	awk -v bf="$bf" -v ciphers="$ciphers" -v addquic="$addquic" '
		function emit(  l){ while((getline l < bf) > 0) print l; close(bf) }
		/^[[:space:]]*ssl_protocols[[:space:]]/ {
			if ($0 !~ /TLSv1\.3/) sub(/;[[:space:]]*$/, " TLSv1.3;")
			print; next
		}
		/^[[:space:]]*ssl_ciphers[[:space:]]/ {
			if ($0 ~ /DES-CBC3|!DSS/) {
				match($0, /^[[:space:]]*/); ind=substr($0, 1, RLENGTH)
				print ind "ssl_ciphers " ciphers ";"; next
			}
		}
		# Схлопываем дубли: оставляем ПЕРВЫЙ http2 on; / http3 on;, остальные выкидываем.
		/^[[:space:]]*http2[[:space:]]+on;[[:space:]]*$/ { if (h2++) next; print; next }
		/^[[:space:]]*http3[[:space:]]+on;[[:space:]]*$/ { if (h3++) next; print; next }
		/^[[:space:]]*listen[[:space:]]/ {
			sub(/[[:space:]]+http2/, "")          # listen 3333 ssl http2; → listen 3333 ssl;
			print
			if (addquic=="1") {                    # добавить QUIC-listen, если их ещё нет
				q=$0
				if (sub(/[[:space:]]ssl[[:space:]]+ipv6only=on;/, " quic reuseport;", q) \
				    || sub(/[[:space:]]ssl;/, " quic reuseport;", q)) print q
			}
			next
		}
		{ print }
		/^[[:space:]]*server_name/ && !done { emit(); done=1 }
	' "$f" >"$f.modern"
	rc=$?
	rm -f "$bf"
	if [[ $rc -ne 0 ]]; then rm -f "$f.modern"; return 1; fi
	if cmp -s "$f" "$f.modern"; then rm -f "$f.modern"; return 2; fi   # ничего не изменилось
	mv "$f.modern" "$f"; return 0
}

# Привести vhost'ы панели ISPConfig и apps к современному синтаксису (и опц. HTTP/3).
# Живые файлы — с nginx -t и авто-откатом; conf-custom мастера — чтобы пережить
# обновление/переконфигурацию ISPConfig. Повторно вызывается из режима --update.
_ispconfig_modernize_panel_vhosts() {
	[[ "${WEBSERVER:-nginx}" == "nginx" ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} vhost панели/apps: listen … http2 → http2 on;${PANEL_HTTP3:+ + HTTP/3}"
		return 0
	fi
	local http3=n
	[[ "${NGX_HTTP3:-${HTTP3:-n}}" == "y" && "${PANEL_HTTP3:-n}" == "y" ]] && http3=y

	ui_step "Модернизация vhost панели/apps (http2 on; + TLSv1.3$([[ $http3 == y ]] && echo ' + HTTP/3'); без deprecated-предупреждений)"

	local changed=0 vh; local -a baks=()
	for vh in /etc/nginx/sites-available/apps.vhost /etc/nginx/sites-available/ispconfig.vhost; do
		[[ -f "$vh" ]] || continue
		cp -a "$vh" "$vh.premodern.bak"
		if _modernize_vhost_file "$vh" "$http3"; then changed=1; baks+=("$vh"); else rm -f "$vh.premodern.bak"; fi
	done

	if ((changed)); then
		if nginx -t >>"$SETUP_LOG" 2>&1; then
			systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
			for vh in "${baks[@]}"; do rm -f "$vh.premodern.bak"; done
			ui_success "vhost панели/apps обновлены: http2 on; + TLSv1.3$([[ $http3 == y ]] && echo ', HTTP/3') — предупреждений «listen … http2 deprecated» больше нет."
		else
			for vh in "${baks[@]}"; do mv -f "$vh.premodern.bak" "$vh"; done
			systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
			ui_warn "nginx -t не прошёл — откатил vhost'ы панели/apps (см. ${SETUP_LOG})."
			return 0
		fi
	else
		ui_info "vhost панели/apps уже современны (http2 on; + TLSv1.3) — изменений нет."
	fi

	# HTTP/3 — открыть UDP-порты в UFW (QUIC поверх UDP)
	# Панель: UDP только с админских IP, как и TCP (иначе QUIC-доступ к панели обходил бы
	# ограничение по IP). Apps-порт (webmail для пользователей) открыт всем и по TCP, и по UDP.
	if [[ "$http3" == "y" ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
		local pp="${ISPCONFIG_PANEL_PORT:-8080}" ap="${ISPCONFIG_APPS_PORT:-8081}" ip
		if [[ -n "${ISPCONFIG_ADMIN_IPS:-}" ]]; then
			ufw delete allow "${pp}/udp" >>"$SETUP_LOG" 2>&1 || true   # прежнее «UDP панели всем»
			for ip in $ISPCONFIG_ADMIN_IPS; do ufw allow from "$ip" to any port "$pp" proto udp >>"$SETUP_LOG" 2>&1 || true; done
		else
			ufw allow "${pp}/udp" >>"$SETUP_LOG" 2>&1 || true
		fi
		ufw allow "${ap}/udp" >>"$SETUP_LOG" 2>&1 || true
		ui_info "UFW: UDP для QUIC/HTTP3 — панель ${pp}${ISPCONFIG_ADMIN_IPS:+ только с ${ISPCONFIG_ADMIN_IPS}}, apps ${ap} всем."
	fi

	# Долговечность: те же правки в conf-custom мастера (ISPConfig их предпочитает
	# и НЕ перетирает при обновлениях). На мастере — только фикс http2 (порт там
	# tmpl-переменная, HTTP/3/Alt-Svc безопаснее держать на живом файле).
	_ispconfig_modernize_masters
}

# Положить модернизированные мастера панели/apps в conf-custom (фикс http2-синтаксиса).
_ispconfig_modernize_masters() {
	local cdir=/usr/local/ispconfig/server/conf ccdir=/usr/local/ispconfig/server/conf-custom m
	[[ -d "$cdir" ]] || return 0
	install -d "$ccdir" 2>/dev/null || return 0
	for m in nginx_ispconfig.vhost.master nginx_apps.vhost.master; do
		[[ -f "$cdir/$m" ]] || continue
		[[ -f "$ccdir/$m" ]] || cp -a "$cdir/$m" "$ccdir/$m"      # старт = живой мастер
		cp -a "$ccdir/$m" "$ccdir/$m.luckystack.bak"
		# на мастере — фикс http2 + TLSv1.3 (HTTP/3 не ставим: порт там tmpl-токен)
		if _modernize_vhost_file "$ccdir/$m" "n"; then :; else rm -f "$ccdir/$m.luckystack.bak"; fi
	done
	ui_info "conf-custom: мастера панели/apps приведены к современному http2 + TLSv1.3 (переживут обновление ISPConfig)."
}

# Настройки безопасности панели (вызывается в конце этапа и в --update). Свои значения админа
# не перетираем: меняем только заводские «опасные».
#  • sys_ini [misc]: session_timeout=0 (сессия не истекала) → 60 мин; min_password_length < 12 → 12
#  • security_settings.ini: письма о безопасности не на root@localhost, а на NOTIFY_EMAIL;
#    warn_passwd_change=yes; IDS и для администратора (ISPC_IDS_ADMIN=y по умолчанию)
ISPC_SECURITY_INI=/usr/local/ispconfig/security/security_settings.ini
_ispconfig_security_settings() {
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} ISPConfig: тайм-аут сессии 60 мин, пароль от 12 символов, IDS для admin"; return 0; }
	local chg=()
	# -r: сырые переводы строк (с -B mariadb выдал бы их как \n)
	local cfg old; cfg="$(_ispc_mysql -N -s -r -e "SELECT config FROM sys_ini WHERE sysini_id=1" 2>/dev/null | tr -d '\r')"
	local to="${ISPC_SESSION_TIMEOUT:-60}"
	if grep -qx 'session_timeout=0' <<<"$cfg"; then
		# в SQL-строке \n — перевод строки, \\1 — ссылка на группу в REGEXP_REPLACE
		_ispc_mysql -e "UPDATE sys_ini SET config=REGEXP_REPLACE(config, '(^|\\n)session_timeout=0(\\r?\\n|\$)', '\\\\1session_timeout=${to}\\\\2') WHERE sysini_id=1" >>"$SETUP_LOG" 2>&1 \
			&& chg+=("сессия панели истекает через ${to} мин бездействия (было: никогда)")
	fi
	old="$(grep -oP '^min_password_length=\K[0-9]+' <<<"$cfg" | head -1)"
	if [[ -n "$old" ]] && ((old < 12)); then
		_ispc_mysql -e "UPDATE sys_ini SET config=REGEXP_REPLACE(config, '(^|\\n)min_password_length=[0-9]+', '\\\\1min_password_length=12') WHERE sysini_id=1" >>"$SETUP_LOG" 2>&1 \
			&& chg+=("пароль от 12 символов (было ${old})")
	fi
	local f="$ISPC_SECURITY_INI"
	if [[ -f "$f" ]]; then
		local mail="${NOTIFY_EMAIL:-}"; mail="${mail%%,*}"; mail="${mail// /}"
		# адрес, заданный в панели, важнее: апдейтер ISPConfig перезаписывает этот файл
		if [[ -n "${SEC_ADMIN_EMAIL:-}" ]]; then
			if ! grep -qxF "security_admin_email=${SEC_ADMIN_EMAIL}" "$f"; then
				sed -i -E "s|^security_admin_email=.*\$|security_admin_email=${SEC_ADMIN_EMAIL}|" "$f" && chg+=("письма о безопасности на ${SEC_ADMIN_EMAIL}")
			fi
		elif [[ -n "$mail" ]] && grep -qE '^security_admin_email=root@localhost[[:space:]]*$' "$f"; then
			sed -i -E "s|^security_admin_email=root@localhost[[:space:]]*\$|security_admin_email=${mail}|" "$f" && chg+=("письма о безопасности на ${mail}")
		fi
		if grep -qE '^warn_passwd_change=no' "$f"; then
			sed -i -E 's/^warn_passwd_change=no/warn_passwd_change=yes/' "$f" && chg+=("письмо при смене пароля администратора")
		fi
		if [[ "${ISPC_IDS_ADMIN:-y}" == "y" ]] && grep -qE '^ids_admin_enabled=no' "$f"; then
			sed -i -E 's/^ids_admin_enabled=no/ids_admin_enabled=yes/' "$f" && chg+=("IDS проверяет и запросы администратора")
		fi
	fi
	((${#chg[@]})) || return 0
	ui_success "ISPConfig: $(IFS=';'; echo "${chg[*]}" | sed 's/;/; /g')."
	log "ispconfig-security: ${chg[*]}"
	return 0
}

# --- conf-custom после обновления ISPConfig ----------------------------------------
# Наши правки живут в копиях стандартных шаблонов (conf-custom/<шаблон>), а копия делается один
# раз. После обновления ISPConfig стандартный шаблон в conf/ меняется, а копия остаётся от старой
# версии: новые переменные и исправления ISPConfig в неё не попадают. Поэтому запоминаем sha256
# стандартного шаблона, с которого сделана копия, и при его изменении пересобираем копию:
# бэкап старой → свежий стандартный шаблон → заново все наши правки (они идемпотентны).
ISPC_CC_DIR=/usr/local/ispconfig/server/conf-custom
ISPC_CC_STATE=/usr/local/ispconfig/server/conf-custom/.luckystack-stock.sha256
ISPC_CC_MASTERS="nginx_vhost.conf.master nginx_apps.vhost.master nginx_ispconfig.vhost.master"

# Записать хеши стандартных шаблонов, для которых есть наша копия и ещё нет записи (до обновления).
_ispconfig_confcustom_record() {
	[[ -d "$ISPC_CC_DIR" ]] || return 0
	local m h
	for m in $ISPC_CC_MASTERS; do
		[[ -f "$ISPC_CC_DIR/$m" && -f "/usr/local/ispconfig/server/conf/$m" ]] || continue
		grep -q " ${m}\$" "$ISPC_CC_STATE" 2>/dev/null && continue
		h="$(sha256sum "/usr/local/ispconfig/server/conf/$m" | awk '{print $1}')"
		echo "$h $m" >>"$ISPC_CC_STATE"
	done
	return 0
}

# Пересобрать копии, у которых сменился стандартный шаблон. rc=0 всегда.
_ispconfig_confcustom_refresh() {
	[[ -d "$ISPC_CC_DIR" ]] || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	local m h old changed=() bdir ts
	for m in $ISPC_CC_MASTERS; do
		[[ -f "$ISPC_CC_DIR/$m" && -f "/usr/local/ispconfig/server/conf/$m" ]] || continue
		h="$(sha256sum "/usr/local/ispconfig/server/conf/$m" | awk '{print $1}')"
		old="$(awk -v m="$m" '$2==m{print $1}' "$ISPC_CC_STATE" 2>/dev/null | tail -1)"
		[[ -n "$old" && "$old" != "$h" ]] && changed+=("$m")
	done
	if ((${#changed[@]} == 0)); then _ispconfig_confcustom_record; return 0; fi

	ts="$(date +%Y%m%d-%H%M%S)"; bdir="$ISPC_CC_DIR/.luckystack-backup"
	mkdir -p "$bdir"; chmod 700 "$bdir"
	local had_harden=0
	for m in "${changed[@]}"; do
		cp -a "$ISPC_CC_DIR/$m" "$bdir/$m.$ts"
		[[ "$m" == nginx_vhost.conf.master ]] && grep -q 'luckystack: deny-secrets' "$ISPC_CC_DIR/$m" && had_harden=1
		cp -a "/usr/local/ispconfig/server/conf/$m" "$ISPC_CC_DIR/$m"
	done
	ui_info "conf-custom: стандартные шаблоны ISPConfig изменились (${changed[*]}) — пересобираю копии; прежние в ${bdir}/*.${ts}"
	# наши правки заново (каждая идемпотентна и работает с копией в conf-custom)
	if [[ " ${changed[*]} " == *" nginx_vhost.conf.master "* ]]; then
		((had_harden)) && HARDEN_CONF_CUSTOM=y _ispconfig_apply_conf_custom
		declare -F _ispconfig_crowdsec_vhost_log >/dev/null && _ispconfig_crowdsec_vhost_log
		declare -F _nginx_drop_legacy_headers >/dev/null && _nginx_drop_legacy_headers
	fi
	if [[ " ${changed[*]} " == *" nginx_apps.vhost.master "* || " ${changed[*]} " == *" nginx_ispconfig.vhost.master "* ]]; then
		_ispconfig_modernize_masters
		declare -F _dbadmin_restrict >/dev/null && _dbadmin_restrict
	fi
	# новые хеши
	local tmp; tmp="$(mktemp)"
	for m in $ISPC_CC_MASTERS; do
		[[ -f "$ISPC_CC_DIR/$m" && -f "/usr/local/ispconfig/server/conf/$m" ]] || continue
		echo "$(sha256sum "/usr/local/ispconfig/server/conf/$m" | awk '{print $1}') $m" >>"$tmp"
	done
	install -m 600 "$tmp" "$ISPC_CC_STATE"; rm -f "$tmp"
	ui_success "conf-custom пересобраны на новых шаблонах ISPConfig: ${changed[*]}. Если в копиях были ручные правки — они в ${bdir}."
	log "confcustom-refresh: ${changed[*]} (бэкап ${bdir}/*.${ts})"
	return 0
}

# --update: встроенные бэкапы ISPConfig у сайтов, где они выключены (по сайту, с ротацией и
# восстановлением из панели: Sites → сайт → Backup). Спрашивает (ISPC_SITE_BACKUPS запоминает
# ответ); без терминала — только подсказка. Копии кладёт сам ISPConfig в backup_dir (/var/backup).
_ispconfig_site_backups() {
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	[[ "${ISPC_SITE_BACKUPS:-}" == "n" ]] && return 0
	local n total copies="${ISPC_SITE_BACKUP_COPIES:-3}"
	n="$(_ispc_mysql -NBe "SELECT COUNT(*) FROM web_domain WHERE type='vhost' AND backup_interval='none'" 2>/dev/null)"
	total="$(_ispc_mysql -NBe "SELECT COUNT(*) FROM web_domain WHERE type='vhost'" 2>/dev/null)"
	[[ "$n" =~ ^[0-9]+$ ]] && ((n > 0)) || return 0
	local bdir; bdir="$(_ispc_mysql -N -s -r -e "SELECT config FROM server WHERE server_id=1" 2>/dev/null | grep -oP '^backup_dir=\K\S+' | head -1)"
	bdir="${bdir:-/var/backup}"
	if [[ "${ISPC_SITE_BACKUPS:-}" != "y" ]]; then
		if [[ ! -t 0 ]]; then
			ui_info "Бэкапы ISPConfig выключены у ${n} из ${total} сайтов. Включить: ISPC_SITE_BACKUPS=y в setup.conf и $(ls_hint --update) (или в панели у сайта)."
			return 0
		fi
		local www free
		www="$(du -sk /var/www 2>/dev/null | awk '{print int($1/1048576)}')"
		mkdir -p "$bdir" 2>/dev/null
		free="$(df -Pk "$bdir" 2>/dev/null | awk 'NR==2{print int($4/1048576)}')"
		ui_info "Бэкапы ISPConfig выключены у ${n} из ${total} сайтов. Сайты занимают ~${www:-?} ГБ, свободно ${free:-?} ГБ; ${copies} копии в сжатом виде займут примерно до $(( ${www:-0} * copies )) ГБ."
		if ! ui_confirm "Включить ежедневный бэкап ISPConfig для этих сайтов (${copies} копии, ${bdir})?" y; then
			config_set ISPC_SITE_BACKUPS n; return 0
		fi
		config_set ISPC_SITE_BACKUPS y
	fi
	_ispc_mysql -e "UPDATE web_domain SET backup_interval='daily', backup_copies=${copies} WHERE type='vhost' AND backup_interval='none'" >>"$SETUP_LOG" 2>&1 \
		&& ui_success "Бэкапы ISPConfig включены у ${n} сайтов: ежедневно, ${copies} копии в ${bdir}. Восстановление: Sites → сайт → Backup." \
		|| ui_warn "Не удалось включить бэкапы сайтов — см. ${SETUP_LOG}."
}

# Хелпер: mysql к базе dbispconfig (через /root/.my.cnf или root-пароль).
_ispc_mysql() {
	if [[ -f /root/.my.cnf ]]; then mysql --defaults-file=/root/.my.cnf dbispconfig "$@"
	else mysql -uroot -p"${MARIADB_ROOT_PW:-}" dbispconfig "$@"; fi
}

# Общая часть наших панелей: interface/lib/ss_panel.inc.php (действия только POST с CSRF-токеном
# ISPConfig + журнал действий) и таблица журнала ss_panel_audit. Вызывается в начале установки
# каждой панели, идемпотентно. Страницы подключают файл через require_once, поэтому без него
# панель ставить нельзя: при сбое возвращаем 1, и панель пропускается.
_ispconfig_deploy_panel_common() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	local src="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/common/ss_panel.inc.php"
	local dst=/usr/local/ispconfig/interface/lib/ss_panel.inc.php
	[[ -d /usr/local/ispconfig/interface/lib ]] || return 1
	[[ -f "$src" ]] || { ui_warn "Не найден assets/ispconfig/common/ss_panel.inc.php."; return 1; }
	if command -v php >/dev/null 2>&1 && ! php -l "$src" >/dev/null 2>&1; then
		ui_warn "php -l ss_panel.inc.php не прошёл."; return 1
	fi
	install -o ispconfig -g ispconfig -m 644 "$src" "$dst" 2>>"$SETUP_LOG" || return 1
	_ispc_mysql <<'SQL' >>"$SETUP_LOG" 2>&1 || true
CREATE TABLE IF NOT EXISTS ss_panel_audit (
  id int(11) unsigned NOT NULL auto_increment,
  created datetime NOT NULL,
  username varchar(64) NOT NULL default '',
  ip varchar(45) NOT NULL default '',
  panel varchar(32) NOT NULL default '',
  action varchar(32) NOT NULL default '',
  detail varchar(500) NOT NULL default '',
  PRIMARY KEY (id),
  KEY created (created)
) DEFAULT CHARSET=utf8mb4;
SQL
	_ispc_menu_deploy
	return 0
}

# Развернуть расширение firewall ISPConfig: дружелюбный модуль «Firewall IP-rules»
# (таблица firewall_restrict с отдельными полями сервер/протокол/порт/IP/описание/вкл) +
# серверный плагин, применяющий правила через /etc/ufw/before.rules (chain ufw-before-input,
# ДО user-правил ISPConfig: ACCEPT перечисленным IP + DROP остальным). Встроенный firewall
# ISPConfig открывает порты ТОЛЬКО всем — модуль задаёт «порт открыт лишь этим IP».
# Плагин — отдельный (переживает обновления ISPConfig); файлы интерфейса и пункт меню
# переналиваются здесь (как conf-custom), т.к. при апдейте ISPConfig их затирает.
# Наши установочные IP-ограничения (SSH/панель/MySQL) сеются в таблицу — видны и правятся
# в панели. Идемпотентно, с php -l и откатом.
_ispconfig_deploy_firewall_ext() {
	[[ "${ISPC_FW_EXT:-y}" == "y" ]] || return 0
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || return 0
	command -v mysql >/dev/null 2>&1 || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} firewall-ext: модуль «Firewall IP-rules» (таблица+форма+меню) + плагин + seed наших правил"; return 0; }
	_ispconfig_deploy_panel_common || { ui_warn "Общая часть панелей не установилась — firewall-ext пропущен."; return 0; }
	local asset="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/firewall-ext/firewall_restrict_plugin.inc.php"
	[[ -f "$asset" ]] || { ui_warn "Asset плагина firewall не найден ($asset) — расширение пропущено."; return 0; }

	ui_step "Расширение firewall ISPConfig (IP-ограничения по портам)"

	# 1) серверный плагин + симлинк (только если php -l чистый — иначе сломали бы server.sh)
	local pav=/usr/local/ispconfig/server/plugins-available pen=/usr/local/ispconfig/server/plugins-enabled
	if command -v php >/dev/null 2>&1 && php -l "$asset" >/dev/null 2>&1; then
		install -o root -g root -m 750 "$asset" "$pav/firewall_restrict_plugin.inc.php"
		[[ -d "$pen" ]] && ln -sf ../plugins-available/firewall_restrict_plugin.inc.php "$pen/firewall_restrict_plugin.inc.php"
	else
		ui_warn "php -l плагина firewall не прошёл — плагин не установлен."
	fi

	# 1b) серверный МОДУЛЬ + симлинк. Без него события плагина (firewall_restrict_*) НЕ
	# поднимаются при сохранении в панели (для кастомной таблицы нет штатного модуля),
	# и before.rules не пересобирается. Модуль регистрирует хук на таблицу и поднимает события.
	local modasset="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/firewall-ext/firewall_restrict_module.inc.php"
	local mav=/usr/local/ispconfig/server/mods-available men=/usr/local/ispconfig/server/mods-enabled
	if [[ -f "$modasset" ]] && command -v php >/dev/null 2>&1 && php -l "$modasset" >/dev/null 2>&1; then
		install -o root -g root -m 750 "$modasset" "$mav/firewall_restrict_module.inc.php"
		[[ -d "$men" ]] && ln -sf ../mods-available/firewall_restrict_module.inc.php "$men/firewall_restrict_module.inc.php"
	else
		ui_warn "php -l модуля firewall не прошёл / asset не найден — модуль не установлен (правила из панели не применятся)."
	fi

	# 1c) гео-инфраструктура: ipset + скрипт обновления зон стран (ipdeny.com) + еженедельный cron.
	# Плагин ссылается на ipset'ы ss_geo_<cc> в before.rules; before.init (его пишет плагин) строит
	# их из /etc/ss-firewall/geoip/<cc>.zone. Скрипт качает зоны для стран из countries.list.
	if ! command -v ipset >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive apt-get install -y -q ipset >>"$SETUP_LOG" 2>&1 || ui_warn "ipset не установился — гео-фильтр firewall работать не будет (rate-limit и IP-правила — будут)."
	fi
	local georef="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/firewall-ext/ss-firewall-geo-refresh.sh"
	if [[ -f "$georef" ]]; then
		install -o root -g root -m 750 "$georef" /usr/local/sbin/ss-firewall-geo-refresh
		mkdir -p /etc/ss-firewall/geoip
		# еженедельное обновление зон (вс 04:17), тихо
		cat > /etc/cron.d/ss-firewall-geo <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# luckystack: еженедельное обновление гео-зон firewall (диапазоны IP по странам)
17 4 * * 0 root /usr/local/sbin/ss-firewall-geo-refresh >/dev/null 2>&1
CRON
		chmod 644 /etc/cron.d/ss-firewall-geo
	fi

	local IFc=/usr/local/ispconfig/interface/web/admin

	# 2) Дружелюбный модуль «Firewall IP-rules»: таблица отдельных правил + файлы + меню
	local moddir="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/firewall-ext/module"
	if [[ -d "$moddir" ]]; then
		_ispc_mysql <<'SQL' >>"$SETUP_LOG" 2>&1 || true
CREATE TABLE IF NOT EXISTS firewall_restrict (
  restrict_id int(11) unsigned NOT NULL auto_increment,
  sys_userid int(11) unsigned NOT NULL default 0,
  sys_groupid int(11) unsigned NOT NULL default 0,
  sys_perm_user varchar(5) default NULL,
  sys_perm_group varchar(5) default NULL,
  sys_perm_other varchar(5) default NULL,
  server_id int(11) unsigned NOT NULL default 0,
  proto enum('tcp','udp') NOT NULL default 'tcp',
  port varchar(16) NOT NULL default '',
  allowed_ips text,
  allow_all enum('n','y') NOT NULL default 'n',
  rate_limit enum('n','y') NOT NULL default 'n',
  geo_mode enum('off','allow','block') NOT NULL default 'off',
  geo_countries varchar(255) default NULL,
  description varchar(255) default NULL,
  active enum('n','y') NOT NULL default 'y',
  applied datetime default NULL,
  PRIMARY KEY (restrict_id)
) DEFAULT CHARSET=utf8;
SQL
		# колонка allow_all для таблиц, созданных прежней версией (без неё)
		_ispc_mysql -e "ALTER TABLE firewall_restrict ADD COLUMN IF NOT EXISTS allow_all enum('n','y') NOT NULL default 'n' AFTER allowed_ips;" >>"$SETUP_LOG" 2>&1 || true
		_ispc_mysql -e "ALTER TABLE firewall_restrict ADD COLUMN IF NOT EXISTS applied datetime default NULL;" >>"$SETUP_LOG" 2>&1 || true
		# rate-limit + гео-фильтр (для таблиц прежней версии)
		_ispc_mysql -e "ALTER TABLE firewall_restrict ADD COLUMN IF NOT EXISTS rate_limit enum('n','y') NOT NULL default 'n' AFTER allow_all;" >>"$SETUP_LOG" 2>&1 || true
		_ispc_mysql -e "ALTER TABLE firewall_restrict ADD COLUMN IF NOT EXISTS geo_mode enum('off','allow','block') NOT NULL default 'off' AFTER rate_limit;" >>"$SETUP_LOG" 2>&1 || true
		_ispc_mysql -e "ALTER TABLE firewall_restrict ADD COLUMN IF NOT EXISTS geo_countries varchar(255) default NULL AFTER geo_mode;" >>"$SETUP_LOG" 2>&1 || true

		# наши IP-ограничения (SSH/панель/MySQL) — в панель всегда (идемпотентно по
		# server_id+proto+port: правки IP сохраняются, удалённое правило восстанавливается).
		_ispconfig_seed_firewall_rules
		# Публичные порты переносим из родного firewall ТОЛЬКО при первом заходе (родной ещё
		# active=y). После takeover (active=n) панель — единственный источник, и апдейт НЕ
		# пересевает публичные порты (чтобы не воскрешать удалённые админом в панели).
		_ispc_native_fw_active && _ispconfig_seed_public_ports
		local okphp=1 pf
		for pf in "$moddir"/*.php "$moddir"/form/*.php "$moddir"/list/*.php; do
			[[ -f "$pf" ]] && { php -l "$pf" >/dev/null 2>&1 || okphp=0; }
		done
		if ((okphp)); then
			install -o ispconfig -g ispconfig -m 644 "$moddir"/firewall_restrict_*.php "$IFc/" 2>>"$SETUP_LOG"
			install -o ispconfig -g ispconfig -m 644 "$moddir"/form/firewall_restrict.tform.php "$IFc/form/" 2>>"$SETUP_LOG"
			install -o ispconfig -g ispconfig -m 644 "$moddir"/list/firewall_restrict.list.php "$IFc/list/" 2>>"$SETUP_LOG"
			install -o ispconfig -g ispconfig -m 644 "$moddir"/templates/firewall_restrict_*.htm "$IFc/templates/" 2>>"$SETUP_LOG"
			install -o ispconfig -g ispconfig -m 644 "$moddir"/lib/lang/*.lng "$IFc/lib/lang/" 2>>"$SETUP_LOG"
			# CUSTOM-валидатор поля allowed_ips (interface/lib/classes — оттуда $app->uses его берёт)
			[[ -f "$moddir"/lib/classes/validate_firewall_restrict.inc.php ]] && \
				install -o ispconfig -g ispconfig -m 644 "$moddir"/lib/classes/validate_firewall_restrict.inc.php /usr/local/ispconfig/interface/lib/classes/ 2>>"$SETUP_LOG"
			ui_info "Модуль «Firewall IP-rules» развёрнут (таблица + форма + меню; родной Firewall убран из меню)."
			# Синхронизировать before.rules с таблицей (всегда), затем — только при первом
			# заходе — перехватить движок у родного firewall (вычистить его user.rules, active=n).
			_ispconfig_fw_rebuild
			_ispconfig_takeover_native_firewall
			# теперь правила ведёт панель — снять базовый блок restrict из before.rules (он записан
			# на этапе security до установки панели и иначе перехватывал бы её правила)
			declare -F _security_ufw_restrict_persist >/dev/null && command -v ufw >/dev/null 2>&1 && _security_ufw_restrict_persist
		else
			ui_warn "php -l файлов модуля Firewall IP-rules не прошёл — модуль не развёрнут."
		fi
	fi

	ui_success "Firewall ISPConfig расширен: модуль «Firewall IP-rules» (отдельные поля) + плагин (before.rules)."
}

# Панель Fail2ban: таблицы (кэш статуса + очередь действий) + admin-страница + root-cron + меню.
# Интерфейс (ispconfig-пользователь) не может дёргать fail2ban-client (root-сокет) → пишет запросы
# в очередь fail2ban_action, root-cron ss-fail2ban-sync.php их выполняет и обновляет кэш статуса
# (таблица fail2ban_jail), который читает страница. Переживает обновления ISPConfig (переналив в --update).
_ispconfig_deploy_fail2ban_panel() {
	[[ "${ISPC_FAIL2BAN_PANEL:-y}" == "y" ]] || return 0
	[[ -d /usr/local/ispconfig/interface/web/admin ]] || return 0
	_ispconfig_deploy_panel_common || { ui_warn "Общая часть панелей не установилась — панель пропущена."; return 0; }
	ui_step "Панель Fail2ban (баны/разбан + статус джейлов)"
	local base="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/fail2ban-panel"
	[[ -d "$base" ]] || { ui_warn "assets fail2ban-panel не найдены — пропуск."; return 0; }

	_ispc_mysql <<'SQL' >>"$SETUP_LOG" 2>&1 || true
CREATE TABLE IF NOT EXISTS fail2ban_jail (
  jail varchar(64) NOT NULL,
  banned int(11) NOT NULL default 0,
  failed int(11) NOT NULL default 0,
  total int(11) NOT NULL default 0,
  banned_ips mediumtext,
  updated datetime default NULL,
  PRIMARY KEY (jail)
) DEFAULT CHARSET=utf8;
CREATE TABLE IF NOT EXISTS fail2ban_action (
  id int(11) unsigned NOT NULL auto_increment,
  action enum('ban','unban') NOT NULL default 'unban',
  jail varchar(64) NOT NULL default '',
  ip varchar(64) NOT NULL default '',
  status enum('pending','done','error') NOT NULL default 'pending',
  result varchar(255) default NULL,
  created datetime default NULL,
  processed datetime default NULL,
  PRIMARY KEY (id)
) DEFAULT CHARSET=utf8;
SQL

	local IFc=/usr/local/ispconfig/interface/web/admin
	local okphp=1
	php -l "$base/admin/fail2ban_list.php" >/dev/null 2>&1 || okphp=0
	php -l "$base/ss-fail2ban-sync.php"   >/dev/null 2>&1 || okphp=0
	if ((okphp)); then
		install -o ispconfig -g ispconfig -m 644 "$base/admin/fail2ban_list.php" "$IFc/" 2>>"$SETUP_LOG"
		install -o ispconfig -g ispconfig -m 644 "$base/admin/lib/lang/"*_fail2ban.lng "$IFc/lib/lang/" 2>>"$SETUP_LOG"
		# root-cron синхронизатор (раз в минуту)
		mkdir -p /usr/local/ispconfig/server/scripts
		install -o root -g root -m 750 "$base/ss-fail2ban-sync.php" /usr/local/ispconfig/server/scripts/ss-fail2ban-sync.php
		cat > /etc/cron.d/ss-fail2ban <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# luckystack: синхронизация Fail2ban ↔ панель ISPConfig (статус джейлов + очередь разбан/бан)
* * * * * root /usr/bin/php /usr/local/ispconfig/server/scripts/ss-fail2ban-sync.php >/dev/null 2>&1
CRON
		chmod 644 /etc/cron.d/ss-fail2ban
		# меню: пункт «Fail2ban» после Directive Snippets (идемпотентно, дедуп)
		# первый прогон синхронизатора — наполнить кэш сразу
		[[ -x /usr/bin/php ]] && /usr/bin/php /usr/local/ispconfig/server/scripts/ss-fail2ban-sync.php >>"$SETUP_LOG" 2>&1 || true
		ui_success "Панель Fail2ban развёрнута (меню «Дополнения» → Fail2ban; кэш статуса + очередь действий + cron)."
	else
		ui_warn "php -l страниц Fail2ban не прошёл — панель не развёрнута."
	fi
}

# Панель «Бэкап / Восстановление»: кэш снимков + очередь restore + admin-страница + root-cron + меню.
# Интерфейс (ispconfig) не может ни читать /var/backups/server (root 700), ни запускать restore (root) →
# панель пишет запрос в backup_restore, root-cron ss-backup-sync.php обновляет кэш снимков (backup_snapshot)
# и выполняет server-backup.sh --restore. Восстановление НЕОБРАТИМО; имя снимка/компоненты валидируются.
_ispconfig_deploy_backup_panel() {
	[[ "${ISPC_BACKUP_PANEL:-y}" == "y" ]] || return 0
	[[ -d /usr/local/ispconfig/interface/web/admin ]] || return 0
	_ispconfig_deploy_panel_common || { ui_warn "Общая часть панелей не установилась — панель пропущена."; return 0; }
	ui_step "Панель «Бэкап / Восстановление» (снимки + one-click restore)"
	local base="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/backup-panel"
	[[ -d "$base" ]] || { ui_warn "assets backup-panel не найдены — пропуск."; return 0; }

	_ispc_mysql <<'SQL' >>"$SETUP_LOG" 2>&1 || true
CREATE TABLE IF NOT EXISTS backup_snapshot (
  snapshot varchar(32) NOT NULL,
  size varchar(32) default NULL,
  components varchar(128) default NULL,
  created datetime default NULL,
  PRIMARY KEY (snapshot)
) DEFAULT CHARSET=utf8;
CREATE TABLE IF NOT EXISTS backup_restore (
  id int(11) unsigned NOT NULL auto_increment,
  snapshot varchar(32) NOT NULL default '',
  components varchar(128) NOT NULL default '',
  status enum('pending','running','done','error') NOT NULL default 'pending',
  result varchar(255) default NULL,
  created datetime default NULL,
  processed datetime default NULL,
  PRIMARY KEY (id)
) DEFAULT CHARSET=utf8;
CREATE TABLE IF NOT EXISTS backup_setting (
  name varchar(32) NOT NULL,
  value varchar(255) default NULL,
  updated datetime default NULL,
  PRIMARY KEY (name)
) DEFAULT CHARSET=utf8;
CREATE TABLE IF NOT EXISTS backup_job (
  id int(11) unsigned NOT NULL auto_increment,
  action enum('run','config') NOT NULL default 'run',
  payload mediumtext,
  status enum('pending','running','done','error') NOT NULL default 'pending',
  result varchar(2048) default NULL,
  created datetime default NULL,
  processed datetime default NULL,
  PRIMARY KEY (id)
) DEFAULT CHARSET=utf8;
SQL

	# Панель управляет бэкапом → server-backup.sh должен существовать. Если этап backup не
	# прогонялся (напр. ручной сервер), ставим сам скрипт из lib/backup.sh (без таймера —
	# таймером рулит панель через настройки). Так «Бэкап сейчас»/restore работают из коробки.
	if [[ ! -x /usr/local/sbin/server-backup.sh ]] && declare -F _backup_write_script >/dev/null; then
		BACKUP_SCRIPT=/usr/local/sbin/server-backup.sh _backup_write_script >>"$SETUP_LOG" 2>&1 \
			&& chmod 700 /usr/local/sbin/server-backup.sh && log "backup-panel: server-backup.sh установлен"
		[[ -f /etc/server-backup.conf ]] || cat >/etc/server-backup.conf <<'BKC'
# LuckyStack — настройки серверного бэкапа (правится из панели ISPConfig).
BACKUP_DIR=/var/backups/server
BACKUP_RETENTION_DAYS=7
BACKUP_INCLUDE_WWW=n
BACKUP_INCLUDE_MAIL=n
BACKUP_TIME=03:30
BACKUP_REMOTE_TYPE=none
BACKUP_REMOTE=''
BKC
		chmod 600 /etc/server-backup.conf 2>/dev/null || true
	fi

	local IFc=/usr/local/ispconfig/interface/web/admin
	local okphp=1
	php -l "$base/admin/backup_restore_list.php" >/dev/null 2>&1 || okphp=0
	php -l "$base/ss-backup-sync.php"            >/dev/null 2>&1 || okphp=0
	if ((okphp)); then
		install -o ispconfig -g ispconfig -m 644 "$base/admin/backup_restore_list.php" "$IFc/" 2>>"$SETUP_LOG"
		install -o ispconfig -g ispconfig -m 644 "$base/admin/lib/lang/"*_backup_restore.lng "$IFc/lib/lang/" 2>>"$SETUP_LOG"
		mkdir -p /usr/local/ispconfig/server/scripts
		install -o root -g root -m 750 "$base/ss-backup-sync.php" /usr/local/ispconfig/server/scripts/ss-backup-sync.php
		cat > /etc/cron.d/ss-backup-panel <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# luckystack: синхронизация бэкапов ↔ панель ISPConfig (кэш снимков + очередь restore)
* * * * * root /usr/bin/php /usr/local/ispconfig/server/scripts/ss-backup-sync.php >/dev/null 2>&1
CRON
		chmod 644 /etc/cron.d/ss-backup-panel
		[[ -x /usr/bin/php ]] && /usr/bin/php /usr/local/ispconfig/server/scripts/ss-backup-sync.php >>"$SETUP_LOG" 2>&1 || true
		ui_success "Панель «Бэкап / Восстановление» развёрнута (меню «Дополнения» → Backup / Restore; кэш снимков + очередь restore + cron)."
	else
		ui_warn "php -l страниц Backup/Restore не прошёл — панель не развёрнута."
	fi
}

# Панель «CrowdSec»: кэш активных решений (баны) + очередь снятия + admin-страница + root-cron + меню.
# Аналог лог-вьюшек ISPConfig, но структурировано. Интерфейс (ispconfig) не может дёргать cscli (root) →
# root-cron ss-crowdsec-sync.php кэширует `cscli decisions list` и выполняет снятие банов. Гейт: cscli есть
# (FIREWALL=crowdsec). Страница/меню переживают обновление ISPConfig (переналив в --update).
_ispconfig_deploy_crowdsec_panel() {
	[[ "${ISPC_CROWDSEC_PANEL:-y}" == "y" ]] || return 0
	[[ -d /usr/local/ispconfig/interface/web/admin ]] || return 0
	_ispconfig_deploy_panel_common || { ui_warn "Общая часть панелей не установилась — панель пропущена."; return 0; }
	command -v cscli >/dev/null 2>&1 || { log "crowdsec-panel: cscli нет — пропуск"; return 0; }
	ui_step "Панель CrowdSec (активные баны + снятие)"
	local base="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/crowdsec-panel"
	[[ -d "$base" ]] || { ui_warn "assets crowdsec-panel не найдены — пропуск."; return 0; }

	_ispc_mysql <<'SQL' >>"$SETUP_LOG" 2>&1 || true
CREATE TABLE IF NOT EXISTS crowdsec_decision (
  id int(11) unsigned NOT NULL auto_increment,
  value varchar(64) NOT NULL default '',
  scope varchar(16) default NULL,
  scenario varchar(128) default NULL,
  origin varchar(32) default NULL,
  type varchar(16) default NULL,
  country varchar(8) default NULL,
  as_name varchar(128) default NULL,
  duration varchar(32) default NULL,
  updated datetime default NULL,
  PRIMARY KEY (id)
) DEFAULT CHARSET=utf8;
CREATE TABLE IF NOT EXISTS crowdsec_action (
  id int(11) unsigned NOT NULL auto_increment,
  action enum('delete_ip') NOT NULL default 'delete_ip',
  value varchar(64) NOT NULL default '',
  status enum('pending','done','error') NOT NULL default 'pending',
  result varchar(255) default NULL,
  created datetime default NULL,
  processed datetime default NULL,
  PRIMARY KEY (id)
) DEFAULT CHARSET=utf8;
CREATE TABLE IF NOT EXISTS crowdsec_origin (
  origin varchar(32) NOT NULL,
  cnt int(11) NOT NULL default 0,
  updated datetime default NULL,
  PRIMARY KEY (origin)
) DEFAULT CHARSET=utf8;
SQL

	local IFc=/usr/local/ispconfig/interface/web/admin
	local okphp=1
	php -l "$base/admin/crowdsec_list.php" >/dev/null 2>&1 || okphp=0
	php -l "$base/ss-crowdsec-sync.php"    >/dev/null 2>&1 || okphp=0
	if ((okphp)); then
		install -o ispconfig -g ispconfig -m 644 "$base/admin/crowdsec_list.php" "$IFc/" 2>>"$SETUP_LOG"
		install -o ispconfig -g ispconfig -m 644 "$base/admin/lib/lang/"*_crowdsec.lng "$IFc/lib/lang/" 2>>"$SETUP_LOG"
		mkdir -p /usr/local/ispconfig/server/scripts
		install -o root -g root -m 750 "$base/ss-crowdsec-sync.php" /usr/local/ispconfig/server/scripts/ss-crowdsec-sync.php
		cat > /etc/cron.d/ss-crowdsec-panel <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# luckystack: синхронизация CrowdSec ↔ панель ISPConfig (активные решения + очередь снятия)
* * * * * root /usr/bin/php /usr/local/ispconfig/server/scripts/ss-crowdsec-sync.php >/dev/null 2>&1
CRON
		chmod 644 /etc/cron.d/ss-crowdsec-panel
		[[ -x /usr/bin/php ]] && /usr/bin/php /usr/local/ispconfig/server/scripts/ss-crowdsec-sync.php >>"$SETUP_LOG" 2>&1 || true
		ui_success "Панель CrowdSec развёрнута (меню «Дополнения» → CrowdSec; кэш решений + очередь снятия + cron)."
	else
		ui_warn "php -l страниц CrowdSec не прошёл — панель не развёрнута."
	fi
}

# Per-site реальные IP для CrowdSec: добавить companion `access_log .../crowdsec.log crowdsec_realip;`
# в АКТИВНЫЙ vhost-шаблон ISPConfig. ISPConfig берёт conf-custom/install/ если есть, иначе conf/ (сток).
# conf-custom-ассет уже содержит crowdsec.log → там гард пропустит; сток патчим здесь. Иначе CrowdSec
# видит по сайтам только анонимизир. лог (а после фикса — вообще ничего, т.к. читаем crowdsec.log).
# Наши панели отдельной группой в меню: файл в admin/lib/menu.d. Он переживает обновление ISPConfig,
# поэтому module.conf.php больше не правим. Старые вставки оттуда убираем.
_ispc_menu_deploy() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	local adm=/usr/local/ispconfig/interface/web/admin src tmp node=n comp=n
	src="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/common/ss_panels.menu.php"
	[[ -d "$adm/lib" && -f "$src" ]] || return 0
	command -v node >/dev/null 2>&1 && node=y
	command -v composer >/dev/null 2>&1 && comp=y
	tmp="$(mktemp)"
	sed -e "s/@@NODE@@/${node}/" -e "s/@@COMPOSER@@/${comp}/" "$src" >"$tmp"
	if ! php -l "$tmp" >/dev/null 2>&1; then
		rm -f "$tmp"; ui_warn "Меню наших панелей: php -l не прошёл, файл не обновлён."; return 1
	fi
	mkdir -p "$adm/lib/menu.d"
	chown ispconfig:ispconfig "$adm/lib/menu.d" 2>/dev/null
	install -o ispconfig -g ispconfig -m 644 "$tmp" "$adm/lib/menu.d/ss_panels.menu.php"
	rm -f "$tmp"

	local mc="$adm/lib/module.conf.php"
	[[ -f "$mc" ]] || return 0
	cp -a "$mc" "$mc.ssbak"
	awk '
		BEGIN {
			n = split("Server maintenance|ss_maint;Notifications|notify_settings;Backup / Restore|backup_restore_list;Firewall IP-rules|firewall_restrict_list;Firewall block-list|ufw_block_list;Trusted IPs|trusted_ips;CrowdSec|crowdsec_list;Fail2ban|fail2ban_list;Node.js|node_apps;Composer|composer_apps", p, ";")
			for (i = 1; i <= n; i++) { split(p[i], kv, "|"); T[i] = kv[1]; H[i] = kv[2] }
		}
		skip != "" { if (index($0, skip "\x27);")) skip = ""; next }
		/^\$items\[\] = array\(/ {
			for (i = 1; i <= n; i++) if (index($0, "=> \x27" T[i] "\x27,")) { skip = H[i]; next }
		}
		{ print }
	' "$mc" >"$mc.new" && mv_keep "$mc.new" "$mc"
	chown ispconfig:ispconfig "$mc" 2>/dev/null
	if php -l "$mc" >/dev/null 2>&1; then rm -f "$mc.ssbak"; else mv -f "$mc.ssbak" "$mc"; ui_warn "module.conf.php: php -l не прошёл, откатил."; fi
	# от прежних версий установщика остались копии рядом с файлом
	rm -f "$mc".*bak "$mc.new"
	return 0
}

# Сбросить opcache интерфейса ISPConfig, перезагрузив его php-fpm пул. Без этого новые пункты меню
# (правки module.conf.php) и файлы страниц панелей не видны, пока opcache отдаёт старую версию — типовой
# симптом «панель не появилась после --update». Находим версию php по пулу ispconfig.conf. Идемпотентно.
_ispc_interface_php_reload() {
	local pool ver svc
	pool="$(ls /etc/php/*/fpm/pool.d/ispconfig.conf 2>/dev/null | head -1)"
	[[ -n "$pool" ]] || { log "ispconfig: пул ispconfig.conf не найден — opcache не сбрасываю"; return 0; }
	ver="$(printf '%s\n' "$pool" | sed -n 's#^/etc/php/\([0-9.]\+\)/fpm/.*#\1#p')"
	[[ -n "$ver" ]] || return 0
	svc="php${ver}-fpm"
	if systemctl reload "$svc" >>"$SETUP_LOG" 2>&1 || systemctl restart "$svc" >>"$SETUP_LOG" 2>&1; then
		log "ispconfig: $svc перезагружен (opcache сброшен — пункты меню/страницы панелей применились)"
	fi
}

# Панель «Node.js / Composer»: управление пакетами по сайтам. Интерфейс (ispconfig) не может ни
# читать файлы сайтов (0710), ни запускать npm/composer от юзера сайта → очередь nodecomposer_action +
# root-cron ss-nodecomposer-sync.php (su - webX, валидация). Пункты меню показываем ТОЛЬКО если
# node/composer реально установлены. Гейт ISPC_NODECOMPOSER_PANEL=y.
_ispconfig_deploy_nodecomposer_panel() {
	[[ "${ISPC_NODECOMPOSER_PANEL:-y}" == "y" ]] || return 0
	[[ -d /usr/local/ispconfig/interface/web/admin ]] || return 0
	_ispconfig_deploy_panel_common || { ui_warn "Общая часть панелей не установилась — панель пропущена."; return 0; }
	local have_node=0 have_comp=0
	command -v node >/dev/null 2>&1 && have_node=1
	{ command -v composer >/dev/null 2>&1 || [[ -x /usr/local/bin/composer ]]; } && have_comp=1
	(( have_node || have_comp )) || { log "nodecomposer: ни node, ни composer — панель не ставим"; return 0; }
	ui_step "Панель Node.js / Composer (пакеты по сайтам)"
	local base="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/nodecomposer-panel"
	[[ -d "$base" ]] || { ui_warn "assets nodecomposer-panel не найдены — пропуск."; return 0; }

	_ispc_mysql <<'SQL' >>"$SETUP_LOG" 2>&1 || true
CREATE TABLE IF NOT EXISTS nodecomposer_action (
  id int(11) unsigned NOT NULL auto_increment,
  tool enum('node','composer') NOT NULL default 'node',
  action varchar(24) NOT NULL default '',
  domain_id int(11) unsigned NOT NULL default 0,
  relpath varchar(255) NOT NULL default 'web',
  package varchar(255) default NULL,
  status enum('pending','running','done','error') NOT NULL default 'pending',
  result mediumtext,
  created datetime default NULL,
  processed datetime default NULL,
  PRIMARY KEY (id)
) DEFAULT CHARSET=utf8;
CREATE TABLE IF NOT EXISTS nodecomposer_pkg (
  id int(11) unsigned NOT NULL auto_increment,
  domain_id int(11) unsigned NOT NULL default 0,
  tool enum('node','composer') NOT NULL default 'node',
  relpath varchar(255) NOT NULL default 'web',
  name varchar(128) NOT NULL default '',
  version varchar(64) default NULL,
  updated datetime default NULL,
  PRIMARY KEY (id),
  KEY idx_proj (domain_id,tool,relpath)
) DEFAULT CHARSET=utf8;
SQL

	local IFc=/usr/local/ispconfig/interface/web/admin okphp=1
	php -l "$base/admin/nodecomposer.php"   >/dev/null 2>&1 || okphp=0
	php -l "$base/ss-nodecomposer-sync.php" >/dev/null 2>&1 || okphp=0
	if ((okphp)); then
		install -o ispconfig -g ispconfig -m 644 "$base/admin/nodecomposer.php" "$IFc/" 2>>"$SETUP_LOG"
		install -o ispconfig -g ispconfig -m 644 "$base/admin/lib/lang/"*_nodecomposer.lng "$IFc/lib/lang/" 2>>"$SETUP_LOG"
		mkdir -p /usr/local/ispconfig/server/scripts
		install -o root -g root -m 750 "$base/ss-nodecomposer-sync.php" /usr/local/ispconfig/server/scripts/ss-nodecomposer-sync.php
		cat > /etc/cron.d/ss-nodecomposer <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# luckystack: очередь Node/Composer ↔ панель ISPConfig (npm/composer от юзера сайта)
* * * * * root /usr/bin/php /usr/local/ispconfig/server/scripts/ss-nodecomposer-sync.php >/dev/null 2>&1
CRON
		chmod 644 /etc/cron.d/ss-nodecomposer
		[[ -x /usr/bin/php ]] && /usr/bin/php /usr/local/ispconfig/server/scripts/ss-nodecomposer-sync.php >>"$SETUP_LOG" 2>&1 || true
		ui_success "Панель Node.js/Composer развёрнута (меню «Дополнения»:${have_node:+ Node.js}${have_comp:+ Composer}; очередь + root-cron)."
	else
		ui_warn "php -l страниц Node/Composer не прошёл — панель не развёрнута."
	fi
}

# Панель «Уведомления»: настройки каналов (email/Telegram) + тест-отправка из ISPConfig.
# Интерфейс не root → очередь notify_job (save/test) + root-cron ss-notify-sync.php правит
# /etc/server-notify.conf и шлёт тест через server-notify.sh. Токен не кэшируется (write-only).
_ispconfig_deploy_notify_panel() {
	[[ "${ISPC_NOTIFY_PANEL:-y}" == "y" ]] || return 0
	[[ -d /usr/local/ispconfig/interface/web/admin ]] || return 0
	_ispconfig_deploy_panel_common || { ui_warn "Общая часть панелей не установилась — панель пропущена."; return 0; }
	ui_step "Панель «Уведомления» (email/Telegram + тест)"
	local base="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/notify-panel"
	[[ -d "$base" ]] || { ui_warn "assets notify-panel не найдены — пропуск."; return 0; }

	_ispc_mysql <<'SQL' >>"$SETUP_LOG" 2>&1 || true
CREATE TABLE IF NOT EXISTS notify_setting (
  name varchar(32) NOT NULL,
  value varchar(255) default NULL,
  updated datetime default NULL,
  PRIMARY KEY (name)
) DEFAULT CHARSET=utf8;
CREATE TABLE IF NOT EXISTS notify_job (
  id int(11) unsigned NOT NULL auto_increment,
  action enum('save','test','discover') NOT NULL default 'save',
  payload mediumtext,
  status enum('pending','running','done','error') NOT NULL default 'pending',
  result varchar(255) default NULL,
  created datetime default NULL,
  processed datetime default NULL,
  PRIMARY KEY (id)
) DEFAULT CHARSET=utf8;
SQL

	# Для уже созданных таблиц: длинные значения (список найденных чатов) и новое действие discover
	_ispc_mysql -e "ALTER TABLE notify_setting MODIFY value mediumtext; ALTER TABLE notify_job MODIFY action enum('save','test','discover') NOT NULL default 'save';" >>"$SETUP_LOG" 2>&1 || true

	# server-notify.sh должен существовать (шлёт по каналам). Если уведомления не настраивались —
	# ставим helper из lib/notify.sh; конфиг создастся при первом «Сохранить» из панели.
	if [[ ! -x /usr/local/sbin/server-notify.sh ]] && declare -F _notify_write_helper >/dev/null; then
		_notify_write_helper >>"$SETUP_LOG" 2>&1 && chmod 700 /usr/local/sbin/server-notify.sh 2>/dev/null && log "notify-panel: server-notify.sh установлен"
	fi

	local IFc=/usr/local/ispconfig/interface/web/admin okphp=1
	php -l "$base/admin/notify_settings.php" >/dev/null 2>&1 || okphp=0
	php -l "$base/ss-notify-sync.php"        >/dev/null 2>&1 || okphp=0
	if ((okphp)); then
		install -o ispconfig -g ispconfig -m 644 "$base/admin/notify_settings.php" "$IFc/" 2>>"$SETUP_LOG"
		install -o ispconfig -g ispconfig -m 644 "$base/admin/lib/lang/"*_notify.lng "$IFc/lib/lang/" 2>>"$SETUP_LOG"
		mkdir -p /usr/local/ispconfig/server/scripts
		install -o root -g root -m 750 "$base/ss-notify-sync.php" /usr/local/ispconfig/server/scripts/ss-notify-sync.php
		cat > /etc/cron.d/ss-notify-panel <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# luckystack: очередь Уведомлений ↔ панель ISPConfig (настройки + тест)
* * * * * root /usr/bin/php /usr/local/ispconfig/server/scripts/ss-notify-sync.php >/dev/null 2>&1
CRON
		chmod 644 /etc/cron.d/ss-notify-panel
		[[ -x /usr/bin/php ]] && /usr/bin/php /usr/local/ispconfig/server/scripts/ss-notify-sync.php >>"$SETUP_LOG" 2>&1 || true
		ui_success "Панель «Уведомления» развёрнута (меню «Дополнения» → Notifications; настройки + тест + cron)."
	else
		ui_warn "php -l страниц Уведомлений не прошёл — панель не развёрнута."
	fi
}

# Важно для всех /etc/cron.d/ss-*: без строки PATH cron запускает с /usr/bin:/bin, и ufw, ipset, sendmail
# из /usr/sbin не находятся. Вручную такие скрипты работают, поэтому ошибка незаметна.
# Панель «Обслуживание сервера»: состояние и проверки, запуск --update по списку пунктов,
# настройки установщика, журнал действий. Интерфейс (ispconfig) ставит задание в очередь, root-cron
# ss-maint-sync.php проверяет его и выполняет. Только для серверов, настроенных этим установщиком.
_ispconfig_deploy_maint_panel() {
	[[ "${ISPC_MAINT_PANEL:-y}" == "y" ]] || return 0
	[[ -d /usr/local/ispconfig/interface/web/admin ]] || return 0
	_ispconfig_deploy_panel_common || { ui_warn "Общая часть панелей не установилась — панель пропущена."; return 0; }
	ui_step "Панель «Обслуживание сервера»"
	local base="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/maint-panel"
	[[ -d "$base" ]] || { ui_warn "assets maint-panel не найдены — пропуск."; return 0; }

	_ispc_mysql <<'SQL' >>"$SETUP_LOG" 2>&1 || true
CREATE TABLE IF NOT EXISTS ss_maint_setting (
  name varchar(32) NOT NULL,
  value mediumtext,
  updated datetime default NULL,
  PRIMARY KEY (name)
) DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ss_maint_job (
  id int(11) unsigned NOT NULL auto_increment,
  action varchar(16) NOT NULL default '',
  payload mediumtext,
  status enum('pending','running','done','error') NOT NULL default 'pending',
  result varchar(255) default NULL,
  log mediumtext,
  created datetime default NULL,
  started datetime default NULL,
  processed datetime default NULL,
  PRIMARY KEY (id),
  KEY status (status)
) DEFAULT CHARSET=utf8mb4;
SQL

	local IFc=/usr/local/ispconfig/interface/web/admin scripts=/usr/local/ispconfig/server/scripts okphp=1
	php -l "$base/admin/ss_maint.php" >/dev/null 2>&1 || okphp=0
	php -l "$base/ss-maint-sync.php"  >/dev/null 2>&1 || okphp=0
	if ((okphp == 0)); then
		ui_warn "php -l страниц Обслуживания не прошёл — панель не развёрнута."
		return 0
	fi
	install -o ispconfig -g ispconfig -m 644 "$base/admin/ss_maint.php" "$IFc/" 2>>"$SETUP_LOG"
	install -o ispconfig -g ispconfig -m 644 "$base/admin/lib/lang/"*_ss_maint.lng "$IFc/lib/lang/" 2>>"$SETUP_LOG"
	mkdir -p "$scripts"
	install -o root -g root -m 750 "$base/ss-maint-sync.php" "$scripts/ss-maint-sync.php"
	# Где код, настройки и журнал. Файл доступен только root: cron запускает то, что здесь указано.
	if declare -F ls_update_maint_conf >/dev/null; then
		ls_update_maint_conf create
	else
		( umask 077; printf "INSTALLER_DIR='%s'\nSETUP_CONF='%s'\nSETUP_LOG='%s'\n" "${LS_OPT_DIR:-/opt/luckystack}/current" "$CONFIG_FILE" "$SETUP_LOG" >"$scripts/ss-maint.conf" )
		chown root:root "$scripts/ss-maint.conf"
	fi
	cat >/etc/cron.d/ss-maint-panel <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# luckystack: очередь панели «Обслуживание сервера»
* * * * * root /usr/bin/php /usr/local/ispconfig/server/scripts/ss-maint-sync.php >/dev/null 2>&1
CRON
	chmod 644 /etc/cron.d/ss-maint-panel
	ui_success "Панель «Обслуживание сервера» развёрнута (меню «Дополнения» → Server maintenance)."
}

# Панель «Firewall: блок-лист» — ручной ufw-deny для IP/подсетей + подсказки по подсетям-кластерам
# из CrowdSec. Интерфейс (ispconfig) не может дёргать ufw (root) → таблица ufw_block (желаемый
# список) + root-cron ss-ufwblock-sync.php реконсилит правила ufw и наполняет ufw_block_suggest.
# Зачем: crowdsec-firewall-bouncer НЕ применяет range-решения (кладёт CIDR как одиночный адрес) —
# подсети режем через ufw (нативный CIDR). Гейт: ufw установлен. Переживает обновление ISPConfig
# (переналив в --update). Вызывается из stage_ispconfig (8.17) и из --update.
_ispconfig_deploy_ufwblock_panel() {
	[[ "${ISPC_UFWBLOCK_PANEL:-y}" == "y" ]] || return 0
	[[ -d /usr/local/ispconfig/interface/web/admin ]] || return 0
	_ispconfig_deploy_panel_common || { ui_warn "Общая часть панелей не установилась — панель пропущена."; return 0; }
	command -v ufw >/dev/null 2>&1 || { log "ufwblock-panel: ufw нет — пропуск"; return 0; }
	ui_step "Панель «Firewall: блок-лист» (ufw-deny IP/подсетей + подсказки)"
	local base="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/ufwblock-panel"
	[[ -d "$base" ]] || { ui_warn "assets ufwblock-panel не найдены — пропуск."; return 0; }

	_ispc_mysql <<'SQL' >>"$SETUP_LOG" 2>&1 || true
CREATE TABLE IF NOT EXISTS ufw_block (
  id int(11) unsigned NOT NULL auto_increment,
  target varchar(64) NOT NULL default '',
  comment varchar(128) default NULL,
  active enum('y','n') NOT NULL default 'y',
  applied enum('y','n') NOT NULL default 'n',
  created datetime default NULL,
  updated datetime default NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_target (target)
) DEFAULT CHARSET=utf8;
CREATE TABLE IF NOT EXISTS ufw_block_suggest (
  subnet varchar(32) NOT NULL,
  ip_count int(11) NOT NULL default 0,
  sample varchar(255) default NULL,
  updated datetime default NULL,
  PRIMARY KEY (subnet)
) DEFAULT CHARSET=utf8;
SQL

	local IFc=/usr/local/ispconfig/interface/web/admin okphp=1
	php -l "$base/admin/ufw_block_list.php" >/dev/null 2>&1 || okphp=0
	php -l "$base/ss-ufwblock-sync.php"     >/dev/null 2>&1 || okphp=0
	if ((okphp)); then
		install -o ispconfig -g ispconfig -m 644 "$base/admin/ufw_block_list.php" "$IFc/" 2>>"$SETUP_LOG"
		install -o ispconfig -g ispconfig -m 644 "$base/admin/lib/lang/"*_ufw_block_list.lng "$IFc/lib/lang/" 2>>"$SETUP_LOG"
		mkdir -p /usr/local/ispconfig/server/scripts
		install -o root -g root -m 750 "$base/ss-ufwblock-sync.php" /usr/local/ispconfig/server/scripts/ss-ufwblock-sync.php
		cat > /etc/cron.d/ss-ufwblock-panel <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# luckystack: реконсиляция блок-листа ufw ↔ панель ISPConfig (+ подсказки-кластеры CrowdSec)
* * * * * root /usr/bin/php /usr/local/ispconfig/server/scripts/ss-ufwblock-sync.php >/dev/null 2>&1
CRON
		chmod 644 /etc/cron.d/ss-ufwblock-panel
		[[ -x /usr/bin/php ]] && /usr/bin/php /usr/local/ispconfig/server/scripts/ss-ufwblock-sync.php >>"$SETUP_LOG" 2>&1 || true
		ui_success "Панель «Firewall: блок-лист» развёрнута (меню «Дополнения» → Firewall block-list; ufw-deny + подсказки + cron)."
	else
		ui_warn "php -l страниц блок-листа ufw не прошёл — панель не развёрнута."
	fi
}

# Панель «Доверенные IP»: один список IP/подсетей, которые не банятся. Root-cron
# ss-trusted-sync.php применяет его к CrowdSec (allowlist luckystack-trusted) и fail2ban
# (ignoreip), снимает уже стоящие баны, чистит истёкшие записи и выполняет проверки «где
# забанен IP». При установке в список попадают админские IP из setup.conf и IP самого сервера
# (почта и сайты ходят к себе по внешнему адресу). Гейт: есть cscli или fail2ban-client.
# Вызывается из stage_ispconfig (8.17b) и из --update.
_ispconfig_deploy_trusted_panel() {
	[[ "${ISPC_TRUSTED_PANEL:-y}" == "y" ]] || return 0
	[[ -d /usr/local/ispconfig/interface/web/admin ]] || return 0
	{ command -v cscli >/dev/null 2>&1 || command -v fail2ban-client >/dev/null 2>&1; } || { log "trusted-panel: нет ни CrowdSec, ни fail2ban — пропуск"; return 0; }
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} панель «Доверенные IP» (CrowdSec allowlist + fail2ban ignoreip)"; return 0; }
	_ispconfig_deploy_panel_common || { ui_warn "Общая часть панелей не установилась — панель пропущена."; return 0; }
	ui_step "Панель «Доверенные IP» (CrowdSec allowlist + fail2ban ignoreip)"
	local base="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/trusted-panel"
	[[ -d "$base" ]] || { ui_warn "assets trusted-panel не найдены — пропуск."; return 0; }

	_ispc_mysql <<'SQL' >>"$SETUP_LOG" 2>&1 || true
CREATE TABLE IF NOT EXISTS ss_trusted_ip (
  id int(11) unsigned NOT NULL auto_increment,
  target varchar(64) NOT NULL default '',
  comment varchar(128) NOT NULL default '',
  expires datetime default NULL,
  source enum('panel','install') NOT NULL default 'panel',
  created datetime default NULL,
  created_by varchar(64) NOT NULL default '',
  applied enum('y','n') NOT NULL default 'n',
  applied_at datetime default NULL,
  note varchar(255) default NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_target (target)
) DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ss_trusted_job (
  id int(11) unsigned NOT NULL auto_increment,
  ip varchar(45) NOT NULL default '',
  status enum('pending','done','error') NOT NULL default 'pending',
  result mediumtext,
  created datetime default NULL,
  processed datetime default NULL,
  PRIMARY KEY (id)
) DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ss_trusted_state (
  name varchar(32) NOT NULL,
  value mediumtext,
  updated datetime default NULL,
  PRIMARY KEY (name)
) DEFAULT CHARSET=utf8mb4;
SQL

	# начальное наполнение: админские IP и IP сервера (INSERT IGNORE — существующие не трогаем)
	local ip seen=" " srv
	for ip in ${ISPCONFIG_ADMIN_IPS:-} ${SSH_ALLOW_IPS:-}; do
		[[ "$ip" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || continue
		[[ "$seen" == *" $ip "* ]] && continue; seen+="$ip "
		_ispc_mysql -e "INSERT IGNORE INTO ss_trusted_ip (target, comment, source, created, created_by) VALUES ('$ip', 'Админ (из настроек установки)', 'install', NOW(), 'LuckyStack');" >>"$SETUP_LOG" 2>&1 || true
	done
	srv="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -o 'src [0-9.]*' | awk '{print $2}')"
	if [[ "$srv" =~ ^[0-9.]+$ && "$seen" != *" $srv "* ]]; then
		_ispc_mysql -e "INSERT IGNORE INTO ss_trusted_ip (target, comment, source, created, created_by) VALUES ('$srv', 'Сам сервер: почта и сайты ходят к себе по внешнему адресу', 'install', NOW(), 'LuckyStack');" >>"$SETUP_LOG" 2>&1 || true
	fi

	local IFc=/usr/local/ispconfig/interface/web/admin okphp=1
	php -l "$base/admin/trusted_ips.php" >/dev/null 2>&1 || okphp=0
	php -l "$base/ss-trusted-sync.php"   >/dev/null 2>&1 || okphp=0
	if ((okphp)); then
		install -o ispconfig -g ispconfig -m 644 "$base/admin/trusted_ips.php" "$IFc/" 2>>"$SETUP_LOG"
		install -o ispconfig -g ispconfig -m 644 "$base/admin/lib/lang/"*_trusted_ips.lng "$IFc/lib/lang/" 2>>"$SETUP_LOG"
		mkdir -p /usr/local/ispconfig/server/scripts
		install -o root -g root -m 750 "$base/ss-trusted-sync.php" /usr/local/ispconfig/server/scripts/ss-trusted-sync.php
		cat > /etc/cron.d/ss-trusted-panel <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# luckystack: «Доверенные IP» из панели ISPConfig → CrowdSec allowlist + fail2ban ignoreip
* * * * * root /usr/bin/php /usr/local/ispconfig/server/scripts/ss-trusted-sync.php >/dev/null 2>&1
CRON
		chmod 644 /etc/cron.d/ss-trusted-panel
		[[ -x /usr/bin/php ]] && /usr/bin/php /usr/local/ispconfig/server/scripts/ss-trusted-sync.php >>"$SETUP_LOG" 2>&1 || true
		ui_success "Панель «Доверенные IP» развёрнута (меню «Дополнения» → Trusted IPs; CrowdSec allowlist + fail2ban ignoreip + cron)."
	else
		ui_warn "php -l страниц «Доверенные IP» не прошёл — панель не развёрнута."
	fi
}

# Формат crowdsec_realip определён в nginx.conf (http{}). Гейт: nginx + cscli (FIREWALL=crowdsec).
# Существующие сайты подхватят строку при ISPConfig Resync/правке (или принудит. resync — отдельно).
# Идемпотентно; вызывается из stage_ispconfig (после conf-custom) и из --update (сток затирается апдейтом).
_ispconfig_crowdsec_vhost_log() {
	command -v cscli >/dev/null 2>&1 || return 0
	[[ "${WEBSERVER:-nginx}" == "apache" ]] && return 0
	# РАНТАЙМ-шаблон vhost берётся плагином из conf-custom/ (если есть), иначе conf/ (сток).
	# НЕ путать с conf-custom/install/ — это шаблоны для УСТАНОВЩИКА, не для генерации vhost.
	local cc=/usr/local/ispconfig/server/conf-custom/nginx_vhost.conf.master
	local st=/usr/local/ispconfig/server/conf/nginx_vhost.conf.master
	local tpl=""
	[[ -f "$cc" ]] && tpl="$cc" || { [[ -f "$st" ]] && tpl="$st"; }
	[[ -n "$tpl" ]] || return 0
	if grep -q "crowdsec.log" "$tpl"; then log "crowdsec: vhost-шаблон уже с crowdsec.log (${tpl})"; return 0; fi
	cp -a "$tpl" "$tpl.csbak"
	# После каждой строки `access_log .../access.log (combined|anonymized);` добавить companion
	# с реальным IP в ЕДИНЫЙ /var/log/nginx/crowdsec.log (общий для ВСЕХ сайтов — CrowdSec тейлит
	# один стабильный файл, новые сайты подхватываются автоматически, без glob/рестартов).
	awk '
		{ print }
		/access_log .*\/access\.log (combined|anonymized);/ {
			c=$0
			sub(/access_log .*/, "access_log /var/log/nginx/crowdsec.log crowdsec_realip;", c)
			print c
		}
	' "$tpl" >"$tpl.new" && mv_keep "$tpl.new" "$tpl"
	if grep -q "crowdsec.log" "$tpl"; then
		ui_info "CrowdSec: в vhost-шаблон добавлен per-site crowdsec.log (${tpl}). Существующие сайты — после ISPConfig Resync."
		log "crowdsec: patched vhost template ${tpl} (per-site crowdsec.log)"
	else
		mv -f "$tpl.csbak" "$tpl"; ui_warn "CrowdSec: не удалось пропатчить vhost-шаблон (формат строки access_log иной) — пропуск."
	fi
}

# Миграция СУЩЕСТВУЮЩИХ сайтов на единый /var/log/nginx/crowdsec.log (Вариант A). Переправляем
# строку `access_log …/httpd/<site>/crowdsec.log crowdsec_realip;` в готовых nginx-vhost'ах на
# общий путь — БЕЗ ISPConfig resync (уникальные директивы/данные сайтов НЕ трогаем, меняем только
# строку лога). Идемпотентно. На чистой установке vhost'ов ещё нет → no-op. Вызов: stage + --update.
_ispconfig_crowdsec_shared_migrate() {
	command -v cscli >/dev/null 2>&1 || return 0
	[[ "${WEBSERVER:-nginx}" == "apache" ]] && return 0
	# 1) РАНТАЙМ-шаблоны (чтобы НОВЫЕ/пересозданные сайты шли в общий лог). Внутри пути есть
	#    <tmpl_var name='domain'> с пробелом → матчим до ';' ([^;]*), а не до пробела.
	local t
	for t in /usr/local/ispconfig/server/conf-custom/nginx_vhost.conf.master /usr/local/ispconfig/server/conf/nginx_vhost.conf.master; do
		[[ -f "$t" ]] || continue
		grep -q 'httpd/[^;]*crowdsec\.log crowdsec_realip' "$t" || continue
		sed -i -E 's#access_log [^;]*httpd/[^;]*crowdsec\.log crowdsec_realip;#access_log /var/log/nginx/crowdsec.log crowdsec_realip;#g' "$t"
	done
	# 2) Существующие СГЕНЕРИРОВАННЫЕ vhost'ы (путь уже с реальным доменом, без пробела)
	local d=/etc/nginx/sites-available changed=0 f
	[[ -d "$d" ]] || return 0
	shopt -s nullglob
	for f in "$d"/*.vhost; do
		grep -q 'httpd/[^;]*crowdsec\.log crowdsec_realip' "$f" || continue
		sed -i -E 's#access_log [^;]*httpd/[^;]*crowdsec\.log crowdsec_realip;#access_log /var/log/nginx/crowdsec.log crowdsec_realip;#g' "$f"
		changed=1
	done
	shopt -u nullglob
	if (( changed )); then
		if nginx -t >>"$SETUP_LOG" 2>&1; then
			systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
			ui_success "CrowdSec: существующие сайты переведены на единый /var/log/nginx/crowdsec.log (без resync — данные сайтов не тронуты)."
		else
			ui_warn "CrowdSec: nginx -t не прошёл после правки vhost'ов — см. ${SETUP_LOG} (изменения в /etc/nginx/sites-available/*.vhost)."
		fi
		# per-site crowdsec-логи больше не пишутся → их отдельный logrotate не нужен
		# (единый /var/log/nginx/crowdsec.log ротируется штатным logrotate nginx).
		rm -f /etc/logrotate.d/crowdsec-realip 2>/dev/null || true
		# у замороженных сайтов текст vhost живёт в базе: забрать туда же правку файлов,
		# иначе следующее сохранение сайта вернёт старый путь лога
		declare -F _ispconfig_freeze_drift_import >/dev/null && _ispconfig_freeze_drift_import
	fi
}

# Засеять таблицу firewall_restrict нашими установочными IP-ограничениями, чтобы они
# были видны/правились в панели (модуль «Firewall IP-rules»). Те же источники, что у
# _security_ufw_restrict_persist (setup.conf): SSH (22 и SSH_PORT → SSH_ALLOW_IPS + IP
# текущей сессии), панель (ISPCONFIG_PANEL_PORT → ISPCONFIG_ADMIN_IPS), MySQL (3306 →
# MARIADB_REMOTE_IPS, если MARIADB_REMOTE=y). Идемпотентно: одно правило на server_id+proto+
# port; повторный прогон НЕ трогает уже существующее (чтобы не затирать ручные правки в панели).
# UDP-открытия (HTTP/3) сюда НЕ заносим — они «всем», а модуль про «только этим IP».
_ispconfig_seed_firewall_rules() {
	command -v mysql >/dev/null 2>&1 || return 0
	_ispc_mysql -e "SELECT 1;" >/dev/null 2>&1 || return 0

	# server_id, под которым крутится этот узел (обычно 1)
	local sid
	sid="$(_ispc_mysql -N -B -e "SELECT server_id FROM server ORDER BY server_id LIMIT 1;" 2>/dev/null)"
	[[ "$sid" =~ ^[0-9]+$ ]] || sid=1

	# текущий IP SSH-сессии — чтобы автор не отрезал себя
	local cur_ip; declare -F _detect_ssh_ip >/dev/null && cur_ip="$(_detect_ssh_ip 2>/dev/null)"

	# собрать список: "proto|port|ips|описание"
	local -a seeds=()
	local ssh_ips="${SSH_ALLOW_IPS:-}"
	if [[ -n "$cur_ip" && " $ssh_ips " != *" $cur_ip "* ]]; then
		ssh_ips="${ssh_ips:+$ssh_ips }$cur_ip"
		ui_info "В правила SSH и панели добавлен ваш текущий IP ${cur_ip}, чтобы не отрезать себя. Если адрес временный, уберите его потом в панели: System → Firewall IP-rules."
	fi
	if [[ -n "$ssh_ips" ]]; then
		seeds+=("tcp|22|${ssh_ips}|SSH — админы")
		[[ -n "${SSH_PORT:-}" && "$SSH_PORT" != "22" ]] && seeds+=("tcp|${SSH_PORT}|${ssh_ips}|SSH — админы")
	fi
	if [[ -n "${ISPCONFIG_ADMIN_IPS:-}" ]]; then
		# текущий адрес добавляем, только если его ещё нет в списке
		local panel_ips="$ISPCONFIG_ADMIN_IPS"
		[[ -n "$cur_ip" && " $panel_ips " != *" $cur_ip "* ]] && panel_ips+=" $cur_ip"
		seeds+=("tcp|${ISPCONFIG_PANEL_PORT:-8080}|${panel_ips}|Панель ISPConfig — админы")
		# панель по HTTP/3 — тот же порт по UDP; ОБЯЗАТЕЛЬНО ограничиваем теми же IP, иначе
		# QUIC-доступ к панели обошёл бы IP-ограничение TCP.
		[[ "${PANEL_HTTP3:-n}" == "y" ]] && seeds+=("udp|${ISPCONFIG_PANEL_PORT:-8080}|${panel_ips}|Панель ISPConfig (HTTP/3) — админы")
	fi
	[[ "${MARIADB_REMOTE:-n}" == "y" && -n "${MARIADB_REMOTE_IPS:-}" ]] && seeds+=("tcp|3306|${MARIADB_REMOTE_IPS}|MySQL — удалённый доступ")

	((${#seeds[@]} == 0)) && { ui_info "Списки IP в setup.conf пусты — в панель Firewall ничего не засеяно."; return 0; }

	local s proto port ips desc esc_ips esc_desc n=0
	for s in "${seeds[@]}"; do
		IFS='|' read -r proto port ips desc <<<"$s"
		# нормализуем IP (через запятую — как ждёт форма) и экранируем для SQL
		ips="$(printf '%s' "$ips" | tr -s ' ' | sed 's/^ //; s/ $//; s/ /, /g')"
		esc_ips="${ips//\'/\'\'}"; esc_desc="${desc//\'/\'\'}"
		# идемпотентно: вставляем только если правила на этот server_id+proto+port ещё нет
		_ispc_mysql >>"$SETUP_LOG" 2>&1 <<SQL || true
INSERT INTO firewall_restrict
  (sys_userid, sys_groupid, sys_perm_user, sys_perm_group, sys_perm_other,
   server_id, proto, port, allowed_ips, description, active)
SELECT 1, 1, 'riud', 'riud', '', ${sid}, '${proto}', '${port}', '${esc_ips}', '${esc_desc}', 'y'
FROM dual
WHERE NOT EXISTS (
  SELECT 1 FROM firewall_restrict WHERE server_id=${sid} AND proto='${proto}' AND port='${port}'
);
SQL
		n=$((n+1))
	done
	ui_info "В панель Firewall засеяно правил-источников: ${n} (SSH/панель${MARIADB_REMOTE:+/MySQL}). Существующие не тронуты."
}

# true, если родной firewall ISPConfig ещё «активен» (его движок не перехвачен нами).
_ispc_native_fw_active() {
	command -v mysql >/dev/null 2>&1 || return 1
	local a; a="$(_ispc_mysql -N -B -e "SELECT active FROM firewall WHERE active='y' LIMIT 1;" 2>/dev/null)"
	[[ "$a" == "y" ]]
}

# Человекочитаемое имя для известного порта (для описаний в панели).
_fw_port_name() {
	case "$1" in
		20|21) echo "FTP";; 22) echo "SSH";; 25) echo "SMTP";; 53) echo "DNS";;
		80) echo "HTTP";; 110) echo "POP3";; 143) echo "IMAP";; 443) echo "HTTPS";;
		465) echo "SMTPS";; 587) echo "Submission";; 993) echo "IMAPS";; 995) echo "POP3S";;
		4190) echo "ManageSieve";; 8080|8081) echo "ISPConfig (apps)";;
		40110:40210) echo "FTP passive";;
		*) echo "Публичный порт";;
	esac
}

# Перенести публичные порты родного firewall (tcp_port/udp_port → открыты ВСЕМ) в нашу
# таблицу как allow_all='y'. Идемпотентно по server_id+proto+port: уже существующие
# (в т.ч. наши IP-ограничения SSH/панель/MySQL) НЕ трогаются — так публичный 22/3333 не
# перекроет IP-ограниченный. Диапазоны (40110:40210) сохраняются как есть.
_ispconfig_seed_public_ports() {
	command -v mysql >/dev/null 2>&1 || return 0
	_ispc_mysql -e "SELECT 1;" >/dev/null 2>&1 || return 0
	local sid; sid="$(_ispc_mysql -N -B -e "SELECT server_id FROM server ORDER BY server_id LIMIT 1;" 2>/dev/null)"
	[[ "$sid" =~ ^[0-9]+$ ]] || sid=1

	local proto list p desc n=0
	local tcp udp
	tcp="$(_ispc_mysql -N -B -e "SELECT tcp_port FROM firewall WHERE server_id=${sid} LIMIT 1;" 2>/dev/null)"
	udp="$(_ispc_mysql -N -B -e "SELECT udp_port FROM firewall WHERE server_id=${sid} LIMIT 1;" 2>/dev/null)"
	for proto in tcp udp; do
		[[ "$proto" == tcp ]] && list="$tcp" || list="$udp"
		[[ -n "$list" ]] || continue
		local -a arr=(); IFS=',' read -ra arr <<<"$list"
		for p in "${arr[@]}"; do
			p="${p//[[:space:]]/}"
			[[ "$p" =~ ^[0-9]{1,5}(:[0-9]{1,5})?$ ]] || continue
			desc="$(_fw_port_name "$p")"
			_ispc_mysql >>"$SETUP_LOG" 2>&1 <<SQL || true
INSERT INTO firewall_restrict
  (sys_userid, sys_groupid, sys_perm_user, sys_perm_group, sys_perm_other,
   server_id, proto, port, allowed_ips, allow_all, description, active)
SELECT 1, 1, 'riud', 'riud', '', ${sid}, '${proto}', '${p}', '', 'y', '${desc}', 'y'
FROM dual
WHERE NOT EXISTS (
  SELECT 1 FROM firewall_restrict WHERE server_id=${sid} AND proto='${proto}' AND port='${p}'
);
SQL
			n=$((n+1))
		done
	done

	# HTTP/3 идёт по UDP — родной firewall обычно не держит эти udp-порты в списке,
	# поэтому добавим ПУБЛИЧНЫЕ HTTP/3-порты явно: 443 (сайты) + apps при PANEL_HTTP3.
	# Панель (её udp) НЕ здесь — она ограничена по IP в _ispconfig_seed_firewall_rules.
	if [[ "${NGX_HTTP3:-${HTTP3:-n}}" == "y" && "${WEBSERVER:-nginx}" == "nginx" ]]; then
		local -a u3=("443|HTTPS (HTTP/3)")
		[[ "${PANEL_HTTP3:-n}" == "y" ]] && u3+=("${ISPCONFIG_APPS_PORT:-8081}|ISPConfig apps (HTTP/3)")
		local spec pp pd
		for spec in "${u3[@]}"; do
			pp="${spec%%|*}"; pd="${spec#*|}"
			[[ "$pp" =~ ^[0-9]{1,5}$ ]] || continue
			_ispc_mysql >>"$SETUP_LOG" 2>&1 <<SQL || true
INSERT INTO firewall_restrict
  (sys_userid, sys_groupid, sys_perm_user, sys_perm_group, sys_perm_other,
   server_id, proto, port, allowed_ips, allow_all, description, active)
SELECT 1, 1, 'riud', 'riud', '', ${sid}, 'udp', '${pp}', '', 'y', '${pd}', 'y'
FROM dual
WHERE NOT EXISTS (
  SELECT 1 FROM firewall_restrict WHERE server_id=${sid} AND proto='udp' AND port='${pp}'
);
SQL
			n=$((n+1))
		done
	fi
	ui_info "Публичные порты родного firewall занесены в панель (allow_all): обработано ${n}. Уже существующие/ограниченные не тронуты."
}

# Пересобрать /etc/ufw/before.rules из таблицы firewall_restrict через серверный плагин
# (bootstrap $app — как это делает server.sh по событию). Безопасно/идемпотентно.
_ispconfig_fw_rebuild() {
	[[ -f /usr/local/ispconfig/server/plugins-available/firewall_restrict_plugin.inc.php ]] || return 0
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || return 0
	command -v php >/dev/null 2>&1 || return 0
	php -r '$conf=array(); require "/usr/local/ispconfig/server/lib/config.inc.php"; require "/usr/local/ispconfig/server/lib/app.inc.php"; require "/usr/local/ispconfig/server/plugins-available/firewall_restrict_plugin.inc.php"; $p=new firewall_restrict_plugin(); $p->rebuild("deploy", array());' >>"$SETUP_LOG" 2>&1 || true
}

# Перехватить движок firewall у родного ISPConfig (единый движок = наш модуль). Только при
# первом заходе (родной active=y). Порядок безопасен (без разрыва доступа):
#   1) before.rules уже собран из таблицы (_ispconfig_fw_rebuild вызван до нас) — все порты
#      уже открыты в цепочке ufw-before-input (срабатывает РАНЬШЕ user.rules);
#   2) вычищаем user.rules родного firewall (ufw delete allow PORT) — доступ не рвётся;
#   3) гасим родной firewall в БД НАПРЯМУЮ (active=n). Прямой UPDATE, БЕЗ сохранения через
#      панель — иначе сработал бы плагин родного firewall, а он на active=n делает `ufw disable`
#      (вырубил бы фаервол целиком). SSH (наш порт) уже в before.rules → не отрежемся.
_ispconfig_takeover_native_firewall() {
	command -v ufw >/dev/null 2>&1 || return 0
	command -v mysql >/dev/null 2>&1 || return 0
	[[ -f /usr/local/ispconfig/server/plugins-available/firewall_restrict_plugin.inc.php ]] || return 0
	_ispc_native_fw_active || { ui_info "Родной firewall уже погашен — takeover пропущен."; return 0; }

	# страховка: before.rules ДОЛЖЕН содержать наш блок (порты открыты) перед чисткой user.rules
	if ! grep -q 'luckystack: restrict-isp START' /etc/ufw/before.rules 2>/dev/null; then
		ui_warn "before.rules не собран — родной firewall НЕ гашу (риск отрезать порты)."
		return 0
	fi

	local sid; sid="$(_ispc_mysql -N -B -e "SELECT server_id FROM server ORDER BY server_id LIMIT 1;" 2>/dev/null)"
	[[ "$sid" =~ ^[0-9]+$ ]] || sid=1

	ui_step "Перехват firewall у родного ISPConfig (единый движок — модуль «Firewall IP-rules»)"
	local tcp udp p
	tcp="$(_ispc_mysql -N -B -e "SELECT tcp_port FROM firewall WHERE server_id=${sid} LIMIT 1;" 2>/dev/null)"
	udp="$(_ispc_mysql -N -B -e "SELECT udp_port FROM firewall WHERE server_id=${sid} LIMIT 1;" 2>/dev/null)"
	local -a arr=()
	IFS=',' read -ra arr <<<"$tcp"; for p in "${arr[@]}"; do p="${p//[[:space:]]/}"; [[ -n "$p" ]] && ufw delete allow "${p}/tcp" >>"$SETUP_LOG" 2>&1 || true; done
	IFS=',' read -ra arr <<<"$udp"; for p in "${arr[@]}"; do p="${p//[[:space:]]/}"; [[ -n "$p" ]] && ufw delete allow "${p}/udp" >>"$SETUP_LOG" 2>&1 || true; done

	# погасить родной firewall в БД напрямую (без триггера плагина)
	_ispc_mysql -e "UPDATE firewall SET active='n' WHERE server_id=${sid};" >>"$SETUP_LOG" 2>&1 || true

	# базовый restrict-блок (из setup.conf) больше не нужен — всё ведёт панель; снимаем его,
	# чтобы не было двух источников. -isp-блок (наш, из таблицы) не трогаем: 'restrict START'
	# не совпадает с 'restrict-isp START'.
	local f
	for f in /etc/ufw/before.rules /etc/ufw/before6.rules; do
		[[ -f "$f" ]] && sed -i '\|# luckystack: restrict START|,\|# luckystack: restrict END|d' "$f"
	done
	ufw reload >>"$SETUP_LOG" 2>&1 || true
	ui_success "Родной firewall ISPConfig погашен (active=n, user.rules вычищены). Движок один — наш модуль."
}

# Развернуть «заморозку vhost»: галочка «Не обновлять vhost» у сайта + отдельный плагин
# zzz_freeze_vhost_plugin (грузится ПОСЛЕ core nginx_plugin → срабатывает после регенерации
# и возвращает frozen-версию vhost). Колонка freeze_vhost в web_domain + плагин (php -l гейт)
# + каталог /etc/nginx/sites-frozen + патч формы сайта (переналивается при апдейте). Идемпотентно.
_ispconfig_deploy_vhost_freeze() {
	[[ "${ISPC_VHOST_FREEZE:-y}" == "y" ]] || return 0
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || return 0
	command -v mysql >/dev/null 2>&1 || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} vhost-freeze: колонка freeze_vhost + плагин + чекбокс в форме сайта"; return 0; }
	_ispconfig_deploy_panel_common || { ui_warn "Общая часть панелей не установилась — панель пропущена."; return 0; }
	local asset="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/vhost-freeze/zzz_freeze_vhost_plugin.inc.php"
	[[ -f "$asset" ]] || { ui_warn "Asset плагина vhost-freeze не найден ($asset) — пропуск."; return 0; }

	ui_step "Заморозка vhost (галочка «Не обновлять vhost» у сайта)"

	# 1) колонки: freeze_vhost (галочка) + freeze_vhost_content (содержимое vhost, правится
	#    textarea в панели; источник правды, плагин-root пишет его на диск).
	_ispc_mysql -e "ALTER TABLE web_domain ADD COLUMN IF NOT EXISTS freeze_vhost enum('n','y') NOT NULL default 'n';" >>"$SETUP_LOG" 2>&1 || true
	_ispc_mysql -e "ALTER TABLE web_domain ADD COLUMN IF NOT EXISTS freeze_vhost_content mediumtext NULL;" >>"$SETUP_LOG" 2>&1 || true
	# generated — последний сгенерированный core vhost (для diff/re-seed/детектора дрейфа в панели);
	# status — итог последнего применения (ok/ошибка nginx -t).
	_ispc_mysql -e "ALTER TABLE web_domain ADD COLUMN IF NOT EXISTS freeze_vhost_generated mediumtext NULL;" >>"$SETUP_LOG" 2>&1 || true
	_ispc_mysql -e "ALTER TABLE web_domain ADD COLUMN IF NOT EXISTS freeze_vhost_status varchar(255) NULL;" >>"$SETUP_LOG" 2>&1 || true

	# 2) серверный плагин + симлинк (zzz_ → грузится ПОСЛЕ nginx_plugin; только при чистом php -l)
	local pav=/usr/local/ispconfig/server/plugins-available pen=/usr/local/ispconfig/server/plugins-enabled
	if command -v php >/dev/null 2>&1 && php -l "$asset" >/dev/null 2>&1; then
		install -o root -g root -m 750 "$asset" "$pav/zzz_freeze_vhost_plugin.inc.php"
		[[ -d "$pen" ]] && ln -sf ../plugins-available/zzz_freeze_vhost_plugin.inc.php "$pen/zzz_freeze_vhost_plugin.inc.php"
	else
		ui_warn "php -l плагина vhost-freeze не прошёл — плагин не установлен."
		return 0
	fi

	# 2b) плагин захвата ручных правок файла: 'aaa_' → срабатывает ДО генератора ISPConfig
	#     (nginx_plugin), пока на диске ещё файл с ручными правками, и забирает их в базу
	local cap="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/vhost-freeze/aaa_freeze_vhost_capture_plugin.inc.php"
	if [[ -f "$cap" ]] && php -l "$cap" >/dev/null 2>&1; then
		install -o root -g root -m 750 "$cap" "$pav/aaa_freeze_vhost_capture_plugin.inc.php"
		[[ -d "$pen" ]] && ln -sf ../plugins-available/aaa_freeze_vhost_capture_plugin.inc.php "$pen/aaa_freeze_vhost_capture_plugin.inc.php"
	else
		ui_warn "Плагин захвата правок vhost не установлен: правки, сделанные прямо в файле, могут потеряться при сохранении сайта."
	fi

	# 3) каталог для замороженных vhost (наша область, не трогается ISPConfig)
	install -d -o root -g root -m 750 /etc/nginx/sites-frozen 2>>"$SETUP_LOG" || true

	# 3a) сверка: забрать в базу ручные правки файлов уже замороженных сайтов (иначе следующее
	#     сохранение сайта или Resync вернут старый текст из базы). Файлы и nginx не трогаются.
	local drift="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/vhost-freeze/ss-freeze-drift.php"
	if [[ -f "$drift" ]] && php -l "$drift" >/dev/null 2>&1; then
		install -o root -g root -m 750 "$drift" /usr/local/ispconfig/server/scripts/ss-freeze-drift.php
		_ispconfig_freeze_drift_import
	fi

	# 3b) страница «Заморозка: статус и diff» (sites-модуль, только админ) + её lang (en/ru)
	local infopage="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/vhost-freeze/web_vhost_freeze_info.php"
	[[ -f "$infopage" ]] && command -v php >/dev/null 2>&1 && php -l "$infopage" >/dev/null 2>&1 && \
		install -o ispconfig -g ispconfig -m 644 "$infopage" /usr/local/ispconfig/interface/web/sites/web_vhost_freeze_info.php 2>>"$SETUP_LOG"
	local fzlangdir="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/vhost-freeze/lang"
	[[ -d "$fzlangdir" ]] && install -o ispconfig -g ispconfig -m 644 "$fzlangdir"/*_web_vhost_freeze.lng /usr/local/ispconfig/interface/web/sites/lib/lang/ 2>>"$SETUP_LOG"

	# 4) UI: чекбокс в форме сайта (tform + шаблон + lang) — авто-детект имени формы, идемпотентно
	_ispconfig_patch_vhost_freeze_form

	ui_success "Заморозка vhost развёрнута: галочка у сайта + плагин (restore frozen-vhost после регенерации)."
}

# Добавить в core-форму сайта чекбокс «Не обновлять vhost». Имя формы зависит от версии
# ISPConfig (3.2+: web_vhost_domain; старее: web_domain) — детектим. Поле кладём во вкладку
# 'advanced' (Options). С php -l и откатом; при апдейте ISPConfig затирает → переналивается.
# Забрать в базу ручные правки файлов замороженных vhost (ss-freeze-drift.php). Вызывается при
# развёртывании заморозки, в --update и после того, как установщик сам правит файлы vhost
# (миграция пути CrowdSec-лога). Без этого у замороженного сайта в базе остаётся старый текст,
# и следующее сохранение сайта в панели вернёт его в файл.
_ispconfig_freeze_drift_import() {
	local s=/usr/local/ispconfig/server/scripts/ss-freeze-drift.php out
	[[ -f "$s" ]] || return 0
	out="$(php "$s" 2>>"$SETUP_LOG")" || return 0
	[[ -n "$out" ]] || return 0
	printf '%s\n' "$out" >>"$SETUP_LOG"
	ui_info "Заморозка vhost: в панель забраны правки, сделанные прямо в файлах:"
	printf '%s\n' "$out" | sed 's/^/    /'
}

_ispconfig_patch_vhost_freeze_form() {
	local IFsf=/usr/local/ispconfig/interface/web/sites
	local tf="" base=""
	local c
	for c in web_vhost_domain web_domain; do
		[[ -f "$IFsf/form/$c.tform.php" ]] && { tf="$IFsf/form/$c.tform.php"; base="$c"; break; }
	done
	[[ -n "$tf" ]] || { ui_warn "Форма сайта не найдена — чекбокс vhost-freeze не добавлен (плагин работает по колонке)."; return 0; }

	# БЕЗОПАСНОСТЬ. Сырой vhost пишется на диск от root, а через конфиг nginx можно, например,
	# подгрузить модуль от root. Поэтому поля заморозки НЕ кладём в tform: по tform работают и
	# обычное сохранение формы (вкладку Options видит и реселлер при reseller_can_use_options),
	# и Remote API (он вообще выставляет себе typ=admin). Поля пишет только наш патч контроллера
	# (4f) и только для настоящего админа; блок на вкладке рисуется по переменной из этого же
	# патча (4e2). Если патч не встал, функции просто нет, а дыры нет. Серверный плагин
	# дополнительно проверяет автора изменения по sys_datalog.

	# 4a) старые версии клали поля в tform — убираем (миграция уже установленных серверов)
	if grep -q "'freeze_vhost" "$tf"; then
		cp -a "$tf" "$tf.ssbak"
		awk '
			/^[[:space:]]*\x27freeze_vhost(_content)?\x27[[:space:]]*=>[[:space:]]*array[[:space:]]*\($/ { skip=1; next }
			skip==1 { if ($0 ~ /^[[:space:]]*\),[[:space:]]*$/) skip=0; next }
			{ print }
		' "$tf" >"$tf.new" && mv_keep "$tf.new" "$tf"
		chown ispconfig:ispconfig "$tf" 2>/dev/null
		if ! php -l "$tf" >/dev/null 2>&1 || grep -q "'freeze_vhost" "$tf"; then
			mv -f "$tf.ssbak" "$tf"
			ui_warn "tform сайта: не удалось убрать поля заморозки — заморозка vhost не ставится (проверьте вручную $tf)."
			return 0
		fi
	fi

	# 4b) чекбокс + редактор vhost во вкладку Options. Рисуется только при ss_fz_admin, её
	# выставляет патч контроллера (4e2) и только для админа. Значения подставляет он же, уже
	# экранированные (DEFAULT_ESCAPE шаблонизатора ISPConfig = null). Скрытый ss_fz_present
	# говорит контроллеру, что форма пришла именно с этой вкладки.
	local tm=""
	for c in "${base}_advanced" web_vhost_domain_advanced web_domain_advanced; do
		[[ -f "$IFsf/templates/$c.htm" ]] && { tm="$IFsf/templates/$c.htm"; break; }
	done
	if [[ -n "$tm" ]] && ! grep -q ss_fz_admin "$tm"; then
		cp -a "$tm" "$tm.ssbak"
		# старая версия блока (по is_admin и полям tform) стоит в начале файла — убрать
		if head -1 "$tm" | grep -q '<tmpl_if name="is_admin">' && grep -q freeze_vhost_content "$tm"; then
			awk 'NR==1 { skip=1 } skip==1 { if ($0 ~ /<\/tmpl_if>/) skip=0; next } { print }' "$tm" >"$tm.new" && mv_keep "$tm.new" "$tm"
		fi
		{ cat <<'HTM'
            <tmpl_if name="ss_fz_admin">
            <input type="hidden" name="ss_fz_present" value="1">
            <div class="form-group">
                <label for="freeze_vhost" class="col-sm-3 control-label">{tmpl_var name='freeze_vhost_txt'}</label>
                <div class="col-sm-9"><input type="checkbox" name="freeze_vhost" id="freeze_vhost" value="y"{tmpl_var name='ss_fz_checked'}>
                <p class="help-block">{tmpl_var name='freeze_vhost_hint_txt'}</p></div>
            </div>
            <div class="form-group">
                <label for="freeze_vhost_content" class="col-sm-3 control-label">{tmpl_var name='freeze_vhost_content_txt'}</label>
                <div class="col-sm-9">
                    <textarea class="form-control" name="freeze_vhost_content" id="freeze_vhost_content" rows="22" style="font-family:monospace;white-space:pre;overflow-wrap:normal">{tmpl_var name='ss_fz_content'}</textarea>
                    <p class="help-block">{tmpl_var name='freeze_vhost_content_hint_txt'}</p>
                    <a class="btn btn-default btn-xs" href="#" data-load-content="sites/web_vhost_freeze_info.php?id={tmpl_var name='id'}">{tmpl_var name='freeze_vhost_info_txt'}</a>
                </div>
            </div>
            </tmpl_if>
HTM
		cat "$tm"; } >"$tm.new" && mv_keep "$tm.new" "$tm"
		chown ispconfig:ispconfig "$tm" 2>/dev/null
	fi

	# 4c) метки (lang) — en/ru, на тот же base. ВАЖНО: lang-файлы ISPConfig обычно БЕЗ
	# закрывающего ?>, поэтому вставляем не «перед ?>», а удаляем возможный ?> и дописываем
	# переменные в конец (для PHP закрывающий тег не нужен).
	local L lf
	for L in en ru; do
		lf="$IFsf/lib/lang/${L}_${base}.lng"
		[[ -f "$lf" ]] || continue
		grep -q freeze_vhost_txt "$lf" && continue
		cp -a "$lf" "$lf.ssbak"
		sed -i '/^?>[[:space:]]*$/d' "$lf"
		if [[ "$L" == ru ]]; then
			printf "%s\n" "\$wb['freeze_vhost_txt'] = 'Не обновлять vhost';" \
				"\$wb['freeze_vhost_hint_txt'] = 'ISPConfig не будет перегенерировать vhost этого сайта — он берётся из поля ниже. Снимок текущего vhost подгрузится в поле при включении галочки (после сохранения).';" \
				"\$wb['freeze_vhost_content_txt'] = 'Содержимое vhost (заморожено)';" \
				"\$wb['freeze_vhost_content_hint_txt'] = 'Полный конфиг nginx этого сайта. Применяется как есть (с проверкой nginx -t и откатом при ошибке). Действует только при включённой галочке «Не обновлять vhost».';" \
				"\$wb['freeze_vhost_banner_txt'] = '⚠ Сайт заморожен: ISPConfig не перегенерирует его vhost. Изменения в панели (PHP, SSL, редиректы, алиасы) НЕ применятся — правьте поле «Содержимое vhost» во вкладке Options.';" \
				"\$wb['freeze_vhost_info_txt'] = 'Заморозка: статус и diff';" >>"$lf"
		else
			printf "%s\n" "\$wb['freeze_vhost_txt'] = 'Do not regenerate vhost';" \
				"\$wb['freeze_vhost_hint_txt'] = 'ISPConfig will not regenerate this site vhost — it is taken from the field below. A snapshot of the current vhost is loaded into the field when you enable this (after saving).';" \
				"\$wb['freeze_vhost_content_txt'] = 'vhost content (frozen)';" \
				"\$wb['freeze_vhost_content_hint_txt'] = 'The full nginx config for this site. Applied as-is (with nginx -t and rollback on error). Active only while \"Do not regenerate vhost\" is ticked.';" \
				"\$wb['freeze_vhost_banner_txt'] = '⚠ This site is frozen: ISPConfig will not regenerate its vhost. Panel changes (PHP, SSL, redirects, aliases) will NOT apply — edit the \"vhost content\" field on the Options tab.';" \
				"\$wb['freeze_vhost_info_txt'] = 'Freeze: status & diff';" >>"$lf"
		fi
		php -l "$lf" >/dev/null 2>&1 || mv -f "$lf.ssbak" "$lf"
	done

	# 4d) заметный баннер «сайт заморожен» НА ВСЕХ вкладках формы. tabbed_form.tpl.htm —
	# общая обёртка табличных форм (рендерится на каждой вкладке). Баннер условный — по
	# template-var freeze_vhost_active (его выставляет контроллер, 4e). Для прочих форм var
	# не задан → блок не рендерится. Тема — default; затирается апдейтом → переналивается.
	local tabf=/usr/local/ispconfig/interface/web/themes/default/templates/tabbed_form.tpl.htm
	if [[ -f "$tabf" ]] && ! grep -q freeze_vhost_active "$tabf"; then
		cp -a "$tabf" "$tabf.ssbak"
		awk '/<tmpl_if name="msg">/ && !d {
			print "\t<tmpl_if name=\"freeze_vhost_active\" op=\"==\" value=\"y\">";
			print "\t\t<div class=\"alert alert-warning\"><strong>{tmpl_var name=\x27freeze_vhost_banner_txt\x27}</strong></div>";
			print "\t</tmpl_if>";
			d=1 } { print }' "$tabf" >"$tabf.new" && mv_keep "$tabf.new" "$tabf"
		grep -q freeze_vhost_active "$tabf" || mv -f "$tabf.ssbak" "$tabf"
	fi

	# 4e) контроллер формы сайта: на каждом рендере выставить freeze_vhost_active из БД
	# (по domain_id). Вставляем в начало onShowEnd (после 'global $app'). php -l + откат.
	local ct="$IFsf/${base}_edit.php"
	[[ -f "$ct" ]] || ct="$IFsf/web_vhost_domain_edit.php"
	if [[ -f "$ct" ]] && ! grep -q freeze_vhost_active "$ct"; then
		cp -a "$ct" "$ct.ssbak"
		awk '
			/function onShowEnd\(\)/ { fz=1 }
			fz==1 && /global \$app/ && !d {
				print;
				print "\t\t$ss_fz_rec = $app->db->queryOneRecord(\"SELECT freeze_vhost FROM web_domain WHERE domain_id = ?\", (isset($this->id) ? (int)$this->id : 0));";
				print "\t\t$app->tpl->setVar(\x27freeze_vhost_active\x27, (is_array($ss_fz_rec) && isset($ss_fz_rec[\x27freeze_vhost\x27]) && $ss_fz_rec[\x27freeze_vhost\x27] == \x27y\x27) ? \x27y\x27 : \x27n\x27);";
				d=1; next } { print }' "$ct" >"$ct.new" && mv_keep "$ct.new" "$ct"
		if php -l "$ct" >/dev/null 2>&1 && grep -q freeze_vhost_active "$ct"; then
			chown ispconfig:ispconfig "$ct" 2>/dev/null
		else
			mv -f "$ct.ssbak" "$ct"; ui_warn "Контроллер формы сайта: патч баннера не прошёл php -l — откат (баннер на вкладке Options всё равно работает по подсказке)."
		fi
	fi

	# 4f) запись полей заморозки: в начале onAfterUpdate(), только для админа и только если
	# форма пришла с вкладки Options (ss_fz_present). Через datalogUpdate, чтобы серверный
	# плагин получил событие. CSRF-токен всей формы ISPConfig проверила раньше. Вставка сразу
	# после строки «global ...» внутри onAfterUpdate (как 4e в onShowEnd); php -l + откат.
	if [[ -f "$ct" ]] && ! grep -q ss_fz_write "$ct"; then
		cp -a "$ct" "$ct.ssbak2"
		awk '
			/function onAfterUpdate\(\)/ { au=1 }
			au==1 && /global \$app/ && !d {
				print;
				print "\t\t// ss_fz_write: заморозка vhost (luckystack). Пишет только админ, только с вкладки Options.";
				print "\t\tif(isset($_POST[\x27ss_fz_present\x27]) && isset($_SESSION[\x27s\x27][\x27user\x27][\x27typ\x27]) && $_SESSION[\x27s\x27][\x27user\x27][\x27typ\x27] == \x27admin\x27 && (int)$this->id > 0) {";
				print "\t\t\t$app->db->datalogUpdate(\x27web_domain\x27, array(";
				print "\t\t\t\t\x27freeze_vhost\x27 => (isset($_POST[\x27freeze_vhost\x27]) && $_POST[\x27freeze_vhost\x27] === \x27y\x27) ? \x27y\x27 : \x27n\x27,";
				print "\t\t\t\t\x27freeze_vhost_content\x27 => isset($_POST[\x27freeze_vhost_content\x27]) ? str_replace(\"\\r\\n\", \"\\n\", (string)$_POST[\x27freeze_vhost_content\x27]) : \x27\x27";
				print "\t\t\t), \x27domain_id\x27, (int)$this->id);";
				print "\t\t}";
				d=1; next } { print }
		' "$ct" >"$ct.new" && mv_keep "$ct.new" "$ct"
		if php -l "$ct" >/dev/null 2>&1 && grep -q ss_fz_write "$ct"; then
			chown ispconfig:ispconfig "$ct" 2>/dev/null
		else
			mv -f "$ct.ssbak2" "$ct"; ui_warn "Контроллер формы сайта: запись полей заморозки не встала — редактор vhost в панели не появится."
		fi
	fi

	# 4e2) значения для блока на вкладке Options (только админ): галочка, экранированный текст vhost
	# и ss_fz_admin, по которой шаблон вообще рисует блок. Ставится только вместе с 4f.
	if [[ -f "$ct" ]] && grep -q ss_fz_write "$ct" && ! grep -q ss_fz_admin "$ct"; then
		cp -a "$ct" "$ct.ssbak3"
		awk '
			/function onShowEnd\(\)/ { se=1 }
			se==1 && /global \$app/ && !d {
				print;
				print "\t\tif(isset($_SESSION[\x27s\x27][\x27user\x27][\x27typ\x27]) && $_SESSION[\x27s\x27][\x27user\x27][\x27typ\x27] == \x27admin\x27) {";
				print "\t\t\t$ss_fz_row = $app->db->queryOneRecord(\"SELECT freeze_vhost, freeze_vhost_content FROM web_domain WHERE domain_id = ?\", (isset($this->id) ? (int)$this->id : 0));";
				print "\t\t\t$app->tpl->setVar(\x27ss_fz_admin\x27, 1);";
				print "\t\t\t$app->tpl->setVar(\x27ss_fz_checked\x27, (is_array($ss_fz_row) && $ss_fz_row[\x27freeze_vhost\x27] == \x27y\x27) ? \x27 checked=\"checked\"\x27 : \x27\x27);";
				print "\t\t\t$app->tpl->setVar(\x27ss_fz_content\x27, is_array($ss_fz_row) ? htmlspecialchars((string)$ss_fz_row[\x27freeze_vhost_content\x27], ENT_QUOTES, \x27UTF-8\x27) : \x27\x27);";
				print "\t\t}";
				d=1; next } { print }
		' "$ct" >"$ct.new" && mv_keep "$ct.new" "$ct"
		if php -l "$ct" >/dev/null 2>&1 && grep -q ss_fz_admin "$ct"; then
			chown ispconfig:ispconfig "$ct" 2>/dev/null
		else
			mv -f "$ct.ssbak3" "$ct"; ui_warn "Контроллер формы сайта: блок заморозки на вкладке Options не встал."
		fi
	fi

	# 4g) IDS-whitelist: разрешить произвольный конфиг в поле freeze_vhost_content (как
	# nginx_directives) — иначе встроенный IDS ISPConfig отвергнет vhost как «possible attack».
	# Префикс admin: → только админ. Файл затирается обновлением ISPConfig → переналиваем.
	local wl=/usr/local/ispconfig/security/ids.whitelist
	local wline="admin:/sites/${base}_edit.php:POST.freeze_vhost_content"
	if [[ -f "$wl" ]] && ! grep -qF "$wline" "$wl"; then
		printf '%s\n' "$wline" >>"$wl"
	fi
}

# Встроить тумблер тёмной темы в панель ISPConfig (вариант «CSS + класс на <html>»):
# ставит ss-dark.css/ss-dark.js в тему default и патчит main.tpl.htm (ссылка на css/js в
# <head> + кнопка-тумблер рядом с logout). Выбор хранится в localStorage браузера, стартовое
# значение — по prefers-color-scheme. Файлы темы затираются обновлением ISPConfig → идемпотентно
# переналивается здесь (install + --update). На всех пользователей.
_ispconfig_deploy_theme_dark() {
	[[ "${ISPC_DARK_THEME:-y}" == "y" ]] || return 0
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} тёмная тема ISPConfig: ss-dark.css/js + тумблер в main.tpl.htm"; return 0; }
	local adir="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/theme-dark"
	[[ -f "$adir/ss-dark.css" && -f "$adir/ss-dark.js" ]] || { ui_warn "Asset'ы тёмной темы не найдены — пропуск."; return 0; }
	local th=/usr/local/ispconfig/interface/web/themes/default
	[[ -d "$th/assets/stylesheets" && -f "$th/templates/main.tpl.htm" ]] || return 0

	ui_step "Тёмная тема ISPConfig (тумблер в шапке)"
	install -o ispconfig -g ispconfig -m 644 "$adir/ss-dark.css" "$th/assets/stylesheets/ss-dark.css"
	install -o ispconfig -g ispconfig -m 644 "$adir/ss-dark.js"  "$th/assets/stylesheets/ss-dark.js"

	# дашборд: чарты метрик — у canvas inline background:white + тёмные оси Chart.js (через JS).
	# Делаем canvas прозрачным и оси/сетку «тёмными» по классу ss-dark. Идемпотентно.
	local mh=/usr/local/ispconfig/interface/web/dashboard/dashlets/templates/metrics.htm
	if [[ -f "$mh" ]] && ! grep -q 'ss-dark' "$mh"; then
		cp -a "$mh" "$mh.ssbak"
		sed -i -e 's/background-color: white;/background-color: transparent;/g' \
			-e 's|beginAtZero: true // Start y-axis at zero|beginAtZero: true, ticks:{color:(document.documentElement.classList.contains("ss-dark")?"#c7cacf":"#666")}, grid:{color:(document.documentElement.classList.contains("ss-dark")?"rgba(255,255,255,0.08)":"rgba(0,0,0,0.1)")}|' "$mh"
		chown ispconfig:ispconfig "$mh" 2>/dev/null
	fi

	local mt="$th/templates/main.tpl.htm"
	if grep -q 'ss-theme-toggle' "$mt"; then ui_info "Тумблер тёмной темы уже встроен."; return 0; fi
	cp -a "$mt" "$mt.ssbak"
	awk '
		/<\/head>/ && !c {
			print "  <link rel=\x27stylesheet\x27 href=\x27themes/<tmpl_var name=\x27current_theme\x27>/assets/stylesheets/ss-dark.css?v=7\x27 />";
			print "  <script src=\x27themes/<tmpl_var name=\x27current_theme\x27>/assets/stylesheets/ss-dark.js\x27></script>";
			print; c=1; next }
		/id=.logout-button./ && !b {
			print;
			print "\t\t\t\t<button type=\x27button\x27 id=\x27ss-theme-toggle\x27 class=\x27btn btn-sm btn-default\x27 style=\x27float:right;margin:16px 8px 0 8px\x27 title=\x27Light/Dark theme\x27 onclick=\x27ssToggleTheme()\x27><span class=\x27fa fa-adjust\x27></span></button>";
			b=1; next }
		{ print }
	' "$mt" >"$mt.new" && mv_keep "$mt.new" "$mt"
	chown ispconfig:ispconfig "$mt" 2>/dev/null
	if grep -q ss-theme-toggle "$mt" && grep -q 'ss-dark.css' "$mt"; then
		ui_success "Тёмная тема встроена: тумблер у кнопки выхода (выбор в localStorage)."
	else
		mv -f "$mt.ssbak" "$mt"; ui_warn "Патч main.tpl.htm для тёмной темы не удался — откат."
	fi
}

# Сменить порт Apps-vhost ISPConfig (webmail/phpMyAdmin через apps.<домен>) на
# ISPCONFIG_APPS_PORT. ISPConfig хранит его в server.config (apps_vhost_port=8081), а в
# шаблоне nginx_apps.vhost.master подставляет <tmpl_var name='apps_vhost_port'>. Меняем:
#   1) конфиг сервера ISPConfig (durable — будущие регенерации vhost берут новый порт);
#   2) живой apps.vhost (немедленно), с nginx -t и откатом;
#   3) firewall открывает новый порт (в _security_ufw_ports/before.rules по ISPCONFIG_APPS_PORT).
_ispconfig_set_apps_port() {
	local newp="${ISPCONFIG_APPS_PORT:-8081}"
	[[ "$newp" =~ ^[0-9]+$ ]] && ((newp >= 1 && newp <= 65535)) || return 0
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || return 0
	command -v mysql >/dev/null 2>&1 || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} Apps-vhost порт → ${newp} (server.config apps_vhost_port + apps.vhost)"
		return 0
	fi
	_ispc_mysql -e "SELECT 1;" >/dev/null 2>&1 || { ui_warn "dbispconfig недоступна — порт Apps не изменён."; return 0; }

	# текущий порт из конфига сервера
	local cur
	cur="$(_ispc_mysql -N -B -e "SELECT config FROM server WHERE server_id=1;" 2>/dev/null | grep -oE 'apps_vhost_port=[0-9]+' | head -1 | cut -d= -f2)"
	cur="${cur:-8081}"
	[[ "$cur" == "$newp" ]] && { ui_info "Apps-vhost уже на порту ${newp}."; return 0; }

	ui_step "Смена порта Apps-vhost ISPConfig: ${cur} → ${newp}"
	# 1) конфиг ISPConfig (для будущих регенераций)
	_ispc_mysql -e "UPDATE server SET config = REPLACE(config, 'apps_vhost_port=${cur}', 'apps_vhost_port=${newp}') WHERE server_id=1;" >>"$SETUP_LOG" 2>&1 \
		|| ui_warn "Не удалось обновить apps_vhost_port в server.config (см. $SETUP_LOG)."
	# 2) живой apps.vhost — порт встречается только как номер apps-vhost, меняем по границе слова
	local f=/etc/nginx/sites-available/apps.vhost
	if [[ -f "$f" ]]; then
		cp -a "$f" "$f.appsport.bak"
		sed -i -E "s/\\b${cur}\\b/${newp}/g" "$f"
		if nginx -t >>"$SETUP_LOG" 2>&1; then
			systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
			rm -f "$f.appsport.bak"
			ui_success "Apps-vhost переведён на порт ${newp} (apps.домен теперь на :${newp})."
		else
			mv -f "$f.appsport.bak" "$f"
			systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
			ui_warn "nginx -t не прошёл после смены порта Apps — откатил apps.vhost (см. $SETUP_LOG)."
		fi
	else
		ui_info "apps.vhost не найден (порт применится при регенерации ISPConfig)."
	fi
}

# Зашить кастомный шаблон зоны DNS в ISPConfig (таблица dns_template, запись «Default»).
# Каждый новый домен через «Add DNS Zone with Wizard» получит vanity-NS этого сервера +
# SPF/DMARC(p=none)/CAA(letsencrypt)/autodiscover. DKIM НЕ включаем — ISPConfig генерит
# ключ per-домен сам. Плейсхолдеры {DOMAIN}/{IP}/{NS1}/{EMAIL} подставляет мастер ISPConfig;
# {NS*_IP} (адреса nameserver'ов = IP сервера) подставляем здесь. Идемпотентно:
# UPDATE по name='Default'; нет шаблонов вовсе → INSERT; есть с другим именем → не трогаем.
_ispconfig_dns_template() {
	[[ "${DNS_ZONE_TEMPLATE:-n}" == "y" ]] || return 0
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || return 0
	command -v mysql >/dev/null 2>&1 || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} DNS: шаблон зоны «Default» в dbispconfig.dns_template (vanity-NS + SPF/DMARC/CAA)"
		return 0
	fi
	_ispc_mysql -e "SELECT 1;" >/dev/null 2>&1 || { ui_warn "dbispconfig недоступна — DNS-шаблон не зашит."; return 0; }

	local primary; primary="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
	local ns1="${DNS_NS1_IP:-$primary}" ns2 ns3 ns4
	ns2="${DNS_NS2_IP:-$ns1}"; ns3="${DNS_NS3_IP:-$ns1}"; ns4="${DNS_NS4_IP:-$ns1}"
	if [[ -z "$ns1" ]]; then ui_warn "Не определён IP nameserver'ов — DNS-шаблон пропущен."; return 0; fi

	# Сколько NS зашить (2–4; по умолчанию 2 — минимум по best-practice).
	local nsc="${DNS_NS_COUNT:-2}"; [[ "$nsc" =~ ^[2-4]$ ]] || nsc=2
	# Динамически собрать A|nsN и NS-записи под выбранное число.
	local -a _nsips=("$ns1" "$ns2" "$ns3" "$ns4")
	local a_ns="" ns_recs="" _i _ipv
	for ((_i=1; _i<=nsc; _i++)); do
		_ipv="${_nsips[$((_i-1))]:-$ns1}"
		a_ns+="A|ns${_i}|${_ipv}|0|3600"$'\n'
		ns_recs+="NS|{DOMAIN}.|ns${_i}.{DOMAIN}.|0|3600"
		((_i < nsc)) && ns_recs+=$'\n'
	done
	a_ns="${a_ns%$'\n'}"

	ui_step "DNS: кастомный шаблон зоны новых доменов (ISPConfig)"

	# Тело шаблона. ВНИМАНИЕ (прод): DMARC p=none, SPF ~all — мягкие режимы намеренно
	# (см. /root/dns-zone-template-notes.txt). Двойные кавычки в CAA для SQL безопасны.
	local tpl
	tpl="$(cat <<TPL
[ZONE]
origin={DOMAIN}.
ns={NS1}.
mbox={EMAIL}.
refresh=7200
retry=540
expire=604800
minimum=3600
ttl=3600
xfer=
also_notify=
dnssec_wanted=N
dnssec_algo=ECDSAP256SHA256

[DNS_RECORDS]
A|{DOMAIN}.|{IP}|0|3600
A|www|{IP}|0|3600
A|mail|{IP}|0|3600
${a_ns}
${ns_recs}
MX|{DOMAIN}.|mail.{DOMAIN}.|10|3600
TXT|{DOMAIN}.|v=spf1 mx a ~all|0|3600
TXT|_dmarc|v=DMARC1; p=none; rua=mailto:{EMAIL}; fo=1|0|3600
CAA|{DOMAIN}.|0 issue "letsencrypt.org"|0|3600
CAA|{DOMAIN}.|0 iodef "mailto:{EMAIL}"|0|3600
CNAME|autodiscover|mail.{DOMAIN}.|0|3600
CNAME|autoconfig|mail.{DOMAIN}.|0|3600
TPL
)"
	# Экранируем для SQL-строки: обратный слэш, затем одинарная кавычка.
	local esc="${tpl//\\/\\\\}"; esc="${esc//\'/\\\'}"

	# Сколько шаблонов вообще и есть ли «Default»
	local total def_cnt
	total="$(_ispc_mysql -N -B -e "SELECT COUNT(*) FROM dns_template;" 2>/dev/null)"
	def_cnt="$(_ispc_mysql -N -B -e "SELECT COUNT(*) FROM dns_template WHERE name='Default';" 2>/dev/null)"

	local sqlf; sqlf="$(mktemp)"
	if [[ "${def_cnt:-0}" -ge 1 ]]; then
		printf "UPDATE dns_template SET template='%s' WHERE name='Default';\n" "$esc" >"$sqlf"
		if _ispc_mysql <"$sqlf" >>"$SETUP_LOG" 2>&1; then
			ui_success "DNS-шаблон «Default» обновлён (${nsc}×NS: ns1..ns${nsc})."
		else
			ui_warn "Не удалось обновить DNS-шаблон (см. $SETUP_LOG)."
		fi
	elif [[ "${total:-0}" -eq 0 ]]; then
		# Шаблонов нет вовсе — создаём «Default»
		printf "INSERT INTO dns_template (sys_userid,sys_groupid,sys_perm_user,sys_perm_group,sys_perm_other,visible,name,template) VALUES (1,1,'riud','riud','','Y','Default','%s');\n" "$esc" >"$sqlf"
		if _ispc_mysql <"$sqlf" >>"$SETUP_LOG" 2>&1; then
			ui_success "DNS-шаблон «Default» создан (${nsc}×NS: ns1..ns${nsc})."
		else
			ui_warn "Не удалось создать DNS-шаблон (см. $SETUP_LOG) — задайте вручную (DNS → Templates)."
		fi
	else
		ui_warn "В ISPConfig есть DNS-шаблоны с другими именами (не «Default») — не трогаю во избежание потери."
		ui_info "Примените шаблон вручную: DNS → Templates, либо переименуйте нужный в «Default»."
	fi
	rm -f "$sqlf"

	_dns_template_prod_notes "$ns1" "$ns2" "$ns3" "$ns4"
}

# Заметки «что подправить в проде» — пишем в /root и кратко показываем в выводе.
_dns_template_prod_notes() {
	local ns1="$1" ns2="$2" ns3="$3" ns4="$4"
	local f=/root/dns-zone-template-notes.txt
	cat >"$f" <<NOTE
# ============================================================================
# DNS-шаблон зоны ISPConfig — что подправить ПЕРЕД продакшеном
# (шаблон зашит установщиком в dbispconfig.dns_template, запись «Default»)
# Редактировать сам шаблон: панель → DNS → Templates → «Default».
# ============================================================================

NS-сервера (glue), сейчас все на ЭТОМ сервере:
  ns1 → ${ns1}
  ns2 → ${ns2}
  ns3 → ${ns3}
  ns4 → ${ns4}

ОБЯЗАТЕЛЬНО в проде:

1) Делегирование у регистратора домена.
   Пропишите ns1–ns4.<домен> с теми же IP (glue) в панели регистратора —
   иначе зона не делегируется и домен не будет резолвиться извне.

2) Резерв NS (важно!). Сейчас все 4 NS — на одной машине: падение хоста
   уронит ВСЕ nameserver'ы (RFC 2182 рекомендует NS в разных сетях).
   Заведите вторичный (slave) DNS на ОТДЕЛЬНОМ сервере:
   ISPConfig → DNS → у зоны поле «Allow zone transfers (xfer=)» = IP вторички,
   на вторичке — Secondary Zone. Или внешняя бесплатная вторичка (buddyns и пр.).

3) DKIM. В шаблоне его НЕТ намеренно — ключ у каждого домена свой.
   Включите DKIM на почтовом домене: панель → Email → Domain → вкладка DKIM
   («Generate DKIM») — ISPConfig сам добавит TXT-запись в зону.

4) DMARC. Сейчас p=none (только мониторинг отчётов на {EMAIL}).
   Когда убедитесь, что SPF и DKIM проходят (по rua-отчётам) — поднимите политику:
   _dmarc TXT → v=DMARC1; p=quarantine; ... затем при стабильности → p=reject.

5) SPF. Сейчас "v=spf1 mx a ~all" (softfail). Когда вся легитимная почта идёт
   через mx/a — ужесточите хвост до "-all" (hardfail).

6) PTR (reverse DNS). Задаётся НЕ в этой зоне, а у владельца IP (хостер/панель
   IPMI): PTR для ${ns1} → mail.<домен> (или FQDN сервера). Без корректного
   PTR почта часто уходит в спам.

7) CAA. Сейчас разрешён только Let's Encrypt. Если будете выпускать серты
   другим CA — добавьте его в CAA issue, иначе выпуск будет заблокирован.

8) DNSSEC (опц.). dnssec_wanted=N. Чтобы включить: в шаблоне/зоне поставьте
   dnssec_wanted=Y (алгоритм ECDSAP256SHA256 уже задан) и пропишите DS-запись
   у регистратора. Без DS на стороне родителя DNSSEC работать не будет.
NOTE
	chmod 600 "$f" 2>/dev/null || true
	ui_info "DNS: что подправить в проде (делегирование, вторичка, DKIM, DMARC→quarantine) → ${UI_W}${f}${UI_NC}"
}

# Composer глобально в /usr/local/bin/composer. Нужен: (1) для jailed shell-юзеров через
# jailkit-секцию [composer] (она копирует /usr/local/bin/composer в chroot), (2) для CLI-деплоя
# по SSH. Идемпотентно; официальная установка с ПРОВЕРКОЙ ПОДПИСИ (sha384). Отключаемо INSTALL_COMPOSER=n.
_ispconfig_install_composer() {
	[[ "${INSTALL_COMPOSER:-y}" == "y" ]] || return 0
	command -v php >/dev/null 2>&1 || { ui_warn "Composer: нет php CLI — пропуск."; return 0; }
	if [[ -x /usr/local/bin/composer ]]; then
		COMPOSER_ALLOW_SUPERUSER=1 /usr/local/bin/composer self-update --2 --no-interaction </dev/null >>"$SETUP_LOG" 2>&1 || true
		ui_info "Composer уже установлен: $(COMPOSER_ALLOW_SUPERUSER=1 /usr/local/bin/composer --version --no-interaction </dev/null 2>/dev/null | head -1)"
		return 0
	fi
	ui_step "Установка Composer (глобально, /usr/local/bin/composer)"
	local tmp; tmp="$(mktemp -d)"
	if php -r "copy('https://getcomposer.org/installer', '$tmp/composer-setup.php');" >>"$SETUP_LOG" 2>&1; then
		local exp sig
		exp="$(php -r "copy('https://composer.github.io/installer.sig', 'php://stdout');" 2>/dev/null)"
		sig="$(php -r "echo hash_file('sha384', '$tmp/composer-setup.php');" 2>/dev/null)"
		if [[ -n "$exp" && "$exp" == "$sig" ]]; then
			if php "$tmp/composer-setup.php" --install-dir=/usr/local/bin --filename=composer >>"$SETUP_LOG" 2>&1; then
				chmod 755 /usr/local/bin/composer
				ui_success "Composer установлен: $(COMPOSER_ALLOW_SUPERUSER=1 /usr/local/bin/composer --version --no-interaction </dev/null 2>/dev/null | head -1)"
			else ui_warn "Composer: установка не удалась (см. ${SETUP_LOG})."; fi
		else
			ui_warn "Composer: подпись установщика не совпала — пропуск (безопасность)."
		fi
	else
		ui_warn "Composer: не скачался (нет сети до getcomposer.org?) — пропуск."
	fi
	rm -rf "$tmp"
}

# Добавить composer/php/node в jailkit_chroot_app_sections ISPConfig, чтобы jailed shell-юзеры
# получали composer/php/node в свой chroot (jk_init копирует их из секций jk_init.ini при сборке
# jail). git обычно уже в списке. Идемпотентно; правит server.config через PHP-регэксп (только
# дополняет недостающее). Существующие jail'ы подхватят при следующем обновлении shell-юзера.
_ispconfig_jailkit_apps() {
	[[ "${INSTALL_COMPOSER:-y}" == "y" ]] || return 0
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || return 0
	command -v php >/dev/null 2>&1 || return 0
	command -v jk_init >/dev/null 2>&1 || { log "jailkit: jk_init нет — секции не трогаю"; return 0; }
	local out
	out="$(php <<'PHP' 2>>"$SETUP_LOG"
<?php
$conf = array();
require '/usr/local/ispconfig/server/lib/config.inc.php';
require '/usr/local/ispconfig/server/lib/app.inc.php';
$want = array('php','composer','node');
$rec = $app->db->queryOneRecord("SELECT server_id, config FROM server ORDER BY server_id LIMIT 1");
if(!is_array($rec) || $rec['config'] === '') { echo 'no-config'; exit; }
$cfg = $rec['config'];
if(!preg_match('/^jailkit_chroot_app_sections=(.*)$/m', $cfg, $m)) { echo 'no-line'; exit; }
$cur = preg_split('/\s+/', trim($m[1]), -1, PREG_SPLIT_NO_EMPTY);
$add = array();
foreach($want as $w) { if(!in_array($w, $cur, true)) { $cur[] = $w; $add[] = $w; } }
if(empty($add)) { echo 'present'; exit; }
$newline = 'jailkit_chroot_app_sections='.implode(' ', $cur);
// callback → замена берётся ЛИТЕРАЛЬНО (без интерпретации $/\ в строке замены)
$cfg2 = preg_replace_callback('/^jailkit_chroot_app_sections=.*$/m', function($mm) use ($newline){ return $newline; }, $cfg, 1);
$app->db->query("UPDATE server SET config = ? WHERE server_id = ?", $cfg2, $rec['server_id']);
echo 'added:'.implode(',', $add);
PHP
)"
	case "$out" in
		added:*) ui_info "Jailkit: в chroot-секции добавлено ${out#added:} (jailed shell-юзеры получат composer/php/node в jail)." ;;
		present) log "jailkit: composer/php/node уже в секциях" ;;
		*)       log "jailkit: секции не изменены (${out})" ;;
	esac
}

# Авто-регистрация всех установленных версий PHP-FPM в ISPConfig — раздел
# System → Additional PHP Versions. ISPConfig читает их из таблицы server_php;
# добавляем по строке на каждую /etc/php/X.Y/fpm. Идемпотентно (по name+server_id).
# После этого версии появляются в выпадающем списке «PHP Version» у сайтов.
_ispconfig_register_php_versions() {
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || return 0
	command -v mysql >/dev/null 2>&1 || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} регистрация версий PHP-FPM в ISPConfig (dbispconfig.server_php)"
		return 0
	fi
	_ispc_mysql -e "SELECT 1;" >/dev/null 2>&1 || { ui_warn "dbispconfig недоступна — регистрация версий PHP пропущена."; return 0; }

	local sid
	sid="$(_ispc_mysql -N -B -e "SELECT server_id FROM server ORDER BY server_id LIMIT 1;" 2>/dev/null)"
	[[ "$sid" =~ ^[0-9]+$ ]] || sid=1

	# Колонки вкладки «PHP-CLI Settings» (ISPConfig 3.2+): php_cli_binary и php_jk_section.
	# ОБА поля валидируются формой как обязательные (NOTEMPTY) — без них при сохранении
	# версии вылезает «PHP Jailkit section field must not be empty». Заполняем, только
	# если колонки реально есть (совместимость со старыми схемами).
	local has_cli=0 has_jk=0
	_ispc_mysql -N -B -e "SHOW COLUMNS FROM server_php LIKE 'php_cli_binary';" 2>/dev/null | grep -q php_cli_binary && has_cli=1
	_ispc_mysql -N -B -e "SHOW COLUMNS FROM server_php LIKE 'php_jk_section';" 2>/dev/null | grep -q php_jk_section && has_jk=1

	ui_step "Регистрация версий PHP в ISPConfig (Additional PHP Versions)"
	local d ver added=0 upd=0 cnt name ini pool svc fbin fini clibin jk xc xv xs
	for d in /etc/php/*/fpm; do
		[[ -d "$d" ]] || continue
		ver="$(basename "$(dirname "$d")")"            # /etc/php/8.3/fpm → 8.3
		[[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]] || continue
		name="PHP ${ver}"; ini="/etc/php/${ver}/fpm"; pool="/etc/php/${ver}/fpm/pool.d"; svc="php${ver}-fpm"

		# FastCGI-бинарь (php-cgiX.Y). В чистой FPM-сборке его нет — при ISPC_PHP_CGI=y
		# доустанавливаем пакет phpX.Y-cgi. Если бинаря нет — поля FastCGI пустые (FPM).
		# Прим.: на nginx сайты используют ТОЛЬКО PHP-FPM; FastCGI-поля нужны для Apache
		# и для выбора версии PHP в shell/cron у клиента. ini-dir FastCGI = .../cgi.
		fbin=""; fini=""
		if [[ "${ISPC_PHP_CGI:-y}" == "y" && ! -x "/usr/bin/php-cgi${ver}" ]] && declare -F apt_install >/dev/null; then
			apt_install "php${ver}-cgi" >>"$SETUP_LOG" 2>&1 || true
		fi
		[[ -x "/usr/bin/php-cgi${ver}" ]] && { fbin="/usr/bin/php-cgi${ver}"; fini="/etc/php/${ver}/cgi"; }

		# CLI-бинарь (есть всегда, пакет phpX.Y-cli) + jailkit-секция (php8.3 → php8_3).
		clibin=""; [[ -x "/usr/bin/php${ver}" ]] && clibin="/usr/bin/php${ver}"
		jk="php${ver//./_}"
		xc=""; xv=""; xs=""
		if ((has_cli)); then xc+=",php_cli_binary"; xv+=",'${clibin}'"; xs+=",php_cli_binary='${clibin}'"; fi
		if ((has_jk));  then xc+=",php_jk_section"; xv+=",'${jk}'";     xs+=",php_jk_section='${jk}'"; fi

		cnt="$(_ispc_mysql -N -B -e "SELECT COUNT(*) FROM server_php WHERE server_id=${sid} AND name='${name}';" 2>/dev/null)"
		if [[ "$cnt" == "0" ]]; then
			if _ispc_mysql -e "INSERT INTO server_php \
				(sys_userid,sys_groupid,sys_perm_user,sys_perm_group,sys_perm_other,client_id,server_id,name,php_fastcgi_binary,php_fastcgi_ini_dir,php_fpm_init_script,php_fpm_ini_dir,php_fpm_pool_dir${xc}) \
				VALUES (1,1,'riud','riud','',0,${sid},'${name}','${fbin}','${fini}','${svc}','${ini}','${pool}'${xv});" >>"$SETUP_LOG" 2>&1; then
				added=$((added+1)); ui_info "  + ${name} (FPM ${svc}${fbin:+, FastCGI ${fbin}}${clibin:+, CLI ${clibin}})"
			else
				ui_warn "  Не удалось добавить ${name} — проверьте структуру таблицы server_php."
			fi
		else
			# Уже есть — синхронизируем пути (FastCGI/CLI-бинари дозаполняются при появлении)
			_ispc_mysql -e "UPDATE server_php SET \
				php_fastcgi_binary='${fbin}',php_fastcgi_ini_dir='${fini}',php_fpm_init_script='${svc}',php_fpm_ini_dir='${ini}',php_fpm_pool_dir='${pool}'${xs} \
				WHERE server_id=${sid} AND name='${name}';" >>"$SETUP_LOG" 2>&1 && upd=$((upd+1)) || true
		fi
	done
	if ((added || upd)); then
		ui_success "Версии PHP в ISPConfig: добавлено ${added}, синхронизировано ${upd}. System → Additional PHP Versions + список «PHP Version» у сайтов."
	else
		ui_info "Установленных версий PHP-FPM не найдено — регистрировать нечего."
	fi
}

# Вставить блок из файла ПОСЛЕ первой строки, совпавшей с pattern (один раз).
# Блок читается из файла построчно — без mangling спецсимволов (\. и пр.).
_ispc_insert_after() {
	local file="$1" pattern="$2" blockfile="$3"
	awk -v pat="$pattern" -v bf="$blockfile" '
		{ print }
		!done && index($0, pat) {
			while ((getline line < bf) > 0) print line
			close(bf); done=1
		}
	' "$file" >"$file.tmp" && mv_keep "$file.tmp" "$file"
}

# Вставить блок (тело — из stdin) после якоря, ЕСЛИ маркера ещё нет.
# rc=0 — блок добавлен; rc=1 — уже присутствовал (идемпотентность).
_ispc_add_block() {
	local file="$1" marker="$2" anchor="$3"
	grep -qF "$marker" "$file" && return 1
	local blk; blk="$(mktemp)"; cat >"$blk"
	_ispc_insert_after "$file" "$anchor" "$blk"
	rm -f "$blk"
	return 0
}

stage_ispconfig_summary() {
	echo "ISPConfig: ветка ${ISPCONFIG_BRANCH:-stable}, https://${SERVER_FQDN:-<server>}:${ISPCONFIG_PANEL_PORT:-8080}"
}
