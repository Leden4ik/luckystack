#!/bin/bash
# =============================================================================
# lib/rspamd.sh — Этап (опц.): антиспам Rspamd + антивирус ClamAV.
# Rspamd ставится из официального репозитория rspamd.com (свежее, чем в Debian).
# Хранилище Rspamd — Redis (ставится этапом database). Интеграцию с Postfix
# (milter) и DKIM настраивает ISPConfig. ClamAV используется Rspamd как antivirus.
# =============================================================================

_rspamd_add_repo() {
	local codename; codename="$(os_codename)"
	[[ -z "$codename" ]] && { ui_warn "Не определено кодовое имя релиза — откат на пакет Rspamd из Debian."; return 1; }
	ui_step "Подключение официального репозитория Rspamd"
	if [[ -f /etc/apt/sources.list.d/rspamd.list ]]; then
		ui_info "Репозиторий Rspamd уже подключён."; return 0
	fi
	apt_install lsb-release wget gpg ca-certificates
	mkdir -p /etc/apt/keyrings
	# timeout + --batch: иначе `wget | gpg --dearmor` может зависнуть на свежей
	# системе (gpg-agent/dirmngr) или медленной сети без какого-либо ограничения.
	if ! ui_spin "Ключ Rspamd" timeout 90 bash -c \
		"set -o pipefail; wget -qO- --timeout=30 --tries=2 https://rspamd.com/apt-stable/gpg.key | gpg --batch --yes --dearmor > /etc/apt/keyrings/rspamd.gpg && gpg --batch --show-keys /etc/apt/keyrings/rspamd.gpg >/dev/null 2>&1"; then
		rm -f /etc/apt/keyrings/rspamd.gpg
		ui_warn "Не удалось получить ключ Rspamd (таймаут/сеть) — откат на пакет из Debian."
		return 1
	fi
	echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rspamd.gpg] http://rspamd.com/apt-stable/ ${codename} main" \
		>/etc/apt/sources.list.d/rspamd.list
	apt_update
	return 0
}

stage_rspamd() {
	ui_info "Антиспам Rspamd + антивирус ClamAV (хранилище — Redis)"

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} репозиторий rspamd.com + apt install rspamd"
		ui_info "${UI_D}[dry-run]${UI_NC} rspamadm pw → пароль web-UI Rspamd (RSPAMD_PASSWORD)"
		ui_info "${UI_D}[dry-run]${UI_NC} apt install clamav clamav-daemon + freshclam"
		ui_info "${UI_D}[dry-run]${UI_NC} milter/DKIM-интеграцию с Postfix настроит ISPConfig"
		ui_success "Rspamd + ClamAV (имитация) установлены."
		return 0
	fi

	# Предупредим, если Redis выключен — Rspamd сильно завязан на него
	if [[ "${INSTALL_REDIS:-y}" != "y" ]]; then
		ui_warn "Redis отключён, а Rspamd использует его как хранилище — рекомендуется включить Redis."
	fi

	# --- Rspamd ---
	if _rspamd_add_repo; then
		ui_step "Установка Rspamd (офиц. репозиторий)"
	else
		ui_step "Установка Rspamd (пакет Debian)"
	fi
	apt_install rspamd
	sys_run "Автозагрузка Rspamd" systemctl enable --now rspamd

	# B1: пароль на web-UI Rspamd (без него любой по пути /rspamd/ зайдёт в панель)
	_rspamd_set_password

	# История в Redis: лимит строк + сжатие + приватность тем писем (ISPConfig не пишет этот файл)
	_rspamd_history_tuning

	# --- ClamAV (опционально: на малой RAM мастер мог отключить, INSTALL_CLAMAV=n) ---
	if [[ "${INSTALL_CLAMAV:-y}" != "y" ]]; then
		ui_info "ClamAV отключён (мало RAM/swap) — Rspamd работает без антивируса."
		log "rspamd: clamav пропущен (INSTALL_CLAMAV=n)"
	else
		ui_step "Установка ClamAV (антивирус)"
		apt_install clamav clamav-daemon
		# Первичное обновление баз (freshclam): останавливаем демон на время апдейта.
		# timeout: базы ~250 МБ, медленные зеркала «подвешивали» установку навсегда —
		# при превышении 15 мин продолжаем (демон clamav-freshclam доскачает сам).
		systemctl stop clamav-freshclam >>"$SETUP_LOG" 2>&1 || true
		ui_spin "Обновление антивирусных баз (freshclam, до 15 мин)" timeout 900 freshclam || \
			ui_warn "freshclam не успел/не смог сейчас — базы доскачает clamav-freshclam по расписанию."
		sys_run "Запуск clamav-freshclam" systemctl enable --now clamav-freshclam

		# clamav-daemon стартуем ТОЛЬКО если базы реально скачаны — иначе он падает
		# («No supported database files found»). Если баз нет — включаем, но не стартуем
		# (поднимется на следующем --update/перезагрузке, когда freshclam докачает).
		systemctl enable clamav-daemon >>"$SETUP_LOG" 2>&1 || true
		if compgen -G "/var/lib/clamav/main.c?d" >/dev/null && compgen -G "/var/lib/clamav/daily.c?d" >/dev/null; then
			if sys_run "Запуск clamav-daemon" systemctl restart clamav-daemon; then :; else
				ui_warn "clamav-daemon не запустился. Частые причины: мало RAM (clamd грузит сигнатуры, нужно ~1–2 ГБ) или базы повреждены."
				ui_info "Диагностика: ${UI_W}journalctl -u clamav-daemon${UI_NC} · ${UI_W}free -h${UI_NC}. Антиспам rspamd работает и без clamd."
			fi
		else
			ui_warn "Антивирусные базы ещё не докачаны — clamav-daemon пока не запускаю (иначе упадёт). Стартует после freshclam."
		fi
	fi

	ui_success "Rspamd установлен$([[ "${INSTALL_CLAMAV:-y}" == "y" ]] && echo " + ClamAV") (milter/DKIM настроит ISPConfig)."
	log "rspamd: установлен (clamav=${INSTALL_CLAMAV:-y}), ожидает интеграции в ISPConfig"
	return 0
}

# B1: задать пароль на просмотр/управление web-UI Rspamd (controller).
# Генерируем пароль, хэшируем через rspamadm pw, пишем local.d/worker-controller.inc
# (rspamd мерджит local.d/). Пароль в открытом виде сохраняем в setup.conf.
_rspamd_set_password() {
	ui_step "Пароль на web-UI Rspamd"
	local pw; pw="$(config_get_or_gen_password RSPAMD_PASSWORD 20)"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} rspamadm pw → хэш в /etc/rspamd/local.d/worker-controller.inc"
		return 0
	fi
	command -v rspamadm >/dev/null 2>&1 || { ui_warn "rspamadm не найден — пароль Rspamd не задан."; return 0; }
	local hash; hash="$(rspamadm pw -p "$pw" 2>/dev/null)"
	if [[ -z "$hash" ]]; then ui_warn "rspamadm pw не вернул хэш — пропуск."; return 0; fi
	mkdir -p /etc/rspamd/local.d
	cat >/etc/rspamd/local.d/worker-controller.inc <<RSP
# luckystack: web-UI Rspamd — слушать только локально (наружу через nginx /rspamd/)
bind_socket = "localhost:11334";
password = "${hash}";
enable_password = "${hash}";
secure_ip = "127.0.0.1";
RSP
	sys_run "Перезапуск Rspamd" systemctl restart rspamd
	ui_success "Пароль Rspamd установлен (открытый — в setup.conf: RSPAMD_PASSWORD)."
}

# История rspamd в Redis: размер (nrows), сжатие, приватность тем писем (хэшируются).
# ISPConfig этот файл НЕ создаёт — наш тюнинг безопасен (Perfect Server делает то же вручную).
_rspamd_history_tuning() {
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	mkdir -p /etc/rspamd/local.d
	cat >/etc/rspamd/local.d/history_redis.conf <<'HIST'
# luckystack: история rspamd в Redis
nrows = 2500;
compress = true;
subject_privacy = true;
HIST
	systemctl reload rspamd >>"$SETUP_LOG" 2>&1 || systemctl restart rspamd >>"$SETUP_LOG" 2>&1 || true
	ui_success "Rspamd: история в Redis (nrows=2500, compress, subject_privacy)."
}

stage_rspamd_summary() { echo "Antispam: Rspamd + ClamAV (интеграция через ISPConfig)"; }
