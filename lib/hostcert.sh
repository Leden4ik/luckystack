#!/bin/bash
# =============================================================================
# lib/hostcert.sh — Этап (опц.): реальный Let's Encrypt-сертификат для FQDN
# сервера (панель ISPConfig + Postfix/Dovecot).
#
#   По умолчанию панель и почта работают на САМОПОДПИСАННОМ сертификате
#   (ispserver.crt) — браузеры/почтовые клиенты ругаются. Этот этап выпускает
#   настоящий LE-сертификат на hostname сервера через acme.sh (webroot) и ставит
#   его в:
#     • панель ISPConfig — /usr/local/ispconfig/interface/ssl/ispserver.{crt,key,pem}
#     • Postfix (smtpd_tls_*) и Dovecot (ssl_cert/ssl_key)
#   Авто-продление — через acme.sh (--reloadcmd переустанавливает серт и
#   перезагружает службы).
#
#   ВАЖНО: LE требует ПУБЛИЧНЫЙ домен, A-запись которого указывает на этот сервер,
#   и открытый порт 80. Если условия не выполнены (тестовый стенд, example.com,
#   домен не делегирован) — этап МЯГКО пропускается, панель остаётся на self-signed.
#   Поэтому стоит запускать на боевом VPS с настроенным DNS.
# =============================================================================

HOSTCERT_DEPLOY=/usr/local/sbin/ispconfig-hostcert-deploy.sh
ISPC_SSL_DIR=/usr/local/ispconfig/interface/ssl

# Уже выпущен ли LE-серт для домена (acme.sh хранит в /root/.acme.sh/<домен>[_ecc]/).
_hostcert_exists() {
	[[ -f "/root/.acme.sh/${1}/fullchain.cer" || -f "/root/.acme.sh/${1}_ecc/fullchain.cer" ]]
}

# Предупредить, если запрошен запрет панели по IP, но hostcert пропускается — иначе
# юзер думает, что вход по IP закрыт, а блок не поставился (он ставится только при
# успешном выпуске LE = публичный FQDN, указывающий на сервер).
_hostcert_skip_fqdnonly_note() {
	[[ "${PANEL_FQDN_ONLY:-n}" == "y" ]] && \
		ui_warn "PANEL_FQDN_ONLY=y, но hostcert пропущен — запрет входа в панель по IP НЕ применён (нужен публичный FQDN на этот сервер)."
	return 0
}

# Self-probe: реально ли http://FQDN/.well-known/acme-challenge/ отдаётся ИЗ webroot.
# Проверяем локально (--resolve на 127.0.0.1, со следованием http→https), чтобы поймать
# несовпадение docroot/редирект ДО обращения к LE. rc=0 — челлендж отдаётся из webroot.
_hostcert_probe_webroot() {  # $1=fqdn $2=webroot
	local fqdn="$1" wr="$2" tok="luckystack-probe-$$-${RANDOM}"
	command -v curl >/dev/null 2>&1 || return 0   # нет curl — не мешаем (probe пропущен)
	[[ -d "$wr" ]] || return 1
	mkdir -p "$wr/.well-known/acme-challenge" 2>/dev/null || return 1
	echo "$tok" > "$wr/.well-known/acme-challenge/$tok" 2>/dev/null || return 1
	local got
	got="$(curl -sLk --max-time 8 \
		--resolve "${fqdn}:80:127.0.0.1" --resolve "${fqdn}:443:127.0.0.1" \
		"http://${fqdn}/.well-known/acme-challenge/${tok}" 2>/dev/null)"
	rm -f "$wr/.well-known/acme-challenge/$tok" 2>/dev/null || true
	[[ "$got" == "$tok" ]]
}

# Определить docroot живого vhost'а для FQDN (nginx root / apache DocumentRoot).
_hostcert_detect_docroot() {  # $1=fqdn -> docroot в stdout
	local fqdn="$1" f root
	for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
		[[ -f "$f" ]] || continue
		grep -qE "server_name[^;]*(\s|^)${fqdn}(\s|;)" "$f" 2>/dev/null || continue
		root="$(grep -oP '^\s*root\s+\K[^;]+' "$f" 2>/dev/null | head -1 | tr -d '"')"
		[[ -n "$root" ]] && { echo "$root"; return 0; }
	done
	for f in /etc/apache2/sites-enabled/*; do
		[[ -f "$f" ]] || continue
		grep -qiE "Server(Name|Alias)[^#]*(\s)${fqdn}(\s|$)" "$f" 2>/dev/null || continue
		root="$(grep -oiP '^\s*DocumentRoot\s+\K\S+' "$f" 2>/dev/null | head -1 | tr -d '"')"
		[[ -n "$root" ]] && { echo "$root"; return 0; }
	done
	return 1
}

stage_hostcert() {
	local fqdn="${SERVER_FQDN:-$(hostname -f 2>/dev/null || hostname)}"

	# --- Базовая вменяемость FQDN ---
	if [[ -z "$fqdn" || "$fqdn" != *.* ]]; then
		ui_info "FQDN не задан/без домена ('${fqdn}') — выпуск LE для хоста пропущен."
		return 0
	fi
	case "$fqdn" in
		localhost|*.local|*.lan|*.internal|*.localdomain|*.test|*.example.com|*.example.org|example.com|example.org)
			ui_info "FQDN '${fqdn}' не публичный — выпуск LE для хоста пропущен (нужен реальный домен)."
			_hostcert_skip_fqdnonly_note; return 0 ;;
	esac
	if [[ ! -f "$ISPC_SSL_DIR/ispserver.crt" ]]; then
		ui_info "ISPConfig не установлен — выпуск LE для хоста пропущен."
		return 0
	fi

	ui_info "Реальный Let's Encrypt-сертификат для ${UI_BOLD}${fqdn}${UI_NC} (панель + почта)."

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} проверка публичной A-записи + порт 80"
		ui_info "${UI_D}[dry-run]${UI_NC} acme.sh --issue -d ${fqdn} -w /var/www/html --server letsencrypt"
		ui_info "${UI_D}[dry-run]${UI_NC} установка в ispserver.{crt,key,pem} + Postfix/Dovecot + авто-продление"
		ui_success "LE для хоста (имитация) настроен."
		return 0
	fi

	# --- Публичная достижимость: A-запись FQDN должна указывать на наш внешний IP ---
	local pub dns
	pub="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null)"
	if command -v dig >/dev/null 2>&1; then
		dns="$(dig +short A "$fqdn" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)"
	else
		dns="$(getent ahostsv4 "$fqdn" 2>/dev/null | awk '{print $1; exit}')"
	fi
	if [[ -z "$pub" || -z "$dns" || "$pub" != "$dns" ]]; then
		ui_warn "FQDN ${fqdn} не указывает на этот сервер (DNS A=${dns:-нет}, наш IP=${pub:-?}) — LE пропущен."
		ui_info "Настройте A-запись ${fqdn} → ${pub:-<IP сервера>} и откройте порт 80, затем: ${UI_W}$(ls_hint --only hostcert)${UI_NC}"
		ui_info "Пока панель/почта остаются на самоподписанном сертификате (это рабочее, но браузер предупреждает)."
		_hostcert_skip_fqdnonly_note; return 0
	fi

	# --- acme.sh ---
	local acme=/root/.acme.sh/acme.sh
	if [[ ! -x "$acme" ]]; then
		ui_warn "acme.sh не найден — LE для хоста пропущен (его ставит этап SSL; SSL_PROVIDER=acme)."
		_hostcert_skip_fqdnonly_note; return 0
	fi

	# --- webroot для HTTP-01 ---------------------------------------------------
	# По умолчанию /var/www/html (наша разметка). На стороннем/ручном сервере домен
	# может отдаваться из ДРУГОГО docroot (или редиректить) → LE получит «неправильный
	# ответ». Поэтому: self-probe (реально ли челлендж отдаётся из webroot) → если нет,
	# пробуем автодетект docroot живого vhost'а → если и он не отдаёт, честно стопаем с
	# ТОЧНЫМ сообщением (а не вводящим в заблуждение «A-запись/порт/CAA»).
	local webroot="${HOSTCERT_WEBROOT:-/var/www/html}"
	mkdir -p "$webroot/.well-known/acme-challenge" 2>/dev/null || true
	if command -v curl >/dev/null 2>&1 && ! _hostcert_probe_webroot "$fqdn" "$webroot"; then
		local _detected; _detected="$(_hostcert_detect_docroot "$fqdn")"
		if [[ -n "$_detected" && "$_detected" != "$webroot" ]] && _hostcert_probe_webroot "$fqdn" "$_detected"; then
			ui_info "HTTP-01: ${fqdn} отдаётся из ${UI_W}${_detected}${UI_NC} (не ${webroot}) — использую этот webroot."
			webroot="$_detected"
		else
			ui_warn "HTTP-01: челлендж http://${fqdn}/.well-known/acme-challenge/ НЕ отдаётся из ${webroot}."
			ui_info "Причина — домен обслуживается другим vhost/docroot или редиректит на https (НЕ A-запись/порт/CAA)."
			ui_info "Решение: укажи реальный docroot — ${UI_W}HOSTCERT_WEBROOT=/путь/к/docroot $(ls_hint --only hostcert)${UI_NC}"
			ui_info "Либо выпусти серт средствами ISPConfig (LE-галка у сайта/панели) или через DNS-01."
			_hostcert_skip_fqdnonly_note
			return 0
		fi
	fi

	# Скрипт переустановки серта (вызывается acme.sh при выпуске и при каждом продлении)
	_hostcert_write_deploy

	# --- Выпуск ---
	# LE_STAGING=y → staging-CA: серт НЕ доверенный, но БЕЗ rate-limit (тест/частые прогоны).
	local le_server="letsencrypt"
	if [[ "${LE_STAGING:-n}" == "y" ]]; then
		le_server="letsencrypt_test"
		ui_warn "LE_STAGING=y — выпуск на staging-CA: серт НЕ доверенный (тест), лимит LE не тратится."
	fi
	ui_step "Выпуск/проверка LE-сертификата для ${fqdn} (webroot ${webroot})"
	local issue_rc=0
	# acme.sh выходит с кодом 2, когда сертификат свежий и выпускать нечего («Skip, Next renewal time»):
	# это не ошибка, и на экране не должно быть красного крестика (при каждом luckyctl update).
	_hostcert_acme_issue() { "$@"; local rc=$?; ((rc == 2)) && return 0; return "$rc"; }
	ui_spin "acme.sh --issue ${fqdn}" _hostcert_acme_issue "$acme" --issue -d "$fqdn" -w "$webroot" --server "$le_server" || issue_rc=$?
	# ВАЖНО: acme.sh возвращает ≠0 и когда серт УЖЕ выпущен и не требует продления
	# («Domains not changed / Skipping») — это НЕ ошибка. Считаем провалом ТОЛЬКО
	# если серта реально нет в /root/.acme.sh.
	if ((issue_rc != 0)); then
		if _hostcert_exists "$fqdn"; then
			ui_info "Сертификат для ${fqdn} уже выпущен и актуален — переустанавливаю в панель/почту."
		else
			# Разбираем причину из лога acme — частый случай: rate-limit Let's Encrypt.
			local _acme_log=/var/log/ispconfig/acme.log
			if grep -qiE "rateLimited|too many certificates" "$_acme_log" 2>/dev/null; then
				local _retry; _retry="$(grep -oiE "retry after [0-9T:Z +-]+" "$_acme_log" 2>/dev/null | tail -1)"
				ui_error "Let's Encrypt: исчерпан лимит сертификатов для ${fqdn} (5 в неделю на один набор доменов)."
				[[ -n "$_retry" ]] && ui_info "Повтор после: ${UI_W}${_retry} UTC${UI_NC}."
				ui_info "Дальше: дождаться сброса и ${UI_W}$(ls_hint --only hostcert)${UI_NC};"
				ui_info "либо тест без лимита — ${UI_W}LE_STAGING=y $(ls_hint --only hostcert)${UI_NC} (серт НЕ доверенный)."
			else
				ui_warn "Выпуск LE не удался. Проверьте: A-запись ${fqdn}→${pub}, порт 80 открыт снаружи, нет CAA-блокировки."
				ui_info "Подробности: ${UI_W}${_acme_log}${UI_NC}. Повторить: ${UI_W}$(ls_hint --only hostcert)${UI_NC}."
			fi
			ui_warn "Панель/почта остаются на self-signed-сертификате."
			# КЛЮЧЕВОЕ (баг, который ловили): запрет панели по IP ставится ТОЛЬКО при
			# успешном LE — здесь он НЕ применён. Раньше об этом молчали → юзер думал,
			# что вход по IP закрыт. Теперь предупреждаем явно.
			_hostcert_skip_fqdnonly_note
			return 0
		fi
	fi

	# --- Установка в панель + reloadcmd (mail/службы) ---
	if "$acme" --install-cert -d "$fqdn" \
		--key-file "$ISPC_SSL_DIR/ispserver.key" \
		--fullchain-file "$ISPC_SSL_DIR/ispserver.crt" \
		--reloadcmd "$HOSTCERT_DEPLOY" >>"$SETUP_LOG" 2>&1; then
		ui_success "LE-сертификат $( ((issue_rc)) && echo "(действующий) " )установлен: панель https://${fqdn}:${ISPCONFIG_PANEL_PORT:-8080} + почта."
		ui_info "Авто-продление — через acme.sh (cron), с переустановкой и перезагрузкой служб."
	else
		ui_warn "Установка сертификата завершилась с замечаниями — см. ${SETUP_LOG}."
	fi

	# Сайт хоста по FQDN на :443 с LE-сертом — чтобы https://FQDN/roundcube (и
	# /phpmyadmin) открывались (иначе упираются в default :443 c ssl_reject_handshake).
	_hostcert_fqdn_website "$fqdn"
	# Вебпочта при свежей установке ставится раньше этого сайта и проверить страницу входа не могла
	if [[ -f "${RC_DIR:-/opt/roundcube}/program/include/iniset.php" ]] && declare -F _rcu_check_page >/dev/null; then
		# Сайт только что включён, а reload nginx мягкий: новые воркеры поднимаются не сразу.
		local _i _ok=1
		for _i in 1 2 3 4 5 6; do _rcu_check_page && { _ok=0; break; }; sleep 5; done
		if ((_ok == 0)); then ui_success "Roundcube: страница входа открывается (https://${fqdn}/roundcube/)."
		else ui_warn "Roundcube: страница входа https://${fqdn}/roundcube/ не открылась — проверьте ${RC_LOG_DIR:-/var/log/roundcube}/errors.log."; fi
	fi

	# Запрет входа в панель по IP (только по FQDN) — безопасно: сюда дошли только
	# когда A-запись ${fqdn} реально указывает на этот сервер (проверка выше).
	_hostcert_panel_fqdn_only "$fqdn"

	log "hostcert: fqdn=${fqdn} ip=${pub} issued via acme.sh"
	return 0
}

# Отдавать стартовый сайт хоста (/var/www/html: roundcube, phpmyadmin) по FQDN на
# :443 с валидным LE-сертом + редирект http→https. Без этого https://FQDN/... упирается
# в default-сервер (TLS отклоняется) — вебмейл по домену «не открывается». Отключение:
# HOST_FQDN_SITE=n. Диспетчер по веб-серверу (реализации ниже).
_hostcert_fqdn_website() {
	[[ "${HOST_FQDN_SITE:-y}" == "y" ]] || return 0
	local fqdn="$1"
	[[ -f "$ISPC_SSL_DIR/ispserver.crt" && -f "$ISPC_SSL_DIR/ispserver.key" ]] || {
		ui_info "Нет ispserver.crt/key — FQDN-сайт хоста пропущен."; return 0; }
	case "${WEBSERVER:-nginx}" in
		nginx)  _fqdn_website_nginx  "$fqdn" ;;
		apache) _fqdn_website_apache "$fqdn" ;;
	esac
}

# --- nginx: conf.d с redirect+ACME (:80) и сайтом :443 на LE-серте ---
_fqdn_website_nginx() {
	local fqdn="$1" conf=/etc/nginx/conf.d/10-host-fqdn.conf
	ui_step "Сайт хоста по FQDN (https://${fqdn}/roundcube, /phpmyadmin) с LE-сертом [nginx]"
	[[ -f "$conf" ]] && cp -a "$conf" "${conf}.bak" 2>/dev/null || true
	cat >"$conf" <<NGX
# luckystack: стартовый сайт хоста по FQDN (вебмейл/инструменты) с LE-сертом.
# Редирект http→https; статика+PHP из /var/www/html (симлинки roundcube/phpmyadmin).
server {
    listen 80;
    listen [::]:80;
    server_name ${fqdn};
    # ACME http-01: отдаём челлендж из ОБОИХ webroot'ов — acme.sh (/var/www/html)
    # и ISPConfig (/usr/local/ispconfig/interface/acme), чтобы продление любого серта
    # не зависело от того, чей это :80 (наш блок конфликтует с acme.vhost ISPConfig).
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
        try_files \$uri @ispc_acme;
    }
    location @ispc_acme { root /usr/local/ispconfig/interface/acme; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${fqdn};
    ssl_certificate     ${ISPC_SSL_DIR}/ispserver.crt;
    ssl_certificate_key ${ISPC_SSL_DIR}/ispserver.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/html;
    index index.php index.html;
    location ~ /\\.(?!well-known) { deny all; }
    # ограничения веб-админки БД (dbadmin-restrict: только по FQDN и с разрешённых IP) и др.
    include /etc/nginx/snippets/default-locations/*.conf;
    location ~ \\.php\$ { include snippets/php-default.conf; }
}
NGX
	if nginx -t >>"$SETUP_LOG" 2>&1; then
		systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
		rm -f "${conf}.bak"
		ui_success "Сайт хоста по FQDN включён: ${UI_C}https://${fqdn}/roundcube${UI_NC} (валидный LE-серт)."
	else
		# Откат: вернуть прежний конфиг из бэкапа; если бэкапа не было (файл создавался
		# впервые) — убрать наш новый. ВАЖНО: if/then/else, а не '&& mv || rm', иначе
		# сбой mv привёл бы к rm живого конфига.
		if [[ -f "${conf}.bak" ]]; then
			mv -f "${conf}.bak" "$conf"
		else
			rm -f "$conf"
		fi
		systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
		ui_warn "nginx -t не прошёл — FQDN-сайт хоста не включён (см. ${SETUP_LOG})."
	fi
}

# --- apache: vhost :80 (redirect+ACME) и :443 на LE-серте, PHP через mod_proxy_fcgi ---
# ВНИМАНИЕ: реализация не проверена на живом Apache — нужна верификация configtest'ом.
_fqdn_website_apache() {
	local fqdn="$1" conf=/etc/apache2/sites-available/luckystack-host-fqdn.conf
	local phpsock="/run/php/php${PHP_DEFAULT:-8.4}-fpm.sock"
	[[ -S "$phpsock" ]] || phpsock="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)"
	[[ -n "$phpsock" ]] || { ui_warn "Не найден php-fpm сокет — FQDN-сайт (Apache) пропущен."; return 0; }
	ui_step "Сайт хоста по FQDN (https://${fqdn}/roundcube, /phpmyadmin) с LE-сертом [apache]"
	a2enmod ssl rewrite proxy_fcgi headers >>"$SETUP_LOG" 2>&1 || true
	[[ -f "$conf" ]] && cp -a "$conf" "${conf}.bak" 2>/dev/null || true
	cat >"$conf" <<APA
# luckystack: стартовый сайт хоста по FQDN (вебмейл/инструменты) с LE-сертом.
# ТОЛЬКО :443. Отдельный :80-redirect-vhost конфликтует с 000-default (тот — default
# на :80 с глобальным ServerName=FQDN, грузится первым) и не выигрывает; делать наш
# первым = он станет catch-all для всех :80-хостов. Поэтому :80 не трогаем (его держит
# 000-default + ISPConfig acme.conf), доступ к вебмейлу — по https://FQDN/...
<VirtualHost *:443>
    ServerName ${fqdn}
    DocumentRoot /var/www/html
    DirectoryIndex index.php index.html
    SSLEngine on
    SSLCertificateFile ${ISPC_SSL_DIR}/ispserver.crt
    SSLCertificateKeyFile ${ISPC_SSL_DIR}/ispserver.key
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    <Directory "/var/www/html">
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
    <DirectoryMatch "/\\.(?!well-known)">
        Require all denied
    </DirectoryMatch>
    <FilesMatch "\\.php\$">
        SetHandler "proxy:unix:${phpsock}|fcgi://localhost"
    </FilesMatch>
</VirtualHost>
APA
	a2ensite luckystack-host-fqdn >>"$SETUP_LOG" 2>&1 || true
	if web_configtest; then
		web_reload; rm -f "${conf}.bak"
		ui_success "Сайт хоста по FQDN включён: ${UI_C}https://${fqdn}/roundcube${UI_NC} (Apache, LE-серт)."
	else
		a2dissite luckystack-host-fqdn >>"$SETUP_LOG" 2>&1 || true
		if [[ -f "${conf}.bak" ]]; then mv -f "${conf}.bak" "$conf"; a2ensite luckystack-host-fqdn >>"$SETUP_LOG" 2>&1 || true
		else rm -f "$conf"; fi
		web_reload
		ui_warn "apache configtest не прошёл — FQDN-сайт хоста не включён (см. ${SETUP_LOG})."
	fi
}

# Закрыть доступ к панели ISPConfig по IP, оставив только FQDN. Реализация для
# nginx: внутрь vhost панели добавляется проверка $host (return 444 для не-FQDN) —
# это «безопасное» использование if (return/rewrite). С бэкапом, nginx -t и
# авто-откатом, чтобы не отрезать доступ. Идемпотентно (маркер). Gated PANEL_FQDN_ONLY.
_hostcert_panel_fqdn_only() {
	case "${WEBSERVER:-nginx}" in
		nginx)  _panel_fqdn_only_nginx  "$1" ;;
		apache) _panel_fqdn_only_apache "$1" ;;
	esac
}

# --- nginx: вставка `if ($host != FQDN) { return 444; }` в vhost панели ---
_panel_fqdn_only_nginx() {
	local fqdn="$1"
	local vhost="" cand
	for cand in /etc/nginx/sites-available/ispconfig.vhost /etc/nginx/sites-enabled/000-ispconfig.vhost; do
		[[ -f "$cand" ]] && { vhost="$cand"; break; }
	done
	[[ -n "$vhost" ]] || { [[ "${PANEL_FQDN_ONLY:-n}" == "y" ]] && ui_info "vhost панели не найден — запрет по IP пропущен."; return 0; }

	local present=0; grep -q "luckystack: panel-fqdn-only" "$vhost" && present=1

	# --- ОТКЛЮЧЕНИЕ: PANEL_FQDN_ONLY!=y — снимаем блок, если он стоит ---
	if [[ "${PANEL_FQDN_ONLY:-n}" != "y" ]]; then
		((present)) || return 0
		ui_step "Снятие запрета входа в панель по IP (доступ по IP снова разрешён)"
		_hostcert_panel_fqdn_remove "$vhost"
		rm -f /usr/local/sbin/ispconfig-panel-allow-ip.sh 2>/dev/null || true
		return 0
	fi

	# --- ВКЛЮЧЕНИЕ ---
	if ((present)); then
		ui_info "Доступ к панели уже ограничен только FQDN (${fqdn})."
		_hostcert_write_allow_ip_helper "$vhost"   # на всякий случай переустановим аварийный скрипт
		return 0
	fi
	ui_step "Запрет входа в панель по IP (только https://${fqdn})"
	cp -a "$vhost" "${vhost}.bak.fqdnonly"
	# Вставляем проверку сразу после строки 'server_name _;'. Точное сравнение '!='
	# (nginx $host уже в нижнем регистре) — без regex/экранирования: всё, что не
	# равно FQDN (заход по IP, чужой Host), получает 444 (соединение закрывается).
	awk -v fqdn="$fqdn" '
		{ print }
		/server_name[[:space:]]+_;/ && !inserted {
			print "        # luckystack: panel-fqdn-only — доступ к панели только по FQDN, по IP закрыт"
			print "        if ($host != \"" fqdn "\") { return 444; }"
			inserted=1
		}
	' "$vhost" >"${vhost}.new" && mv_keep "${vhost}.new" "$vhost"

	if nginx -t >>"$SETUP_LOG" 2>&1; then
		systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
		rm -f "${vhost}.bak.fqdnonly"
		_hostcert_write_allow_ip_helper "$vhost"
		ui_success "Доступ к панели только по https://${fqdn}:${ISPCONFIG_PANEL_PORT:-8080} — заход по IP закрыт (444)."
		ui_info "Если что-то отвалится — аварийно вернуть доступ по IP: ${UI_W}ispconfig-panel-allow-ip.sh${UI_NC}"
		ui_info "Либо в setup.conf ${UI_W}PANEL_FQDN_ONLY=n${UI_NC} и ${UI_W}$(ls_hint --only hostcert)${UI_NC}."
	else
		mv -f "${vhost}.bak.fqdnonly" "$vhost"
		systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
		ui_warn "nginx -t не прошёл — откатил, запрет по IP не применён (см. ${SETUP_LOG})."
	fi
}

# --- apache: <If "%{HTTP_HOST} !~ /FQDN/"> Require all denied </If> в vhost панели ---
# ВНИМАНИЕ: реализация не проверена на живом Apache — нужна верификация configtest'ом.
_panel_fqdn_only_apache() {
	local fqdn="$1" esc="${fqdn//./\\.}"
	local vhost="" cand
	for cand in /etc/apache2/sites-available/ispconfig.vhost /etc/apache2/sites-enabled/000-ispconfig.vhost; do
		[[ -f "$cand" ]] && { vhost="$cand"; break; }
	done
	[[ -n "$vhost" ]] || { [[ "${PANEL_FQDN_ONLY:-n}" == "y" ]] && ui_info "vhost панели (Apache) не найден — запрет по IP пропущен."; return 0; }
	local present=0; grep -q "luckystack: panel-fqdn-only" "$vhost" && present=1

	# ОТКЛЮЧЕНИЕ: убираем блок (маркер … </If>) если стоит
	if [[ "${PANEL_FQDN_ONLY:-n}" != "y" ]]; then
		((present)) || return 0
		ui_step "Снятие запрета входа в панель по IP [apache]"
		cp -a "$vhost" "${vhost}.bak.fqdnoff"
		sed -i '/luckystack: panel-fqdn-only/,/<\/If>/d' "$vhost"
		if web_configtest; then
			web_reload; rm -f "${vhost}.bak.fqdnoff" /usr/local/sbin/ispconfig-panel-allow-ip.sh
			ui_success "Запрет снят — вход в панель по IP снова разрешён."
		else
			mv -f "${vhost}.bak.fqdnoff" "$vhost"; web_reload
			ui_warn "apache configtest не прошёл при снятии — откатил."
		fi
		return 0
	fi

	# ВКЛЮЧЕНИЕ
	((present)) && { ui_info "Доступ к панели уже ограничен только FQDN (${fqdn})."; _hostcert_write_allow_ip_helper "$vhost"; return 0; }
	ui_step "Запрет входа в панель по IP (только https://${fqdn}) [apache]"
	cp -a "$vhost" "${vhost}.bak.fqdnonly"
	# Вставляем <If> сразу после первой строки <VirtualHost …>. %{HTTP_HOST} включает порт
	# для нестандартного :3333 → допускаем опциональный (:порт) в regex.
	awk -v esc="$esc" '
		{ print }
		/<VirtualHost/ && !inserted {
			print "    # luckystack: panel-fqdn-only — доступ к панели только по FQDN, по IP закрыт"
			print "    <If \"%{HTTP_HOST} !~ /^" esc "(:[0-9]+)?$/\">"
			print "        Require all denied"
			print "    </If>"
			inserted=1
		}
	' "$vhost" >"${vhost}.new" && mv_keep "${vhost}.new" "$vhost"
	if web_configtest; then
		web_reload; rm -f "${vhost}.bak.fqdnonly"; _hostcert_write_allow_ip_helper "$vhost"
		ui_success "Доступ к панели только по https://${fqdn}:${ISPCONFIG_PANEL_PORT:-8080} — по IP закрыт (403)."
		ui_info "Аварийно вернуть доступ по IP: ${UI_W}ispconfig-panel-allow-ip.sh${UI_NC}"
	else
		mv -f "${vhost}.bak.fqdnonly" "$vhost"; web_reload
		ui_warn "apache configtest не прошёл — откатил, запрет не применён (см. ${SETUP_LOG})."
	fi
}

# Удалить блок panel-fqdn-only (строку-маркер + следующую за ней строку 'if ($host…')
# из nginx-vhost панели, проверить конфиг и перезагрузить nginx (с откатом).
_hostcert_panel_fqdn_remove() {
	local vhost="$1"
	cp -a "$vhost" "${vhost}.bak.fqdnoff"
	awk '
		/luckystack: panel-fqdn-only/ { skip=1; next }       # выкидываем строку-маркер
		skip==1 { skip=0; if ($0 ~ /return 444/) next }         # и следующую — ТОЛЬКО если это та самая проверка
		{ print }
	' "$vhost" >"${vhost}.new" && mv_keep "${vhost}.new" "$vhost"
	if nginx -t >>"$SETUP_LOG" 2>&1; then
		systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
		rm -f "${vhost}.bak.fqdnoff"
		ui_success "Запрет снят — вход в панель по IP снова разрешён."
	else
		mv -f "${vhost}.bak.fqdnoff" "$vhost"
		systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
		ui_warn "nginx -t не прошёл при снятии запрета — откатил (см. ${SETUP_LOG})."
	fi
}

# Положить аварийный скрипт: одной командой вернуть доступ к панели по IP, если
# FQDN/сертификат отвалится и панель станет недоступна. Самодостаточен (знает vhost).
_hostcert_write_allow_ip_helper() {
	local vhost="$1" h=/usr/local/sbin/ispconfig-panel-allow-ip.sh
	# Контент скрипта зависит от веб-сервера: способ удаления блока и проверка/перезагрузка.
	local sedcmd testcmd reloadcmd
	if [[ "${WEBSERVER:-nginx}" == "apache" ]]; then
		sedcmd="sed -i '/panel-fqdn-only/,/<\\/If>/d' \"\$V\""
		testcmd="apache2ctl configtest"; reloadcmd="systemctl reload apache2"
	else
		sedcmd="sed -i '/panel-fqdn-only/{N;/return 444/d}' \"\$V\""
		testcmd="nginx -t"; reloadcmd="systemctl reload nginx"
	fi
	cat >"$h" <<HLP
#!/bin/bash
# luckystack: аварийно вернуть доступ к панели ISPConfig по IP (снять panel-fqdn-only).
# Запуск: ispconfig-panel-allow-ip.sh
V="${vhost}"
[[ -f "\$V" ]] || { echo "vhost панели не найден: \$V"; exit 1; }
${sedcmd}
if ${testcmd}; then
    ${reloadcmd} && echo "OK: доступ к панели по IP восстановлен."
else
    echo "конфиг веб-сервера не прошёл проверку — проверьте \$V"; exit 1
fi
HLP
	chmod 700 "$h" 2>/dev/null || true
}

# Скрипт, который acme.sh запускает после выпуска/продления: собирает .pem,
# выставляет права, переключает Postfix/Dovecot на свежий серт и перезагружает службы.
_hostcert_write_deploy() {
	cat >"$HOSTCERT_DEPLOY" <<'DEP'
#!/bin/bash
# Переустановка LE-сертификата хоста для ISPConfig (панель + Postfix/Dovecot).
# Автогенерация LuckyStack. Вызывается acme.sh (--reloadcmd) при продлении.
SSL=/usr/local/ispconfig/interface/ssl
[[ -f "$SSL/ispserver.crt" && -f "$SSL/ispserver.key" ]] || exit 0

# под umask 077: внутри приватный ключ, файл не должен ни мгновения быть читаемым для всех
( umask 077; cat "$SSL/ispserver.key" "$SSL/ispserver.crt" > "$SSL/ispserver.pem.new" ) && mv -f "$SSL/ispserver.pem.new" "$SSL/ispserver.pem"
chmod 600 "$SSL/ispserver.key" "$SSL/ispserver.crt" "$SSL/ispserver.pem" 2>/dev/null || true
chown root:root "$SSL"/ispserver.* 2>/dev/null || true

# Postfix → серт хоста
if command -v postconf >/dev/null 2>&1; then
	postconf -e "smtpd_tls_cert_file = $SSL/ispserver.crt" "smtpd_tls_key_file = $SSL/ispserver.key" 2>/dev/null
	systemctl reload postfix 2>/dev/null || true
fi
# Dovecot → серт хоста (глобальный default; per-domain SNI из mailsni остаётся поверх)
if command -v dovecot >/dev/null 2>&1; then
	DVC=/etc/dovecot/conf.d/99-luckystack-ssl.conf
	# Dovecot >=2.4 (Debian 13): формат ssl-настроек несовместим — ssl_cert/ssl_key с '<' не работают,
	# нужны ssl_server_cert_file/ssl_server_key_file (иначе демон не стартует).
	DVV="$(dovecot --version 2>/dev/null | awk '{print $1}')"
	case "$DVV" in
		2.[4-9]*|[3-9].*) printf 'ssl_server_cert_file = %s\nssl_server_key_file = %s\n' "$SSL/ispserver.crt" "$SSL/ispserver.key" >"$DVC.new" ;;
		*)                printf 'ssl_cert = <%s\nssl_key = <%s\n' "$SSL/ispserver.crt" "$SSL/ispserver.key" >"$DVC.new" ;;
	esac
	[[ -f "$DVC" ]] && cp -a "$DVC" "$DVC.prev"
	mv -f "$DVC.new" "$DVC"
	if doveconf -n >/dev/null 2>&1; then
		systemctl reload dovecot 2>/dev/null || true
		rm -f "$DVC.prev"
	else
		# конфиг не прошёл проверку — откат, работающий Dovecot не трогаем
		if [[ -f "$DVC.prev" ]]; then mv -f "$DVC.prev" "$DVC"; else rm -f "$DVC"; fi
		logger -t ispconfig-hostcert-deploy "dovecot ${DVV}: ${DVC} не прошёл doveconf -n — откат" 2>/dev/null || true
	fi
fi
# Monit → серт хоста (только если включён HTTPS веб-интерфейса: есть monit.pem).
# Заменяем временный self-signed на LE и при выпуске, и при каждом продлении.
if [[ -f /etc/monit/monit.pem ]] && command -v monit >/dev/null 2>&1; then
	( umask 077; cat "$SSL/ispserver.key" "$SSL/ispserver.crt" > /etc/monit/monit.pem.new ) && mv -f /etc/monit/monit.pem.new /etc/monit/monit.pem
	chmod 600 /etc/monit/monit.pem
	systemctl reload monit 2>/dev/null || monit reload 2>/dev/null || true
fi
# Веб-сервер панели + ISPConfig
systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true
systemctl restart ispconfig_server 2>/dev/null || true
exit 0
DEP
	chmod 700 "$HOSTCERT_DEPLOY" 2>/dev/null || true
}

stage_hostcert_summary() {
	echo "Host cert: LE для FQDN (панель + почта) при публичном домене"
}
