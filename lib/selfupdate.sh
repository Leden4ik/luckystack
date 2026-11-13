#!/usr/bin/env bash
# =============================================================================
# selfupdate.sh — обновление самого LuckyStack.
#   --check-update  сверить локальную версию с репозиторием (без изменений)
#   --self-update   скачать свежий код и поставить его новым выпуском в /opt/luckystack;
#                   прошлый выпуск остаётся для luckyctl rollback luckystack
#
# Репозиторий: SELF_UPDATE_REPO (owner/repo), ветка SELF_UPDATE_BRANCH, подкаталог
# SELF_UPDATE_SUBDIR, если код лежит не в корне репозитория. Настройки, состояние и журнал
# лежат в /etc и /var и обновлением не трогаются.
# =============================================================================

: "${SELF_UPDATE_REPO:=Leden4ik/luckystack}"
: "${SELF_UPDATE_BRANCH:=main}"
: "${SELF_UPDATE_SUBDIR:=}"

# версия из произвольного server-setup.sh (VERSION="...")
_su_version_of() { grep -m1 -oE 'VERSION="[^"]+"' "$1" 2>/dev/null | cut -d'"' -f2; }

# версия server-setup.sh в репозитории (raw)
_su_remote_version() {
	local sub=""; [[ -n "$SELF_UPDATE_SUBDIR" ]] && sub="${SELF_UPDATE_SUBDIR%/}/"
	local url="https://raw.githubusercontent.com/${SELF_UPDATE_REPO}/${SELF_UPDATE_BRANCH}/${sub}server-setup.sh"
	curl -fsSL --max-time 20 "$url" 2>/dev/null | grep -m1 -oE 'VERSION="[^"]+"' | cut -d'"' -f2
}

_su_repo_set() { [[ -n "$SELF_UPDATE_REPO" && "$SELF_UPDATE_REPO" != "OWNER/REPO" ]]; }

# --- только проверка версии ---
run_check_update() {
	command -v curl >/dev/null 2>&1 || { ui_error "Для проверки обновлений нужен curl."; return 1; }
	_su_repo_set || { ui_warn "Репозиторий обновлений не настроен (SELF_UPDATE_REPO в lib/selfupdate.sh)."; return 1; }
	ui_step "Проверка обновлений LuckyStack (${SELF_UPDATE_REPO}@${SELF_UPDATE_BRANCH})"
	local rv; rv="$(_su_remote_version)"
	[[ -n "$rv" ]] || { ui_warn "Не удалось получить версию из репозитория (сеть?)."; return 1; }
	ui_info "Установлена: ${VERSION:-?} · в репозитории: ${rv}"
	if [[ "$rv" == "${VERSION:-}" ]]; then
		ui_success "Установлена последняя версия."
	else
		ui_warn "Доступна другая версия: ${rv}. Обновить: $(ls_hint --self-update)"
	fi
	return 0
}

# --- обновление: скачанное становится новым выпуском, рабочий не трогаем ---
run_self_update() {
	require_root
	_su_repo_set || { ui_error "Репозиторий обновлений не настроен (SELF_UPDATE_REPO в lib/selfupdate.sh)."; return 1; }
	ls_running_installed || { ui_error "Обновлять можно установленный LuckyStack (${LS_OPT_DIR}/current). Команда: luckyctl self-update"; return 1; }
	command -v curl >/dev/null 2>&1 || { ui_error "Нужен curl для обновления."; return 1; }
	command -v tar  >/dev/null 2>&1 || { ui_error "Нужен tar для распаковки обновления."; return 1; }
	ui_header "Обновление LuckyStack (${SELF_UPDATE_REPO}@${SELF_UPDATE_BRANCH})"

	local tmp; tmp="$(mktemp -d)"
	local url="https://github.com/${SELF_UPDATE_REPO}/archive/refs/heads/${SELF_UPDATE_BRANCH}.tar.gz"
	ui_step "Загрузка ${url}"
	if ! curl -fsSL --max-time 120 "$url" -o "$tmp/src.tgz"; then
		ui_error "Не удалось скачать архив (сеть или неверная ветка)."; rm -rf "$tmp"; return 1
	fi
	mkdir "$tmp/x"
	if ! tar xzf "$tmp/src.tgz" -C "$tmp/x" --no-same-owner --no-same-permissions 2>>"${SETUP_LOG:-/dev/null}"; then
		ui_error "Архив не распаковался."; rm -rf "$tmp"; return 1
	fi
	# каталог вида <repo>-<branch>/ (+ подкаталог, если код не в корне)
	local root; root="$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
	[[ -n "$SELF_UPDATE_SUBDIR" ]] && root="$root/${SELF_UPDATE_SUBDIR%/}"
	if [[ ! -f "$root/server-setup.sh" ]]; then
		ui_error "В архиве нет server-setup.sh (проверьте SELF_UPDATE_SUBDIR)."; rm -rf "$tmp"; return 1
	fi

	# ls_install_code сам проверяет синтаксис и не трогает рабочий выпуск, пока новый не готов
	local rel
	rel="$(ls_install_code "$root")" || { rm -rf "$tmp"; return 1; }
	rm -rf "$tmp"
	ls_install_cli
	_ls_refresh_maint_sync
	ls_update_maint_conf
	ui_success "LuckyStack обновлён до версии $(_su_version_of "$rel/server-setup.sh"): ${rel}"
	ui_info "Вернуть прошлый выпуск: luckyctl rollback luckystack"
	return 0
}
