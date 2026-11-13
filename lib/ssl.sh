#!/bin/bash
# =============================================================================
# lib/ssl.sh — Этап: ACME-клиент для Let's Encrypt.
# Ставит acme.sh (предпочтительно для ISPConfig 3.2) ИЛИ certbot. ISPConfig
# использует установленный клиент для выпуска/продления сертификатов доменов
# через панель. Провайдер — SSL_PROVIDER (acme|certbot|none), по умолчанию acme.
# =============================================================================

stage_ssl() {
	local provider="${SSL_PROVIDER:-acme}"
	local email="${ISPCONFIG_ADMIN_EMAIL:-admin@${SERVER_FQDN:-localhost}}"
	ui_info "ACME-клиент Let's Encrypt: ${UI_BOLD}${provider}${UI_NC}"

	case "$provider" in
		none) ui_info "SSL отключён (SSL_PROVIDER=none) — пропуск."; return 0 ;;
	esac

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		if [[ "$provider" == "certbot" ]]; then
			ui_info "${UI_D}[dry-run]${UI_NC} apt install certbot"
		else
			ui_info "${UI_D}[dry-run]${UI_NC} curl https://get.acme.sh | sh (email=${email})"
		fi
		ui_info "${UI_D}[dry-run]${UI_NC} ISPConfig выпускает сертификаты доменов через клиент"
		ui_success "ACME-клиент (имитация) установлен."
		return 0
	fi

	if [[ "$provider" == "certbot" ]]; then
		ui_step "Установка certbot"
		apt_install certbot
		ui_success "certbot установлен."
	else
		ui_step "Установка acme.sh"
		apt_install curl socat
		if [[ -f /root/.acme.sh/acme.sh ]]; then
			ui_info "acme.sh уже установлен."
			# Каталог мог остаться от удаления без --purge: acme.sh --uninstall снимает задание
			# продления, и сертификаты перестали бы обновляться. Возвращаем его.
			if ! crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
				/root/.acme.sh/acme.sh --install-cronjob >>"$SETUP_LOG" 2>&1 \
					&& ui_info "Задание продления acme.sh восстановлено в cron." \
					|| ui_warn "Не удалось вернуть задание продления acme.sh: /root/.acme.sh/acme.sh --install-cronjob"
			fi
		elif ui_spin "Установка acme.sh (get.acme.sh)" bash -c \
			"curl -fsS https://get.acme.sh | sh -s email=${email}"; then
			ui_success "acme.sh установлен в /root/.acme.sh (auto-renew через cron)."
		else
			ui_error "Не удалось установить acme.sh."
			return 1
		fi
	fi
	log "ssl: ACME-клиент ${provider} готов для ISPConfig"
	return 0
}

stage_ssl_summary() { echo "SSL: ${SSL_PROVIDER:-acme} (Let's Encrypt через ISPConfig)"; }
