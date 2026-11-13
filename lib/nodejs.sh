#!/bin/bash
# =============================================================================
# lib/nodejs.sh — Этап (опц.): Node.js из официального репозитория NodeSource.
# Версия выбирается в мастере (NODEJS_VERSION: 20/22/24). Ставит node + npm.
# =============================================================================

stage_nodejs() {
	local ver="${NODEJS_VERSION:-22}"
	ui_info "Node.js ${UI_BOLD}${ver}.x${UI_NC} (NodeSource)"

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} curl nodesource setup_${ver}.x | bash ; apt install nodejs"
		ui_info "${UI_D}[dry-run]${UI_NC} проверка node -v / npm -v"
		ui_success "Node.js (имитация) установлен."
		return 0
	fi

	# Репозиторий NodeSource
	ui_step "Подключение репозитория NodeSource (${ver}.x)"
	apt_install ca-certificates curl gnupg
	if ! ui_spin "Настройка NodeSource ${ver}.x" bash -c \
		"curl -fsSL https://deb.nodesource.com/setup_${ver}.x | bash -"; then
		ui_error "Не удалось подключить репозиторий NodeSource."
		return 1
	fi

	ui_step "Установка Node.js ${ver}.x"
	apt_install nodejs

	# Проверка
	if command -v node >/dev/null 2>&1; then
		ui_success "Node.js: $(node -v 2>/dev/null) · npm: $(npm -v 2>/dev/null)"
	else
		ui_warn "node не найден после установки — проверьте $SETUP_LOG"
	fi
	return 0
}

stage_nodejs_summary() { echo "Node.js: ${NODEJS_VERSION:-—}.x (NodeSource)"; }
