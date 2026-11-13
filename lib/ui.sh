#!/bin/bash
# =============================================================================
# lib/ui.sh — Визуальный слой (стилизованный текст-мастер)
# Рамки, нумерованные меню, текстовые чекбоксы, спиннер, gauge, overview.
# Без whiptail/ncurses — только ANSI + tput.
#
# i18n: все текстовые аргументы ui_* прогоняются через t() (модель gettext: ключ =
# русская строка-оригинал; перевод из lang/<код>.lng, иначе — оригинал). Поэтому
# перевод CLI = добавление строк в lang/en.lng, БЕЗ правок вызовов ui_*. Здесь
# определён фолбэк t() (эхо-как-есть) на случай, если i18n.sh не подключён; при
# наличии i18n.sh его t() переопределит этот (сорсится позже) — на момент ВЫЗОВА
# работает настоящий. Динамические строки (с ${var} внутри) в ключ не попадут и
# останутся русскими — это ок; переводим статические.
# =============================================================================
command -v t >/dev/null 2>&1 || t() { printf '%s' "$1"; }

# --- Палитра -----------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
	UI_R='\033[0;31m'   # red
	UI_G='\033[0;32m'   # green
	UI_Y='\033[1;33m'   # yellow
	UI_B='\033[0;34m'   # blue
	UI_C='\033[0;36m'   # cyan
	UI_M='\033[0;35m'   # magenta
	UI_W='\033[1;37m'   # bright white
	UI_D='\033[0;90m'   # dim/grey
	UI_BOLD='\033[1m'
	UI_NC='\033[0m'
else
	UI_R='' UI_G='' UI_Y='' UI_B='' UI_C='' UI_M='' UI_W='' UI_D='' UI_BOLD='' UI_NC=''
fi

# --- Ширина терминала (вычисляется один раз и кэшируется) ---------------------
# Кэш гарантирует, что верх/низ/строки одной рамки используют одинаковую ширину
# даже в неинтерактивном пайпе, где tput cols может отдавать разные значения.
UI_COLS_CACHE=""
ui_cols() {
	if [[ -n "$UI_COLS_CACHE" ]]; then echo "$UI_COLS_CACHE"; return; fi
	local c=""
	if [[ -t 1 ]]; then
		c=$(tput cols 2>/dev/null) || c=""
	fi
	[[ -z "$c" && -n "${COLUMNS:-}" ]] && c="$COLUMNS"
	[[ -z "$c" || ! "$c" =~ ^[0-9]+$ || "$c" -lt 40 ]] && c=80
	[[ "$c" -gt 100 ]] && c=100
	UI_COLS_CACHE="$c"
	echo "$c"
}

# Повторить символ N раз: ui_repeat '═' 40
ui_repeat() {
	local ch="$1" n="$2" out=''
	while ((n-- > 0)); do out+="$ch"; done
	printf '%s' "$out"
}

# Видимая длина строки (без ANSI-последовательностей), для выравнивания рамок
ui_vislen() {
	local s="$1"
	# срезаем ESC[...m. Цвета UI_* хранятся текстом '\033[...m' (в байт ESC их превращает echo -e
	# при выводе), поэтому убираем и настоящий ESC, и запись \033 / \e, иначе рамки съезжают.
	s=$(printf '%s' "$s" | sed -E $'s/(\033|\\\\033|\\\\e)\\[[0-9;]*m//g')
	printf '%s' "${#s}"
}

# --- Заголовки и рамки -------------------------------------------------------
# ui_header "TITLE" — двойная рамка во всю ширину
ui_header() {
	local title; title="$(t "$1")"; local w line
	w=$(ui_cols)
	line=$(ui_repeat '═' "$w")
	echo ""
	echo -e "${UI_C}${line}${UI_NC}"
	# центрируем заголовок
	local tlen pad
	tlen=$(ui_vislen "$title")
	pad=$(((w - tlen) / 2))
	((pad < 0)) && pad=0
	echo -e "${UI_W}$(ui_repeat ' ' "$pad")${title}${UI_NC}"
	echo -e "${UI_C}${line}${UI_NC}"
}

# ui_box_top "Заголовок блока" / ui_box_line "текст" / ui_box_bottom
# Рисует одиночную рамку фиксированной внутренней ширины UI_BOX_W (по умолчанию).
ui_box_top() {
	local title; title="$(t "$1")"; local w inner
	w=$(ui_cols)
	inner=$((w - 2))
	UI_BOX_INNER=$inner
	if [[ -n "$title" ]]; then
		local tlen rest
		tlen=$(ui_vislen " $title ")
		rest=$((inner - tlen - 1))
		((rest < 0)) && rest=0
		echo -e "${UI_C}┌─${UI_NC}${UI_BOLD} ${title} ${UI_NC}${UI_C}$(ui_repeat '─' "$rest")┐${UI_NC}"
	else
		echo -e "${UI_C}┌$(ui_repeat '─' "$inner")┐${UI_NC}"
	fi
}
ui_box_line() {
	local text; text="$(t "$1")"; local inner=${UI_BOX_INNER:-$(($(ui_cols) - 2))}
	local tlen pad
	tlen=$(ui_vislen "$text")
	pad=$((inner - tlen - 1))
	((pad < 0)) && pad=0
	echo -e "${UI_C}│${UI_NC} ${text}$(ui_repeat ' ' "$pad")${UI_C}│${UI_NC}"
}
ui_box_bottom() {
	local inner=${UI_BOX_INNER:-$(($(ui_cols) - 2))}
	echo -e "${UI_C}└$(ui_repeat '─' "$inner")┘${UI_NC}"
}

# --- Сообщения ---------------------------------------------------------------
ui_info()    { echo -e "${UI_C}[i]${UI_NC} $(t "$1")"; }
ui_success() { echo -e "${UI_G}[✓]${UI_NC} $(t "$1")"; }
ui_warn()    { echo -e "${UI_Y}[!]${UI_NC} $(t "$1")"; }
ui_error()   { echo -e "${UI_R}[✗]${UI_NC} $(t "$1")" >&2; }
ui_step()    { echo -e "${UI_M}[→]${UI_NC} ${UI_BOLD}$(t "$1")${UI_NC}"; }

# --- Меню (нумерованный выбор, один пункт) -----------------------------------
# ui_menu "Заголовок" default_index "Пункт 1" "Пункт 2" ...
# Возвращает 1-based индекс через переменную UI_MENU_CHOICE.
# Опция: задайте UI_MENU_ZERO="Метка" ПЕРЕД вызовом — добавится пункт «0) Метка»
# (для «Выход»/«Назад»); выбор 0 вернёт UI_MENU_CHOICE=0. Переменная одноразовая.
ui_menu() {
	local title="$1" def="$2"; shift 2
	local items=("$@") n=$#
	local zero="${UI_MENU_ZERO:-}"; UI_MENU_ZERO=""   # одноразово, чтобы не «протекало»
	ui_box_top "$title"                                # заголовок переведёт ui_box_top
	local i=1
	for it in "${items[@]}"; do
		ui_box_line "${UI_G}${i})${UI_NC} $(t "${it}")"   # элемент — переводим явно (у строки есть префикс)
		((i++))
	done
	[[ -n "$zero" ]] && ui_box_line "${UI_G}0)${UI_NC} $(t "${zero}")"
	ui_box_bottom
	local choice
	while true; do
		# Промпт печатаем в STDOUT (тот же поток, что бокс), НЕ через read -p (тот пишет в
		# stderr без \n — часть терминалов, особенно SSH-клиенты под Windows, не отрисовывают
		# такую строку до перевода строки → «промпт/последний пункт не виден пока не нажмёшь Enter»).
		echo -en "${UI_W}$(t "Ваш выбор")${UI_NC} [${def}]: "
		read -r choice
		choice=${choice:-$def}
		if [[ "$choice" =~ ^[0-9]+$ ]]; then
			if [[ -n "$zero" ]] && ((choice == 0)); then UI_MENU_CHOICE=0; return 0; fi
			if ((choice >= 1 && choice <= n)); then UI_MENU_CHOICE=$choice; return 0; fi
		fi
		if [[ -n "$zero" ]]; then ui_warn "$(t "Введите число от 0 до") $n"; else ui_warn "$(t "Введите число от 1 до") $n"; fi
	done
}

# --- Чекбоксы (множественный выбор) ------------------------------------------
# ui_checklist "Заголовок" preselected_csv key1 "Метка 1" key2 "Метка 2" ...
#   preselected_csv — список ключей через запятую, помеченных [x] по умолчанию.
# Результат: UI_CHECK_RESULT — выбранные ключи через пробел.
ui_checklist() {
	local title="$1" preselected="$2"; shift 2
	local keys=() labels=()
	while (($#)); do keys+=("$1"); labels+=("$2"); shift 2; done
	local n=${#keys[@]}

	# карта выбранных
	declare -A sel
	local k
	for k in "${keys[@]}"; do sel["$k"]=0; done
	IFS=',' read -ra _pre <<<"$preselected"
	for k in "${_pre[@]}"; do [[ -n "$k" ]] && sel["$k"]=1; done

	while true; do
		ui_box_top "$title"
		local i=1
		for ((i = 1; i <= n; i++)); do
			local key="${keys[i-1]}" label="${labels[i-1]}" mark
			if [[ "${sel[$key]}" == "1" ]]; then
				mark="${UI_G}[x]${UI_NC}"
			else
				mark="${UI_D}[ ]${UI_NC}"
			fi
			ui_box_line "${mark} ${UI_G}$(printf '%2d' "$i"))${UI_NC} $(t "${label}")"
		done
		ui_box_bottom
		echo -e "${UI_D}$(t "Номер = вкл/выкл · [a] все · [n] ничего · [d] готово")${UI_NC}"
		local input
		echo -en "${UI_W}>${UI_NC} "   # промпт в stdout (см. ui_menu)
		read -r input
		case "$input" in
			d|D|'') break ;;
			a|A) for k in "${keys[@]}"; do sel["$k"]=1; done ;;
			n|N) for k in "${keys[@]}"; do sel["$k"]=0; done ;;
			*)
				if [[ "$input" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= n)); then
					local key="${keys[input-1]}"
					if [[ "${sel[$key]}" == "1" ]]; then sel["$key"]=0; else sel["$key"]=1; fi
				else
					ui_warn "$(t "Неизвестный ввод:") $input"
				fi
				;;
		esac
		# перерисовка: чистим предыдущий блок (+2 строки подсказки/ввода)
		# простая реализация — просто печатаем заново ниже (без курсорной магии)
	done

	local result=()
	for k in "${keys[@]}"; do [[ "${sel[$k]}" == "1" ]] && result+=("$k"); done
	UI_CHECK_RESULT="${result[*]}"
}

# --- Подтверждение / ввод ----------------------------------------------------
# ui_confirm "Сообщение" [y|n] -> код возврата 0=yes 1=no
ui_confirm() {
	local msg; msg="$(t "$1")"; local def="${2:-y}" ans hint
	if [[ "$def" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
	while true; do
		echo -en "${UI_W}${msg}${UI_NC} ${hint}: "   # промпт в stdout (см. ui_menu)
		read -r ans
		ans=${ans:-$def}
		case "$ans" in
			[Yy]*) return 0 ;;
			[Nn]*) return 1 ;;
			*) ui_warn "Ответьте y или n" ;;
		esac
	done
}

# ui_input "Подсказка" [default] -> значение в UI_INPUT
ui_input() {
	local prompt; prompt="$(t "$1")"; local def="${2:-}" val
	if [[ -n "$def" ]]; then
		echo -en "${UI_W}${prompt}${UI_NC} [${def}]: "   # промпт в stdout (см. ui_menu)
		read -r val
		val=${val:-$def}
	else
		echo -en "${UI_W}${prompt}${UI_NC}: "
		read -r val
	fi
	UI_INPUT="$val"
}

# ui_input_validated "Подсказка" "default" "ERE-regex" "текст ошибки" -> UI_INPUT
# Перезапрашивает, пока ввод не пройдёт regex. На non-tty (EOF) не зацикливается:
# ui_input вернёт default; если он невалиден — принимаем как есть с предупреждением.
ui_input_validated() {
	local prompt="$1" def="$2" re="$3" err="${4:-Некорректное значение}"
	while true; do
		ui_input "$prompt" "$def"                # перевод промпта — внутри ui_input
		[[ "$UI_INPUT" =~ $re ]] && return 0
		ui_warn "$err"                           # перевод — внутри ui_warn
		if [[ ! -t 0 ]]; then ui_warn "$(t "Не-tty — оставляю значение без проверки:") '${UI_INPUT}'"; return 0; fi
	done
}

# ui_password "Подсказка" -> значение в UI_PASSWORD (скрытый ввод)
ui_password() {
	local prompt; prompt="$(t "$1")"; local val
	echo -en "${UI_W}${prompt}${UI_NC}: "   # промпт в stdout (см. ui_menu); ввод скрытый
	read -rs val
	echo ""
	UI_PASSWORD="$val"
}

# --- Спиннер для долгих команд -----------------------------------------------
# ui_spin "Описание" command arg1 arg2 ...
#   stdout/stderr команды уходят в $SETUP_LOG (если задан), иначе в /dev/null.
#   Возвращает код возврата команды.
ui_spin() {
	local desc; desc="$(t "$1")"; shift
	local logfile="${SETUP_LOG:-/dev/null}"
	local spin='|/-\' i=0
	local start=$SECONDS

	if [[ ! -t 1 ]]; then
		# не-TTY: просто запускаем без анимации
		echo -e "${UI_C}[i]${UI_NC} ${desc}..."
		"$@" >>"$logfile" 2>&1 </dev/null
		return $?
	fi

	# Ширина терминала: строка ОБЯЗАНА влезать в одну строку, иначе она
	# переносится и \r возвращает курсор только на последнюю визуальную строку —
	# получается «лесенка» из повторов. Поэтому всё обрезаем до cols-1.
	local cols; cols=$(tput cols 2>/dev/null); [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

	# stdin из /dev/null: любой неожиданный промпт получит EOF и не зависнет
	# невидимо под спиннером (needrestart глушим через NEEDRESTART_* в core.sh).
	"$@" >>"$logfile" 2>&1 </dev/null &
	local pid=$!
	tput civis 2>/dev/null
	while kill -0 "$pid" 2>/dev/null; do
		i=$(((i + 1) % 4))
		local elapsed=$((SECONDS - start))
		# Живой хвост лога — видно, ЧТО сейчас реально происходит
		local tailline=""
		if [[ -f "$logfile" ]]; then
			tailline=$(tail -n1 "$logfile" 2>/dev/null | tr -d '\r\000' | tr '\t' ' ')
		fi
		local line="${desc} · ${elapsed}s"
		[[ -n "$tailline" ]] && line+=" │ ${tailline}"
		line=${line:0:cols-6}     # 4 видимых символа префикса "[x] " + запас
		printf '\r\033[K%b %s' "${UI_C}[${spin:$i:1}]${UI_NC}" "$line"
		sleep 0.5
	done
	wait "$pid"
	local rc=$?
	tput cnorm 2>/dev/null
	local total=$((SECONDS - start)) tstr=""
	((total >= 5)) && tstr=" (${total}s)"
	local fdesc="${desc}${tstr}"
	fdesc=${fdesc:0:cols-6}
	if ((rc == 0)); then
		printf '\r\033[K%b %s\n' "${UI_G}[✓]${UI_NC}" "$fdesc"
	else
		printf '\r\033[K%b %s\n' "${UI_R}[✗]${UI_NC}" "$fdesc"
		# Показать хвост лога — почему упало
		if [[ -f "$logfile" ]]; then
			echo -e "${UI_D}--- $(t "последние строки лога") ---${UI_NC}"
			tail -n 8 "$logfile" 2>/dev/null | cut -c1-$((cols-2)) | sed 's/^/  /'
			echo -e "${UI_D}--- $(t "полный лог"): ${logfile} ---${UI_NC}"
		fi
	fi
	return $rc
}

# --- Gauge (progress bar) ----------------------------------------------------
# ui_gauge current total "Метка"
ui_gauge() {
	local cur="$1" total="$2" label="$3"
	local width=30 filled empty pct
	((total == 0)) && total=1
	pct=$((cur * 100 / total))
	filled=$((cur * width / total))
	empty=$((width - filled))
	printf "${UI_G}[%s%s]${UI_NC} %d/%d  %s\n" \
		"$(ui_repeat '█' "$filled")" "$(ui_repeat '░' "$empty")" "$cur" "$total" "$label"
}

# --- Overview всех этапов ----------------------------------------------------
# Ожидает глобальные массивы из core.sh:
#   STAGE_KEYS=(...)  STAGE_LABELS["key"]=...  и функцию state_get "key".
# ui_progress_overview "current_key"
ui_progress_overview() {
	local current="$1"
	ui_box_top "Прогресс установки"
	local key label status icon
	for key in "${STAGE_KEYS[@]}"; do
		label="$(t "${STAGE_LABELS[$key]}")"
		status=$(state_get "$key")
		case "$status" in
			done)    icon="${UI_G}✓${UI_NC}" ;;
			failed)  icon="${UI_R}✗${UI_NC}" ;;
			skipped) icon="${UI_D}○${UI_NC}" ;;
			*)
				if [[ "$key" == "$current" ]]; then
					icon="${UI_Y}▸${UI_NC}"; label="${UI_BOLD}${label}${UI_NC}"
				else
					icon="${UI_D}○${UI_NC}"
				fi
				;;
		esac
		ui_box_line "  ${icon}  ${label}"
	done
	ui_box_bottom
}

# --- Пауза -------------------------------------------------------------------
ui_pause() {
	local msg; msg="$(t "${1:-Нажмите Enter для продолжения}")"
	echo -en "${UI_D}${msg}...${UI_NC}"   # промпт в stdout (см. ui_menu)
	read -r _
}
