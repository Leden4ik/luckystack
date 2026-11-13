#!/bin/bash
# =============================================================================
# lib/database.sh — Этап 2: MariaDB (+ Redis).
# Выбор источника MariaDB (официальный репо / Debian), генерация root-пароля,
# неинтерактивный аналог mysql_secure_installation, charset utf8mb4, Redis.
# =============================================================================

# Версия MariaDB определяется АВТОМАТИЧЕСКИ (последняя LTS Stable из REST API).
# Фолбэк — проверенная с ISPConfig LTS. Порядок: явный пин MARIADB_VERSION →
# авто (MARIADB_AUTO_VERSION=y) → фолбэк. Результат кешируется на прогон.
: "${MARIADB_FALLBACK_VER:=11.4}"

# Последняя LTS Stable из официального REST API MariaDB (пусто при неудаче).
_mariadb_resolve_version() {
	command -v python3 >/dev/null 2>&1 || return 0
	curl -fsSL --connect-timeout 10 --max-time 20 https://downloads.mariadb.org/rest-api/mariadb/ 2>/dev/null \
	| python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
best = None
for r in d.get("major_releases", []):
    if r.get("release_status") == "Stable" and r.get("release_support_type", "").lower().startswith("long term"):
        rid = r.get("release_id", "")
        try:
            k = tuple(int(x) for x in rid.split("."))
        except Exception:
            continue
        if best is None or k > best[0]:
            best = (k, rid)
print(best[1] if best else "")
' 2>/dev/null
}

# Эффективная версия MariaDB (с кешем на прогон).
_mariadb_effective_version() {
	[[ -n "${_MARIADB_VER_RESOLVED:-}" ]] && { echo "$_MARIADB_VER_RESOLVED"; return 0; }
	local v=""
	if [[ -n "${MARIADB_VERSION:-}" ]]; then
		v="$MARIADB_VERSION"                       # явный пин — уважаем
	elif [[ "${MARIADB_AUTO_VERSION:-y}" == "y" && "${DRY_RUN:-0}" != "1" ]]; then
		v="$(_mariadb_resolve_version)"            # авто: последняя LTS
	fi
	[[ -z "$v" ]] && v="$MARIADB_FALLBACK_VER"     # фолбэк
	_MARIADB_VER_RESOLVED="$v"
	echo "$v"
}

# Подключение официального репозитория MariaDB (mariadb_repo_setup).
# Поддерживает Debian 12/13 — скрипт сам определяет кодовое имя релиза.
_mariadb_add_official_repo() {
	local ver; ver="$(_mariadb_effective_version)"
	ui_step "Подключение официального репозитория MariaDB ${ver}"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} mariadb_repo_setup --mariadb-server-version=mariadb-${ver}"
		return 0
	fi
	if [[ -f /etc/apt/sources.list.d/mariadb.list || -f /etc/apt/sources.list.d/mariadb.sources ]]; then
		ui_info "Репозиторий MariaDB уже подключён."
		return 0
	fi
	apt_install curl ca-certificates
	if ! ui_spin "mariadb_repo_setup (mariadb-${ver})" bash -c \
		"curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash -s -- --mariadb-server-version=mariadb-${ver}"; then
		ui_warn "Не удалось подключить офиц. репозиторий MariaDB — откат на пакеты Debian."
		return 1
	fi
	apt_update
	return 0
}

# Установка пакетов MariaDB согласно выбранному источнику.
_mariadb_install_packages() {
	local source="${MARIADB_SOURCE:-official}"
	if [[ "$source" == "official" ]]; then
		ui_info "Источник MariaDB: ${UI_BOLD}официальный репозиторий${UI_NC} (версия $(_mariadb_effective_version))"
		_mariadb_add_official_repo || true   # при ошибке — фолбэк на Debian-пакеты ниже
	else
		ui_info "Источник MariaDB: ${UI_BOLD}репозиторий Debian${UI_NC}"
	fi
	ui_step "Установка MariaDB server + client"
	apt_install mariadb-server mariadb-client
}

stage_database() {
	# --- Установка (с выбором источника) ---
	_mariadb_install_packages

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} secure-install, root-пароль, utf8mb4"
		_redis_install
		ui_success "MariaDB (имитация) установлена."
		return 0
	fi

	sys_run "Запуск и автозагрузка MariaDB" systemctl enable --now mariadb

	# --- root-пароль: ADOPT-SAFE ---
	# Если у root MariaDB УЖЕ есть рабочий пароль (ручная установка по гайду или наш
	# повтор) — адаптируем существующий и НЕ сбрасываем (важно: иначе сломали бы
	# приложения, ходящие со старым паролем). Иначе — первичная настройка.
	local root_pw existing_pw="" adopted=0
	if [[ -f /root/.my.cnf ]]; then
		existing_pw="$(sed -nE 's/^[[:space:]]*password[[:space:]]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' /root/.my.cnf | head -1)"
	fi
	if [[ -n "$existing_pw" ]] && mysql -uroot -p"$existing_pw" --execute="SELECT 1;" >/dev/null 2>&1; then
		root_pw="$existing_pw"; adopted=1
		config_set MARIADB_ROOT_PW "$root_pw"
		ui_info "MariaDB: найден рабочий root-пароль — адаптирую существующий (сброс НЕ выполняется)."
	else
		root_pw="$(config_get_or_gen_password MARIADB_ROOT_PW 24)"
	fi

	# Определяем, как подключиться.
	local mysql_root
	if ((adopted)); then
		mysql_root=(mysql --user=root --password="$root_pw")
	elif mysql --user=root --execute="SELECT 1;" >/dev/null 2>&1; then
		mysql_root=(mysql --user=root)                       # socket-аутентификация (свежая)
	elif mysql --user=root --password="$root_pw" --execute="SELECT 1;" >/dev/null 2>&1; then
		mysql_root=(mysql --user=root --password="$root_pw") # уже настроен нами
	else
		ui_error "Не удаётся подключиться к MariaDB ни через socket, ни с сохранённым паролем."
		if [[ -d /var/lib/mysql/mysql ]]; then
			ui_info "Похоже, в /var/lib/mysql остались базы прошлой установки со своим паролем root."
			ui_info "Впишите тот пароль в /root/.my.cnf (строки [client], user=root, password=...) и повторите: $(ls_hint --resume)"
			ui_info "Если старые базы не нужны: остановите MariaDB, перенесите /var/lib/mysql в сторону и повторите этап."
		fi
		return 1
	fi

	# --- Аналог mysql_secure_installation — ТОЛЬКО при первичной настройке ---
	# При адаптации существующей установки НЕ трогаем пароль/привилегии/БД.
	if ((adopted)); then
		ui_info "MariaDB уже настроена — secure-installation пропущена (адаптация существующего сервера)."
	else
		ui_step "Базовая защита MariaDB (secure installation)"
		# ISPConfig ожидает, что root может логиниться по паролю с localhost.
		if ! "${mysql_root[@]}" <<SQL
-- задать/обновить пароль root и разрешить парольную аутентификацию
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${root_pw}');
-- убрать анонимов
DELETE FROM mysql.global_priv WHERE User='';
-- запретить удалённый root
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
-- удалить тестовую БД
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
		then
			ui_error "Ошибка при настройке безопасности MariaDB."
			return 1
		fi
		ui_success "root-пароль установлен, анонимные пользователи и тестовая БД удалены."
	fi

	# Сохраним клиентский конфиг для root (удобно для последующих этапов/админа)
	cat >/root/.my.cnf <<MYCNF
[client]
user=root
password=${root_pw}
MYCNF
	chmod 600 /root/.my.cnf

	# --- Кодировка utf8mb4 + bind-address ---
	ui_step "Настройка кодировки utf8mb4"
	local cnf=/etc/mysql/mariadb.conf.d/99-luckystack.cnf
	# bind-address: по умолчанию 127.0.0.1 (только локально). Если включён удалённый
	# доступ (MARIADB_REMOTE=y, для галочки «Remote Access» у БД в ISPConfig) — слушаем
	# 0.0.0.0 (localhost при этом продолжает работать). Доступ ограничивает firewall (3306).
	local _bind="127.0.0.1" _bindnote="только локально"
	if [[ "${MARIADB_REMOTE:-n}" == "y" ]]; then _bind="0.0.0.0"; _bindnote="наружу (remote access ISPConfig); 3306 ограничен firewall'ом"; fi
	cat >"$cnf" <<CNF
[mysqld]
character-set-server = utf8mb4
collation-server     = utf8mb4_general_ci
# bind-address: ${_bindnote}
bind-address = ${_bind}
# ISPConfig рекомендует отключить strict-режим (sql_mode)
sql_mode = "NO_ENGINE_SUBSTITUTION"
innodb_strict_mode = 0
CNF
	[[ "${MARIADB_REMOTE:-n}" == "y" ]] && ui_info "MariaDB слушает 0.0.0.0 (удалённый доступ). Доступ к 3306 — только с разрешённых IP (firewall)."
	sys_run "Перезапуск MariaDB" systemctl restart mariadb

	# --- Maintenance-аккаунт (гайд правит /etc/mysql/debian.cnf) ---
	# Не редактируем файл вслепую — проверяем доступ и чиним ТОЛЬКО при рассинхроне.
	_mariadb_ensure_maint "$root_pw"

	# --- Проверка ---
	local ver
	ver="$(mysql --version 2>/dev/null | awk '{print $0}')"
	ui_success "MariaDB готова: ${ver}"
	log "MariaDB root password сохранён в setup.conf (MARIADB_ROOT_PW) и /root/.my.cnf"

	# --- Redis ---
	_redis_install
	return 0
}

# Синхронизация служебного аккаунта MariaDB (debian-sys-maint) с /etc/mysql/debian.cnf.
# Гайд Perfect Server правит этот файл вручную; на свежей установке пакет уже держит
# пароль в синхроне — править нечего. Мы НЕ вписываем root-пароль вслепую (это ломает
# служебный аккаунт), а ПРОВЕРЯЕМ его доступ и чиним только при реальном рассинхроне.
# Им пользуются logrotate/mariadb-upgrade — без рабочего аккаунта они падают «Access denied».
_mariadb_ensure_maint() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} проверка maintenance-аккаунта (debian.cnf)"; return 0; }
	local f=/etc/mysql/debian.cnf
	[[ -f "$f" ]] || { ui_info "debian.cnf отсутствует — maintenance-аккаунт не настраиваю."; return 0; }
	# Обычный случай (свежая установка): аккаунт уже работает — файл не трогаем.
	if mysql --defaults-file="$f" -e 'SELECT 1' >/dev/null 2>&1; then
		ui_info "MariaDB: debian-sys-maint работает — debian.cnf править не нужно."
		return 0
	fi
	local mu mp
	mu="$(awk -F= '/^[[:space:]]*user[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$f")"
	mp="$(awk '/^[[:space:]]*password[[:space:]]*=/{sub(/^[[:space:]]*password[[:space:]]*=[[:space:]]*/,"");print;exit}' "$f")"
	mu="${mu:-debian-sys-maint}"
	if [[ "$mu" == "root" ]]; then
		# MariaDB 11+ и Debian 13: debian.cnf стал заглушкой с user=root без пароля (рассчитан на
		# вход root по сокету), а наш root входит по паролю. Пароль root здесь НЕ меняем, а вписываем
		# его в файл, как в гайде Perfect Server: файлом пользуются debian-start (mariadb-upgrade
		# после обновления MariaDB) и logrotate.
		local pw="${1:-}"
		[[ -n "$pw" ]] || { ui_warn "MariaDB: debian.cnf не подходит к root, а пароля root нет под рукой — пропуск."; return 0; }
		[[ -f "$f.luckystack.bak" ]] || cp -a "$f" "$f.luckystack.bak" 2>/dev/null || true
		local tmp; tmp="$(mktemp "$f.XXXXXX")" || return 0
		PW="$pw" awk '
			/^[[:space:]]*password[[:space:]]*=/ { next }
			{ print }
			/^[[:space:]]*user[[:space:]]*=[[:space:]]*root[[:space:]]*$/ { print "password = " ENVIRON["PW"] }
		' "$f" >"$tmp" && chmod 600 "$tmp" && chown root:root "$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 0; }
		if mysql --defaults-file="$f" -e 'SELECT 1' >/dev/null 2>&1; then
			ui_info "MariaDB: пароль root вписан в debian.cnf (нужен debian-start и logrotate)."
			log "database: debian.cnf дополнен паролем root"
		else
			ui_warn "MariaDB: debian.cnf всё ещё не подходит к root, проверьте файл вручную."
		fi
		return 0
	fi
	ui_warn "MariaDB: maintenance-аккаунт (debian.cnf) не аутентифицируется — синхронизирую."
	[[ -n "$mp" ]] || { ui_warn "В debian.cnf нет пароля — пропуск (отредактируйте вручную)."; return 0; }
	mysql --defaults-file=/root/.my.cnf <<SQL >>"$SETUP_LOG" 2>&1 || { ui_warn "Не удалось синхронизировать ${mu}."; return 0; }
CREATE USER IF NOT EXISTS '${mu}'@'localhost' IDENTIFIED BY '${mp}';
ALTER USER '${mu}'@'localhost' IDENTIFIED BY '${mp}';
GRANT ALL PRIVILEGES ON *.* TO '${mu}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
	if mysql --defaults-file="$f" -e 'SELECT 1' >/dev/null 2>&1; then
		ui_success "MariaDB: maintenance-аккаунт (${mu}) синхронизирован с debian.cnf."
	else
		ui_warn "MariaDB: maintenance-аккаунт всё ещё не проходит — см. $SETUP_LOG."
	fi
}

# Установка redis-server (если включён в мастере, по умолчанию — да).
_redis_install() {
	[[ "${INSTALL_REDIS:-y}" == "y" ]] || { ui_info "Redis отключён в настройках — пропуск."; return 0; }
	ui_step "Установка Redis (redis-server)"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt install redis-server + enable"
		return 0
	fi
	apt_install redis-server
	# supervised systemd — корректный запуск под systemd
	if [[ -f /etc/redis/redis.conf ]]; then
		sed -i 's|^supervised .*|supervised systemd|' /etc/redis/redis.conf 2>/dev/null || true
	fi
	_redis_tune
	# ВАЖНО: apt стартует redis сразу при установке, ДО _redis_tune. `enable --now` уже
	# запущенный сервис НЕ перезапускает → правки (supervised, maxmemory) не применяются.
	# Поэтому именно restart — он и стартует, если был остановлен, и применяет новый конфиг.
	systemctl enable redis-server >>"$SETUP_LOG" 2>&1 || true
	sys_run "Перезапуск Redis (применить конфиг)" systemctl restart redis-server
	ui_success "Redis установлен."
}

# Предохранитель Redis: maxmemory (потолок) + policy noeviction. На общей с MariaDB
# машине Redis без лимита раздувается до OOM-kill всей системы. noeviction (а не *-lru):
# Redis шарится с rspamd (bayes/fuzzy/history) — вытеснение испортило бы антиспам;
# при заполнении вместо потери данных Redis вернёт ошибку записи (мягкая деградация).
# Размер: 15% RAM, минимум 256M, потолок 2G. Идемпотентно.
_redis_tune() {
	local conf=/etc/redis/redis.conf ram_mb mm
	[[ -f "$conf" ]] || return 0
	ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
	[[ "$ram_mb" =~ ^[0-9]+$ ]] || ram_mb=2048
	mm=$(( ram_mb * 15 / 100 )); ((mm < 256)) && mm=256; ((mm > 2048)) && mm=2048

	if grep -qE '^[[:space:]]*maxmemory[[:space:]]+[0-9]' "$conf"; then
		sed -i -E "s|^[[:space:]]*maxmemory[[:space:]]+[0-9].*|maxmemory ${mm}mb|" "$conf"
	elif grep -qE '^[[:space:]]*#[[:space:]]*maxmemory[[:space:]]' "$conf"; then
		sed -i -E "0,/^[[:space:]]*#[[:space:]]*maxmemory[[:space:]].*/s|^[[:space:]]*#[[:space:]]*maxmemory[[:space:]].*|maxmemory ${mm}mb|" "$conf"
	else
		printf '\n# luckystack\nmaxmemory %smb\n' "$mm" >>"$conf"
	fi

	if grep -qE '^[[:space:]]*maxmemory-policy[[:space:]]' "$conf"; then
		sed -i -E "s|^[[:space:]]*maxmemory-policy[[:space:]].*|maxmemory-policy noeviction|" "$conf"
	elif grep -qE '^[[:space:]]*#[[:space:]]*maxmemory-policy[[:space:]]' "$conf"; then
		sed -i -E "0,/^[[:space:]]*#[[:space:]]*maxmemory-policy[[:space:]].*/s|^[[:space:]]*#[[:space:]]*maxmemory-policy[[:space:]].*|maxmemory-policy noeviction|" "$conf"
	else
		printf 'maxmemory-policy noeviction\n' >>"$conf"
	fi
	ui_info "Redis: maxmemory=${mm}mb, policy=noeviction (предохранитель от OOM; данные rspamd целы)."
}

stage_database_summary() {
	echo "MariaDB root password: ${MARIADB_ROOT_PW:-<в setup.conf>} · Redis: ${INSTALL_REDIS:-y}"
}
