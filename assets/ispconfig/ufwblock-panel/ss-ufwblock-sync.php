<?php
/*
  LuckyStack: синхронизатор блок-листа ufw ↔ панель ISPConfig (root-cron, раз в минуту).

  Интерфейс ISPConfig (непривилегированный) не может дёргать ufw (root). Поэтому:
    1) панель ведёт таблицу ufw_block (желаемый блок-лист: IP/CIDR, active y/n);
    2) этот скрипт (root) РЕКОНСИЛИТ реальные правила ufw с таблицей:
         - для active-строк, которых нет в ufw → `ufw insert 1 deny from <t> comment panel-block:<t>`;
         - для правил panel-block, которых нет среди active-строк → `ufw delete deny from <t>`;
       (правила ставим ПЕРВЫМИ — бьют до allow-правил портов);
    3) обновляет флаг applied у строк + кэширует ПОДСКАЗКИ (ufw_block_suggest): подсети /24,
       из которых в CrowdSec активно забанено ≥3 IP (кандидаты на бан всей подсети — CrowdSec
       firewall-bouncer range-решения НЕ применяет, поэтому подсеть бьём через ufw).

  Валидация цели дублируется здесь (не доверяем входу): только IPv4/IPv6/CIDR, маска не шире /8
  (IPv4) / /16 (IPv6). escapeshellarg на всё. Комментарий-тег panel-block:<t> — для реконсиляции.
*/

$conf = array();
require '/usr/local/ispconfig/server/lib/config.inc.php';
require '/usr/local/ispconfig/server/lib/app.inc.php';

if(!function_exists('exec')) exit(1);
exec('which ufw 2>/dev/null', $w, $rc);
if($rc !== 0 || empty($w)) exit(0);

// корректная цель: IPv4/IPv6/CIDR, не слишком широкая маска
function _ub_valid_target($t) {
	if(filter_var($t, FILTER_VALIDATE_IP)) return true;
	if(strpos($t, '/') !== false) {
		list($ip, $mask) = explode('/', $t, 2);
		if(!ctype_digit($mask)) return false;
		$m = (int)$mask;
		if(filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return ($m >= 8 && $m <= 32);
		if(filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) return ($m >= 16 && $m <= 128);
	}
	return false;
}

// извлечь цели panel-block из `ufw status` (по нашему комментарию-тегу)
function _ub_applied() {
	$st = array(); exec('ufw status 2>/dev/null', $st, $rc);
	$active = false; $out = array();
	foreach($st as $line) {
		if(stripos($line, 'Status: active') !== false) $active = true;
		if(preg_match('/panel-block:(\S+)/', $line, $m)) $out[$m[1]] = 1;
	}
	return array($active, $out);
}

// --- 1) реконсиляция ufw ↔ таблица ---
$rows = $app->db->queryAllRecords("SELECT id, target, active FROM ufw_block");
if(!is_array($rows)) $rows = array();
$desired = array();
foreach($rows as $r) if($r['active'] === 'y' && _ub_valid_target($r['target'])) $desired[$r['target']] = (int)$r['id'];

list($ufw_active, $applied) = _ub_applied();

if($ufw_active) {
	// добавить недостающие
	foreach($desired as $t => $id) {
		if(!isset($applied[$t])) {
			$o = array(); $rc = 1;
			exec('ufw insert 1 deny from '.escapeshellarg($t).' comment '.escapeshellarg('panel-block:'.$t).' 2>&1', $o, $rc);
		}
	}
	// снять лишние (правило panel-block есть, а в желаемом наборе цели нет)
	foreach(array_keys($applied) as $t) {
		if(!isset($desired[$t]) && _ub_valid_target($t)) {
			$o = array(); $rc = 1;
			exec('ufw delete deny from '.escapeshellarg($t).' 2>&1', $o, $rc);
		}
	}
}

// обновить флаг applied по фактическому состоянию
list($ufw_active2, $applied2) = _ub_applied();
foreach($rows as $r) {
	$ap = ($r['active'] === 'y' && isset($applied2[$r['target']])) ? 'y' : 'n';
	$app->db->query("UPDATE ufw_block SET applied = ? WHERE id = ?", $ap, (int)$r['id']);
}

// --- 2) подсказки: кластеры /24 из активных решений CrowdSec (≥3 IP из одной подсети) ---
$app->db->query("DELETE FROM ufw_block_suggest");
exec('which cscli 2>/dev/null', $wc, $rcc);
if($rcc === 0 && !empty($wc)) {
	$out = array(); $rc = 0;
	exec('cscli decisions list -o json 2>/dev/null', $out, $rc);
	$arr = json_decode(implode("\n", $out), true);
	$cluster = array(); $samples = array();
	if(is_array($arr)) {
		foreach($arr as $al) {
			$decs = (isset($al['decisions']) && is_array($al['decisions'])) ? $al['decisions'] : array();
			foreach($decs as $d) {
				if(strcasecmp(isset($d['scope']) ? $d['scope'] : '', 'Ip') !== 0) continue;
				$v = isset($d['value']) ? (string)$d['value'] : '';
				if(!filter_var($v, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) continue;   // /24-кластеры только для IPv4
				$p = explode('.', $v);
				$net = $p[0].'.'.$p[1].'.'.$p[2].'.0/24';
				$cluster[$net] = (isset($cluster[$net]) ? $cluster[$net] : 0) + 1;
				if(!isset($samples[$net])) $samples[$net] = array();
				if(count($samples[$net]) < 6) $samples[$net][] = $v;
			}
		}
	}
	$blocked = array();
	foreach($rows as $r) if($r['active'] === 'y') $blocked[$r['target']] = 1;
	arsort($cluster);
	foreach($cluster as $net => $cnt) {
		if($cnt < 3) continue;                 // порог кластера
		if(isset($blocked[$net])) continue;    // уже блокируем — не предлагаем
		$app->db->query("INSERT INTO ufw_block_suggest (subnet, ip_count, sample, updated) VALUES (?,?,?,NOW())",
			$net, (int)$cnt, substr(implode(', ', $samples[$net]), 0, 255));
	}
}

exit(0);
?>
