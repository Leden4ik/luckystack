#!/bin/bash
# =============================================================================
# lib/dns.sh — Этап (опц.): авторитативный DNS-сервер BIND9.
# Ставим пакеты; зоны и записи управляются через ISPConfig (configure_dns=y).
# =============================================================================

stage_dns() {
	ui_info "DNS-сервер BIND9 (зоны управляются через ISPConfig)"

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} apt install bind9 bind9-utils bind9-dnsutils haveged"
		ui_info "${UI_D}[dry-run]${UI_NC} enable named; зоны создаст ISPConfig"
		ui_success "BIND9 (имитация) установлен."
		return 0
	fi

	ui_step "Установка BIND9"
	apt_install bind9 bind9-utils bind9-dnsutils
	# haveged — дополнительная энтропия (полезно для DNSSEC-ключей на VPS)
	apt_install haveged || ui_warn "haveged не установлен (не критично)."

	# Если у сервера нет IPv6 — переводим named в IPv4-only для исходящих запросов (-4).
	# Иначе named пытается ходить к апстрим-NS по IPv6, ловит "address not available" и
	# засоряет лог тысячами строк (резолв при этом откатывается на IPv4 и работает).
	_dns_named_ipv4_only

	# Сервис называется named (через bind9.service alias)
	sys_run "Автозагрузка BIND9" systemctl enable --now named || \
		sys_run "Автозагрузка bind9" systemctl enable --now bind9

	ui_success "BIND9 установлен (зоны создаст ISPConfig при configure_dns=y)."
	log "dns: bind9 установлен, ожидает configure_dns в ISPConfig"
	return 0
}

# named -4 (IPv4-only исходящие), если на сервере нет рабочего IPv6. Идемпотентно.
# Источник истины об IPv6 — _has_ipv6 (SERVER_HAS_IPV6 из setup.conf, см. lib/core.sh).
# Вызывается из stage_dns и из --update.
_dns_named_ipv4_only() {
	local df=/etc/default/named
	[[ -f "$df" ]] || return 0
	if declare -F _has_ipv6 >/dev/null && _has_ipv6; then
		# IPv6 есть — убираем наш -4, если когда-то добавляли (возвращаем dual-stack)
		if grep -qE '^OPTIONS=.*[[:space:]-]4' "$df"; then
			sed -i -E 's/(^OPTIONS="[^"]*) -4(["[:space:]])/\1\2/; s/(^OPTIONS="[^"]*) -4"/\1"/' "$df" 2>/dev/null || true
			systemctl restart named >>"$SETUP_LOG" 2>&1 || systemctl restart bind9 >>"$SETUP_LOG" 2>&1 || true
			ui_info "named: IPv6 доступен — IPv4-only (-4) снят."
		fi
		return 0
	fi
	# IPv6 нет — добавить -4, если ещё не стоит
	if grep -qE '^OPTIONS=' "$df"; then
		grep -qE '^OPTIONS="[^"]*-4' "$df" && return 0   # уже стоит
		sed -i -E 's/^OPTIONS="([^"]*)"/OPTIONS="\1 -4"/' "$df"
	else
		echo 'OPTIONS="-u bind -4"' >>"$df"
	fi
	sed -i -E 's/  +/ /g; s/" /"/' "$df" 2>/dev/null || true
	systemctl restart named >>"$SETUP_LOG" 2>&1 || systemctl restart bind9 >>"$SETUP_LOG" 2>&1 || true
	ui_info "named: IPv6 на сервере нет → включён IPv4-only (-4), лог больше не засоряется «address not available»."
	log "dns: named -4 (no IPv6)"
}

stage_dns_summary() { echo "DNS: BIND9 (зоны через ISPConfig)"; }
