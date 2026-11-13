#!/bin/bash
# =============================================================================
# lib/maildeliver.sh — Этап (опц.): доставляемость и TLS-харденинг почты.
#
#   ISPConfig поднимает Postfix/Dovecot и DKIM, но «доставляемость» (почему
#   письма уходят в спам / не шифруются) обычно остаётся на администраторе.
#   Этот этап:
#     • усиливает TLS в Postfix (выключает устаревшие SSLv3/TLSv1/1.1)
#     • проверяет rDNS/PTR главного IP и предупреждает о несовпадении
#     • проверяет наличие SPF/DMARC в DNS (если есть dig)
#     • генерирует ШПАРГАЛКУ DNS-записей (SPF, DMARC, MTA-STS, TLS-RPT) в файл,
#       которые нужно опубликовать у вашего DNS-провайдера
#     • кладёт готовый MTA-STS policy-файл для публикации
#   DNS-записи установщик опубликовать не может (зона у вашего провайдера) —
#   поэтому он их ГОТОВИТ и показывает, а не применяет молча.
# =============================================================================

MAILDELIVER_RECORDS=/root/mail-dns-records.txt
MAILDELIVER_MTASTS=/root/mta-sts-policy.txt

# Логин к почте только поверх TLS: пароль не уходит открытым текстом.
#  • Postfix: smtpd_tls_auth_only=yes — AUTH на 25 только после STARTTLS (587/465 и так с TLS).
#  • Dovecot: 2.3 disable_plaintext_auth=yes, 2.4+ auth_allow_cleartext=no. С localhost
#    Dovecot по-прежнему пускает (Roundcube ходит на localhost:143 — вебмейл не ломается).
# Dovecot-настройку пишем туда, где её не затрёт обновление ISPConfig: живой
# conf.d/99-ispconfig-custom-config.conf (его подключает dovecot.conf ISPConfig) и мастер
# conf-custom/install/dovecot_custom.conf.master (из него ISPConfig пересоздаёт файл при
# обновлении). Наш блок между маркерами, чужие строки в файлах не трогаем.
MAIL_DVC_CUSTOM=/etc/dovecot/conf.d/99-ispconfig-custom-config.conf
MAIL_DVC_MASTER=/usr/local/ispconfig/server/conf-custom/install/dovecot_custom.conf.master

_mail_block_put() {
	local f="$1" body="$2" tmp
	tmp="$(mktemp)" || return 1
	[[ -f "$f" ]] && sed '/^# luckystack: auth-tls BEGIN/,/^# luckystack: auth-tls END/d' "$f" >"$tmp"
	printf '# luckystack: auth-tls BEGIN\n%s\n# luckystack: auth-tls END\n' "$body" >>"$tmp"
	if [[ -f "$f" ]] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
	install -m 644 "$tmp" "$f"; rm -f "$tmp"
}

_mail_auth_tls_only() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} почта: логин только по TLS (Postfix + Dovecot)"; return 0; }
	if command -v postconf >/dev/null 2>&1 && [[ -f /etc/postfix/main.cf ]]; then
		if [[ "$(postconf -h smtpd_tls_auth_only 2>/dev/null)" != "yes" ]]; then
			postconf -e 'smtpd_tls_auth_only = yes' >>"$SETUP_LOG" 2>&1 \
				&& systemctl reload postfix >>"$SETUP_LOG" 2>&1 \
				&& ui_success "Postfix: AUTH только после STARTTLS (smtpd_tls_auth_only=yes)."
		fi
	fi
	command -v dovecot >/dev/null 2>&1 && [[ -f /etc/dovecot/dovecot.conf ]] || return 0
	# Подключает ли dovecot.conf наш файл? (ISPConfig-шаблон — да; голый Debian — conf.d/*.conf)
	if ! grep -qE '^[[:space:]]*!include(_try)?[[:space:]]+(conf\.d/\*\.conf|conf\.d/99-ispconfig-custom-config\.conf|/etc/dovecot/conf\.d/99-ispconfig-custom-config\.conf)' /etc/dovecot/dovecot.conf; then
		ui_warn "Dovecot: dovecot.conf не подключает ${MAIL_DVC_CUSTOM} — запрет открытого пароля пропущен."
		return 0
	fi
	local ver line
	ver="$(dovecot --version 2>/dev/null | awk '{print $1}')"
	case "$ver" in
		2.[4-9]*|[3-9].*) line='auth_allow_cleartext = no' ;;
		*)                line='disable_plaintext_auth = yes' ;;
	esac
	# уже применено (и в живом файле, и в мастере) — ничего не трогаем, Dovecot не перечитываем
	if grep -qxF "$line" "$MAIL_DVC_CUSTOM" 2>/dev/null \
	   && { [[ ! -d "${MAIL_DVC_MASTER%/*}" ]] || grep -qxF "$line" "$MAIL_DVC_MASTER" 2>/dev/null; } \
	   && [[ "$(doveconf -h "${line%% *}" 2>/dev/null)" == "${line##* }" ]]; then
		return 0
	fi
	local had=0; [[ -f "$MAIL_DVC_CUSTOM" ]] && had=1 && cp -a "$MAIL_DVC_CUSTOM" "${MAIL_DVC_CUSTOM}.ss-prev"
	_mail_block_put "$MAIL_DVC_CUSTOM" "$line" || return 0
	if ! doveconf -n >/dev/null 2>&1; then
		if ((had)); then mv -f "${MAIL_DVC_CUSTOM}.ss-prev" "$MAIL_DVC_CUSTOM"; else rm -f "$MAIL_DVC_CUSTOM"; fi
		ui_warn "Dovecot ${ver}: «${line}» не прошло doveconf -n — откат, Dovecot не тронут."
		return 0
	fi
	rm -f "${MAIL_DVC_CUSTOM}.ss-prev"
	[[ -d "${MAIL_DVC_MASTER%/*}" ]] && _mail_block_put "$MAIL_DVC_MASTER" "$line"
	if [[ "$(doveconf -h "${line%% *}" 2>/dev/null)" == "${line##* }" ]]; then
		systemctl reload dovecot >>"$SETUP_LOG" 2>&1 || systemctl restart dovecot >>"$SETUP_LOG" 2>&1
		ui_success "Dovecot: пароль только поверх TLS (${line}); с localhost (Roundcube) — как раньше."
	else
		ui_warn "Dovecot: ${line} записано, но doveconf показывает другое значение — проверьте ${MAIL_DVC_CUSTOM}."
	fi
	return 0
}

# Включить submission (587, STARTTLS) и submissions (465, implicit TLS) через
# postconf -M/-P (идемпотентно). SASL-тип/путь и прочее наследуются из main.cf,
# который настроил ISPConfig (Dovecot SASL). На submission-портах требуем аутентификацию.
_maildeliver_enable_submission() {
	command -v postconf >/dev/null 2>&1 || return 0
	ui_step "Включение submission (587) и submissions (465) для почтовых клиентов"
	# 587 — STARTTLS
	postconf -M "submission/inet=submission inet n - y - - smtpd" >>"$SETUP_LOG" 2>&1 || true
	postconf -P "submission/inet/syslog_name=postfix/submission" \
	            "submission/inet/smtpd_tls_security_level=encrypt" \
	            "submission/inet/smtpd_sasl_auth_enable=yes" \
	            "submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject" >>"$SETUP_LOG" 2>&1 || true
	# 465 — implicit TLS (wrappermode)
	postconf -M "submissions/inet=submissions inet n - y - - smtpd" >>"$SETUP_LOG" 2>&1 || true
	postconf -P "submissions/inet/syslog_name=postfix/submissions" \
	            "submissions/inet/smtpd_tls_wrappermode=yes" \
	            "submissions/inet/smtpd_tls_security_level=encrypt" \
	            "submissions/inet/smtpd_sasl_auth_enable=yes" \
	            "submissions/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject" >>"$SETUP_LOG" 2>&1 || true
	sys_run "Перезапуск Postfix (submission/submissions)" systemctl restart postfix || \
		systemctl reload postfix >>"$SETUP_LOG" 2>&1 || true
	if ss -ltn 2>/dev/null | grep -qE ':587[[:space:]]'; then
		ui_success "submission :587 (STARTTLS) и submissions :465 (TLS) включены, аутентификация обязательна."
	else
		ui_warn "submission :587 не поднялся — проверьте Postfix (${SETUP_LOG})."
	fi
}

stage_maildeliver() {
	if ! command -v postfix >/dev/null 2>&1; then
		ui_info "Postfix не установлен — этап доставляемости почты пропущен (нужен компонент «Почта»)."
		return 0
	fi

	local fqdn="${SERVER_FQDN:-$(hostname -f 2>/dev/null || hostname)}"
	local domain="$fqdn"
	# server1.example.com → example.com (если меток ≥3, берём родительский домен)
	if (( $(awk -F. '{print NF}' <<<"$fqdn") >= 3 )); then domain="${fqdn#*.}"; fi
	local main_ip; main_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"

	ui_info "Доставляемость почты: домен ${domain}, FQDN ${fqdn}, IP ${main_ip:-?}"

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} postconf: отключение SSLv3/TLSv1/1.1, tls_preempt_cipherlist"
		ui_info "${UI_D}[dry-run]${UI_NC} проверка rDNS/PTR и SPF/DMARC"
		ui_info "${UI_D}[dry-run]${UI_NC} генерация ${MAILDELIVER_RECORDS} + ${MAILDELIVER_MTASTS}"
		ui_success "Доставляемость почты (имитация) настроена."
		return 0
	fi

	# --- 1) TLS-харденинг Postfix ---
	ui_step "TLS-харденинг Postfix (отключение устаревших протоколов)"
	local maincf=/etc/postfix/main.cf
	if [[ -f "$maincf" ]]; then
		# Единый бэкап (не плодим файлы при повторном --update).
		[[ -f "${maincf}.luckystack.bak" ]] || cp -a "$maincf" "${maincf}.luckystack.bak" 2>/dev/null || true
		postconf -e \
			'smtpd_tls_security_level = may' \
			'smtp_tls_security_level = may' \
			'smtpd_tls_protocols = >=TLSv1.2' \
			'smtp_tls_protocols = >=TLSv1.2' \
			'smtpd_tls_mandatory_protocols = >=TLSv1.2' \
			'smtp_tls_mandatory_protocols = >=TLSv1.2' \
			'tls_preempt_cipherlist = yes' \
			'smtpd_tls_loglevel = 1' \
			>>"$SETUP_LOG" 2>&1 \
			&& ui_success "Postfix: TLS усилен (только TLS 1.2+)." \
			|| ui_warn "Не удалось применить часть TLS-параметров Postfix — см. ${SETUP_LOG}."
		sys_run "Перезагрузка Postfix" systemctl reload postfix || \
			sys_run "Перезапуск Postfix" systemctl restart postfix
	else
		ui_warn "${maincf} не найден — TLS-харденинг Postfix пропущен."
	fi

	# --- 1.5) submission (587) + submissions (465) для почтовых клиентов ---
	# ISPConfig/Debian оставляют их закомментированными в master.cf → 587/465 не слушают,
	# клиенты не могут отправлять. Включаем (SASL/TLS наследуются из main.cf, что задал ISPConfig).
	_maildeliver_enable_submission

	# --- 1.6) логин к почте только поверх TLS (Postfix + Dovecot) ---
	_mail_auth_tls_only
	declare -F _ipv6_postfix_prefer_v4 >/dev/null && _ipv6_postfix_prefer_v4

	# --- 2) rDNS / PTR ---
	ui_step "Проверка обратной записи (rDNS/PTR)"
	if command -v dig >/dev/null 2>&1 && [[ -n "$main_ip" ]]; then
		# dig +short пишет ошибки (";; UDP setup … failed" при недоступном IPv6-резолвере) в stdout —
		# берём только строку-имя, а без ответа повторяем по IPv4.
		local ptr q
		for q in "" -4; do
			ptr="$(dig $q +short +time=3 +tries=1 -x "$main_ip" 2>/dev/null | grep -E '^[A-Za-z0-9_.-]+\.?$' | sed 's/\.$//' | head -1)"
			[[ -n "$ptr" ]] && break
		done
		if [[ -z "$ptr" ]]; then
			ui_warn "PTR для ${main_ip} не настроен. Попросите хостера выставить rDNS → ${fqdn} (иначе почта уходит в спам)."
		elif [[ "$ptr" == "$fqdn" ]]; then
			ui_success "rDNS/PTR: ${main_ip} → ${ptr} (совпадает с FQDN)."
		else
			ui_warn "rDNS/PTR: ${main_ip} → ${ptr}, а ожидается ${fqdn}. Попросите хостера исправить."
		fi
	else
		ui_info "dig недоступен или IP не определён — проверку rDNS пропускаю (нужен пакет bind9-dnsutils)."
	fi

	# --- 3) Наличие SPF/DMARC в DNS (информативно) ---
	if command -v dig >/dev/null 2>&1; then
		local spf dmarc
		spf="$(dig +short +time=3 +tries=1 TXT "$domain" 2>/dev/null | grep -i 'v=spf1' | head -1)"
		dmarc="$(dig +short +time=3 +tries=1 TXT "_dmarc.${domain}" 2>/dev/null | grep -i 'v=DMARC1' | head -1)"
		[[ -n "$spf" ]]   && ui_info "SPF уже опубликован: ${spf}"   || ui_warn "SPF для ${domain} не найден — добавьте (см. ${MAILDELIVER_RECORDS})."
		[[ -n "$dmarc" ]] && ui_info "DMARC уже опубликован: ${dmarc}" || ui_warn "DMARC для ${domain} не найден — добавьте (см. ${MAILDELIVER_RECORDS})."
	fi

	# --- 4) MTA-STS policy-файл ---
	local sts_id; sts_id="$(date +%Y%m%d%H%M%S)"
	cat >"$MAILDELIVER_MTASTS" <<EOF
version: STSv1
mode: testing
mx: ${fqdn}
max_age: 604800
EOF
	chmod 644 "$MAILDELIVER_MTASTS" 2>/dev/null || true

	# --- 5) Шпаргалка DNS-записей ---
	ui_step "Генерация рекомендованных DNS-записей: ${MAILDELIVER_RECORDS}"
	cat >"$MAILDELIVER_RECORDS" <<EOF
==============================================================================
 DNS-записи для доставляемости почты — домен: ${domain}
 Сгенерировано LuckyStack. Опубликуйте их у вашего DNS-провайдера.
==============================================================================

1) PTR / rDNS  (настраивается У ХОСТЕРА, не в зоне домена!)
   ${main_ip:-<ваш_IP>}  ->  ${fqdn}

2) A / MX  (если ещё нет)
   ${fqdn}.            IN A     ${main_ip:-<ваш_IP>}
   ${domain}.          IN MX 10 ${fqdn}.

3) SPF  (TXT на корне домена; ~all — мягко, -all — жёстко после проверки)
   ${domain}.          IN TXT   "v=spf1 a mx ip4:${main_ip:-<ваш_IP>} ~all"

4) DKIM
   Включается В ISPConfig: Email -> Domain -> вкладка DKIM -> «Generate DKIM».
   Панель покажет готовую TXT-запись (selector._domainkey) — добавьте её в зону.

5) DMARC  (TXT на _dmarc; начните с p=none для мониторинга, затем quarantine/reject)
   _dmarc.${domain}.   IN TXT   "v=DMARC1; p=quarantine; rua=mailto:postmaster@${domain}; ruf=mailto:postmaster@${domain}; fo=1; adkim=s; aspf=s"

6) MTA-STS  (TXT + policy по HTTPS — гарантирует TLS при приёме вашей почты)
   _mta-sts.${domain}.       IN TXT   "v=STSv1; id=${sts_id}"
   mta-sts.${domain}.        IN A     ${main_ip:-<ваш_IP>}
   Затем разместите файл политики (см. ${MAILDELIVER_MTASTS}) по адресу:
     https://mta-sts.${domain}/.well-known/mta-sts.txt
   (создайте сайт mta-sts.${domain} в ISPConfig с LE-сертификатом).
   Когда проверите — поменяйте в политике mode: testing -> enforce.

7) TLS-RPT  (TXT — отчёты о проблемах TLS при доставке вам)
   _smtp._tls.${domain}.     IN TXT   "v=TLSRPTv1; rua=mailto:tls-reports@${domain}"

------------------------------------------------------------------------------
Проверка после публикации:
  dig TXT ${domain} +short
  dig TXT _dmarc.${domain} +short
  dig TXT _mta-sts.${domain} +short
  Внешне: mxtoolbox.com, mail-tester.com, dmarcian.com
==============================================================================
EOF
	chmod 600 "$MAILDELIVER_RECORDS" 2>/dev/null || true

	ui_success "Готово. DNS-записи для публикации: ${UI_W}${MAILDELIVER_RECORDS}${UI_NC}"
	ui_info "MTA-STS policy-файл: ${UI_W}${MAILDELIVER_MTASTS}${UI_NC} (разместить по https://mta-sts.${domain}/.well-known/mta-sts.txt)"
	ui_info "DKIM включается в панели ISPConfig (Email → Domain → DKIM)."
	log "maildeliver: domain=${domain} fqdn=${fqdn} ip=${main_ip} records=${MAILDELIVER_RECORDS}"
	return 0
}

stage_maildeliver_summary() {
	echo "Mail deliverability: TLS-харденинг + ${MAILDELIVER_RECORDS}"
}
