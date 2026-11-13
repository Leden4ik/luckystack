#!/bin/bash
# =============================================================================
# lib/backup.sh — Этап (опц.): серверное резервное копирование.
#
#   ISPConfig умеет бэкап САЙТОВ, но бэкапа серверного уровня (все БД + конфиги
#   + /etc) у него нет. Этот этап ставит автономный скрипт + systemd-таймер,
#   который ежедневно делает:
#     • по-базный дамп MariaDB (mysqldump --single-transaction, gzip)
#     • архив /etc, /usr/local/ispconfig (конфиг панели), crontab root
#     • опционально — /var/www (сайты) и /var/vmail (почта)
#   с ротацией по числу дней.
#
#   Параметры берутся из мастера (config_set) и дублируются в
#   /etc/server-backup.conf, чтобы скрипт/таймер работали независимо от
#   установщика и легко правились вручную.
# =============================================================================

BACKUP_SCRIPT=/usr/local/sbin/server-backup.sh
BACKUP_CONF=/etc/server-backup.conf
BACKUP_SVC=/etc/systemd/system/server-backup.service
BACKUP_TIMER=/etc/systemd/system/server-backup.timer

# Можно ли использовать каталог под бэкапы. Скрипт делает chmod 700 на каталог и чистит в нём
# старые снимки, поэтому системные каталоги, сайты, почта и корни вроде /var или /mnt запрещены.
# Те же правила продублированы в server-backup.sh (ниже) и в ss-backup-sync.php (панель).
_backup_dir_ok() {
	local d="${1%/}"
	[[ "$d" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
	[[ "$d" == *..* || "$d" == *//* ]] && return 1
	case "$d" in
		/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/var|/var/backups|/var/cache|/var/lib|/var/log|/var/mail|/var/spool|/var/tmp|/var/www|/var/vmail) return 1 ;;
		/bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib32/*|/lib64/*|/proc/*|/run/*|/sbin/*|/sys/*|/tmp/*|/usr/*|/var/cache/*|/var/lib/*|/var/log/*|/var/mail/*|/var/spool/*|/var/tmp/*|/var/www/*|/var/vmail/*) return 1 ;;
	esac
	return 0
}

stage_backup() {
	local dir="${BACKUP_DIR:-/var/backups/server}"
	if ! _backup_dir_ok "$dir"; then
		ui_error "Каталог бэкапов ${dir} не подходит: системный, каталог сайтов или почты. Укажите отдельный, например /var/backups/server."
		return 1
	fi
	local ret="${BACKUP_RETENTION_DAYS:-7}"
	local inc_www="${BACKUP_INCLUDE_WWW:-n}"
	local inc_mail="${BACKUP_INCLUDE_MAIL:-n}"
	local at="${BACKUP_TIME:-03:30}"
	local rtype="${BACKUP_REMOTE_TYPE:-none}"

	ui_info "Резервное копирование: ${dir} · хранить ${ret} дн. · сайты=${inc_www} почта=${inc_mail} · ежедневно в ${at}"
	[[ "$rtype" != "none" ]] && ui_info "Оффсайт-копия: ${rtype} → ${BACKUP_REMOTE:-<не задан>}"

	# rclone нужен для облачного оффсайта — доустанавливаем (если выбран и его нет)
	if [[ "$rtype" == "rclone" && "${DRY_RUN:-0}" != "1" ]] && ! command -v rclone >/dev/null 2>&1; then
		apt_install rclone || ui_warn "rclone не установился — облачный оффсайт работать не будет (apt install rclone)."
	fi

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} запись ${BACKUP_SCRIPT} + ${BACKUP_CONF}"
		ui_info "${UI_D}[dry-run]${UI_NC} systemd-таймер server-backup.timer (OnCalendar=${at})"
		ui_info "${UI_D}[dry-run]${UI_NC} первый тестовый прогон бэкапа"
		ui_success "Резервное копирование (имитация) настроено."
		return 0
	fi

	mkdir -p "$dir" 2>/dev/null || { ui_error "Не удаётся создать каталог бэкапов ${dir}."; return 1; }
	chmod 700 "$dir" 2>/dev/null || true   # в дампах БД пароли — закрываем от чужих

	# --- /etc/server-backup.conf (читается рантайм-скриптом) ---
	ui_step "Запись настроек бэкапа: ${BACKUP_CONF}"
	cat >"$BACKUP_CONF" <<EOF
# LuckyStack — настройки серверного бэкапа. Правьте вручную при необходимости.
BACKUP_DIR=${dir}
BACKUP_RETENTION_DAYS=${ret}
BACKUP_INCLUDE_WWW=${inc_www}
BACKUP_INCLUDE_MAIL=${inc_mail}
# Оффсайт-копия: BACKUP_REMOTE_TYPE = none | rsync | rclone
#   rsync:  BACKUP_REMOTE='user@host:/path/'  (+ опц. BACKUP_REMOTE_SSHPORT, BACKUP_REMOTE_SSHKEY)
#   rclone: BACKUP_REMOTE='remote:bucket/path' (предварительно настроить: rclone config)
BACKUP_REMOTE_TYPE=${rtype}
BACKUP_REMOTE='${BACKUP_REMOTE:-}'
BACKUP_REMOTE_SSHPORT='${BACKUP_REMOTE_SSHPORT:-}'
BACKUP_REMOTE_SSHKEY='${BACKUP_REMOTE_SSHKEY:-}'
BACKUP_REMOTE_OPTS='${BACKUP_REMOTE_OPTS:-}'
EOF
	chmod 600 "$BACKUP_CONF" 2>/dev/null || true

	# --- Рантайм-скрипт бэкапа ---
	ui_step "Установка скрипта бэкапа: ${BACKUP_SCRIPT}"
	_backup_write_script || { ui_error "Не удалось записать ${BACKUP_SCRIPT}."; return 1; }
	chmod 700 "$BACKUP_SCRIPT" 2>/dev/null || true

	# --- systemd service + timer ---
	ui_step "Создание systemd-таймера (ежедневно в ${at})"
	cat >"$BACKUP_SVC" <<EOF
[Unit]
Description=Server backup (databases + configs)
After=mariadb.service

[Service]
Type=oneshot
ExecStart=${BACKUP_SCRIPT}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
	cat >"$BACKUP_TIMER" <<EOF
[Unit]
Description=Daily server backup (databases + configs)

[Timer]
OnCalendar=*-*-* ${at}:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
	systemctl daemon-reload >>"$SETUP_LOG" 2>&1 || true
	sys_run "Включение таймера бэкапа" systemctl enable --now server-backup.timer || \
		ui_warn "Не удалось включить server-backup.timer — запускайте бэкап вручную: ${BACKUP_SCRIPT}"

	# --- Оффсайт rclone: создать remote из ответов мастера (S3/B2/SFTP) + проверить связь ---
	_backup_setup_rclone_remote

	# --- Первый тестовый прогон (чтобы убедиться, что всё работает) ---
	ui_spin "Первый тестовый бэкап (БД + конфиги)" "$BACKUP_SCRIPT" || \
		ui_warn "Тестовый бэкап завершился с замечаниями — см. ${dir}/backup.log"

	local last sz
	last="$(ls -1dt "$dir"/*/ 2>/dev/null | head -1)"
	sz="$(cat "${last%/}/.size" 2>/dev/null)"
	ui_success "Бэкап настроен. Последний: ${last:-—}${sz:+ (${sz})}"
	ui_info "Запуск вручную: ${UI_W}${BACKUP_SCRIPT}${UI_NC} · расписание: ${UI_W}systemctl list-timers server-backup.timer${UI_NC}"
	log "backup: dir=${dir} retention=${ret} www=${inc_www} mail=${inc_mail} at=${at}"
	return 0
}

# Записывает /usr/local/sbin/server-backup.sh.
# ВАЖНО: heredoc в кавычках ('SCRIPT') — содержимое НЕ интерполируется установщиком,
# все переменные раскрываются уже при запуске скрипта на сервере.
_backup_write_script() {
	cat >"$BACKUP_SCRIPT" <<'SCRIPT'
#!/bin/bash
# =============================================================================
# server-backup.sh — серверный бэкап (БД + конфиги). Автогенерация LuckyStack.
# Настройки: /etc/server-backup.conf. Запуск: ./server-backup.sh [--list]
# =============================================================================
set -uo pipefail

CONF=/etc/server-backup.conf
[[ -f "$CONF" ]] && . "$CONF"
DEST="${BACKUP_DIR:-/var/backups/server}"
DEST="${DEST%/}"
RET="${BACKUP_RETENTION_DAYS:-7}"
INC_WWW="${BACKUP_INCLUDE_WWW:-n}"
INC_MAIL="${BACKUP_INCLUDE_MAIL:-n}"
# У службы systemd нет HOME, и mysql сам не найдёт /root/.my.cnf, поэтому файл указываем явно.
# Без этого ночной запуск по таймеру получал Access denied и сохранял снимок без баз.
MYDEF=(); [[ -r /root/.my.cnf ]] && MYDEF=(--defaults-extra-file=/root/.my.cnf)

# Каталог бэкапов не может быть системным, каталогом сайтов или почты: chmod 700 и чистка
# старых снимков по такому пути сломали бы сервер. Правила те же, что в установщике и панели.
_dir_ok() {
	local d="$1"
	[[ "$d" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
	[[ "$d" == *..* || "$d" == *//* ]] && return 1
	case "$d" in
		/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/var|/var/backups|/var/cache|/var/lib|/var/log|/var/mail|/var/spool|/var/tmp|/var/www|/var/vmail) return 1 ;;
		/bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib32/*|/lib64/*|/proc/*|/run/*|/sbin/*|/sys/*|/tmp/*|/usr/*|/var/cache/*|/var/lib/*|/var/log/*|/var/mail/*|/var/spool/*|/var/tmp/*|/var/www/*|/var/vmail/*) return 1 ;;
	esac
	return 0
}
if ! _dir_ok "$DEST"; then
	echo "BACKUP_DIR=${DEST} не подходит для бэкапов (системный каталог, сайты или почта). Отказ." >&2
	exit 2
fi

LOG="$DEST/backup.log"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG" >&2; }

# --list — показать существующие бэкапы и выйти
if [[ "${1:-}" == "--list" ]]; then
	printf '%-22s %8s\n' "СНИМОК" "РАЗМЕР"
	for d in "$DEST"/*/; do
		[[ -d "$d" ]] || continue
		printf '%-22s %8s\n' "$(basename "$d")" "$(cat "${d%/}/.size" 2>/dev/null || echo '?')"
	done
	exit 0
fi

# --restore [СНИМОК] [--db --etc --ispconfig --www --vmail | --all] [--yes]
# Восстановление НЕОБРАТИМО перезаписывает данные. По умолчанию: последний снимок,
# только базы данных (самый частый и безопасный случай). Работает автономно.
if [[ "${1:-}" == "--restore" ]]; then
	shift
	SNAP=""; r_db=0; r_etc=0; r_ispc=0; r_www=0; r_vmail=0; yes=0
	while (($#)); do
		case "$1" in
			--db) r_db=1 ;; --etc) r_etc=1 ;; --ispconfig) r_ispc=1 ;;
			--www) r_www=1 ;; --vmail) r_vmail=1 ;;
			--all) r_db=1; r_etc=1; r_ispc=1; r_www=1; r_vmail=1 ;;
			--yes|-y) yes=1 ;;
			-*) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
			*) SNAP="$1" ;;
		esac; shift
	done
	[[ -z "$SNAP" ]] && SNAP="$(ls -1dt "$DEST"/*/ 2>/dev/null | head -1 | xargs -r basename)"
	[[ -n "$SNAP" && -d "$DEST/$SNAP" ]] || { echo "Снимок не найден: ${SNAP:-<нет>}. Список: $0 --list" >&2; exit 1; }
	SRC="$DEST/$SNAP"
	((r_db || r_etc || r_ispc || r_www || r_vmail)) || r_db=1   # по умолчанию — БД

	echo "Восстановление из снимка: $SNAP"
	((r_db))    && echo "  • базы данных MariaDB (перезапишет текущие)"
	((r_etc))   && echo "  • /etc (ОПАСНО: перезапишет системные конфиги)"
	((r_ispc))  && echo "  • /usr/local/ispconfig"
	((r_www))   && echo "  • /var/www (сайты)"
	((r_vmail)) && echo "  • /var/vmail (почта)"
	if ((yes == 0)); then
		read -rp "Это НЕОБРАТИМО перезапишет данные. Для продолжения введите 'yes': " ans
		[[ "$ans" == "yes" ]] || { echo "Отменено."; exit 0; }
	fi
	log "=== restore начат: $SNAP (db=$r_db etc=$r_etc ispc=$r_ispc www=$r_www vmail=$r_vmail) ==="
	rrc=0
	# --- Базы данных (дампы делались с --databases: содержат CREATE/USE) ---
	if ((r_db)); then
		if command -v mysql >/dev/null 2>&1; then
			shopt -s nullglob
			for f in "$SRC"/mysql/*.sql.gz; do
				db="$(basename "$f" .sql.gz)"
				if gunzip -c "$f" | mysql "${MYDEF[@]}" 2>>"$LOG"; then log "restore БД: $db"; else log "ОШИБКА restore БД $db"; rrc=1; fi
			done
			shopt -u nullglob
		else log "mysql не найден — БД пропущены"; rrc=1; fi
	fi
	# --- tar-компоненты (распаковка в /) ---
	_restore_tar() {
		[[ -f "$1" ]] || { log "нет архива $(basename "$1") — пропуск"; return 0; }
		if tar xzf "$1" -C / 2>>"$LOG"; then log "restore: $2"; else log "ОШИБКА restore $2"; rrc=1; fi
	}
	((r_etc))   && _restore_tar "$SRC/etc.tar.gz" "/etc"
	((r_ispc))  && _restore_tar "$SRC/ispconfig.tar.gz" "ISPConfig"
	if ((r_www)); then
		# ISPConfig ставит на корни сайтов chattr +i, tar не может выставить им владельца и время.
		# На время распаковки флаг снимаем и потом возвращаем.
		immut=()
		if command -v lsattr >/dev/null 2>&1; then
			while read -r a d; do [[ "$a" == *i* ]] && immut+=("$d"); done \
				< <(lsattr -d /var/www/clients/client*/web* 2>/dev/null)
		fi
		((${#immut[@]})) && chattr -i "${immut[@]}" 2>>"$LOG"
		_restore_tar "$SRC/www.tar.gz" "/var/www"
		((${#immut[@]})) && chattr +i "${immut[@]}" 2>>"$LOG"
	fi
	((r_vmail)) && _restore_tar "$SRC/vmail.tar.gz" "/var/vmail"
	# --- Перезапуск ключевых служб (best-effort) ---
	if ((r_db || r_etc || r_ispc)); then
		systemctl daemon-reload >>"$LOG" 2>&1 || true
		for v in /etc/php/*/; do [[ -d "$v/fpm" ]] && systemctl restart "php$(basename "$v")-fpm" >>"$LOG" 2>&1 || true; done
		for s in mariadb nginx apache2 postfix dovecot; do
			systemctl cat "$s.service" >/dev/null 2>&1 && { systemctl restart "$s" >>"$LOG" 2>&1 || true; }
		done
	fi
	log "=== restore завершён: $SNAP (rc=$rrc) ==="
	echo "Готово (rc=$rrc). Лог: $LOG"
	exit $rrc
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DEST/$TS"
mkdir -p "$OUT" || { echo "Не удаётся создать $OUT" >&2; exit 1; }
chmod 700 "$OUT" 2>/dev/null || true
rc=0
log "=== backup начат: $TS ==="

# --- MariaDB: по одному дампу на базу ---
# Авторизация — через /root/.my.cnf (создаётся этапом database). Системные БД пропускаем.
if command -v mysqldump >/dev/null 2>&1 && command -v mysql >/dev/null 2>&1; then
	mkdir -p "$OUT/mysql"
	if ! dbs="$(mysql "${MYDEF[@]}" -N -e 'SHOW DATABASES;' 2>>"$LOG")"; then
		log "ОШИБКА: нет доступа к MariaDB (проверьте /root/.my.cnf), базы НЕ сохранены"; rc=1; dbs=""
	fi
	dbs="$(grep -Ev '^(information_schema|performance_schema|sys)$' <<<"$dbs")"
	for db in $dbs; do
		if mysqldump "${MYDEF[@]}" --single-transaction --quick --routines --triggers --events \
		   --databases "$db" 2>>"$LOG" | gzip -c > "$OUT/mysql/${db}.sql.gz"; then
			log "БД: ${db} → mysql/${db}.sql.gz"
		else
			log "ОШИБКА дампа БД ${db}"; rc=1
		fi
	done
else
	log "mysqldump не найден — пропуск БД"
fi

# --- Конфиги: /etc, ISPConfig, crontab root ---
if tar czf "$OUT/etc.tar.gz" -C / etc 2>>"$LOG"; then log "конфиг: /etc → etc.tar.gz"; else log "ОШИБКА архива /etc"; rc=1; fi
if [[ -d /usr/local/ispconfig ]]; then
	if tar czf "$OUT/ispconfig.tar.gz" --exclude='usr/local/ispconfig/server/temp/*' -C / usr/local/ispconfig 2>>"$LOG"; then
		log "конфиг: ISPConfig → ispconfig.tar.gz"
	else log "ОШИБКА архива ISPConfig"; rc=1; fi
fi
crontab -l >"$OUT/root.crontab" 2>/dev/null || true

# --- Опционально: сайты и почта (могут быть большими) ---
# Хватит ли места: без сжатия архив не больше исходника, плюс 1 ГБ запаса. Не хватает —
# пропускаем с ошибкой (придёт уведомление), а не забиваем диск под сайтами и базой.
room_for() {
	local need avail
	need="$(du -sk "$1" 2>/dev/null | awk '{print $1}')"; avail="$(df -Pk "$OUT" | awk 'NR==2{print $4}')"
	[[ -n "$need" && -n "$avail" ]] || return 0
	(( avail > need + 1048576 )) && return 0
	log "ОШИБКА: мало места для $1 ($((need / 1024)) МБ, свободно $((avail / 1024)) МБ) — пропущено"
	return 1
}
if [[ "$INC_WWW" == "y" && -d /var/www ]]; then
	if ! room_for /var/www; then rc=1
	elif tar czf "$OUT/www.tar.gz" -C / var/www 2>>"$LOG"; then log "данные: /var/www → www.tar.gz"; else log "ОШИБКА архива /var/www"; rc=1; fi
fi
if [[ "$INC_MAIL" == "y" && -d /var/vmail ]]; then
	if ! room_for /var/vmail; then rc=1
	elif tar czf "$OUT/vmail.tar.gz" -C / var/vmail 2>>"$LOG"; then log "данные: /var/vmail → vmail.tar.gz"; else log "ОШИБКА архива /var/vmail"; rc=1; fi
fi

# --- Размер снимка + ротация по дням ---
du -sh "$OUT" 2>/dev/null | awk '{print $1}' > "$OUT/.size"
log "размер снимка: $(cat "$OUT/.size" 2>/dev/null || echo '?')"
# Удаляем только каталоги снимков (имя вида 20261105-033000), только после бэкапа без ошибок
# и никогда не трогаем последние KEEP снимков: при сбоях старые копии остаются.
KEEP=3
if (( rc != 0 )); then
	log "ротация пропущена: бэкап с ошибками, старые снимки сохранены"
elif [[ "$RET" =~ ^[0-9]+$ && "$RET" -gt 0 ]]; then
	mapfile -t snaps < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
		-regex '.*/[0-9]{8}-[0-9]{6}' -printf '%f\n' 2>/dev/null | sort)
	n_del=0
	for ((i = 0; i < ${#snaps[@]} - KEEP; i++)); do
		d="$DEST/${snaps[i]}"
		[[ -n "$(find "$d" -maxdepth 0 -mtime +"$RET" 2>/dev/null)" ]] || continue
		rm -rf -- "$d" 2>>"$LOG" && n_del=$((n_del + 1))
	done
	log "ротация: удалено снимков старше ${RET} дн.: ${n_del} (последние ${KEEP} не трогаются)"
fi

# --- Оффсайт-копия (опц.): зеркалирование каталога бэкапов вовне ---
# rsync — по SSH на другой сервер (нужен ключ к удалёнке); rclone — в облако
# (S3/B2/GDrive и пр., предварительно настроить `rclone config`). Защита от потери диска.
case "${BACKUP_REMOTE_TYPE:-none}" in
	rsync)
		if [[ -n "${BACKUP_REMOTE:-}" ]] && command -v rsync >/dev/null 2>&1; then
			if rsync -az --delete ${BACKUP_REMOTE_OPTS:-} \
			     -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${BACKUP_REMOTE_SSHPORT:+-p ${BACKUP_REMOTE_SSHPORT}} ${BACKUP_REMOTE_SSHKEY:+-i ${BACKUP_REMOTE_SSHKEY}}" \
			     "$DEST"/ "$BACKUP_REMOTE" >>"$LOG" 2>&1; then
				log "оффсайт rsync → ${BACKUP_REMOTE}: ок"
			else log "ОШИБКА оффсайт rsync → ${BACKUP_REMOTE} (ключ/доступ/путь?)"; rc=1; fi
		else log "оффсайт rsync пропущен: нет rsync или пустой BACKUP_REMOTE"; fi
		;;
	rclone)
		if [[ -n "${BACKUP_REMOTE:-}" ]] && command -v rclone >/dev/null 2>&1; then
			if rclone sync ${BACKUP_REMOTE_OPTS:-} "$DEST" "$BACKUP_REMOTE" >>"$LOG" 2>&1; then
				log "оффсайт rclone → ${BACKUP_REMOTE}: ок"
			else log "ОШИБКА оффсайт rclone → ${BACKUP_REMOTE} (rclone config?)"; rc=1; fi
		else log "оффсайт rclone пропущен: нет rclone или пустой BACKUP_REMOTE"; fi
		;;
esac

# --- Уведомление о сбое (если настроены уведомления) ---
if (( rc != 0 )) && [[ -x /usr/local/sbin/server-notify.sh ]]; then
	/usr/local/sbin/server-notify.sh -e backup -l crit "Сбой резервного копирования" \
		"Бэкап ${TS} завершился с ошибкой (rc=${rc}). Лог: ${LOG}" || true
fi

log "=== backup завершён: $TS (rc=$rc) ==="
exit $rc
SCRIPT
}

# Создать rclone-remote из ответов мастера (S3 / Backblaze B2 / SFTP) — НЕинтерактивно,
# чтобы пользователю не пришлось вручную гонять `rclone config`. Имя remote = часть
# BACKUP_REMOTE до ':'. Секреты переданы из setup.conf (BACKUP_RCLONE_*). После создания —
# проверка связи (rclone lsd/about). backend=manual → пользователь настраивает rclone сам.
_backup_setup_rclone_remote() {
	[[ "${BACKUP_REMOTE_TYPE:-none}" == "rclone" ]] || return 0
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	command -v rclone >/dev/null 2>&1 || { ui_warn "rclone не установлен — remote не создан."; return 0; }
	local backend="${BACKUP_RCLONE_BACKEND:-manual}"
	local name="${BACKUP_REMOTE:-}"; name="${name%%:*}"
	if [[ "$backend" == "manual" || -z "$name" ]]; then
		ui_info "rclone: используется заранее настроенный remote '${name:-?}' (rclone config — вручную)."
		return 0
	fi

	ui_step "Настройка rclone-remote '${name}' (${backend})"
	local -a a=(config create "$name")
	case "$backend" in
		s3)
			a+=(s3 provider "${BACKUP_RCLONE_S3_PROVIDER:-Other}"
			    access_key_id "${BACKUP_RCLONE_S3_KEY:-}"
			    secret_access_key "${BACKUP_RCLONE_S3_SECRET:-}")
			[[ -n "${BACKUP_RCLONE_S3_REGION:-}"   ]] && a+=(region "$BACKUP_RCLONE_S3_REGION")
			[[ -n "${BACKUP_RCLONE_S3_ENDPOINT:-}" ]] && a+=(endpoint "$BACKUP_RCLONE_S3_ENDPOINT")
			;;
		b2)
			a+=(b2 account "${BACKUP_RCLONE_B2_ACCOUNT:-}" key "${BACKUP_RCLONE_B2_KEY:-}")
			;;
		sftp)
			a+=(sftp host "${BACKUP_RCLONE_SFTP_HOST:-}" user "${BACKUP_RCLONE_SFTP_USER:-}")
			[[ -n "${BACKUP_RCLONE_SFTP_PORT:-}" ]] && a+=(port "$BACKUP_RCLONE_SFTP_PORT")
			if [[ -n "${BACKUP_RCLONE_SFTP_KEY:-}" ]]; then
				a+=(key_file "$BACKUP_RCLONE_SFTP_KEY")
			elif [[ -n "${BACKUP_RCLONE_SFTP_PASS:-}" ]]; then
				a+=(pass "$(rclone obscure "$BACKUP_RCLONE_SFTP_PASS")")
			fi
			;;
		*) ui_warn "rclone: неизвестный backend '${backend}' — пропуск."; return 0 ;;
	esac

	if rclone "${a[@]}" >>"$SETUP_LOG" 2>&1; then
		ui_info "rclone-remote '${name}' записан (~/.config/rclone/rclone.conf)."
	else
		ui_warn "rclone config create '${name}' не прошёл — см. ${SETUP_LOG}."; return 0
	fi
	# Проверка связи (создаём бакет/каталог при необходимости — rclone mkdir идемпотентен)
	rclone mkdir "$BACKUP_REMOTE" >>"$SETUP_LOG" 2>&1 || true
	if rclone lsd "${name}:" >/dev/null 2>&1 || rclone about "${name}:" >/dev/null 2>&1; then
		ui_success "rclone-remote '${name}' (${backend}) создан и доступен — оффсайт-копия активна."
	else
		ui_warn "rclone-remote '${name}' создан, но связь не подтверждена — проверьте ключи/доступ: ${UI_W}rclone lsd ${name}:${UI_NC}"
	fi
	return 0
}

# Краткая строка для финального summary
stage_backup_summary() {
	echo "Backup: ${BACKUP_DIR:-/var/backups/server} (хранить ${BACKUP_RETENTION_DAYS:-7} дн.)"
}

# =============================================================================
# Интерактивное восстановление (--restore / пункт меню). Показывает снимки,
# даёт выбрать снимок + компоненты, грозно подтверждает, зовёт server-backup.sh.
# =============================================================================
run_backup_restore() {
	local script="$BACKUP_SCRIPT" conf="$BACKUP_CONF" dir="/var/backups/server"
	[[ -f "$conf" ]] && dir="$( . "$conf"; echo "${BACKUP_DIR:-/var/backups/server}" )"
	if [[ ! -x "$script" ]]; then
		ui_error "Скрипт бэкапа не найден (${script}). Сначала настройте резервное копирование (этап backup)."
		return 1
	fi
	clear 2>/dev/null || true
	ui_header "Восстановление из резервной копии"

	# Снимки (свежие сверху)
	local snaps=() s
	while IFS= read -r s; do [[ -n "$s" ]] && snaps+=("$s"); done < <(ls -1dt "$dir"/*/ 2>/dev/null)
	if ((${#snaps[@]} == 0)); then
		ui_error "Снимков не найдено в ${dir}. Сначала сделайте бэкап: ${script}"
		return 1
	fi
	local labels=() sn
	for s in "${snaps[@]}"; do
		sn="$(basename "$s")"
		labels+=("${sn}  (${UI_D}$(cat "${s%/}/.size" 2>/dev/null || echo '?')${UI_NC})")
	done
	UI_MENU_ZERO="Отмена"
	ui_menu "Выберите снимок для восстановления" 1 "${labels[@]}"
	((UI_MENU_CHOICE == 0)) && { ui_info "Отменено."; return 0; }
	local snap; snap="$(basename "${snaps[$((UI_MENU_CHOICE - 1))]}")"

	# Что восстановить
	ui_checklist "Что восстановить из ${snap}" "db" \
		db        "Базы данных MariaDB (перезапишет текущие)" \
		etc       "/etc — системные конфиги (ОПАСНО, может изменить сеть/доступ)" \
		ispconfig "/usr/local/ispconfig (конфиг панели)" \
		www       "/var/www — сайты (если есть в снимке)" \
		vmail     "/var/vmail — почта (если есть в снимке)"
	local sel=" $UI_CHECK_RESULT " flags=()
	[[ "$sel" == *" db "* ]]        && flags+=(--db)
	[[ "$sel" == *" etc "* ]]       && flags+=(--etc)
	[[ "$sel" == *" ispconfig "* ]] && flags+=(--ispconfig)
	[[ "$sel" == *" www "* ]]       && flags+=(--www)
	[[ "$sel" == *" vmail "* ]]     && flags+=(--vmail)
	((${#flags[@]})) || { ui_warn "Ничего не выбрано — восстановление отменено."; return 0; }

	echo ""
	ui_warn "ВНИМАНИЕ: восстановление НЕОБРАТИМО перезапишет выбранные данные текущей системы."
	[[ "$sel" == *" etc "* ]] && ui_warn "Восстановление /etc может изменить сетевые/системные настройки — действуйте осознанно."
	if ! ui_confirm "Восстановить снимок ${snap} (${UI_CHECK_RESULT})?" n; then
		ui_info "Отменено."; return 0
	fi

	ui_step "Восстановление снимка ${snap}…"
	if "$script" --restore "$snap" "${flags[@]}" --yes; then
		ui_success "Восстановление завершено. Проверьте сервисы: ${UI_W}$(ls_hint --healthcheck)${UI_NC}"
	else
		ui_warn "Восстановление завершилось с замечаниями — см. ${dir}/backup.log."
	fi
	return 0
}
