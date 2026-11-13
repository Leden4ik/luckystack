#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# LuckyStack: обновление гео-зон (диапазоны IP по странам) для модуля Firewall IP-rules.
#
# Качает агрегированные CIDR-списки по странам с ipdeny.com в /etc/ss-firewall/geoip/:
#   <cc>.zone  — IPv4,  <cc>6.zone — IPv6 (best-effort).
# Список нужных стран кладёт ISPConfig-плагин в countries.list (по активным гео-правилам).
# После обновления — ufw reload, чтобы хук /etc/ufw/before.init пересобрал ipset'ы.
# Запускается из плагина (при появлении новой страны) и еженедельным cron.

set -u
GEODIR=/etc/ss-firewall/geoip
LIST="$GEODIR/countries.list"
V4_BASE="https://www.ipdeny.com/ipblocks/data/aggregated"
V6_BASE="https://www.ipdeny.com/ipv6/ipaddresses/aggregated"

mkdir -p "$GEODIR"
[ -f "$LIST" ] || exit 0

fetch() { # url dest
	tmp=$(mktemp) || return 1
	if curl -fsSL --max-time 90 "$1" -o "$tmp" && [ -s "$tmp" ]; then
		mv "$tmp" "$2"; return 0
	fi
	rm -f "$tmp"; return 1
}

wanted=""
while IFS= read -r cc; do
	cc=$(printf '%s' "$cc" | tr 'A-Z' 'a-z' | tr -cd 'a-z')
	[ ${#cc} -eq 2 ] || continue
	wanted="$wanted $cc"
	fetch "$V4_BASE/${cc}-aggregated.zone" "$GEODIR/${cc}.zone"  || true
	fetch "$V6_BASE/${cc}-aggregated.zone" "$GEODIR/${cc}6.zone" || true
done < "$LIST"

# удалить зоны стран, которых больше нет в списке
for f in "$GEODIR"/*.zone; do
	[ -f "$f" ] || continue
	b=$(basename "$f" .zone); b=${b%6}
	case " $wanted " in *" $b "*) : ;; *) rm -f "$f" ;; esac
done

# применить: ufw reload → before.init пересоберёт ipset'ы
ufw reload >/dev/null 2>&1 || true
exit 0
