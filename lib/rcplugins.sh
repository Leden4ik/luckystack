#!/bin/bash
# =============================================================================
# lib/rcplugins.sh — Этап (опц.): плагины ISPConfig для Roundcube (w2c).
#
#   Набор плагинов w2c/ispconfig3_roundcube встраивает самообслуживание прямо в
#   веб-почту Roundcube: смена пароля, автоответчик (отпуск), фильтры,
#   пересылка, бело/чёрный списки, антиспам — через ISPConfig remote API.
#   Пользователю не нужен доступ в панель ISPConfig.
#
#   Что делает этап:
#     1. скачивает плагины и кладёт выбранные в каталог плагинов Roundcube;
#     2. создаёт УЗКОГО remote API-пользователя ISPConfig (только почтовые
#        права) прямой вставкой в dbispconfig.remote_user;
#     3. проверяет доступ тест-логином по SOAP (с откатом на инструкцию);
#     4. прописывает плагинам доступ к API и включает их в конфиге Roundcube.
#
#   Требует установленных Roundcube (этап webmail) и ISPConfig (база dbispconfig).
#   Поэтому регистрируется ПОСЛЕ ispconfig.
# =============================================================================

# Плагины берём с конкретного проверенного коммита и сверяем sha256 архива. Раньше качалась
# ветка master: что бы ни оказалось в ней в момент установки, то и попадало в webmail.
# Обновить: выбрать новый коммит на github.com/w2c/ispconfig3_roundcube, посчитать sha256 архива
# https://github.com/w2c/ispconfig3_roundcube/archive/<коммит>.tar.gz и поменять обе строки.
RCPLUGINS_COMMIT="e8b2fbcc76eb6d46c4da08883abb05f0c31d0153"   # 2026-05-29, последний на 2026-11-05
RCPLUGINS_SHA256="c99271d15a74f9c0c3d6939adf1de237ac0f39e5dbd5e8a604da463810c60bff"
RCPLUGINS_URL="https://github.com/w2c/ispconfig3_roundcube/archive/${RCPLUGINS_COMMIT}.tar.gz"
# Набор по умолчанию (account — ядро, обязателен). fetchmail/autoselect не
# включаем по умолчанию (нишевые/чувствительные).
RCPLUGINS_DEFAULT="ispconfig3_account ispconfig3_pass ispconfig3_autoreply ispconfig3_filter ispconfig3_forward ispconfig3_spam ispconfig3_wblist"
# Права remote-пользователя — штатный набор ISPConfig «Roundcube plugins functions»
# (interface/web/admin/lib/remote.conf.php). ISPConfig сверяет права по ТОЧНЫМ именам функций
# (remoting.inc.php checkPerm: in_array), поэтому здесь имена функций, а не названия групп.
# Раньше тут стояли названия групп (mail_user_functions…) — у пользователя не было ни одного права.
RCPLUGINS_FUNCTIONS="client_get_id,login,logout,mail_alias_get,mail_fetchmail_add,mail_fetchmail_delete,mail_fetchmail_get,mail_fetchmail_update,mail_policy_get,mail_spamfilter_blacklist_add,mail_spamfilter_blacklist_delete,mail_spamfilter_blacklist_get,mail_spamfilter_blacklist_update,mail_spamfilter_user_add,mail_spamfilter_user_get,mail_spamfilter_user_update,mail_spamfilter_whitelist_add,mail_spamfilter_whitelist_delete,mail_spamfilter_whitelist_get,mail_spamfilter_whitelist_update,mail_user_filter_add,mail_user_filter_delete,mail_user_filter_get,mail_user_filter_update,mail_user_get,mail_user_update,server_get,server_get_app_version"

# Каталог плагинов Roundcube и его конфиг (Debian-пакет).
_rc_plugins_dir() {
	local d
	for d in /opt/roundcube/plugins /var/lib/roundcube/plugins /usr/share/roundcube/plugins /var/www/html/roundcube/plugins; do
		[[ -d "$d" ]] && { echo "$d"; return 0; }
	done
	return 1
}
_rc_config_file() {
	local f
	for f in /opt/roundcube/config/config.inc.php /etc/roundcube/config.inc.php /var/lib/roundcube/config/config.inc.php /usr/share/roundcube/config/config.inc.php; do
		[[ -f "$f" ]] && { echo "$f"; return 0; }
	done
	return 1
}
# mysql к dbispconfig (через /root/.my.cnf или root-пароль).
_rc_mysql() {
	if [[ -f /root/.my.cnf ]]; then mysql --defaults-file=/root/.my.cnf dbispconfig "$@"
	else mysql -uroot -p"${MARIADB_ROOT_PW:-}" dbispconfig "$@"; fi
}

stage_rcplugins() {
	local pdir cfg
	if ! pdir="$(_rc_plugins_dir)"; then
		ui_info "Roundcube не найден — этап плагинов ISPConfig пропущен (нужен компонент «Webmail»)."
		return 0
	fi
	if ! cfg="$(_rc_config_file)"; then
		ui_warn "Не найден config.inc.php Roundcube — пропуск плагинов."
		return 0
	fi
	if ! _rc_mysql -e 'SELECT 1' >/dev/null 2>&1; then
		ui_warn "База dbispconfig недоступна — плагины ISPConfig для Roundcube пропущены."
		return 0
	fi

	local plist="${RCPLUGINS:-$RCPLUGINS_DEFAULT}"
	local panel_port="${ISPCONFIG_PANEL_PORT:-8080}"
	ui_info "Плагины ISPConfig для Roundcube: ${plist}"

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} скачать w2c/ispconfig3_roundcube → ${pdir}"
		ui_info "${UI_D}[dry-run]${UI_NC} remote API-пользователь в dbispconfig.remote_user (только почта)"
		ui_info "${UI_D}[dry-run]${UI_NC} SOAP https://127.0.0.1:${panel_port}/remote/ + включение плагинов в ${cfg}"
		ui_success "Плагины ISPConfig для Roundcube (имитация) настроены."
		return 0
	fi

	# --- 1) Скачивание плагинов ---
	ui_step "Скачивание плагинов w2c/ispconfig3_roundcube"
	local tmp; tmp="$(mktemp -d)"
	if ! curl -fsSL --connect-timeout 15 --max-time 120 "$RCPLUGINS_URL" -o "$tmp/rc.tar.gz" 2>>"$SETUP_LOG"; then
		ui_warn "Не удалось скачать плагины (нет сети/доступа к GitHub) — пропуск."
		rm -rf "$tmp"; return 0
	fi
	local sum; sum="$(sha256sum "$tmp/rc.tar.gz" | awk '{print $1}')"
	if [[ "$sum" != "$RCPLUGINS_SHA256" ]]; then
		ui_warn "Архив плагинов Roundcube не совпал с проверенным (sha256 ${sum:0:16}…) — не ставлю. Проверьте RCPLUGINS_COMMIT/RCPLUGINS_SHA256 в lib/rcplugins.sh."
		rm -rf "$tmp"; return 0
	fi
	tar xzf "$tmp/rc.tar.gz" -C "$tmp" --no-same-owner --no-same-permissions 2>>"$SETUP_LOG" || { ui_warn "Архив плагинов повреждён — пропуск."; rm -rf "$tmp"; return 0; }
	local src; src="$(find "$tmp" -maxdepth 1 -type d -name 'ispconfig3_roundcube*' | head -1)"
	[[ -d "$src" ]] || { ui_warn "Каталог плагинов не найден в архиве — пропуск."; rm -rf "$tmp"; return 0; }

	# --- 2) remote API-пользователь ---
	_rc_enable_remote_api
	if ! _rc_create_remote_user; then
		ui_warn "Не удалось создать remote API-пользователя — плагины поставлю, но настройте доступ вручную (см. ниже)."
	fi

	# --- 3) Копирование выбранных плагинов + их настройка ---
	local soap_url; soap_url="$(_rc_soap_url "$panel_port")"
	local p copied=()
	for p in $plist; do
		if [[ ! -d "$src/$p" ]]; then ui_warn "Плагин $p не найден в репозитории — пропуск."; continue; fi
		rm -rf "${pdir:?}/$p"
		cp -R --no-preserve=mode,ownership "$src/$p" "$pdir/$p"
		perm_strip_gw_ow "$pdir/$p"
		_rc_write_plugin_config "$pdir/$p" "$soap_url"
		copied+=("$p")
	done
	rm -rf "$tmp"
	if ((${#copied[@]} == 0)); then ui_warn "Ни один плагин не скопирован — пропуск."; return 0; fi

	# --- 4) Включение плагинов в конфиге Roundcube ---
	_rc_enable_in_config "$cfg" "${copied[@]}"

	# --- 5) Права (в конфигах плагинов — пароль API) ---
	# Код плагинов — root, конфиги — root:www-data 640: читает только веб-процесс Roundcube.
	# Раньше группа бралась от каталога plugins (root) — и Roundcube не мог прочитать конфиг.
	chown -R root:root "$pdir"/ispconfig3_* 2>/dev/null || true
	find "$pdir"/ispconfig3_* -name 'config.inc.php' -exec chown root:www-data {} \; -exec chmod 640 {} \; 2>/dev/null || true

	# --- 6) Проверка доступа к API (необязательная, информативная) ---
	_rc_verify_api "$soap_url"

	ui_success "Плагины ISPConfig для Roundcube установлены: ${copied[*]}"
	ui_info "Пользователи Roundcube теперь могут менять пароль, ставить автоответчик, фильтры и пересылку."
	log "rcplugins: installed=${copied[*]} api_user=${RC_API_USER:-roundcube}"
	return 0
}

# --- Создание узкого remote API-пользователя ---------------------------------
# Прямая вставка в dbispconfig.remote_user (первого remote-юзера иначе не создать —
# для самого API уже нужен remote-пользователь). Пароль — crypt SHA-512.
_rc_create_remote_user() {
	RC_API_USER="${RCPLUGINS_API_USER:-roundcube}"
	RC_API_PW="$(gen_password 24)"
	local hash
	hash="$(openssl passwd -6 "$RC_API_PW" 2>/dev/null)"
	[[ -n "$hash" ]] || { ui_warn "openssl passwd недоступен — не могу создать API-пользователя."; return 1; }
	ui_step "Создание remote API-пользователя ISPConfig: ${RC_API_USER} (только почта)"
	# ВАЖНО: колонки ISPConfig — remote_username/remote_password/remote_functions
	# (+ remote_access='y', remote_ips NULL = с любого IP). Имена username/password/
	# functions в этой таблице НЕ существуют (ERROR 1054).
	# Идемпотентно: убираем прежнего одноимённого.
	_rc_mysql -e "DELETE FROM remote_user WHERE remote_username='${RC_API_USER}';" >>"$SETUP_LOG" 2>&1 || true
	# Экранируем хеш для SQL (содержит '$' и '/', но не кавычки).
	local h_esc="${hash//\'/\'\'}"
	if _rc_mysql -e "INSERT INTO remote_user \
		(sys_userid,sys_groupid,sys_perm_user,sys_perm_group,sys_perm_other,remote_username,remote_password,remote_access,remote_functions) \
		VALUES (1,1,'riud','riud','','${RC_API_USER}','${h_esc}','y','${RCPLUGINS_FUNCTIONS}');" >>"$SETUP_LOG" 2>&1; then
		# Сохраняем для справки/повторов
		declare -F config_set >/dev/null && { config_set RCPLUGINS_API_USER "$RC_API_USER"; config_set RCPLUGINS_API_PW "$RC_API_PW"; }
		ui_success "remote API-пользователь создан (права: только почтовые функции)."
		return 0
	fi
	ui_warn "INSERT в remote_user не выполнился — проверьте структуру dbispconfig."
	return 1
}

# --- Запись config.inc.php плагина с доступом к API --------------------------
# Берём dist как основу (если есть) и дописываем наши значения в КОНЦЕ —
# они перекрывают дефолты независимо от имени переменной ($config/$rcmail_config).
_rc_write_plugin_config() {
	local dir="$1" url="$2" cfg="$1/config/config.inc.php" dist="$1/config/config.inc.php.dist"
	mkdir -p "$dir/config" 2>/dev/null || true
	if [[ -f "$dist" ]]; then cp -f "$dist" "$cfg"; else printf '<?php\n' >"$cfg"; fi
	cat >>"$cfg" <<PHP

// LuckyStack — доступ к ISPConfig remote API (ключи, которые читают плагины w2c)
\$config['soap_url'] = '${url}';
\$config['remote_soap_user'] = '${RC_API_USER:-roundcube}';
\$config['remote_soap_pass'] = '${RC_API_PW:-}';
\$config['soap_validate_cert'] = false;
PHP
	# внутри пароль remote API: читать может только веб-процесс (www-data), но не все.
	# Раньше выходило root:root 640 — Roundcube не мог прочитать файл, и плагин работал без API.
	chown root:www-data "$cfg" 2>/dev/null; chmod 640 "$cfg" 2>/dev/null
	return 0
}

# --update: права конфигов плагинов (раньше root:root 640 — Roundcube их не читал)
_rc_fix_plugin_perms() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	local f n=0
	for f in /opt/roundcube/plugins/*/config/config.inc.php /var/lib/roundcube/plugins/*/config/config.inc.php; do
		[[ -f "$f" && ! -L "$f" ]] || continue
		[[ "$(stat -c '%U:%G %a' "$f")" == "root:www-data 640" ]] && continue
		chown root:www-data "$f" && chmod 640 "$f" && n=$((n + 1))
	done
	((n)) && ui_success "Конфиги плагинов Roundcube: root:www-data 640 (${n} шт.) — теперь веб-почта их читает, а остальные нет."
	# Адрес API: 127.0.0.1 не проходит «панель только по FQDN» (nginx отвечает 444)
	local port url m=0
	port="$(grep -m1 -oE 'listen[[:space:]]+[0-9]+' /etc/nginx/sites-available/ispconfig.vhost 2>/dev/null | grep -oE '[0-9]+$')"
	port="${port:-${ISPCONFIG_PANEL_PORT:-8080}}"
	url="$(_rc_soap_url "$port")"
	local k=0
	for f in /opt/roundcube/plugins/*/config/config.inc.php /var/lib/roundcube/plugins/*/config/config.inc.php; do
		[[ -f "$f" && ! -L "$f" ]] || continue
		# Прежние установки писали remote_soap_url / remote_soap_password, а плагины читают
		# soap_url / remote_soap_pass — и брали адрес-заглушку из .dist (запрос висел до 504).
		if grep -q "\$config\['remote_soap_password'\]" "$f" && ! grep -q "luckystack: ключи плагина" "$f"; then
			printf '\n// luckystack: ключи плагина (soap_url / remote_soap_pass)\n$config['"'"'soap_url'"'"'] = $config['"'"'remote_soap_url'"'"'];\n$config['"'"'remote_soap_pass'"'"'] = $config['"'"'remote_soap_password'"'"'];\n$config['"'"'soap_validate_cert'"'"'] = false;\n' >>"$f"
			k=$((k + 1))
		fi
		[[ "$url" == https://127.0.0.1:* ]] && continue
		grep -qE "soap_url'\] = 'https://127\.0\.0\.1:" "$f" || continue
		sed -i -E "s#((remote_)?soap_url'\] = )'https://127\.0\.0\.1:[0-9]+/remote/'#\1'${url}'#" "$f" && m=$((m + 1))
	done
	((k)) && ui_success "Плагины Roundcube: ключи доступа к API исправлены (${k} шт.) — раньше плагины их не видели."
	((m)) && ui_success "Плагины Roundcube: адрес API ${url} (${m} шт.) — 127.0.0.1 панель с «только по FQDN» отбрасывала."
	# Права remote-пользователя: прежние установки записали названия групп вместо функций
	local apiu="${RC_API_USER:-${RCPLUGINS_API_USER:-roundcube}}" curf
	curf="$(_rc_mysql -NBe "SELECT remote_functions FROM remote_user WHERE remote_username='${apiu}'" 2>/dev/null)"
	if [[ -n "$curf" && "$curf" != "$RCPLUGINS_FUNCTIONS" && ",${curf//;/,}," != *",mail_user_get,"* ]]; then
		_rc_mysql -e "UPDATE remote_user SET remote_functions='${RCPLUGINS_FUNCTIONS}' WHERE remote_username='${apiu}'" >>"$SETUP_LOG" 2>&1 \
			&& ui_success "Remote API-пользователь ${apiu}: права по набору ISPConfig «Roundcube plugins functions» (раньше не было ни одного)."
	fi
	return 0
}

# Адрес remote API панели для плагинов. Если панель отвечает только по FQDN
# (hostcert: panel-fqdn-only, иначе 444) — ходим по FQDN; он резолвится в этот же сервер.
_rc_soap_url() {
	local port="${1:-${ISPCONFIG_PANEL_PORT:-8080}}" fqdn="${SERVER_FQDN:-$(hostname -f 2>/dev/null)}"
	if [[ -n "$fqdn" ]] && grep -q 'panel-fqdn-only' /etc/nginx/sites-available/ispconfig.vhost 2>/dev/null \
	   && getent hosts "$fqdn" >/dev/null 2>&1; then
		echo "https://${fqdn}:${port}/remote/"
	else
		echo "https://127.0.0.1:${port}/remote/"
	fi
}

# --- Включение плагинов в основном конфиге Roundcube -------------------------
# Дописываем merge-блок в КОНЕЦ config.inc.php — он сольёт наш список с уже
# существующим $config['plugins'] без правки PHP-массива по месту.
_rc_enable_in_config() {
	local cfg="$1"; shift
	local list="" p
	for p in "$@"; do list+="'${p}',"; done
	if grep -q "luckystack: плагины ISPConfig" "$cfg" 2>/dev/null; then
		return 0   # уже добавляли — не дублируем
	fi
	cp -a "$cfg" "${cfg}.luckystack.bak" 2>/dev/null || true
	cat >>"$cfg" <<PHP

// luckystack: плагины ISPConfig для Roundcube
\$config['plugins'] = array_values(array_unique(array_merge(
	(array)(isset(\$config['plugins']) ? \$config['plugins'] : array()),
	array(${list})
)));
PHP
	ui_success "Плагины включены в конфиге Roundcube (${cfg})."
}

# Свежие сборки ISPConfig 3.3 по умолчанию выключают remote API (remote_api_allowed=no в
# security_settings.ini), и плагины получают «Remote API is disabled in security settings».
# Включаем только здесь, раз плагинам он нужен; права самого API-пользователя узкие.
_rc_enable_remote_api() {
	local f=/usr/local/ispconfig/security/security_settings.ini
	[[ -f "$f" ]] || return 0
	grep -qE '^remote_api_allowed=yes[[:space:]]*$' "$f" && return 0
	[[ -f "$f.luckystack.bak" ]] || cp -a "$f" "$f.luckystack.bak" 2>/dev/null || true
	if grep -qE '^remote_api_allowed=' "$f"; then
		sed -i -E 's/^remote_api_allowed=.*/remote_api_allowed=yes/' "$f"
	else
		printf 'remote_api_allowed=yes\n' >>"$f"
	fi
	ui_info "Remote API ISPConfig включён (security_settings.ini): через него работают плагины Roundcube."
	log "rcplugins: remote_api_allowed=yes в $f"
}

# Один тест-логин по SOAP → echo OK/FAIL/NOSOAP/NOPHP/ERR:..
_rc_soap_login_test() {
	local url="$1" php="" v
	for v in php php8.3 php8.2 php8.4 php8.1 php8.0; do command -v "$v" >/dev/null 2>&1 && { php="$v"; break; }; done
	[[ -n "$php" ]] || { echo "NOPHP"; return 0; }
	"$php" -r '
		if(!class_exists("SoapClient")){ echo "NOSOAP"; exit; }
		$ctx = stream_context_create(["ssl"=>["verify_peer"=>false,"verify_peer_name"=>false]]);
		try {
			$c = new SoapClient(null, ["location"=>$argv[1]."index.php","uri"=>$argv[1],"stream_context"=>$ctx,"connection_timeout"=>10]);
			$sid = $c->login($argv[2],$argv[3]);
			if($sid){ echo "OK"; $c->logout($sid); } else echo "FAIL";
		} catch(Exception $e){ echo "ERR:".$e->getMessage(); }
	' "$url" "${RC_API_USER:-roundcube}" "${RC_API_PW:-}" 2>/dev/null
}

# --- Проверка доступа к remote API тест-логином (+ самовосстановление хеша) ---
_rc_verify_api() {
	local url="$1" out
	out="$(_rc_soap_login_test "$url")"
	# Если пароль не принят — возможно, версия ISPConfig сверяет md5 (старая схема).
	# Перезаписываем хеш на md5 и пробуем ещё раз.
	if [[ "$out" == "FAIL" ]]; then
		local md5h; md5h="$(printf '%s' "${RC_API_PW:-}" | md5sum 2>/dev/null | awk '{print $1}')"
		if [[ -n "$md5h" ]]; then
			_rc_mysql -e "UPDATE remote_user SET remote_password='${md5h}' WHERE remote_username='${RC_API_USER:-roundcube}';" >>"$SETUP_LOG" 2>&1 || true
			out="$(_rc_soap_login_test "$url")"
			[[ "$out" == "OK" ]] && ui_info "remote API: применена md5-схема пароля (старая версия ISPConfig)."
		fi
	fi
	case "$out" in
		OK)      ui_success "Проверка remote API: вход успешен — плагины смогут управлять почтой." ;;
		NOSOAP)  ui_warn "В PHP нет расширения SOAP (php-soap) — плагины не смогут обращаться к API. Установите php-soap." ;;
		NOPHP)   ui_info "PHP CLI не найден — проверку API пропускаю." ;;
		FAIL|ERR:*) ui_warn "Тест-логин в remote API не прошёл (${out}). Проверьте System → Remote Users в панели."
		         ui_info "Пользователь ${RC_API_USER:-roundcube} должен иметь права: ${RCPLUGINS_FUNCTIONS}" ;;
		*)       ui_info "Не удалось однозначно проверить API (${out:-нет ответа}) — проверьте вход в Roundcube вручную." ;;
	esac
	return 0
}

stage_rcplugins_summary() {
	echo "Roundcube plugins: ISPConfig (пароль/автоответчик/фильтры/пересылка)"
}
