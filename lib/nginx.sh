#!/bin/bash
# =============================================================================
# lib/nginx.sh — Native-сборка nginx из исходников (без обёрток).
# Самодостаточный порт build-логики: pre-build QuicTLS (HTTP/3), модули
# (Brotli, Headers-More, GeoIP2, zlib-ng, PCRE2-JIT, zstd, cache-purge,
# set-misc, VTS), компиляция, systemd, landing page, CrowdSec.
#
# Профиль модулей читается из setup.conf (переменные NGX_*). Значения по
# умолчанию = «recommended». Расширяется добавлением записей в _ngx_module_*.
# =============================================================================

# --- Версии компонентов ------------------------------------------------------
# nginx-версии по умолчанию ОПРЕДЕЛЯЮТСЯ автоматически (последняя с nginx.org)
# в _nginx_autoset_versions. Значения ниже — ФОЛБЭК на случай отсутствия сети.
# OpenSSL: ветка из OPENSSL_BRANCH, последний выпуск ветки и PCRE2 определяются автоматически
# (OpenSSL и PCRE2 с GitHub), значения ниже и в _openssl_branch_ver — фолбэк. Проверено 2026-11-05.
: "${NGINX_STABLE_VER:=1.30.6}"
: "${NGINX_MAINLINE_VER:=1.31.8}"
: "${OPENSSL_VER:=}"            # пин версии; пусто = последний выпуск ветки OPENSSL_BRANCH
: "${PCRE2_VER:=10.49}"
: "${ZLIBNG_VER:=2.3.3}"
: "${LIBMAXMINDDB_VER:=1.14.1}"
: "${GEOIP2_VER:=3.4}"
: "${NGINX_DEV_KIT:=0.3.4}"
# Прим.: headers-more, brotli, zstd, ngx_cache_purge, set-misc, vts тянутся git-ом
# (latest), поэтому версии для них здесь НЕ задаются.

# --- Пути --------------------------------------------------------------------
NGX_SRC=/usr/local/src/nginx
NGX_MOD="$NGX_SRC/modules"
NGX_BUILD_LOG="${SETUP_LOG:-/var/log/luckystack/setup.log}"

# --- Авто-определение последних версий nginx ---------------------------------
# Тянет список релизов с nginx.org и выставляет последний stable (чётный minor)
# и mainline (самый свежий). Уважает явный пин NGINX_STABLE_VER/MAINLINE_VER в
# setup.conf и фолбэк-константы при отсутствии сети. NGINX_AUTO_VERSION=n — выкл.
_nginx_autoset_versions() {
	[[ "${NGINX_AUTO_VERSION:-y}" == "y" ]] || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	[[ -n "${_NGINX_VER_RESOLVED:-}" ]] && return 0
	_NGINX_VER_RESOLVED=1
	# Явный пин версии в setup.conf не трогаем.
	local pin_s=0 pin_m=0
	[[ -f "${CONFIG_FILE:-}" ]] && grep -q '^NGINX_STABLE_VER=' "$CONFIG_FILE" 2>/dev/null && pin_s=1
	[[ -f "${CONFIG_FILE:-}" ]] && grep -q '^NGINX_MAINLINE_VER=' "$CONFIG_FILE" 2>/dev/null && pin_m=1
	((pin_s && pin_m)) && return 0
	local list; list="$(curl -fsSL --connect-timeout 10 --max-time 20 https://nginx.org/download/ 2>/dev/null \
		| grep -oE 'nginx-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
		| sed -E 's/^nginx-([0-9.]+)\.tar\.gz$/\1/' | sort -u -V)"
	if [[ -z "$list" ]]; then
		ui_info "nginx: список версий недоступен — использую встроенные (stable ${NGINX_STABLE_VER}, mainline ${NGINX_MAINLINE_VER})."
		return 0
	fi
	local ls lm
	lm="$(printf '%s\n' "$list" | tail -1)"                       # mainline = самая свежая
	ls="$(printf '%s\n' "$list" | awk -F. '($2%2)==0' | tail -1)"  # stable = последняя с чётным minor
	((pin_s)) || [[ -z "$ls" ]] || NGINX_STABLE_VER="$ls"
	((pin_m)) || [[ -z "$lm" ]] || NGINX_MAINLINE_VER="$lm"
	ui_info "nginx (авто): последние версии — stable ${UI_W}${NGINX_STABLE_VER}${UI_NC}, mainline ${UI_W}${NGINX_MAINLINE_VER}${UI_NC}."
	_nginx_autoset_deps
}

# OpenSSL (последний выпуск ТОЙ ЖЕ ветки, например 3.6.x: смена ветки — осознанное решение) и
# PCRE2 (последний). Раньше они были жёстко прописаны и отставали от исправлений безопасности.
# Явный пин в setup.conf уважаем; без сети остаются фолбэк-значения.
_nginx_autoset_deps() {
	local api="https://api.github.com/repos" v series
	if ! { [[ -f "${CONFIG_FILE:-}" ]] && grep -q '^OPENSSL_VER=' "$CONFIG_FILE" 2>/dev/null; }; then
		series="${OPENSSL_VER%.*}"
		v="$(curl -fsSL --connect-timeout 10 --max-time 20 "$api/openssl/openssl/releases?per_page=40" 2>/dev/null \
			| grep -oE "\"tag_name\": *\"openssl-${series//./\\.}\.[0-9]+\"" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
		[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && OPENSSL_VER="$v"
	fi
	if ! { [[ -f "${CONFIG_FILE:-}" ]] && grep -q '^PCRE2_VER=' "$CONFIG_FILE" 2>/dev/null; }; then
		v="$(curl -fsSL --connect-timeout 10 --max-time 20 "$api/PCRE2Project/pcre2/releases/latest" 2>/dev/null \
			| grep -oE '"tag_name": *"pcre2-[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+')"
		[[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] && PCRE2_VER="$v"
	fi
	ui_info "OpenSSL ${UI_W}${OPENSSL_VER}${UI_NC}, PCRE2 ${UI_W}${PCRE2_VER}${UI_NC}."
}

# --- Ветка OpenSSL (нужен для HTTP/3) ----------------------------------------
# Выпуск на случай отсутствия сети; сроки поддержки с openssl-library.org, проверено 2026-11-05.
# Ветки без поддержки сюда не входят. Пин OPENSSL_VER в setup.conf важнее ветки.
_openssl_branch_ver() {
	case "$1" in
		3.5) echo 3.5.9 ;;   # LTS, поддержка до 2030-04-08
		4.1) echo 4.1.0 ;;   # до 2027-11-23
		4.0) echo 4.0.3 ;;   # до 2027-05-14
	esac
}

_nginx_openssl_select() {
	[[ -n "${OPENSSL_VER:-}" ]] && return 0
	local b="${OPENSSL_BRANCH:-3.5}"
	OPENSSL_VER="$(_openssl_branch_ver "$b")"
	if [[ -z "$OPENSSL_VER" ]]; then
		ui_warn "Ветка OpenSSL ${b} не поддерживается, беру 3.5 LTS."
		OPENSSL_VER="$(_openssl_branch_ver 3.5)"
	fi
}

# Вопрос о ветке: в мастере и в --update. Без HTTP/3 nginx собирается с системным OpenSSL, спрашивать незачем.
_nginx_ask_openssl_branch() {
	[[ "${NGX_HTTP3:-y}" == "y" ]] || return 0
	if [[ -f "${CONFIG_FILE:-}" ]] && grep -q '^OPENSSL_VER=' "$CONFIG_FILE" 2>/dev/null; then
		ui_info "OpenSSL закреплён в setup.conf: ${OPENSSL_VER:-}."
		return 0
	fi
	local def=1 b=3.5
	case "${OPENSSL_BRANCH:-3.5}" in
		4.1) def=2 ;;
		4.0) def=3 ;;
	esac
	ui_menu "Какой OpenSSL собирать с nginx" "$def" \
		"3.5 LTS — поддержка до апреля 2030 (рекомендуется)" \
		"4.1 — самая новая, поддержка до ноября 2027" \
		"4.0 — поддержка до мая 2027"
	case "$UI_MENU_CHOICE" in
		2) b=4.1 ;;
		3) b=4.0 ;;
	esac
	config_set OPENSSL_BRANCH "$b"
	# если версии уже определялись в этом процессе, определить заново для новой ветки
	OPENSSL_VER=""
	_NGINX_VER_RESOLVED=""
}

# --- Разрешение флагов модулей (профиль) -------------------------------------
# Значения берутся из setup.conf (если мастер их задал), иначе — recommended.
_nginx_resolve_flags() {
	NGINX_CHANNEL="${NGINX_CHANNEL:-stable}"
	_nginx_openssl_select
	_nginx_autoset_versions
	case "$NGINX_CHANNEL" in
		mainline) NGINX_VER="$NGINX_MAINLINE_VER" ;;
		*)        NGINX_VER="$NGINX_STABLE_VER" ;;
	esac

	# Профиль recommended (по умолчанию). y/n.
	NGX_HTTP3="${NGX_HTTP3:-y}"          # HTTP/3 QUIC (pre-build OpenSSL)
	NGX_BROTLI="${NGX_BROTLI:-y}"
	NGX_HEADERMOD="${NGX_HEADERMOD:-y}"
	NGX_ZLIBNG="${NGX_ZLIBNG:-y}"
	NGX_PCRE2="${NGX_PCRE2:-y}"          # +JIT
	NGX_ZSTD="${NGX_ZSTD:-y}"
	NGX_CACHEPURGE="${NGX_CACHEPURGE:-y}"
	NGX_SETMISC="${NGX_SETMISC:-y}"
	NGX_VTS="${NGX_VTS:-n}"
	NGX_JEMALLOC="${NGX_JEMALLOC:-y}"
	NGX_NATIVE_OPT="${NGX_NATIVE_OPT:-n}"  # -march=native+LTO (CPU-specific binary)

	# GeoIP2 — управляется мастером (GEOIP + учётки MaxMind)
	NGX_GEOIP="${GEOIP:-n}"
	# www-data — стандарт для ISPConfig-стека на Debian: PHP-FPM-пулы и шаблоны
	# ISPConfig рассчитаны на него. Переопределяется NGINX_USER/GROUP в setup.conf.
	NGX_USER="${NGINX_USER:-www-data}"
	NGX_GROUP="${NGINX_GROUP:-www-data}"
}

# --- apt build-зависимости ---------------------------------------------------
_nginx_install_deps() {
	ui_step "Установка build-зависимостей nginx"
	# libpcre2-dev вместо устаревших libpcre3/libpcre3-dev (PCRE1): в Debian 13
	# (trixie) пакетов PCRE1 уже нет, а сборка nginx использует bundled PCRE2
	# (NGX_PCRE2=y) либо системный libpcre2. libpcre3-dev на trixie — transitional
	# без кандидата на установку, из-за чего apt валил весь вызов установки.
	apt_install build-essential ca-certificates wget curl libpcre2-dev \
		autoconf unzip automake libtool tar git libssl-dev zlib1g-dev uuid-dev \
		lsb-release libxml2-dev libxslt1-dev cmake nasm libjemalloc-dev libzstd-dev \
		liburing-dev equivs binutils ccache pkg-config
}

# Хелпер: git clone (depth 1) с учётом DRY_RUN
# Уже склонированный модуль обновляем до свежего коммита (раньше пропускали, и пересборка
# nginx оставляла модули годовой давности). Не удалось обновить — собираем с тем, что есть.
_ngx_clone() {
	local url="$1" dest="$2"; shift 2
	if [[ -d "$dest/.git" ]]; then
		[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} git fetch $(basename "$dest")"; return 0; }
		local before; before="$(git -C "$dest" rev-parse HEAD 2>/dev/null)"
		if git -C "$dest" fetch --depth 1 origin >>"$NGX_BUILD_LOG" 2>&1 && git -C "$dest" reset --hard FETCH_HEAD >>"$NGX_BUILD_LOG" 2>&1; then
			[[ " $* " == *" --recurse-submodules "* ]] && git -C "$dest" submodule update --init --recursive --depth 1 >>"$NGX_BUILD_LOG" 2>&1
			[[ "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" != "$before" ]] && ui_info "обновлён: $(basename "$dest")" || ui_info "актуален: $(basename "$dest")"
		else
			ui_warn "Не удалось обновить $(basename "$dest") — собираю с прежней версией."
		fi
		return 0
	fi
	sys_run "git clone $(basename "$dest")" git clone --depth 1 "$@" "$url" "$dest"
}
# Хелпер: wget + распаковка tar
_ngx_fetch_tar() {
	local url="$1" dest="$2" strip="${3:-1}"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} wget+tar → $(basename "$dest")"
		return 0
	fi
	mkdir -p "$dest"
	# Сначала в файл, с повторами и проверкой архива. Раньше wget шёл сразу в tar: обрыв связи
	# не замечался, каталог оставался пустым, и сборка падала потом с непонятной ошибкой.
	local tmp; tmp="$(mktemp)"
	if ! ui_spin "Загрузка $(basename "$dest")" bash -c \
		"for i in 1 2 3; do wget -q --timeout=30 --tries=2 -O '$tmp' '$url' && gzip -t '$tmp' && exit 0; sleep 5; done; exit 1"; then
		rm -f "$tmp"
		ui_error "Не удалось скачать $(basename "$dest"): $url"
		return 1
	fi
	tar xzf "$tmp" --no-same-owner --no-same-permissions --strip-components="$strip" -C "$dest" 2>>"$NGX_BUILD_LOG"
	local rc=$?
	rm -f "$tmp"
	((rc == 0)) || ui_error "Не удалось распаковать $(basename "$dest")."
	return "$rc"
}

# --- Загрузка исходников модулей ---------------------------------------------
_nginx_fetch_sources() {
	ui_step "Загрузка исходников nginx и модулей"
	if [[ "${DRY_RUN:-0}" != "1" ]]; then mkdir -p "$NGX_MOD"; fi

	# nginx tarball
	_ngx_fetch_tar "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz" \
		"$NGX_SRC/nginx-${NGINX_VER}" 1 || return 1

	# Brotli (+submodule) — библиотеки deps/brotli нужно СОБРАТЬ (cmake),
	# иначе линковка nginx падает: «cannot find -lbrotlienc -lbrotlicommon».
	if [[ "$NGX_BROTLI" == "y" ]]; then
		_ngx_clone "https://github.com/google/ngx_brotli" "$NGX_MOD/ngx_brotli" --recurse-submodules
		_nginx_build_brotli
	fi
	# Headers-More
	[[ "$NGX_HEADERMOD" == "y" ]] && _ngx_clone \
		"https://github.com/openresty/headers-more-nginx-module" "$NGX_MOD/headers-more-nginx-module"
	# zstd
	[[ "$NGX_ZSTD" == "y" ]] && _ngx_clone \
		"https://github.com/tokers/zstd-nginx-module.git" "$NGX_MOD/zstd-nginx-module"
	# cache purge
	[[ "$NGX_CACHEPURGE" == "y" ]] && _ngx_clone \
		"https://github.com/FRiCKLE/ngx_cache_purge" "$NGX_MOD/ngx_cache_purge"
	# set-misc (+ devel kit)
	if [[ "$NGX_SETMISC" == "y" ]]; then
		_ngx_fetch_tar "https://github.com/simplresty/ngx_devel_kit/archive/v${NGINX_DEV_KIT}.tar.gz" \
			"$NGX_MOD/ngx_devel_kit-${NGINX_DEV_KIT}" 1 || return 1
		_ngx_clone "https://github.com/openresty/set-misc-nginx-module.git" "$NGX_MOD/set-misc-nginx-module"
	fi
	# VTS
	[[ "$NGX_VTS" == "y" ]] && _ngx_clone \
		"https://github.com/vozlt/nginx-module-vts.git" "$NGX_MOD/nginx-module-vts"
	# zlib-ng — скачать И собрать (libz-ng.a). nginx линкуется через патч ниже.
	if [[ "$NGX_ZLIBNG" == "y" ]]; then
		_ngx_fetch_tar "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${ZLIBNG_VER}.tar.gz" \
			"$NGX_MOD/zlib-ng-${ZLIBNG_VER}" 1 || return 1
		_nginx_build_zlibng
	fi
	# PCRE2
	if [[ "$NGX_PCRE2" == "y" ]]; then
		_ngx_fetch_tar "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VER}/pcre2-${PCRE2_VER}.tar.gz" \
			"$NGX_MOD/pcre2-${PCRE2_VER}" 1 || return 1
	fi
	# GeoIP2 (модуль + libmaxminddb)
	if [[ "$NGX_GEOIP" == "y" ]]; then
		_nginx_build_libmaxminddb || return 1
		_ngx_fetch_tar "https://github.com/leev/ngx_http_geoip2_module/archive/${GEOIP2_VER}.tar.gz" \
			"$NGX_MOD/ngx_http_geoip2_module-${GEOIP2_VER}" 1 || return 1
	fi
	return 0
}

# Сборка brotli-библиотек из ngx_brotli/deps/brotli (cmake, статические .a).
# Без этого ngx_brotli компилируется, но линковка nginx падает (нет libbrotlienc).
_nginx_build_brotli() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} cmake deps/brotli → libbrotlienc.a (static)"
		return 0
	fi
	local d="$NGX_MOD/ngx_brotli/deps/brotli"
	if [[ ! -f "$d/CMakeLists.txt" ]]; then
		ui_warn "ngx_brotli/deps/brotli пуст (submodule не подтянулся) — Brotli ОТКЛЮЧЁН."
		NGX_BROTLI=n
		return 0
	fi
	# собраны ли библиотеки ИМЕННО из текущего коммита brotli (модуль мог обновиться)
	local rev; rev="$(git -C "$d" rev-parse HEAD 2>/dev/null)"
	if [[ -f "$d/out/libbrotlienc.a" && -n "$rev" && "$(cat "$d/out/.ss-rev" 2>/dev/null)" == "$rev" ]]; then
		ui_info "brotli-библиотеки уже собраны — пропуск."
		return 0
	fi
	rm -rf "$d/out"
	if ! ui_spin "Сборка brotli-библиотек (cmake)" bash -c "
		cd '$d' && rm -rf out && mkdir out && cd out && \
		cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
		      -DCMAKE_C_FLAGS='-Ofast -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections' \
		      -DCMAKE_CXX_FLAGS='-Ofast -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections' \
		      -DCMAKE_INSTALL_PREFIX=./installed .. && \
		cmake --build . --config Release --target brotlienc"; then
		ui_warn "Сборка brotli не удалась — Brotli ОТКЛЮЧЁН (сборка nginx продолжится без него)."
		NGX_BROTLI=n
		return 0
	fi
	[[ -n "$rev" ]] && echo "$rev" >"$d/out/.ss-rev"
	# CLI brotli — для пред-сжатия статики (brotli_static on)
	apt_install brotli || true
	ui_success "brotli-библиотеки собраны (deps/brotli/out)."
}

# Сборка zlib-ng → libz-ng.a (без --zlib-compat, как в оригинале).
_nginx_build_zlibng() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} ./configure && make zlib-ng (libz-ng.a)"
		return 0
	fi
	local d="$NGX_MOD/zlib-ng-${ZLIBNG_VER}"
	[[ -d "$d" ]] || return 0
	ui_spin "Сборка zlib-ng" bash -c \
		"cd '$d' && ./configure >>'$NGX_BUILD_LOG' 2>&1 && make -j\$(nproc) >>'$NGX_BUILD_LOG' 2>&1" || \
		{ ui_warn "Сборка zlib-ng не удалась — будет использован системный zlib."; NGX_ZLIBNG=n; }
}

# Патчи к исходникам nginx ПЕРЕД ./configure. Версионно-зависимы: при неуспехе
# фича отключается (fallback на системный zlib), а не валит всю сборку.
# patch --forward делает применение идемпотентным (на ретрае не дублирует).
_nginx_apply_patches() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} патчи nginx: use_openssl_md5_sha1, nginx_zlib-ng"
		return 0
	fi
	local src="$NGX_SRC/nginx-${NGINX_VER}"
	[[ -d "$src" ]] || return 0
	# Патчи лежат в репозитории (assets/nginx/patches), проверенные копии. Раньше они
	# скачивались при каждой сборке с ветки master чужих репозиториев и компилировались в
	# nginx от root: взлом любого из них дал бы чужой код в нашем nginx.
	local pd="${ASSETS_DIR:-$SCRIPT_DIR/assets}/nginx/patches"
	ui_step "Применение патчей к nginx ${NGINX_VER}"
	# OpenSSL MD5/SHA1 (нужен при сборке с --with-openssl для HTTP/3)
	if [[ "$NGX_HTTP3" == "y" && -f "$pd/use_openssl_md5_sha1.patch" ]]; then
		( cd "$src" && patch -p1 --forward <"$pd/use_openssl_md5_sha1.patch" >>"$NGX_BUILD_LOG" 2>&1 ) || true
	fi
	# zlib-ng патч — критичен: без него --with-zlib=<zlib-ng> ломает сборку
	if [[ "$NGX_ZLIBNG" == "y" ]]; then
		if [[ -f "$pd/nginx_zlib-ng.patch" ]] && ( cd "$src" && patch -p1 --forward <"$pd/nginx_zlib-ng.patch" >>"$NGX_BUILD_LOG" 2>&1 ); then
			ui_success "Патч nginx_zlib-ng применён."
		else
			# Уже применён? Проверим маркер; иначе отключаем zlib-ng.
			if grep -q "libz-ng" "$src/auto/lib/zlib/conf" 2>/dev/null; then
				ui_info "Патч nginx_zlib-ng уже применён."
			else
				ui_warn "Патч nginx_zlib-ng не применился к nginx ${NGINX_VER} — zlib-ng ОТКЛЮЧЁН (системный zlib)."
				NGX_ZLIBNG=n
			fi
		fi
	fi
}

# libmaxminddb — нужна для GeoIP2-модуля
_nginx_build_libmaxminddb() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} сборка libmaxminddb ${LIBMAXMINDDB_VER}"
		return 0
	fi
	local d="$NGX_MOD/libmaxminddb-${LIBMAXMINDDB_VER}"
	_ngx_fetch_tar \
		"https://github.com/maxmind/libmaxminddb/releases/download/${LIBMAXMINDDB_VER}/libmaxminddb-${LIBMAXMINDDB_VER}.tar.gz" \
		"$d" 1 || true   # не скачалась: сборка ниже не пройдёт, и сработает общая проверка
	ui_spin "Сборка libmaxminddb" bash -c \
		"cd '$d' && ./configure >>'$NGX_BUILD_LOG' 2>&1 && make -j\$(nproc) >>'$NGX_BUILD_LOG' 2>&1 && make install >>'$NGX_BUILD_LOG' 2>&1 && ldconfig" && return 0
	# Без библиотеки модуль GeoIP2 не соберётся. Библиотека от прошлой сборки подойдёт,
	# но об этом надо сказать: иначе сервер молча остаётся на старой версии.
	if [[ -e /usr/local/lib/libmaxminddb.so && -e /usr/local/include/maxminddb.h ]]; then
		ui_warn "libmaxminddb ${LIBMAXMINDDB_VER} не собралась, nginx соберётся с уже установленной версией. Причина: ${NGX_BUILD_LOG}"
		return 0
	fi
	ui_error "libmaxminddb ${LIBMAXMINDDB_VER} не собралась, без неё модуль GeoIP2 не собрать. Причина: ${NGX_BUILD_LOG}"
	return 1
}

# Скачать базы GeoLite2 (нужны учётки MaxMind из мастера)
_nginx_fetch_geoip_db() {
	[[ "$NGX_GEOIP" == "y" ]] || return 0
	[[ -n "${GEOIP2_LICENSE_KEY:-}" ]] || { ui_warn "GeoIP2 включён, но ключ MaxMind пуст — базы не скачиваю."; return 0; }
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} загрузка баз GeoLite2 (Country/City/ASN) в /opt/geoip"
		return 0
	fi
	ui_step "Загрузка баз MaxMind GeoLite2"
	mkdir -p /opt/geoip
	local ed
	for ed in GeoLite2-Country GeoLite2-City GeoLite2-ASN; do
		local url="https://download.maxmind.com/app/geoip_download?edition_id=${ed}&license_key=${GEOIP2_LICENSE_KEY}&suffix=tar.gz"
		# Через временный каталог и атомарную замену: обрыв не должен оставить битую базу,
		# с ней nginx не запустится. MaxMind ограничивает частоту загрузок (ответ 429).
		local tmp; tmp="$(mktemp -d)"
		ui_spin "Загрузка ${ed}" bash -c \
			"wget -qO '$tmp/db.tgz' '$url' && tar xzf '$tmp/db.tgz' --no-same-owner --no-same-permissions -C '$tmp' --strip-components=1 --wildcards '*/${ed}.mmdb' && test -s '$tmp/${ed}.mmdb' && install -m 644 '$tmp/${ed}.mmdb' '/opt/geoip/.${ed}.new' && mv -f '/opt/geoip/.${ed}.new' '/opt/geoip/${ed}.mmdb'" || \
			ui_warn "База ${ed} не обновлена: неверный ключ MaxMind или лимит загрузок. Текущая база оставлена."
		rm -rf "$tmp"
	done
}

# Таймауты клиентов отдельным файлом: его не затрёт пересборка, а убрать можно настройкой.
# Медленные атаки держат соединения открытыми, по умолчанию nginx ждёт 60 с на каждый шаг.
_nginx_tight_timeouts() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	command -v nginx >/dev/null 2>&1 && [[ -d /etc/nginx/conf.d ]] || return 0
	local f=/etc/nginx/conf.d/05-luckystack-timeouts.conf tmp prev=""
	if [[ "${NGX_TIGHT_TIMEOUTS:-y}" != "y" ]]; then
		if [[ -f "$f" ]]; then
			rm -f "$f"
			nginx -t >>"$SETUP_LOG" 2>&1 && systemctl reload nginx >>"$SETUP_LOG" 2>&1
			ui_info "Короткие таймауты nginx выключены."
		fi
		return 0
	fi
	tmp="$(mktemp)"
	cat >"$tmp" <<'CONF'
# luckystack: таймауты клиентов (NGX_TIGHT_TIMEOUTS=n убирает этот файл)
client_header_timeout 15s;
client_body_timeout 60s;
send_timeout 60s;
reset_timedout_connection on;
CONF
	if [[ -f "$f" ]] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
	[[ -f "$f" ]] && prev="$(mktemp)" && cp -a "$f" "$prev"
	install -m 644 "$tmp" "$f"; rm -f "$tmp"
	if nginx -t >>"$SETUP_LOG" 2>&1; then
		rm -f "$prev"
		systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
		ui_success "nginx: короткие таймауты клиентов."
		return 0
	fi
	if [[ -n "$prev" ]]; then mv -f "$prev" "$f"; else rm -f "$f"; fi
	ui_warn "nginx -t не принял таймауты, файл откатил."
	return 1
}

# --- Pre-build QuicTLS (OpenSSL с QUIC) для HTTP/3 ----------------------------
# СИНХРОННО (не в фоне): фоновый вариант создавал гонку — «wait $PID» из subshell
# не работает (PID не его ребёнок), nginx make стартовал без libssl.a и запускал
# СВОЮ сборку OpenSSL (с тестами, -O3) поверх нашей → BIO_MSG-фейлы/долгая сборка.
_nginx_prebuild_openssl() {
	[[ "$NGX_HTTP3" == "y" ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} pre-build OpenSSL ${OPENSSL_VER} (-O2, no-tests, статический libssl.a)"
		return 0
	fi
	local q="$NGX_MOD/quictls"
	# Пропускаем, только если собрана ИМЕННО эта версия. Раньше хватало наличия libssl.a, и
	# пересборка nginx молча оставляла старый OpenSSL (на проде так и стоял 3.6.3).
	if [[ -f "$q/.openssl/lib/libssl.a" && "$(cat "$q/.openssl/.ss-version" 2>/dev/null)" == "$OPENSSL_VER" ]]; then
		ui_info "OpenSSL ${OPENSSL_VER} уже пре-собран — пропуск."
		return 0
	fi
	[[ -f "$q/.openssl/lib/libssl.a" ]] && ui_info "Собран другой OpenSSL ($(cat "$q/.openssl/.ss-version" 2>/dev/null || echo 'версия неизвестна')) — пересобираю ${OPENSSL_VER}."
	ui_step "Pre-build OpenSSL ${OPENSSL_VER} для HTTP/3 (~3-7 мин)"
	mkdir -p "$NGX_MOD"
	# Чистка перед сборкой: грязное дерево после ретрая даёт «BIO_MSG» и
	# «impossible API compatibility level».
	if ! ui_spin "OpenSSL ${OPENSSL_VER}: загрузка + сборка (no-tests, -O2)" bash -c "
		cd '$NGX_MOD' && \
		rm -rf quictls 'openssl-${OPENSSL_VER}' 'openssl-${OPENSSL_VER}.tar.gz'* && \
		( wget -q --timeout=30 --tries=2 -O 'openssl-${OPENSSL_VER}.tar.gz' 'https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz' \
		  || wget -q --timeout=30 --tries=2 -O 'openssl-${OPENSSL_VER}.tar.gz' 'https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz' \
		  || wget -q --timeout=30 --tries=2 -O 'openssl-${OPENSSL_VER}.tar.gz' 'https://www.openssl.org/source/old/${OPENSSL_VER%.*}/openssl-${OPENSSL_VER}.tar.gz' ) && \
		test -s 'openssl-${OPENSSL_VER}.tar.gz' && \
		tar xaf 'openssl-${OPENSSL_VER}.tar.gz' --no-same-owner --no-same-permissions && \
		mv 'openssl-${OPENSSL_VER}' quictls && \
		cd quictls && \
		./Configure --prefix='$q/.openssl' no-shared no-threads enable-ktls no-tests -O2 -fPIC && \
		make -j\$(nproc) build_sw && \
		make install_sw LIBDIR=lib"; then
		ui_error "Pre-build OpenSSL не удался. Лог: $NGX_BUILD_LOG"
		return 1
	fi
	if [[ ! -f "$q/.openssl/lib/libssl.a" ]]; then
		ui_error "OpenSSL собрался, но libssl.a не найден в $q/.openssl/lib — прерываю."
		return 1
	fi
	echo "$OPENSSL_VER" >"$q/.openssl/.ss-version"
	ui_success "OpenSSL pre-build готов (nginx make пропустит свою сборку)."
}

# --- Сборка configure-флагов -------------------------------------------------
_nginx_assemble_flags() {
	NGX_OPTIONS="--prefix=/etc/nginx \
		--sbin-path=/usr/sbin/nginx \
		--conf-path=/etc/nginx/nginx.conf \
		--error-log-path=/var/log/nginx/error.log \
		--http-log-path=/var/log/nginx/access.log \
		--pid-path=/run/nginx.pid \
		--lock-path=/run/nginx.lock \
		--http-client-body-temp-path=/var/cache/nginx/client_temp \
		--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
		--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
		--user=${NGX_USER} --group=${NGX_GROUP}"

	NGX_MODULES="--with-threads --with-file-aio --with-poll_module --with-select_module \
		--with-http_ssl_module --with-http_v2_module --with-http_mp4_module \
		--with-http_auth_request_module --with-http_slice_module --with-http_stub_status_module \
		--with-http_realip_module --with-http_sub_module --with-http_degradation_module \
		--with-http_secure_link_module --with-http_gzip_static_module \
		--with-stream --with-stream_ssl_module --with-stream_ssl_preread_module"

	local add=""
	[[ "$NGX_HTTP3" == "y" ]] && { NGX_MODULES+=" --with-http_v3_module"; add+=" --with-openssl=$NGX_MOD/quictls --with-openssl-opt=enable-ktls"; }
	[[ "$NGX_BROTLI" == "y" ]] && add+=" --add-module=$NGX_MOD/ngx_brotli"
	[[ "$NGX_HEADERMOD" == "y" ]] && add+=" --add-module=$NGX_MOD/headers-more-nginx-module"
	[[ "$NGX_GEOIP" == "y" ]] && add+=" --add-module=$NGX_MOD/ngx_http_geoip2_module-${GEOIP2_VER}"
	[[ "$NGX_CACHEPURGE" == "y" ]] && add+=" --add-module=$NGX_MOD/ngx_cache_purge"
	[[ "$NGX_VTS" == "y" ]] && add+=" --add-module=$NGX_MOD/nginx-module-vts"
	[[ "$NGX_ZSTD" == "y" ]] && add+=" --add-module=$NGX_MOD/zstd-nginx-module"
	if [[ "$NGX_SETMISC" == "y" ]]; then
		add+=" --add-module=$NGX_MOD/ngx_devel_kit-${NGINX_DEV_KIT} --add-module=$NGX_MOD/set-misc-nginx-module"
	fi
	[[ "$NGX_ZLIBNG" == "y" ]] && add+=" --with-zlib=$NGX_MOD/zlib-ng-${ZLIBNG_VER}"
	[[ "$NGX_PCRE2" == "y" ]] && add+=" --with-pcre=$NGX_MOD/pcre2-${PCRE2_VER} --with-pcre-jit"
	NGX_ADD="$add"

	# CC/LD флаги
	if [[ "$NGX_NATIVE_OPT" == "y" ]]; then
		NGX_CC="-O3 -march=native -fPIC -DTCP_FASTOPEN=23 -D_FORTIFY_SOURCE=2 -fstack-protector-strong -flto=auto -Wno-deprecated-declarations -Wno-ignored-qualifiers"
		NGX_LD="-Wl,-z,relro -Wl,-z,now -flto=auto"
	else
		NGX_CC="-O2 -fPIC -DTCP_FASTOPEN=23 -D_FORTIFY_SOURCE=2 -fstack-protector-strong -Wno-deprecated-declarations -Wno-ignored-qualifiers"
		NGX_LD="-Wl,-z,relro -Wl,-z,now"
	fi
	[[ "$NGX_JEMALLOC" == "y" ]] && NGX_LD+=" -ljemalloc"

	# GeoIP2: libmaxminddb собирается в /usr/local — указываем пути, иначе
	# ./configure модуля geoip2 не найдёт заголовки/библиотеку.
	if [[ "$NGX_GEOIP" == "y" ]]; then
		NGX_CC+=" -I/usr/local/include"
		NGX_LD+=" -L/usr/local/lib -Wl,-rpath,/usr/local/lib"
	fi
}

# --- Компиляция + установка бинаря ------------------------------------------
_nginx_compile() {
	ui_step "Компиляция nginx ${NGINX_VER}"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} ./configure ${NGX_ADD}"
		ui_info "${UI_D}[dry-run]${UI_NC} make -j\$(nproc) && make install (DESTDIR)"
		return 0
	fi

	# Контроль: при HTTP/3 libssl.a обязан существовать (prebuild синхронный).
	if [[ "$NGX_HTTP3" == "y" && ! -f "$NGX_MOD/quictls/.openssl/lib/libssl.a" ]]; then
		ui_error "Нет $NGX_MOD/quictls/.openssl/lib/libssl.a — pre-build OpenSSL не выполнен."
		return 1
	fi

	local src="$NGX_SRC/nginx-${NGINX_VER}"
	local destdir="/tmp/nginx-install-$$"
	# shellcheck disable=SC2086
	if ! ( cd "$src" && \
		./configure $NGX_OPTIONS $NGX_MODULES $NGX_ADD \
			--with-cc-opt="$NGX_CC" --with-ld-opt="$NGX_LD" \
	) >>"$NGX_BUILD_LOG" 2>&1; then
		ui_error "configure nginx не удался. Лог: $NGX_BUILD_LOG"
		return 1
	fi
	# Анти-двойная-сборка OpenSSL: nginx-таргет для --with-openssl зависит от
	# objs/Makefile (он всегда новее после configure) и БЕЗУСЛОВНО пересобирает
	# OpenSSL (-O3, С ТЕСТАМИ, ~15 мин). Делаем ssl.h новее Makefile — make
	# увидит готовый pre-build и пропустит пересборку.
	if [[ "$NGX_HTTP3" == "y" && -f "$NGX_MOD/quictls/.openssl/include/openssl/ssl.h" ]]; then
		touch "$NGX_MOD/quictls/.openssl/include/openssl/ssl.h"
	fi
	if ! ( cd "$src" && \
		make -j"$(nproc)" && \
		make install DESTDIR="$destdir" \
	) >>"$NGX_BUILD_LOG" 2>&1; then
		ui_error "Компиляция nginx не удалась. Лог: $NGX_BUILD_LOG"
		return 1
	fi

	# Тест свежего бинаря. ВАЖНО: compiled-in пути логов/кэша должны существовать,
	# иначе nginx -t падает «open /var/log/nginx/error.log failed» при валидном
	# синтаксисе (именно так выглядел фейл на чистой системе).
	mkdir -p /var/log/nginx /var/cache/nginx
	local newbin="$destdir/usr/sbin/nginx" tconf
	tconf="$(mktemp)"
	printf 'error_log stderr;\npid /tmp/nginx-test.pid;\nevents {}\nhttp {}\n' >"$tconf"
	if ! "$newbin" -t -c "$tconf" >>"$NGX_BUILD_LOG" 2>&1; then
		ui_error "Тест нового бинаря nginx провалился. Лог: $NGX_BUILD_LOG"
		rm -f "$tconf"; return 1
	fi
	rm -f "$tconf"

	# Бэкап старого + установка нового
	[[ -f /usr/sbin/nginx ]] && cp -a /usr/sbin/nginx /usr/sbin/nginx.backup
	install -m 755 "$newbin" /usr/sbin/nginx
	rm -rf "$destdir"

	# Конфиг-файлы из исходников
	local cdir="$src/conf" f
	mkdir -p /etc/nginx
	for f in mime.types fastcgi_params scgi_params uwsgi_params koi-utf koi-win win-utf; do
		[[ -f "$cdir/$f" ]] && cp -n "$cdir/$f" "/etc/nginx/$f"
	done
	ui_success "nginx ${NGINX_VER} скомпилирован и установлен в /usr/sbin/nginx"
}

# --- Пользователь, директории, systemd, logrotate ---------------------------
_nginx_setup_service() {
	ui_step "Системная интеграция nginx (user, dirs, systemd)"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} useradd ${NGX_USER}, /var/cache|log/nginx, systemd unit, logrotate"
		return 0
	fi

	id -u "$NGX_USER" &>/dev/null || \
		useradd --system --no-create-home --shell /usr/sbin/nologin --user-group "$NGX_USER"

	mkdir -p /var/cache/nginx /var/log/nginx /run/nginx \
		/etc/nginx/sites-available /etc/nginx/sites-enabled \
		/etc/nginx/conf.d /etc/nginx/stream.d /etc/nginx/snippets
	chmod 755 /run/nginx /var/log/nginx
	chown -R "$NGX_USER:$NGX_GROUP" /var/cache/nginx /var/log/nginx /run/nginx

	cat >/lib/systemd/system/nginx.service <<UNIT
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
RuntimeDirectory=nginx
RuntimeDirectoryMode=0755
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/usr/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true
LimitNOFILE=65535
Restart=on-failure
RestartSec=5s
KillMode=process

[Install]
WantedBy=multi-user.target
UNIT

	cat >/etc/logrotate.d/nginx <<ROT
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 ${NGX_USER} root
    sharedscripts
    postrotate
        if [ -f /run/nginx.pid ]; then kill -USR1 \`cat /run/nginx.pid\`; fi
    endscript
}
ROT

	# equivs-обёртка: apt не перезапишет кастомный бинарь
	local ctrl="/tmp/nginx-custom.control"
	cat >"$ctrl" <<EOF
Section: misc
Priority: optional
Standards-Version: 3.9.2
Package: nginx
Provides: nginx-full, nginx-common, nginx-core, nginx-light, nginx-extras, httpd
Version: ${NGINX_VER}-custom
Architecture: all
Maintainer: root <root@localhost>
Description: Custom nginx ${NGINX_VER} compiled from source
EOF
	( cd /tmp && equivs-build "$ctrl" && dpkg -i "nginx_${NGINX_VER}-custom_all.deb" ) >>"$NGX_BUILD_LOG" 2>&1 || \
		ui_warn "equivs-обёртка не создана (не критично)."

	systemctl daemon-reload
}

# --- Деплой кастомного nginx.conf + сниппетов (Группа A) ---------------------
_nginx_deploy_conf() {
	local adir="${ASSETS_DIR:-$SCRIPT_DIR/assets}/nginx"
	[[ -f "$adir/nginx.conf" ]] || { ui_info "assets/nginx/nginx.conf не найден — оставляю стандартный конфиг."; return 0; }
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} деплой nginx.conf + snippets (user=${NGX_USER}) + sync под модули"
		return 0
	fi
	ui_step "Установка кастомного nginx.conf + сниппетов из assets"
	[[ -f /etc/nginx/nginx.conf ]] && cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
	install -m 644 "$adir/nginx.conf" /etc/nginx/nginx.conf
	# user под нашу сборку (в конфиге по умолчанию 'user nginx;')
	sed -i "s/^user .*/user ${NGX_USER};/" /etc/nginx/nginx.conf
	# pcre_jit требует сборки с PCRE JIT — выключаем, если PCRE2 не собран
	[[ "$NGX_PCRE2" == "y" ]] || sed -i 's/^\([[:space:]]*\)pcre_jit on;/\1# pcre_jit on;/' /etc/nginx/nginx.conf
	# Сниппеты (не перезатираем существующие, напр. php-default.conf). Права задаём явно:
	# ассеты могли приехать с Windows как 777, а nginx читает сниппеты от root.
	install -d -m 755 /etc/nginx/snippets
	if [[ -d "$adir/snippets" ]]; then
		local sf
		for sf in "$adir/snippets/"*; do
			[[ -f "$sf" ]] || continue
			[[ -e "/etc/nginx/snippets/${sf##*/}" ]] || install -m 644 "$sf" "/etc/nginx/snippets/${sf##*/}"
		done
	fi
	perm_conf_tree /etc/nginx/snippets
	# Синхронизация директив под выбранные модули
	_nginx_sync_conf /etc/nginx/nginx.conf
	ui_success "nginx.conf и сниппеты установлены (бэкап: /etc/nginx/nginx.conf.orig)."
}

# Убрать устаревшие заголовки X-XSS-Protection и Expect-CT с уже установленного сервера: из
# nginx.conf, conf-custom шаблона сайтов ISPConfig и готовых vhost. Браузеры их больше не
# поддерживают, а X-XSS-Protection в старых браузерах сам давал утечку данных (XS-Leak). Скрытие
# такого заголовка от бэкенда (fastcgi/proxy_hide_header) остаётся. nginx -t, при ошибке откат.
# У замороженных сайтов правку файла забираем в базу (иначе вернётся при сохранении сайта).
_nginx_drop_legacy_headers() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	command -v nginx >/dev/null 2>&1 || return 0
	local re="^[[:space:]]*(more_set_headers[[:space:]]+'(X-XSS-Protection|Expect-CT):|add_header[[:space:]]+(X-XSS-Protection|Expect-CT)[[:space:]])"
	local files=() f
	shopt -s nullglob
	for f in /etc/nginx/nginx.conf /usr/local/ispconfig/server/conf-custom/nginx_vhost.conf.master /etc/nginx/sites-available/*.vhost; do
		[[ -f "$f" ]] && grep -qE "$re" "$f" && files+=("$f")
	done
	shopt -u nullglob
	((${#files[@]})) || return 0
	for f in "${files[@]}"; do cp -a "$f" "$f.legacyhdr.bak"; sed -i -E "/$re/d" "$f"; done
	if nginx -t >>"$SETUP_LOG" 2>&1; then
		for f in "${files[@]}"; do rm -f "$f.legacyhdr.bak"; done
		systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
		declare -F _ispconfig_freeze_drift_import >/dev/null && _ispconfig_freeze_drift_import
		ui_success "Убраны устаревшие заголовки X-XSS-Protection и Expect-CT (файлов: ${#files[@]})."
	else
		for f in "${files[@]}"; do mv -f "$f.legacyhdr.bak" "$f"; done
		ui_warn "nginx -t не прошёл после удаления устаревших заголовков — откат (см. ${SETUP_LOG})."
	fi
}

# Раскомментировать/закомментировать директивы под выбранные NGX_*-модули.
# Порт sync_nginx_conf из nginx-autoinstall.sh (авто-режим, без вопросов).
_nginx_sync_conf() {
	local conf="${1:-/etc/nginx/nginx.conf}"
	[[ -f "$conf" ]] || return 0
	# вложенные хелперы (в bash они глобальны — это ок для локального использования)
	_active()    { grep -q "^[[:space:]]*$1" "$conf"; }
	_commented() { grep -q "^[[:space:]]*#[[:space:]]*$1" "$conf"; }
	_unc() { sed -i "s/^\([[:space:]]*\)#[[:space:]]*\($1\)/\1\2/" "$conf"; }
	_com() { sed -i "s/^\([[:space:]]*\)\($1\)/\1# \2/" "$conf"; }

	# flag probe prefix...  — однострочные директивы
	_sync_simple() {
		local flag="$1" probe="$2"; shift 2
		local p
		if [[ "$flag" == "y" ]]; then
			_commented "$probe" || return 0
			for p in "$@"; do _unc "$p"; done
		else
			_active "$probe" || return 0
			for p in "$@"; do _com "$p"; done
		fi
	}

	ui_step "Синхронизация nginx.conf под модули (HTTP3=$NGX_HTTP3 Brotli=$NGX_BROTLI zstd=$NGX_ZSTD geoip=$NGX_GEOIP headers=$NGX_HEADERMOD vts=$NGX_VTS)"
	# quic: ТОЧНЫЕ директивы ("on;"), иначе паттерн ловит строки-описания.
	# quic_gso и quic_retry — ОТДЕЛЬНЫЕ флаги (по умолчанию ВЫКЛ, как у nginx):
	#   • quic_gso на части virtio-NIC роняет QUIC (чёрная дыра больших UDP-пакетов) —
	#     апстрим-дефолт off не случайно; включаем только по NGX_QUIC_GSO=y;
	#   • quic_retry добавляет +1 RTT (валидация адреса) — по NGX_QUIC_RETRY=y.
	# Оба валидны ТОЛЬКО при HTTP3=y (без http_v3_module nginx -t упадёт на неизвестной директиве).
	local _gso=n _retry=n
	[[ "$NGX_HTTP3" == "y" && "${NGX_QUIC_GSO:-n}"   == "y" ]] && _gso=y
	[[ "$NGX_HTTP3" == "y" && "${NGX_QUIC_RETRY:-n}" == "y" ]] && _retry=y
	_sync_simple "$_gso"   "quic_gso on;"   "quic_gso on;"
	_sync_simple "$_retry" "quic_retry on;" "quic_retry on;"

	# $http3 в access-логе (формат anonymized) — видно долю HTTP/3 vs HTTP/2. Переменная
	# определена только модулем http_v3 → добавляем ТОЛЬКО при HTTP3=y, иначе nginx -t упадёт
	# («unknown variable http3»). sed идемпотентен и обратим (убираем при HTTP3=n).
	if [[ "$NGX_HTTP3" == "y" ]]; then
		sed -i "s|\$http_user_agent\"';|\$http_user_agent\" h3=\$http3';|" "$conf"
	else
		sed -i "s|\$http_user_agent\" h3=\$http3';|\$http_user_agent\"';|" "$conf"
	fi

	# quic_bpf валиден ТОЛЬКО в main-контексте → анкор начала строки БЕЗ отступа
	# (не заденет ни описания, ни примеры с отступом внутри http-блока).
	if [[ "$NGX_HTTP3" == "y" ]]; then
		sed -i 's|^#[[:space:]]*\(quic_bpf on;\)|\1|' "$conf"
	else
		sed -i 's|^\(quic_bpf on;\)|# \1|' "$conf"
	fi
	_sync_simple "$NGX_BROTLI"    "brotli on;"                "brotli on;" "brotli_comp" "brotli_static" "brotli_types"
	_sync_simple "$NGX_ZSTD"      "zstd on;"                  "zstd on;" "zstd_comp" "zstd_static" "zstd_types"
	_sync_simple "$NGX_HEADERMOD" "more_clear_headers"        "more_clear_headers" "more_set_headers"
	_sync_simple "$NGX_VTS"       "vhost_traffic_status_zone" "vhost_traffic_status_zone"

	# GeoIP2 — многострочные блоки geoip2 { } (perl). log_format geoip НЕ трогаем
	# (он многострочный и опционален — иначе сломается nginx -t).
	if [[ "$NGX_GEOIP" == "y" ]] && _commented "geoip2"; then
		perl -i -ne 'if(/^\s*#\s*geoip2\s/){s/^(\s*)#\s?/$1/;$in=1}elsif($in&&/^\s*#\s*\$geoip2/){s/^(\s*)#\s?/$1/}elsif($in&&/^\s*#\s*\}/){s/^(\s*)#\s?/$1/;$in=0}print;' "$conf" 2>/dev/null || ui_warn "perl-синхронизация geoip2 не выполнена."
	elif [[ "$NGX_GEOIP" != "y" ]] && _active "geoip2"; then
		perl -i -ne 'if(/^\s*geoip2\s/){s/^(\s*)/$1# /;$in=1}elsif($in&&/^\s*\$geoip2/){s/^(\s*)/$1# /}elsif($in&&/^\s*\}/){s/^(\s*)/$1# /;$in=0}print;' "$conf" 2>/dev/null || true
	fi
}

# --- Landing page + default server ------------------------------------------
_nginx_landing_page() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} /var/www/html/index.html + conf.d/00-default.conf"
		return 0
	fi
	mkdir -p /var/www/html
	if [[ ! -f /var/www/html/index.html ]]; then
		cat >/var/www/html/index.html <<'HTML'
<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">
<title>nginx</title></head><body style="font-family:sans-serif;text-align:center;margin-top:6em">
<h1>nginx работает</h1><p>Сервер установлен через server-installer.</p></body></html>
HTML
		chown -R "$NGX_USER:$NGX_GROUP" /var/www/html
	fi
	# Плейсхолдер php-сниппета: пустой до php-этапа, затем php.sh впишет FPM-сокет
	# версии по умолчанию. Пустой include безопасен (location вернёт 404 на .php).
	[[ -f /etc/nginx/snippets/php-default.conf ]] || \
		echo "# заполняется на этапе PHP (php.sh _php_set_default)" >/etc/nginx/snippets/php-default.conf
	# Каталог доп. location'ов default-сервера: сюда другие этапы кладут правила
	# (напр. dbtools — ограничение доступа к /phpmyadmin). Пустой include безопасен.
	mkdir -p /etc/nginx/snippets/default-locations
	local quic=""
	[[ "$NGX_HTTP3" == "y" ]] && quic=$'\n    listen 443 quic reuseport;\n    add_header alt-svc \'h3=":443"; ma=86400\';'
	# Поведение default-сервера на :80 по IP / неизвестному домену (HTTP_IP_POLICY):
	#   landing  — отдавать /var/www/html (roundcube/phpmyadmin по IP) [по умолчанию]
	#   redirect — 301 на SERVER_FQDN (если публичный)
	#   deny     — 444 (по IP ничего не отдаётся)
	local _http80_body=""
	case "${HTTP_IP_POLICY:-landing}" in
		deny) _http80_body='    return 444;' ;;
		redirect)
			if [[ "${SERVER_FQDN:-}" == *.* ]]; then
				_http80_body="    return 301 https://${SERVER_FQDN}\$request_uri;"
			else
				ui_warn "HTTP_IP_POLICY=redirect без публичного SERVER_FQDN — оставляю лендинг по IP."
			fi
			;;
	esac
	[[ -z "$_http80_body" ]] && _http80_body="$(cat <<'L80'
    root /var/www/html;
    index index.php index.html;

    # Доп. правила этапов (ограничение /phpmyadmin и т.п.). ДО общего .php-location.
    include snippets/default-locations/*.conf;

    # PHP в /var/www/html (включая симлинки /phpmyadmin, /roundcube).
    location ~ \.php$ {
        include snippets/php-default.conf;
    }
L80
)"
	cat >/etc/nginx/conf.d/00-default.conf <<DEF
server {
    listen 80 default_server;
    server_name _;
${_http80_body}
}
server {
    listen 443 ssl default_server;${quic}
    server_name _;
    ssl_reject_handshake on;
}
DEF
}

# --- CrowdSec (post-install) -------------------------------------------------
install_crowdsec() {
	[[ "${FIREWALL:-}" == "crowdsec" ]] || return 0
	ui_step "Установка CrowdSec"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} crowdsec + collections + firewall-bouncer (nftables)"
		return 0
	fi
	ui_spin "Репозиторий CrowdSec" bash -c "curl -s --connect-timeout 15 --max-time 120 https://install.crowdsec.net | bash" || \
		{ ui_warn "Не удалось добавить репозиторий CrowdSec."; _crowdsec_fallback_ufw; return 0; }
	# Репозиторий CrowdSec раздаётся через CloudFront — с части VDS (особенно RU)
	# он не качается (Connection timed out). Без cscli продолжать бессмысленно.
	# ВАЖНО: успех судим по НАЛИЧИЮ cscli, а НЕ по коду возврата apt. Постинст
	# crowdsec (cscli setup / hub update / capi register) часто выходит non-zero,
	# хотя пакет реально установлен и cscli работает. Опора на apt-код давала
	# ЛОЖНЫЙ фоллбэк на UFW при полностью рабочем crowdsec (acquis/bouncer пропускались).
	apt_install crowdsec || true
	if ! command -v cscli >/dev/null 2>&1; then
		ui_error "Пакет crowdsec не установился (CDN packagecloud/CloudFront недоступен с этого сервера)."
		_crowdsec_fallback_ufw
		return 0
	fi
	# Без свежего hub-индекса collections install сыпет ошибками
	sys_run "Обновление hub CrowdSec" cscli hub update || true
	# Коллекция парсера под активный веб-сервер (nginx или apache2)
	local web_collection="crowdsecurity/nginx" web_type="nginx"
	[[ "${WEBSERVER:-nginx}" == "apache" ]] && { web_collection="crowdsecurity/apache2"; web_type="apache2"; }
	local c
	for c in "$web_collection" crowdsecurity/http-cve crowdsecurity/base-http-scenarios \
	         crowdsecurity/whitelist-good-actors crowdsecurity/linux; do
		sys_run "cscli collections install $c" cscli collections install "$c" || true
	done
	# Acquisition: логи активного веб-сервера + per-site логи ISPConfig.
	# type ДОЛЖЕН совпадать с парсером коллекции, иначе строки не разбираются.
	# ВАЖНО (nginx): публичные access-логи анонимизируются (GDPR, последний октет → .0) — если
	# скармливать их CrowdSec, он банит сетевой адрес «.0», а не реального атакующего. Поэтому для
	# nginx читаем РЕАЛЬНЫЕ IP из отдельного crowdsec.log (его пишут nginx.conf + vhost-шаблон рядом
	# с публичным логом). Apache в нашей сборке логи не анонимизирует — там читаем обычные access.
	mkdir -p /etc/crowdsec/acquis.d
	# nginx: ВСЕ сайты пишут crowdsec-строки в ЕДИНЫЙ /var/log/nginx/crowdsec.log (vhost-шаблон),
	# поэтому читаем ОДИН стабильный файл — новые сайты покрываются автоматически, без per-site
	# glob (его CrowdSec не подхватывал для каталогов сайтов, созданных после старта → пробел).
	# Apache логи не анонимизирует → там читаем обычные per-site access (glob оставляем).
	local acq_files
	if [[ "${WEBSERVER:-nginx}" == "apache" ]]; then
		acq_files=$'  - /var/log/apache2/*access*.log\n  - /var/log/ispconfig/httpd/*/access.log'
	else
		acq_files='  - /var/log/nginx/crowdsec.log'
	fi
	cat >/etc/crowdsec/acquis.d/web-ispconfig.yaml <<ACQ
filenames:
${acq_files}
labels:
  type: ${web_type}
ACQ
	# Подчищаем устаревшее имя из прошлых версий установщика
	rm -f /etc/crowdsec/acquis.d/nginx-ispconfig.yaml
	# Пакет CrowdSec при установке создаёт setup.nginx.yaml, читающий АНОНИМИЗИРОВАННЫЙ
	# /var/log/nginx/*.log (баны .0 + дубль нашего crowdsec.log). Наш web-ispconfig.yaml уже
	# покрывает nginx реальными IP — убираем пакетный (только для nginx).
	[[ "${WEBSERVER:-nginx}" == "apache" ]] || _crowdsec_drop_anon_acquis
	# CAPI: community blocklist (упреждающие баны). Идемпотентная страховка поверх postinst пакета.
	_crowdsec_capi_register
	# Еженедельное авто-обновление правил детекта (hub сам не апгрейдится).
	_crowdsec_hub_autoupdate
	# Эскалация bantime рецидивистам (повторный IP сидит дольше).
	_crowdsec_profile_escalation
	# Per-site логи crowdsec больше не используются (единый /var/log/nginx/crowdsec.log, ротируется
	# штатным logrotate nginx). Старый per-site logrotate убираем — иначе повторный прогон
	# пересоздавал его вопреки _ispconfig_crowdsec_shared_migrate (который его удаляет).
	rm -f /etc/logrotate.d/crowdsec-realip 2>/dev/null || true
	# Детект почтового брута (SMTP/IMAP) — если выбрана почта. Веб-логи ISPConfig
	# анонимизирует (последний октет .0) → CrowdSec там банит «.0»; mail.log с РЕАЛЬНЫМИ
	# IP, поэтому почтовые брутеры банятся по-настоящему. E2E: 81.30.98.0/24 (IR) забанен.
	_crowdsec_enable_mail
	# Bouncer тип 1 — firewall (nftables, без модулей nginx)
	apt_install crowdsec-firewall-bouncer-nftables || \
		apt_install crowdsec-firewall-bouncer-iptables || \
		ui_warn "firewall-bouncer не установлен — CrowdSec будет детектить, но НЕ банить."

	# ВАЖНО: LAPI CrowdSec по умолчанию слушает 127.0.0.1:8080 — ТОТ ЖЕ порт, что и
	# веб-панель ISPConfig (ISPCONFIG_PANEL_PORT, по умолч. 8080). После установки
	# панели агент CrowdSec не стартует («address already in use»). Уводим LAPI на
	# свободный порт. Делать ПОСЛЕ установки бунсера (правим и его api_url).
	_crowdsec_avoid_panel_port

	sys_run "Перезапуск CrowdSec" systemctl restart crowdsec
	# Бунсер мог запуститься с прежним api_url — перечитываем.
	systemctl restart crowdsec-firewall-bouncer >>"$SETUP_LOG" 2>&1 || true
}

# Включить детект почтового брута в CrowdSec: коллекции postfix+dovecot + acquisition mail.log.
# Идемпотентно; гейт — только если выбрана/стоит почта. type=syslog: один лог mail.log, парсеры
# postfix/dovecot роутятся по имени программы. mail.log НЕ анонимизируется (реальные IP) →
# SMTP/IMAP-брутеры банятся по-настоящему (в отличие от веб-логов с маскировкой .0).
# Вызывается из install_crowdsec (install) и из --update (для уже стоящих серверов).
_crowdsec_enable_mail() {
	command -v cscli >/dev/null 2>&1 || return 0
	# почта есть? (выбрана в компонентах ИЛИ уже установлен postfix)
	[[ " ${COMPONENTS:-} " == *" mail "* ]] || command -v postfix >/dev/null 2>&1 || return 0
	local changed=0 c
	if [[ ! -f /etc/crowdsec/collections/postfix.yaml || ! -f /etc/crowdsec/collections/dovecot.yaml ]]; then
		cscli hub update >>"$SETUP_LOG" 2>&1 || true
		for c in crowdsecurity/postfix crowdsecurity/dovecot; do
			[[ -f "/etc/crowdsec/collections/$(basename "$c").yaml" ]] && continue
			sys_run "cscli collections install $c" cscli collections install "$c" && changed=1 || true
		done
	fi
	mkdir -p /etc/crowdsec/acquis.d
	local f=/etc/crowdsec/acquis.d/mail-ispconfig.yaml
	if [[ ! -f "$f" ]]; then
		cat >"$f" <<'ACQ'
filenames:
  - /var/log/mail.log
labels:
  type: syslog
ACQ
		changed=1
	fi
	# mail.log может ещё не существовать (этап mail позже по порядку) — создаём, чтобы
	# CrowdSec начал его тейлить сразу; реальные строки появятся, когда заработает Postfix/Dovecot.
	[[ -e /var/log/mail.log ]] || { : >/var/log/mail.log; chmod 640 /var/log/mail.log 2>/dev/null || true; }
	# Debian/Ubuntu дублируют mail.* И в /var/log/mail.log, И в /var/log/syslog. CrowdSec читает
	# оба (наш mail-ispconfig.yaml=mail.log + сгенерированный cscli setup.linux.yaml=syslog) →
	# почтовый брут парсится ДВАЖДЫ (баны срабатывают вдвое агрессивнее). Исключаем mail из syslog.
	_crowdsec_mail_nodup_syslog
	if (( changed )); then
		# restart, НЕ reload: reload оставляет подтяжку CAPI неинициализированной (см. selfupdate/hub).
		systemctl restart crowdsec >>"$SETUP_LOG" 2>&1 || true
		ui_info "CrowdSec: включён детект почтового брута (postfix+dovecot, /var/log/mail.log) — реальные IP."
	fi
	return 0
}

# Исключить mail.* из /var/log/syslog (rsyslog), чтобы CrowdSec не парсил почту дважды
# (mail.log + syslog). Источник истины по почте — /var/log/mail.log. Идемпотентно, с проверкой
# конфига rsyslogd -N1 и откатом. Бонус: syslog чуть меньше пухнет.
_crowdsec_mail_nodup_syslog() {
	local rc=/etc/rsyslog.conf
	[[ -f "$rc" ]] || return 0
	command -v rsyslogd >/dev/null 2>&1 || return 0
	grep -qE 'mail\.none' "$rc" && return 0                                         # уже исключено
	grep -qE '\*\.\*.*[[:space:]]-?/var/log/syslog[[:space:]]*$' "$rc" || return 0   # нет ожидаемой строки
	cp -a "$rc" "$rc.ss.bak"
	awk '
		/\*\.\*.*[[:space:]]-?\/var\/log\/syslog[[:space:]]*$/ && $0 !~ /mail\.none/ {
			sub(/[[:space:]]+-?\/var\/log\/syslog[[:space:]]*$/, ";mail.none&")
		}
		{ print }
	' "$rc.ss.bak" > "$rc"
	if rsyslogd -N1 >>"$SETUP_LOG" 2>&1; then
		rm -f "$rc.ss.bak"
		systemctl restart rsyslog >>"$SETUP_LOG" 2>&1 || true
		ui_info "CrowdSec: mail исключён из /var/log/syslog — двойной парсинг почты устранён (источник только mail.log)."
	else
		mv -f "$rc.ss.bak" "$rc"
		ui_warn "CrowdSec: rsyslogd -N1 отверг правку syslog — откатил, mail пока парсится дважды (не критично)."
	fi
}

# Убрать авто-acquis пакета CrowdSec (setup.nginx.yaml), который читает анонимизированный
# /var/log/nginx/*.log → CrowdSec банит сетевой .0 (а не атакующего) и дублирует наш crowdsec.log.
# Реальные IP nginx читаются из web-ispconfig.yaml (crowdsec.log). Идемпотентно; reload подхватывает.
# Зовётся из install_crowdsec (install) и из --update (для уже стоящих серверов).
_crowdsec_drop_anon_acquis() {
	command -v cscli >/dev/null 2>&1 || return 0
	[[ -f /etc/crowdsec/acquis.d/setup.nginx.yaml ]] || return 0
	rm -f /etc/crowdsec/acquis.d/setup.nginx.yaml
	systemctl reload crowdsec >>"$SETUP_LOG" 2>&1 || systemctl restart crowdsec >>"$SETUP_LOG" 2>&1 || true
	ui_info "CrowdSec: убран setup.nginx.yaml (читал анонимизированный лог → баны .0); nginx — через crowdsec.log."
	log "crowdsec: removed pkg setup.nginx.yaml (anonymized acquis)"
}

# CAPI (CrowdSec Central API): регистрация для community blocklist — упреждающие баны IP,
# отмеченных всей сетью CrowdSec (десятки тысяч), + анонимный обмен сигналами. Пакет обычно
# регистрирует сам в postinst; здесь идемпотентная страховка (регистрируем ТОЛЬКО если не
# зарегистрирован — иначе создали бы дубль машины в CAPI). Отключаемо CROWDSEC_CAPI=n.
_crowdsec_capi_register() {
	command -v cscli >/dev/null 2>&1 || return 0
	[[ "${CROWDSEC_CAPI:-y}" == "y" ]] || return 0
	if cscli capi status >/dev/null 2>&1; then
		log "crowdsec: CAPI уже зарегистрирован (community blocklist активен)."
		return 0
	fi
	if cscli capi register >>"$SETUP_LOG" 2>&1; then
		systemctl reload crowdsec >>"$SETUP_LOG" 2>&1 || systemctl restart crowdsec >>"$SETUP_LOG" 2>&1 || true
		ui_info "CrowdSec CAPI зарегистрирован — community blocklist (упреждающие баны известных сетей) активен."
	else
		ui_warn "CrowdSec CAPI: регистрация не удалась (нет доступа к api.crowdsec.net?) — работают локальные сценарии."
	fi
}

# Еженедельное авто-обновление ПРАВИЛ детекта CrowdSec (hub: сценарии/парсеры/коллекции).
# Community blocklist (список IP) агент тянет сам ~раз в 2ч; а вот hub-правила сами НЕ
# апгрейдятся — со временем устаревают (новые CVE/паттерны атак не детектятся). Ставим
# wrapper + cron (аналог авто-обновления баз антивируса). Отключаемо CROWDSEC_HUB_AUTOUPDATE=n.
_crowdsec_hub_autoupdate() {
	command -v cscli >/dev/null 2>&1 || return 0
	[[ "${CROWDSEC_HUB_AUTOUPDATE:-y}" == "y" ]] || return 0
	cat >/usr/local/sbin/ss-crowdsec-hub-upgrade <<'SH'
#!/bin/sh
# luckystack: обновление правил hub CrowdSec (сценарии/парсеры/коллекции) + reload.
# Случайная задержка до ~40 мин — не бить CDN hub со всех серверов разом.
command -v cscli >/dev/null 2>&1 || exit 0
sleep $(( $(od -An -N2 -tu2 /dev/urandom 2>/dev/null || echo 0) % 2400 ))
cscli hub update  >/dev/null 2>&1
cscli hub upgrade >/dev/null 2>&1
# restart, НЕ reload: reload (SIGHUP) оставляет подтяжку community blocklist (CAPI) неинициализированной
# → CAPI-решения истекают и не обновляются до полного рестарта. После hub upgrade рестарт и правильнее
# (подхватывает новые парсеры/сценарии/коллекции).
systemctl restart crowdsec >/dev/null 2>&1
exit 0
SH
	chmod 750 /usr/local/sbin/ss-crowdsec-hub-upgrade
	cat >/etc/cron.d/ss-crowdsec-hub <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# luckystack: еженедельное авто-обновление правил hub CrowdSec (пн 04:23 + случайная задержка)
23 4 * * 1 root /usr/local/sbin/ss-crowdsec-hub-upgrade
CRON
	chmod 644 /etc/cron.d/ss-crowdsec-hub
	ui_info "CrowdSec: еженедельное авто-обновление правил hub включено (пн 04:23)."
	log "crowdsec: hub autoupdate cron installed"
}

# Эскалация bantime рецидивистам: в profiles.yaml включаем duration_expr, который умножает
# базовый бан на (число прошлых решений по этому IP + 1). Первый бан = 4ч; повторный (был 1
# прошлый) = 8ч; 3 прошлых = 16ч; 8 = 36ч и т.д. — «постоянные гости» сидят кратно дольше.
# Идемпотентно: если активная (не закомментированная) строка duration_expr уже есть — не трогаем
# (уважаем ручные правки). Line-based awk (mawk-safe: Debian по умолчанию mawk, без multichar RS).
# CrowdSec штатно поставляет эту же строку закомментированной — мы её активируем.
# Вызывается из install_crowdsec (install) и из --update (для уже стоящих серверов).
_crowdsec_profile_escalation() {
	command -v cscli >/dev/null 2>&1 || return 0
	[[ "${CROWDSEC_BANTIME_ESCALATION:-y}" == "y" ]] || return 0
	local pf=/etc/crowdsec/profiles.yaml
	[[ -f "$pf" ]] || return 0
	# уже включено (активная, не закомментированная строка)? — идемпотентный выход
	if grep -Eq '^[[:space:]]*duration_expr:' "$pf"; then
		log "crowdsec: эскалация bantime уже включена (duration_expr присутствует)"
		return 0
	fi
	local de="duration_expr: Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 4)"
	cp -a "$pf" "${pf}.bak.$(date +%s)" 2>/dev/null || true
	# Вставляем de перед top-level on_success: в каждом профиле с remediation-фильтром,
	# если в этом блоке ещё нет активного duration_expr. Разделитель профилей — строка '---'.
	awk -v de="$de" '
		/^---[[:space:]]*$/ { rem=0; has=0; print; next }
		/Alert\.Remediation == true/ { rem=1 }
		/^[[:space:]]*duration_expr:/ { has=1 }
		/^on_success:/ { if(rem==1 && has==0){ print de }; print; next }
		{ print }
	' "$pf" > "${pf}.new" 2>/dev/null || { rm -f "${pf}.new"; ui_warn "CrowdSec: не удалось обработать profiles.yaml — эскалация пропущена."; return 0; }
	# Подстраховка: если awk ничего не вставил (нет on_success/структура иная) — не ломаем файл
	if ! grep -Eq '^[[:space:]]*duration_expr:' "${pf}.new"; then
		rm -f "${pf}.new"; log "crowdsec: profiles.yaml без ожидаемой структуры — эскалация пропущена"; return 0
	fi
	mv "${pf}.new" "$pf"
	# ВАЖНО: именно restart, НЕ reload. `systemctl reload crowdsec` (SIGHUP) на практике оставляет
	# планировщик подтяжки community blocklist (CAPI) неинициализированным → CAPI-решения истекают и
	# больше не обновляются до полного рестарта (наблюдалось на проде: 0 CAPI после reload, 15k после
	# restart). Идемпотентность функции (return выше, если duration_expr уже есть) гарантирует, что
	# рестарт происходит ОДИН раз — при первом включении эскалации, не на каждом --update.
	if systemctl restart crowdsec >>"$SETUP_LOG" 2>&1; then
		ui_info "CrowdSec: включена эскалация bantime рецидивистам (+4ч за каждое прошлое решение по IP)."
	else
		ui_warn "CrowdSec: restart после правки profiles.yaml не прошёл — проверьте $pf (бэкап рядом)."
	fi
	log "crowdsec: bantime escalation enabled"
}

# Порт занят (слушается) кем-либо?
# (без пайпа в grep -q как условия: SIGPIPE-футган под pipefail — см. pipefail_grep_footgun)
_port_in_use() { [[ -n "$(ss -ltnH 2>/dev/null | awk -v p="$1" '{n=split($4,a,":"); if (a[n]==p) print "y"}')" ]]; }
# Порт слушает сам crowdsec (повторный прогон при работающем агенте) — это НЕ конфликт.
_port_held_by_crowdsec() { [[ -n "$(ss -ltnpH "sport = :${1}" 2>/dev/null | grep -o 'users:(("crowdsec"')" ]]; }

# Сверка портов LAPI CrowdSec ↔ панель ISPConfig (и вообще занятость).
# LAPI по умолчанию 127.0.0.1:8080 = порт панели ISPConfig (по умолч. 8080) →
# агент CrowdSec не стартует. Здесь: если текущий порт LAPI совпадает с портом
# панели ИЛИ уже кем-то слушается — уводим LAPI на ближайший свободный порт,
# заведомо отличный от порта панели.
_crowdsec_avoid_panel_port() {
	local cfg=/etc/crowdsec/config.yaml cred=/etc/crowdsec/local_api_credentials.yaml b
	local panel="${ISPCONFIG_PANEL_PORT:-8080}" cur lapi
	# Текущий порт LAPI из конфига (по умолчанию 8080).
	cur="$(grep -E '^[[:space:]]*listen_uri:' "$cfg" 2>/dev/null | grep -oE '[0-9]+$' | head -1)"
	cur="${cur:-8080}"
	# Конфликта нет: LAPI ≠ порт панели И порт LAPI пока свободен → не трогаем.
	if [[ "$cur" != "$panel" ]] && { ! _port_in_use "$cur" || _port_held_by_crowdsec "$cur"; }; then
		log "crowdsec: LAPI порт ${cur} ≠ панели (${panel}) и свободен/наш — без изменений."
		return 0
	fi
	# Подбираем свободный порт, заведомо отличный от порта панели.
	lapi=8237
	while [[ "$lapi" == "$panel" ]] || _port_in_use "$lapi"; do lapi=$((lapi + 1)); done
	[[ -f "$cfg" ]]  && sed -i -E "s|^([[:space:]]*listen_uri:).*|\1 127.0.0.1:${lapi}|" "$cfg"
	[[ -f "$cred" ]] && sed -i -E "s|^(url:).*|\1 http://127.0.0.1:${lapi}|" "$cred"
	for b in /etc/crowdsec/bouncers/*.yaml; do
		[[ -f "$b" ]] && sed -i -E "s|^([[:space:]]*api_url:).*|\1 http://127.0.0.1:${lapi}/|" "$b"
	done
	ui_info "CrowdSec LAPI перенесён на 127.0.0.1:${lapi} (порт ${cur} конфликтует с панелью/занят)."
	log "crowdsec: LAPI ${cur} → ${lapi} (panel=${panel})"
}

# CrowdSec недоступен (обычно CDN заблокирован для региона VDS) — чтобы сервер
# не остался совсем без firewall, переключаемся на UFW: его настроит этап
# «Безопасность» (если выбран), иначе предупреждаем.
_crowdsec_fallback_ufw() {
	if [[ " ${COMPONENTS:-} " == *" security "* ]]; then
		ui_warn "Переключаю FIREWALL=ufw — UFW будет настроен на этапе «Безопасность»."
		config_set FIREWALL ufw
	else
		ui_error "Этап «Безопасность» не выбран — сервер останется БЕЗ firewall!"
		ui_warn "Установите вручную: apt install ufw && ufw allow 22,80,443/tcp && ufw enable"
		config_set FIREWALL none
	fi
}

# Повторный прогон на РАБОТАЮЩЕМ nginx (--update «пересборка» / --only nginx): новый бинарник уже
# лежит в /usr/sbin/nginx, но живой master работает на старом (enable --now на активной службе —
# no-op, а -s reload бинарник не меняет) → security-апдейт остался бы неактивным.
# Гейт: nginx -t НОВЫМ бинарником с реальным конфигом; при провале — откат бинарника
# (nginx.backup) и конфига (nginx.conf.orig = копия ДО этого прогона), живой nginx не трогаем.
_nginx_activate_new_binary() {
	local newv; newv="$(/usr/sbin/nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
	if ! /usr/sbin/nginx -t >>"$SETUP_LOG" 2>&1; then
		ui_error "Новый nginx ${newv} не прошёл nginx -t — откат бинарника и конфига, живой nginx не тронут."
		[[ -f /usr/sbin/nginx.backup ]]     && cp -a /usr/sbin/nginx.backup /usr/sbin/nginx
		[[ -f /etc/nginx/nginx.conf.orig ]] && cp -a /etc/nginx/nginx.conf.orig /etc/nginx/nginx.conf
		log "nginx: activate FAILED (nginx -t) -> rollback binary+conf"
		return 1
	fi
	if [[ "${UNATTENDED:-0}" != "1" && -t 0 ]]; then
		ui_confirm "Активировать новый nginx ${newv}? (systemctl restart, ~1 с простоя)" y || {
			ui_warn "Новый бинарник НЕ активен — работает прежний nginx. Позже: nginx -t && systemctl restart nginx"
			log "nginx: activate skipped by user"; return 0; }
	fi
	if sys_run "Рестарт nginx (активация ${newv})" systemctl restart nginx && systemctl is-active nginx >/dev/null 2>&1; then
		ui_success "nginx активен: $(nginx -v 2>&1 | sed 's/^nginx version: //')"
		log "nginx: activated ${newv}"
		return 0
	fi
	ui_error "Рестарт с новым бинарником не удался — откатываю на предыдущий nginx."
	[[ -f /usr/sbin/nginx.backup ]]     && cp -a /usr/sbin/nginx.backup /usr/sbin/nginx
	[[ -f /etc/nginx/nginx.conf.orig ]] && cp -a /etc/nginx/nginx.conf.orig /etc/nginx/nginx.conf
	systemctl restart nginx >>"$SETUP_LOG" 2>&1 || true
	log "nginx: activate FAILED (restart) -> rollback + restart old"
	return 1
}

# Откат на прошлую сборку (--rollback nginx). Бинарники меняются местами, поэтому откат можно отменить
# таким же повтором. Прошлая сборка сначала проверяет текущий конфиг, иначе рабочий nginx не трогаем.
_nginx_rollback() {
	local cur=/usr/sbin/nginx bak=/usr/sbin/nginx.backup tmp="/usr/sbin/nginx.rollback.$$"
	[[ -x "$bak" ]] || { ui_error "Прошлой сборки nginx нет (${bak})."; return 1; }
	if cmp -s "$cur" "$bak"; then ui_error "Прошлая сборка не отличается от текущей, откатывать нечего."; return 1; fi
	local cv bv
	cv="$("$cur" -V 2>&1 | grep -oE 'nginx/[0-9.]+|OpenSSL [0-9.]+' | head -2 | tr '\n' ' ')"
	bv="$("$bak" -V 2>&1 | grep -oE 'nginx/[0-9.]+|OpenSSL [0-9.]+' | head -2 | tr '\n' ' ')"
	ui_step "Откат nginx: ${cv}→ ${bv}"
	if ! "$bak" -t >>"$SETUP_LOG" 2>&1; then
		ui_error "Прошлая сборка не принимает текущий конфиг. Откат отменён, nginx не тронут. См. ${SETUP_LOG}"
		return 1
	fi
	cp -a "$cur" "$tmp" || return 1
	cp -a "$bak" "$cur.new" && mv -f "$cur.new" "$cur" && mv -f "$tmp" "$bak"
	if systemctl restart nginx >>"$SETUP_LOG" 2>&1 && sleep 1 && systemctl is-active --quiet nginx; then
		ui_success "nginx: откат выполнен, работает ${bv}. Прошлая сборка теперь ${cv}"
		log "nginx: rollback ${cv}-> ${bv}"
		return 0
	fi
	cp -a "$cur" "$tmp" && cp -a "$bak" "$cur.new" && mv -f "$cur.new" "$cur" && mv -f "$tmp" "$bak"
	systemctl restart nginx >>"$SETUP_LOG" 2>&1 || true
	ui_error "С прошлой сборкой nginx не запустился, вернул ${cv}"
	return 1
}

# --- Точка входа этапа -------------------------------------------------------
stage_nginx() {
	_nginx_resolve_flags
	local _ngx_was_active=0; systemctl is-active nginx >/dev/null 2>&1 && _ngx_was_active=1
	ui_info "nginx ${UI_BOLD}${NGINX_VER}${UI_NC} (${NGINX_CHANNEL}) · HTTP3=${NGX_HTTP3} Brotli=${NGX_BROTLI} GeoIP2=${NGX_GEOIP} zstd=${NGX_ZSTD}"

	_nginx_install_deps        || return 1
	_nginx_prebuild_openssl    || return 1   # синхронно; при HTTP3 критична
	_nginx_fetch_sources       || return 1
	_nginx_apply_patches       # патчи (может отключить zlib-ng) — ДО assemble
	_nginx_assemble_flags
	_nginx_compile             || return 1
	_nginx_setup_service       || return 1
	_nginx_deploy_conf                      # кастомный nginx.conf + snippets + sync
	_nginx_landing_page
	_nginx_fetch_geoip_db

	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		if (( _ngx_was_active )); then
			_nginx_activate_new_binary || true
		else
			sys_run "Запуск nginx" systemctl enable --now nginx || \
				ui_warn "nginx установлен, но не стартовал — проверьте 'nginx -t' и $NGX_BUILD_LOG"
		fi
	fi

	install_crowdsec
	ui_success "nginx готов."
	return 0
}
