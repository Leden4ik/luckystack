#!/bin/bash
# =============================================================================
# server-setup.sh — движок LuckyStack: установка и обслуживание сервера хостинга.
# Ставит стек: nginx из исходников + PHP (несколько версий, FPM) + MariaDB (опц.
# PostgreSQL) + почта (Postfix/Dovecot/Rspamd) + DNS (BIND) + FTP (PureFTPd) + SSL
# (Let's Encrypt) + firewall + Roundcube + панель ISPConfig и наши дополнения к ней.
#
# Пошаговый мастер, сохранение прогресса и продолжение с места обрыва (--resume).
# Обычно запускается через команду luckyctl (код лежит в /opt/luckystack/current).
#
#   Запуск:    sudo luckyctl          (или sudo ./server-setup.sh из распакованного архива)
#   Ключи:     ./server-setup.sh --help
# =============================================================================

set -uo pipefail

# Файлы создаём с обычными правами независимо от umask того, кто запустил. С umask 077 (жёсткий
# профиль root) ключ репозитория выходил 600, apt его не читал, и установка падала на этапе PHP,
# а конфиги и исходники становились закрытыми для служб. Секреты защищены своими chmod и (umask 077).
umask 022

# Рамки и выравнивание зависят от того, что bash считает длину строки в СИМВОЛАХ,
# а не в байтах — для этого оболочке нужна применённая UTF-8-локаль (одного лишь
# LC_CTYPE=*.UTF-8 в окружении бывает недостаточно). Принудительно выставляем
# LC_ALL на первую доступную UTF-8-локаль; предпочитаем текущую, если она UTF-8.
_pick_utf8_locale() {
	local avail cur loc
	avail=$(locale -a 2>/dev/null)
	cur="${LC_ALL:-${LANG:-}}"
	# Доверяем текущей локали ТОЛЬКО если она UTF-8 И реально присутствует в системе.
	# Минимальные образы Debian/WSL выставляют LANG=en_US.UTF-8 без генерации самой
	# локали — слепое доверие давало «setlocale: cannot change locale» и ломало
	# подсчёт ширины кириллицы (рамки разъезжались, padding считался в байтах).
	if [[ "$cur" =~ [Uu][Tt][Ff]-?8 ]] && printf '%s\n' "$avail" | grep -qiFx "$cur"; then
		echo "$cur"; return
	fi
	for loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 ru_RU.UTF-8 ru_RU.utf8; do
		if printf '%s\n' "$avail" | grep -qiFx "$loc"; then echo "$loc"; return; fi
	done
	# последний шанс: любая *.utf8 из системы
	printf '%s\n' "$avail" | grep -iE 'utf-?8$' | head -n1
}
_utf8_locale="$(_pick_utf8_locale)"
[[ -n "$_utf8_locale" ]] && export LC_ALL="$_utf8_locale"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
LS_ORIG_ARGS=("$@")

# Где настройки, состояние и журнал (код в /opt/luckystack, см. lib/layout.sh).
: "${LS_OPT_DIR:=/opt/luckystack}" "${LS_ETC_DIR:=/etc/luckystack}" "${LS_VAR_DIR:=/var/lib/luckystack}" "${LS_LOG_DIR:=/var/log/luckystack}"
CONFIG_FILE="$LS_ETC_DIR/setup.conf"
STATE_FILE="$LS_VAR_DIR/setup.state"
SETUP_LOG="$LS_LOG_DIR/setup.log"
if [[ $EUID -eq 0 ]]; then
	install -d -m 700 -o root -g root "$LS_ETC_DIR" "$LS_VAR_DIR" "$LS_LOG_DIR" 2>/dev/null || true
fi

VERSION="0.1.1"

# --- Флаги -------------------------------------------------------------------
DRY_RUN=0          # этапы-заглушки имитируют работу, без изменений в системе
DO_RESUME=0        # продолжить прерванную установку
DO_RECONFIGURE=0   # заново задать setup.conf
UNATTENDED=0       # без вопросов, использовать существующий setup.conf
FORCE=0            # выполнять даже done-этапы без вопроса
START_FROM=""      # начать с конкретного этапа
ONLY_STAGE=""      # выполнить РОВНО один этап и выйти
DO_UNINSTALL=0     # режим удаления компонентов
CLEAN_BUILD=0      # очистить кеш сборки (исходники прошлых попыток) перед стартом
DO_STATUS=0        # показать инвентаризацию (что установлено + версии) и выйти
DO_HEALTHCHECK=0   # проверить здоровье сервера (сервисы/порты/TLS/панель) и выйти
DO_DIAGNOSTICS=0   # собрать обезличенный архив диагностики для поддержки и выйти
DO_RESTORE=0       # восстановление из резервной копии (интерактивно) и выйти
DO_UPDATE=0        # режим обновления/патчей (безопасно, без ядра) и выйти
DO_ADOPT=0         # adopt-режим: аддоны на уже установленный (ручной) сервер и выйти
DO_PHP_REMOVE=0    # режим удаления выбранных версий PHP (интерактивно) и выйти
DO_ROLLBACK=0      # вернуть прошлую версию nginx или Roundcube
ROLLBACK_TARGET=""
DO_PHP_ADD=0       # доустановить версии PHP (интерактивно или --add-php 8.5) и выйти
PHP_ADD_ARG=""     # версия для --add-php (пусто — выбор из списка)
DO_TIMEZONE=0      # сменить часовой пояс везде (система, PHP, MariaDB, cron) и выйти
TZ_ARG=""          # зона для --timezone (пусто — спросить)
DO_SELF_UPDATE=0   # обновить сам установщик с GitHub (git/curl) и выйти
DO_CHECK_UPDATE=0  # сверить версию с GitHub (без изменений) и выйти
DO_INSTALL_CODE=0  # поставить эту копию кода новым выпуском в /opt/luckystack
PURGE_DATA=n       # удалять ли ДАННЫЕ при --uninstall (set -u: инициализируем явно)

usage() {
	# Язык справки: по умолчанию русский (как весь установщик); English — только явно
	# через --lang en или UI_LANG=en. НЕ смотрим $LANG окружения: у VDS он часто en_US.UTF-8,
	# а аудитория установщика русскоязычная — иначе справка молча уходила бы в EN.
	local _l="${UI_LANG_ARG:-${UI_LANG:-ru}}"
	if [[ "$_l" == en ]]; then
		cat <<EOF
LuckyStack v$VERSION, server installer

  sudo luckyctl                      main menu (after install; see luckyctl help)
  sudo ./server-setup.sh [flags]     the same engine with flags

Flags:
  --resume         Continue an interrupted install from the first unfinished stage
  --reconfigure    Re-run the setup wizard (overwrite setup.conf)
  --unattended     No questions: use the existing setup.conf
  --dry-run        Demo mode: stages only simulate work (for UI debugging)
  --force          Re-run even already-completed stages
  --from <stage>   Start from the given stage and continue to the end
  --only <stage>   Run EXACTLY one stage and exit (install a single component:
                   webserver, php, database, monit, ssl, …)
  --uninstall      Component removal mode (full/partial)
  --purge          Removal together with DATA (DB/mail/sites) — IRREVERSIBLE
  --clean-build    Clear the build cache (nginx/ISPConfig sources of past attempts)
  --status         Show what is installed and which versions (and exit)
  --healthcheck    Check server health (services, ports, TLS, panel) and exit
  --diagnostics    Collect an anonymized diagnostics bundle for support and exit
  --restore        Restore data from a backup (interactive)
  --update         Update/patch mode: update packages + re-apply additive
                   improvements WITHOUT touching the core (for an already-set-up server)
  --rollback X     Return the previous version: nginx, roundcube or luckystack (repeat to undo)
  --adopt          Attach our add-ons to a THIRD-PARTY-installed server (manual/guided):
                   backup + confirmation, server-agnostic only, ISPConfig core/templates
                   are not touched
  --add-php [X.Y]  Install another PHP version (FPM + modules, time zone, secure defaults,
                   registered in ISPConfig). Without X.Y — pick interactively
  --remove-php     Remove SELECTED PHP versions (interactive, with guards: won't remove
                   the panel/CLI-default/site-used version; cleans apt + ISPConfig)
  --timezone [TZ]  Change the time zone everywhere: system, every PHP version (FPM and
                   CLI), MariaDB, cron, logs. Without TZ — asks interactively
  --lang <code>    CLI interface language (ru by default; en). ISPConfig panels
                   are bilingual independently
  --check-update   Compare the LuckyStack version with the repository (no changes)
  --self-update    Download the latest LuckyStack and install it as a new release
  --install-code   Install this copy of the code as a new release in /opt/luckystack
  --help           This help
EOF
		return 0
	fi
	cat <<EOF
LuckyStack v$VERSION, установщик сервера

  sudo luckyctl                      главное меню (после установки; команды: luckyctl help)
  sudo ./server-setup.sh [флаги]     тот же движок с ключами

Флаги:
  --resume         Продолжить прерванную установку с первого незавершённого этапа
  --reconfigure    Заново пройти мастер настройки (перезаписать setup.conf)
  --unattended     Без вопросов: использовать готовый setup.conf
  --dry-run        Демо-режим: этапы только имитируют работу (для отладки UI)
  --force          Выполнять заново даже уже завершённые этапы
  --from <stage>   Начать с указанного этапа и идти дальше до конца
  --only <stage>   Выполнить РОВНО один этап и выйти (отдельная установка
                   компонента: webserver, php, database, monit, ssl, …)
  --uninstall      Режим удаления компонентов (полное/частичное)
  --purge          Удаление вместе с ДАННЫМИ (БД/почта/сайты) — НЕОБРАТИМО
  --clean-build    Очистить кеш сборки (исходники nginx/ISPConfig прошлых попыток)
  --status         Показать, что уже установлено и какие версии (и выйти)
  --healthcheck    Проверить здоровье сервера (сервисы, порты, TLS, панель) и выйти
  --diagnostics    Собрать обезличенный архив диагностики для поддержки и выйти
  --restore        Восстановить данные из резервной копии (интерактивно)
  --update         Режим обновления/патчей: обновить пакеты + переприменить
                   аддитивные улучшения, НЕ трогая ядро (для уже настроенного сервера)
  --rollback X     Вернуть прошлую версию: nginx, roundcube или luckystack (повтор отменяет откат)
  --adopt          Подключить наши аддоны к СТОРОННЕ установленному серверу (вручную/по
                   гайду): бэкап + подтверждение, только server-agnostic, ядро/шаблоны
                   ISPConfig не трогаются
  --add-php [X.Y]  Доустановить версию PHP (FPM + модули, часовой пояс, безопасные настройки,
                   регистрация в ISPConfig). Без версии — выбор из списка
  --remove-php     Удалить ВЫБРАННЫЕ версии PHP (интерактивно, с защитой: не даёт снести
                   версию панели/CLI-дефолт/используемую сайтом; чистит apt + ISPConfig)
  --timezone [пояс] Сменить часовой пояс везде: система, все версии PHP (FPM и CLI),
                   MariaDB, cron, журналы. Без пояса — спросит
  --lang <код>     Язык интерфейса CLI (ru по умолч.; en). Панели ISPConfig
                   двуязычны независимо
  --check-update   Сверить версию LuckyStack с репозиторием (без изменений)
  --self-update    Скачать свежий LuckyStack и поставить его новым выпуском
  --install-code   Поставить эту копию кода новым выпуском в /opt/luckystack
  --help           Эта справка
EOF
}

while (($#)); do
	case "$1" in
		--resume)      DO_RESUME=1 ;;
		--reconfigure) DO_RECONFIGURE=1 ;;
		--unattended)  UNATTENDED=1 ;;
		--dry-run)     DRY_RUN=1 ;;
		--force)       FORCE=1 ;;
		--from)        START_FROM="${2:-}"; shift ;;
		--only)        ONLY_STAGE="${2:-}"; shift ;;
		--uninstall|--remove) DO_UNINSTALL=1 ;;
		--purge)       DO_UNINSTALL=1; PURGE_DATA=y ;;
		--clean-build) CLEAN_BUILD=1 ;;
		--status)      DO_STATUS=1 ;;
		--healthcheck) DO_HEALTHCHECK=1 ;;
		--diagnostics) DO_DIAGNOSTICS=1 ;;
		--restore)     DO_RESTORE=1 ;;
		--update)      DO_UPDATE=1 ;;
		--rollback)    DO_ROLLBACK=1; if [[ -n "${2:-}" && "${2:-}" != --* ]]; then ROLLBACK_TARGET="$2"; shift; fi ;;
		--adopt)       DO_ADOPT=1 ;;
		--add-php)     DO_PHP_ADD=1; if [[ "${2:-}" =~ ^[0-9]+\.[0-9]+$ ]]; then PHP_ADD_ARG="$2"; shift; fi ;;
		--remove-php)  DO_PHP_REMOVE=1 ;;
		--timezone)    DO_TIMEZONE=1; if [[ -n "${2:-}" && "${2:-}" != --* ]]; then TZ_ARG="$2"; shift; fi ;;
		--self-update) DO_SELF_UPDATE=1 ;;
		--check-update) DO_CHECK_UPDATE=1 ;;
		--install-code) DO_INSTALL_CODE=1 ;;
		--lang)        UI_LANG_ARG="${2:-}"; shift ;;
		--help|-h)     usage; exit 0 ;;
		*) echo "Неизвестный флаг: $1"; usage; exit 1 ;;
	esac
	shift
done

# --- Валидация взаимоисключающих режимов/флагов ------------------------------
# (до загрузки библиотек — поэтому обычный echo, а не ui_*)
_modes=0
for _m in "$DO_STATUS" "$DO_HEALTHCHECK" "$DO_DIAGNOSTICS" "$DO_RESTORE" "$DO_UPDATE" "$DO_ROLLBACK" "$DO_ADOPT" "$DO_UNINSTALL" "$DO_PHP_REMOVE" "$DO_PHP_ADD" "$DO_TIMEZONE" "$DO_SELF_UPDATE" "$DO_CHECK_UPDATE" "$DO_INSTALL_CODE"; do
	(( _m )) && (( _modes++ ))
done
if (( _modes > 1 )); then
	echo "Ошибка: несколько взаимоисключающих режимов (--status/--healthcheck/--restore/--update/--uninstall|--purge) — оставьте один." >&2
	exit 1
fi
if (( _modes == 1 )) && { [[ -n "$ONLY_STAGE" || -n "$START_FROM" ]] || (( DO_RESUME || DO_RECONFIGURE || UNATTENDED )); }; then
	echo "Ошибка: режим (--status/--healthcheck/--restore/--update/--uninstall) нельзя совмещать с --only/--from/--resume/--reconfigure/--unattended." >&2
	exit 1
fi
if [[ -n "$ONLY_STAGE" && -n "$START_FROM" ]]; then
	echo "Ошибка: --only и --from взаимоисключающи." >&2; exit 1
fi
if (( DO_RESUME )) && { [[ -n "$ONLY_STAGE" || -n "$START_FROM" ]] || (( DO_RECONFIGURE )); }; then
	echo "Ошибка: --resume нельзя совмещать с --only/--from/--reconfigure." >&2; exit 1
fi
if (( DO_RECONFIGURE )) && [[ -n "$ONLY_STAGE" || -n "$START_FROM" ]]; then
	echo "Ошибка: --reconfigure нельзя совмещать с --only/--from." >&2; exit 1
fi

# --- Подключение библиотек ---------------------------------------------------
if [[ ! -f "$LIB_DIR/ui.sh" || ! -f "$LIB_DIR/core.sh" ]]; then
	echo "Ошибка: не найдены lib/ui.sh и lib/core.sh рядом со скриптом." >&2
	exit 1
fi
# shellcheck source=lib/ui.sh
. "$LIB_DIR/ui.sh"
# shellcheck source=lib/core.sh
. "$LIB_DIR/core.sh"
# Каркас i18n (t()/языковые файлы). Грузим сразу после ui/core, до этапных модулей,
# чтобы t() был доступен везде. Язык применим ниже (после разбора --lang и config_load).
[[ -f "$LIB_DIR/i18n.sh" ]] && . "$LIB_DIR/i18n.sh"
# Раскладка на сервере: /opt, /etc, /var, команда luckyctl, выпуски и откат.
[[ -f "$LIB_DIR/layout.sh" ]] && . "$LIB_DIR/layout.sh"
# Само-обновление установщика с GitHub (--self-update / --check-update).
[[ -f "$LIB_DIR/selfupdate.sh" ]] && . "$LIB_DIR/selfupdate.sh"
[[ -n "${UI_LANG_ARG:-}" ]] && UI_LANG="$UI_LANG_ARG"
type i18n_load >/dev/null 2>&1 && i18n_load "${UI_LANG:-ru}"

# Этапы, реализованные в отдельных native-модулях. Подключаем те, что существуют;
# для ещё не реализованных этапов остаются заглушки ниже.
# nginx.sh/apache.sh подключаются до webserver.sh (он диспетчеризует к ним).
for _stage_lib in preflight database nginx apache webserver php nodejs dbtools monit \
                   mail rspamd dns ftp ssl security webmail ispconfig \
                   hostcert rcplugins maildeliver mailsni tuning backup malware notify \
                   update healthcheck uninstall; do
	[[ -f "$LIB_DIR/${_stage_lib}.sh" ]] && . "$LIB_DIR/${_stage_lib}.sh"
done

# =============================================================================
# РЕЕСТР ЭТАПОВ
# register_stage key "Метка" core|optional
# Порядок здесь = порядок выполнения.
# =============================================================================
register_stage preflight  "1. Подготовка системы (FQDN, время, обновления)" core
register_stage database   "2. База данных (MariaDB + Redis)"                 core
register_stage webserver  "3. Веб-сервер (nginx / Apache)"                   core
register_stage php        "4. PHP (мульти-версии, FPM)"                      core
register_stage nodejs     "5. Node.js (NodeSource)"                          optional
register_stage phpmyadmin "6. phpMyAdmin (веб-админка MariaDB)"              optional
register_stage postgresql "7. PostgreSQL + pgAdmin"                          optional
register_stage mail       "8. Почта (Postfix + Dovecot)"                     optional
register_stage rspamd     "9. Антиспам (Rspamd + ClamAV)"                    optional
register_stage dns        "10. DNS-сервер (BIND)"                            optional
register_stage ftp        "11. FTP + квоты (PureFTPd)"                        optional
register_stage ssl        "12. SSL-сертификаты (Let's Encrypt)"              core
register_stage security   "13. Безопасность (firewall, fail2ban, Lynis-аудит)"  optional
register_stage monit      "14. Мониторинг (Monit, интеграция с ISPConfig)"  optional
register_stage webmail    "15. Webmail + статистика (RoundCube)"             optional
register_stage ispconfig  "16. ISPConfig (панель управления)"               core
register_stage hostcert   "17. LE-сертификат хоста (панель + почта)"         optional
register_stage rcplugins  "18. Плагины ISPConfig для Roundcube (self-service)" optional
register_stage maildeliver "19. Доставляемость почты (TLS + DNS-записи)"     optional
register_stage mailsni    "20. Per-domain TLS почты (SNI из Let's Encrypt)"  optional
register_stage tuning     "21. Авто-тюнинг под железо (MariaDB/PHP/Postfix)" optional
register_stage backup     "22. Резервное копирование (БД + конфиги, cron)"   optional
register_stage malware    "23. Анти-malware (rkhunter + LMD, скан + alert)"  optional

# =============================================================================
# Все этапы реализованы в lib/*.sh (preflight, database, nginx/apache, php,
# nodejs, dbtools, monit, mail, rspamd, dns, ftp, ssl, security, webmail,
# ispconfig) и подключены через цикл загрузки выше. Заглушек больше нет.
# =============================================================================

# =============================================================================
# Выбор модулей nginx (профили + кастомный чеклист) → NGX_* в setup.conf
# =============================================================================
# Все поддерживаемые native-сборкой модули (ключ = суффикс переменной NGX_*).
NGINX_ALL_MODULES="HTTP3 BROTLI ZSTD PCRE2 ZLIBNG HEADERMOD CACHEPURGE SETMISC VTS JEMALLOC NATIVE_OPT"

_apply_nginx_profile() {
	local p="$1" m
	declare -A f=( [HTTP3]=n [BROTLI]=n [ZSTD]=n [PCRE2]=y [ZLIBNG]=n [HEADERMOD]=n \
	               [CACHEPURGE]=n [SETMISC]=n [VTS]=n [JEMALLOC]=n [NATIVE_OPT]=n )
	case "$p" in
		recommended) f[HTTP3]=y f[BROTLI]=y f[ZSTD]=y f[ZLIBNG]=y f[HEADERMOD]=y \
		             f[CACHEPURGE]=y f[SETMISC]=y f[JEMALLOC]=y ;;
		full) f[HTTP3]=y f[BROTLI]=y f[ZSTD]=y f[ZLIBNG]=y f[HEADERMOD]=y \
		      f[CACHEPURGE]=y f[SETMISC]=y f[VTS]=y f[JEMALLOC]=y f[NATIVE_OPT]=y ;;
		minimal) : ;;   # только PCRE2=y (из дефолтов выше)
	esac
	for m in $NGINX_ALL_MODULES; do config_set "NGX_$m" "${f[$m]}"; done
	config_set NGINX_PROFILE "$p"
	ui_success "Профиль nginx: ${p}"
}

_wizard_nginx_custom() {
	ui_checklist "Модули nginx (сборка из исходников)" \
		"HTTP3,BROTLI,ZSTD,PCRE2,ZLIBNG,HEADERMOD,CACHEPURGE,SETMISC,JEMALLOC" \
		HTTP3      "HTTP/3 (QUIC) — требует pre-build OpenSSL (+время сборки)" \
		BROTLI     "Brotli — сжатие Google (эффективнее gzip)" \
		ZSTD       "zstd — очень быстрое сжатие (Facebook)" \
		PCRE2      "PCRE2 + JIT — ускоренные регулярные выражения" \
		ZLIBNG     "zlib-ng — ускоренный gzip" \
		HEADERMOD  "Headers-More — гибкое управление заголовками" \
		CACHEPURGE "ngx_cache_purge — точечная очистка кэша" \
		SETMISC    "set-misc (+devel-kit) — доп. директивы (uri encode и пр.)" \
		VTS        "VTS — страница статистики трафика/соединений" \
		JEMALLOC   "jemalloc — аллокатор памяти (меньше фрагментации)" \
		NATIVE_OPT "march=native + LTO — быстрее, но бинарь привязан к CPU"
	local sel m
	sel=" $UI_CHECK_RESULT "
	for m in $NGINX_ALL_MODULES; do
		if [[ "$sel" == *" $m "* ]]; then config_set "NGX_$m" y; else config_set "NGX_$m" n; fi
	done
	config_set NGINX_PROFILE custom
	ui_success "Профиль nginx: custom ($(echo "$UI_CHECK_RESULT" | wc -w) модулей)"
}

# =============================================================================
# МАСТЕР НАСТРОЙКИ (запись в setup.conf)
# =============================================================================
run_wizard() {
	clear 2>/dev/null || true
	ui_header "Мастер настройки сервера"
	echo -e "${UI_D}Ответы сохраняются в setup.conf и переиспользуются при --resume.${UI_NC}"

	config_init_header

	# Язык уже выбран при первом запуске (_ensure_language) и сохранён в setup.conf —
	# здесь повторно не спрашиваем; фиксируем текущий выбор. Сменить: --lang <код>.
	config_set UI_LANG "${UI_LANG:-ru}"

	# --- Веб-сервер ---
	# Apache в мастере скрыт до выпуска с полноценной поддержкой (усиление, WAF, тюнинг).
	# Код Apache на месте: выбор показывается с LS_APACHE=1 (наши тесты) и на сервере,
	# который уже стоит на Apache (перенастройка не должна молча сменить веб-сервер).
	if [[ "${LS_APACHE:-0}" == 1 || "${WEBSERVER:-}" == apache ]]; then
		ui_box_top "Веб-сервер"
		ui_box_line "Оба варианта работают с ISPConfig и PHP-FPM. Не уверены — выберите nginx."
		ui_box_bottom
		ui_menu "Выбор веб-сервера" 1 \
			"nginx  — быстрый, современный; собирается из исходников (HTTP/3, Brotli) — ставится дольше" \
			"Apache — классический, проще; ставится из пакетов, поддержка .htaccess — ставится быстрее"
		case "$UI_MENU_CHOICE" in
			1) config_set WEBSERVER nginx ;;
			2) config_set WEBSERVER apache ;;
		esac
	else
		config_set WEBSERVER nginx
		ui_info "Веб-сервер: nginx, собирается из исходников (HTTP/3, Brotli)."
	fi

	# --- nginx: канал + профиль сборки + модули ---
	if [[ "$WEBSERVER" == "nginx" ]]; then
		ui_menu "Какую версию nginx собирать" 1 \
			"stable — проверенная стабильная (рекомендуется)" \
			"mainline — новее, свежие возможности (чуть менее обкатана)"
		[[ "$UI_MENU_CHOICE" == "2" ]] && config_set NGINX_CHANNEL mainline || config_set NGINX_CHANNEL stable

		ui_menu "Набор возможностей nginx (профиль сборки)" 1 \
			"Рекомендуемый — оптимально для большинства (HTTP/3, сжатие Brotli/zstd, ускорения)" \
			"Минимальный — только база, без доп. модулей (сборка быстрее)" \
			"Полный — рекомендуемый + статистика трафика (VTS) + оптимизация под ваш CPU" \
			"Свой — отметить модули вручную"
		case "$UI_MENU_CHOICE" in
			1) _apply_nginx_profile recommended ;;
			2) _apply_nginx_profile minimal ;;
			3) _apply_nginx_profile full ;;
			4) _wizard_nginx_custom ;;
		esac
		_nginx_ask_openssl_branch
	fi

	# --- GeoIP2 (только nginx; требует учётной записи MaxMind) ---
	# Ключ MaxMind вводится здесь, в процессе установки, а не берётся из файла.
	if [[ "$WEBSERVER" == "nginx" ]]; then
		ui_box_top "GeoIP2 — определение страны по IP (геоблокировка, гео-логи)"
		ui_box_line "Необязательно. Нужно, если хотите блокировать/различать страны."
		ui_box_line "Требуется бесплатный аккаунт MaxMind GeoLite2 и лицензионный ключ:"
		ui_box_line "${UI_C}https://www.maxmind.com/en/accounts/current/license-key${UI_NC}"
		ui_box_bottom
		if ui_confirm "Включить GeoIP2?" n; then
			config_set GEOIP y
			ui_input "MaxMind Account ID" "${GEOIP2_ACCOUNT_ID:-}"
			config_set GEOIP2_ACCOUNT_ID "$UI_INPUT"
			ui_input "MaxMind License Key" "${GEOIP2_LICENSE_KEY:-}"
			config_set GEOIP2_LICENSE_KEY "$UI_INPUT"
			if [[ -z "$GEOIP2_ACCOUNT_ID" || -z "$GEOIP2_LICENSE_KEY" ]]; then
				ui_warn "Учётные данные MaxMind пусты — GeoIP2 не сможет скачать базы."
			fi
		else
			config_set GEOIP n
			config_set GEOIP2_ACCOUNT_ID ""
			config_set GEOIP2_LICENSE_KEY ""
		fi
	fi

	# --- PHP-версии ---
	# Нативная версия дистрибутива — на ней РАБОТАЕТ ПАНЕЛЬ ISPConfig (её FPM обязателен,
	# иначе панель = 502). Помечаем её в списке, предвыбираем и гарантированно добавляем
	# ниже, даже если пользователь снял галочку. Определяем по релизу (sury перебивает `php`).
	local _native_php; _native_php="$(_distro_native_php)"
	local -a _phpitems=(); local _vv _lbl
	for _vv in 8.5 8.4 8.3 8.2 8.1 8.0 7.4; do
		_lbl="PHP $_vv"
		[[ "$_vv" == "8.3" ]] && _lbl+=" (рекомендуется)"
		[[ "$_vv" == "7.4" ]] && _lbl+=" (legacy)"
		[[ -n "$_native_php" && "$_vv" == "$_native_php" ]] && _lbl+=" — нужна панели ISPConfig"
		_phpitems+=("$_vv" "$_lbl")
	done
	ui_checklist "Версии PHP для установки (FPM)" "8.3${_native_php:+,$_native_php}" "${_phpitems[@]}"
	# Гарантия: нативная версия панели ВСЕГДА в списке (иначе панель ISPConfig отдаст 502).
	local _phpsel="$UI_CHECK_RESULT"
	if [[ -n "$_native_php" && " $_phpsel " != *" $_native_php "* ]]; then
		_phpsel="${_phpsel:+$_phpsel }$_native_php"
		ui_info "PHP ${_native_php} добавлена автоматически — на ней работает панель ISPConfig (без неё панель = 502)."
	fi
	config_set PHP_VERSIONS "$_phpsel"
	UI_CHECK_RESULT="$_phpsel"   # чтобы блок «версия по умолчанию» ниже видел актуальный список

	# --- Версия PHP по умолчанию (системный /usr/bin/php + php-default сниппет) ---
	local php_default="" _v
	local _php_sel=()
	for _v in $UI_CHECK_RESULT; do _php_sel+=("$_v"); done
	if ((${#_php_sel[@]} <= 1)); then
		php_default="${_php_sel[0]:-8.3}"
	else
		# рекомендация: 8.3 если выбрана; иначе самая новая НЕ 8.5 (совместимость
		# большинства приложений); иначе самая новая
		local _rec=1 _i _labels=()
		for _i in "${!_php_sel[@]}"; do
			if [[ "${_php_sel[$_i]}" == "8.3" ]]; then _rec=$((_i + 1)); break; fi
			if [[ "${_php_sel[$_i]}" != "8.5" && $_rec -eq 1 && "${_php_sel[0]}" == "8.5" ]]; then
				_rec=$((_i + 1))
			fi
		done
		for _v in "${_php_sel[@]}"; do
			local _l="PHP ${_v}"
			case "$_v" in
				8.3) _l+=" (рекомендуется — максимальная совместимость)" ;;
				8.5) _l+=" (новейшая; часть приложений ещё не поддерживает)" ;;
				7.4) _l+=" (legacy — только для старых приложений)" ;;
			esac
			_labels+=("$_l")
		done
		ui_box_top "Версия PHP по умолчанию"
		ui_box_line "Версия для системного ${UI_C}php${UI_NC} (командная строка) и для .php на"
		ui_box_line "стартовой странице сервера (phpMyAdmin/Adminer, RoundCube)."
		ui_box_line "Сайты в панели ISPConfig выбирают свою версию PHP отдельно."
		ui_box_bottom
		ui_menu "Версия PHP по умолчанию" "$_rec" "${_labels[@]}"
		php_default="${_php_sel[$((UI_MENU_CHOICE - 1))]}"
	fi
	config_set PHP_DEFAULT "${php_default:-8.3}"

	# --- Системный php в консоли/cron (можно отвязать от версии сайтов) ---
	# По умолчанию = PHP_DEFAULT. Все версии остаются доступны явно (php8.2, php8.3…).
	ui_menu "Системный php в консоли/cron (команда php)" 1 \
		"PHP ${php_default} — как версия по умолчанию (рекомендуется)" \
		"Оставить системный дефолт Debian (не трогать /usr/bin/php)" \
		"Указать другую установленную версию"
	case "$UI_MENU_CHOICE" in
		1) config_set PHP_CLI_DEFAULT "$php_default" ;;
		2) config_set PHP_CLI_DEFAULT "system" ;;
		3) ui_input "Версия для системного php (из установленных: ${PHP_VERSIONS})" "$php_default"
		   config_set PHP_CLI_DEFAULT "$UI_INPUT" ;;
	esac

	# --- Источник MariaDB ---
	ui_menu "Источник установки MariaDB" 1 \
		"Официальный репозиторий MariaDB (свежий LTS, рекомендуется)" \
		"Репозиторий Debian (mariadb-server из дистрибутива)"
	case "$UI_MENU_CHOICE" in
		1) config_set MARIADB_SOURCE official
		   # --- Выбор версии MariaDB ---
		   ui_menu "Версия MariaDB" 1 \
		       "Авто — последняя LTS с сайта MariaDB (свежее всего)" \
		       "Проверенная LTS 11.4 (рекомендуется для ISPConfig)" \
		       "Указать версию вручную"
		   case "$UI_MENU_CHOICE" in
		       1) config_set MARIADB_AUTO_VERSION y; config_set MARIADB_VERSION "" ;;
		       2) config_set MARIADB_AUTO_VERSION n; config_set MARIADB_VERSION 11.4 ;;
		       3) config_set MARIADB_AUTO_VERSION n
		          while :; do
		              ui_input "Версия MariaDB (например 11.4, 11.8, 12.3)" "${MARIADB_VERSION:-11.8}"
		              [[ "$UI_INPUT" =~ ^[0-9]+\.[0-9]+$ ]] && break
		              ui_warn "Формат версии — мажор.минор, например 11.4"
		          done
		          config_set MARIADB_VERSION "$UI_INPUT" ;;
		   esac ;;
		2) config_set MARIADB_SOURCE debian ;;
	esac

	# --- Redis ---
	if ui_confirm "Установить Redis (redis-server для кэша/сессий)?" y; then
		config_set INSTALL_REDIS y
	else
		config_set INSTALL_REDIS n
	fi

	# --- Опциональные компоненты (optional-этапы) ---
	# phpmyadmin — веб-админка к обязательной MariaDB; postgresql — НЕЗАВИСИМОЕ
	# дополнение (PostgreSQL+pgAdmin), ставится РЯДОМ с MariaDB, не вместо неё
	# (ISPConfig работает только с MariaDB).
	# --- Профиль установки (пресет): предзаполняет чеклист компонентов ниже ---
	# Пресет = умный дефолт, а НЕ клетка: список под ним правится вручную. Ядро
	# (веб-сервер + PHP-FPM + MariaDB + ISPConfig + SSL) ставится всегда, в чеклист
	# не входит. Веб-сервер (nginx/Apache) выбран отдельно и ортогонален профилю.
	ui_menu "Профиль установки" 2 \
		"Минимальный — ядро + DNS + security + LE-серт хоста (сайты добавишь сам; 1–2 ГБ RAM)" \
		"Веб+Почта — сайты + почта + вебмейл + бэкап/тюнинг (2–4 ГБ RAM)" \
		"Полный — всё: + PostgreSQL, Node.js, FTP, Monit (4+ ГБ RAM)" \
		"Свой — выбрать компоненты вручную"
	local _preset_def
	case "$UI_MENU_CHOICE" in
		1) _preset_def="dns,security,hostcert"
		   ui_info "Профиль ${UI_W}Минимальный${UI_NC} — нужное можно добавить в списке ниже." ;;
		2) _preset_def="phpmyadmin,mail,rspamd,dns,security,webmail,hostcert,rcplugins,maildeliver,mailsni,tuning,backup"
		   ui_info "Профиль ${UI_W}Веб+Почта${UI_NC} — список ниже можно поправить (Monit/Node.js/FTP/PostgreSQL — по желанию)." ;;
		3) _preset_def="nodejs,phpmyadmin,postgresql,mail,rspamd,dns,ftp,security,monit,webmail,hostcert,rcplugins,maildeliver,mailsni,tuning,backup"
		   ui_info "Профиль ${UI_W}Полный${UI_NC} — лишнее можно снять в списке ниже." ;;
		*) _preset_def="phpmyadmin,mail,rspamd,security,webmail,hostcert,tuning,backup"
		   ui_info "Профиль ${UI_W}Свой${UI_NC} — отметь нужные компоненты вручную." ;;
	esac

	ui_checklist "Компоненты сервера" "$_preset_def" \
		nodejs      "Node.js (NodeSource LTS)" \
		phpmyadmin  "Веб-админка БД (phpMyAdmin / Adminer)" \
		postgresql  "PostgreSQL (+ pgAdmin при Apache / Adminer при nginx)" \
		mail        "Почта (Postfix + Dovecot)" \
		rspamd      "Антиспам (Rspamd + ClamAV)" \
		dns         "DNS-сервер (BIND)" \
		ftp         "FTP + квоты (PureFTPd)" \
		security    "Безопасность (firewall, fail2ban, Lynis, автообновления)" \
		monit       "Мониторинг Monit (интеграция с ISPConfig)" \
		webmail     "Webmail + статистика (RoundCube)" \
		hostcert    "LE-сертификат хоста для панели/почты (нужен публичный домен)" \
		rcplugins   "Плагины ISPConfig для Roundcube (пароль/автоответчик/фильтры)" \
		maildeliver "Доставляемость почты (TLS-харденинг + DNS-записи)" \
		mailsni     "Per-domain TLS почты (SNI из Let's Encrypt)" \
		tuning      "Авто-тюнинг под железо (MariaDB/PHP/Postfix)" \
		backup      "Резервное копирование (БД + конфиги, по расписанию)"
	config_set COMPONENTS "$UI_CHECK_RESULT"

	# --- Ресурсы: swap (для малой RAM) + ClamAV (прожорлив к памяти) ---
	local _ram_mb _swap_kb _swap_mb
	_ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"; [[ "$_ram_mb" =~ ^[0-9]+$ ]] || _ram_mb=0
	_swap_kb="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)"; [[ "$_swap_kb" =~ ^[0-9]+$ ]] || _swap_kb=0
	# Swap предлагаем, только если RAM < 4 ГБ и swap ещё нет.
	if (( _ram_mb > 0 && _ram_mb < 4096 && _swap_kb == 0 )); then
		ui_box_top "Swap-файл (RAM ${_ram_mb} МБ — немного)"
		ui_box_line "Без swap тяжёлые службы (ClamAV грузит ~1 ГБ сигнатур) ловят OOM."
		ui_box_line "Swap-файл смягчает это ценой места на диске (1 ГБ swap = 1 ГБ на диске)."
		ui_box_bottom
		ui_menu "Создать swap-файл?" 1 \
			"Да, 2 ГБ (рекомендуется)" \
			"Да, 4 ГБ" \
			"Да, указать размер (1–16 ГБ)" \
			"Нет, не создавать"
		case "$UI_MENU_CHOICE" in
			1) config_set TUNE_SWAP y; config_set TUNE_SWAP_SIZE 2G ;;
			2) config_set TUNE_SWAP y; config_set TUNE_SWAP_SIZE 4G ;;
			3) ui_input "Размер swap в ГБ (1–16)" "2"
			   local _sz="${UI_INPUT//[!0-9]/}"; [[ "$_sz" =~ ^[0-9]+$ ]] || _sz=2; (( _sz < 1 )) && _sz=1; (( _sz > 16 )) && _sz=16
			   config_set TUNE_SWAP y; config_set TUNE_SWAP_SIZE "${_sz}G" ;;
			4) config_set TUNE_SWAP n ;;
		esac
	else
		config_set TUNE_SWAP n   # swap уже есть или RAM достаточно — не создаём
	fi
	# ClamAV (часть rspamd) очень прожорлив. Считаем эффективную память (RAM + swap,
	# с учётом планируемого) и на малом объёме даём отказаться (Rspamd работает и без него).
	if [[ " ${UI_CHECK_RESULT} " == *" rspamd "* ]]; then
		_swap_mb=$(( _swap_kb / 1024 ))
		[[ "${TUNE_SWAP:-n}" == "y" && -n "${TUNE_SWAP_SIZE:-}" ]] && _swap_mb=$(( _swap_mb + ${TUNE_SWAP_SIZE%[Gg]} * 1024 ))
		local _eff=$(( _ram_mb + _swap_mb ))
		if (( _ram_mb > 0 && _eff < 1536 )); then
			ui_warn "RAM+swap ≈ ${_eff} МБ — ClamAV (нужно ~1–2 ГБ) рискует падать с OOM."
			if ui_confirm "Ставить ClamAV всё равно? (Нет — Rspamd без антивируса, легче)" n; then
				config_set INSTALL_CLAMAV y
			else
				config_set INSTALL_CLAMAV n
			fi
		else
			config_set INSTALL_CLAMAV y
		fi
	fi

	# --- Настройки резервного копирования (только если выбран компонент backup) ---
	if [[ " $UI_CHECK_RESULT " == *" backup "* ]]; then
		ui_box_top "Резервное копирование"
		ui_box_line "Ежедневный дамп всех БД + архив /etc и конфигов ISPConfig по systemd-таймеру."
		ui_box_line "Сайты (/var/www) и почта (/var/vmail) — отдельно, могут быть большими."
		ui_box_bottom
		ui_input "Каталог для бэкапов" "${BACKUP_DIR:-/var/backups/server}"
		while declare -F _backup_dir_ok >/dev/null && ! _backup_dir_ok "$UI_INPUT"; do
			ui_warn "Этот каталог не подходит: системный, каталог сайтов или почты. Нужен отдельный, например /var/backups/server."
			ui_input "Каталог для бэкапов" "/var/backups/server"
		done
		config_set BACKUP_DIR "$UI_INPUT"
		ui_input "Сколько дней хранить снимки" "${BACKUP_RETENTION_DAYS:-7}"
		config_set BACKUP_RETENTION_DAYS "$UI_INPUT"
		ui_input "Время ежедневного запуска (ЧЧ:ММ)" "${BACKUP_TIME:-03:30}"
		config_set BACKUP_TIME "$UI_INPUT"
		if ui_confirm "Включать в бэкап сайты (/var/www)? Может быть много данных." n; then
			config_set BACKUP_INCLUDE_WWW y; else config_set BACKUP_INCLUDE_WWW n; fi
		ui_info "Сайты удобнее бэкапить средствами ISPConfig: по сайту, с ротацией и восстановлением из панели (Sites → сайт → Backup)."
		if ui_confirm "Включать в бэкап почту (/var/vmail)? Обычно она небольшая, а потерять её больнее всего." y; then
			config_set BACKUP_INCLUDE_MAIL y; else config_set BACKUP_INCLUDE_MAIL n; fi

		# Оффсайт-копия — вторая копия ВНЕ сервера (защита от потери диска/сервера)
		ui_menu "Оффсайт-копия бэкапов (вторая копия вне сервера)?" 1 \
			"Нет — хранить только локально" \
			"rsync по SSH — на другой сервер (нужен SSH-ключ к удалёнке)" \
			"rclone — в облако (S3 / B2 / Google Drive и пр.; настраивается rclone config)"
		case "$UI_MENU_CHOICE" in
			2)
				config_set BACKUP_REMOTE_TYPE rsync
				ui_input "Удалёнка rsync (user@host:/path/)" "${BACKUP_REMOTE:-}"
				config_set BACKUP_REMOTE "$UI_INPUT"
				ui_input "Порт SSH удалёнки (Enter = 22)" "${BACKUP_REMOTE_SSHPORT:-}"
				config_set BACKUP_REMOTE_SSHPORT "$UI_INPUT"
				ui_input "SSH-ключ для удалёнки (путь, Enter = по умолчанию)" "${BACKUP_REMOTE_SSHKEY:-}"
				config_set BACKUP_REMOTE_SSHKEY "$UI_INPUT"
				ui_info "Заранее настройте вход по ключу на удалёнку (ssh-copy-id), иначе выгрузка будет падать."
				;;
			3)
				config_set BACKUP_REMOTE_TYPE rclone
				ui_menu "Облачный бэкенд (настроим rclone за вас)" 1 \
					"Amazon S3 / S3-совместимый (Wasabi, MinIO, Storj, и пр.)" \
					"Backblaze B2" \
					"SFTP (по SSH на другой сервер/NAS)" \
					"Уже настроен сам (rclone config) — задать только remote:path"
				case "$UI_MENU_CHOICE" in
					1)
						config_set BACKUP_RCLONE_BACKEND s3
						ui_menu "Провайдер S3" 1 "AWS" "Wasabi" "Storj" "MinIO/другой (Other)"
						case "$UI_MENU_CHOICE" in 1) _p=AWS;; 2) _p=Wasabi;; 3) _p=Storj;; *) _p=Other;; esac
						config_set BACKUP_RCLONE_S3_PROVIDER "$_p"
						ui_input "Access Key ID" "${BACKUP_RCLONE_S3_KEY:-}";        config_set BACKUP_RCLONE_S3_KEY "$UI_INPUT"
						ui_input "Secret Access Key" "${BACKUP_RCLONE_S3_SECRET:-}"; config_set BACKUP_RCLONE_S3_SECRET "$UI_INPUT"
						ui_input "Регион (напр. us-east-1; Enter — пропустить)" "${BACKUP_RCLONE_S3_REGION:-}"; config_set BACKUP_RCLONE_S3_REGION "$UI_INPUT"
						ui_input "Endpoint для не-AWS (напр. s3.wasabisys.com; Enter — авто)" "${BACKUP_RCLONE_S3_ENDPOINT:-}"; config_set BACKUP_RCLONE_S3_ENDPOINT "$UI_INPUT"
						ui_input "Бакет и путь (bucket/path)" "${BACKUP_REMOTE#*:}"
						config_set BACKUP_REMOTE "offsite:${UI_INPUT}"
						;;
					2)
						config_set BACKUP_RCLONE_BACKEND b2
						ui_input "B2 keyID (Application Key ID)" "${BACKUP_RCLONE_B2_ACCOUNT:-}"; config_set BACKUP_RCLONE_B2_ACCOUNT "$UI_INPUT"
						ui_input "B2 applicationKey" "${BACKUP_RCLONE_B2_KEY:-}";              config_set BACKUP_RCLONE_B2_KEY "$UI_INPUT"
						ui_input "Бакет и путь (bucket/path)" "${BACKUP_REMOTE#*:}"
						config_set BACKUP_REMOTE "offsite:${UI_INPUT}"
						;;
					3)
						config_set BACKUP_RCLONE_BACKEND sftp
						ui_input "SFTP хост" "${BACKUP_RCLONE_SFTP_HOST:-}"; config_set BACKUP_RCLONE_SFTP_HOST "$UI_INPUT"
						ui_input "SFTP пользователь" "${BACKUP_RCLONE_SFTP_USER:-}"; config_set BACKUP_RCLONE_SFTP_USER "$UI_INPUT"
						ui_input "SFTP порт (Enter = 22)" "${BACKUP_RCLONE_SFTP_PORT:-}"; config_set BACKUP_RCLONE_SFTP_PORT "$UI_INPUT"
						if ui_confirm "Авторизация по SSH-ключу (иначе по паролю)?" y; then
							ui_input "Путь к приватному ключу" "${BACKUP_RCLONE_SFTP_KEY:-/root/.ssh/id_ed25519}"; config_set BACKUP_RCLONE_SFTP_KEY "$UI_INPUT"; config_set BACKUP_RCLONE_SFTP_PASS ""
						else
							ui_input "SFTP пароль" "${BACKUP_RCLONE_SFTP_PASS:-}"; config_set BACKUP_RCLONE_SFTP_PASS "$UI_INPUT"; config_set BACKUP_RCLONE_SFTP_KEY ""
						fi
						ui_input "Путь на удалёнке (напр. /backups/$(hostname -s))" "${BACKUP_REMOTE#*:}"
						config_set BACKUP_REMOTE "offsite:${UI_INPUT}"
						;;
					*)
						config_set BACKUP_RCLONE_BACKEND manual
						ui_input "Назначение rclone (remote:bucket/path)" "${BACKUP_REMOTE:-}"
						config_set BACKUP_REMOTE "$UI_INPUT"
						ui_info "После установки настройте удалёнку: ${UI_W}rclone config${UI_NC} (имя remote должно совпасть)."
						;;
				esac
				ui_info "Секреты сохранятся в setup.conf (chmod 600) и в rclone.conf; rclone-remote создастся при установке."
				;;
			*)
				config_set BACKUP_REMOTE_TYPE none
				;;
		esac
	fi

	# --- Анти-malware (rkhunter + LMD) — только если выбран компонент malware ---
	if [[ " $UI_CHECK_RESULT " == *" malware "* ]]; then
		ui_box_top "$(t "Анти-malware (rkhunter + Linux Malware Detect)")"
		ui_box_line "$(t "Ежедневный скан на веб-шеллы/малварь по systemd-таймеру + алерт админу.")"
		ui_box_line "$(t "По умолчанию — только оповещение (файлы не трогаем); карантин по желанию.")"
		ui_box_bottom
		ui_input "$(t "Что сканировать (пути через пробел)")" "${MALWARE_PATHS:-/var/www}"
		config_set MALWARE_PATHS "$UI_INPUT"
		ui_input "$(t "Время ежедневного скана (ЧЧ:ММ)")" "${MALWARE_SCAN_TIME:-03:30}"
		config_set MALWARE_SCAN_TIME "$UI_INPUT"
		if ui_confirm "$(t "Карантинить находки автоматически? (Нет — только алерт, файлы не трогаем)")" n; then
			config_set MALWARE_QUARANTINE y
			ui_warn "$(t "Карантин перемещает подозрительные файлы — держите бэкапы под рукой (ложные срабатывания).")"
		else
			config_set MALWARE_QUARANTINE n
		fi
		# Движок ClamAV в LMD точнее, но прожорлив — предлагаем только если ClamAV ставится (часть rspamd)
		if [[ "${INSTALL_CLAMAV:-n}" == "y" ]]; then
			if ui_confirm "$(t "Использовать движок ClamAV в LMD (точнее, но +RAM/CPU)?")" y; then
				config_set MALWARE_CLAMAV y; else config_set MALWARE_CLAMAV n; fi
		else
			config_set MALWARE_CLAMAV n
		fi
	fi

	# --- Уведомления (email/Telegram) — кросс-компонентно, спрашиваем всегда ---
	ui_box_top "Уведомления администратору"
	ui_box_line "Оповещения о проблемах: сбой бэкапа, мало места на диске, истекает TLS-серт, упала служба."
	ui_box_line "Каналы: email (нужен компонент mail) и/или Telegram-бот. Ежедневная проверка + по событию."
	ui_box_bottom
	if ui_confirm "Настроить уведомления?" n; then
		ui_input "Email для уведомлений (Enter — пропустить)" "${NOTIFY_EMAIL:-}"
		config_set NOTIFY_EMAIL "$UI_INPUT"
		if ui_confirm "Добавить Telegram-бота?" n; then
			ui_input "Token бота (от @BotFather)" "${NOTIFY_TG_TOKEN:-}"
			config_set NOTIFY_TG_TOKEN "$UI_INPUT"
			ui_info "Chat ID можно оставить пустым: потом напишите боту /start и выберите чат в панели (System → Дополнения → Уведомления → «Найти chat id»)."
			ui_input "Chat ID (ваш id от @userinfobot или id группы; несколько через пробел)" "${NOTIFY_TG_CHAT:-}"
			config_set NOTIFY_TG_CHAT "$UI_INPUT"
		fi
	else
		config_set NOTIFY_EMAIL ""
		config_set NOTIFY_TG_TOKEN ""
		config_set NOTIFY_TG_CHAT ""
	fi

	# --- Доступ к Monit (web-интерфейс :2812) ---
	if [[ " $UI_CHECK_RESULT " == *" monit "* ]]; then
		ui_box_top "Доступ к Monit (web-интерфейс :2812)"
		ui_box_line "По умолчанию — только localhost (безопасно; снаружи через SSH-туннель)."
		ui_box_line "Можно открыть наружу, ограничив доступ ОДНИМ IP."
		ui_box_bottom
		if ui_confirm "Открыть Monit наружу (с ограничением по IP)?" n; then
			config_set MONIT_EXPOSE y
			local _ssh_ip _ip=""
			_ssh_ip="$(_detect_ssh_ip)"
			if [[ -n "$_ssh_ip" ]] && ui_confirm "Ваш IP из SSH-сессии: ${UI_W}${_ssh_ip}${UI_NC} — разрешить доступ с него?" y; then
				_ip="$_ssh_ip"
			else
				while :; do
					ui_input "IP, которому разрешить доступ к Monit" "${MONIT_ALLOW_IP:-$_ssh_ip}"
					[[ "$UI_INPUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$UI_INPUT" == *:* ]] && { _ip="$UI_INPUT"; break; }
					ui_warn "Введите корректный IP (например 203.0.113.7)."
				done
			fi
			config_set MONIT_ALLOW_IP "$_ip"
			ui_info "Monit будет открыт на :2812 только для ${UI_W}${_ip}${UI_NC}."
		else
			config_set MONIT_EXPOSE n
			config_set MONIT_ALLOW_IP ""
		fi
	fi

	# --- DNS: кастомный шаблон зоны для новых доменов (ISPConfig) ---
	if [[ " $UI_CHECK_RESULT " == *" dns "* ]]; then
		ui_box_top "DNS: шаблон зоны новых доменов (ISPConfig)"
		ui_box_line "Зашьём шаблон «Default»: vanity-NS этого сервера + SPF, DMARC (p=none),"
		ui_box_line "CAA (letsencrypt), autodiscover/autoconfig. DKIM добавит сам ISPConfig per-домен."
		ui_box_line "Число NS выбираешь ниже (минимум по best-practice — 2). Несколько NS на одном"
		ui_box_line "хосте не дают резерва при падении машины — вторичку лучше держать отдельно."
		ui_box_bottom
		if ui_confirm "Зашить кастомный DNS-шаблон зоны в ISPConfig?" y; then
			config_set DNS_ZONE_TEMPLATE y
			# Сколько NS-записей зашить в шаблон (2–4).
			local _nsc
			ui_input "Сколько NS-записей зашить в шаблон? (2–4)" "${DNS_NS_COUNT:-2}"
			_nsc="$UI_INPUT"; [[ "$_nsc" =~ ^[2-4]$ ]] || { ui_warn "Нужно 2–4 — ставлю 2."; _nsc=2; }
			config_set DNS_NS_COUNT "$_nsc"
			# Автоопределение глобальных IPv4 сервера (primary — первым, без дублей).
			local _primary _ip _ordered _arr _i _def _saved
			_primary="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
			_ordered="$_primary"
			for _ip in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
				[[ "$_ip" == "$_primary" ]] && continue
				_ordered+=" $_ip"
			done
			_arr=($_ordered)
			ui_info "IP сервера (scope global): ${_ordered:-—}"
			for _i in $(seq 1 "$_nsc"); do
				_def="${_arr[$((_i-1))]:-${_arr[0]:-$_primary}}"
				eval "_saved=\"\${DNS_NS${_i}_IP:-}\""
				ui_input "IP для ns${_i}.<домен> (glue-запись)" "${_saved:-$_def}"
				config_set "DNS_NS${_i}_IP" "$UI_INPUT"
			done
		else
			config_set DNS_ZONE_TEMPLATE n
		fi
	fi

	# --- Roundcube: откуда ставить ---
	# Пакет Debian обновляется через apt, но исправления безопасности приходят с задержкой
	# (в ноябре 2026 в bookworm висели 20 уязвимостей, давно закрытых у разработчиков).
	if [[ " $UI_CHECK_RESULT " == *" webmail "* ]]; then
		local _rcs=1; [[ "${RC_SOURCE:-}" == "debian" ]] && _rcs=3
		[[ "${RC_SOURCE:-}" == "upstream" && "${RC_BRANCH:-1.6}" == "1.7" ]] && _rcs=2
		ui_menu "Откуда ставить Roundcube (вебмейл)" "$_rcs" \
			"С сайта разработчиков, ветка 1.6 LTS (рекомендуется: исправления сразу, обновляет --update)" \
			"С сайта разработчиков, ветка 1.7 (новые возможности, нужен PHP 8.1+)" \
			"Из пакетов Debian (обновляет apt, исправления приходят с задержкой)"
		case "$UI_MENU_CHOICE" in
			2) config_set RC_SOURCE upstream; config_set RC_BRANCH 1.7 ;;
			3) config_set RC_SOURCE debian ;;
			*) config_set RC_SOURCE upstream; config_set RC_BRANCH 1.6 ;;
		esac
	fi

	# --- Веб-админка БД: инструмент с учётом веб-сервера ---
	# Apache → phpMyAdmin (pgAdmin для PostgreSQL ставит этап postgresql).
	# nginx  → выбор: Adminer (MariaDB+PostgreSQL, без Apache) или phpMyAdmin (MariaDB).
	if [[ " $UI_CHECK_RESULT " == *" phpmyadmin "* ]]; then
		if [[ "$WEBSERVER" == "apache" ]]; then
			config_set DBADMIN_TOOL phpmyadmin
		else
			ui_menu "Веб-админка БД (nginx)" 1 \
				"Adminer — один инструмент на MariaDB и PostgreSQL (рекомендуется, без Apache)" \
				"phpMyAdmin — только MariaDB"
			[[ "$UI_MENU_CHOICE" == "2" ]] && config_set DBADMIN_TOOL phpmyadmin || config_set DBADMIN_TOOL adminer
		fi

		# Ограничение доступа к веб-админке БД (она открывает БД — лучше прикрыть).
		# По умолчанию — только по FQDN (закрыть доступ по IP/чужому домену).
		if ui_confirm "Открывать веб-админку БД только по доменному имени (закрыть по IP/чужому домену)?" y; then
			config_set DBADMIN_FQDN_ONLY y
		else
			config_set DBADMIN_FQDN_ONLY n
		fi
		local _dba_ip; _dba_ip="$(_detect_ssh_ip)"
		if [[ -n "$_dba_ip" ]]; then
			ui_menu "Доступ к веб-админке БД по IP" 2 \
				"Только с моего IP (${_dba_ip})" \
				"Со всех IP (без ограничения)" \
				"Указать список вручную"
			case "$UI_MENU_CHOICE" in
				1) config_set DBADMIN_ALLOW_IPS "$_dba_ip" ;;
				2) config_set DBADMIN_ALLOW_IPS "" ;;
				3) ui_input "IP через пробел (пусто = со всех)" "${DBADMIN_ALLOW_IPS:-$_dba_ip}"
				   config_set DBADMIN_ALLOW_IPS "$UI_INPUT" ;;
			esac
		else
			ui_input "Разрешить веб-админку БД только с этих IP (пусто = со всех)" "${DBADMIN_ALLOW_IPS:-}"
			config_set DBADMIN_ALLOW_IPS "$UI_INPUT"
		fi
	fi

	# --- Удалённый доступ к MariaDB (для галочки «Remote Access» у БД в ISPConfig) ---
	ui_box_top "Удалённый доступ к MariaDB (ISPConfig «Remote Access»)"
	ui_box_line "По умолчанию БД слушает только localhost (безопасно). Чтобы галочка «Remote Access»"
	ui_box_line "у базы в ISPConfig реально работала (коннект к базе извне), MariaDB должна слушать"
	ui_box_line "наружу, а порт 3306 — открыт ТОЛЬКО доверенным IP. Нужно лишь если к базе"
	ui_box_line "подключаются внешние приложения/второй сервер. ⚠ Открывать 3306 всем — опасно."
	ui_box_bottom
	if ui_confirm "Включить удалённый доступ к MariaDB (для Remote Access в ISPConfig)?" n; then
		config_set MARIADB_REMOTE y
		local _mr_ip; _mr_ip="$(_detect_ssh_ip)"
		while :; do
			ui_input "IP с доступом к 3306 (через пробел; пусто = ВСЕМ, не рекомендуется)" "${MARIADB_REMOTE_IPS:-$_mr_ip}"
			if [[ -z "$UI_INPUT" ]]; then
				if ui_confirm "Точно открыть 3306 ВСЕМ IP (небезопасно)?" n; then config_set MARIADB_REMOTE_IPS ""; break; fi
			else
				config_set MARIADB_REMOTE_IPS "$UI_INPUT"; break
			fi
		done
	else
		config_set MARIADB_REMOTE n
		config_set MARIADB_REMOTE_IPS ""
	fi

	# Версия Node.js — спрашиваем только если выбран
	if [[ " $UI_CHECK_RESULT " == *" nodejs "* ]]; then
		ui_menu "Версия Node.js" 1 \
			"22 LTS (рекомендуется)" \
			"20 LTS" \
			"24 (Current)"
		case "$UI_MENU_CHOICE" in
			1) config_set NODEJS_VERSION 22 ;;
			2) config_set NODEJS_VERSION 20 ;;
			3) config_set NODEJS_VERSION 24 ;;
		esac
	fi

	# --- Инструменты аудита для этапа «Безопасность» (если он выбран) ---
	# fail2ban + firewall + jailkit ставятся всегда; здесь — выбор доп. аудиторов.
	# Опираемся на $COMPONENTS (не на UI_CHECK_RESULT — он перезапишется чеклистом).
	if [[ " ${COMPONENTS:-} " == *" security "* ]]; then
		ui_checklist "Инструменты аудита безопасности" "lynis" \
			lynis    "Lynis — аудит конфигурации (рекомендуется; активно поддерживается)" \
			rkhunter "rkhunter — сканер руткитов (устарел, малополезен; для совместимости)"
		[[ " $UI_CHECK_RESULT " == *" lynis "*    ]] && config_set SEC_LYNIS y    || config_set SEC_LYNIS n
		[[ " $UI_CHECK_RESULT " == *" rkhunter "* ]] && config_set SEC_RKHUNTER y || config_set SEC_RKHUNTER n

		# Автообновления безопасности (закрывают дыры без ручного apt upgrade)
		if ui_confirm "Включить автоматические обновления безопасности (только security-патчи, без авто-перезагрузки)?" y; then
			config_set SEC_AUTO_UPDATES y; else config_set SEC_AUTO_UPDATES n; fi

		# Аудит файлов с правом записи для всех (world-writable)
		ui_menu "Проверка файлов, доступных на запись всем (world-writable)" 1 \
			"Только показать отчёт (рекомендуется)" \
			"Показать и исправить права (chmod o-w)" \
			"Не проверять"
		case "$UI_MENU_CHOICE" in
			1) config_set SEC_WORLDWRITABLE report ;;
			2) config_set SEC_WORLDWRITABLE fix ;;
			3) config_set SEC_WORLDWRITABLE off ;;
		esac

		# Сетевой/ядровый харденинг через sysctl (безопасные параметры Lynis/CIS)
		if ui_confirm "Применить харденинг ядра (sysctl: анти-спуфинг, SYN cookies, ASLR, скрытие адресов ядра, ptrace)?" y; then
			config_set SEC_SYSCTL y
			if ui_confirm "Запретить непривилегированные user namespaces (закрывает часть эксплойтов ядра; ломает rootless-контейнеры и песочницу браузеров)?" n; then
				config_set SEC_USERNS_OFF y; else config_set SEC_USERNS_OFF n; fi
		else
			config_set SEC_SYSCTL n
		fi
	fi

	# --- Утилиты администратора (выбор) ---
	# Ключ = имя пакета apt; метка = пакет + краткое описание.
	# Базовые зависимости установщика (wget/curl/gnupg2/ca-certificates/…) ставятся
	# всегда отдельно в preflight и здесь НЕ перечислены.
	ui_checklist "Утилиты администратора (что доустановить)" \
		"nano,vim,mc,htop,git,sudo,rsync,unzip,tar,bzip2,perl,net-tools,bash-completion" \
		nano           "nano — простой консольный редактор" \
		vim            "vim — продвинутый редактор" \
		mc             "mc — Midnight Commander, файловый менеджер" \
		htop           "htop — интерактивный монитор процессов" \
		git            "git — система контроля версий" \
		sudo           "sudo — выполнение команд от имени root" \
		rsync          "rsync — быстрая синхронизация/копирование файлов" \
		unzip          "unzip — распаковка .zip" \
		tar            "tar — архиватор tar" \
		bzip2          "bzip2 — сжатие/распаковка .bz2" \
		perl           "perl — интерпретатор Perl (нужен ряду скриптов)" \
		net-tools      "net-tools — ifconfig, netstat, route" \
		bash-completion "bash-completion — автодополнение команд в bash" \
		telnet         "telnet — клиент для проверки доступности портов" \
		binutils       "binutils — strings, objdump, ld и пр."
	config_set UTILS "$UI_CHECK_RESULT"

	# --- Базовые параметры ---
	# FQDN — критичен: опечатка тихо каскадит в провал LE-серта и почты. Проверяем формат.
	# По умолчанию — текущее имя сервера, если оно похоже на FQDN (обычно его уже выставил хостер).
	local _fq_def="${SERVER_FQDN:-}"
	if [[ -z "$_fq_def" ]]; then
		_fq_def="$(hostname -f 2>/dev/null)"
		[[ "$_fq_def" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ && "$_fq_def" != *localdomain ]] \
			|| _fq_def="server1.example.com"
	fi
	ui_input_validated "FQDN сервера (server1.example.com)" "$_fq_def" \
		'^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$' \
		"FQDN должен быть вида host.domain.tld (буквы/цифры/дефис, минимум домен + зона ≥2 букв)."
	config_set SERVER_FQDN "$UI_INPUT"
	# Часовой пояс — проверяем по наличию файла в zoneinfo.
	while true; do
		ui_input "Часовой пояс" "${TIMEZONE:-Europe/Moscow}"
		[[ -f "/usr/share/zoneinfo/$UI_INPUT" ]] && break
		ui_warn "Часовой пояс '${UI_INPUT}' не найден (пример: Europe/Moscow, UTC; список: timedatectl list-timezones)."
		[[ ! -t 0 ]] && break
	done
	config_set TIMEZONE "$UI_INPUT"

	# --- Firewall ---
	# CrowdSec = авто-баны по IP (анализ логов), UFW = закрытые порты (default-deny).
	# Это РАЗНЫЕ слои и работают вместе (ufw=порты, crowdsec=IP-баны) — связка надёжнее.
	# Выбор «оба» = FIREWALL=crowdsec + CROWDSEC_WITH_UFW=y (ufw поднимается поверх).
	ui_menu "Защита от атак (firewall)" 1 \
		"CrowdSec + UFW — авто-баны атакующих И закрытые порты (рекомендуется)" \
		"Только CrowdSec — авто-баны по IP, порты НЕ закрываются" \
		"Только UFW — закрытые порты, без авто-банов" \
		"Не настраивать — настрою firewall сам"
	case "$UI_MENU_CHOICE" in
		1) config_set FIREWALL crowdsec; config_set CROWDSEC_WITH_UFW y ;;
		2) config_set FIREWALL crowdsec; config_set CROWDSEC_WITH_UFW n ;;
		3) config_set FIREWALL ufw ;;
		4) config_set FIREWALL none ;;
	esac

	# --- ISPConfig: источник + порт панели ---
	# Nightly = git stable-3.2 в готовом tarball: рабочий autoinstall на PHP 8.3/8.4
	# и надёжная загрузка. У release-stable неинтерактивный install.php зацикливается
	# на PHP 8.3+ (Debian 13/trixie), поэтому nightly — выбор по умолчанию.
	# Только надёжные tarball-источники. Установка из git-клона (git.ispconfig.org)
	# убрана: репозиторий хронически нестабилен (обрывы клона), а nightly даёт ту же
	# свежую ветку готовым архивом и с рабочим autoinstall.
	ui_menu "Версия ISPConfig" 1 \
		"Nightly — свежая стабильная сборка, надёжно ставится автоматически (рекомендуется)" \
		"Stable — официальный релиз (на новых PHP авто-установка иногда не завершается)"
	case "$UI_MENU_CHOICE" in
		1) config_set ISPCONFIG_BRANCH nightly ;;
		2) config_set ISPCONFIG_BRANCH stable ;;
	esac
	ui_info "Доступность выбранного источника проверим на этапе установки ISPConfig."

	ui_input "Порт веб-панели ISPConfig (по умолчанию 8080)" "${ISPCONFIG_PANEL_PORT:-8080}"
	config_set ISPCONFIG_PANEL_PORT "$UI_INPUT"

	# Порт Apps-vhost (webmail/phpMyAdmin через apps.<домен>). ISPConfig по умолчанию 8081;
	# меняется в его конфиге сервера (apps_vhost_port), применяем после установки.
	ui_input "Порт Apps-vhost ISPConfig (webmail/pma через apps.домен; по умолчанию 8081)" "${ISPCONFIG_APPS_PORT:-8081}"
	config_set ISPCONFIG_APPS_PORT "$UI_INPUT"

	# Ограничение доступа к панели по IP (через firewall). Пусто = вход со всех.
	local _adm_ssh; _adm_ssh="$(_detect_ssh_ip)"
	if [[ -n "$_adm_ssh" ]]; then
		ui_menu "Доступ к панели ISPConfig по IP" 2 \
			"Только с моего IP (${_adm_ssh})" \
			"Со всех IP (без ограничения)" \
			"Указать список вручную"
		case "$UI_MENU_CHOICE" in
			1) config_set ISPCONFIG_ADMIN_IPS "$_adm_ssh"; ui_info "Доступ к панели — только с ${_adm_ssh}." ;;
			2) config_set ISPCONFIG_ADMIN_IPS "" ;;
			3) ui_input "IP через пробел (пусто = со всех)" "${ISPCONFIG_ADMIN_IPS:-$_adm_ssh}"
			   config_set ISPCONFIG_ADMIN_IPS "$UI_INPUT" ;;
		esac
	else
		ui_input "Разрешить вход в панель только с этих IP (через пробел; пусто = со всех)" "${ISPCONFIG_ADMIN_IPS:-}"
		config_set ISPCONFIG_ADMIN_IPS "$UI_INPUT"
	fi

	# Запрет входа в панель по IP (только по FQDN). Включается ТОЛЬКО при реальном
	# публичном FQDN и после успешного выпуска LE (этап hostcert проверяет, что домен
	# резолвится на этот сервер) — иначе можно случайно отрезать себе доступ.
	if [[ "${SERVER_FQDN:-}" == *.* ]]; then
		if ui_confirm "Запретить вход в панель по IP-адресу (разрешить только по https://${SERVER_FQDN}:${ISPCONFIG_PANEL_PORT:-8080})? Включится после проверки, что домен указывает на сервер."; then
			config_set PANEL_FQDN_ONLY y
		else
			config_set PANEL_FQDN_ONLY n
		fi
	fi

	# Что отдавать по IP / неизвестному домену на :80 (default-сервер nginx).
	if [[ "${WEBSERVER:-nginx}" == "nginx" ]]; then
		ui_menu "Доступ к сайту по IP (http://IP/ на :80)" 1 \
			"Лендинг — стартовая /var/www/html (roundcube/phpmyadmin доступны по IP)" \
			"Редирект на домен (301 → https://${SERVER_FQDN:-FQDN}); нужен публичный FQDN" \
			"Ничего (444) — по IP сайт не открывается (только по домену)"
		case "$UI_MENU_CHOICE" in
			1) config_set HTTP_IP_POLICY landing ;;
			2) config_set HTTP_IP_POLICY redirect ;;
			3) config_set HTTP_IP_POLICY deny ;;
		esac
	fi

	# HTTP/3 (QUIC) для панели/apps — только если nginx собран с поддержкой HTTP/3.
	# Устаревший «listen … http2» в любом случае будет исправлен на «http2 on;».
	if [[ "${WEBSERVER:-nginx}" == "nginx" && "${NGX_HTTP3:-${HTTP3:-n}}" == "y" ]]; then
		if ui_confirm "Включить HTTP/3 (QUIC) для панели и apps? (откроется UDP-порт; для админ-панели выигрыш небольшой)"; then
			config_set PANEL_HTTP3 y
		else
			config_set PANEL_HTTP3 n
		fi
		# QUIC-тюнинг (nginx docs). Безопасные дефолты — ВЫКЛ (как у самого nginx).
		if ui_confirm "QUIC: включить quic_gso? (быстрее, но на части virtio-NIC роняет HTTP/3 — поэтому по умолч. выкл)" n; then
			config_set NGX_QUIC_GSO y
		else
			config_set NGX_QUIC_GSO n
		fi
		if ui_confirm "QUIC: включить quic_retry? (валидация адреса клиента: защита от амплификации, +1 RTT на старте)" n; then
			config_set NGX_QUIC_RETRY y
		else
			config_set NGX_QUIC_RETRY n
		fi
	fi

	# SSH-порт меняется В САМОМ КОНЦЕ установки (после всех этапов), чтобы обрыв/
	# повтор не оставил сервер на нестандартном порту раньше времени.
	# Порт — число 1–65535 (неверный порт = смена SSH провалится или отрежет доступ).
	# По умолчанию — порт, на котором sshd работает сейчас (у части хостеров это не 22):
	# Enter не должен переносить SSH на другой порт.
	local _ssh_cur
	_ssh_cur="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')"
	[[ "$_ssh_cur" =~ ^[0-9]+$ ]] || _ssh_cur=22
	while true; do
		ui_input "Порт SSH (Enter — оставить текущий)" "${SSH_PORT:-$_ssh_cur}"
		if [[ "$UI_INPUT" =~ ^[0-9]+$ ]] && ((UI_INPUT >= 1 && UI_INPUT <= 65535)); then break; fi
		ui_warn "Порт должен быть числом 1–65535."
		[[ ! -t 0 ]] && break
	done
	config_set SSH_PORT "$UI_INPUT"

	# Ограничение доступа к SSH по IP (через firewall): только со своего IP или со всех.
	# ⚠ Опаснее, чем для панели/monit: ошибка/смена IP отрежет SSH — спасёт только
	# консоль/VNC провайдера. Работает при firewall=ufw.
	local _ssh_my; _ssh_my="$(_detect_ssh_ip)"
	if [[ -n "$_ssh_my" ]]; then
		ui_menu "Доступ к SSH (порт ${SSH_PORT:-22}) по IP" 2 \
			"Только с моего IP (${_ssh_my})" \
			"Со всех IP (без ограничения)" \
			"Указать список вручную"
		case "$UI_MENU_CHOICE" in
			1) config_set SSH_ALLOW_IPS "$_ssh_my"
			   ui_warn "SSH будет доступен ТОЛЬКО с ${_ssh_my}. Сменишь IP/провайдера — доступ пропадёт (нужна VNC/консоль VPS)." ;;
			2) config_set SSH_ALLOW_IPS "" ;;
			3) ui_input "IP через пробел (пусто = со всех)" "${SSH_ALLOW_IPS:-$_ssh_my}"
			   config_set SSH_ALLOW_IPS "$UI_INPUT" ;;
		esac
	else
		ui_input "Разрешить SSH только с этих IP (через пробел; пусто = со всех)" "${SSH_ALLOW_IPS:-}"
		config_set SSH_ALLOW_IPS "$UI_INPUT"
	fi

	# --- SSH-харденинг (применяется в конце установки) ---
	# X11/агент/TCP-проброс off и таймауты применяются всегда (SSH_SAFE=y, apply_ssh_safe).
	# Здесь спрашиваем только про вход по паролю: отключаем ТОЛЬКО при наличии рабочего ключа.
	ui_info "SSH: X11, проброс агента и TCP будут выключены, мёртвые сессии — закрываться (SSH_TCP_FORWARD=y, если нужны SSH-туннели)."
	if ui_confirm "Отключить вход по паролю в SSH (только по ключу)?" n; then
		config_set SSH_HARDEN y
		if declare -F _has_authorized_key >/dev/null && _has_authorized_key; then
			ui_info "Найден ~/.ssh/authorized_keys — вход по паролю будет безопасно отключён."
			config_set SSH_PUBKEY ""
		else
			ui_warn "Ключ для входа (authorized_keys) не найден."
			ui_box_top "Важно"
			ui_box_line "Без ключа вход по паролю НЕ отключим — иначе вы потеряете доступ к серверу."
			ui_box_line "Можно вставить свой ПУБЛИЧНЫЙ ключ сейчас (с локальной машины: cat ~/.ssh/id_ed25519.pub)."
			ui_box_bottom
			if ui_confirm "Вставить публичный SSH-ключ сейчас?" n; then
				ui_input "Публичный ключ (ssh-ed25519 AAAA... / ssh-rsa AAAA...)" ""
				config_set SSH_PUBKEY "$UI_INPUT"
			else
				config_set SSH_PUBKEY ""
				ui_info "Ключ не задан — будут применены только безопасные ужесточения (X11 off, лимиты)."
			fi
		fi
	else
		config_set SSH_HARDEN n
	fi

	# Усиление шаблонов сайтов ISPConfig (conf-custom). Необязательно и для опытных:
	# правит «живой» шаблон nginx_vhost.conf.master, по умолчанию ВЫКЛ. ТОЛЬКО для nginx —
	# фича редактирует nginx-шаблон (HTTP/3, security-заголовки и т.п.); на Apache этого
	# шаблона нет и она ничего не делает, поэтому и вопрос не показываем.
	if [[ "${WEBSERVER:-nginx}" == "nginx" ]] && \
		ui_confirm "Усилить шаблоны сайтов ISPConfig (HTTP/3, security-заголовки, запрет секретных/скрытых файлов, server_tokens off)?" n; then
		config_set HARDEN_CONF_CUSTOM y
		# HSTS — отдельно: принудительный HTTPS, ОПАСЕН без валидного сертификата
		# на всех поддоменах (браузер запомнит и заблокирует HTTP). По умолчанию нет.
		ui_box_top "HSTS (необязательно)"
		ui_box_line "Заставляет браузеры ходить ТОЛЬКО по HTTPS. Включайте, только если у ВСЕХ"
		ui_box_line "сайтов/поддоменов есть валидные сертификаты — иначе доступ к ним пропадёт."
		ui_box_bottom
		if ui_confirm "Включить HSTS (Strict-Transport-Security)?" n; then
			config_set HARDEN_HSTS y; else config_set HARDEN_HSTS n; fi
	else
		config_set HARDEN_CONF_CUSTOM n
		config_set HARDEN_HSTS n
	fi

	# --- ISPConfig: панели-расширения (управление стеком из веб-панели) ---
	# Все по умолчанию ВКЛ; здесь даём отказаться. Гейты частично зависят от выбранных
	# компонентов (бэкап/CrowdSec) и наличия инструментов (node/composer показываются в меню
	# только если реально установлены).
	ui_box_top "$(t "Панели-расширения ISPConfig")"
	ui_box_line "$(t "Доп. разделы в панели: бэкап (настройки+запуск+восстановление), уведомления")"
	ui_box_line "$(t "(email/Telegram), Node.js/Composer по сайтам, CrowdSec, Firewall IP-rules.")"
	ui_box_line "$(t "Все необязательны и не влияют на работу сайтов. Рекомендуется оставить.")"
	ui_box_bottom
	if ui_confirm "$(t "Ставить все панели-расширения ISPConfig (рекомендуется)?")" y; then
		config_set INSTALL_COMPOSER y
		config_set ISPC_NODECOMPOSER_PANEL y
		config_set ISPC_NOTIFY_PANEL y
		config_set ISPC_MAINT_PANEL y
		config_set ISPC_BACKUP_PANEL y
		config_set ISPC_CROWDSEC_PANEL y
		config_set ISPC_UFWBLOCK_PANEL y
		config_set ISPC_TRUSTED_PANEL y
	else
		# Composer глобально нужен и для jailed shell-юзеров (SSH-деплой), не только для панели.
		if ui_confirm "$(t "  Composer глобально (для SSH-деплоя в jail'ах и панели по сайтам)?")" y; then
			config_set INSTALL_COMPOSER y; else config_set INSTALL_COMPOSER n; fi
		if ui_confirm "$(t "  Панель Node.js/Composer (управление пакетами по сайтам)?")" y; then
			config_set ISPC_NODECOMPOSER_PANEL y; else config_set ISPC_NODECOMPOSER_PANEL n; fi
		if ui_confirm "$(t "  Панель уведомлений (email/Telegram из меню ISPConfig)?")" y; then
			config_set ISPC_NOTIFY_PANEL y; else config_set ISPC_NOTIFY_PANEL n; fi
		if ui_confirm "$(t "  Панель обслуживания (состояние сервера, обновление и настройки из ISPConfig)?")" y; then
			config_set ISPC_MAINT_PANEL y; else config_set ISPC_MAINT_PANEL n; fi
		if [[ " $UI_CHECK_RESULT " == *" backup "* ]]; then
			if ui_confirm "$(t "  Панель бэкапа (настройки + «Бэкап сейчас» + восстановление)?")" y; then
				config_set ISPC_BACKUP_PANEL y; else config_set ISPC_BACKUP_PANEL n; fi
		fi
		if [[ "${FIREWALL:-}" == "crowdsec" ]]; then
			if ui_confirm "$(t "  Панель CrowdSec (баны/метрики/решения в панели)?")" y; then
				config_set ISPC_CROWDSEC_PANEL y; else config_set ISPC_CROWDSEC_PANEL n; fi
		fi
		# Блок-лист ufw имеет смысл, только если ufw поднимается (FIREWALL=ufw ИЛИ crowdsec+ufw)
		if [[ "${FIREWALL:-}" == "ufw" || ( "${FIREWALL:-}" == "crowdsec" && "${CROWDSEC_WITH_UFW:-y}" == "y" ) ]]; then
			if ui_confirm "$(t "  Панель «Firewall: блок-лист» (ручной ufw-deny IP/подсетей + подсказки)?")" y; then
				config_set ISPC_UFWBLOCK_PANEL y; else config_set ISPC_UFWBLOCK_PANEL n; fi
		fi
		if ui_confirm "$(t "  Панель «Доверенные IP» (белый список для CrowdSec и fail2ban + поиск, где забанен IP)?")" y; then
			config_set ISPC_TRUSTED_PANEL y; else config_set ISPC_TRUSTED_PANEL n; fi
	fi

	# Применяем выбор компонентов к state (optional → skipped/pending)
	apply_component_selection "$COMPONENTS"

	echo ""
	ui_success "Настройка сохранена в setup.conf"
	show_config_summary
	# Явное подтверждение перед стартом: веб-сервер — самый «дорогой» выбор (меняется
	# только переустановкой), поэтому переспрашиваем именно про него, чтобы поймать
	# случайный промах в меню до начала установки.
	if [[ -t 0 ]]; then
		ui_confirm "Веб-сервер будет ${UI_BOLD}${WEBSERVER:-—}${UI_NC}. Всё верно — начать установку?" y || {
			ui_info "Отменено. Запустите снова (${UI_W}$(ls_hint)${UI_NC}) и поправьте выбор в мастере."
			exit 0
		}
	else
		ui_pause
	fi
}

show_config_summary() {
	ui_box_top "Текущая конфигурация"
	ui_box_line "${UI_BOLD}➤ ВЕБ-СЕРВЕР:  ${WEBSERVER:-—}${UI_NC}   ${UI_D}(сменить — только переустановкой)${UI_NC}"
	local geoip_state="выкл"
	if [[ "${GEOIP:-n}" == "y" ]]; then
		if [[ -n "${GEOIP2_LICENSE_KEY:-}" ]]; then geoip_state="вкл (ключ задан)"; else geoip_state="вкл (⚠ без ключа)"; fi
	fi
	if [[ "${WEBSERVER:-}" == "nginx" ]]; then
		local _ngmods=""
		for _m in $NGINX_ALL_MODULES; do
			local _v; _v="$(eval "echo \${NGX_${_m}:-}")"
			[[ "$_v" == "y" ]] && _ngmods+="${_m,,} "
		done
		ui_box_line "nginx:         ${UI_W}${NGINX_CHANNEL:-stable} · профиль ${NGINX_PROFILE:-recommended}${UI_NC}"
		ui_box_line "  модули:      ${UI_D}${_ngmods:-—}${UI_NC}"
		[[ "${NGX_HTTP3:-y}" == "y" ]] && ui_box_line "  OpenSSL:     ${UI_W}${OPENSSL_VER:-ветка ${OPENSSL_BRANCH:-3.5}}${UI_NC}"
		ui_box_line "GeoIP2:        ${UI_W}${geoip_state}${UI_NC}"
	fi
	ui_box_line "PHP:           ${UI_W}${PHP_VERSIONS:-—}${UI_NC} (по умолчанию ${PHP_DEFAULT:-—})"
	local mdb="${MARIADB_SOURCE:-official}"
	if [[ "$mdb" == "official" ]]; then
		if [[ -n "${MARIADB_VERSION:-}" ]]; then mdb="офиц. репо MariaDB ${MARIADB_VERSION}"
		else mdb="офиц. репо MariaDB (авто: последняя LTS)"; fi
	else mdb="репо Debian"; fi
	ui_box_line "MariaDB:       ${UI_W}${mdb}${UI_NC}"
	ui_box_line "Redis:         ${UI_W}$([[ "${INSTALL_REDIS:-y}" == "y" ]] && echo "вкл" || echo "выкл")${UI_NC}"
	ui_box_line "Компоненты:    ${UI_W}${COMPONENTS:-—}${UI_NC}"
	[[ " ${COMPONENTS:-} " == *" webmail "* ]] && \
		ui_box_line "Roundcube:     ${UI_W}$([[ "${RC_SOURCE:-upstream}" == "debian" ]] && echo "пакет Debian" || echo "с сайта разработчиков, ветка ${RC_BRANCH:-1.6}")${UI_NC}"
	local _utn; _utn=$(echo ${UTILS:-} | wc -w)
	ui_box_line "Утилиты:       ${UI_W}${_utn} выбрано${UI_NC} (${UTILS:-—})"
	ui_box_line "FQDN:          ${UI_W}${SERVER_FQDN:-—}${UI_NC}"
	ui_box_line "Часовой пояс:  ${UI_W}${TIMEZONE:-—}${UI_NC}"
	ui_box_line "Firewall:      ${UI_W}${FIREWALL:-—}${UI_NC}"
	ui_box_line "ISPConfig:     ${UI_W}ветка ${ISPCONFIG_BRANCH:-stable}${UI_NC} · порт ${ISPCONFIG_PANEL_PORT:-8080}"
	[[ -n "${SSH_PORT:-}" && "${SSH_PORT}" != "22" ]] && \
		ui_box_line "SSH-порт:      ${UI_Y}${SSH_PORT} (сменится в конце установки)${UI_NC}"
	[[ -n "${SSH_ALLOW_IPS:-}" ]] && \
		ui_box_line "SSH-доступ:    ${UI_Y}только с IP: ${SSH_ALLOW_IPS}${UI_NC}"
	ui_box_bottom
}

# =============================================================================
# ИТОГОВЫЙ ЭКРАН
# =============================================================================
# Сохранить ключевые доступы в файл — чтобы не потерять при закрытии терминала
# (сводка на экране иначе исчезает безвозвратно). Только root, chmod 600.
_write_access_file() {
	local f=/root/server-access.txt
	local fqdn="${SERVER_FQDN:-<server-ip>}" pport="${ISPCONFIG_PANEL_PORT:-8080}"
	{
		echo "============================================================"
		echo " Доступы к серверу — сгенерировано LuckyStack"
		echo " Дата: $(date '+%F %T')    FQDN: ${fqdn}"
		echo " Файл только для root (chmod 600). Не передавайте по открытым каналам."
		echo "============================================================"
		echo ""
		echo "[ Панель ISPConfig ]"
		echo "  URL:    https://${fqdn}:${pport}"
		[[ -n "${ISPCONFIG_ADMIN_IPS:-}" ]] && echo "  Доступ: ТОЛЬКО с IP ${ISPCONFIG_ADMIN_IPS}"
		echo "  Логин:  admin"
		echo "  Пароль: ${ISPCONFIG_ADMIN_PW:-<см. ${CONFIG_FILE:-setup.conf}: ISPCONFIG_ADMIN_PW>}"
		echo "  Совет:  включите 2FA — в панели: Tools -> (профиль) -> Two Factor Authentication (TOTP)."
		echo ""
		if [[ "$(state_get phpmyadmin)" == "done" ]]; then
			echo "[ Веб-админка БД ]"
			echo "  URL:    http://${fqdn}/phpmyadmin  (или /adminer) — логин: учётка MariaDB"
			echo ""
		fi
		if [[ "$(state_get webmail)" == "done" ]]; then
			echo "[ Webmail (Roundcube) ]"
			echo "  URL:    https://${fqdn}/roundcube — вход: e-mail ящика + его пароль"
			echo ""
		fi
		if [[ "$(state_get monit)" == "done" && "${MONIT_EXPOSE:-n}" == "y" ]]; then
			echo "[ Monit ]"
			echo "  URL:    https://${fqdn}:2812  (admin / пароль: MONIT_PASSWORD в ${CONFIG_FILE:-setup.conf})"
			[[ -n "${MONIT_ALLOW_IP:-}" ]] && echo "  Доступ: ТОЛЬКО с IP ${MONIT_ALLOW_IP}"
			echo ""
		fi
		[[ "$(state_get maildeliver)" == "done" ]] && {
			echo "[ Почта ]"
			echo "  DNS-записи (SPF/DKIM/DMARC/PTR): /root/mail-dns-records.txt — опубликовать у DNS-провайдера"
			echo ""
		}
		echo "[ Остальные пароли ]"
		echo "  ${CONFIG_FILE:-setup.conf} (chmod 600): MARIADB_ROOT_PW, ISPCONFIG_DB_PW,"
		echo "  POSTGRES_PASSWORD, RSPAMD_PASSWORD, ROUNDCUBE_DB_PW, MONIT_PASSWORD и др."
		echo ""
		echo "[ Первые шаги ]"
		echo "  Гайд новичка: /root/GETTING-STARTED.md (войти в панель, завести сайт/ящик/DNS)"
		echo ""
		echo "[ Обслуживание ]"
		echo "  Проверка здоровья:  $(ls_hint --healthcheck)"
		echo "  Статус/версии:      $(ls_hint --status)"
		echo "  Диагностика:        $(ls_hint --diagnostics)  (архив для поддержки)"
		echo "  Лог установки:      ${SETUP_LOG}"
		echo "  SSH:                порт ${SSH_PORT:-22}"
	} > "$f" 2>/dev/null && chmod 600 "$f" 2>/dev/null || true
}

run_summary() {
	clear 2>/dev/null || true
	ui_header "Установка завершена"
	local key st done_n=0 skip_n=0 fail_n=0
	ui_box_top "Результаты по этапам"
	for key in "${STAGE_KEYS[@]}"; do
		st=$(state_get "$key")
		case "$st" in
			done)    ui_box_line "${UI_G}✓${UI_NC} ${STAGE_LABELS[$key]}"; ((done_n++)) ;;
			skipped) ui_box_line "${UI_D}○${UI_NC} ${STAGE_LABELS[$key]} ${UI_D}(пропущен)${UI_NC}"; ((skip_n++)) ;;
			failed)  ui_box_line "${UI_R}✗${UI_NC} ${STAGE_LABELS[$key]} ${UI_R}(ошибка)${UI_NC}"; ((fail_n++)) ;;
			*)       ui_box_line "${UI_Y}▸${UI_NC} ${STAGE_LABELS[$key]} ${UI_Y}(не выполнен)${UI_NC}" ;;
		esac
	done
	ui_box_bottom
	echo ""
	ui_success "Выполнено: $done_n   Пропущено: $skip_n   Ошибок: $fail_n"
	echo ""
	ui_box_top "Доступ"
	ui_box_line "Панель ISPConfig:  ${UI_C}https://${SERVER_FQDN:-<server>}:${ISPCONFIG_PANEL_PORT:-8080}${UI_NC}"
	[[ -n "${ISPCONFIG_ADMIN_IPS:-}" ]] && \
		ui_box_line "                   ${UI_Y}⚠ доступ к панели разрешён ТОЛЬКО с IP: ${ISPCONFIG_ADMIN_IPS}${UI_NC}"
	# Веб-админка БД — инструмент зависит от выбора (Adminer/phpMyAdmin)
	if [[ "$(state_get phpmyadmin)" == "done" ]]; then
		case "$(declare -F _dbadmin_tool >/dev/null && _dbadmin_tool)" in
			adminer)    ui_box_line "Adminer:           ${UI_C}http://${SERVER_FQDN:-<server>}/adminer/${UI_NC} (MariaDB + PostgreSQL)" ;;
			phpmyadmin) ui_box_line "phpMyAdmin:        ${UI_C}http://${SERVER_FQDN:-<server>}/phpmyadmin${UI_NC} (логин: учётка MariaDB)" ;;
		esac
	fi
	if [[ "$(state_get postgresql)" == "done" ]]; then
		if [[ "${WEBSERVER:-nginx}" == "apache" ]]; then
			ui_box_line "pgAdmin:           ${UI_C}http://${SERVER_FQDN:-<server>}/pgadmin4${UI_NC} (логин: ${PGADMIN_EMAIL:-admin})"
		else
			ui_box_line "Adminer (для PG):  ${UI_C}http://${SERVER_FQDN:-<server>}/adminer/${UI_NC} (System → PostgreSQL)"
		fi
		ui_box_line "PostgreSQL:        ${UI_D}роль postgres / пароль в setup.conf${UI_NC}"
	fi
	[[ "$(state_get nodejs)" == "done" ]] && \
		ui_box_line "Node.js:           ${UI_W}${NODEJS_VERSION:-22}.x${UI_NC} (node, npm)"
	if [[ "$(state_get monit)" == "done" ]]; then
		if [[ "${MONIT_EXPOSE:-n}" == "y" && -n "${MONIT_ALLOW_IP:-}" ]]; then
			ui_box_line "Monit:             ${UI_C}https://${SERVER_FQDN:-<server>}:2812${UI_NC} (admin / MONIT_PASSWORD)"
			ui_box_line "                   ${UI_Y}⚠ доступ к Monit разрешён ТОЛЬКО с IP: ${MONIT_ALLOW_IP} · по HTTPS${UI_NC}"
		else
			ui_box_line "Monit:             ${UI_C}http://localhost:2812${UI_NC} (admin / MONIT_PASSWORD) — ${UI_D}через SSH-туннель${UI_NC}"
		fi
	fi
	[[ "$(state_get hostcert)" == "done" ]] && \
		ui_box_line "TLS хоста:         ${UI_D}LE для FQDN (панель + почта) — если домен публичный; иначе self-signed${UI_NC}"
	if [[ "$(state_get webmail)" == "done" ]]; then
		if [[ "$(state_get hostcert)" == "done" && "${HOST_FQDN_SITE:-y}" == "y" && "${SERVER_FQDN:-}" == *.* ]]; then
			ui_box_line "Roundcube webmail: ${UI_C}https://${SERVER_FQDN}/roundcube${UI_NC} (вход: e-mail + пароль ящика)"
		else
			ui_box_line "Roundcube webmail: ${UI_C}http://${SERVER_FQDN:-<server>}/roundcube${UI_NC} (вход: e-mail + пароль ящика)"
		fi
	fi
	[[ "$(state_get rcplugins)" == "done" ]] && \
		ui_box_line "Roundcube+ISPConfig: ${UI_D}самообслуживание: пароль/автоответчик/фильтры/пересылка${UI_NC}"
	[[ "$(state_get maildeliver)" == "done" ]] && \
		ui_box_line "DNS для почты:     ${UI_D}/root/mail-dns-records.txt${UI_NC} (опубликовать у DNS-провайдера)"
	[[ "$(state_get mailsni)" == "done" ]] && \
		ui_box_line "Per-domain TLS:    ${UI_D}SNI активен · ispconfig-mail-sni.sh (обновляется по таймеру)${UI_NC}"
	[[ "$(state_get tuning)" == "done" ]] && \
		ui_box_line "Авто-тюнинг:       ${UI_D}MariaDB/PHP/Postfix под RAM/CPU${UI_NC}"
	[[ "$(state_get backup)" == "done" ]] && \
		ui_box_line "Бэкапы:            ${UI_D}${BACKUP_DIR:-/var/backups/server} · server-backup.sh --list${UI_NC}"
	_write_access_file
	ui_box_line "${UI_G}Доступы (файл):    ${UI_W}/root/server-access.txt${UI_NC}${UI_G} — URL/логины/где пароли (chmod 600)${UI_NC}"
	# Кладём онбординг-гайд рядом с админом — «что делать дальше» для новичка
	[[ -f "$SCRIPT_DIR/GETTING-STARTED.md" ]] && cp -f "$SCRIPT_DIR/GETTING-STARTED.md" /root/ 2>/dev/null || true
	[[ -f /root/GETTING-STARTED.md ]] && \
		ui_box_line "${UI_C}Первые шаги:       ${UI_W}/root/GETTING-STARTED.md${UI_NC}${UI_C} — как завести сайт/ящик/DNS${UI_NC}"
	ui_box_line "Лог установки:     ${UI_D}${SETUP_LOG}${UI_NC}"
	ui_box_line "Состояние:         ${UI_D}${STATE_FILE}${UI_NC}"
	ui_box_line "Проверка здоровья: ${UI_D}$(ls_hint --healthcheck)${UI_NC}"
	ui_box_bottom
	if ((fail_n > 0)); then
		echo ""
		ui_warn "Есть этапы с ошибками. Повторить их: $(ls_hint --resume)"
	fi
}

# =============================================================================
# ГЛАВНОЕ МЕНЮ — показывается при интерактивном запуске без явного режима-флага.
# Просмотры (состояние, здоровье, почтовые порты) идут прямо здесь. Всё, что меняет
# сервер, запускается отдельным процессом (_menu_run): у действия своё состояние
# (DRY_RUN, загруженный конфиг, блокировки), а меню после него возвращается.
# =============================================================================

# Действие из меню отдельным процессом, потом итог и возврат в меню.
# Ctrl+C прерывает только действие: у меню на время запуска свой обработчик INT
# (обработчик, в отличие от игнора, ребёнку не наследуется).
_menu_run() {
	local self="$SCRIPT_DIR/server-setup.sh" rc a pass=()
	if declare -F ls_running_installed >/dev/null && ls_running_installed \
	   && [[ -f "$LS_OPT_DIR/current/server-setup.sh" ]]; then
		self="$LS_OPT_DIR/current/server-setup.sh"   # после обновления сразу новый код
	fi
	[[ -n "${UI_LANG_ARG:-}" ]] && pass+=(--lang "$UI_LANG_ARG")
	((DRY_RUN)) && pass+=(--dry-run)
	trap ':' INT
	LS_MENU_CHILD=1 bash "$self" "${pass[@]}" "$@"; rc=$?
	trap - INT
	echo ""
	case $rc in
		0)   ui_success "Готово." ;;
		130) ui_warn "Прервано (Ctrl+C)." ;;
		*)   ui_error "Завершилось с ошибкой (код ${rc}). Журнал: ${SETUP_LOG}" ;;
	esac
	echo -en "${UI_D}$(t "Enter вернёт в меню, 0 выход"): ${UI_NC}"
	read -r a || exit "$rc"
	[[ "$a" == 0 ]] && { ui_info "Выход."; exit 0; }
	return 0
}

main_menu() {
	local has_progress incomplete
	while true; do
		has_progress=0; incomplete=0   # действие могло поменять состояние установки
		state_has_progress && has_progress=1
		state_is_incomplete && incomplete=1
		clear 2>/dev/null || true
		ui_header "LuckyStack v$VERSION"

		local os="?"; [[ -r /etc/os-release ]] && os="$(. /etc/os-release; echo "$PRETTY_NAME")"
		ui_box_top "Сервер"
		ui_box_line "  ОС: ${UI_W}${os}${UI_NC}"
		[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] && \
			ui_box_line "  ISPConfig: ${UI_G}установлен${UI_NC}"
		if ((incomplete)); then
			ui_box_line "  ${UI_Y}Обнаружена незавершённая/частичная установка${UI_NC}"
		elif ((has_progress)); then
			ui_box_line "  ${UI_G}Установка завершена (все этапы выполнены)${UI_NC}"
		fi
		ui_box_bottom

		local labels=() actions=()
		if ((incomplete)); then
			labels+=("Продолжить установку (с незавершённого этапа)"); actions+=(resume)
			labels+=("Перенастроить заново (мастер настройки)");       actions+=(reconfigure)
			labels+=("Начать заново (сброс состояния установки)");     actions+=(reset)
		elif ((has_progress)); then
			labels+=("Перенастроить / доустановить (мастер настройки)"); actions+=(reconfigure)
			labels+=("Начать заново (сброс состояния установки)");       actions+=(reset)
		else
			labels+=("Установить / настроить сервер (мастер)");        actions+=(install)
		fi
		labels+=("Режим обновления / патчей (безопасно, без ядра)"); actions+=(update)
		labels+=("Добавить версию PHP");                            actions+=(phpadd)
		labels+=("Удалить версии PHP (по выбору)");                 actions+=(phpremove)
		labels+=("Сменить часовой пояс (система, PHP, MariaDB, cron)"); actions+=(timezone)
		labels+=("Состояние системы (что установлено + версии)");  actions+=(status)
		labels+=("Проверка здоровья сервера (healthcheck)");       actions+=(health)
		labels+=("Проверка блокировки почтовых портов хостером");  actions+=(mailports)
		[[ -x /usr/local/sbin/server-backup.sh ]] && { labels+=("Восстановить из резервной копии"); actions+=(restore); }
		labels+=("Демо-прогон (--dry-run, ничего не меняет)");     actions+=(dryrun)
		labels+=("Удалить компоненты (uninstall)");                actions+=(uninstall)

		# Установка завершена — по Enter безопасная проверка здоровья, а не перенастройка всего сервера
		# (случайный Enter после «Готово» запускал мастер заново).
		local _def=1 _j
		if ((has_progress && !incomplete)); then
			for _j in "${!actions[@]}"; do [[ "${actions[$_j]}" == health ]] && _def=$((_j + 1)); done
		fi
		UI_MENU_ZERO="Выход"
		ui_menu "Главное меню" "$_def" "${labels[@]}"
		((UI_MENU_CHOICE == 0)) && { ui_info "Выход."; exit 0; }
		case "${actions[$((UI_MENU_CHOICE - 1))]}" in
			install)     _menu_run ;;
			resume)      _menu_run --resume ;;
			reconfigure) _menu_run --reconfigure ;;
			reset)
				state_reset
				if ui_confirm "Очистить также кеш сборки (исходники nginx/ISPConfig, сборка с нуля)?" y; then
					_menu_run --clean-build
				else
					_menu_run
				fi
				;;
			dryrun)
				ui_warn "Демо-режим: этапы только имитируются, изменений в системе не будет."
				_menu_run --dry-run
				;;
			status)
				show_system_status; ui_pause ;;
			health)
				if declare -F run_healthcheck >/dev/null; then run_healthcheck; else ui_warn "healthcheck недоступен."; fi
				ui_pause ;;
			mailports)
				if declare -F run_mailport_check >/dev/null; then run_mailport_check; else ui_warn "проверка почтовых портов недоступна."; fi
				ui_pause ;;
			update)      _menu_run --update ;;
			timezone)    _menu_run --timezone ;;
			phpadd)      _menu_run --add-php ;;
			phpremove)   _menu_run --remove-php ;;
			restore)     _menu_run --restore ;;
			uninstall)   _menu_run --uninstall ;;
		esac
	done
}

# Выбор языка при ПЕРВОМ интерактивном запуске. Приоритет: --lang > сохранённый UI_LANG
# (setup.conf) > вопрос пользователю > ru. Ответ сохраняется в setup.conf → больше не спросит.
# Метки нейтральны к языку (спрашиваем ДО того, как язык выбран).
_ensure_language() {
	type i18n_load >/dev/null 2>&1 || return 0
	# 1) явный --lang — уважаем, не спрашиваем
	if [[ -n "${UI_LANG_ARG:-}" ]]; then UI_LANG="$UI_LANG_ARG"; i18n_load "$UI_LANG"; return 0; fi
	# 2) уже сохранён в setup.conf — берём (без полного config_load)
	local saved=""
	[[ -f "$CONFIG_FILE" ]] && saved="$(grep -m1 '^UI_LANG=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d "\"'")"
	if [[ -n "$saved" ]]; then UI_LANG="$saved"; i18n_load "$UI_LANG"; return 0; fi
	# 3) неинтерактивно / --unattended — тихо русский по умолчанию
	if [[ "${UNATTENDED:-0}" == "1" || ! -t 0 || ! -t 1 ]]; then UI_LANG="${UI_LANG:-ru}"; i18n_load "$UI_LANG"; return 0; fi
	# 4) первый интерактивный запуск — спрашиваем
	ui_menu "Выберите язык / Choose language" 1 "Русский" "English"
	case "${UI_MENU_CHOICE:-1}" in 2) UI_LANG=en ;; *) UI_LANG=ru ;; esac
	i18n_load "$UI_LANG"
	declare -F config_set >/dev/null && config_set UI_LANG "$UI_LANG" >/dev/null 2>&1 || true
}

# =============================================================================
# ГЛАВНЫЙ ПОТОК
# =============================================================================
main() {
	log_init

	# Код должен работать из /opt/luckystack. Чистый сервер: ставим туда и перезапускаемся.
	if declare -F ls_guard_code_location >/dev/null; then
		ls_guard_code_location; local _g=$?
		((_g == 100)) && exit 0
		((_g != 0)) && exit "$_g"
		if [[ $EUID -eq 0 && ! -L "${LS_BIN:-/usr/local/sbin/luckyctl}" ]] && ls_running_installed; then
			ls_install_cli || true
		fi
	fi
	if ((DO_INSTALL_CODE)); then
		ui_info "Эта копия уже рабочий выпуск LuckyStack (${SCRIPT_DIR}), ставить нечего."
		exit 0
	fi

	_ensure_language   # первый запуск: выбор языка (сохраняется, для всех режимов)

	# Копия с Windows приезжает 777: любой локальный пользователь мог бы подменить код,
	# который дальше выполняется от root. Снимаем запись для группы и «других».
	if [[ $EUID -eq 0 ]] && [[ -n "$(find "$SCRIPT_DIR" -xdev ! -type l -perm /022 -print -quit 2>/dev/null)" ]]; then
		perm_strip_gw_ow "$SCRIPT_DIR"
		ui_warn "Каталог установщика был открыт на запись (обычно после копирования с Windows). Права исправлены: chmod go-w."
	fi

	# Само-обновление / проверка версии установщика с GitHub (root не нужен — пишем в каталог скрипта)
	if ((DO_CHECK_UPDATE)); then
		if declare -F run_check_update >/dev/null; then run_check_update; exit $?; fi
		ui_error "lib/selfupdate.sh не подключён."; exit 1
	fi
	if ((DO_SELF_UPDATE)); then
		if declare -F run_self_update >/dev/null; then run_self_update; exit $?; fi
		ui_error "lib/selfupdate.sh не подключён."; exit 1
	fi

	# Инвентаризация — что установлено и какие версии (root не нужен)
	if ((DO_STATUS)); then show_system_status; exit 0; fi

	# Проверка здоровья — read-only диагностика (часть проверок точнее под root)
	if ((DO_HEALTHCHECK)); then
		if declare -F run_healthcheck >/dev/null; then run_healthcheck; exit $?; fi
		ui_error "lib/healthcheck.sh не подключён."; exit 1
	fi

	# Diagnostics-bundle — обезличенный архив для поддержки (нужен root: журнал/конфиги)
	if ((DO_DIAGNOSTICS)); then
		require_root
		if declare -F run_diagnostics >/dev/null; then run_diagnostics; exit $?; fi
		ui_error "lib/healthcheck.sh не подключён."; exit 1
	fi

	# Восстановление из бэкапа — пишет в систему, нужен root
	if ((DO_RESTORE)); then
		require_root
		if declare -F run_backup_restore >/dev/null; then run_backup_restore; exit $?; fi
		ui_error "lib/backup.sh не подключён."; exit 1
	fi

	# Режим обновления/патчей — безопасное сопровождение (без ядра)
	if ((DO_UPDATE)); then
		if declare -F run_update_mode >/dev/null; then run_update_mode; exit $?; fi
		ui_error "lib/update.sh не подключён."; exit 1
	fi

	# Откат nginx или Roundcube на прошлую версию
	if ((DO_ROLLBACK)); then
		if declare -F run_rollback_mode >/dev/null; then run_rollback_mode; exit $?; fi
		ui_error "lib/update.sh не подключён."; exit 1
	fi

	# Доустановка версий PHP — пишет в систему, нужен root
	if ((DO_PHP_ADD)); then
		require_root
		config_load || true
		if declare -F run_php_add >/dev/null; then run_php_add; exit $?; fi
		ui_error "lib/php.sh не подключён."; exit 1
	fi

	# Удаление выбранных версий PHP (интерактивно, с защитой) — пишет в систему, нужен root
	if ((DO_PHP_REMOVE)); then
		require_root
		if declare -F run_php_remove >/dev/null; then run_php_remove; exit $?; fi
		ui_error "lib/php.sh не подключён."; exit 1
	fi

	# Смена часового пояса везде (система, PHP, MariaDB, cron) — пишет в систему, нужен root
	if ((DO_TIMEZONE)); then
		config_load || true
		if declare -F run_timezone_mode >/dev/null; then run_timezone_mode; exit $?; fi
		ui_error "lib/preflight.sh не подключён."; exit 1
	fi

	# Adopt-режим — аддоны на уже установленный (ручной) сервер: бэкап + подтверждение,
	# только server-agnostic, ядро/шаблоны ISPConfig не трогаются
	if ((DO_ADOPT)); then
		if declare -F run_adopt_mode >/dev/null; then run_adopt_mode; exit $?; fi
		ui_error "lib/update.sh не подключён."; exit 1
	fi

	# Режим удаления — отдельная ветка, не трогает установку
	if ((DO_UNINSTALL)); then
		if declare -F run_uninstall >/dev/null; then run_uninstall; exit $?; fi
		ui_error "lib/uninstall.sh не подключён."; exit 1
	fi

	require_root
	check_os

	clear 2>/dev/null || true
	ui_header "LuckyStack v$VERSION"
	if ((DRY_RUN)); then ui_warn "Режим --dry-run: этапы только имитируются."; fi

	# Загружаем существующий конфиг, если есть
	config_load || true

	# Язык интерфейса: флаг --lang приоритетнее UI_LANG из setup.conf. Переприменяем
	# после config_load (мог принести UI_LANG), но не затираем явный --lang.
	if type i18n_load >/dev/null 2>&1; then
		[[ -n "${UI_LANG_ARG:-}" ]] && UI_LANG="$UI_LANG_ARG"
		i18n_load "${UI_LANG:-ru}"
	fi

	# --resume без незавершённой установки — нечего продолжать (иначе молча ушли бы
	# в полный мастер мимо предохранителя).
	if ((DO_RESUME)) && ! state_has_progress; then
		ui_error "--resume: нет незавершённой установки (setup.state пуст)."
		ui_info  "Новая установка: $(ls_hint). Один этап: $(ls_hint --only "<этап>")."
		exit 1
	fi

	# Стартовое главное меню — при ИНТЕРАКТИВНОМ запуске без явно заданного режима.
	# Явные флаги (--unattended/--resume/--only/--from) и не-tty его пропускают.
	local show_menu=1
	((UNATTENDED)) && show_menu=0
	((DO_RESUME))  && show_menu=0
	# `luckyctl install --reconfigure` и т.п. — режим уже выбран, меню его только перебивало
	((${DO_RECONFIGURE:-0} || ${CLEAN_BUILD:-0} || ${FORCE:-0})) && show_menu=0
	[[ -n "$ONLY_STAGE" || -n "$START_FROM" ]] && show_menu=0
	[[ -t 0 ]] || show_menu=0
	# Запуск из главного меню: меню уже было, второй раз его не показываем
	# и не переспрашиваем про незавершённую установку ниже.
	local menu_seen=$show_menu
	[[ -n "${LS_MENU_CHILD:-}" ]] && { show_menu=0; menu_seen=1; }
	((show_menu)) && main_menu

	# Предохранитель: ПОЛНАЯ установка на уже настроенном (не нами) сервере.
	# Срабатывает только для полного прогона (не --only/--from/--resume/--unattended/
	# --update) и когда нашего setup.state нет, но сервер выглядит «обжитым».
	# Примечание: --from НЕ исключается из предохранителя (он гоняет core-этапы и
	# опасен на чужом сервере так же, как полный прогон).
	if [[ -z "$ONLY_STAGE" ]] && ! ((DO_RESUME || UNATTENDED || DO_UPDATE)) \
	   && ! state_has_progress \
	   && declare -F _detect_existing_install >/dev/null && _detect_existing_install; then
		# Внутри: уход в --update / подсказку --only / выход, либо return 0 при
		# подтверждённой перезаписи (OVERWRITE) — тогда продолжаем полный прогон.
		_existing_install_guard
	fi

	# Определяем, нужен ли мастер настройки
	local need_wizard=1
	if ((UNATTENDED)); then
		if [[ -f "$CONFIG_FILE" ]]; then
			need_wizard=0
			ui_info "Режим --unattended: используется существующий setup.conf"
		else
			ui_error "--unattended требует готовый setup.conf, но его нет."
			exit 1
		fi
	elif ((DO_RESUME)) && state_has_progress && [[ -f "$CONFIG_FILE" ]]; then
		need_wizard=0
		ui_info "Продолжение прерванной установки (--resume)."
	elif ((DO_RECONFIGURE)); then
		need_wizard=1
	elif [[ -n "$ONLY_STAGE" ]]; then
		# Точечный перезапуск этапа (--only): переиспользуем существующий setup.conf,
		# мастер НЕ запускаем. Без конфига — НЕ гоним полный мастер ради одного этапа
		# (на non-tty он бы завис на read), а явно требуем готовый setup.conf.
		if [[ -f "$CONFIG_FILE" ]]; then
			need_wizard=0
			ui_info "Режим --only: используется существующий setup.conf (мастер пропущен)."
		else
			ui_error "--only '${ONLY_STAGE}' требует готовый setup.conf, но его нет (${CONFIG_FILE})."
			ui_info  "Сначала выполните установку (или хотя бы мастер настройки), затем повторяйте этап: $(ls_hint --only "<этап>")."
			exit 1
		fi
	elif state_is_incomplete && ((menu_seen == 0)); then
		# Установка НЕ завершена (есть незакрытые этапы), resume не указан И стартовое
		# меню не показывалось (не-tty / явный режим) — спросим здесь.
		ui_warn "Обнаружена незавершённая установка."
		ui_menu "Что сделать?" 1 \
			"Продолжить с незавершённого этапа" \
			"Перенастроить заново (мастер)" \
			"Начать с чистого листа (сброс состояния)" \
			"Удалить компоненты (uninstall)" \
			"Показать состояние системы (что установлено + версии)"
		case "$UI_MENU_CHOICE" in
			1) need_wizard=0 ;;
			2) need_wizard=1 ;;
			3)
				state_reset; need_wizard=1
				# «Чистый лист» = заново; предложим убрать и кеш сборки,
				# чтобы исходники прошлых попыток не переиспользовались.
				if ui_confirm "Очистить также кеш сборки (исходники nginx/ISPConfig, сборка пойдёт с нуля)?" y; then
					CLEAN_BUILD=1
				fi
				;;
			4) run_uninstall; exit $? ;;
			5) show_system_status; ui_pause; exit 0 ;;
		esac
	fi

	# Очистка кеша сборки (по флагу --clean-build или выбору выше)
	((CLEAN_BUILD)) && clean_build_cache

	# Отключить битые apt-репозитории (напр. мёртвый bullseye-backports на Debian 11)
	# ДО любых этапов — иначе apt update валит установку. Работает и для --only/--resume.
	declare -F disable_broken_apt_sources >/dev/null && disable_broken_apt_sources

	# --- Режим одного этапа (--only): отдельная установка компонента ---
	if [[ -n "$ONLY_STAGE" ]]; then
		# Спец-цель `ssh`: НЕ этап, а финальные SSH-шаги (харденинг + ограничение по IP +
		# смена порта). Нужна, если полный прогон до них не дошёл / добивали через --only.
		if [[ "$ONLY_STAGE" == "ssh" ]]; then
			((need_wizard)) && run_wizard
			ui_header "Применение SSH-настроек (харденинг + смена порта)"
			# Сюда же отправляет откат анти-лок-аута, а он выключает firewall: под той же
			# страховкой возвращаем и SSH, и ufw, и снова ждём подтверждения доступа.
			declare -F _net_safety_arm      >/dev/null && _net_safety_arm
			declare -F apply_ssh_hardening  >/dev/null && apply_ssh_hardening
			declare -F apply_ssh_safe       >/dev/null && apply_ssh_safe
			declare -F apply_ssh_port       >/dev/null && apply_ssh_port
			declare -F _ufw_ensure_enabled  >/dev/null && _ufw_ensure_enabled
			ui_info "Ограничение по IP (SSH_ALLOW_IPS) применяется через firewall — это этап security."
			ui_success "SSH-настройки применены (режим --only ssh)."
			declare -F _net_safety_announce >/dev/null && _net_safety_announce
			log "=== LuckyStack завершён (only: ssh) ==="
			return 0
		fi
		local only_fn="stage_${ONLY_STAGE}"
		if ! declare -F "$only_fn" >/dev/null; then
			ui_error "Неизвестный этап '${ONLY_STAGE}'. Доступные: ${STAGE_KEYS[*]} ssh"
			exit 1
		fi
		((need_wizard)) && run_wizard
		# Снимаем возможный skipped (компонент мог быть не выбран ранее)
		[[ "$(state_get "$ONLY_STAGE")" == "skipped" ]] && state_set "$ONLY_STAGE" pending
		FORCE=1 run_step "$ONLY_STAGE" "$only_fn"
		ui_success "Этап '${ONLY_STAGE}' выполнен (режим --only). Остальные этапы не запускались."
		log "=== LuckyStack завершён (only: $ONLY_STAGE) ==="
		return 0
	fi

	((need_wizard)) && run_wizard

	# Гарантируем, что выбор компонентов применён к state
	[[ -n "${COMPONENTS:-}" ]] && apply_component_selection "$COMPONENTS"

	# --- Точка старта (--from) ---
	# Валидируем имя этапа: иначе опечатка молча пропустит ВСЕ этапы («успех» без работы).
	if [[ -n "$START_FROM" ]]; then
		local _f_ok=0 _f_k
		for _f_k in "${STAGE_KEYS[@]}"; do [[ "$_f_k" == "$START_FROM" ]] && { _f_ok=1; break; }; done
		((_f_ok)) || { ui_error "Неизвестный этап для --from: '${START_FROM}'. Доступные: ${STAGE_KEYS[*]}"; exit 1; }

		# Предохранитель: если в диапазон --from попадают уже ВЫПОЛНЕННЫЕ деструктивные
		# core-этапы (database/webserver/ispconfig), повторный прогон может пересобрать
		# nginx / переустановить ISPConfig / тронуть БД на рабочем сервере. Глобальный
		# guard это пропускает (он молчит при наличии прогресса) — поэтому спрашиваем тут.
		if ! ((FORCE)); then
			local _danger=0 _seen=0 _k
			for _k in "${STAGE_KEYS[@]}"; do
				[[ "$_k" == "$START_FROM" ]] && _seen=1
				((_seen)) || continue
				case "$_k" in
					database|webserver|ispconfig)
						[[ "$(state_get "$_k")" == "done" ]] && _danger=1 ;;
				esac
			done
			if ((_danger)); then
				ui_warn "--from ${START_FROM}: в диапазон входят уже выполненные core-этапы (database/webserver/ispconfig)."
				ui_warn "Повторный прогон может переустановить ISPConfig / пересобрать nginx / тронуть БД."
				if [[ -t 0 ]]; then
					ui_confirm "Точно продолжить --from ${START_FROM}?" n || { ui_info "Отменено."; exit 0; }
				else
					ui_error "Отказ: --from с деструктивными core-этапами в non-tty. Добавьте --force, если уверены."
					exit 2
				fi
			fi
		fi
	fi
	local started=1
	[[ -n "$START_FROM" ]] && started=0

	# --- Цикл по этапам ---
	local key fn
	for key in "${STAGE_KEYS[@]}"; do
		if ((started == 0)); then
			[[ "$key" == "$START_FROM" ]] && started=1 || continue
		fi
		fn="stage_${key}"
		if ! declare -F "$fn" >/dev/null; then
			ui_warn "Нет функции этапа $fn — пропуск."
			continue
		fi
		run_step "$key" "$fn"
	done

	# Очистка лишних пакетов для выбранного стека (напр. Apache при nginx) —
	# показать и спросить, «чтобы не засирать систему».
	declare -F cleanup_unneeded >/dev/null && cleanup_unneeded

	# Права конфигов ещё раз в конце: ISPConfig, Roundcube и др. ставятся после этапа security.
	declare -F _security_fix_stack_perms >/dev/null && _security_fix_stack_perms

	# Уведомления (email/Telegram) + ежедневный монитор — если задан канал.
	declare -F apply_notifications >/dev/null && apply_notifications

	# Анти-лок-аут: взвести таймер отката ДО рискованных SSH/firewall-правок.
	declare -F _net_safety_arm >/dev/null && _net_safety_arm
	# Финальные шаги по SSH: харденинг (X11/пароль) → смена порта.
	# (Ограничение по IP — через firewall в этапе security, не отдельным sshd-шагом.)
	declare -F apply_ssh_hardening >/dev/null && apply_ssh_hardening
	declare -F apply_ssh_safe >/dev/null && apply_ssh_safe
	declare -F apply_ssh_port >/dev/null && apply_ssh_port
	# ufw могли выключить после этапа security: штатный firewall-плагин ISPConfig или прошлый откат
	# анти-лок-аута (повторный прогон этапы пропускает и сам firewall не вернёт). Включаем под той же страховкой.
	declare -F _ufw_ensure_enabled >/dev/null && _ufw_ensure_enabled

	run_summary

	# Авто-самопроверка в финале ПОЛНОГО прогона (не для --only/--from): новичок не
	# запустит --healthcheck вручную, а так сразу видит зелёный/красный итог. Идёт ПОД
	# сводкой (HC_NO_CLEAR=1 — не затирает её).
	if [[ -z "${ONLY_STAGE:-}" && -z "${START_FROM:-}" ]] && declare -F run_healthcheck >/dev/null; then
		echo ""
		HC_NO_CLEAR=1 run_healthcheck || true
	fi

	# Объявить, как подтвердить доступ (ПОСЛЕДНИМ — чтобы не затёрлось сводкой/healthcheck
	# и было первым, что видит админ; иначе таймер откатит firewall/SSH).
	declare -F _net_safety_announce >/dev/null && _net_safety_announce

	log "=== LuckyStack завершён ==="
}

main "$@"
