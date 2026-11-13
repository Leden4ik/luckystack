#!/bin/bash
# =============================================================================
# lib/mailsni.sh — Этап (опц.): per-domain TLS для почты (SNI).
#
#   По умолчанию Dovecot/Postfix отдают ОДИН сертификат (на hostname сервера),
#   и клиент, подключаясь к mail.<свой-домен>, видит предупреждение о
#   несовпадении. Этот этап раздаёт КАЖДОМУ домену его собственный
#   Let's Encrypt-сертификат через SNI:
#     • Dovecot: блоки local_name { ssl_cert/ssl_key } в /etc/dovecot/sni.conf
#     • Postfix: tls_server_sni_maps (hash-карта домен → ключ/сертификат)
#   Источник сертификатов — /etc/letsencrypt/live/<домен>/. Скрипт-генератор
#   ставится в /usr/local/sbin и обновляется по systemd-таймеру (подхватывает
#   новые сайты и продления). Это лёгкая альтернатива сторонним панелям.
# =============================================================================

MAILSNI_SCRIPT=/usr/local/sbin/ispconfig-mail-sni.sh
DOVECOT_SNI=/etc/dovecot/sni.conf
DOVECOT_CONF=/etc/dovecot/dovecot.conf
PF_SNI_MAP=/etc/postfix/sni/vmail_ssl.map

stage_mailsni() {
	if ! command -v dovecot >/dev/null 2>&1 && ! command -v postfix >/dev/null 2>&1; then
		ui_info "Почта не установлена — этап per-domain TLS (SNI) пропущен."
		return 0
	fi

	ui_info "Per-domain TLS почты (SNI): источник — /etc/letsencrypt/live, обновление по таймеру."

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} ${MAILSNI_SCRIPT} + Dovecot sni.conf + Postfix tls_server_sni_maps"
		ui_info "${UI_D}[dry-run]${UI_NC} systemd-таймер ispconfig-mail-sni.timer (ежедневно)"
		ui_success "Per-domain TLS почты (имитация) настроен."
		return 0
	fi

	# --- 1) Генератор ---
	ui_step "Установка генератора SNI: ${MAILSNI_SCRIPT}"
	_mailsni_write_script || { ui_error "Не удалось записать ${MAILSNI_SCRIPT}."; return 1; }
	chmod 700 "$MAILSNI_SCRIPT" 2>/dev/null || true

	# --- 2) Заготовки, чтобы include/карта были валидны даже при 0 сертификатов ---
	mkdir -p /etc/postfix/sni 2>/dev/null || true
	touch "$DOVECOT_SNI" 2>/dev/null || true

	# --- 3) Подключить sni.conf в Dovecot (однократно) ---
	if command -v dovecot >/dev/null 2>&1 && [[ -f "$DOVECOT_CONF" ]]; then
		if ! grep -qF "!include $DOVECOT_SNI" "$DOVECOT_CONF" 2>/dev/null; then
			printf '\n# luckystack: per-domain TLS (SNI)\n!include %s\n' "$DOVECOT_SNI" >>"$DOVECOT_CONF"
			ui_success "В dovecot.conf добавлен !include sni.conf"
		else
			ui_info "dovecot.conf уже содержит !include sni.conf"
		fi
	fi

	# --- 4) Первый прогон генератора (создаст карту/конфиг и перезагрузит службы) ---
	ui_spin "Генерация SNI-конфигов из сертификатов Let's Encrypt" "$MAILSNI_SCRIPT" || \
		ui_warn "Генератор SNI завершился с замечаниями — см. ${SETUP_LOG}."

	# --- 5) Включить SNI-карту в Postfix ---
	if command -v postfix >/dev/null 2>&1; then
		postconf -e "tls_server_sni_maps = hash:${PF_SNI_MAP}" >>"$SETUP_LOG" 2>&1 && \
			sys_run "Перезагрузка Postfix (SNI)" systemctl reload postfix || \
			ui_warn "Не удалось включить tls_server_sni_maps в Postfix."
	fi

	# --- 6) systemd-таймер: ежедневно подхватывать новые сайты/продления ---
	ui_step "Создание таймера обновления SNI (ежедневно)"
	cat >/etc/systemd/system/ispconfig-mail-sni.service <<EOF
[Unit]
Description=Refresh per-domain mail TLS (SNI) from Let's Encrypt certs
After=dovecot.service postfix.service

[Service]
Type=oneshot
ExecStart=${MAILSNI_SCRIPT}
EOF
	cat >/etc/systemd/system/ispconfig-mail-sni.timer <<'EOF'
[Unit]
Description=Daily refresh of per-domain mail TLS (SNI)

[Timer]
OnCalendar=*-*-* 04:10:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
	systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
	sys_run "Включение таймера SNI" systemctl enable --now ispconfig-mail-sni.timer || \
		ui_warn "Не удалось включить ispconfig-mail-sni.timer."

	local n; n="$(grep -c '^local_name' "$DOVECOT_SNI" 2>/dev/null)"; n="${n:-0}"
	ui_success "Per-domain TLS почты настроен. Доменов с собственным сертификатом: ${n}."
	ui_info "Обновить вручную: ${UI_W}${MAILSNI_SCRIPT}${UI_NC} (запускается также при выпуске новых LE-сертификатов по таймеру)."
	[[ "$n" == "0" ]] && ui_info "Сертификатов в /etc/letsencrypt/live пока нет — SNI заполнится после выпуска LE для почтовых доменов."
	log "mailsni: domains=${n}"
	return 0
}

# Runtime-генератор. Кавычки в heredoc ('SNI') — переменные раскрываются на сервере.
_mailsni_write_script() {
	cat >"$MAILSNI_SCRIPT" <<'SNI'
#!/bin/bash
# ispconfig-mail-sni.sh — генерирует per-domain TLS (SNI) для Dovecot и Postfix
# из сертификатов Let's Encrypt. Автогенерация LuckyStack.
set -uo pipefail

DOVECOT_SNI=/etc/dovecot/sni.conf
PF_DIR=/etc/postfix/sni
PF_MAP="$PF_DIR/vmail_ssl.map"
LE=/etc/letsencrypt/live
mkdir -p "$PF_DIR"

# Dovecot >=2.4 (Debian 13): ssl_cert/ssl_key с '<' не работают → ssl_server_*_file
DV24=0
case "$(dovecot --version 2>/dev/null | awk '{print $1}')" in 2.[4-9]*|[3-9].*) DV24=1 ;; esac

dsni="${DOVECOT_SNI}.tmp.$$"
pmap="${PF_MAP}.tmp.$$"
: >"$dsni"; : >"$pmap"
count=0

if [[ -d "$LE" ]]; then
	for d in "$LE"/*/; do
		dom="$(basename "$d")"
		[[ "$dom" == "README" ]] && continue
		cert="${d%/}/fullchain.pem"; key="${d%/}/privkey.pem"
		[[ -f "$cert" && -f "$key" ]] || continue
		{
			echo "local_name ${dom} {"
			if (( DV24 )); then
				echo "  ssl_server_cert_file = ${cert}"
				echo "  ssl_server_key_file = ${key}"
			else
				echo "  ssl_cert = <${cert}"
				echo "  ssl_key = <${key}"
			fi
			echo "}"
		} >>"$dsni"
		printf '%s %s %s\n' "$dom" "$key" "$cert" >>"$pmap"
		count=$((count + 1))
	done
fi

[[ -f "$DOVECOT_SNI" ]] && cp -a "$DOVECOT_SNI" "${DOVECOT_SNI}.prev"
mv "$dsni" "$DOVECOT_SNI"
mv "$pmap" "$PF_MAP"
chmod 600 "$DOVECOT_SNI" "$PF_MAP" 2>/dev/null || true
# гейт: новый sni.conf обязан проходить doveconf -n, иначе откат (работающий Dovecot не ломаем)
if command -v doveconf >/dev/null 2>&1 && ! doveconf -n >/dev/null 2>&1; then
	if [[ -f "${DOVECOT_SNI}.prev" ]]; then mv -f "${DOVECOT_SNI}.prev" "$DOVECOT_SNI"; else : >"$DOVECOT_SNI"; fi
	logger -t ispconfig-mail-sni "sni.conf не прошёл doveconf -n (DV24=${DV24}) — откат" 2>/dev/null || true
fi
rm -f "${DOVECOT_SNI}.prev"

# Postfix: hash-карта (-F: значения — пути к файлам ключ/сертификат)
command -v postmap >/dev/null 2>&1 && postmap -F "hash:$PF_MAP" 2>/dev/null || true

# Перезагрузка служб (молча, если их нет)
systemctl reload dovecot 2>/dev/null || systemctl restart dovecot 2>/dev/null || true
systemctl reload postfix 2>/dev/null || systemctl restart postfix 2>/dev/null || true

echo "mail-sni: обработано доменов: ${count}"
SNI
}

stage_mailsni_summary() {
	echo "Mail SNI: per-domain TLS (Dovecot/Postfix) из Let's Encrypt"
}
