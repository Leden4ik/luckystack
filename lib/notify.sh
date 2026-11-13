#!/bin/bash
# =============================================================================
# lib/notify.sh — уведомления администратору (email и/или Telegram).
#
#   Ставит автономный helper /usr/local/sbin/server-notify.sh (шлёт сообщение по настроенным
#   каналам) + ежедневный монитор server-monitor.sh (диск, сертификат, службы, бэкап,
#   перезагрузка), который шлёт уведомление при проблемах, а при включённой сводке — каждый день.
#   Настройки — /etc/server-notify.conf (правятся в панели ISPConfig System → Дополнения → Уведомления
#   или вручную, работают без установщика).
#
#   Ключи конфига:
#     NOTIFY_EMAIL       — один или несколько адресов через запятую
#     NOTIFY_FROM        — отправитель (адрес на DKIM-подписанном домене)
#     NOTIFY_TG_TOKEN    — токен бота
#     NOTIFY_TG_CHATS    — один или несколько chat id через пробел (старый ключ NOTIFY_TG_CHAT тоже читается)
#     NOTIFY_EVENTS      — какие события слать: monitor backup malware login digest
#     NOTIFY_LOGIN_MODE  — входы: new (только с нового IP) или all
#     NOTIFY_QUIET       — тихие часы, например 23:00-08:00: в Telegram без звука, кроме критичных
#     NOTIFY_TG_API      — адрес Telegram API (по умолчанию https://api.telegram.org; нужен для тестов)
#     MON_DISK_PCT, MON_CERT_DAYS, MON_BACKUP_DAYS — пороги монитора
# =============================================================================

NOTIFY_HELPER=/usr/local/sbin/server-notify.sh
NOTIFY_MONITOR=/usr/local/sbin/server-monitor.sh
NOTIFY_CONF=/etc/server-notify.conf
NOTIFY_SVC=/etc/systemd/system/server-monitor.service
NOTIFY_TIMER=/etc/systemd/system/server-monitor.timer
NOTIFY_DEFAULT_EVENTS="monitor backup malware login"

# Подобрать отправителя (From) для уведомлений: адрес на DKIM-подписанном почтовом домене
# ISPConfig (SPF+DKIM+DMARC-выравнивание). Пусто, если БД/домена нет → helper упадёт на root@FQDN.
_notify_detect_from() {
	local d=""
	if declare -F _ispc_mysql >/dev/null; then
		d="$(_ispc_mysql -N -B -e "SELECT domain FROM mail_domain WHERE active='y' AND dkim='y' ORDER BY domain LIMIT 1" 2>/dev/null | head -1)"
	fi
	[[ -n "$d" ]] && printf 'noreply@%s' "$d"
}

# Записать /etc/server-notify.conf. То, что уже есть в файле (настроено в панели или вручную),
# сохраняется; значения из setup.conf только заполняют пустые ключи. Раньше конфиг каждый раз
# перезаписывался из setup.conf и стирал настройки панели.
_notify_write_conf() {
	local -A cur=()
	local line k v
	if [[ -f "$NOTIFY_CONF" ]]; then
		while IFS= read -r line; do
			[[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
			k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
			v="${v#\'}"; v="${v%\'}"; v="${v#\"}"; v="${v%\"}"
			cur[$k]="$v"
		done <"$NOTIFY_CONF"
	fi
	# старый ключ одного чата → список чатов
	[[ -z "${cur[NOTIFY_TG_CHATS]:-}" && -n "${cur[NOTIFY_TG_CHAT]:-}" ]] && cur[NOTIFY_TG_CHATS]="${cur[NOTIFY_TG_CHAT]}"
	unset 'cur[NOTIFY_TG_CHAT]'
	local nfrom="${cur[NOTIFY_FROM]:-${NOTIFY_FROM:-}}"
	[[ -z "$nfrom" ]] && nfrom="$(_notify_detect_from)"
	cur[NOTIFY_EMAIL]="${cur[NOTIFY_EMAIL]:-${NOTIFY_EMAIL:-}}"
	cur[NOTIFY_FROM]="$nfrom"
	cur[NOTIFY_TG_TOKEN]="${cur[NOTIFY_TG_TOKEN]:-${NOTIFY_TG_TOKEN:-}}"
	cur[NOTIFY_TG_CHATS]="${cur[NOTIFY_TG_CHATS]:-${NOTIFY_TG_CHAT:-}}"
	cur[NOTIFY_EVENTS]="${cur[NOTIFY_EVENTS]:-$NOTIFY_DEFAULT_EVENTS}"
	cur[NOTIFY_LOGIN_MODE]="${cur[NOTIFY_LOGIN_MODE]:-new}"
	cur[NOTIFY_QUIET]="${cur[NOTIFY_QUIET]:-}"
	cur[MON_DISK_PCT]="${cur[MON_DISK_PCT]:-${MON_DISK_PCT:-90}}"
	cur[MON_CERT_DAYS]="${cur[MON_CERT_DAYS]:-${MON_CERT_DAYS:-14}}"
	cur[MON_BACKUP_DAYS]="${cur[MON_BACKUP_DAYS]:-${MON_BACKUP_DAYS:-2}}"
	unset 'cur[MON_SERVICES]'   # службы монитор теперь находит сам

	local order=(NOTIFY_EMAIL NOTIFY_FROM NOTIFY_TG_TOKEN NOTIFY_TG_CHATS NOTIFY_EVENTS NOTIFY_LOGIN_MODE NOTIFY_QUIET MON_DISK_PCT MON_CERT_DAYS MON_BACKUP_DAYS)
	local tmp; tmp="$(mktemp)"
	{
		echo "# LuckyStack — настройки уведомлений. Правятся в панели ISPConfig (System → Дополнения → Уведомления) или вручную."
		for k in "${order[@]}"; do printf "%s='%s'\n" "$k" "${cur[$k]//\'/}"; unset "cur[$k]"; done
		for k in "${!cur[@]}"; do printf "%s='%s'\n" "$k" "${cur[$k]//\'/}"; done
	} >"$tmp"
	install -m 600 -o root -g root "$tmp" "$NOTIFY_CONF"
	rm -f "$tmp"
}

# Точка входа — вызывается из main() в финале и из --update. Ставит helper, монитор и таймер
# ВСЕГДА (канал можно задать позже в панели), конфиг — с сохранением настроек панели.
apply_notifications() {
	ui_step "Уведомления (email / Telegram) + ежедневный монитор"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} ${NOTIFY_HELPER} + ${NOTIFY_MONITOR} + ежедневный таймер + ${NOTIFY_CONF}"
		return 0
	fi

	_notify_write_conf
	_notify_write_helper  || { ui_warn "Не удалось записать ${NOTIFY_HELPER}."; return 0; }
	_notify_write_monitor || { ui_warn "Не удалось записать ${NOTIFY_MONITOR}."; return 0; }
	chmod 700 "$NOTIFY_HELPER" "$NOTIFY_MONITOR" 2>/dev/null || true
	_notify_write_login_watch
	_notify_install_bot

	cat >"$NOTIFY_SVC" <<EOF
[Unit]
Description=Server monitor (disk/cert/services/backup) → notify

[Service]
Type=oneshot
ExecStart=${NOTIFY_MONITOR}
Nice=15
EOF
	cat >"$NOTIFY_TIMER" <<EOF
[Unit]
Description=Daily server monitor → notify on problems (and daily digest if enabled)

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
EOF
	systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
	systemctl enable --now server-monitor.timer >>"$SETUP_LOG" 2>&1 || ui_warn "Не удалось включить server-monitor.timer."

	# что в итоге настроено (значения берём из записанного конфига)
	local email tgt chats
	email="$(. "$NOTIFY_CONF"; echo "${NOTIFY_EMAIL:-}")"
	tgt="$(. "$NOTIFY_CONF"; echo "${NOTIFY_TG_TOKEN:-}")"
	chats="$(. "$NOTIFY_CONF"; echo "${NOTIFY_TG_CHATS:-}")"
	if [[ -n "$tgt" && -z "$chats" ]]; then
		ui_warn "Токен Telegram-бота задан, а chat id нет — в Telegram ничего не уйдёт."
		ui_info "Напишите боту /start и выберите чат в панели: System → Дополнения → Уведомления → «Найти chat id»."
	fi
	[[ -n "$email" ]] && ! command -v sendmail >/dev/null 2>&1 && ! command -v mail >/dev/null 2>&1 && \
		ui_warn "Для email-уведомлений нужен MTA (компонент mail) — иначе работает только Telegram."

	if [[ -n "$email" || ( -n "$tgt" && -n "$chats" ) ]]; then
		if "$NOTIFY_HELPER" "Уведомления настроены" "luckystack: канал уведомлений активен на $(hostname -f 2>/dev/null || hostname)."; then
			ui_success "Уведомления настроены — отправлено тестовое сообщение."
		else
			ui_warn "Уведомления настроены, но тестовая отправка не прошла — проверьте ${NOTIFY_CONF} (для email нужен MTA)."
		fi
	else
		ui_info "Канал уведомлений не задан: монитор работает, но слать некуда. Настройте в панели: System → Дополнения → Уведомления."
	fi
	log "notify: email=${email:+set} tg_token=${tgt:+set} chats=${chats:+set}"
	return 0
}

# --- Рантайм-helper: шлёт сообщение по настроенным каналам -------------------
_notify_write_helper() {
	cat >"$NOTIFY_HELPER" <<'SCRIPT'
#!/bin/bash
# server-notify.sh [-e событие] [-l info|warn|crit] "тема" ["тело"] — уведомление по каналам.
#   -e  событие (monitor backup malware login digest bot): если его нет в NOTIFY_EVENTS,
#       сообщение не шлётся (выход 0). Без -e шлётся всегда (тест, ручной вызов).
#   -l  уровень: crit приходит со звуком и в тихие часы, остальное в тихие часы без звука.
# Конфиг: /etc/server-notify.conf. Возврат 0, если хотя бы один канал отправил (или событие выключено).
set -uo pipefail
# зовут и из cron, а sendmail лежит в /usr/sbin
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /etc/server-notify.conf 2>/dev/null || true
EVENT=""; LEVEL="warn"
while getopts "e:l:" o; do case "$o" in e) EVENT="$OPTARG" ;; l) LEVEL="$OPTARG" ;; *) ;; esac; done
shift $((OPTIND - 1))
SUBJ="${1:-Уведомление сервера}"; BODY="${2:-$SUBJ}"
HOST="$(hostname -f 2>/dev/null || hostname)"

if [[ -n "$EVENT" ]]; then
	case " ${NOTIFY_EVENTS:-monitor backup malware login} " in *" $EVENT "*) ;; *) exit 0 ;; esac
fi

# тихие часы: NOTIFY_QUIET='23:00-08:00' (через полночь тоже)
silent=false
if [[ "$LEVEL" != "crit" && "${NOTIFY_QUIET:-}" =~ ^([0-9]{1,2}):([0-9]{2})-([0-9]{1,2}):([0-9]{2})$ ]]; then
	s=$((10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]})); e=$((10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]}))
	n=$((10#$(date +%H) * 60 + 10#$(date +%M)))
	if (( s < e )); then (( n >= s && n < e )) && silent=true
	elif (( s > e )); then (( n >= s || n < e )) && silent=true; fi
fi

sent=0
# --- Email (нужен sendmail/mail = работающий MTA). Несколько адресов через запятую. ---
# Отправитель NOTIFY_FROM должен быть на DKIM-подписанном домене (ставит панель/установщик),
# иначе mail.ru и пр. режут как спам. Фолбэк — root@FQDN.
if [[ -n "${NOTIFY_EMAIL:-}" ]]; then
	FROM="${NOTIFY_FROM:-root@$HOST}"
	TO="$(printf '%s' "$NOTIFY_EMAIL" | tr ' ;' ',,' | tr -s ',' | sed 's/^,//; s/,$//')"
	if command -v sendmail >/dev/null 2>&1; then
		# Русская тема и текст: без кодировки письмо приходит кракозябрами или попадает в спам
		SUBJ_ENC="=?UTF-8?B?$(printf '[%s] %s' "$HOST" "$SUBJ" | base64 -w0)?="
		printf 'From: %s\nTo: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n' "$FROM" "$TO" "$SUBJ_ENC" "$BODY" \
			| sendmail -f "$FROM" -t 2>/dev/null && sent=1
	elif command -v mail >/dev/null 2>&1; then
		printf '%s\n' "$BODY" | mail -s "[$HOST] $SUBJ" -r "$FROM" ${TO//,/ } 2>/dev/null && sent=1
	fi
fi
# --- Telegram: на все чаты из NOTIFY_TG_CHATS (и старого NOTIFY_TG_CHAT) ---
chats="${NOTIFY_TG_CHATS:-} ${NOTIFY_TG_CHAT:-}"
if [[ -n "${NOTIFY_TG_TOKEN:-}" && -n "${chats// /}" ]] && command -v curl >/dev/null 2>&1; then
	api="${NOTIFY_TG_API:-https://api.telegram.org}"
	text="$(printf '[%s] %s\n%s' "$HOST" "$SUBJ" "$BODY" | head -c 4000)"
	seen=" "
	for c in $(printf '%s' "$chats" | tr ',;' '  '); do
		[[ "$c" =~ ^-?[0-9]+$ ]] || continue
		[[ "$seen" == *" $c "* ]] && continue; seen+="$c "
		curl -s --max-time 15 "${api}/bot${NOTIFY_TG_TOKEN}/sendMessage" \
			--data-urlencode "chat_id=${c}" --data-urlencode "text=${text}" \
			--data-urlencode "disable_notification=${silent}" 2>/dev/null | grep -q '"ok":true' && sent=1
	done
fi
exit $(( sent ? 0 : 1 ))
SCRIPT
}

# --- Рантайм-монитор: проблемы → уведомление; при включённой сводке — ежедневно ---
_notify_write_monitor() {
	cat >"$NOTIFY_MONITOR" <<'SCRIPT'
#!/bin/bash
# server-monitor.sh — ежедневная проверка. Проблемы → уведомление (событие monitor).
# Если в NOTIFY_EVENTS есть digest — каждый день сводка о сервере (даже без проблем).
set -uo pipefail
. /etc/server-notify.conf 2>/dev/null || true
NOTIFY=/usr/local/sbin/server-notify.sh
problems=()

# Диск /
use="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')"
[[ "${use:-0}" =~ ^[0-9]+$ ]] && (( use >= ${MON_DISK_PCT:-90} )) && \
	problems+=("Диск / заполнен на ${use}% (порог ${MON_DISK_PCT:-90}%)")

# TLS-сертификат хоста (панель, почта)
crt=/usr/local/ispconfig/interface/ssl/ispserver.crt
cert_days=""
if [[ -f "$crt" ]] && command -v openssl >/dev/null 2>&1; then
	enddate="$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)"
	if [[ -n "$enddate" ]]; then
		end="$(date -d "$enddate" +%s 2>/dev/null || echo 0)"
		cert_days=$(( (end - $(date +%s)) / 86400 ))
		(( end > 0 && cert_days < ${MON_CERT_DAYS:-14} )) && problems+=("TLS-сертификат хоста истекает через ${cert_days} дн.")
	fi
fi

# Службы: всё, что включено, из известного списка + все PHP-FPM
svcs=""
for s in mariadb mysql redis-server postfix dovecot named bind9 nginx apache2 rspamd crowdsec crowdsec-firewall-bouncer fail2ban pure-ftpd-mysql clamav-daemon $(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{sub(".service","",$1); print $1}'); do
	systemctl is-enabled --quiet "$s" 2>/dev/null && svcs+="$s "
done
for s in $svcs; do
	systemctl is-active --quiet "$s" 2>/dev/null || problems+=("Служба ${s} НЕ активна")
done

# Свежесть бэкапа (если настроен наш backup-модуль); снимки — каталоги вида 20261105-033000
backup_age=""
if [[ -f /etc/server-backup.conf ]]; then
	bkdir="$( . /etc/server-backup.conf 2>/dev/null; echo "${BACKUP_DIR:-/var/backups/server}" )"
	newest="$(find "$bkdir" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
	if [[ -n "$newest" ]]; then
		backup_age=$(( ( $(date +%s) - ${newest%.*} ) / 86400 ))
		(( backup_age > ${MON_BACKUP_DAYS:-2} )) && problems+=("Бэкап устарел: последний снимок ${backup_age} дн. назад (порог ${MON_BACKUP_DAYS:-2} дн.)")
	else
		problems+=("Бэкап настроен (${bkdir}), но снимков нет — проверьте server-backup.sh")
	fi
fi

# Нужна перезагрузка (обновилось ядро или системные библиотеки)
reboot_need=""
[[ -f /var/run/reboot-required ]] && reboot_need="да" && problems+=("Нужна перезагрузка: $(tr '\n' ' ' </var/run/reboot-required.pkgs 2>/dev/null | head -c 200)")

# ufw выключен, а правила остались в ядре: status пишет active, но reload молчит, а после
# перезагрузки фаервола не будет (так делает штатный firewall_plugin ISPConfig)
if [[ -f /etc/ufw/ufw.conf ]] && ! grep -qE '^ENABLED=yes' /etc/ufw/ufw.conf && iptables -S ufw-user-input >/dev/null 2>&1; then
	problems+=("ufw выключен (ENABLED=no): правила не обновляются, после перезагрузки фаервола не будет. Исправить: luckyctl update")
fi

# MariaDB 3306 открыт всем: у какой-то базы включён Remote access без списка IP
if command -v iptables >/dev/null 2>&1 && iptables -S ufw-before-input 2>/dev/null | grep -- '--dport 3306 -j ACCEPT' | grep -vq -- ' -s '; then
	problems+=("MariaDB (порт 3306) открыт всему интернету: у базы включён Remote access без списка IP. Укажите IP в настройках базы")
fi

if (( ${#problems[@]} > 0 )); then
	"$NOTIFY" -e monitor -l warn "Проблемы (${#problems[@]})" "$(printf '• %s\n' "${problems[@]}")" || true
fi

# Вышла новая версия Roundcube (стоит с сайта разработчиков): GitHub спрашиваем не чаще раза
# в сутки, об одной версии сообщаем один раз. Обновление: luckyctl update.
rc_ini=/opt/roundcube/program/include/iniset.php
if [[ -f "$rc_ini" ]] && command -v php >/dev/null 2>&1; then
	st=/var/lib/server-monitor; mkdir -p "$st"
	rc_cur="$(grep -oE "RCMAIL_VERSION'?,[[:space:]]*'[0-9.]+" "$rc_ini" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$')"
	if [[ -n "$rc_cur" ]] && [[ -z "$(find "$st/rc-latest" -mmin -1380 2>/dev/null)" ]]; then
		curl -fsSL --max-time 20 "https://api.github.com/repos/roundcube/roundcubemail/releases?per_page=40" 2>/dev/null \
			| php -r '$b=$argv[1]; foreach ((array)json_decode(stream_get_contents(STDIN), true) as $x) {
				if (empty($x["prerelease"]) && preg_match("/^".preg_quote($b)."\\.[0-9]+$/", $x["tag_name"] ?? "")) { echo $x["tag_name"]; break; } }' \
				"${rc_cur%.*}" >"$st/rc-latest.tmp" 2>/dev/null && [[ -s "$st/rc-latest.tmp" ]] && mv -f "$st/rc-latest.tmp" "$st/rc-latest"
		rm -f "$st/rc-latest.tmp"
	fi
	rc_new="$(cat "$st/rc-latest" 2>/dev/null)"
	if [[ -n "$rc_cur" && -n "$rc_new" ]] && dpkg --compare-versions "$rc_cur" lt "$rc_new" \
	   && [[ "$(cat "$st/rc-notified" 2>/dev/null)" != "$rc_new" ]]; then
		"$NOTIFY" -e monitor -l warn "Roundcube: вышла версия ${rc_new}" \
			"Стоит ${rc_cur}. Разработчики выпускают исправления безопасности именно так. Обновить: luckyctl update (раздел безопасности, с бэкапом и откатом)." \
			&& echo "$rc_new" >"$st/rc-notified"
	fi
fi

# Ежедневная сводка (событие digest)
case " ${NOTIFY_EVENTS:-} " in *" digest "*)
	upd="$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst')"
	sec="$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep '^Inst' | grep -ci security)"
	bans_cs="—"; command -v cscli >/dev/null 2>&1 && bans_cs="$(cscli decisions list -o raw 2>/dev/null | tail -n +2 | grep -c .)"
	alerts_cs="—"; command -v cscli >/dev/null 2>&1 && alerts_cs="$(cscli alerts list --since 24h -o raw 2>/dev/null | tail -n +2 | grep -c .)"
	bans_f2b="—"; command -v fail2ban-client >/dev/null 2>&1 && bans_f2b="$(fail2ban-client banned 2>/dev/null | grep -oE "'[0-9a-fA-F:.]+'" | grep -c .)"
	us="$(cut -d. -f1 /proc/uptime)"; upt="$(( us / 86400 )) д $(( us % 86400 / 3600 )) ч $(( us % 3600 / 60 )) мин"; upt="${upt#0 д }"
	if [[ -n "$backup_age" ]]; then bk_txt="последний ${backup_age} дн. назад"; elif [[ -f /etc/server-backup.conf ]]; then bk_txt="снимков нет"; else bk_txt="не настроен"; fi
	if [[ -n "$cert_days" ]]; then cert_txt="ещё ${cert_days} дн."; else cert_txt="—"; fi
	logins="—"; [[ -f /var/log/server-login-watch.log ]] && logins="$(awk -v t="$(date -d '-24 hours' '+%F %T')" '$0 >= t' /var/log/server-login-watch.log 2>/dev/null | grep -c .)"
	body="$(printf '%s\n' \
		"Аптайм: ${upt}, нагрузка: $(cut -d' ' -f1-3 /proc/loadavg)" \
		"Диск /: ${use:-?}%, память: $(free -m | awk '/^Mem:/{printf "%d из %d МБ", $3, $2}')" \
		"Службы: $( (( ${#problems[@]} )) && echo "есть проблемы (${#problems[@]})" || echo "все работают")" \
		"Бэкап: ${bk_txt}" \
		"Сертификат хоста: ${cert_txt}" \
		"Обновления: ${upd} (безопасности: ${sec}), перезагрузка: ${reboot_need:-не нужна}" \
		"CrowdSec: активных банов ${bans_cs}, срабатываний за сутки ${alerts_cs}; fail2ban: банов ${bans_f2b}" \
		"Входов в панель и по SSH за сутки: ${logins}")"
	(( ${#problems[@]} )) && body+=$'\n\n'"Проблемы:"$'\n'"$(printf '• %s\n' "${problems[@]}")"
	"$NOTIFY" -e digest -l info "Сводка за сутки" "$body" || true
	;;
esac
exit 0
SCRIPT
}

# --- Наблюдение за входами (панель ISPConfig и SSH) → уведомление (событие login) ----
# Служба читает журнал sshd и /var/log/ispconfig/auth.log в реальном времени. PAM и конфиг SSH
# не трогаются, поэтому ошибка здесь не может закрыть доступ к серверу.
NOTIFY_LOGIN_WATCH=/usr/local/sbin/server-login-watch.sh
NOTIFY_LOGIN_SVC=/etc/systemd/system/server-login-watch.service

_notify_write_login_watch() {
	cat >"$NOTIFY_LOGIN_WATCH" <<'SCRIPT'
#!/bin/bash
# server-login-watch.sh — входы в панель ISPConfig и по SSH → server-notify.sh -e login.
#   NOTIFY_LOGIN_MODE=new — сообщать только о входе с нового IP (не было за 180 дней), all — о каждом.
#   Подбор пароля к панели: 5 неудачных входов с одного IP за 10 минут → одно сообщение (не чаще раза в час).
# Журнал всех входов: /var/log/server-login-watch.log (по нему считает сводка).
set -uo pipefail
STATE=/var/lib/server-notify; KNOWN=$STATE/known-logins; LOG=/var/log/server-login-watch.log
NOTIFY=/usr/local/sbin/server-notify.sh
AUTHLOG=/var/log/ispconfig/auth.log
mkdir -p "$STATE"; chmod 700 "$STATE"; touch "$KNOWN" "$LOG"; chmod 600 "$KNOWN" "$LOG"

ts() { date '+%F %T'; }

# Первый запуск: входы за 30 дней считаем известными, чтобы не прислать «новый IP» про свои же адреса
if [[ ! -s "$KNOWN" ]]; then
	now=$(date +%s)
	journalctl _COMM=sshd _COMM=sshd-session --since "-30d" -o cat 2>/dev/null | sed -nE 's/^Accepted [a-z-]+ for ([^ ]+) from ([0-9a-fA-F:.]+) .*/ssh \1 \2/p' | sort -u | while read -r k u i; do echo "$k $u $i $now"; done >>"$KNOWN"
	[[ -r "$AUTHLOG" ]] && sed -nE "s/^Successful login for user '([^']+)' +from ([0-9a-fA-F:.]+) .*/panel \1 \2/p" "$AUTHLOG" | sort -u | while read -r k u i; do echo "$k $u $i $now"; done >>"$KNOWN"
fi

# имя ключа SSH по отпечатку (из authorized_keys пользователя)
key_name() {
	local user="$1" fp="$2" home
	home="$(getent passwd "$user" | cut -d: -f6)"
	[[ -n "$home" && -r "$home/.ssh/authorized_keys" ]] || return 0
	ssh-keygen -lf "$home/.ssh/authorized_keys" 2>/dev/null | awk -v f="$fp" '$2==f { $1=""; $2=""; sub(/^  /,""); print; exit }'
}
trusted_note() {
	command -v mariadb >/dev/null 2>&1 || return 0
	# у службы systemd нет HOME, поэтому файл с паролем root указываем явно
	local def=(); [[ -r /root/.my.cnf ]] && def=(--defaults-file=/root/.my.cnf)
	local c; c="$(timeout 5 mariadb "${def[@]}" -N dbispconfig -e "SELECT comment FROM ss_trusted_ip WHERE target='$1' LIMIT 1" 2>/dev/null)"
	[[ -n "$c" ]] && printf 'доверенный IP: %s' "$c"
}

# вход: kind (ssh|panel), user, ip, details
on_login() {
	local kind="$1" user="$2" ip="$3" det="${4:-}" now isnew=1 last label
	[[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || return 0
	[[ "$user" =~ ^[A-Za-z0-9._@-]+$ ]] || return 0
	now=$(date +%s)
	# известен ли IP для этого пользователя (за 180 дней)
	last="$(awk -v k="$kind" -v u="$user" -v i="$ip" '$1==k && $2==u && $3==i { t=$4 } END { print t+0 }' "$KNOWN")"
	(( last > 0 && now - last < 180 * 86400 )) && isnew=0
	# повтор того же входа в течение 10 минут не дублируем
	local recent=0; (( last > 0 && now - last < 600 )) && recent=1
	echo "$kind $user $ip $now" >>"$KNOWN"
	# держим файл компактным: по одной строке на kind+user+ip
	if (( $(wc -l <"$KNOWN") > 2000 )); then
		awk '{ k=$1" "$2" "$3; t[k]=$4 } END { for(k in t) print k, t[k] }' "$KNOWN" >"$KNOWN.tmp" && mv "$KNOWN.tmp" "$KNOWN"
	fi
	label=$([[ "$kind" == ssh ]] && echo "по SSH" || echo "в панель ISPConfig")
	echo "$(ts) $kind $user $ip $([[ $isnew == 1 ]] && echo new || echo known)${det:+ $det}" >>"$LOG"

	. /etc/server-notify.conf 2>/dev/null || true
	local mode="${NOTIFY_LOGIN_MODE:-new}"
	if [[ "$isnew" == 1 || ( "$mode" == all && "$recent" == 0 ) ]]; then
		local host rdns tn body
		host="$(hostname -f 2>/dev/null || hostname)"
		rdns="$(timeout 2 getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')"
		tn="$(trusted_note "$ip")"
		body="$(printf '%s\n' "Пользователь: $user" "IP: $ip${rdns:+ ($rdns)}$([[ $isnew == 1 ]] && echo ' — НОВЫЙ IP')" ${det:+"$det"} ${tn:+"$tn"} "Время: $(ts)")"
		"$NOTIFY" -e login -l "$([[ $isnew == 1 ]] && echo warn || echo info)" "Вход ${label}: ${user} с ${ip}" "$body" || true
	fi
}

# подбор пароля к панели: 5 неудач с IP за 10 минут → сообщение (не чаще раза в час на IP)
declare -A FAILS=() FAIL_ALERTED=()
on_panel_fail() {
	local user="$1" ip="$2" now; now=$(date +%s)
	[[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || return 0
	echo "$(ts) panel-fail $user $ip" >>"$LOG"
	local list="${FAILS[$ip]:-} $now" kept="" t n=0
	for t in $list; do (( now - t < 600 )) && { kept+=" $t"; n=$((n + 1)); }; done
	FAILS[$ip]="$kept"
	if (( n >= 5 )) && (( now - ${FAIL_ALERTED[$ip]:-0} > 3600 )); then
		FAIL_ALERTED[$ip]=$now
		"$NOTIFY" -e login -l warn "Подбор пароля к панели с ${ip}" "$(printf '%s\n' "Неудачных входов за 10 минут: $n" "Последний логин: $user" "IP: $ip" "Время: $(ts)")" || true
	fi
}

watch_ssh() {
	journalctl -f -n0 _COMM=sshd _COMM=sshd-session -o cat 2>/dev/null | while IFS= read -r line; do
		if [[ "$line" =~ ^Accepted\ ([a-z-]+)\ for\ ([^ ]+)\ from\ ([0-9a-fA-F:.]+)\ port\ [0-9]+\ ssh2(:\ ([A-Z0-9-]+)\ (SHA256:[^ ]+))? ]]; then
			# каждое значение отдельно: в одной команде local bash раскрывает всё до присваивания
			local method="${BASH_REMATCH[1]}" user="${BASH_REMATCH[2]}" ip="${BASH_REMATCH[3]}" fp="${BASH_REMATCH[6]:-}"
			local det="Способ: $method" kn=""
			if [[ -n "$fp" ]]; then kn="$(key_name "$user" "$fp")"; det="Ключ: ${kn:-$fp}"; fi
			[[ "$method" == password ]] && det="Способ: ПАРОЛЬ"
			on_login ssh "$user" "$ip" "$det"
		fi
	done
}
watch_panel() {
	tail -n0 -F "$AUTHLOG" 2>/dev/null | while IFS= read -r line; do
		if [[ "$line" =~ ^Successful\ login\ for\ user\ \'([^\']+)\'\ +from\ ([0-9a-fA-F:.]+) ]]; then
			on_login panel "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
		elif [[ "$line" =~ ^Failed\ login\ for\ user\ \'([^\']*)\'\ +from\ ([0-9a-fA-F:.]+) ]]; then
			on_panel_fail "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
		fi
	done
}

watch_ssh &
watch_panel &
wait -n
exit 1   # один из потоков завершился — systemd перезапустит службу
SCRIPT
	chmod 700 "$NOTIFY_LOGIN_WATCH"
	cat >"$NOTIFY_LOGIN_SVC" <<EOF
[Unit]
Description=Login watcher (ISPConfig panel + SSH) → notify
After=network.target

[Service]
ExecStart=${NOTIFY_LOGIN_WATCH}
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
	systemctl enable server-login-watch.service >>"$SETUP_LOG" 2>&1 || true
	systemctl restart server-login-watch.service >>"$SETUP_LOG" 2>&1 || ui_warn "Не удалось запустить server-login-watch (оповещения о входах)."
	# ротация журнала входов
	cat >/etc/logrotate.d/server-login-watch <<'EOF'
/var/log/server-login-watch.log {
	monthly
	rotate 6
	compress
	missingok
	notifempty
	create 600 root root
}
EOF
}

# --- Управление сервером из Telegram (служба server-tg-bot) ---------------------
# Скрипт и служба ставятся всегда, а работают только при NOTIFY_TG_BOT='y' в конфиге
# (включается галочкой в панели System → Дополнения → Уведомления). Подробности — в шапке server-tg-bot.php.
NOTIFY_BOT=/usr/local/sbin/server-tg-bot.php
NOTIFY_BOT_SVC=/etc/systemd/system/server-tg-bot.service

_notify_install_bot() {
	local src="${ASSETS_DIR:-$SCRIPT_DIR/assets}/notify/server-tg-bot.php"
	[[ -f "$src" ]] || { ui_warn "Нет assets/notify/server-tg-bot.php — управление из Telegram не установлено."; return 0; }
	command -v php >/dev/null 2>&1 && ! php -l "$src" >/dev/null 2>&1 && { ui_warn "php -l server-tg-bot.php не прошёл — бот не установлен."; return 0; }
	install -o root -g root -m 700 "$src" "$NOTIFY_BOT"
	cat >"$NOTIFY_BOT_SVC" <<EOF
[Unit]
Description=Telegram bot: server control (status, bans, unban, allow, backup)
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/php ${NOTIFY_BOT}
Restart=always
RestartSec=15
Nice=10

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
	cat >/etc/logrotate.d/server-tg-bot <<'EOF'
/var/log/server-tg-bot.log {
	monthly
	rotate 6
	compress
	missingok
	notifempty
	create 600 root root
}
EOF
	if [[ "$(. "$NOTIFY_CONF" 2>/dev/null; echo "${NOTIFY_TG_BOT:-n}")" == "y" ]]; then
		systemctl enable server-tg-bot.service >>"$SETUP_LOG" 2>&1 || true
		systemctl restart server-tg-bot.service >>"$SETUP_LOG" 2>&1 || ui_warn "Не удалось запустить server-tg-bot."
	else
		systemctl disable --now server-tg-bot.service >>"$SETUP_LOG" 2>&1 || true
	fi
}

# --- Удаление (вызывается из run_uninstall, как swap) -----------------------
_un_remove_notify() {
	[[ -e "$NOTIFY_HELPER" || -e "$NOTIFY_CONF" || -e "$NOTIFY_TIMER" ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} удалить уведомления (server-notify/monitor + таймер + conf)"
		return 0
	fi
	systemctl disable --now server-monitor.timer >>"$SETUP_LOG" 2>&1 || true
	systemctl disable --now server-login-watch.service >>"$SETUP_LOG" 2>&1 || true
	systemctl disable --now server-tg-bot.service >>"$SETUP_LOG" 2>&1 || true
	rm -f "$NOTIFY_HELPER" "$NOTIFY_MONITOR" "$NOTIFY_CONF" "$NOTIFY_SVC" "$NOTIFY_TIMER" \
		"$NOTIFY_LOGIN_WATCH" "$NOTIFY_LOGIN_SVC" /etc/logrotate.d/server-login-watch \
		"$NOTIFY_BOT" "$NOTIFY_BOT_SVC" /etc/logrotate.d/server-tg-bot
	rm -rf /var/lib/server-notify /var/lib/server-monitor /var/log/server-login-watch.log /var/log/server-tg-bot.log
	systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
	ui_info "  Уведомления удалены (helper + монитор + таймер + конфиг)."
}
