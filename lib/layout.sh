#!/usr/bin/env bash
# =============================================================================
# layout.sh — где живёт LuckyStack на сервере.
#
#   /opt/luckystack/releases/<версия>-<время>   код, каждый выпуск отдельно
#   /opt/luckystack/current                     ссылка на рабочий выпуск
#   /etc/luckystack/setup.conf                  настройки и пароли (700/600)
#   /var/lib/luckystack/setup.state             отметки пройденных этапов
#   /var/log/luckystack/setup.log               журнал
#   /usr/local/sbin/luckyctl                    команда
# =============================================================================

: "${LS_OPT_DIR:=/opt/luckystack}"
: "${LS_ETC_DIR:=/etc/luckystack}"
: "${LS_VAR_DIR:=/var/lib/luckystack}"
: "${LS_LOG_DIR:=/var/log/luckystack}"
: "${LS_BIN:=/usr/local/sbin/luckyctl}"
LS_KEEP_RELEASES=3

# Что из каталога с кодом входит в выпуск. Настройки, состояние и журнал сюда не попадают.
LS_CODE_ITEMS=(server-setup.sh luckyctl lib assets lang DOCUMENTATION.md GETTING-STARTED.md README.md)

_ls_real() { readlink -f -- "$1" 2>/dev/null; }

# Команда luckyctl для подсказок в выводе по ключу server-setup.sh.
# ls_hint --only hostcert  ->  luckyctl install --only hostcert
ls_hint() {
	local f="${1:-}"; shift 2>/dev/null || true
	case "$f" in
		"")             echo "luckyctl" ;;
		--only|--from|--resume|--reconfigure|--unattended) echo "luckyctl install $f${*:+ $*}" ;;
		--healthcheck)  echo "luckyctl check" ;;
		--status)       echo "luckyctl status" ;;
		--diagnostics)  echo "luckyctl diagnostics" ;;
		--update)       echo "luckyctl update${*:+ $*}" ;;
		--rollback)     echo "luckyctl rollback${*:+ $*}" ;;
		--self-update)  echo "luckyctl self-update" ;;
		--check-update) echo "luckyctl version" ;;
		--restore)      echo "luckyctl restore" ;;
		*)              echo "luckyctl ${f#--}${*:+ $*}" ;;
	esac
}

# Запущен ли код из /opt/luckystack (напрямую или через ссылку).
ls_running_installed() {
	local me opt
	me="$(_ls_real "$SCRIPT_DIR")"; opt="$(_ls_real "$LS_OPT_DIR")"
	[[ -n "$me" && -n "$opt" && "$me/" == "$opt/"* ]]
}

ls_current_release() { _ls_real "$LS_OPT_DIR/current"; }

# Каталоги новой раскладки, только root.
ls_make_dirs() {
	install -d -m 755 -o root -g root "$LS_OPT_DIR" "$LS_OPT_DIR/releases" || return 1
	install -d -m 700 -o root -g root "$LS_ETC_DIR" "$LS_VAR_DIR" "$LS_LOG_DIR" || return 1
}

# ls_install_code SRC — скопировать код из SRC новым выпуском и переключить current.
# Печатает путь выпуска. Прежний выпуск остаётся для отката.
ls_install_code() {
	local src="$1" ts name rel tmp it
	[[ -f "$src/server-setup.sh" && -d "$src/lib" ]] || { ui_error "В ${src} нет server-setup.sh и lib/."; return 1; }
	bash -n "$src/server-setup.sh" 2>>"${SETUP_LOG:-/dev/null}" || { ui_error "server-setup.sh в ${src} не проходит проверку синтаксиса."; return 1; }
	ls_make_dirs || { ui_error "Не удалось создать каталоги ${LS_OPT_DIR}, ${LS_ETC_DIR}, ${LS_VAR_DIR}, ${LS_LOG_DIR}."; return 1; }
	ts="$(date +%Y%m%d-%H%M%S)"
	name="$(grep -m1 -oE 'VERSION="[^"]+"' "$src/server-setup.sh" | cut -d'"' -f2)"
	name="${name:-0}-${ts}"
	rel="$LS_OPT_DIR/releases/$name"; tmp="$rel.tmp"
	rm -rf -- "$tmp"; mkdir -m 755 -- "$tmp" || return 1
	for it in "${LS_CODE_ITEMS[@]}"; do
		[[ -e "$src/$it" ]] || continue
		cp -R -- "$src/$it" "$tmp/" || { ui_error "Не удалось скопировать ${it}."; rm -rf -- "$tmp"; return 1; }
	done
	# setup.* мог оказаться внутри lib/assets только по ошибке, но проверим: в выпуске секретов быть не должно
	# без «find | grep -q»: под pipefail ранний выход grep даёт 141, и находка бы потерялась
	[[ -n "$(find "$tmp" \( -name 'setup.conf*' -o -name 'setup.state*' -o -name 'setup.log*' \) -print -quit)" ]] \
		&& { ui_error "В коде нашлись setup.conf/state/log, выпуск не создан."; rm -rf -- "$tmp"; return 1; }
	chown -R root:root "$tmp"
	find "$tmp" -type d -exec chmod 755 {} +
	find "$tmp" -type f -exec chmod go-w,u+rw {} +
	chmod 755 "$tmp/server-setup.sh"; [[ -f "$tmp/luckyctl" ]] && chmod 755 "$tmp/luckyctl"
	mv -T -- "$tmp" "$rel" || { rm -rf -- "$tmp"; return 1; }
	ln -sfn "releases/$name" "$LS_OPT_DIR/current.new" && mv -Tf "$LS_OPT_DIR/current.new" "$LS_OPT_DIR/current" \
		|| { ui_error "Не удалось переключить ${LS_OPT_DIR}/current."; return 1; }
	log "Выпуск установлен: $rel"
	_ls_prune_releases
	echo "$rel"
}

# Оставить последние LS_KEEP_RELEASES выпусков, рабочий не трогать никогда.
_ls_prune_releases() {
	local cur d n=0
	cur="$(ls_current_release)"
	while IFS= read -r d; do
		[[ -n "$d" ]] || continue
		n=$((n + 1))
		((n <= LS_KEEP_RELEASES)) && continue
		[[ "$(_ls_real "$d")" == "$cur" ]] && continue
		[[ "$d" == "$LS_OPT_DIR/releases/"* ]] && rm -rf -- "$d" && log "Старый выпуск удалён: $d"
	done < <(find "$LS_OPT_DIR/releases" -mindepth 1 -maxdepth 1 -type d ! -name '*.tmp' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
}

# Команда luckyctl и автодополнение. Ссылки на current, поэтому после обновления ничего менять не надо.
ls_install_cli() {
	local comp
	ln -sfn "$LS_OPT_DIR/current/luckyctl" "$LS_BIN" 2>/dev/null || return 1
	if [[ -d /usr/share/bash-completion/completions ]]; then comp=/usr/share/bash-completion/completions/luckyctl
	else comp=/etc/bash_completion.d/luckyctl; mkdir -p /etc/bash_completion.d; fi
	ln -sfn "$LS_OPT_DIR/current/assets/luckyctl/completion.bash" "$comp" 2>/dev/null || true
	return 0
}

# Каталог кода для внешних потребителей (панель обслуживания): всегда current, чтобы после
# обновления LuckyStack панель сразу звала новый выпуск.
ls_code_dir() { echo "$LS_OPT_DIR/current"; }

# Панель обслуживания знает, где код, настройки и журнал. Обновляем, если панель стоит.
ls_update_maint_conf() {
	local f=/usr/local/ispconfig/server/scripts/ss-maint.conf
	[[ -d /usr/local/ispconfig/server/scripts ]] || return 0
	[[ -f "$f" ]] || [[ "${1:-}" == create ]] || return 0
	( umask 077
	  printf "INSTALLER_DIR='%s'\nSETUP_CONF='%s'\nSETUP_LOG='%s'\n" "$(ls_code_dir)" "$CONFIG_FILE" "$SETUP_LOG" >"$f.tmp" ) \
		&& chown root:root "$f.tmp" && mv -f "$f.tmp" "$f"
}

# Поставить скрипт панели обслуживания из текущего кода (он знает про SETUP_CONF и SETUP_LOG).
_ls_refresh_maint_sync() {
	local src="${ASSETS_DIR:-$SCRIPT_DIR/assets}/ispconfig/maint-panel/ss-maint-sync.php"
	local dst=/usr/local/ispconfig/server/scripts/ss-maint-sync.php
	[[ -f "$dst" && -f "$src" ]] || return 0
	cmp -s "$src" "$dst" && return 0
	if ! php -l "$src" >/dev/null 2>&1; then ui_warn "Новый скрипт панели обслуживания не прошёл php -l, оставляю прежний."; return 1; fi
	install -o root -g root -m 750 "$src" "$dst.new" && mv -f "$dst.new" "$dst" && log "ss-maint-sync.php обновлён из $src"
}

# Старт не из /opt/luckystack. Возврат: 0 продолжать, иначе код выхода.
ls_guard_code_location() {
	ls_running_installed && return 0
	[[ "${LS_ALLOW_FOREIGN:-0}" == 1 || "${DRY_RUN:-0}" == 1 ]] && return 0
	[[ $EUID -eq 0 ]] || return 0
	local rel
	if ((DO_INSTALL_CODE)); then
		rel="$(ls_install_code "$SCRIPT_DIR")" || return 1
		ls_install_cli
		_ls_refresh_maint_sync
		ls_update_maint_conf
		ui_success "Код LuckyStack обновлён: ${rel}"
		ui_info "Дальше работайте командой ${UI_BOLD}luckyctl${UI_NC}. Вернуть прошлый выпуск: luckyctl rollback luckystack"
		return 100
	fi
	if [[ ! -e "$LS_OPT_DIR/current" ]]; then
		# Кода в /opt ещё нет. Режимы вроде --status работают прямо отсюда, а установку
		# ставим на место и продолжаем уже оттуда.
		(( ${_modes:-0} == 0 )) || return 0
		ui_step "Установка кода LuckyStack в ${LS_OPT_DIR}"
		rel="$(ls_install_code "$SCRIPT_DIR")" || return 1
		ls_install_cli
		ui_success "Код установлен: ${rel}. Команда luckyctl готова."
		export LS_REEXEC=1
		exec "$LS_OPT_DIR/current/server-setup.sh" "${LS_ORIG_ARGS[@]}"
	fi
	ui_error "LuckyStack уже установлен в ${LS_OPT_DIR}/current, а запущена копия из ${SCRIPT_DIR}."
	ui_info "Работайте командой ${UI_BOLD}luckyctl${UI_NC}. Поставить эту копию как новый выпуск: ${UI_BOLD}${SCRIPT_DIR}/server-setup.sh --install-code${UI_NC}"
	return 1
}

# Откат самого LuckyStack на предыдущий выпуск. Повтор возвращает обратно.
ls_rollback_code() {
	[[ -L "$LS_OPT_DIR/current" ]] || { ui_error "LuckyStack ещё не установлен в ${LS_OPT_DIR}: откатывать нечего."; return 1; }
	local cur prev d
	cur="$(ls_current_release)"
	while IFS= read -r d; do
		[[ "$(_ls_real "$d")" == "$cur" ]] && continue
		prev="$d"; break
	done < <(find "$LS_OPT_DIR/releases" -mindepth 1 -maxdepth 1 -type d ! -name '*.tmp' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
	[[ -n "${prev:-}" && -f "$prev/server-setup.sh" ]] || { ui_error "Прошлого выпуска нет."; return 1; }
	bash -n "$prev/server-setup.sh" || { ui_error "Прошлый выпуск повреждён, откат отменён."; return 1; }
	ui_step "Откат LuckyStack: $(basename "$cur") → $(basename "$prev")"
	ln -sfn "releases/$(basename "$prev")" "$LS_OPT_DIR/current.new" && mv -Tf "$LS_OPT_DIR/current.new" "$LS_OPT_DIR/current" || return 1
	# чтобы повтор вернул обратно, делаем текущий выпуск «свежим» по времени
	touch "$prev"
	ui_success "Работает выпуск $(basename "$prev"). Прошлый теперь $(basename "$cur"), повтор команды вернёт его."
}
