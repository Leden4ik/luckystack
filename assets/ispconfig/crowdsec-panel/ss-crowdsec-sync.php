<?php
/*
  LuckyStack: синхронизатор CrowdSec ↔ панель ISPConfig (root-cron, раз в минуту).

  Интерфейс ISPConfig (непривилегированный пользователь) не может дёргать cscli (root).
  Поэтому:
    1) панель пишет запросы (снять решение по IP) в очередь crowdsec_action (status='pending');
    2) этот скрипт (root) их выполняет (cscli decisions delete) и обновляет кэш активных
       решений (таблица crowdsec_decision), который читает страница «CrowdSec».

  Источник — `cscli decisions list -o json`: массив алертов, в каждом decisions[] + source{cn,as_name}.
*/

$conf = array();
require '/usr/local/ispconfig/server/lib/config.inc.php';
require '/usr/local/ispconfig/server/lib/app.inc.php';

if(!function_exists('exec')) exit(1);
exec('which cscli 2>/dev/null', $w, $rc);
if($rc !== 0 || empty($w)) exit(0);

// --- 1) выполнить отложенные действия (снятие бана по IP) ---
$acts = $app->db->queryAllRecords("SELECT id, action, value FROM crowdsec_action WHERE status = 'pending' ORDER BY id ASC LIMIT 100");
if(is_array($acts)) {
	foreach($acts as $a) {
		$val = (string)$a['value'];
		$o = array(); $rc = 1;
		if($a['action'] === 'delete_ip' && filter_var($val, FILTER_VALIDATE_IP)) {
			exec('cscli decisions delete --ip '.escapeshellarg($val).' 2>&1', $o, $rc);
		} else {
			$o = array('invalid value');
		}
		$app->db->query("UPDATE crowdsec_action SET status = ?, result = ?, processed = NOW() WHERE id = ?",
			($rc === 0 ? 'done' : 'error'), substr(trim(implode(' ', $o)), 0, 255), $a['id']);
	}
}

// --- 2) обновить кэш активных решений ---
$out = array(); $rc = 0;
exec('cscli decisions list -o json 2>/dev/null', $out, $rc);
$arr = json_decode(implode("\n", $out), true);

$app->db->query("DELETE FROM crowdsec_decision");
if(is_array($arr)) {
	foreach($arr as $al) {
		$src = (isset($al['source']) && is_array($al['source'])) ? $al['source'] : array();
		$cn  = isset($src['cn']) ? (string)$src['cn'] : '';
		$asn = isset($src['as_name']) ? (string)$src['as_name'] : '';
		$decs = (isset($al['decisions']) && is_array($al['decisions'])) ? $al['decisions'] : array();
		foreach($decs as $d) {
			if(isset($d['simulated']) && $d['simulated']) continue;
			$g = function($k) use ($d) { return isset($d[$k]) ? (string)$d[$k] : ''; };
			$app->db->query(
				"INSERT INTO crowdsec_decision (value, scope, scenario, origin, type, country, as_name, duration, updated) VALUES (?,?,?,?,?,?,?,?,NOW())",
				substr($g('value'), 0, 64), substr($g('scope'), 0, 16), substr($g('scenario'), 0, 128),
				substr($g('origin'), 0, 32), substr($g('type'), 0, 16), substr($cn, 0, 8),
				substr($asn, 0, 128), substr($g('duration'), 0, 32)
			);
		}
	}
}

// --- 3) сводка по origin (вкл. community blocklist CAPI) — дёшево прямо из sqlite CrowdSec.
// Детальная таблица выше (cscli decisions list, по умолчанию) — только ЛОКАЛЬНЫЕ решения (их
// можно снимать). Community blocklist (CAPI) — это десятки тысяч IP, их показываем СВОДКОЙ.
$app->db->query("DELETE FROM crowdsec_origin");
$csdb = '/var/lib/crowdsec/data/crowdsec.db';
if(class_exists('PDO') && is_readable($csdb)) {
	try {
		$cs = new PDO('sqlite:'.$csdb);
		$cs->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
		$q = $cs->query("SELECT origin, COUNT(*) c FROM decisions WHERE until > datetime('now') GROUP BY origin");
		foreach($q as $r) {
			$app->db->query("INSERT INTO crowdsec_origin (origin, cnt, updated) VALUES (?,?,NOW())",
				substr((string)$r['origin'], 0, 32), (int)$r['c']);
		}
		$cs = null;
	} catch(Exception $e) { /* иная схема/нет доступа — сводку пропускаем */ }
}

// подчистить старые выполненные действия
$app->db->query("DELETE FROM crowdsec_action WHERE status <> 'pending' AND processed < (NOW() - INTERVAL 7 DAY)");
exit(0);
?>
