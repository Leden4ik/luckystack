#!/bin/bash
# =============================================================================
# lib/tuning.sh — Этап (опц.): авто-тюнинг под реальное железо.
#
#   Стек ставится на «безопасных» дефолтах, рассчитанных на минимум RAM. На VPS
#   с 4-16 ГБ это значит простаивающие ресурсы. Этап подбирает разумные значения
#   по фактическим RAM/CPU:
#     • MariaDB  — innodb_buffer_pool_size, log_file_size, max_connections
#     • PHP      — OPcache, memory_limit, realpath cache (для всех версий FPM/CLI)
#     • Postfix  — message_size_limit
#   Настройки кладутся ОТДЕЛЬНЫМИ drop-in файлами (не правят основной конфиг) —
#   их легко найти и откатить. MariaDB-тюнинг с автo-откатом, если служба не
#   поднялась с новыми значениями.
# =============================================================================

TUNE_MARIADB_DROPIN=""   # вычисляется в стадии (зависит от каталога conf.d)
TUNE_PHP_INI=99-zz-luckystack-tuning.ini

stage_tuning() {
	local ram_mb cpu
	ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
	cpu="$(nproc 2>/dev/null || echo 1)"
	[[ "$ram_mb" =~ ^[0-9]+$ ]] || ram_mb=1024
	ui_info "Авто-тюнинг под железо: RAM ${ram_mb} МБ, CPU ${cpu}."

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} MariaDB: innodb_buffer_pool ~$(_tune_pool_mb "$ram_mb")M, max_connections, log_file_size"
		ui_info "${UI_D}[dry-run]${UI_NC} PHP: OPcache + memory_limit для всех версий"
		ui_info "${UI_D}[dry-run]${UI_NC} Postfix: message_size_limit 50M"
		ui_info "${UI_D}[dry-run]${UI_NC} LimitNOFILE=65535 для mariadb/postfix/dovecot (systemd-override) + limits.conf"
		ui_success "Авто-тюнинг (имитация) выполнен."
		return 0
	fi

	_tune_limits          # ДО mariadb — чтобы её рестарт подхватил LimitNOFILE
	_tune_mariadb "$ram_mb" "$cpu"
	_tune_php "$ram_mb"
	_tune_postfix

	ui_success "Авто-тюнинг применён (RAM ${ram_mb} МБ, CPU ${cpu})."
	log "tuning: ram=${ram_mb} cpu=${cpu} pool=$(_tune_pool_mb "$ram_mb")M"
	return 0
}

# Размер innodb_buffer_pool в МБ по объёму RAM (консервативно).
_tune_pool_mb() {
	local ram="$1" pct pool
	if   ((ram < 2048)); then pct=25
	elif ((ram < 4096)); then pct=40
	else                      pct=50; fi
	pool=$((ram * pct / 100))
	((pool < 128)) && pool=128
	((pool > 24576)) && pool=24576   # потолок 24 ГБ — без фанатизма
	echo "$pool"
}

# Лимит открытых файлов (nofile) для сервисов БД/почты.
# ВАЖНО: для systemd-сервисов работает ТОЛЬКО systemd-override (LimitNOFILE=) —
# /etc/security/limits.conf на них НЕ влияет (PAM, только login-сессии). Пишем оба:
# override (рабочий путь) + limits.conf (паритет с Perfect Server, для login/cron).
_tune_limits() {
	ui_step "Лимит открытых файлов (LimitNOFILE) для сервисов"
	local svc changed=0
	for svc in mariadb postfix dovecot; do
		# наличие юнита проверяем через systemctl cat (надёжно, без pipe→SIGPIPE)
		systemctl cat "${svc}.service" >/dev/null 2>&1 || continue
		mkdir -p "/etc/systemd/system/${svc}.service.d"
		cat >"/etc/systemd/system/${svc}.service.d/limits.conf" <<'LIM'
# luckystack: лимит открытых файлов
[Service]
LimitNOFILE=65535
LIM
		changed=1
	done

	# limits.conf — паритет с гайдом (для login-сессий/cron; systemd-сервисы — через override выше)
	if ! grep -q 'luckystack: nofile' /etc/security/limits.conf 2>/dev/null; then
		cat >>/etc/security/limits.conf <<'LIMC'
# luckystack: nofile (login-сессии/cron; для systemd-сервисов — LimitNOFILE в override)
*    soft nofile 65535
*    hard nofile 65535
root soft nofile 65535
root hard nofile 65535
LIMC
	fi

	if ((changed)); then
		systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
		# postfix/dovecot перезапускаем здесь (нужен restart, не reload — лимит читается при старте);
		# mariadb перезапустит следующий шаг _tune_mariadb, поэтому её здесь не трогаем.
		for svc in postfix dovecot; do
			systemctl is-active --quiet "$svc" 2>/dev/null && \
				systemctl restart "$svc" >>"$SETUP_LOG" 2>&1 || true
		done
		ui_success "LimitNOFILE=65535 (mariadb/postfix/dovecot, systemd-override) + limits.conf."
	else
		ui_info "Целевые сервисы не найдены — LimitNOFILE применён только к limits.conf."
	fi
}

_tune_mariadb() {
	command -v mysql >/dev/null 2>&1 || { ui_info "MariaDB не установлена — тюнинг БД пропущен."; return 0; }
	local ram="$1" cpu="$2"
	local dir
	if [[ -d /etc/mysql/mariadb.conf.d ]]; then dir=/etc/mysql/mariadb.conf.d
	elif [[ -d /etc/mysql/conf.d ]];      then dir=/etc/mysql/conf.d
	else ui_warn "Не найден каталог conf.d MariaDB — тюнинг БД пропущен."; return 0; fi
	TUNE_MARIADB_DROPIN="$dir/90-luckystack-tuning.cnf"

	local pool log_mb conns
	pool="$(_tune_pool_mb "$ram")"
	log_mb=$((pool / 4)); ((log_mb > 512)) && log_mb=512; ((log_mb < 64)) && log_mb=64
	conns=$((cpu * 40)); ((conns < 100)) && conns=100; ((conns > 500)) && conns=500

	# innodb_buffer_pool_instances НЕ задаём: deprecated в MariaDB 10.5, удалён в 10.6 —
	# на 12.x это no-op + warning в логе (buffer pool всегда единый).
	# innodb_log_file_size в MariaDB актуален (это НЕ MySQL'ный innodb_redo_log_capacity).
	ui_step "Тюнинг MariaDB (buffer pool ${pool}M, max_connections ${conns})"
	cat >"$TUNE_MARIADB_DROPIN" <<EOF
# LuckyStack — авто-тюнинг под RAM ${ram}M / CPU ${cpu}. Можно править/удалить.
[mysqld]
innodb_buffer_pool_size      = ${pool}M
innodb_log_file_size         = ${log_mb}M
innodb_flush_method          = O_DIRECT
max_connections              = ${conns}
tmp_table_size               = 64M
max_heap_table_size          = 64M
EOF

	# Перезапуск с авто-откатом: если служба не поднялась — убираем drop-in.
	if sys_run "Перезапуск MariaDB с новыми параметрами" systemctl restart mariadb; then
		ui_success "MariaDB: тюнинг применён (${TUNE_MARIADB_DROPIN})."
	else
		ui_warn "MariaDB не поднялась с новыми параметрами — откатываю тюнинг."
		rm -f "$TUNE_MARIADB_DROPIN"
		sys_run "Перезапуск MariaDB (откат)" systemctl restart mariadb || \
			ui_error "MariaDB всё ещё не запускается — проверьте ${SETUP_LOG}."
	fi
}

_tune_php() {
	local ram="$1" v had=0 mem oc_mem
	# memory_limit и размер OPcache по объёму RAM (это БАЗОВЫЙ дефолт; ISPConfig
	# выставляет свои значения на уровне пулов отдельных сайтов).
	if   ((ram < 2048)); then mem=128; oc_mem=96
	elif ((ram < 4096)); then mem=256; oc_mem=128
	else                      mem=512; oc_mem=192; fi

	for v in /etc/php/*/; do
		v="$(basename "$v")"
		[[ -d "/etc/php/$v" ]] || continue
		had=1
		local sapi
		for sapi in fpm cli; do
			[[ -d "/etc/php/$v/$sapi/conf.d" ]] || continue
			cat >"/etc/php/$v/$sapi/conf.d/${TUNE_PHP_INI}" <<EOF
; LuckyStack — авто-тюнинг PHP ${v} (${sapi}). Можно править/удалить.
memory_limit = ${mem}M
realpath_cache_size = 4096k
realpath_cache_ttl = 600
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = ${oc_mem}
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 2
EOF
		done
		# Перезагрузить FPM этой версии (если активен)
		if systemctl is-active "php${v}-fpm" >/dev/null 2>&1; then
			systemctl reload "php${v}-fpm" >>"$SETUP_LOG" 2>&1 || \
				systemctl restart "php${v}-fpm" >>"$SETUP_LOG" 2>&1 || \
				ui_warn "php${v}-fpm не перезапустился после тюнинга — проверьте ${SETUP_LOG}."
		fi
	done
	((had)) && ui_success "PHP: OPcache + memory_limit ${mem}M применены ко всем версиям." \
	         || ui_info "PHP не найден — тюнинг PHP пропущен."
}

_tune_postfix() {
	command -v postfix >/dev/null 2>&1 || return 0
	ui_step "Тюнинг Postfix (размер письма не меньше 50 МБ)"
	# 0 = без лимита. Заданный больший или снятый лимит не снижаем: на проде из-за этого письма
	# больше 50 МБ перестали бы приниматься.
	local cur lim=52428800
	cur="$(postconf -h message_size_limit 2>/dev/null)"
	[[ "$cur" =~ ^[0-9]+$ ]] && { ((cur == 0)) || ((cur > lim)); } && lim="$cur"
	postconf -e "message_size_limit = ${lim}" 'mailbox_size_limit = 0' >>"$SETUP_LOG" 2>&1 && \
		sys_run "Перезагрузка Postfix" systemctl reload postfix || \
		ui_warn "Не удалось применить лимиты размера письма Postfix."
}

stage_tuning_summary() {
	echo "Tuning: MariaDB/PHP/Postfix под RAM/CPU"
}
