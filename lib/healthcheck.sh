#!/bin/bash
# =============================================================================
# lib/healthcheck.sh — Проверка здоровья сервера (--healthcheck).
#
#   Read-only диагностика «а реально ли всё работает» после установки:
#     • сервисы active/inactive
#     • слушаются ли ожидаемые порты (web, панель, почта, DNS, FTP, БД)
#     • срок действия TLS-сертификатов (панель + Let's Encrypt)
#     • отвечает ли веб-панель ISPConfig (HTTP-код)
#     • резолвится ли FQDN, не растёт ли почтовая очередь
#     • место на диске / inodes
#   В конце — сводка OK/ВНИМАНИЕ/ОШИБКА. Код выхода ≠0 при наличии ОШИБОК
#   (удобно для cron/мониторинга). Систему НЕ меняет.
# =============================================================================

HC_OK=0; HC_WARN=0; HC_FAIL=0
_hc_ok()   { ui_box_line "  ${UI_G}✓${UI_NC} $1"; ((HC_OK++));   }
_hc_warn() { ui_box_line "  ${UI_Y}!${UI_NC} $1"; ((HC_WARN++)); }
_hc_fail() { ui_box_line "  ${UI_R}✗${UI_NC} $1"; ((HC_FAIL++)); }

# Порт слушается (TCP или UDP, любой адрес)?
_hc_listen() {
	ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}\$" && return 0
	ss -H -lnu 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}\$" && return 0
	return 1
}

# rc=0, если TCP-порт слушается на НЕ-localhost (0.0.0.0/публичный) — т.е. торчит наружу.
# Без pipe-в-условии (защита от SIGPIPE под pipefail): сначала в переменную, потом here-string.
_hc_exposed() {
	local addrs
	addrs="$(ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]${1}\$")" || true
	[[ -z "$addrs" ]] && return 1   # порт не слушается
	grep -qvE '^(127\.0\.0\.1|\[::1\]):' <<<"$addrs"
}

# Дней до истечения сертификата (отрицательное — просрочен); rc=1 если не прочитать.
_hc_cert_days() {
	local f="$1" end secs now
	end="$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)"
	[[ -z "$end" ]] && return 1
	secs="$(date -d "$end" +%s 2>/dev/null)" || return 1
	now="$(date +%s)"
	echo $(( (secs - now) / 86400 ))
}

_hc_svc() {  # _hc_svc "Имя" имя_сервиса [soft]
	# soft=мягкий: неактивность считаем предупреждением, а не ошибкой (напр. ClamAV
	# часто намеренно выключен — тяжёлый, а проверку берёт на себя rspamd).
	local s soft="${3:-}"; s="$(systemctl is-active "$2" 2>/dev/null | head -1)"
	case "$s" in
		active)      _hc_ok   "${1} (${2}): active" ;;
		activating)  _hc_warn "${1} (${2}): activating (ещё запускается)" ;;
		"")          _hc_warn "${1} (${2}): статус неизвестен" ;;
		*)           if [[ "$soft" == "soft" ]]; then _hc_warn "${1} (${2}): ${s} (не критично)"
		             else _hc_fail "${1} (${2}): ${s}"; fi ;;
	esac
}

# Безопасность и бэкапы: то, что не ломает сервер сразу, но подводит в плохой день.
# $1 — есть почта, $2 — есть ISPConfig.
_hc_security_backups() {
	local have_mail="${1:-0}" have_panel="${2:-0}" v n
	ui_box_top "Безопасность и бэкапы"

	if [[ -f /var/run/reboot-required ]]; then
		_hc_warn "нужна перезагрузка (обновились: $(tr '\n' ' ' </var/run/reboot-required.pkgs 2>/dev/null | head -c 120))"
	else
		_hc_ok "перезагрузка не требуется"
	fi

	if command -v ufw >/dev/null 2>&1 && [[ "${FIREWALL:-none}" == "ufw" || "${CROWDSEC_WITH_UFW:-n}" == "y" ]]; then
		if grep -qE '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
			_hc_ok "ufw включён и переживёт перезагрузку"
		else
			_hc_fail "ufw выключен (ENABLED=no): после перезагрузки фаервола нет — $(ls_hint --update)"
		fi
	fi

	if command -v sshd >/dev/null 2>&1; then
		v="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
		if [[ "$v" == "yes" ]]; then
			_hc_warn "SSH: вход по паролю разрешён (надёжнее только по ключу)"
		elif [[ -n "$v" ]]; then
			_hc_ok "SSH: вход только по ключу"
		fi
		v="$(sshd -T 2>/dev/null | awk '$1=="x11forwarding"||$1=="allowagentforwarding"{if($2=="yes")print $1}' | tr '\n' ' ')"
		[[ -n "$v" ]] && _hc_warn "SSH: включено ${v}— luckyctl update выключит"
	fi

	if [[ -f /etc/server-notify.conf ]]; then
		local em tok chats
		em="$( . /etc/server-notify.conf 2>/dev/null; echo "${NOTIFY_EMAIL:-}" )"
		tok="$( . /etc/server-notify.conf 2>/dev/null; echo "${NOTIFY_TG_TOKEN:-}" )"
		chats="$( . /etc/server-notify.conf 2>/dev/null; echo "${NOTIFY_TG_CHATS:-}" )"
		if [[ -z "$em" && ( -z "$tok" || -z "$chats" ) ]]; then
			_hc_warn "уведомления никуда не уходят — System → Дополнения → Уведомления"
		else
			_hc_ok "уведомления: ${em:+email }${tok:+${chats:+Telegram}}"
		fi
	else
		_hc_warn "уведомления не настроены (нет /etc/server-notify.conf)"
	fi

	n="$(find /etc -xdev ! -type l -perm -0002 2>/dev/null | head -50 | wc -l)"
	if ((n > 0)); then
		_hc_fail "в /etc запись для всех: ${n} шт. ($(find /etc -xdev ! -type l -perm -0002 2>/dev/null | head -1)) — $(ls_hint --update)"
	else
		_hc_ok "в /etc нет файлов с записью для всех"
	fi

	# Бэкапы
	local bconf=/etc/server-backup.conf www mail rtype
	if [[ -f "$bconf" ]]; then
		www="$( . "$bconf" 2>/dev/null; echo "${INC_WWW:-${BACKUP_INCLUDE_WWW:-n}}" )"
		mail="$( . "$bconf" 2>/dev/null; echo "${INC_MAIL:-${BACKUP_INCLUDE_MAIL:-n}}" )"
		rtype="$( . "$bconf" 2>/dev/null; echo "${BACKUP_REMOTE_TYPE:-none}" )"
		if systemctl is-active --quiet server-backup.timer 2>/dev/null; then
			_hc_ok "серверный бэкап (БД и конфиги) по расписанию"
		else
			_hc_fail "серверный бэкап: таймер server-backup.timer не активен"
		fi
		# Таймер мог работать, а базы в снимок не попадать (Access denied у службы): смотрим сам снимок.
		local bdir last nd
		bdir="$( . "$bconf" 2>/dev/null; echo "${BACKUP_DIR:-/var/backups/server}" )"; bdir="${bdir%/}"
		last="$(ls -1d "$bdir"/2*/ 2>/dev/null | tail -1)"
		if [[ -n "$last" ]] && command -v mariadb >/dev/null 2>&1; then
			nd="$(ls "${last}mysql/"*.sql.gz 2>/dev/null | wc -l)"
			if ((nd > 0)); then
				_hc_ok "последний снимок $(basename "$last"): баз данных ${nd}"
			else
				_hc_fail "последний снимок $(basename "$last") без баз данных, смотрите ${bdir}/backup.log"
			fi
		fi
		if [[ "$rtype" == "none" || -z "$rtype" ]]; then
			_hc_warn "бэкапы только на этом диске, копии вне сервера нет"
		else
			_hc_ok "оффсайт-копия: ${rtype}"
		fi
		((have_mail)) && [[ "$mail" != "y" ]] && _hc_warn "почта (/var/vmail) в бэкап не входит"
	else
		_hc_warn "серверного бэкапа нет (БД, конфиги) — этап backup"
	fi
	if ((have_panel)) && declare -F _ispc_mysql >/dev/null; then
		local total off
		total="$(_ispc_mysql -NBe "SELECT COUNT(*) FROM web_domain WHERE type='vhost'" 2>/dev/null)"
		off="$(_ispc_mysql -NBe "SELECT COUNT(*) FROM web_domain WHERE type='vhost' AND backup_interval='none'" 2>/dev/null)"
		if [[ "$off" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] && ((total > 0)); then
			if ((off == 0)); then
				_hc_ok "бэкапы ISPConfig включены у всех сайтов (${total})"
			elif [[ "${www:-n}" == "y" ]]; then
				_hc_ok "сайты входят в серверный бэкап (/var/www)"
			else
				_hc_warn "у ${off} из ${total} сайтов нет бэкапа — $(ls_hint --update) предложит включить"
			fi
		fi
	fi
	ui_box_bottom
}

run_healthcheck() {
	config_load >/dev/null 2>&1 || true
	# Счётчики итогов сбрасываем В НАЧАЛЕ каждого прогона (а не только при загрузке файла) —
	# иначе повторный вызов в ОДНОМ процессе (меню утилит / финал+ручной запуск) суммирует числа.
	HC_OK=0; HC_WARN=0; HC_FAIL=0
	# HC_NO_CLEAR=1 — не чистить экран (авто-проверка в финале установки идёт ПОД
	# итоговой сводкой, чтобы её не затереть).
	[[ "${HC_NO_CLEAR:-0}" == "1" ]] || clear 2>/dev/null || true
	ui_header "Проверка здоровья сервера"

	local fqdn="${SERVER_FQDN:-$(hostname -f 2>/dev/null || hostname)}"
	local panel_port="${ISPCONFIG_PANEL_PORT:-8080}"
	# Проверяем ЗДОРОВЬЕ ТОЛЬКО установленных компонентов: не считаем «ошибкой» то,
	# что компонент не выбран/не установлен. Поэтому каждый блок гейтим по факту наличия.
	local have_mail=0 have_dns=0 have_ftp=0 have_web=0 have_db=0 have_panel=0 any=0
	command -v postfix >/dev/null 2>&1 && have_mail=1
	command -v named   >/dev/null 2>&1 && have_dns=1
	dpkg -l pure-ftpd-mysql 2>/dev/null | grep -q '^ii' && have_ftp=1
	{ command -v nginx >/dev/null 2>&1 || command -v apache2 >/dev/null 2>&1; } && have_web=1
	command -v mysql >/dev/null 2>&1 && have_db=1
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] && have_panel=1
	# Признак «на сервере вообще что-то ставили» — иначе healthcheck бессмыслен.
	{ ((have_web || have_db || have_mail || have_panel)) || command -v php >/dev/null 2>&1; } && any=1

	if ((any == 0)); then
		ui_box_top "Состояние"
		ui_box_line "  ${UI_Y}Компоненты сервера не установлены${UI_NC} — проверять нечего."
		ui_box_line "  ${UI_D}Запустите установку: $(ls_hint)${UI_NC}"
		ui_box_bottom
		ui_info "Система чистая — healthcheck пропущен (нет установленных компонентов)."
		return 0
	fi

	# --- Сервисы ---
	ui_box_top "Сервисы"
	command -v nginx   >/dev/null 2>&1 && _hc_svc "nginx"   nginx
	command -v apache2 >/dev/null 2>&1 && _hc_svc "Apache"  apache2
	command -v mysql   >/dev/null 2>&1 && _hc_svc "MariaDB" mariadb
	local v
	for v in /etc/php/*/; do
		v="$(basename "$v")"
		[[ -d "/etc/php/$v/fpm" ]] && _hc_svc "PHP-FPM ${v}" "php${v}-fpm"
	done
	command -v redis-server >/dev/null 2>&1 && _hc_svc "Redis" redis-server
	((have_mail)) && { _hc_svc "Postfix" postfix; _hc_svc "Dovecot" dovecot; }
	command -v rspamd >/dev/null 2>&1 && _hc_svc "Rspamd" rspamd
	dpkg -l clamav-daemon 2>/dev/null | grep -q '^ii' && _hc_svc "ClamAV" clamav-daemon soft
	((have_dns)) && _hc_svc "BIND9 (DNS)" named
	((have_ftp)) && _hc_svc "PureFTPd" pure-ftpd-mysql
	command -v monit >/dev/null 2>&1 && _hc_svc "Monit" monit
	command -v fail2ban-client >/dev/null 2>&1 && _hc_svc "fail2ban" fail2ban
	dpkg -l crowdsec 2>/dev/null | grep -q '^ii' && _hc_svc "CrowdSec" crowdsec
	# Валидность конфигурации активного веб-сервера (битый конфиг = сервис «active»,
	# но reload/новые vhost'ы молча не применяются — частый источник «почему не работает»).
	if [[ -x /usr/sbin/nginx ]] || command -v nginx >/dev/null 2>&1; then
		if nginx -t >/dev/null 2>&1; then _hc_ok "конфигурация nginx валидна (nginx -t)"
		else _hc_fail "конфигурация nginx СЛОМАНА — см. 'nginx -t'"; fi
	fi
	if command -v apache2ctl >/dev/null 2>&1; then
		if apache2ctl configtest >/dev/null 2>&1; then _hc_ok "конфигурация Apache валидна (configtest)"
		else _hc_fail "конфигурация Apache СЛОМАНА — см. 'apache2ctl configtest'"; fi
	fi
	ui_box_bottom

	# --- Порты ---
	ui_box_top "Сетевые порты (LISTEN)"
	if command -v ss >/dev/null 2>&1; then
		local p
		if ((have_web)); then
			for p in 80 443; do
				_hc_listen "$p" && _hc_ok "порт ${p} (web) слушается" || _hc_warn "порт ${p} (web) не слушается"
			done
		fi
		# Firewall-движок: если порты фильтрует ufw (FIREWALL=ufw ИЛИ crowdsec+ufw), а ufw
		# ВЫКЛЮЧЕН — правила портов и панель «Firewall IP-rules» НЕ применяются (тихий провал:
		# before.rules пишется, но в ядро не грузится без активного ufw). Явно ловим.
		if command -v ufw >/dev/null 2>&1; then
			local _ufw_exp=0
			[[ "${FIREWALL:-}" == "ufw" ]] && _ufw_exp=1
			[[ "${FIREWALL:-}" == "crowdsec" && "${CROWDSEC_WITH_UFW:-y}" == "y" ]] && _ufw_exp=1
			if ((_ufw_exp)); then
				if ufw status 2>/dev/null | grep -q "Status: active"; then
					_hc_ok "ufw активен (фильтрация портов работает)"
				else
					_hc_fail "ufw ВЫКЛЮЧЕН, хотя это активный firewall — правила портов и «Firewall IP-rules» НЕ применяются. Включите: ufw enable"
				fi
			fi
		fi
		# HTTP/3 (QUIC): если собран — он по UDP/443. Проверяем, что nginx реально
		# слушает UDP/443 и что ufw его не режет (иначе тихий откат на HTTP/2).
		if ((have_web)) && [[ "${WEBSERVER:-nginx}" == "nginx" && "${NGX_HTTP3:-${HTTP3:-n}}" == "y" ]]; then
			if ss -H -lnu 2>/dev/null | awk '{print $4}' | grep -qE '[:.]443$'; then
				_hc_ok "HTTP/3: nginx слушает UDP/443 (QUIC)"
			else
				_hc_warn "HTTP/3: nginx НЕ слушает UDP/443 — QUIC не поднялся (см. nginx -T / сборку)"
			fi
			if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
				ufw status 2>/dev/null | grep -q '443/udp' \
					&& _hc_ok "HTTP/3: UDP/443 открыт в ufw" \
					|| _hc_warn "HTTP/3: UDP/443 закрыт в ufw — браузеры откатятся на HTTP/2 ('ufw allow 443/udp')"
			fi
		fi
		((have_panel)) && { _hc_listen "$panel_port" && _hc_ok "порт ${panel_port} (панель ISPConfig) слушается" \
			|| _hc_fail "порт ${panel_port} (панель ISPConfig) НЕ слушается"; }
		((have_db)) && { _hc_listen 3306 && _hc_ok "порт 3306 (MariaDB) слушается" || _hc_warn "порт 3306 (MariaDB) не слушается"; }
		if ((have_mail)); then
			for p in 25 587 143 993; do
				_hc_listen "$p" && _hc_ok "порт ${p} (почта) слушается" || _hc_warn "порт ${p} (почта) не слушается"
			done
		fi
		((have_dns)) && { _hc_listen 53 && _hc_ok "порт 53 (DNS) слушается" || _hc_warn "порт 53 (DNS) не слушается"; }
		((have_ftp)) && { _hc_listen 21 && _hc_ok "порт 21 (FTP) слушается" || _hc_warn "порт 21 (FTP) не слушается"; }
		# Экспозиция наружу: БД/кэш ДОЛЖНЫ слушать только localhost. Торчащий 3306/6379
		# и т.п. = доступ из интернета (firewall по IP-банам порт НЕ закрывает).
		local _sp _spn _exposed=0
		for _sp in 3306:MariaDB 5432:PostgreSQL 6379:Redis 11211:memcached 27017:MongoDB; do
			_spn="${_sp#*:}"
			if _hc_exposed "${_sp%%:*}"; then
				# MariaDB наружу — ОСОЗНАННО, если включён удалённый доступ (MARIADB_REMOTE=y):
				# тогда это не ошибка, а ожидаемо, и 3306 ограничен firewall'ом по IP.
				if [[ "${_sp%%:*}" == "3306" && "${MARIADB_REMOTE:-n}" == "y" ]]; then
					_hc_warn "MariaDB слушает 0.0.0.0 — удалённый доступ ВКЛючён (MARIADB_REMOTE=y). Убедитесь, что 3306 в firewall открыт только доверенным IP${MARIADB_REMOTE_IPS:+: $MARIADB_REMOTE_IPS}."
				else
					_hc_fail "${_spn} слушает на 0.0.0.0 — доступен из интернета! привяжите к 127.0.0.1 (порт ${_sp%%:*})"
					_exposed=1
				fi
			fi
		done
		((_exposed == 0)) && _hc_ok "чувствительные сервисы (БД/кэш) не торчат наружу (только localhost)"
	else
		_hc_warn "утилита ss не найдена (apt install iproute2) — проверка портов пропущена"
	fi
	ui_box_bottom

	# --- TLS-сертификаты ---
	ui_box_top "TLS-сертификаты"
	if command -v openssl >/dev/null 2>&1; then
		local crt d dom
		# Сертификат панели ISPConfig — с определением издателя (LE / самоподписанный)
		for crt in /usr/local/ispconfig/interface/ssl/ispserver.crt; do
			[[ -f "$crt" ]] || continue
			local issuer note=""
			issuer="$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null)"
			if grep -qiE "let'?s encrypt" <<<"$issuer"; then note=" ${UI_G}(Let's Encrypt)${UI_NC}"
			else note=" ${UI_Y}(самоподписанный — для валидного: $(ls_hint --only hostcert))${UI_NC}"; fi
			if d="$(_hc_cert_days "$crt")"; then
				if   ((d < 0));  then _hc_fail "панель ISPConfig: сертификат ПРОСРОЧЕН ($((-d)) дн. назад)${note}"
				elif ((d < 14)); then _hc_warn "панель ISPConfig: истекает через ${d} дн.${note}"
				else                  _hc_ok   "панель ISPConfig: валиден (${d} дн.)${note}"; fi
			fi
		done
		# Сертификаты Let's Encrypt: certbot (/etc/letsencrypt/live) И acme.sh (/root/.acme.sh)
		local n=0
		for crt in /etc/letsencrypt/live/*/cert.pem /root/.acme.sh/*/fullchain.cer; do
			[[ -f "$crt" ]] || continue
			n=1; dom="$(basename "$(dirname "$crt")")"; dom="${dom%_ecc}"
			if d="$(_hc_cert_days "$crt")"; then
				if   ((d < 0));  then _hc_fail "LE ${dom}: ПРОСРОЧЕН ($((-d)) дн. назад)"
				elif ((d < 14)); then _hc_warn "LE ${dom}: истекает через ${d} дн."
				else                  _hc_ok   "LE ${dom}: валиден (${d} дн.)"; fi
			fi
		done
		((n)) || ui_box_line "  ${UI_D}Let's Encrypt-сертификатов не найдено (acme.sh: /root/.acme.sh, certbot: /etc/letsencrypt)${UI_NC}"
	else
		_hc_warn "openssl не найден — проверка сертификатов пропущена"
	fi
	ui_box_bottom

	# --- Веб-панель ISPConfig (только если установлена) ---
	if ((have_panel)); then
		ui_box_top "Веб-панель ISPConfig"
		if command -v curl >/dev/null 2>&1; then
			local code
			# Стучимся по FQDN (а не localhost): при PANEL_FQDN_ONLY панель отдаёт 444
			# на чужой Host. --resolve направляет FQDN на 127.0.0.1 — проверяем локально,
			# но с правильными Host/SNI (и серт CN совпадает).
			local _hc_host="${fqdn:-localhost}"
			code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${_hc_host}:${panel_port}:127.0.0.1" "https://${_hc_host}:${panel_port}/" 2>/dev/null)"
			case "$code" in
				200|301|302) _hc_ok   "панель отвечает (HTTP ${code}) на https://${fqdn}:${panel_port}" ;;
				000|"")      _hc_fail "панель НЕ отвечает на https://${_hc_host}:${panel_port} (нет соединения)" ;;
				5*)          _hc_fail "панель отдаёт ошибку HTTP ${code} (проверьте php-fpm/логи)" ;;
				*)           _hc_warn "панель отдаёт HTTP ${code}" ;;
			esac
		else
			_hc_warn "curl не найден — проверка панели пропущена"
		fi
		ui_box_bottom
	fi

	# --- DNS / FQDN ---
	ui_box_top "DNS / имя хоста"
	if getent hosts "$fqdn" >/dev/null 2>&1; then
		_hc_ok "FQDN ${fqdn} резолвится локально"
	else
		_hc_warn "FQDN ${fqdn} не резолвится (проверьте /etc/hosts и DNS)"
	fi
	if command -v dig >/dev/null 2>&1; then
		local pub; pub="$(dig +short +time=3 +tries=1 "$fqdn" A 2>/dev/null | grep -E '^[0-9]' | head -1)"
		[[ -n "$pub" ]] && ui_box_line "  ${UI_D}публичная A-запись: ${pub}${UI_NC}"
	fi
	if grep -qsxF "${IPV6_GAI_MARK:-# luckystack: ipv4-first}" /etc/gai.conf; then
		_hc_warn "IPv6 у хостера наружу не работает, система ходит по IPv4 первой (/etc/gai.conf)"
	fi
	ui_box_bottom

	# --- Почтовая очередь ---
	if ((have_mail)) && command -v postqueue >/dev/null 2>&1; then
		ui_box_top "Почтовая очередь (Postfix)"
		local q; q="$(postqueue -p 2>/dev/null | grep -c '^[0-9A-F]')"
		q="${q:-0}"
		if   ((q == 0));   then _hc_ok   "очередь пуста"
		elif ((q < 50));   then _hc_ok   "в очереди ${q} писем"
		elif ((q < 500));  then _hc_warn "в очереди ${q} писем (стоит проверить доставку)"
		else                    _hc_fail "в очереди ${q} писем (возможна проблема доставки/спам-рассылка)"; fi
		ui_box_bottom
	fi

	# --- Диск / inodes ---
	ui_box_top "Дисковое пространство"
	local use ino
	use="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
	ino="$(df -Pi / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
	if [[ "$use" =~ ^[0-9]+$ ]]; then
		if   ((use >= 95)); then _hc_fail "корень /: занято ${use}% (критично)"
		elif ((use >= 85)); then _hc_warn "корень /: занято ${use}%"
		else                     _hc_ok   "корень /: занято ${use}%"; fi
	fi
	if [[ "$ino" =~ ^[0-9]+$ ]]; then
		((ino >= 90)) && _hc_warn "корень /: inodes занято ${ino}%"
	fi
	ui_box_bottom

	_hc_security_backups "$have_mail" "$have_panel"

	# --- Сводка ---
	ui_box_top "Итог"
	ui_box_line "  ${UI_G}OK: ${HC_OK}${UI_NC}   ${UI_Y}ВНИМАНИЕ: ${HC_WARN}${UI_NC}   ${UI_R}ОШИБКА: ${HC_FAIL}${UI_NC}"
	ui_box_bottom
	if   ((HC_FAIL > 0)); then ui_error "Найдены проблемы (${HC_FAIL}). Разберите пункты с ✗ выше."; return 2
	elif ((HC_WARN > 0)); then ui_warn  "Есть предупреждения (${HC_WARN}) — посмотрите пункты с !."; return 0
	else                       ui_success "Все проверки пройдены — сервер здоров."; return 0
	fi
}

# Проверить ОДИН порт: перебрать цели, КАЖДУЮ залогировать в отчёт (хост, IP, результат,
# длительность), вывести одну строку-вердикт на экран (✓ только при OPEN). Возвращает
# 0=открыт, 1=заблокирован. Резолв в КОНКРЕТНЫЙ IPv4 (на IPv4-only сервере имя берёт IPv6
# → ложная блокировка); IPv6 — только если есть глобальный (MAILPORT_HAVE_IP6). Подробности
# в файл $MAILPORT_REPORT. Дин. видимость переменных — из run_mailport_check.
_mailport_check_port() {
	local port="$1" desc="$2"; shift 2
	local h ip start dur ok=1
	printf '>>> Port %s (%s):\n' "$port" "$desc" >>"$MAILPORT_REPORT"
	for h in "$@"; do
		ip="$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1; exit}')"
		if [[ -z "$ip" && -n "${MAILPORT_HAVE_IP6:-}" ]]; then
			ip="$(getent ahostsv6 "$h" 2>/dev/null | awk '{print $1; exit}')"
		fi
		if [[ -z "$ip" ]]; then printf '    %-42s -> no IP (DNS)\n' "$h" >>"$MAILPORT_REPORT"; continue; fi
		start=$SECONDS
		if timeout 6 bash -c "exec 3<>/dev/tcp/${ip}/${port}" 2>/dev/null; then
			exec 3>&- 2>/dev/null || true; dur=$((SECONDS-start))
			printf '    %-42s [%s]:%s  CONNECTED in %ss\n' "$h" "$ip" "$port" "$dur" >>"$MAILPORT_REPORT"
			ok=0; MAILPORT_HOST="${h} (${ip})"
		else
			dur=$((SECONDS-start))
			printf '    %-42s [%s]:%s  NO CONNECTION / TIMEOUT (~%ss) => blocked\n' "$h" "$ip" "$port" "$dur" >>"$MAILPORT_REPORT"
		fi
	done
	if ((ok==0)); then
		printf '    RESULT: port %s OPEN\n\n' "$port" >>"$MAILPORT_REPORT"
		ui_box_line "  ${UI_G}✓${UI_NC} порт ${port} (${desc}) — ОТКРЫТ  ${UI_D}(${MAILPORT_HOST})${UI_NC}"
	else
		printf '    RESULT: port %s BLOCKED (no target reachable)\n\n' "$port" >>"$MAILPORT_REPORT"
	fi
	return $ok
}

# Проверка блокировки ИСХОДЯЩИХ почтовых портов хостером + подробный отчёт с временем
# для отправки в поддержку. Классика VPS — закрытый наружу порт 25. ВХОДЯЩУЮ доступность
# так не проверить (нужен внешний пробер).
run_mailport_check() {
	clear 2>/dev/null || true
	ui_header "Блокировка почтовых портов хостером (исходящие)"
	local ts fqdn pubip MAILPORT_HOST="" MAILPORT_HAVE_IP6="" MAILPORT_REPORT="/root/mailport-check.txt"
	ts="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
	fqdn="${SERVER_FQDN:-$(hostname -f 2>/dev/null || hostname)}"
	pubip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
	# Единая истина об IPv6 (глобальный адрес + маршрут) — _has_ipv6 (lib/core.sh).
	if declare -F _has_ipv6 >/dev/null; then _has_ipv6 && MAILPORT_HAVE_IP6=1
	else ip -6 addr show scope global 2>/dev/null | grep -q inet6 && MAILPORT_HAVE_IP6=1; fi

	# Шапка отчёта (англ. — чтобы годилось для любой поддержки)
	{
		echo "=== Outbound mail-port connectivity check (server-installer) ==="
		echo "Date:        ${ts}"
		echo "Server FQDN: ${fqdn}"
		echo "Public IPv4: ${pubip:-unknown}"
		echo "Server IPv6: $([[ -n "$MAILPORT_HAVE_IP6" ]] && echo present || echo none)"
		echo "Method:      outbound TCP connect (/dev/tcp) from THIS server to public mail servers, 6s timeout."
		echo ""
	} >"$MAILPORT_REPORT"

	ui_info "Дата: ${ts}"
	ui_info "Сервер: ${fqdn} · IP ${pubip:-?}"
	echo ""
	ui_box_top "Исходящие соединения с этого сервера"
	local blocked25=0 any_blocked=0
	_mailport_check_port 25  "доставка server->server" gmail-smtp-in.l.google.com alt1.gmail-smtp-in.l.google.com mx01.mail.icloud.com mx.yandex.ru mxs.mail.ru \
		|| { blocked25=1; any_blocked=1; ui_box_line "  ${UI_R}✗${UI_NC} порт 25  (доставка server→server) — ${UI_R}ЗАБЛОКИРОВАН${UI_NC}"; }
	_mailport_check_port 587 "submission/STARTTLS" smtp.gmail.com smtp-mail.outlook.com smtp.yandex.ru smtp.mail.ru \
		|| { any_blocked=1; ui_box_line "  ${UI_Y}!${UI_NC} порт 587 (submission/STARTTLS) — недоступен наружу"; }
	_mailport_check_port 465 "submissions/TLS" smtp.gmail.com smtp-mail.outlook.com smtp.yandex.ru smtp.mail.ru \
		|| { any_blocked=1; ui_box_line "  ${UI_Y}!${UI_NC} порт 465 (submissions/TLS)   — недоступен наружу"; }
	ui_box_bottom
	echo ""

	# Заключение в отчёт (готовый текст запроса хостеру)
	{
		echo "=== CONCLUSION ==="
		if ((blocked25)); then
			echo "Outbound TCP port 25 is BLOCKED from this server (${pubip:-?})."
			echo "=> This server CANNOT deliver email to other mail servers."
			echo ""
			echo "REQUEST TO HOSTING PROVIDER:"
			echo "Please unblock OUTBOUND TCP port 25 for this VPS (IP ${pubip:-?})."
			((any_blocked)) && echo "Outbound 587/465 also appear blocked — please unblock outbound SMTP entirely."
		elif ((any_blocked)); then
			echo "Outbound port 25 is OPEN; ports 587/465 appear blocked (usually not critical for delivery)."
		else
			echo "All tested outbound mail ports are OPEN — no provider block detected."
		fi
	} >>"$MAILPORT_REPORT"

	if ((blocked25)); then
		ui_error "Порт 25 наружу ЗАКРЫТ — блокировка хостером (типично для VPS)."
		ui_info "  • запросить разблокировку 25 у хостера (тикетом, приложив отчёт);"
		ui_info "  • либо релей через сервис на альтернативном порту (если 587/465 тоже закрыты)."
	elif ((any_blocked)); then
		ui_warn "Порт 25 открыт; 587/465 наружу недоступны — обычно не критично для доставки."
	else
		ui_success "Все исходящие почтовые порты открыты — блокировок хостера не видно."
	fi
	echo ""
	ui_success "Подробный отчёт с временем сохранён: ${UI_W}${MAILPORT_REPORT}${UI_NC}"
	ui_info "Отправь его хостеру в запрос на разблокировку. Посмотреть: ${UI_W}cat ${MAILPORT_REPORT}${UI_NC}"
	ui_info "Прим.: проверка ИСХОДЯЩИХ соединений; ВХОДЯЩИЙ :25 проверяй внешне (mxtoolbox)."
}

# =============================================================================
# Diagnostics-bundle (--diagnostics): собирает обезличенный архив для поддержки —
# система, конфиг (БЕЗ паролей), хвост лога (со скрабом секретов), статус служб,
# configtest, порты, firewall, ошибки журнала, healthcheck, версии.
# =============================================================================
run_diagnostics() {
	config_load >/dev/null 2>&1 || true
	local ts out tgz; ts="$(date +%Y%m%d-%H%M%S)"
	out="/root/server-diagnostics-${ts}"; tgz="${out}.tar.gz"
	mkdir -p "$out" || { ui_error "Не удаётся создать ${out}."; return 1; }
	ui_header "Сбор диагностики"
	ui_info "Собираю информацию (пароли/токены вырезаются)…"

	{ echo "# LuckyStack diagnostics ${ts}"; echo "## uname"; uname -a
	  echo; echo "## os-release"; [[ -r /etc/os-release ]] && cat /etc/os-release
	  echo; echo "## uptime"; uptime; echo; echo "## mem"; free -h
	  echo; echo "## disk"; df -hT; } > "$out/system.txt" 2>&1

	# Конфиг установщика БЕЗ секретов
	[[ -f "${CONFIG_FILE:-}" ]] && \
		grep -ivE 'PASSWORD|_PW=|TOKEN|SECRET|TG_CHAT' "$CONFIG_FILE" > "$out/setup.conf.sanitized" 2>/dev/null || true
	[[ -f "${STATE_FILE:-}" ]] && cp "$STATE_FILE" "$out/setup.state" 2>/dev/null || true

	# Хвост лога со скрабом возможных секретов
	[[ -f "${SETUP_LOG:-}" ]] && \
		sed -E 's/(password|passwd|pwd|token|secret|IDENTIFIED BY)([=: ]+)[^ "'"'"']+/\1\2***/Ig' "$SETUP_LOG" 2>/dev/null \
		| tail -n 2000 > "$out/setup.log.tail" 2>/dev/null || true

	systemctl list-units --type=service --state=running --no-pager > "$out/services-running.txt" 2>&1 || true
	systemctl --failed --no-pager > "$out/services-failed.txt" 2>&1 || true

	{ if command -v nginx >/dev/null 2>&1; then echo "## nginx -t"; nginx -t 2>&1; echo; echo "## nginx -V"; nginx -V 2>&1; fi
	  if command -v apache2ctl >/dev/null 2>&1; then echo "## apache configtest"; apache2ctl configtest 2>&1; fi; } > "$out/webserver.txt" 2>&1 || true

	ss -tlnp > "$out/ports.txt" 2>&1 || true

	{ if command -v ufw >/dev/null 2>&1; then echo "## ufw"; ufw status verbose 2>&1; fi
	  if command -v fail2ban-client >/dev/null 2>&1; then echo; echo "## fail2ban"; fail2ban-client status 2>&1; fi
	  if command -v cscli >/dev/null 2>&1; then echo; echo "## crowdsec decisions"; cscli decisions list 2>&1 | head -30; fi; } > "$out/firewall.txt" 2>&1 || true

	journalctl -p err -n 300 --no-pager > "$out/journal-errors.txt" 2>&1 || true

	if declare -F run_healthcheck >/dev/null; then HC_NO_CLEAR=1 run_healthcheck > "$out/healthcheck.txt" 2>&1 || true; fi

	{ local c; for c in nginx apache2 php mysql mariadb postfix dovecot named pure-ftpd node redis-server fail2ban-client; do
		command -v "$c" >/dev/null 2>&1 && { printf '%s: ' "$c"; "$c" --version 2>&1 | head -1; }; done; } > "$out/versions.txt" 2>&1 || true

	if tar czf "$tgz" -C /root "$(basename "$out")" 2>/dev/null; then
		rm -rf "$out"; chmod 600 "$tgz" 2>/dev/null || true
		echo ""
		ui_success "Диагностика собрана: ${UI_W}${tgz}${UI_NC}"
		ui_info "Пароли/токены вырезаны, но ПРОВЕРЬ архив перед отправкой: ${UI_W}tar tzf ${tgz}${UI_NC}"
		ui_info "Можно приложить к обращению в поддержку (скачать: scp с сервера)."
	else
		ui_error "Не удалось упаковать архив — содержимое в ${out}/"
		return 1
	fi
	return 0
}
