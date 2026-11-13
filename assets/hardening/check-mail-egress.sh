#!/bin/bash
# =============================================================================
# check-mail-egress.sh — диагностика «почему не уходит почта»
# Проверяет: интернет, egress-порты (через portquiz), :25 к реальным MX,
# submission-порты для relay, локальный firewall. Выдаёт вердикт.
# Запуск:  bash check-mail-egress.sh   (root желателен — для проверки firewall)
# =============================================================================

TIMEOUT="${TIMEOUT:-7}"

# Цвета (отключаются, если не терминал)
if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi

ok(){   echo "  ${G}OPEN${N}    $*"; }
bad(){  echo "  ${R}BLOCKED${N} $*"; }
hdr(){  echo; echo "${B}== $* ==${N}"; }

# Проверка TCP-коннекта (без nc, через bash /dev/tcp). Возврат: 0=OPEN 1=BLOCKED
tcp(){
	local host=$1 port=$2 ip
	ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
	[[ -z $ip ]] && ip=$host
	timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null
}

# check <host> <port> [подпись]
check(){
	local host=$1 port=$2 label=${3:-}
	if tcp "$host" "$port"; then ok "$host:$port $label"; return 0
	else bad "$host:$port $label"; return 1; fi
}

echo "${B}=== Диагностика egress почты (timeout ${TIMEOUT}s) ===${N}"

# --- 1. Жив ли интернет вообще ---
hdr "1) Интернет (контроль)"
NET_OK=1
check 1.1.1.1 443 "Cloudflare HTTPS" || NET_OK=0
check 1.1.1.1 80  "Cloudflare HTTP"  || true

# --- 2. Карта egress-портов через portquiz.net (отвечает на ЛЮБОМ порту) ---
hdr "2) Egress-порты (portquiz.net — отвечает на любом порту)"
declare -A PQ
for p in 80 443 25 465 587 2525 1025; do
	if tcp portquiz.net "$p"; then PQ[$p]=OPEN; ok "portquiz.net:$p"; else PQ[$p]=BLOCKED; bad "portquiz.net:$p"; fi
done

# --- 3. :25 к реальным MX (исходящая доставка) ---
hdr "3) :25 к реальным MX (прямая доставка)"
MX25_ANY_OPEN=0
for h in aspmx.l.google.com mxs.mail.ru mx.yandex.ru inmx.rambler.ru mx1.hotmail.com; do
	if check "$h" 25; then MX25_ANY_OPEN=1; fi
done

# --- 4. Submission-порты для relay (реальные submission-хосты) ---
hdr "4) Submission-порты для relay"
RELAY_OK=0
for hp in smtp.gmail.com:587 smtp.gmail.com:465 smtp-relay.brevo.com:2525 smtp.sendgrid.net:2525 smtp.mailgun.org:587; do
	if check "${hp%:*}" "${hp#*:}"; then RELAY_OK=1; fi
done

# --- 5. Локальный firewall (контекст) ---
hdr "5) Локальный firewall (контекст)"
if command -v ufw &>/dev/null; then
	echo "  ufw: $(ufw status verbose 2>/dev/null | grep -i '^Default' || echo 'нет доступа (нужен root)')"
fi
if command -v nft &>/dev/null; then
	cs=$(nft list ruleset 2>/dev/null | grep -c crowdsec)
	echo "  nftables crowdsec-правил: ${cs:-0}"
	out25=$(nft list ruleset 2>/dev/null | grep -iE 'oif|output' | grep -c 'dport 25')
	echo "  локальных DROP/REJECT на исходящий :25: проверьте вручную (см. ниже)"
fi
command -v fail2ban-client &>/dev/null && \
	echo "  fail2ban jails: $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' || echo '—')"

# --- 6. Очередь почты ---
hdr "6) Очередь Postfix"
if command -v mailq &>/dev/null; then
	echo "  писем в очереди: $(mailq 2>/dev/null | grep -c '^[A-F0-9]')"
fi

# --- ВЕРДИКТ ---
hdr "ВЕРДИКТ"
if [[ $NET_OK -eq 0 ]]; then
	echo "  ${R}Нет исходящего интернета вообще${N} — проблема не в почте, а в сети/маршруте."
elif [[ "${PQ[25]}" == BLOCKED && "${PQ[443]}" == OPEN ]]; then
	echo "  ${R}Хостер блокирует исходящий :25${N} (egress по порту: portquiz:25 закрыт, :443 открыт)."
	echo "  Локальный firewall ни при чём — режется выше по сети."
	echo
	if [[ "${PQ[587]}" == OPEN || "${PQ[465]}" == OPEN || "${PQ[2525]}" == OPEN || $RELAY_OK -eq 1 ]]; then
		echo "  ${G}Есть открытые submission-порты${N} → можно поднять RELAY без хостера:"
		[[ "${PQ[587]}"  == OPEN ]] && echo "    • :587 открыт"
		[[ "${PQ[465]}"  == OPEN ]] && echo "    • :465 открыт"
		[[ "${PQ[2525]}" == OPEN ]] && echo "    • :2525 открыт (Brevo/Mailgun/SendGrid)"
		echo "    Настройте relayhost через сервис рассылки или свой ящик."
	else
		echo "  ${Y}Submission-порты тоже закрыты${N} → relay по стандартным портам не выйдет."
		echo "  Единственный путь — ТИКЕТ ХОСТЕРУ: открыть исходящие TCP/25 (и 587)."
	fi
elif [[ $MX25_ANY_OPEN -eq 1 ]]; then
	echo "  ${G}:25 наружу работает${N} — блокировки портов нет."
	echo "  Если почта всё равно не уходит — причина в доставляемости (PTR/SPF/DKIM/DMARC,"
	echo "  RBL) или в локальном firewall/CrowdSec по конкретным IP. Смотрите mail.log:"
	echo "    grep -E 'status=(deferred|bounced)' /var/log/mail.log | tail"
else
	echo "  ${Y}Неоднозначно${N} — :25 к MX закрыт, но и portquiz:25 закрыт."
	echo "  Скорее всего хостер режет :25. Проверьте mail.log и обратитесь к хостеру."
fi

echo
echo "Подсказки:"
echo "  • локальные DROP на исходящий :25:   nft list ruleset | grep -iA3 'oif.*dport 25'"
echo "  • разбанить IP в CrowdSec:            cscli decisions list ; cscli decisions delete -i <IP>"
echo "  • пробить очередь после фикса:        postqueue -f"
