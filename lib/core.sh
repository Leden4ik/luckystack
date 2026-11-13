#!/bin/bash
# =============================================================================
# lib/core.sh — Ядро: state-машина, логирование, run_step, проверки, конфиг.
# Зависит от lib/ui.sh (должен быть подключён раньше).
# =============================================================================

# Пути задаются главным скриптом; здесь — дефолты на случай автономного запуска.
: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${ASSETS_DIR:=$SCRIPT_DIR/assets}"
: "${SETUP_LOG:=/var/log/luckystack/setup.log}"
: "${STATE_FILE:=/var/lib/luckystack/setup.state}"
: "${CONFIG_FILE:=/etc/luckystack/setup.conf}"

# --- Полностью неинтерактивный apt ------------------------------------------
# DEBIAN_FRONTEND глушит debconf, но НЕ needrestart (Debian 12/13), который
# спрашивает «какие сервисы перезапустить?» читая /dev/tty — из-за этого apt
# зависал «навсегда» под спиннером. NEEDRESTART_MODE=a/SUSPEND=1 подавляют его.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export UCF_FORCE_CONFFOLD=1

# Реестр этапов (заполняется главным скриптом):
#   STAGE_KEYS=(preflight database ...)
#   STAGE_LABELS[key]="Человекочитаемая метка"
#   STAGE_TYPE[key]="core|optional"
declare -gA STAGE_LABELS
declare -gA STAGE_TYPE
declare -ga STAGE_KEYS

# Регистрация этапа: register_stage key "Метка" core|optional
register_stage() {
	local key="$1" label="$2" type="${3:-core}"
	STAGE_KEYS+=("$key")
	STAGE_LABELS["$key"]="$label"
	STAGE_TYPE["$key"]="$type"
}

# --- Логирование -------------------------------------------------------------
log() {
	local ts
	ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || ts='--'
	# лог создаём сразу с правами 600 (в нём вывод инсталлеров и диагностика)
	[[ -e "$SETUP_LOG" ]] || ( umask 077; : >"$SETUP_LOG" ) 2>/dev/null || true
	echo "[$ts] $*" >>"$SETUP_LOG"
}
# Старые записи setup.log могли сохранить пароли открытым текстом: новые config_set уже скрывает.
_log_scrub_secrets() {
	local f
	for f in "$SETUP_LOG" "${SETUP_LOG}.1"; do
		[[ -f "$f" ]] || continue
		grep -qE '[A-Z0-9_]*(PW|PASS|PASSWORD|SECRET|TOKEN|KEY)=[^<[:space:]]' "$f" || continue
		sed -i -E 's/([A-Z0-9_]*(PW|PASS|PASSWORD|SECRET|TOKEN|KEY))=[^<[:space:]][^[:space:]]*/\1=<скрыто>/g' "$f"
		chmod 600 "$f"
		log "setup.log: секреты в старых записях скрыты"
	done
	return 0
}
log_init() {
	# НЕ обрезаем лог: read-only запуски (--status/--healthcheck), меню и повторные
	# прогоны не должны затирать журнал установки. Дозаписываем; при разрастании
	# (>5 МБ) ротируем в .1, чтобы файл не рос бесконечно.
	if [[ -f "$SETUP_LOG" ]]; then
		local sz; sz=$(wc -c <"$SETUP_LOG" 2>/dev/null || echo 0)
		[[ "$sz" =~ ^[0-9]+$ ]] && ((sz > 5242880)) && mv -f "$SETUP_LOG" "${SETUP_LOG}.1" 2>/dev/null || true
	fi
	{ echo ""; echo "==================================================================="; } >>"$SETUP_LOG" 2>/dev/null || true
	# setup.log и ротация .1 — только root (раньше создавались под umask → 644, читаемы всеми)
	chmod 600 "$SETUP_LOG" "${SETUP_LOG}.1" 2>/dev/null || true
	log "=== LuckyStack запущен ==="
}

# --- State-машина ------------------------------------------------------------
# Формат STATE_FILE: строки  key=done|failed|skipped|pending
state_get() {
	local key="$1"
	[[ -f "$STATE_FILE" ]] || { echo "pending"; return; }
	local line
	line=$(grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -n1)
	if [[ -n "$line" ]]; then echo "${line#*=}"; else echo "pending"; fi
}

state_set() {
	local key="$1" val="$2"
	touch "$STATE_FILE"
	if grep -qE "^${key}=" "$STATE_FILE" 2>/dev/null; then
		# заменяем существующую строку (sed-портативно)
		local tmp="${STATE_FILE}.tmp"
		grep -vE "^${key}=" "$STATE_FILE" >"$tmp"
		echo "${key}=${val}" >>"$tmp"
		mv "$tmp" "$STATE_FILE"
	else
		echo "${key}=${val}" >>"$STATE_FILE"
	fi
	log "state: ${key}=${val}"
}

state_reset() {
	: >"$STATE_FILE"
	log "state: сброшен"
}

# Есть ли незавершённая установка (хоть один done/failed)?
state_has_progress() {
	[[ -f "$STATE_FILE" ]] || return 1
	grep -qE '=(done|failed|skipped)$' "$STATE_FILE" 2>/dev/null
}

# Первый незавершённый этап (для resume); пусто если все done/skipped
state_first_pending() {
	local key st
	for key in "${STAGE_KEYS[@]}"; do
		st=$(state_get "$key")
		[[ "$st" == "done" || "$st" == "skipped" ]] && continue
		echo "$key"; return 0
	done
	return 1
}

# Установка ЕСТЬ, но НЕ завершена (остался этап не done/skipped) → rc=0.
# Отличает «частичную/незавершённую» от «полностью завершённой» (все done/skipped) —
# чтобы меню не кричало «обнаружена незавершённая установка» на готовом сервере.
state_is_incomplete() {
	state_has_progress || return 1
	[[ -n "$(state_first_pending)" ]]
}

# --- Конфиг (ответы пользователя) -------------------------------------------
# setup.conf — source-абельный bash (KEY=value / KEY="a b c").
config_load() {
	[[ -f "$CONFIG_FILE" ]] && { . "$CONFIG_FILE"; log "config: загружен из $CONFIG_FILE"; return 0; }
	return 1
}

# config_set KEY VALUE — записать/обновить переменную в setup.conf и в окружении
config_set() {
	local key="$1" val="$2"
	touch "$CONFIG_FILE"
	if grep -qE "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
		local tmp="${CONFIG_FILE}.tmp"
		grep -vE "^${key}=" "$CONFIG_FILE" >"$tmp"
		printf '%s=%q\n' "$key" "$val" >>"$tmp"
		mv "$tmp" "$CONFIG_FILE"
	else
		printf '%s=%q\n' "$key" "$val" >>"$CONFIG_FILE"
	fi
	# mv tmp-файла сбрасывает права на umask — возвращаем 600 (в файле пароли)
	chmod 600 "$CONFIG_FILE" 2>/dev/null || true
	printf -v "$key" '%s' "$val"   # экспорт в текущее окружение
	# значения чувствительных ключей (пароли/токены/ключи) в лог НЕ пишем
	case "$key" in
		*PW*|*PASS*|*SECRET*|*TOKEN*|*KEY*) log "config: ${key}=<скрыто>" ;;
		*) log "config: ${key}=${val}" ;;
	esac
}

config_init_header() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		{
			echo "# LuckyStack — настройки сервера (автогенерация, можно править вручную)"
			echo "# Используется при --resume / --unattended"
		} >"$CONFIG_FILE"
	fi
	# В setup.conf хранятся пароли (MariaDB, Monit, Rspamd…) — только для root
	chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# --- Системные команды (с учётом DRY_RUN) ------------------------------------
# sys_run "Описание" command args...
#   В обычном режиме — запускает команду со спиннером, вывод в setup.log.
#   В --dry-run — только печатает, что было бы выполнено (ничего не меняет).
sys_run() {
	local desc="$1"; shift
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} ${desc}"
		log "[dry-run] $*"
		return 0
	fi
	log "RUN: $*"
	ui_spin "$desc" "$@"
}

# apt_available pkg — есть ли у пакета реальный кандидат на установку. Одного `apt-cache show`
# мало: снятые пакеты (webalizer в Debian 13, libpcre3-dev на trixie) имеют запись,
# но «Candidate: (none)», и apt-get install на них падает.
apt_available() {
	local cand
	cand="$(apt-cache policy "$1" 2>/dev/null | sed -nE 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -1)"
	[[ -n "$cand" && "$cand" != "(none)" ]]
}

# Ждать чужой apt вместо мгновенной ошибки. На свежем сервере сразу после загрузки почти всегда
# работают apt-daily и unattended-upgrades, и любой наш apt-get падал с «Could not get lock».
# Пишем один раз, дальше это действует на все вызовы apt (и на наши прямые apt-get в модулях).
APT_LOCK_CONF=/etc/apt/apt.conf.d/50luckystack-lock
apt_lock_wait_conf() {
	[[ "${DRY_RUN:-0}" == "1" || -f "$APT_LOCK_CONF" ]] && return 0
	[[ -d /etc/apt/apt.conf.d ]] || return 0
	printf '%s\n' '// luckystack: ждать, пока другой apt (apt-daily, unattended-upgrades) освободит блокировку' \
		'DPkg::Lock::Timeout "600";' >"$APT_LOCK_CONF" 2>/dev/null && chmod 644 "$APT_LOCK_CONF"
	return 0
}

# apt_install pkg1 pkg2 ...  — установка пакетов (idempotent, неинтерактивно)
apt_install() {
	local pkgs="$*"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt-get install: ${pkgs}"
		log "[dry-run] apt-get install $pkgs"
		return 0
	fi
	apt_lock_wait_conf
	# Фильтр недоступных пакетов: apt АТОМАРЕН — один отсутствующий пакет валит весь
	# вызов (не ставится НИЧЕГО). Имена пакетов различаются между релизами: напр.
	# software-properties-common есть в Debian 12/Ubuntu, но отсутствует в Debian 13
	# (trixie) — из-за этого падала установка базовых зависимостей и дальше всё
	# рушилось каскадом. Отсеиваем недоступное заранее, остальное ставим.
	local avail="" missing="" p
	for p in $pkgs; do
		# Доступен = есть РЕАЛЬНЫЙ кандидат на установку. Просто `apt-cache show` мало:
		# снятые/transitional пакеты (webalizer на bullseye, libpcre3-dev на trixie)
		# имеют запись, но «Candidate: (none)» → apt-get install падает на них атомарно.
		if apt_available "$p"; then avail+=" $p"; else missing+=" $p"; fi
	done
	if [[ -n "$missing" ]]; then
		ui_warn "Нет в репозитории (пропуск):${missing}"
		log "APT: недоступны и пропущены:${missing}"
	fi
	pkgs="${avail# }"
	[[ -z "$pkgs" ]] && { ui_warn "apt_install: доступных пакетов не осталось — пропуск."; return 0; }
	log "APT install: $pkgs"
	# Acquire-таймауты: недоступный CDN (напр. CloudFront у CrowdSec) по умолчанию
	# висит ~2 мин на каждой попытке скачивания — ограничиваем 30 секундами.
	# shellcheck disable=SC2086
	# APT_NO_RECOMMENDS=1 перед вызовом — без рекомендуемых пакетов (см. phpMyAdmin в dbtools.sh)
	ui_spin "Установка пакетов: ${pkgs}" apt-get install -y -qq ${APT_NO_RECOMMENDS:+--no-install-recommends} \
		-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2 \
		-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef $pkgs
}

# Кодовое имя релиза (bookworm/trixie/jammy…) БЕЗ зависимости от lsb_release:
# пакет lsb-release может быть не установлен (а если он не встал — на Debian 13
# пустой codename давал «deb …/php/  main» → Malformed entry → падал ВЕСЬ apt).
# Берём VERSION_CODENAME из /etc/os-release, lsb_release — лишь запасной вариант.
os_codename() {
	local c=""
	[[ -r /etc/os-release ]] && c=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")
	[[ -z "$c" ]] && command -v lsb_release >/dev/null 2>&1 && c=$(lsb_release -sc 2>/dev/null)
	printf '%s' "$c"
}

# Нативная версия PHP дистрибутива — НА НЕЙ ISPConfig держит FPM-пул панели (её -fpm
# ОБЯЗАТЕЛЕН, иначе панель отдаёт 502). ВАЖНО: `apt-cache depends php` НЕ подходит —
# репозиторий Ondřej Surý (deb.sury.org), который мы подключаем ради мультиверсийности,
# перебивает метапакет `php` на свою САМУЮ СВЕЖУЮ (напр. на bookworm выдаст 8.4, хотя
# нативная 8.2). Поэтому определяем по релизу ОС. Пусто для неизвестных релизов — тогда
# полагаемся на пост-фактум определение из vhost панели (_ispconfig_ensure_panel_php).
_distro_native_php() {
	local id code
	id=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")
	code="$(os_codename)"
	case "${id}:${code}" in
		debian:bullseye) echo 7.4 ;;
		debian:bookworm) echo 8.2 ;;
		debian:trixie)   echo 8.4 ;;
		ubuntu:jammy)    echo 8.1 ;;
		ubuntu:noble)    echo 8.3 ;;
		*)               echo "" ;;
	esac
}

apt_update() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt-get update"
		return 0
	fi
	export DEBIAN_FRONTEND=noninteractive
	apt_lock_wait_conf
	ui_spin "Обновление списков пакетов (apt update)" apt-get update -qq
}

# Отключить БИТЫЕ apt-репозитории (нет Release file / не качаются) — иначе любой
# apt-get update возвращает ошибку и валит этапы. Частый случай: мёртвый
# bullseye-backports на Debian 11 (ушёл в LTS), оставшийся в sources.list образа.
# Закомментированные строки помечаются «luckystack-disabled».
disable_broken_apt_sources() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} проверка/отключение битых apt-репозиториев"; return 0; }
	local out suites s
	out="$(apt-get update 2>&1)"
	# Достаём suite битых репо из строк вида:
	#   E: The repository 'http://.../debian bullseye-backports Release' does not have a Release file.
	mapfile -t suites < <(printf '%s\n' "$out" \
		| sed -nE "s/.*'[^']* ([^ ']+) Release' does not have a Release file.*/\1/p" | sort -u)
	((${#suites[@]})) || return 0
	ui_warn "Битые apt-репозитории (нет Release) — отключаю, чтобы не ломать установку: ${suites[*]}"
	for s in "${suites[@]}"; do
		[[ -n "$s" ]] || continue
		# комментируем deb/deb-src строки с этим suite в sources.list и *.list
		sed -i -E "/^[[:space:]]*deb([[:space:]]|-src[[:space:]]).*[[:space:]]${s}([[:space:]]|\$)/ s/^[[:space:]]*/# luckystack-disabled /" \
			/etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
		log "preflight: отключён битый репозиторий suite=${s}"
	done
	apt-get update >/dev/null 2>&1 || true
}

# Перф-sysctl: ПЕРСИСТЕНТНО (переживает ребут) и НЕЗАВИСИМО от создания swap.
#   • vm.swappiness=10 — реже свопить горячие страницы InnoDB (раньше ставился только
#     через `sysctl -w` внутри _ensure_swap → откатывался на 60 после ребута; это был баг);
#   • TCP BBR (fq + bbr) — конгешн-контроль, заметный прирост пропускной на VPS (если ядро умеет).
# Вызывается из preflight (core-этап, выполняется всегда). Идемпотентно.
_tune_kernel_perf() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} sysctl: vm.swappiness=10 + TCP BBR (fq+bbr)"; return 0; }
	local f=/etc/sysctl.d/99-luckystack-perf.conf bbr=""
	# BBR добавляем только если ядро его поддерживает (модуль tcp_bbr) — иначе sysctl ругнётся.
	if modprobe tcp_bbr >/dev/null 2>&1 || grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		bbr=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n'
	fi
	{
		echo "# luckystack: перф-sysctl (swappiness + TCP BBR). Можно править/удалить."
		echo "vm.swappiness = 10"
		[[ -n "$bbr" ]] && printf '%s' "$bbr"
	} >"$f"
	sysctl -p "$f" >>"$SETUP_LOG" 2>&1 || ui_warn "Часть перф-sysctl не применилась (см. $SETUP_LOG)."
	ui_success "Перф-sysctl: vm.swappiness=10${bbr:+ + TCP BBR} (персистентно, /etc/sysctl.d)."
}

# Создать swap-файл, если RAM мало и swap отсутствует. Вызывается РАНО (preflight),
# чтобы защитить весь стек от OOM — в частности clamd (этап rspamd грузит ~1 ГБ
# сигнатур и на малых VPS без swap ловит oom-kill). 2 ГБ при RAM<4G. Откл: TUNE_SWAP=n.
_ensure_swap() {
	[[ "${TUNE_SWAP:-y}" == "y" ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} swap: создать 2G-файл, если RAM<4G и swap нет (защита от OOM)"
		return 0
	fi
	local swap_kb ram_mb
	swap_kb="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
	(( ${swap_kb:-0} > 0 )) && return 0          # swap уже есть
	ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
	(( ${ram_mb:-9999} >= 4096 )) && return 0    # RAM достаточно
	[[ -e /swapfile ]] && return 0
	# Размер из мастера (TUNE_SWAP_SIZE, напр. 2G/4G); дефолт 2G, пол — 512M.
	local size="${TUNE_SWAP_SIZE:-2G}" size_mb
	size_mb=$(( ${size%[Gg]} * 1024 )); (( size_mb < 512 )) && { size_mb=512; size=512M; }
	ui_step "Создание swap-файла ${size} (RAM ${ram_mb}M, swap нет — защита от OOM, напр. clamd)"
	if ! fallocate -l "$size" /swapfile >>"$SETUP_LOG" 2>&1; then
		dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" >>"$SETUP_LOG" 2>&1 || { ui_warn "Не удалось создать /swapfile."; rm -f /swapfile; return 0; }
	fi
	chmod 600 /swapfile
	if mkswap /swapfile >>"$SETUP_LOG" 2>&1 && swapon /swapfile >>"$SETUP_LOG" 2>&1; then
		# Маркер-строка перед записью — чтобы uninstall удалял ТОЛЬКО наш swap, а не
		# чужой /swapfile, созданный админом независимо.
		grep -q '^/swapfile[[:space:]]' /etc/fstab 2>/dev/null || \
			printf '# luckystack-swap\n/swapfile none swap sw 0 0\n' >>/etc/fstab
		# vm.swappiness задаёт _tune_kernel_perf (персистентно), здесь не дублируем.
		ui_success "swap ${size} создан и включён (/swapfile)."
	else
		ui_warn "Не удалось включить swap (возможно, контейнер/WSL) — пропуск."
		swapoff /swapfile 2>/dev/null || true; rm -f /swapfile
	fi
}

# IP клиента из текущей SSH-сессии (для авто-подстановки в allow-правила). Пусто,
# если запуск не по SSH. Печатает IPv4/IPv6.
_detect_ssh_ip() {
	# :- обязателен: под set -u незаданная переменная (cron, консоль, sudo) роняла весь скрипт
	local ip="${SSH_CLIENT:-}"; ip="${ip%% *}"
	if [[ -z "$ip" ]]; then ip="${SSH_CONNECTION:-}"; ip="${ip%% *}"; fi
	# ВАЖНО: sudo ВЫРЕЗАЕТ SSH_CLIENT/SSH_CONNECTION из окружения → выше пусто, и анти-локаут
	# firewall/ssh не мог определить IP админа → рубил доступ. Достаём IP текущей SSH-сессии
	# способами, переживающими sudo: who am i (utmp) и ss по established-соединению к sshd.
	if [[ -z "$ip" ]]; then
		ip="$(who am i 2>/dev/null | sed -nE 's/.*\(([0-9a-fA-F:.]+)\)[[:space:]]*$/\1/p' | head -1)"
	fi
	if [[ -z "$ip" ]]; then
		ip="$(ss -Htno state established "( sport = :${SSH_PORT:-22} )" 2>/dev/null \
			| awk '{print $5}' | sed -E 's/:[0-9]+$//; s/[][]//g' | grep -vE '^(127\.|::1$)' | head -1)"
	fi
	[[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$ip" == *:* ]] && printf '%s' "$ip"
}

# gen_password [length] — печатает случайный пароль (без спецсимволов, удобный для CLI)
gen_password() {
	local len="${1:-20}"
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$len"
	else
		tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
	fi
	echo ""
}

# config_get_or_gen KEY [length] — вернуть сохранённый пароль или сгенерировать,
# сохранив его в setup.conf. Печатает значение.
config_get_or_gen_password() {
	local key="$1" len="${2:-20}" cur
	cur="$(eval "echo \${$key:-}")"
	if [[ -z "$cur" ]]; then
		cur="$(gen_password "$len")"
		config_set "$key" "$cur"
	fi
	echo "$cur"
}

# --- Очистка кеша сборки ------------------------------------------------------
# Артефакты прошлых установок, которые переиспользуются как кеш (идемпотентные
# пропуски «уже склонировано/собрано»). Удаление гарантирует сборку с нуля.
clean_build_cache() {
	local paths=(
		/usr/local/src/nginx          # исходники nginx + модули + quictls + brotli/zlib-ng
		/tmp/ispconfig3_install       # исходники ISPConfig
		/tmp/ispconfig.tar.gz
	)
	ui_step "Очистка кеша сборки (исходники прошлых попыток)"
	local p
	for p in "${paths[@]}"; do
		if [[ "${DRY_RUN:-0}" == "1" ]]; then
			ui_info "${UI_D}[dry-run]${UI_NC} rm -rf ${p}"
			continue
		fi
		[[ -e "$p" ]] && { rm -rf "$p"; log "clean_build_cache: rm -rf $p"; }
	done
	# хвосты make install DESTDIR (nginx-install-<pid>)
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		rm -rf /tmp/nginx-install-* 2>/dev/null || true
	fi
	ui_success "Кеш сборки очищен — следующая сборка пройдёт с нуля."
}

# --- Права на то, что раскладывает установщик ---------------------------------
# Копия установщика с Windows (WinSCP, архив) приезжает с правами 777, а cp -a и tar
# под root переносят их на системные файлы. Так /etc/nginx/snippets на проде стал 777:
# процесс любого сайта мог подменить сниппет, который nginx читает при reload от root.

# Заменить файл новой версией, сохранив владельца и права старого: «awk … > f.new && mv f.new f»
# давал root:root 644 по umask, а файлы ISPConfig, vhost'ы и fstab бывают с другими правами
# (например, конфиги с паролями 600 или файлы панели ispconfig:ispconfig).
mv_keep() {
	local new="$1" dst="$2"
	if [[ -e "$dst" ]]; then
		chown --reference="$dst" "$new" 2>/dev/null || true
		chmod --reference="$dst" "$new" 2>/dev/null || true
	fi
	mv -f "$new" "$dst"
}

# Снять запись для группы и «других» со СВОЕГО дерева (наши ассеты, каталог установщика).
# Симлинки пропускаем: chmod пошёл бы по ссылке.
perm_strip_gw_ow() {
	local p
	for p in "$@"; do
		[[ -e "$p" ]] || continue
		find "$p" -xdev ! -type l -perm /022 -exec chmod go-w {} + 2>/dev/null || true
	done
}

# Дерево конфигов, которое целиком наше (сниппеты nginx): каталоги 755, файлы 644.
# Убирает и запись, и лишний бит исполнения, оставшийся от 777.
perm_conf_tree() {
	local p
	for p in "$@"; do
		[[ -d "$p" ]] || continue
		find "$p" -xdev ! -type l -type d ! -perm 755 -exec chmod 755 {} + 2>/dev/null || true
		find "$p" -xdev ! -type l -type f ! -perm 644 -exec chmod 644 {} + 2>/dev/null || true
	done
}

# Конфиги стека: снимаем ТОЛЬКО запись для «других». Групповую запись не трогаем, она
# бывает штатной (ISPConfig lib/lang 770 под редактор языков, /etc/bind/slave 2770).
# Каталоги со sticky-битом пропускаем. Печатает число исправленных путей, список — в лог.
STACK_CONF_DIRS=(/etc/nginx /etc/php /usr/local/ispconfig /etc/postfix /etc/dovecot
	/etc/crowdsec /etc/fail2ban /etc/ufw /etc/roundcube /etc/phpmyadmin /etc/rspamd
	/etc/bind /etc/pure-ftpd /etc/mysql /etc/ssh /etc/systemd/system /etc/cron.d)
perm_fix_stack_conf() {
	local d dirs=() n
	for d in "${STACK_CONF_DIRS[@]}"; do [[ -e "$d" ]] && dirs+=("$d"); done
	((${#dirs[@]})) || { echo 0; return 0; }
	n="$(find "${dirs[@]}" -xdev ! -type l -perm -0002 ! \( -type d -perm -1000 \) \
		-print -exec chmod o-w {} + 2>/dev/null | tee -a "${SETUP_LOG:-/dev/null}" | grep -c .)"
	echo "${n:-0}"
}

# --- Проверки окружения ------------------------------------------------------
require_root() {
	if [[ $EUID -ne 0 ]]; then
		if [[ "${DRY_RUN:-0}" == "1" ]]; then
			ui_warn "Не root, но режим --dry-run — продолжаем (без изменений в системе)."
			return 0
		fi
		ui_error "Нужны права root. Запустите через sudo."
		exit 1
	fi
}

# Проверка ОС. Допускаются Debian 12+ и Ubuntu 22.04+.
# При --dry-run / не-Linux (разработка) — только предупреждение.
check_os() {
	if [[ ! -f /etc/os-release ]]; then
		if [[ "${DRY_RUN:-0}" == "1" ]]; then
			ui_warn "Нет /etc/os-release — режим разработки (--dry-run)."
			return 0
		fi
		ui_error "Не удаётся определить ОС (/etc/os-release отсутствует)."
		exit 1
	fi
	# Читаем os-release В СУБШЕЛЛЕ: прямой `. /etc/os-release` затирал переменные
	# скрипта (там VERSION="12 (bookworm)" перебивал наш VERSION баннера → «v12»).
	local osid osver
	osid=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")
	osver=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}")
	case "$osid" in
		debian)
			# Основная поддержка — Debian 12 (Bookworm) и 13 (Trixie). Debian 11
			# (Bullseye) разрешён как ЭКСПЕРИМЕНТАЛЬНЫЙ (ещё в LTS, репо живые), но
			# не тестировался полностью — особенно сборка nginx с HTTP/3 на gcc-10.
			if ((${osver%%.*} < 11)); then
				ui_error "Требуется Debian 11+ (Bullseye/Bookworm/Trixie). Обнаружено: Debian $osver."
				exit 1
			fi
			((${osver%%.*} == 11)) && ui_warn "Debian 11 (Bullseye) — ЭКСПЕРИМЕНТАЛЬНО (полностью тестировались 12/13)."
			((${osver%%.*} > 13)) && ui_warn "Debian $osver новее протестированных 12/13 — продолжаем." ;;
		ubuntu)
			if ((${osver%%.*} < 22)); then
				ui_error "Требуется Ubuntu 22.04+. Обнаружено: Ubuntu $osver."
				exit 1
			fi ;;
		*)
			ui_warn "ОС '$osid' не тестировалась (ожидается Debian 12/13 / Ubuntu 22.04+)."
			# Неинтерактивно (--unattended/без tty) не зависаем на вопросе — прерываем.
			if ((${UNATTENDED:-0})) || [[ ! -t 0 ]]; then
				ui_error "Неинтерактивный режим на нетестированной ОС — прерываю."; exit 1
			fi
			ui_confirm "Продолжить на свой риск?" n || exit 1 ;;
	esac
	OS_ID="$osid"; OS_VERSION="$osver"
	log "OS: $OS_ID $OS_VERSION"
}

# --- run_step: исполнение одного этапа с обработкой статуса/ошибок -----------
# run_step key stage_function
run_step() {
	local key="$1" fn="$2"
	local status
	status=$(state_get "$key")

	# Уже выполнен ранее
	if [[ "$status" == "done" && "${FORCE:-0}" != "1" ]]; then
		# В неинтерактивном режиме (--unattended или отсутствие tty) НЕ задаём
		# блокирующий вопрос: read из неподключённого stdin зависает «навсегда»
		# (так подвисал повторный --unattended-прогон). Пропускаем; повтор — --force.
		if ((${UNATTENDED:-0})) || [[ ! -t 0 ]]; then
			ui_info "Пропуск (уже выполнен): ${STAGE_LABELS[$key]}. Повторить этот этап: $(ls_hint --only "$key")"
			return 0
		fi
		if ! ui_confirm "Этап «${STAGE_LABELS[$key]}» уже выполнен. Выполнить заново?" n; then
			ui_info "Пропуск (уже выполнен): ${STAGE_LABELS[$key]}"
			return 0
		fi
	fi

	# Не выбран (optional, снят галочкой)
	if [[ "$status" == "skipped" ]]; then
		ui_info "Пропуск (не выбран): ${STAGE_LABELS[$key]}"
		return 0
	fi

	clear 2>/dev/null || true
	ui_progress_overview "$key"
	ui_header "${STAGE_LABELS[$key]}"
	log "=== ЭТАП: $key ==="
	apt_lock_wait_conf

	# Перечитываем setup.conf перед каждым этапом: предыдущие этапы могли записать
	# в него СГЕНЕРИРОВАННЫЕ секреты (MARIADB_ROOT_PW, ISPCONFIG_ADMIN_PW и т.п.).
	# Они пишутся в файл через config_set, но при полном прогоне в один процесс НЕ
	# попадают в окружение родителя: config_get_or_gen_password вызывается в $(...)
	# (subshell), а config_load отрабатывает лишь раз в начале main(). Без этого
	# повторного источника этап ISPConfig получал ПУСТОЙ MARIADB_ROOT_PW и падал
	# с «Access denied (using password: NO)».
	[[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE" 2>/dev/null || true

	# Исполняем функцию этапа; ошибки не должны ронять весь мастер
	local rc=0
	if "$fn"; then
		state_set "$key" "done"
		ui_success "Этап завершён: ${STAGE_LABELS[$key]}"
	else
		rc=$?
		state_set "$key" failed
		ui_error "Этап завершился с ошибкой ($rc): ${STAGE_LABELS[$key]}"
		log "ЭТАП $key завершился с ошибкой rc=$rc"
		# Неинтерактивно (--unattended/без tty): не показываем блокирующее меню.
		# Fail-fast — выходим, сохранив state=failed для продолжения через --resume.
		if ((${UNATTENDED:-0})) || [[ ! -t 0 ]]; then
			ui_error "Неинтерактивный режим — выход (rc=$rc). Продолжить после правок: $(ls_hint --resume)"
			exit "$rc"
		fi
		# Меню восстановления
		ui_menu "Что делать дальше?" 1 \
			"Повторить этап" \
			"Пропустить и продолжить" \
			"Выйти (продолжить позже через --resume)"
		case "$UI_MENU_CHOICE" in
			1) run_step "$key" "$fn"; return $? ;;
			2) state_set "$key" skipped; return 0 ;;
			3) ui_info "Выход. Продолжить потом: $(ls_hint --resume)"; exit "$rc" ;;
		esac
	fi
	return 0
}

# Пометить невыбранные optional-этапы как skipped (по списку COMPONENTS)
# apply_component_selection "mail dns ftp"  — выбранные optional-ключи
apply_component_selection() {
	local selected=" $1 " key
	for key in "${STAGE_KEYS[@]}"; do
		[[ "${STAGE_TYPE[$key]}" == "optional" ]] || continue
		if [[ "$selected" == *" $key "* ]]; then
			# выбран: если был skipped — вернуть в pending
			[[ "$(state_get "$key")" == "skipped" ]] && state_set "$key" pending
		else
			# не выбран: пометить skipped (если ещё не done)
			[[ "$(state_get "$key")" != "done" ]] && state_set "$key" skipped
		fi
	done
}

# --- Очистка лишних пакетов для выбранного стека (показать + спросить) --------
# Главный случай: WEBSERVER=nginx, но в системе оказался Apache + его модули
# (остатки прошлых попыток/переключений). Чтобы «не засирать систему».
# В новом дизайне под nginx pgAdmin не ставится → Apache и не появляется; это
# подстраховка. Если стоит pgadmin4-web — Apache ему НУЖЕН, не трогаем.
cleanup_unneeded() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} проверка лишних пакетов (apache при nginx и т.п.)"; return 0; }
	local ws="${WEBSERVER:-nginx}" cand=() p
	if [[ "$ws" == "nginx" ]]; then
		if dpkg -l pgadmin4-web 2>/dev/null | grep -q '^ii'; then
			ui_info "Очистка: установлен pgadmin4-web — Apache ему необходим, пропускаю."
			return 0
		fi
		for p in apache2 apache2-bin apache2-data \
		         libapache2-mod-php8.0 libapache2-mod-php8.1 libapache2-mod-php8.2 \
		         libapache2-mod-php8.3 libapache2-mod-php8.4 libapache2-mod-php \
		         libapache2-mod-fcgid libapache2-mod-wsgi-py3; do
			dpkg -l "$p" 2>/dev/null | grep -q '^ii' && cand+=("$p")
		done
	fi
	((${#cand[@]})) || { ui_info "Лишних пакетов для стека «${ws}» не найдено."; return 0; }

	ui_box_top "Лишние пакеты для стека «${ws}» (не нужны)"
	for p in "${cand[@]}"; do ui_box_line "  ${UI_Y}•${UI_NC} ${p}"; done
	ui_box_bottom
	# Неинтерактивно: только показываем (per «показать и спросить»), не удаляем.
	if ((${UNATTENDED:-0})) || [[ ! -t 0 ]]; then
		ui_warn "Неинтерактивный режим — НЕ удаляю. Вручную: apt purge ${cand[*]} && apt autoremove"
		return 0
	fi
	if ui_confirm "Удалить эти лишние пакеты (apt purge + autoremove)?" n; then
		export DEBIAN_FRONTEND=noninteractive
		# shellcheck disable=SC2086
		apt-get purge -y -qq "${cand[@]}" >>"$SETUP_LOG" 2>&1 || true
		apt-get autoremove -y -qq >>"$SETUP_LOG" 2>&1 || true
		ui_success "Лишние пакеты удалены, система подчищена."
	else
		ui_info "Очистка пропущена (пакеты оставлены)."
	fi
}

# --- Инвентаризация: что установлено и какие версии (--status / пункт меню) ---
_st_line() {  # _st_line "Метка" "версия" "сервис"
	local svc="$3" act="" s
	# ВАЖНО: без `|| echo` — systemctl is-active для 'activating' выходит с
	# ненулевым кодом, и `||` дописывал вторую строку, ломая рамку.
	if [[ -n "$svc" ]]; then
		s="$(systemctl is-active "$svc" 2>/dev/null | head -1)"
		act=" · ${s:-n/a}"
	fi
	ui_box_line "  ${UI_W}$1${UI_NC}: ${2:-—}${act}"
}
show_system_status() {
	# Грузим setup.conf, чтобы показать реальные значения (порт панели и т.п.),
	# а не дефолты — иначе панель показывалась как :8080 при фактическом :3333.
	config_load >/dev/null 2>&1 || true
	clear 2>/dev/null || true
	ui_header "Состояние системы — установленные компоненты и версии"
	local PRETTY_NAME=""; [[ -r /etc/os-release ]] && PRETTY_NAME="$(. /etc/os-release; echo "$PRETTY_NAME")"
	ui_box_top "ОС"; ui_box_line "  ${PRETTY_NAME:-?}"; ui_box_bottom

	ui_box_top "Веб-сервер"
	command -v nginx    >/dev/null 2>&1 && _st_line "nginx"   "$(nginx -v 2>&1 | sed 's#.*/##')" nginx
	command -v apache2  >/dev/null 2>&1 && _st_line "apache2" "$(apache2 -v 2>/dev/null | sed -n 's#.*Apache/\([0-9.]*\).*#\1#p' | head -1)" apache2
	{ command -v nginx >/dev/null 2>&1 || command -v apache2 >/dev/null 2>&1; } || ui_box_line "  ${UI_D}не установлен${UI_NC}"
	ui_box_bottom

	ui_box_top "PHP"
	local v had=0
	for v in /etc/php/*/; do
		v="$(basename "$v")"
		[[ -d "/etc/php/$v/fpm" ]] || continue
		had=1; _st_line "php${v}" "$("php${v}" -v 2>/dev/null | head -1 | sed 's/ (cli).*//')" "php${v}-fpm"
	done
	((had)) || ui_box_line "  ${UI_D}не установлен${UI_NC}"
	command -v php >/dev/null 2>&1 && ui_box_line "  ${UI_D}default php → $(php -v 2>/dev/null | head -1 | sed 's/ (cli).*//')${UI_NC}"
	ui_box_bottom

	ui_box_top "Базы данных"
	command -v mysql >/dev/null 2>&1 && _st_line "MariaDB"    "$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' | head -1)" mariadb
	command -v psql  >/dev/null 2>&1 && _st_line "PostgreSQL" "$(psql --version 2>/dev/null | grep -oE '[0-9.]+' | head -1)" postgresql
	command -v redis-server >/dev/null 2>&1 && _st_line "Redis" "$(redis-server --version 2>/dev/null | grep -oE 'v=[0-9.]+' | cut -d= -f2)" redis-server
	ui_box_bottom

	ui_box_top "Почта / антиспам"
	local _m=0
	command -v postfix >/dev/null 2>&1 && { _st_line "Postfix" "$(postconf -h mail_version 2>/dev/null)" postfix; _m=1; }
	command -v dovecot >/dev/null 2>&1 && { _st_line "Dovecot" "$(dovecot --version 2>/dev/null | awk '{print $1}')" dovecot; _m=1; }
	command -v rspamd  >/dev/null 2>&1 && { _st_line "Rspamd"  "$(rspamd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9.]+' | head -1)" rspamd; _m=1; }
	dpkg -l clamav-daemon 2>/dev/null | grep -q '^ii' && { _st_line "ClamAV" "$(clamd -V 2>/dev/null | grep -oE '[0-9.]+' | head -1)" clamav-daemon; _m=1; }
	((_m)) || ui_box_line "  ${UI_D}не установлено${UI_NC}"
	ui_box_bottom

	ui_box_top "Сервисы"
	command -v named >/dev/null 2>&1 && _st_line "BIND9 (DNS)" "$(named -v 2>/dev/null | awk '{print $2}')" named
	dpkg -l pure-ftpd-mysql 2>/dev/null | grep -q '^ii' && _st_line "PureFTPd" "$(dpkg-query -W -f='${Version}' pure-ftpd-mysql 2>/dev/null | grep -oE '^[0-9.]+')" pure-ftpd-mysql
	command -v monit >/dev/null 2>&1 && _st_line "Monit" "$(monit --version 2>/dev/null | grep -oE '[0-9.]+' | head -1)" monit
	command -v node  >/dev/null 2>&1 && _st_line "Node.js" "$(node -v 2>/dev/null)" ""
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] && \
		ui_box_line "  ${UI_W}ISPConfig${UI_NC}: $(grep -m1 ISPC_APP_VERSION /usr/local/ispconfig/server/lib/config.inc.php | grep -oE "'[^']*'" | tail -1 | tr -d "'") · панель :${ISPCONFIG_PANEL_PORT:-8080}"
	ui_box_bottom

	ui_box_top "Безопасность"
	local _s=0
	dpkg -l crowdsec 2>/dev/null | grep -q '^ii' && { _st_line "CrowdSec" "$(cscli version 2>/dev/null | grep -oiE 'v[0-9][0-9.]+' | head -1)" crowdsec; _s=1; }
	command -v ufw >/dev/null 2>&1 && { ui_box_line "  ${UI_W}UFW${UI_NC}: $(ufw status 2>/dev/null | sed -n 's/^Status: //p' | head -1)"; _s=1; }
	command -v fail2ban-client >/dev/null 2>&1 && { _st_line "fail2ban" "$(fail2ban-client --version 2>/dev/null | grep -oE '[0-9.]+' | head -1)" fail2ban; _s=1; }
	if command -v lynis >/dev/null 2>&1; then
		local _hi=""; [[ -f /var/log/lynis-report.dat ]] && _hi=" · hardening $(grep -a '^hardening_index=' /var/log/lynis-report.dat 2>/dev/null | tail -1 | cut -d= -f2)/100"
		ui_box_line "  ${UI_W}Lynis${UI_NC}: $(lynis show version 2>/dev/null | head -1)${_hi}"; _s=1
	fi
	command -v rkhunter >/dev/null 2>&1 && { _st_line "rkhunter" "$(rkhunter --version 2>/dev/null | grep -oE '[0-9]+\.[0-9.]+' | head -1)" ""; _s=1; }
	((_s)) || ui_box_line "  ${UI_D}не настроено${UI_NC}"
	ui_box_bottom

	ui_box_top "Веб-админки БД"
	local _a=0
	[[ -e /var/www/html/phpmyadmin ]]        && { ui_box_line "  phpMyAdmin → /phpmyadmin"; _a=1; }
	[[ -f /var/www/html/adminer/index.php ]] && { ui_box_line "  Adminer → /adminer/ (MariaDB + PostgreSQL)"; _a=1; }
	[[ -f /var/lib/pgadmin/pgadmin4.db ]]    && { ui_box_line "  pgAdmin → /pgadmin4"; _a=1; }
	((_a)) || ui_box_line "  ${UI_D}не установлены${UI_NC}"
	ui_box_bottom

	# --- Доступные обновления (помогает решить, нужно ли обновляться) ---
	ui_box_top "Обновления"
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		local _up; _up="$(LC_ALL=C apt-get -s upgrade 2>/dev/null | grep -c '^Inst')"
		ui_box_line "  Пакетов apt к обновлению: ${UI_W}${_up:-0}${UI_NC}   (обновить: apt update && apt upgrade)"
	fi
	if [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
		local _cfg=/usr/local/ispconfig/server/lib/config.inc.php _cur
		_cur="$(grep -m1 ISPC_APP_VERSION "$_cfg" 2>/dev/null | grep -oE "'[^']*'" | tail -1 | tr -d "'")"

		if [[ "$_cur" == *dev* || "${ISPCONFIG_BRANCH:-}" == "nightly" ]]; then
			# --- NIGHTLY: сравнение со stable бессмысленно (nightly свежее). Сверяем
			# ДАТУ установленной сборки с датой последней nightly (Last-Modified тарбола). ---
			local _inst_e _lat_e _lat_d _inst_d
			if [[ -n "${ISPCONFIG_INSTALL_DATE:-}" ]]; then _inst_e="$(date -d "$ISPCONFIG_INSTALL_DATE" +%s 2>/dev/null)"; fi
			[[ -z "${_inst_e:-}" ]] && _inst_e="$(stat -c %Y "$_cfg" 2>/dev/null)"
			if [[ "${DRY_RUN:-0}" != "1" ]] && command -v curl >/dev/null 2>&1; then
				local _lm; _lm="$(curl -fsSI --max-time 8 https://www.ispconfig.org/downloads/ISPConfig-3-nightly.tar.gz 2>/dev/null | grep -i '^last-modified:' | cut -d' ' -f2- | tr -d '\r')"
				[[ -n "$_lm" ]] && { _lat_e="$(date -d "$_lm" +%s 2>/dev/null)"; _lat_d="$(date -d "$_lm" '+%Y-%m-%d' 2>/dev/null)"; }
			fi
			[[ -n "${_inst_e:-}" ]] && _inst_d="$(date -d "@$_inst_e" '+%Y-%m-%d' 2>/dev/null)"
			if [[ -n "${_inst_e:-}" && -n "${_lat_e:-}" ]]; then
				if ((_lat_e > _inst_e + 86400)); then
					ui_box_line "  ISPConfig: ${UI_W}${_cur}${UI_NC} (nightly, установлен ${_inst_d}) → ${UI_Y}свежая сборка от ${_lat_d}${UI_NC} ${UI_D}(ispconfig_update.sh)${UI_NC}"
				else
					ui_box_line "  ISPConfig: ${UI_G}${_cur} (nightly, ${_inst_d}) — актуальная сборка${UI_NC}"
				fi
			else
				ui_box_line "  ISPConfig: ${UI_W}${_cur}${UI_NC} (nightly${_inst_d:+, ${_inst_d}})${_lat_d:+ · последняя nightly: ${_lat_d}} ${UI_D}(обновление: ispconfig_update.sh)${UI_NC}"
			fi
			# Исправления безопасности 3.3.2p1 (Remote API SQLi #7051, fetchmail #7052, reset-link #7044)
			# вошли в develop 2026-09-21. Признак — проверка ID в remoting.inc.php (#7051).
			if grep -q 'The ID has to be > 0' /usr/local/ispconfig/interface/lib/classes/remoting.inc.php 2>/dev/null; then
				ui_box_line "  ${UI_G}исправления безопасности 3.3.2p1 есть${UI_NC}"
			else
				ui_box_line "  ${UI_R}нет исправлений безопасности 3.3.2p1 (#7051 SQLi в Remote API) — обновите: $(ls_hint --update ispconfig)${UI_NC}"
			fi
		else
			# --- STABLE: сравнение версии с актуальной стабильной ---
			local _lat
			if [[ "${DRY_RUN:-0}" != "1" ]] && command -v curl >/dev/null 2>&1; then
				_lat="$(curl -fsS --max-time 8 https://www.ispconfig.org/downloads/ispconfig3_version.txt 2>/dev/null | tr -d ' \r\n')"
			fi
			if [[ -n "$_cur" && -n "${_lat:-}" ]]; then
				if [[ "$_cur" == "$_lat" ]]; then
					ui_box_line "  ISPConfig: ${UI_G}${_cur} — актуальная версия${UI_NC}"
				else
					ui_box_line "  ISPConfig: ${UI_W}${_cur}${UI_NC} → доступна ${UI_Y}${_lat}${UI_NC} ${UI_D}(обновление через панель Tools)${UI_NC}"
				fi
			else
				ui_box_line "  ISPConfig${_cur:+ ${_cur}}: обновление через панель (Tools) или ${UI_D}ispconfig_update.sh${UI_NC}"
			fi
		fi
	fi
	ui_box_bottom
}

# =============================================================================
# IPv6 — единая «истина» по серверу. Источник: SERVER_HAS_IPV6 в setup.conf
# (выставляет preflight через _detect_ipv6, переопределяемо вручную). Любые
# IPv6-зависимые фиксы (named -4, проверки портов и т.п.) должны спрашивать ТУТ,
# а не детектить каждый по-своему. Фоллбэк — живой детект (глобальный адрес+маршрут).
# =============================================================================

# 0 = у сервера есть рабочий (маршрутизируемый) IPv6; 1 = нет.
_has_ipv6() {
	case "${SERVER_HAS_IPV6:-}" in
		y|yes|1) return 0 ;;
		n|no|0)  return 1 ;;
	esac
	# флаг не задан — живой детект: нужен И глобальный адрес, И default-маршрут v6
	ip -6 addr show scope global 2>/dev/null | grep -q "inet6" \
		&& ip -6 route show default 2>/dev/null | grep -q . 
}

# Определить факт IPv6 и записать в setup.conf (SERVER_HAS_IPV6=y|n). Уважает уже
# заданное значение (ручной оверрайд/прошлый прогон). Зовётся из preflight.
_detect_ipv6() {
	[[ -n "${SERVER_HAS_IPV6:-}" ]] && { log "ipv6: SERVER_HAS_IPV6=${SERVER_HAS_IPV6} (задано — не меняю)"; return 0; }
	local v6=n
	if ip -6 addr show scope global 2>/dev/null | grep -q "inet6" \
	   && ip -6 route show default 2>/dev/null | grep -q . ; then
		v6=y
	fi
	declare -F config_set >/dev/null && config_set SERVER_HAS_IPV6 "$v6"
	export SERVER_HAS_IPV6="$v6"
	if [[ "$v6" == y ]]; then
		ui_info "IPv6 на сервере: есть (глобальный адрес + маршрут) — IPv6-зависимые фиксы в обычном режиме."
	else
		ui_info "IPv6 на сервере: нет → IPv6-зависимые фиксы переводятся в IPv4-режим (напр. named -4)."
	fi
	log "ipv6: SERVER_HAS_IPV6=${v6} (автодетект)"
	return 0
}

# IPv6-адрес и маршрут есть, а наружу соединения не проходят: так бывает у хостеров.
# Тогда wget, PHP и Postfix сначала ждут IPv6 до таймаута (ключ Sury, Composer, письма
# на ящики с IPv6). Интерфейсы не трогаем: выключенный IPv6 при секции inet6 в
# /etc/network/interfaces может уронить сеть после перезагрузки. Вместо этого просим
# систему ходить по IPv4 первым (/etc/gai.conf), а Postfix отправлять по IPv4.
# Если хостер IPv6 починил, повторный запуск убирает нашу строку.
IPV6_GAI_MARK='# luckystack: ipv4-first'

# 0 = IPv6 наружу работает, 1 = не работает, 2 = проверить нечем (нет IPv6 или DNS).
_ipv6_egress_ok() {
	ip -6 addr show scope global 2>/dev/null | grep -q inet6 && ip -6 route show default 2>/dev/null | grep -q . || return 2
	local h a tried=0
	for h in deb.debian.org www.google.com one.one.one.one; do
		# ::ffff:… это IPv4 под видом IPv6, такое соединение пошло бы по IPv4
		a="$(getent ahostsv6 "$h" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1; exit}')"
		[[ -n "$a" ]] || continue
		tried=1
		timeout 6 bash -c "exec 3<>/dev/tcp/${a}/443" 2>/dev/null && return 0
	done
	((tried)) && return 1
	return 2
}

_ipv6_egress_fix() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	local f=/etc/gai.conf rc
	_ipv6_egress_ok; rc=$?
	if ((rc == 1)); then
		if ! grep -qsxF "$IPV6_GAI_MARK" "$f"; then
			[[ -f "$f" && ! -f "$f.luckystack.bak" ]] && cp -a "$f" "$f.luckystack.bak"
			printf '%s\nprecedence ::ffff:0:0/96  100\n' "$IPV6_GAI_MARK" >>"$f"
		fi
		ui_warn "IPv6-адрес у сервера есть, но наружу по IPv6 соединения не проходят (это у хостера). Система будет ходить по IPv4 первой (/etc/gai.conf), чтобы загрузки и почта не ждали таймаутов."
		log "ipv6: наружу не работает, ipv4-first в $f"
		if [[ -z "${SERVER_HAS_IPV6:-}" ]]; then
			declare -F config_set >/dev/null && config_set SERVER_HAS_IPV6 n
			export SERVER_HAS_IPV6=n
		fi
	elif ((rc == 0)) && grep -qsxF "$IPV6_GAI_MARK" "$f"; then
		sed -i "\|^${IPV6_GAI_MARK}\$|{N;d}" "$f"
		ui_info "IPv6 наружу снова работает, строку ipv4-first из /etc/gai.conf убрал."
		log "ipv6: наружу работает, ipv4-first убран"
	fi
	return 0
}

# Postfix: при нерабочем IPv6 отправлять по IPv4 (иначе письма на ящики с IPv6 ждут таймаутов).
_ipv6_postfix_prefer_v4() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	command -v postconf >/dev/null 2>&1 && [[ -f /etc/postfix/main.cf ]] || return 0
	grep -qsxF "$IPV6_GAI_MARK" /etc/gai.conf || return 0
	[[ "$(postconf -h smtp_address_preference 2>/dev/null)" == "ipv4" ]] && return 0
	postconf -e 'smtp_address_preference = ipv4' >>"$SETUP_LOG" 2>&1 \
		&& systemctl reload postfix >>"$SETUP_LOG" 2>&1 \
		&& ui_info "Postfix: исходящие письма по IPv4 (IPv6 у хостера наружу не работает)."
	return 0
}
