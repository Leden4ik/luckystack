<?php
/*
  LuckyStack: синхронизатор Fail2ban ↔ панель ISPConfig (запускается root-cron'ом раз в минуту).

  Интерфейс ISPConfig работает под непривилегированным пользователем и НЕ может дёргать
  fail2ban-client (root-сокет). Поэтому:
    1) панель пишет запросы (разбан/бан) в таблицу fail2ban_action (status='pending');
    2) этот скрипт (root) их выполняет через fail2ban-client и помечает done/error;
    3) затем обновляет кэш статуса джейлов в таблице fail2ban_jail (его читает панель).

  Использует $app->db ISPConfig (creds из server/lib/config.inc.php) — отдельных паролей не надо.
*/

$conf = array();
require '/usr/local/ispconfig/server/lib/config.inc.php';
require '/usr/local/ispconfig/server/lib/app.inc.php';

if(!function_exists('exec')) exit(1);

// fail2ban установлен?
exec('which fail2ban-client 2>/dev/null', $w, $rc);
if($rc !== 0 || empty($w)) exit(0);

// --- 1) выполнить отложенные действия из панели -------------------------------------------
$acts = $app->db->queryAllRecords("SELECT id, action, jail, ip FROM fail2ban_action WHERE status = 'pending' ORDER BY id ASC LIMIT 200");
if(is_array($acts)) {
	foreach($acts as $a) {
		$okj = preg_match('/^[A-Za-z0-9_.\-]+$/', (string)$a['jail']);
		$oki = filter_var((string)$a['ip'], FILTER_VALIDATE_IP);
		if(!$okj || !$oki) {
			$app->db->query("UPDATE fail2ban_action SET status = 'error', result = 'invalid jail/ip', processed = NOW() WHERE id = ?", $a['id']);
			continue;
		}
		$verb = ($a['action'] === 'ban') ? 'banip' : 'unbanip';
		$cmd  = 'fail2ban-client set '.escapeshellarg($a['jail']).' '.$verb.' '.escapeshellarg($a['ip']).' 2>&1';
		$out = array(); $rc = 0;
		exec($cmd, $out, $rc);
		$res = trim(implode(' ', $out));
		$app->db->query("UPDATE fail2ban_action SET status = ?, result = ?, processed = NOW() WHERE id = ?",
			($rc === 0 ? 'done' : 'error'), substr($res, 0, 255), $a['id']);
	}
}

// --- 2) обновить кэш статуса джейлов ------------------------------------------------------
$o = array();
exec('fail2ban-client status 2>/dev/null', $o, $rc);
$jails = array();
foreach($o as $line) {
	if(stripos($line, 'Jail list:') !== false) {
		$p = explode(':', $line, 2);
		foreach(explode(',', $p[1]) as $j) { $j = trim($j); if($j !== '') $jails[] = $j; }
	}
}

$app->db->query("DELETE FROM fail2ban_jail");
foreach($jails as $j) {
	if(!preg_match('/^[A-Za-z0-9_.\-]+$/', $j)) continue;
	$s = array();
	exec('fail2ban-client status '.escapeshellarg($j).' 2>/dev/null', $s);
	$banned = 0; $total = 0; $failed = 0; $ips = '';
	foreach($s as $l) {
		if(preg_match('/Currently banned:\s*(\d+)/i', $l, $m)) $banned = (int)$m[1];
		if(preg_match('/Total banned:\s*(\d+)/i', $l, $m))     $total  = (int)$m[1];
		if(preg_match('/Currently failed:\s*(\d+)/i', $l, $m)) $failed = (int)$m[1];
		if(stripos($l, 'Banned IP list:') !== false) { $p = explode(':', $l, 2); $ips = trim($p[1]); }
	}
	$app->db->query("INSERT INTO fail2ban_jail (jail, banned, total, failed, banned_ips, updated) VALUES (?,?,?,?,?,NOW())",
		$j, $banned, $total, $failed, substr($ips, 0, 65000));
}

// подчистить старые выполненные действия (>7 дней)
$app->db->query("DELETE FROM fail2ban_action WHERE status <> 'pending' AND processed < (NOW() - INTERVAL 7 DAY)");
exit(0);
?>
