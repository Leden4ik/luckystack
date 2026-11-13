#!/bin/bash
# =============================================================================
# lib/webserver.sh — Диспетчер развилки веб-сервера.
# Делегирует stage_nginx() (lib/nginx.sh) или stage_apache() (lib/apache.sh).
# =============================================================================

stage_webserver() {
	local ws="${WEBSERVER:-nginx}"
	ui_info "Веб-сервер: ${UI_BOLD}${ws}${UI_NC}"
	case "$ws" in
		nginx)
			if declare -F stage_nginx >/dev/null; then stage_nginx; else
				ui_error "lib/nginx.sh не подключён."; return 1; fi ;;
		apache)
			if declare -F stage_apache >/dev/null; then stage_apache; else
				ui_error "lib/apache.sh не подключён."; return 1; fi ;;
		*) ui_error "Неизвестный веб-сервер: ${ws}"; return 1 ;;
	esac
}

stage_webserver_summary() { echo "Веб-сервер: ${WEBSERVER:-nginx}"; }

# =============================================================================
# Абстракция веб-сервера — общие операции, чтобы фичи (hostcert, dbtools, …) не
# дублировали `nginx -t`/`apache2ctl` и reload и не плодили `if WEBSERVER==nginx`.
# Каждая webserver-специфичная фича = диспетчер `_feature` + реализации
# `_feature_nginx` / `_feature_apache` (паттерн как у _dbadmin_restrict).
# =============================================================================

# Проверка конфигурации активного веб-сервера. return 0 = конфиг валиден.
web_configtest() {
	case "${WEBSERVER:-nginx}" in
		nginx)  nginx -t >>"$SETUP_LOG" 2>&1 ;;
		apache) { command -v apache2ctl >/dev/null 2>&1 && apache2ctl configtest; } >>"$SETUP_LOG" 2>&1 ;;
		*) return 1 ;;
	esac
}

# Graceful-перезагрузка активного веб-сервера (ошибку гасим — вызывающий решает сам).
web_reload() {
	case "${WEBSERVER:-nginx}" in
		nginx)  systemctl reload nginx    >>"$SETUP_LOG" 2>&1 || true ;;
		apache) systemctl reload apache2  >>"$SETUP_LOG" 2>&1 || true ;;
	esac
}

# Имя службы активного веб-сервера (для systemctl/мониторинга).
web_service() { case "${WEBSERVER:-nginx}" in apache) echo apache2 ;; *) echo nginx ;; esac; }
