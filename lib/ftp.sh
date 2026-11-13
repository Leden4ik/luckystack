#!/bin/bash
# =============================================================================
# lib/ftp.sh — Этап (опц.): PureFTPd + дисковые квоты.
# PureFTPd ставится и переводится в TLS; виртуальных пользователей создаёт
# ISPConfig (configure_ftp=y). Квоты в /etc/fstab — то, что ISPConfig сам НЕ
# делает, поэтому настраиваем здесь (usrquota,grpquota на корень).
# =============================================================================

stage_ftp() {
	ui_info "FTP-сервер PureFTPd (TLS) + дисковые квоты"

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt install pure-ftpd-common pure-ftpd-mysql quota quotatool"
		ui_info "${UI_D}[dry-run]${UI_NC} TLS=1, CreateHomeDir, DontResolve; пользователей создаёт ISPConfig"
		ui_info "${UI_D}[dry-run]${UI_NC} fstab: journaled usrjquota/grpjquota (jqfmt=vfsv0) на / + quotacheck/quotaon"
		ui_success "PureFTPd + квоты (имитация) настроены."
		return 0
	fi

	# --- PureFTPd ---
	ui_step "Установка PureFTPd"
	apt_install pure-ftpd-common pure-ftpd-mysql

	# Базовые параметры (ISPConfig дополнит): TLS, создание домашних каталогов
	mkdir -p /etc/pure-ftpd/conf
	_ftp_tls_value >/etc/pure-ftpd/conf/TLS
	echo "yes" >/etc/pure-ftpd/conf/CreateHomeDir
	echo "1"   >/etc/pure-ftpd/conf/DontResolve

	# Самоподписанный сертификат для FTPS (ISPConfig может заменить своим).
	# ВАЖНО: openssl с одинаковыми -keyout/-out оставляет файл БЕЗ сертификата
	# (второй -out затирает ключ/наоборот) — генерируем в отдельные файлы и склеиваем.
	if [[ ! -f /etc/ssl/private/pure-ftpd.pem ]]; then
		mkdir -p /etc/ssl/private
		ui_spin "Генерация TLS-сертификата для PureFTPd" bash -c \
			"openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
			 -keyout /etc/ssl/private/pure-ftpd.key -out /etc/ssl/private/pure-ftpd.crt \
			 -subj '/CN=${SERVER_FQDN:-localhost}' && \
			 cat /etc/ssl/private/pure-ftpd.key /etc/ssl/private/pure-ftpd.crt > /etc/ssl/private/pure-ftpd.pem && \
			 rm -f /etc/ssl/private/pure-ftpd.key /etc/ssl/private/pure-ftpd.crt" \
			|| ui_warn "Не удалось создать сертификат FTPS."
		chmod 600 /etc/ssl/private/pure-ftpd.pem 2>/dev/null || true
	fi
	sys_run "Перезапуск PureFTPd" systemctl restart pure-ftpd-mysql

	# --- Дисковые квоты ---
	_ftp_setup_quota

	ui_success "PureFTPd установлен (пользователей создаст ISPConfig); квоты настроены."
	log "ftp: pure-ftpd-mysql + quota настроены"
	return 0
}

# Режим TLS PureFTPd из FTP_TLS_REQUIRED (по умолчанию y):
#   2 — вход только по FTPS (пароль не ходит открытым текстом), 1 — TLS по желанию клиента.
# FileZilla и WinSCP по умолчанию сами делают «explicit TLS», так что для них ничего не меняется.
_ftp_tls_value() { [[ "${FTP_TLS_REQUIRED:-y}" == "n" ]] && echo 1 || echo 2; }

_ftp_tls_mode() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	dpkg -l pure-ftpd-mysql 2>/dev/null | grep -q '^ii' || return 0
	local want f=/etc/pure-ftpd/conf/TLS
	want="$(_ftp_tls_value)"
	[[ "$(tr -d '[:space:]' <"$f" 2>/dev/null)" == "$want" ]] && return 0
	# без сертификата PureFTPd с TLS=2 не примет ни одного входа
	if [[ "$want" == "2" && ! -s /etc/ssl/private/pure-ftpd.pem ]]; then
		ui_warn "PureFTPd: нет /etc/ssl/private/pure-ftpd.pem — FTP только по TLS не включаю."
		return 0
	fi
	echo "$want" >"$f"
	systemctl restart pure-ftpd-mysql >>"$SETUP_LOG" 2>&1 || ui_warn "pure-ftpd-mysql не перезапустился — проверьте: systemctl status pure-ftpd-mysql"
	if [[ "$want" == "2" ]]; then
		ui_success "PureFTPd: вход только по FTPS (TLS=2). В клиенте: «FTP с явным TLS» (explicit FTP over TLS)."
	else
		ui_success "PureFTPd: TLS по желанию клиента (TLS=1)."
	fi
}

# Включить journaled-квоты (usrjquota/grpjquota, jqfmt=vfsv0) на корневой ФС.
# Journaled-вариант (как в Perfect Server) не требует quotacheck при каждой загрузке
# и совместим с ext3/ext4. Идемпотентно, с гейтами: контейнеры/не-ext пропускаем,
# fstab бэкапим. ISPConfig использует эти квоты для лимитов диска веб-сайтов.
_ftp_setup_quota() {
	ui_step "Настройка дисковых квот (journaled quota)"

	# Гейт: пользователь мог отключить квоты (SETUP_QUOTA=n)
	if [[ "${SETUP_QUOTA:-y}" != "y" ]]; then
		ui_info "Дисковые квоты отключены (SETUP_QUOTA=n) — пропуск."
		return 0
	fi

	# Контейнеры (LXC/OpenVZ/Docker): квоты на корень обычно недоступны/опасны — пропускаем
	if systemd-detect-virt --container --quiet 2>/dev/null; then
		ui_warn "Обнаружен контейнер ($(systemd-detect-virt 2>/dev/null)) — дисковые квоты на / не поддерживаются, пропуск."
		ui_info "Лимиты диска веб-сайтов в ISPConfig работать не будут (ограничение контейнера, не ошибка)."
		return 0
	fi

	# Тип ФС корня: journaled usrjquota работает на ext3/ext4. XFS/btrfs/zfs — иной механизм.
	local rootfs; rootfs="$(findmnt -no FSTYPE / 2>/dev/null)"
	case "$rootfs" in
		ext4|ext3) : ;;
		"")  ui_warn "Не удалось определить тип ФС корня — квоты пропущены (fstab не трогаю)."; return 0 ;;
		*)   ui_warn "Корень на ${rootfs} (не ext3/ext4) — journaled-квоты неприменимы, пропуск."
		     ui_info "Для ${rootfs} лимиты диска настраиваются средствами самой ФС, вне этого установщика."
		     return 0 ;;
	esac

	apt_install quota quotatool
	local jopts="usrjquota=quota.user,grpjquota=quota.group,jqfmt=vfsv0"

	# Уже включены? (любой из journaled-маркеров)
	if grep -E '^\S+\s+/\s+\S+\s+\S*usrjquota' /etc/fstab >/dev/null 2>&1; then
		ui_info "Journaled-квоты на / уже прописаны в /etc/fstab."
	else
		cp -a /etc/fstab /etc/fstab.luckystack.bak
		# Дополняем опции (поле 4) строки монтирования '/'. Старые usrquota/grpquota
		# (если есть) убираем, чтобы не конфликтовали с journaled-вариантом.
		awk -v jq="$jopts" 'BEGIN{OFS="\t"}
			/^[[:space:]]*#/ {print; next}
			{
				if ($2=="/" && $4 !~ /usrjquota/) {
					gsub(/,?(usrquota|grpquota)/, "", $4)
					sub(/^,/, "", $4); if ($4=="") $4="defaults"
					$4=$4","jq
				}
				print
			}' /etc/fstab >/etc/fstab.new && mv_keep /etc/fstab.new /etc/fstab

		# Проверка целостности: строка корня должна остаться. Если awk что-то сломал — откат.
		if ! grep -E '^\S+\s+/\s+\S+' /etc/fstab >/dev/null 2>&1; then
			cp -a /etc/fstab.luckystack.bak /etc/fstab
			ui_warn "Правка /etc/fstab дала некорректный результат — откат из бэкапа, квоты не включены."
			return 0
		fi
		ui_success "В /etc/fstab добавлены journaled-квоты на / (бэкап: /etc/fstab.luckystack.bak)."
		mount -o remount / >>"$SETUP_LOG" 2>&1 || ui_warn "Не удалось перемонтировать / — квоты включатся после перезагрузки."
	fi

	# Инициализация и включение. Файлы quota.user/quota.group создаёт quotacheck.
	ui_spin "quotacheck (инициализация баз квот)" quotacheck -avugm || \
		ui_warn "quotacheck сообщил о проблемах (для journaled-квот может потребоваться перезагрузка)."
	quotaon -avug >>"$SETUP_LOG" 2>&1 || ui_warn "quotaon не запустился сейчас (включится после перезагрузки)."
}

stage_ftp_summary() { echo "FTP: PureFTPd (TLS) + дисковые квоты"; }
