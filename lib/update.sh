#!/bin/bash
# =============================================================================
# lib/update.sh — Предохранитель занятого сервера + режим обновления/патчей.
#
#   Установщик рассчитан на ЧИСТЫЙ сервер: core-этапы (database, webserver/nginx,
#   ispconfig, preflight) перезаписывают/сбрасывают существующее. Чтобы случайно
#   не снести сервер, собранный вручную (Perfect Server гайд), здесь:
#     • _detect_existing_install — распознаёт «обжитой» сервер;
#     • _existing_install_guard  — при полном прогоне предлагает выбор;
#     • run_update_mode (--update) — БЕЗОПАСНОЕ сопровождение: обновить пакеты +
#       переприменить наши АДДИТИВНЫЕ патчи, НЕ трогая ядро.
# =============================================================================

# Глобал с человекочитаемой причиной срабатывания (для сообщения).
EXISTING_INSTALL_REASON=""

# Похоже ли, что сервер уже настроен (не нашим установщиком)? rc=0 — да.
_detect_existing_install() {
	EXISTING_INSTALL_REASON=""
	local signs=()
	[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] && signs+=("ISPConfig установлен")
	[[ -d /var/www/clients ]] && signs+=("есть сайты ISPConfig (/var/www/clients)")
	# собственная сборка nginx из исходников (наш или ручной) + рабочий веб-сервер
	if systemctl is-active nginx >/dev/null 2>&1 || systemctl is-active apache2 >/dev/null 2>&1; then
		local _php=0; for _d in /etc/php/*/fpm; do [[ -d "$_d" ]] && _php=1; done
		((_php)) && systemctl is-active mariadb >/dev/null 2>&1 && signs+=("веб-сервер + PHP-FPM + MariaDB уже работают")
	fi
	if ((${#signs[@]})); then
		EXISTING_INSTALL_REASON="$(IFS='; '; echo "${signs[*]}")"
		return 0
	fi
	return 1
}

# Предохранитель: показывается при ПОЛНОЙ установке на уже настроенном сервере.
# rc=0 — пользователь подтвердил перезапись (продолжаем полный прогон).
# Иначе — внутри уходим в update-режим / подсказку / выход (exit).
_existing_install_guard() {
	if [[ ! -t 0 ]]; then
		ui_error "Обнаружен уже настроенный сервер (${EXISTING_INSTALL_REASON})."
		ui_error "Полная установка НЕ запущена (неинтерактивно) — она перезапишет MariaDB-пароль, сборку nginx, ISPConfig."
		ui_info  "Безопасно: ${UI_W}$(ls_hint --update)${UI_NC} (обновление/патчи) или ${UI_W}$(ls_hint --only "<этап>")${UI_NC}. Перезапись: ${UI_W}$(ls_hint --reconfigure)${UI_NC} + подтверждение в tty."
		exit 2
	fi
	clear 2>/dev/null || true
	ui_header "Обнаружен уже настроенный сервер"
	ui_box_top "Что найдено"
	ui_box_line "  ${UI_Y}${EXISTING_INSTALL_REASON}${UI_NC}"
	ui_box_bottom
	ui_warn "Полная установка ПЕРЕЗАПИШЕТ: пароль root MariaDB, сборку и конфиг nginx, переустановит ISPConfig, конфиги служб."
	echo ""
	UI_MENU_ZERO="Выход"; [[ -n "${LS_MENU_CHILD:-}" ]] && UI_MENU_ZERO="Назад в меню"
	ui_menu "Что сделать?" 1 \
		"Режим обновления / патчей — безопасно, НЕ трогает ядро (рекомендуется)" \
		"Применить один этап (--only) — показать список и выйти" \
		"Полная установка ПОВЕРХ — ОПАСНО, перезапишет существующее"
	case "$UI_MENU_CHOICE" in
		0) ui_info "Выход."; exit 0 ;;
		1) run_update_mode; exit $? ;;
		2)
			ui_info "Доступные этапы: ${UI_W}${STAGE_KEYS[*]}${UI_NC}"
			ui_info "Применить один: ${UI_W}$(ls_hint --only "<этап>")${UI_NC} (переиспользует setup.conf, мастер не запускается)."
			ui_info "Предпросмотр без изменений: добавьте ${UI_W}--dry-run${UI_NC}."
			exit 0 ;;
		3)
			ui_warn "ОПАСНО: полная установка поверх существующего сервера может его сломать."
			local a; read -rp "$(echo -e "${UI_W}Введите ${UI_R}OVERWRITE${UI_W} для подтверждения полной перезаписи:${UI_NC} ")" a
			if [[ "$a" == "OVERWRITE" ]]; then return 0; fi
			ui_info "Не подтверждено — отмена."; exit 0 ;;
	esac
	return 1
}

# =============================================================================
# Режим обновления (--update): безопасное сопровождение существующего сервера.
# Обновляет пакеты и ПЕРЕПРИМЕНЯЕТ только аддитивные патчи (каждый сам пропустит
# себя, если не применим). НЕ запускает: preflight, database, webserver/nginx,
# php(base), ispconfig(reinstall), mail/dns/ftp(base), firewall/SSH-харденинг.
# =============================================================================
# Два обновления одновременно ломают друг друга. Панель смотрит этот же файл.
_update_lock() {
	local f=/run/luckystack-update.pid p
	p="$(cat "$f" 2>/dev/null)"
	if [[ -n "$p" && "$p" != "$$" ]] && grep -qa 'server-setup' "/proc/${p}/cmdline" 2>/dev/null; then
		ui_error "Обновление уже идёт (PID ${p}). Дождитесь окончания."
		return 1
	fi
	echo "$$" >"$f"
}

# --rollback nginx|roundcube: вернуть прошлую версию. Повтор отменяет откат.
run_rollback_mode() {
	require_root
	config_load || true
	_update_lock || return 1
	case "${ROLLBACK_TARGET:-}" in
		nginx)     _nginx_rollback ;;
		roundcube) _rcu_rollback ;;
		luckystack) ls_rollback_code ;;
		*) ui_error "Укажите, что откатить: $(ls_hint --rollback) nginx, roundcube или luckystack"; return 2 ;;
	esac
}

run_update_mode() {
	require_root
	check_os
	config_load || true
	apt_lock_wait_conf
	clear 2>/dev/null || true
	ui_header "Режим обновления / патчей"
	ui_info "Обновляет пакеты и переприменяет наши аддитивные улучшения (безопасно, авто)."
	ui_info "Ядро — ${UI_BOLD}nginx (пересборка) и ISPConfig (офиц. апдейтер)${UI_NC} — обновляется ТОЛЬКО по явному запросу."
	ui_info "Пароль root MariaDB и базовые конфиги служб НЕ трогаются."

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt update/upgrade + аддитивные патчи (security-sub, conf-custom, tuning, mail*, hostcert, rcplugins, backup)"
		ui_info "${UI_D}[dry-run]${UI_NC} опц.: пересборка nginx до последней версии + ISPConfig official update"
		ui_success "Режим обновления (имитация) — изменений не вносится."
		return 0
	fi

	_update_lock || return 1
	_log_scrub_secrets

	# --- Выбор пунктов обновления (интерактивно). Не-tty → все аддитивные, ядро НЕ трогаем. ---
	# В adopt-режиме (чужой/ручной сервер) показываем ТОЛЬКО server-agnostic аддоны;
	# ядро и пункты, мутирующие шаблоны ISPConfig (confcustom/certs/rcplugins/nginx/ispconfig),
	# скрыты — они рассчитаны на нашу сборку и могут сломать ручной сервер.
	local sel
	# UPDATE_ITEMS="pkgs security … nginx ispconfig" — набор без вопросов (для cron и проверок)
	if [[ -n "${UPDATE_ITEMS:-}" && "${UPD_ADOPTED:-0}" != "1" ]]; then
		sel=" ${UPDATE_ITEMS//,/ } "
		ui_info "Пункты обновления из UPDATE_ITEMS:${sel% }"
	elif [[ "${UPD_ADOPTED:-0}" == "1" ]]; then
		if [[ -t 0 ]]; then
			ui_checklist "Что применить (безопасные аддоны · adopt-режим)" \
				"pkgs,security,tuning,mail,backup,notify" \
				pkgs     "Системные пакеты (apt upgrade)" \
				security "Патчи безопасности (sysctl, fail2ban-jail'ы, автообновления, world-writable)" \
				tuning   "Авто-тюнинг (MariaDB/PHP/Postfix)" \
				mail     "Почта: доставляемость + per-domain TLS (maildeliver, mailsni)" \
				backup   "Резервное копирование (+ оффсайт)" \
				notify   "Уведомления (email/Telegram) + ежедневный монитор"
			sel=" $UI_CHECK_RESULT "
		else
			sel=" pkgs security tuning mail backup notify "
		fi
	elif [[ -t 0 ]]; then
		ui_checklist "Что обновить / переприменить (пробел — отметить, Enter — далее)" \
			"pkgs,security,tuning,mail,certs,rcplugins,backup,notify" \
			pkgs       "Системные пакеты (apt upgrade)" \
			security   "Патчи безопасности (sysctl, fail2ban, автообновления, world-writable)" \
			confcustom "Усиление шаблонов ISPConfig (conf-custom)" \
			tuning     "Авто-тюнинг (MariaDB/PHP/Postfix)" \
			mail       "Почта: доставляемость + per-domain TLS (maildeliver, mailsni)" \
			certs      "LE-сертификат хоста (hostcert)" \
			rcplugins  "Плагины ISPConfig для Roundcube" \
			backup     "Резервное копирование" \
			notify     "Уведомления (email/Telegram) + ежедневный монитор" \
			nginx      "ПЕРЕСБОРКА nginx до последней версии (ядро)" \
			ispconfig  "Обновление ISPConfig офиц. апдейтером (ядро)"
		sel=" $UI_CHECK_RESULT "
	else
		sel=" pkgs security confcustom tuning mail certs rcplugins backup notify "
	fi

	# 1) Системные пакеты
	if [[ "$sel" == *" pkgs "* ]] && ui_confirm "Обновить системные пакеты (apt update && apt upgrade)?" y; then
		apt_update
		sys_run "apt upgrade" apt-get -y -o Dpkg::Options::=--force-confold upgrade || \
			ui_warn "apt upgrade завершился с замечаниями — см. ${SETUP_LOG}."
		sys_run "apt autoremove" apt-get -y autoremove || true
	fi

	# 1.5) ЯДРО — до наших патчей. Апдейтер ISPConfig перезаписывает меню (module.conf.php), формы,
	# шаблоны панели, ids.whitelist, vhost панели/apps и при «Reconfigure Services» — dovecot.conf
	# (include sni.conf) и конфиги служб. Раньше он шёл последним и затирал только что наложенные
	# патчи до следующего --update. Теперь: ядро → пересборка conf-custom → все патчи поверх.
	UPD_FAILED=()
	local _ispc_updated=0
	if [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] && declare -F _ispconfig_confcustom_record >/dev/null; then
		_ispconfig_confcustom_record   # с какого стандартного шаблона сделаны наши копии (до обновления)
	fi
	if [[ "$sel" == *" ispconfig "* ]] && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
		# патчи накладываем и после неудачной попытки: апдейтер мог успеть их затереть
		_ispc_updated=1
		( _update_ispconfig ) || UPD_FAILED+=("Обновление ISPConfig")
		declare -F config_load >/dev/null && { config_load >/dev/null 2>&1 || true; }
	fi
	if [[ "$sel" == *" nginx "* ]] && declare -F stage_nginx >/dev/null && command -v nginx >/dev/null 2>&1; then
		[[ -f "$CONFIG_FILE" ]] || ui_warn "setup.conf отсутствует — профиль сборки nginx возьмётся по умолчанию (recommended)."
		[[ -f /etc/nginx/nginx.conf ]] && cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.pre-update.bak" 2>/dev/null || true
		# UPDATE_ITEMS — запуск без вопросов, там ветка берётся из setup.conf
		[[ -t 0 && -z "${UPDATE_ITEMS:-}" ]] && _nginx_ask_openssl_branch
		_upd_run "Пересборка nginx (последняя версия)" stage_nginx
	fi
	if [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] && declare -F _ispconfig_confcustom_refresh >/dev/null; then
		_upd_run "conf-custom: сверка с шаблонами ISPConfig" _ispconfig_confcustom_refresh
	fi
	if ((_ispc_updated)); then
		# всё, что апдейтер мог перезаписать, накладываем заново, даже если не отмечено
		local _s
		for _s in security confcustom mail certs rcplugins; do
			[[ "$sel" == *" ${_s} "* ]] || sel+="${_s} "
		done
		ui_info "После обновления ISPConfig заново применяются: безопасность, шаблоны, почта, сертификат хоста, плагины Roundcube."
	fi

	# 2) Аддитивные патчи безопасности (без firewall; SSH — только безопасные параметры, пароль не трогаем)
	if [[ "$sel" == *" security "* ]]; then
		declare -F _security_auto_updates     >/dev/null && _upd_run "Автообновления безопасности" _security_auto_updates
		declare -F apply_ssh_safe >/dev/null && _upd_run "SSH: безопасные настройки (вход по паролю не трогаю)" apply_ssh_safe
		declare -F _security_service_hardening >/dev/null && _upd_run "Ограничения служб systemd (если SEC_SERVICE_HARDEN=y)" _security_service_hardening
		declare -F _nginx_tight_timeouts >/dev/null && [[ "${WEBSERVER:-nginx}" == "nginx" ]] && _upd_run "nginx: таймауты клиентов" _nginx_tight_timeouts
		declare -F _security_journald >/dev/null && _upd_run "Предел журнала systemd (${JOURNAL_MAX:-500M})" _security_journald
		declare -F _security_rkhunter_apt >/dev/null && _upd_run "rkhunter: база после каждого apt" _security_rkhunter_apt
		declare -F _security_aide >/dev/null && _upd_run "AIDE (если SEC_AIDE=y)" _security_aide
		declare -F _security_sysctl_hardening >/dev/null && _upd_run "sysctl-харденинг"             _security_sysctl_hardening
		declare -F _security_fail2ban_jails   >/dev/null && _upd_run "fail2ban jail'ы стека"        _security_fail2ban_jails
		declare -F _security_fix_stack_perms  >/dev/null && _upd_run "Права конфигов стека (без записи для всех)" _security_fix_stack_perms
		declare -F _tz_php_sync >/dev/null && _upd_run "Часовой пояс PHP = пояс системы" _tz_php_sync
		declare -F _php_security_ini >/dev/null && _upd_run "Безопасные настройки PHP (сессии, OPcache)" _php_security_ini
		declare -F _php_drop_stray >/dev/null && _upd_run "Убрать лишнюю версию PHP, притянутую зависимостями" _php_drop_stray
		declare -F _rcu_update_mode >/dev/null && _upd_run "Roundcube: версия разработчиков (обновление / переезд с пакета Debian)" _rcu_update_mode
		declare -F _rcu_fix_smtp >/dev/null && _upd_run "Roundcube: отправка писем через STARTTLS (587)" _rcu_fix_smtp
		declare -F _rc_fix_plugin_perms >/dev/null && _upd_run "Roundcube: плагины ISPConfig (права конфигов, адрес API)" _rc_fix_plugin_perms
		declare -F _webmail_nginx_deny >/dev/null && _upd_run "Roundcube: закрыть служебные каталоги (logs, SQL, config)" _webmail_nginx_deny
		declare -F _mail_auth_tls_only >/dev/null && _upd_run "Почта: пароль только поверх TLS (Postfix + Dovecot)" _mail_auth_tls_only
		declare -F _ftp_tls_mode >/dev/null && _upd_run "FTP: вход только по TLS" _ftp_tls_mode
		declare -F _nginx_drop_legacy_headers >/dev/null && [[ "${WEBSERVER:-nginx}" == "nginx" ]] \
			&& _upd_run "Убрать устаревшие заголовки X-XSS-Protection / Expect-CT" _nginx_drop_legacy_headers
		declare -F _security_world_writable   >/dev/null && _upd_run "Аудит world-writable"         _security_world_writable
		# CrowdSec: детект почтового брута (postfix+dovecot + acquisition mail.log) — для уже стоящих
		# серверов, где CrowdSec поднят без mail-движка. Идемпотентно, гейт по наличию cscli+почты.
		declare -F _crowdsec_enable_mail >/dev/null && command -v cscli >/dev/null 2>&1 \
			&& _upd_run "CrowdSec: детект почтового брута (postfix/dovecot)" _crowdsec_enable_mail
		# named -4 (IPv4-only исходящие), если на сервере нет IPv6 — гасит «address not available» в логе.
		declare -F _dns_named_ipv4_only >/dev/null && [[ -f /etc/default/named ]] \
			&& _upd_run "named: IPv4-only при отсутствии IPv6" _dns_named_ipv4_only
		# CrowdSec: убрать пакетный setup.nginx.yaml (читает анонимизир. лог → баны .0; есть наш crowdsec.log)
		declare -F _crowdsec_drop_anon_acquis >/dev/null && [[ -f /etc/crowdsec/acquis.d/setup.nginx.yaml ]] \
			&& _upd_run "CrowdSec: убрать анонимизир. nginx-acquis (.0)" _crowdsec_drop_anon_acquis
		# CAPI: community blocklist — страховка регистрации (если ещё не зарегистрирован)
		declare -F _crowdsec_capi_register >/dev/null && command -v cscli >/dev/null 2>&1 \
			&& ! cscli capi status >/dev/null 2>&1 \
			&& _upd_run "CrowdSec: регистрация CAPI (community blocklist)" _crowdsec_capi_register
		# Еженедельное авто-обновление правил hub CrowdSec (ставим механизм; сам апгрейд — по cron)
		declare -F _crowdsec_hub_autoupdate >/dev/null && command -v cscli >/dev/null 2>&1 \
			&& _upd_run "CrowdSec: авто-обновление правил hub (cron)" _crowdsec_hub_autoupdate
		# Эскалация bantime рецидивистам (duration_expr в profiles.yaml; идемпотентно)
		declare -F _crowdsec_profile_escalation >/dev/null && command -v cscli >/dev/null 2>&1 \
			&& _upd_run "CrowdSec: эскалация bantime рецидивистам" _crowdsec_profile_escalation
		# Жёсткие IP-ограничения в before.rules — переживают ISPConfig-firewall (если он включён).
		# Берёт IP из setup.conf + текущий SSH-IP (анти-локаут). Только при наличии ufw.
		declare -F _ufw_ensure_enabled >/dev/null && _upd_run "Фаервол: ufw должен быть включён" _ufw_ensure_enabled
		declare -F _security_ufw_restrict_persist >/dev/null && command -v ufw >/dev/null 2>&1 \
			&& _upd_run "Жёсткие IP-ограничения (переживают ISPConfig-firewall)" _security_ufw_restrict_persist
	fi

	# 3) Кастомные шаблоны ISPConfig
	if [[ "$sel" == *" confcustom "* ]] && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] \
	   && declare -F _ispconfig_apply_conf_custom >/dev/null; then
		HARDEN_CONF_CUSTOM=y _upd_run "Кастомные шаблоны ISPConfig" _ispconfig_apply_conf_custom
	fi
	# ВАЖНО: блоки 3.1–3.4 МУТИРУЮТ шаблоны/БД ISPConfig (vhost панели, server_php,
	# server.config). На adopt-сервере (собран не нами) их трогать НЕЛЬЗЯ — наши
	# конвенции могут разойтись с ручной сборкой/3.3dev. Поэтому весь блок — только
	# на «нашем» сервере (UPD_ADOPTED!=1).
	if [[ "${UPD_ADOPTED:-0}" != "1" ]]; then
		# 3.0) ГАРАНТИЯ PHP панели: если phpX.Y-fpm версии, на которой ISPConfig держит панель
		#      (читаем из её vhost), не установлен — доустанавливаем FPM+модули. Self-heal для
		#      серверов, где панель отдаёт 502 (нативная версия не была поставлена; sury/Debian 13).
		if declare -F _ispconfig_ensure_panel_php >/dev/null \
		   && [[ -f /etc/nginx/sites-available/ispconfig.vhost ]]; then
			_upd_run "PHP панели ISPConfig (FPM нативной версии)" _ispconfig_ensure_panel_php
		fi
		# 3.1) Модернизация vhost панели/apps (http2 on; + опц. HTTP/3). Переприменяем
		#      ВСЕГДА — ISPConfig мог перегенерить vhost'ы и вернуть deprecated «listen … http2».
		if [[ "${WEBSERVER:-nginx}" == "nginx" ]] && declare -F _ispconfig_modernize_panel_vhosts >/dev/null \
		   && [[ -f /etc/nginx/sites-available/ispconfig.vhost || -f /etc/nginx/sites-available/apps.vhost ]]; then
			_upd_run "Модернизация vhost панели/apps (http2/http3)" _ispconfig_modernize_panel_vhosts
		fi
		# 3.2) Регистрация версий PHP в ISPConfig (вдруг доустановили новую версию PHP)
		if [[ "${ISPC_REGISTER_PHP:-y}" == "y" ]] && declare -F _ispconfig_register_php_versions >/dev/null \
		   && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Регистрация версий PHP в ISPConfig" _ispconfig_register_php_versions
		fi
		# 3.2.1) Переналить расширение firewall ISPConfig (обновление ISPConfig затирает правки UI формы)
		if declare -F _ispconfig_deploy_firewall_ext >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Расширение firewall ISPConfig (IP-ограничения портов)" _ispconfig_deploy_firewall_ext
		fi
		# 3.2.2) Переналить заморозку vhost (галочка «Не обновлять vhost» + плагин)
		if declare -F _ispconfig_deploy_vhost_freeze >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Заморозка vhost (галочка «Не обновлять vhost»)" _ispconfig_deploy_vhost_freeze
		fi
		# 3.2.3) Переналить тёмную тему панели (тумблер; main.tpl.htm затирается обновлением ISPConfig)
		if declare -F _ispconfig_deploy_theme_dark >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Тёмная тема панели (тумблер)" _ispconfig_deploy_theme_dark
		fi
		# 3.2.4) Переналить панель Fail2ban (страница/меню затираются обновлением ISPConfig; cron/таблицы — идемпотентно)
		if declare -F _ispconfig_deploy_fail2ban_panel >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Панель Fail2ban (баны/разбан + статус)" _ispconfig_deploy_fail2ban_panel
		fi
		# 3.2.5) Переналить панель «Бэкап / Восстановление» (страница/меню затираются обновлением ISPConfig)
		if declare -F _ispconfig_deploy_backup_panel >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Панель Бэкап/Восстановление (снимки + restore)" _ispconfig_deploy_backup_panel
		fi
		# 3.2.6) Переналить панель CrowdSec (страница/меню затираются обновлением ISPConfig; гейт по cscli)
		if declare -F _ispconfig_deploy_crowdsec_panel >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Панель CrowdSec (активные баны + снятие)" _ispconfig_deploy_crowdsec_panel
		fi
		# 3.2.7) Real-IP лог CrowdSec в vhost-шаблон (единый crowdsec.log; сток затирается обновлением)
		if declare -F _ispconfig_crowdsec_vhost_log >/dev/null && command -v cscli >/dev/null 2>&1; then
			_upd_run "CrowdSec: crowdsec.log в vhost-шаблон" _ispconfig_crowdsec_vhost_log
		fi
		# 3.2.7.1) Перевести существующие сайты на единый /var/log/nginx/crowdsec.log (без resync)
		if declare -F _ispconfig_crowdsec_shared_migrate >/dev/null && command -v cscli >/dev/null 2>&1; then
			_upd_run "CrowdSec: сайты → единый crowdsec.log" _ispconfig_crowdsec_shared_migrate
		fi
		# 3.2.8) Composer глобально + jailkit-секции (composer/php/node) для SSH-деплоя и jail'ов
		declare -F _ispconfig_install_composer >/dev/null && _upd_run "Composer (глобально)" _ispconfig_install_composer
		declare -F _ispconfig_jailkit_apps >/dev/null && _upd_run "Jailkit-секции (composer/php/node)" _ispconfig_jailkit_apps
		# 3.2.9) Панель Node.js / Composer (страница/меню затираются обновлением ISPConfig)
		if declare -F _ispconfig_deploy_nodecomposer_panel >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Панель Node.js/Composer (пакеты по сайтам)" _ispconfig_deploy_nodecomposer_panel
		fi
		# 3.2.10) Панель «Уведомления» (email/Telegram + тест)
		if declare -F _ispconfig_deploy_notify_panel >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Панель Уведомления (email/Telegram)" _ispconfig_deploy_notify_panel
		fi
		# 3.2.10a) Панель «Обслуживание сервера» (состояние, обновление, настройки, журнал)
		if declare -F _ispconfig_deploy_maint_panel >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Панель Обслуживание сервера" _ispconfig_deploy_maint_panel
		fi
		# 3.2.11) Панель «Firewall: блок-лист» (ufw-deny IP/подсетей + подсказки-кластеры)
		if declare -F _ispconfig_deploy_ufwblock_panel >/dev/null && command -v ufw >/dev/null 2>&1 && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Панель Firewall блок-лист (ufw)" _ispconfig_deploy_ufwblock_panel
		fi
		# 3.2.11b) Панель «Доверенные IP» (CrowdSec allowlist + fail2ban ignoreip)
		if declare -F _ispconfig_deploy_trusted_panel >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Панель Доверенные IP (CrowdSec + fail2ban)" _ispconfig_deploy_trusted_panel
		fi
		# 3.2.11c) Настройки безопасности панели (тайм-аут сессии, длина пароля, IDS для admin)
		if declare -F _ispconfig_security_settings >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "ISPConfig: тайм-аут сессии, длина пароля, IDS для admin" _ispconfig_security_settings
		fi
		# 3.2.11d) Бэкапы сайтов средствами ISPConfig (спрашивает)
		if declare -F _ispconfig_site_backups >/dev/null && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Бэкапы сайтов в ISPConfig" _ispconfig_site_backups
		fi
		# 3.2.12) Сброс opcache интерфейса — чтобы новые пункты меню/страницы панелей были видны сразу
		if declare -F _ispc_interface_php_reload >/dev/null && [[ -d /usr/local/ispconfig/interface/web/admin ]]; then
			_upd_run "Сброс opcache интерфейса ISPConfig (панели в меню)" _ispc_interface_php_reload
		fi
		# 3.3) Системный php (CLI/cron) — переприменить выбранную версию (PHP_CLI_DEFAULT)
		if [[ -n "${PHP_CLI_DEFAULT:-}" ]] && declare -F _php_set_cli_default >/dev/null; then
			_upd_run "Системный php (CLI/cron)" _php_set_cli_default
		fi
		# 3.4) Monit → ISPConfig (Server Config → Monitor): вписать/обновить URL и доступ
		if [[ "${MONIT_ISPC_INTEGRATE:-y}" == "y" ]] && declare -F _monit_apply_to_ispconfig >/dev/null \
		   && command -v monit >/dev/null 2>&1 && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			_upd_run "Monit → ISPConfig (Server Config)" _monit_apply_to_ispconfig
		fi
		# 3.5) Блокировка доступа по IP — ТЕ ЖЕ патчи, что при установке (логично их
		#      переприменять: ISPConfig resync / правки могли их размыть). Идемпотентно.
		#   • default-сервер nginx (:80 по HTTP_IP_POLICY, :443 ssl_reject_handshake);
		#   • панель только по FQDN (PANEL_FQDN_ONLY — функция сама вкл/выкл и nginx -t);
		#   • ограничение веб-админки БД (DBADMIN_FQDN_ONLY/IP — сама делает nginx -t+откат).
		if [[ "${WEBSERVER:-nginx}" == "nginx" ]] && declare -F _nginx_landing_page >/dev/null \
		   && [[ -f /etc/nginx/conf.d/00-default.conf ]]; then
			echo ""; ui_step "Обновление: default-сервер — доступ по IP (HTTP_IP_POLICY=${HTTP_IP_POLICY:-landing})"
			cp -a /etc/nginx/conf.d/00-default.conf /etc/nginx/conf.d/00-default.conf.preupd.bak 2>/dev/null || true
			_nginx_landing_page
			if nginx -t >>"$SETUP_LOG" 2>&1; then
				systemctl reload nginx >>"$SETUP_LOG" 2>&1 || true
				rm -f /etc/nginx/conf.d/00-default.conf.preupd.bak
				ui_success "Default-сервер переприменён (по IP — ${HTTP_IP_POLICY:-landing}; :443 reject)."
			else
				mv -f /etc/nginx/conf.d/00-default.conf.preupd.bak /etc/nginx/conf.d/00-default.conf 2>/dev/null || true
				ui_warn "nginx -t не прошёл — откатил 00-default.conf (см. ${SETUP_LOG})."
			fi
		fi
		if declare -F _hostcert_panel_fqdn_only >/dev/null && [[ -n "${SERVER_FQDN:-}" ]] \
		   && [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]]; then
			echo ""; ui_step "Обновление: доступ к панели только по FQDN (PANEL_FQDN_ONLY=${PANEL_FQDN_ONLY:-n})"
			_hostcert_panel_fqdn_only "${SERVER_FQDN}" || ui_warn "panel-fqdn-only: замечания (не критично)."
		fi
		if declare -F _dbadmin_restrict >/dev/null && [[ -e /var/www/html/phpmyadmin || -e /var/www/html/adminer ]]; then
			_upd_run "Ограничение веб-админки БД (FQDN/IP)" _dbadmin_restrict
		fi
	else
		ui_info "Adopt-режим: модернизация vhost/PHP-регистрация/Monit→ISPConfig пропущены (не трогаем шаблоны ISPConfig)."
	fi

	# 4) Авто-тюнинг
	[[ "$sel" == *" tuning "* ]] && declare -F stage_tuning >/dev/null && _upd_run "Авто-тюнинг под железо" stage_tuning

	# 5) Почта (доставляемость + per-domain TLS)
	if [[ "$sel" == *" mail "* ]]; then
		declare -F stage_maildeliver >/dev/null && _upd_run "Доставляемость почты"       stage_maildeliver
		declare -F stage_mailsni     >/dev/null && _upd_run "Per-domain TLS почты (SNI)" stage_mailsni
	fi

	# 6) LE-серт хоста / 7) плагины Roundcube / 8) бэкапы
	[[ "$sel" == *" certs "*     ]] && declare -F stage_hostcert  >/dev/null && _upd_run "LE-сертификат хоста"             stage_hostcert
	[[ "$sel" == *" rcplugins "* ]] && declare -F stage_rcplugins >/dev/null && _upd_run "Плагины ISPConfig для Roundcube" stage_rcplugins
	[[ "$sel" == *" backup "*    ]] && declare -F stage_backup    >/dev/null && _upd_run "Резервное копирование"           stage_backup
	[[ "$sel" == *" notify "*    ]] && declare -F apply_notifications >/dev/null && _upd_run "Уведомления + ежедневный монитор" apply_notifications

	# (ядро — nginx и ISPConfig — обновляется в начале, шаг 1.5)
	# Плагин firewall ISPConfig мог сработать по ходу обновления — ещё раз в самом конце
	declare -F _ufw_ensure_enabled >/dev/null && ( _ufw_ensure_enabled )

	echo ""
	if ((${#UPD_FAILED[@]})); then
		ui_warn "Обновление закончено, но с ошибками в шагах (${#UPD_FAILED[@]}), подробности выше и в ${SETUP_LOG}:"
		local _f; for _f in "${UPD_FAILED[@]}"; do ui_warn "  • ${_f}"; done
	else
		ui_success "Обновление/патчи применены."
	fi
	ui_info "Проверка: ${UI_W}$(ls_hint --healthcheck)${UI_NC}"
	log "update-mode: завершён"
	return 0
}

# Обновление ISPConfig штатным механизмом (https://www.faqforge.com/.../how-to-update-ispconfig-3/).
# ispconfig_update.sh скачивает свежую версию и запускает интерактивный update.php.
# Запускаем ИНТЕРАКТИВНО — админ отвечает на вопросы (reconfigure services и т.п.).
# Без вопросов (--autoinstall, секция [update]): бэкап ISPConfig = да, Reconfigure Services = да,
# новый SSL-сертификат панели = НЕТ (иначе заменит LE-сертификат хоста), сертификаты служб не
# пересоздаются, симлинки Postfix/PureFTPd на ispserver.* сохраняются. Источник — ISPCONFIG_BRANCH
# (nightly | stable). ISPC_UPDATE_INTERACTIVE=y — старый режим с вопросами апдейтера.
# rc=0 — обновление прошло и панель отвечает.
_update_ispconfig() {
	ui_step "Обновление ISPConfig (официальный апдейтер)"
	command -v ispconfig_update.sh >/dev/null 2>&1 || {
		ui_warn "ispconfig_update.sh не найден — обновите вручную (faqforge: how-to-update-ispconfig-3)."; return 1; }
	local src="${ISPCONFIG_BRANCH:-}" before after dbb dba
	before="$(grep -oP "ISPC_APP_VERSION.,\s*.\K[^'\"]+" /usr/local/ispconfig/server/lib/config.inc.php 2>/dev/null)"
	# ветка не задана — по текущей версии: 3.3dev и т.п. — nightly, иначе stable
	if [[ "$src" != stable && "$src" != nightly ]]; then
		[[ "$before" == *dev* ]] && src=nightly || src=stable
	fi
	dbb="$(mysql --defaults-file=/root/.my.cnf -NBe "SELECT dbversion FROM dbispconfig.server WHERE server_id=1" 2>/dev/null)"
	local rc=0
	if [[ "${ISPC_UPDATE_INTERACTIVE:-n}" == "y" ]]; then
		ui_info "Отвечайте на вопросы апдейтера: Reconfigure Services = yes, новый SSL-сертификат = no."
		ispconfig_update.sh --update-source="$src" || rc=$?
	else
		local ini port rootpw
		port="$(grep -m1 -oE 'listen[[:space:]]+[0-9]+' /etc/nginx/sites-available/ispconfig.vhost 2>/dev/null | grep -oE '[0-9]+$')"
		port="${port:-${ISPCONFIG_PANEL_PORT:-8080}}"
		rootpw="$(awk -F= '/^[[:space:]]*password[[:space:]]*=/{sub(/^[[:space:]]*/,"",$2); gsub(/^["'"'"']|["'"'"']$/,"",$2); print $2; exit}' /root/.my.cnf 2>/dev/null)"
		rootpw="${rootpw:-${MARIADB_ROOT_PW:-}}"
		ini="$(umask 077; mktemp /root/.ispc-update.XXXXXX.ini)"
		cat >"$ini" <<INI
[update]
do_backup=yes
mysql_root_password=${rootpw}
mysql_master_hostname=
mysql_master_root_user=
mysql_master_root_password=
mysql_master_database=
reconfigure_permissions_in_master_database=no
reconfigure_services=yes
ispconfig_port=${port}
create_new_ispconfig_ssl_cert=no
reconfigure_crontab=yes
create_ssl_server_certs=n
ignore_hostname_dns=n
ispconfig_postfix_ssl_symlink=y
ispconfig_pureftpd_ssl_symlink=y
svc_detect_change_mail_server=yes
svc_detect_change_web_server=yes
svc_detect_change_dns_server=yes
svc_detect_change_xmpp_server=yes
svc_detect_change_firewall_server=yes
svc_detect_change_vserver_server=yes
svc_detect_change_db_server=yes
INI
		local ulog=/var/log/luckystack/ispconfig-update.log
		ui_spin "Обновление ISPConfig (${src}), журнал ${ulog}" bash -c \
			"ispconfig_update.sh --update-source='$src' --autoinstall='$ini' </dev/null >'$ulog' 2>&1" || rc=$?
		rm -f "$ini"
		chmod 600 "$ulog" 2>/dev/null
		grep -qiE 'fatal error|update failed|ERROR' "$ulog" && { ui_warn "В журнале апдейтера есть ошибки: $(grep -iE 'fatal error|update failed|ERROR' "$ulog" | head -2 | tr '\n' ' ')"; }
	fi
	after="$(grep -oP "ISPC_APP_VERSION.,\s*.\K[^'\"]+" /usr/local/ispconfig/server/lib/config.inc.php 2>/dev/null)"
	dba="$(mysql --defaults-file=/root/.my.cnf -NBe "SELECT dbversion FROM dbispconfig.server WHERE server_id=1" 2>/dev/null)"
	# панель отвечает? (страница входа; с «панель только по FQDN» — по имени хоста)
	local fqdn="${SERVER_FQDN:-$(hostname -f 2>/dev/null)}" code
	code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve "${fqdn}:${port:-8080}:127.0.0.1" "https://${fqdn}:${port:-8080}/login/" 2>/dev/null)"
	if ((rc == 0)) && [[ "$code" == 200 ]]; then
		ui_success "ISPConfig обновлён: ${before:-?} (БД ${dbb:-?}) → ${after:-?} (БД ${dba:-?}); панель отвечает."
		declare -F config_set >/dev/null && config_set ISPCONFIG_INSTALL_DATE "$(date '+%Y-%m-%d' 2>/dev/null)"
		return 0
	fi
	ui_warn "Обновление ISPConfig: код ${rc}, панель отвечает ${code:-—}. Бэкап апдейтера — /var/backup/ispconfig_*; подробности — журнал апдейтера."
	return 1
}

# Запуск одного шага обновления с обрамлением и терпимостью к ошибкам.
# Шаг идёт в подоболочке: при set -u незаданная переменная завершает весь процесс, и раньше
# сбой одного шага обрывал --update (хуже всего сразу после обновления ISPConfig: ядро уже
# новое, а патчи не наложены). Настройки, записанные шагом через config_set, перечитываем.
_upd_run() {
	local label="$1" fn="$2" rc=0
	echo ""
	ui_step "Обновление: ${label}"
	( "$fn" ) || rc=$?
	if ((rc != 0)); then
		ui_warn "${label}: завершилось с ошибкой (код ${rc}), остальные шаги продолжаются."
		UPD_FAILED+=("$label")
	fi
	declare -F config_load >/dev/null && { config_load >/dev/null 2>&1 || true; }
	return 0
}

# =============================================================================
# Adopt-режим (--adopt): безопасно подключить наши аддоны к УЖЕ установленному
# (ручному / по гайду) серверу — с бэкапом и повторным подтверждением.
# =============================================================================

# Бэкап ПЕРЕД изменениями: все БД (вкл. dbispconfig) + /etc + /usr/local/ispconfig.
# rc=0 — полный бэкап создан; rc!=0 — не удалось/неполон (вызывающий потребует ручного).
_adopt_backup() {
	local ts dest; ts="$(date +%Y%m%d-%H%M%S)"; dest="/var/backups/luckystack-preadopt-${ts}"
	ui_step "Резервная копия ПЕРЕД изменениями: ${dest}"
	mkdir -p /var/backups 2>/dev/null || true
	local freem; freem="$(df -Pm /var/backups 2>/dev/null | awk 'NR==2{print $4}')"
	if [[ "${freem:-0}" =~ ^[0-9]+$ ]] && (( freem < 2048 )); then
		ui_warn "Мало места под бэкап в /var/backups (${freem} МБ; нужно ≥2 ГБ)."
		return 1
	fi
	mkdir -p "$dest" || { ui_warn "Не удаётся создать ${dest}."; return 1; }
	chmod 700 "$dest" 2>/dev/null || true
	local rc=0
	# --- Базы данных ---
	if command -v mysqldump >/dev/null 2>&1 && command -v mysql >/dev/null 2>&1; then
		mkdir -p "$dest/mysql"
		local dbs db
		dbs="$(mysql -N -e 'SHOW DATABASES;' 2>/dev/null | grep -Ev '^(information_schema|performance_schema|sys)$')"
		[[ -z "$dbs" ]] && { ui_warn "Список БД пуст/нет доступа к MySQL — БД НЕ забэкаплены."; rc=1; }
		for db in $dbs; do
			mysqldump --single-transaction --quick --routines --triggers --events --databases "$db" 2>>"$SETUP_LOG" \
				| gzip -c > "$dest/mysql/${db}.sql.gz" || { ui_warn "Дамп БД ${db} не удался."; rc=1; }
		done
		[[ -d /usr/local/ispconfig && ! -s "$dest/mysql/dbispconfig.sql.gz" ]] && \
			{ ui_warn "БД ISPConfig (dbispconfig) НЕ забэкаплена."; rc=1; }
	else
		ui_warn "mysqldump/mysql недоступны — БД НЕ забэкаплены."; rc=1
	fi
	# --- Конфиги ---
	tar czf "$dest/etc.tar.gz" -C / etc 2>>"$SETUP_LOG" || { ui_warn "Архив /etc не удался."; rc=1; }
	[[ -d /usr/local/ispconfig ]] && \
		{ tar czf "$dest/ispconfig.tar.gz" -C / usr/local/ispconfig 2>>"$SETUP_LOG" || { ui_warn "Архив ISPConfig не удался."; rc=1; }; }
	du -sh "$dest" 2>/dev/null | awk '{print $1}' > "$dest/.size" 2>/dev/null || true
	if (( rc == 0 )); then
		ui_success "Бэкап создан: ${dest} ($(cat "$dest/.size" 2>/dev/null))."
		log "adopt-backup: ok → ${dest}"
	else
		ui_warn "Бэкап НЕПОЛОН/с ошибками: ${dest} — НЕ полагайтесь на него."
		log "adopt-backup: PARTIAL → ${dest}"
	fi
	return $rc
}

run_adopt_mode() {
	require_root
	check_os
	config_load || true
	clear 2>/dev/null || true
	ui_header "Adopt-режим — аддоны на уже установленный сервер"

	if _detect_existing_install; then
		ui_box_top "Найдено"
		ui_box_line "  ${UI_Y}${EXISTING_INSTALL_REASON}${UI_NC}"
		ui_box_bottom
	else
		ui_warn "Признаков установленного сервера не найдено."
		ui_info "Adopt рассчитан на УЖЕ настроенный сервер; для чистой установки — без --adopt."
		[[ -t 0 ]] && { ui_confirm "Всё равно продолжить в adopt-режиме?" n || { ui_info "Отмена."; return 0; }; } || return 0
	fi
	ui_warn "Сервер воспринимается как ВНЕШНИЙ (собран не нашим установщиком):"
	ui_info "  • НЕ трогаем: сборку nginx, переустановку ISPConfig, его шаблоны/vhost'ы/БД, firewall/SSH."
	ui_info "  • Ставим только server-agnostic аддоны: бэкап, уведомления, тюнинг, доставляемость почты, security-доп."
	export UPD_ADOPTED=1

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} бэкап + подтверждение пропускаются; ниже — предпросмотр применяемого."
		run_update_mode
		return $?
	fi

	# --- 1/3 BACKUP-GATE ---
	echo ""; ui_step "Шаг 1/3 — резервная копия (на сервере есть БД ISPConfig и проекты)"
	if ! _adopt_backup; then
		echo ""
		ui_warn "АВТО-БЭКАП не удался/неполон. Сделайте копию ВРУЧНУЮ (все БД + /etc + /usr/local/ispconfig) ПЕРЕД продолжением."
		[[ -t 0 ]] || { ui_error "Неинтерактивно и без подтверждённого бэкапа — adopt прерван."; return 2; }
		local a; read -rp "$(echo -e "${UI_W}Бэкап сделан вручную? Введите ${UI_R}BACKUP-OK${UI_W}:${UI_NC} ")" a
		[[ "$a" == "BACKUP-OK" ]] || { ui_info "Не подтверждено — отмена."; return 0; }
	fi

	# --- 2/3 RE-CONFIRM ---
	echo ""; ui_step "Шаг 2/3 — подтверждение применения"
	ui_warn "Аддоны будут применены к РАБОЧЕМУ серверу с данными."
	if [[ -t 0 ]]; then
		local c; read -rp "$(echo -e "${UI_W}Для продолжения введите ${UI_G}APPLY${UI_NC}: ")" c
		[[ "$c" == "APPLY" ]] || { ui_info "Не подтверждено — отмена."; return 0; }
	fi

	# --- 3/3 ПРИМЕНЕНИЕ (update-режим в adopt-постуре: UPD_ADOPTED=1) ---
	echo ""; ui_step "Шаг 3/3 — применение аддонов"
	run_update_mode
	return $?
}
