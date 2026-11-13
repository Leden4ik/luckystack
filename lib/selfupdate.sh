#!/usr/bin/env bash
# =============================================================================
# selfupdate.sh — версии и обновление самого LuckyStack.
#   --check-update  какая версия стоит и есть ли новая (без изменений)
#   --self-update   поставить последний выпуск с GitHub новым выпуском в /opt/luckystack;
#                   прошлый остаётся для luckyctl rollback luckystack
#
# Выпуски — релизы на GitHub с тегом vX.Y.Z. Ветка main сюда не попадает, пока не выпущена.
#   SELF_UPDATE_REPO  owner/repo
#   SELF_UPDATE_REF   поставить конкретный тег или ветку (v0.1.1, main) вместо последнего релиза
#   SELF_UPDATE_API   адрес API (по умолчанию https://api.github.com), нужен для проверок
#   GITHUB_TOKEN      токен, если репозиторий приватный (свой форк)
# Настройки, состояние и журнал лежат в /etc и /var и обновлением не трогаются.
# =============================================================================

: "${SELF_UPDATE_REPO:=Leden4ik/luckystack}"
: "${SELF_UPDATE_API:=https://api.github.com}"

# версия из произвольного server-setup.sh (VERSION="...")
_su_version_of() { grep -m1 -oE 'VERSION="[^"]+"' "$1" 2>/dev/null | cut -d'"' -f2; }

_su_repo_set() { [[ -n "$SELF_UPDATE_REPO" && "$SELF_UPDATE_REPO" != "OWNER/REPO" ]]; }

# запрос к API GitHub: _su_api <путь> [curl-ключи...]
_su_api() {
	local path="$1"; shift
	local auth=(); [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
	curl -fsSL --max-time 30 -H "Accept: application/vnd.github+json" "${auth[@]}" "$@" \
		"${SELF_UPDATE_API%/}/repos/${SELF_UPDATE_REPO}/${path}"
}

# последний релиз: в _SU_TAG тег, в _SU_NOTES описание изменений
_su_latest() {
	local json
	_SU_TAG=""; _SU_NOTES=""
	json="$(_su_api releases/latest 2>/dev/null)" || return 1
	_SU_TAG="$(grep -m1 -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$json" | sed -E 's/.*"([^"]+)"$/\1/')"
	# описание — одна строка JSON с \n внутри; для показа хватит простого разбора
	_SU_NOTES="$(grep -m1 -oE '"body"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' <<<"$json" \
		| sed -E 's/^"body"[[:space:]]*:[[:space:]]*"//; s/"$//' | sed -e 's/\\r//g' -e 's/\\n/\n/g' -e 's/\\"/"/g')"
	[[ -n "$_SU_TAG" ]]
}

# 0, если версия $2 новее $1 (0.1.10 > 0.1.9)
_su_newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$2" ]]; }

# что стоит сейчас: версия, путь выпуска и откуда он взят
_su_show_installed() {
	local rel="" origin="" when=""
	declare -F ls_current_release >/dev/null && rel="$(ls_current_release)"
	if [[ -n "$rel" && -f "$rel/.release" ]]; then
		origin="$(. "$rel/.release" 2>/dev/null; printf '%s' "${ORIGIN:-}")"
		when="$(. "$rel/.release" 2>/dev/null; printf '%s' "${INSTALLED:-}")"
	fi
	ui_info "Установлена: LuckyStack ${VERSION:-?}${rel:+ (${rel})}"
	[[ -n "$origin" ]] && ui_info "Откуда: ${origin}${when:+, поставлен ${when}}"
	return 0
}

# --- только проверка версии ---
run_check_update() {
	_su_show_installed
	command -v curl >/dev/null 2>&1 || { ui_error "Для проверки обновлений нужен curl."; return 1; }
	_su_repo_set || { ui_warn "Репозиторий обновлений не задан (SELF_UPDATE_REPO)."; return 1; }
	if ! _su_latest; then
		ui_warn "Не удалось узнать последний выпуск в ${SELF_UPDATE_REPO} (сеть, или выпусков ещё нет)."
		return 1
	fi
	local rv="${_SU_TAG#v}"
	if _su_newer "${VERSION:-0}" "$rv"; then
		ui_warn "Есть новая версия: ${rv}. Обновить: $(ls_hint --self-update)"
		if [[ -n "$_SU_NOTES" ]]; then
			ui_info "Что в ней:"
			sed 's/^/    /' <<<"$_SU_NOTES" | head -30
		fi
	else
		ui_success "Последний выпуск ${rv}, у вас установлена последняя версия."
	fi
	return 0
}

# --- обновление: скачанное становится новым выпуском, рабочий не трогаем ---
run_self_update() {
	require_root
	_su_repo_set || { ui_error "Репозиторий обновлений не задан (SELF_UPDATE_REPO)."; return 1; }
	ls_running_installed || { ui_error "Обновлять можно установленный LuckyStack (${LS_OPT_DIR}/current). Команда: luckyctl self-update"; return 1; }
	command -v curl >/dev/null 2>&1 || { ui_error "Нужен curl для обновления."; return 1; }
	command -v tar  >/dev/null 2>&1 || { ui_error "Нужен tar для распаковки обновления."; return 1; }

	local ref="${SELF_UPDATE_REF:-}" rv=""
	if [[ -z "$ref" ]]; then
		_su_latest || { ui_error "Не удалось узнать последний выпуск в ${SELF_UPDATE_REPO} (сеть, или выпусков ещё нет)."; return 1; }
		ref="$_SU_TAG"; rv="${ref#v}"
		if ! _su_newer "${VERSION:-0}" "$rv" && [[ "${FORCE:-0}" != "1" ]]; then
			ui_success "У вас уже последняя версия (${VERSION}). Поставить её заново: luckyctl self-update --force"
			return 0
		fi
	elif [[ "$ref" =~ ^v[0-9]+(\.[0-9]+)+$ ]]; then
		rv="${ref#v}"   # явный тег: версия внутри архива обязана с ним совпасть
	fi
	ui_header "Обновление LuckyStack: ${VERSION:-?} → ${rv:-$ref}"
	[[ -n "${_SU_NOTES:-}" ]] && { ui_info "Что нового:"; sed 's/^/    /' <<<"$_SU_NOTES" | head -30; }

	local tmp; tmp="$(mktemp -d)"
	ui_step "Загрузка ${SELF_UPDATE_REPO}@${ref}"
	if ! _su_api "tarball/${ref}" --max-time 180 -o "$tmp/src.tgz"; then
		ui_error "Не удалось скачать ${ref} (сеть, неверный тег или нет доступа к репозиторию)."; rm -rf "$tmp"; return 1
	fi
	mkdir "$tmp/x"
	if ! tar xzf "$tmp/src.tgz" -C "$tmp/x" --no-same-owner --no-same-permissions 2>>"${SETUP_LOG:-/dev/null}"; then
		ui_error "Архив не распаковался."; rm -rf "$tmp"; return 1
	fi
	# каталог вида owner-repo-<коммит>/
	local root; root="$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
	if [[ ! -f "$root/server-setup.sh" ]]; then
		ui_error "В архиве нет server-setup.sh."; rm -rf "$tmp"; return 1
	fi
	local got commit; got="$(_su_version_of "$root/server-setup.sh")"; commit="${root##*-}"
	if [[ -n "$rv" && "$got" != "$rv" ]]; then
		ui_error "В выпуске ${ref} внутри версия ${got:-?}, а не ${rv}. Обновление остановлено."; rm -rf "$tmp"; return 1
	fi

	# ls_install_code сам проверяет синтаксис и не трогает рабочий выпуск, пока новый не готов
	local rel
	rel="$(ls_install_code "$root" "GitHub ${SELF_UPDATE_REPO} ${ref} (коммит ${commit:0:7})")" || { rm -rf "$tmp"; return 1; }
	rm -rf "$tmp"
	ls_install_cli
	_ls_refresh_maint_sync
	ls_update_maint_conf
	ui_success "LuckyStack обновлён до версии ${got}: ${rel}"
	ui_info "Вернуть прошлый выпуск: luckyctl rollback luckystack"
	ui_info "Настройки сервера этим не меняются. Применить то, что изменилось в новой версии: luckyctl update"
	return 0
}
