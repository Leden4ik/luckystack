<?php
/*
  LuckyStack: «Доверенные IP» ↔ CrowdSec и fail2ban (root-cron, раз в минуту).

  Панель ведёт таблицу ss_trusted_ip (какие IP и подсети должны быть доверенными). Интерфейс
  ISPConfig работает не от root и не может вызывать cscli и fail2ban-client, поэтому этот
  скрипт от root приводит систему к списку из таблицы:
    - CrowdSec: allowlist luckystack-trusted (cscli allowlists, CrowdSec 1.6.8+). Такой IP не
      получает решений ни от локальных сценариев, ни из общего блок-листа. Уже стоящие решения по
      новому IP снимаем (cscli decisions delete).
    - fail2ban: [DEFAULT] ignoreip в /etc/fail2ban/jail.d/zz-luckystack-trusted.local, reload
      только когда список изменился. Уже стоящие баны по новому IP снимаем (fail2ban-client unban).
  Записи с истёкшим сроком удаляются из таблицы и уходят из обоих мест.

  Ещё здесь: очередь проверок «где забанен IP» (ss_trusted_job) и состояние для страницы
  (ss_trusted_state). Всё, что приходит из БД, проверяется заново, аргументы через escapeshellarg.
*/

$conf = array();
require '/usr/local/ispconfig/server/lib/config.inc.php';
require '/usr/local/ispconfig/server/lib/app.inc.php';
if(!function_exists('exec')) exit(1);

$lock = @fopen('/run/ss-trusted-sync.lock', 'c');
if($lock === false) $lock = @fopen(sys_get_temp_dir().'/ss-trusted-sync.lock', 'c');
if($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) exit(0);

$AL       = 'luckystack-trusted';
$F2B_FILE = '/etc/fail2ban/jail.d/zz-luckystack-trusted.local';

// Доверенный IP или подсеть. Слишком широкие сети не принимаем (IPv4 шире /16, IPv6 шире /32):
// доверие ко всей сети провайдера отключило бы защиту от всех, кто в ней сидит.
function tr_valid($t) {
	$t = (string)$t;
	if(strpos($t, '/') === false) return (bool)filter_var($t, FILTER_VALIDATE_IP);
	$p = explode('/', $t, 2);
	if(!ctype_digit($p[1])) return false;
	$m = (int)$p[1];
	if(filter_var($p[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return ($m >= 16 && $m <= 32);
	if(filter_var($p[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) return ($m >= 32 && $m <= 128);
	return false;
}
// входит ли IP в подсеть (или совпадает с одиночным адресом)
function tr_in($ip, $cidr) {
	if(strpos($cidr, '/') === false) return $ip === $cidr;
	list($net, $mask) = explode('/', $cidr, 2); $mask = (int)$mask;
	$ipb = @inet_pton($ip); $nb = @inet_pton($net);
	if($ipb === false || $nb === false || strlen($ipb) !== strlen($nb)) return false;
	$bytes = intdiv($mask, 8); $rem = $mask % 8;
	if($bytes > 0 && substr($ipb, 0, $bytes) !== substr($nb, 0, $bytes)) return false;
	if($rem > 0) { $mb = (0xff << (8 - $rem)) & 0xff; if((ord($ipb[$bytes]) & $mb) !== (ord($nb[$bytes]) & $mb)) return false; }
	return true;
}
function run($cmd, &$rc = null) { $o = array(); exec($cmd.' 2>&1', $o, $rc); return $o; }
function st_set($k, $v) { global $app; $app->db->query("REPLACE INTO ss_trusted_state (name, value, updated) VALUES (?, ?, NOW())", $k, (string)$v); }
function clean_comment($s) { return substr(trim(preg_replace('/[^\p{L}\p{N} ._,:()\/@-]+/u', ' ', (string)$s)), 0, 120); }

$have_cs  = trim((string)shell_exec('command -v cscli 2>/dev/null')) !== '';
$have_f2b = trim((string)shell_exec('command -v fail2ban-client 2>/dev/null')) !== '';
st_set('have_crowdsec', $have_cs ? 'y' : 'n');
st_set('have_fail2ban', $have_f2b ? 'y' : 'n');

// --- 1) истёкшие записи и желаемый список ---
$app->db->query("DELETE FROM ss_trusted_ip WHERE expires IS NOT NULL AND expires <= NOW()");
$rows = $app->db->queryAllRecords("SELECT id, target, comment, UNIX_TIMESTAMP(expires) AS exp_ts, applied, UNIX_TIMESTAMP(applied_at) AS applied_ts FROM ss_trusted_ip");
if(!is_array($rows)) $rows = array();
$desired = array();
foreach($rows as $r) if(tr_valid($r['target'])) $desired[$r['target']] = $r;

$errors = array();   // target => текст ошибки

// Снимать уже стоящие баны: для новых записей и ещё 5 минут после применения. fail2ban после
// reload асинхронно восстанавливает баны из своей базы и может вернуть только что снятый.
function tr_fresh($r) { return $r['applied'] !== 'y' || empty($r['applied_ts']) || (time() - (int)$r['applied_ts']) < 300; }

// --- 2) CrowdSec allowlist ---
if($have_cs) {
	$j = json_decode(implode("\n", run('cscli allowlists inspect '.escapeshellarg($AL).' -o json', $rc)), true);
	if($rc !== 0 || !is_array($j)) {
		run('cscli allowlists create '.escapeshellarg($AL).' -d '.escapeshellarg('Доверенные IP из панели ISPConfig (LuckyStack)'), $rc);
		$j = array('items' => array());
	}
	$have = array();
	foreach((array)(isset($j['items']) ? $j['items'] : array()) as $it) if(isset($it['value'])) $have[(string)$it['value']] = true;

	foreach($have as $v => $x) {
		if(!isset($desired[$v])) run('cscli allowlists remove '.escapeshellarg($AL).' '.escapeshellarg($v));
	}
	foreach($desired as $t => $r) {
		if(isset($have[$t])) continue;
		$cmd = 'cscli allowlists add '.escapeshellarg($AL).' '.escapeshellarg($t);
		$c = clean_comment($r['comment']);
		if($c !== '') $cmd .= ' -d '.escapeshellarg($c);
		if(!empty($r['exp_ts'])) $cmd .= ' -e '.max(60, (int)$r['exp_ts'] - time()).'s';
		$o = run($cmd, $rc);
		if($rc !== 0) $errors[$t] = 'CrowdSec: '.substr(trim(implode(' ', $o)), 0, 200);
	}
	// уже стоящие решения по новым доверенным снимаем (один раз, пока applied='n')
	foreach($desired as $t => $r) {
		if(!tr_fresh($r) || isset($errors[$t])) continue;
		// для подсети --contained: снять решения на любые адреса внутри неё, а не только на сам диапазон
		run('cscli decisions delete '.(strpos($t, '/') === false ? '--ip '.escapeshellarg($t) : '--range '.escapeshellarg($t).' --contained'));
	}
	// другие allowlists (не наши) — показать на странице, только чтение
	$other = array();
	foreach((array)json_decode(implode("\n", run('cscli allowlists list -o json')), true) as $a) {
		if(!is_array($a) || !isset($a['name']) || $a['name'] === $AL) continue;
		$vals = array();
		foreach((array)(isset($a['items']) ? $a['items'] : array()) as $it) if(isset($it['value'])) $vals[] = $it['value'];
		$other[] = array('name' => $a['name'], 'description' => isset($a['description']) ? $a['description'] : '', 'values' => $vals);
	}
	st_set('other_allowlists', json_encode($other, JSON_UNESCAPED_UNICODE));
}

// --- 3) fail2ban ignoreip ---
if($have_f2b) {
	$list = array('127.0.0.1/8', '::1');
	foreach($desired as $t => $r) $list[] = $t;
	$content = "# luckystack: доверенные IP из панели ISPConfig (страница «Доверенные IP»).\n"
		."# Файл перезаписывается cron ss-trusted-sync.php, вручную не править.\n"
		."[DEFAULT]\nignoreip = ".implode(' ', $list)."\n";
	if(@file_get_contents($F2B_FILE) !== $content) {
		@file_put_contents($F2B_FILE, $content); @chmod($F2B_FILE, 0644);
		$o = run('fail2ban-client reload', $rc);
		sleep(3);   // дать джейлам подняться, иначе unban ниже может опередить восстановление банов
		if($rc !== 0) foreach($desired as $t => $r) if($r['applied'] !== 'y') $errors[$t] = (isset($errors[$t]) ? $errors[$t].'; ' : '').'fail2ban: '.substr(trim(implode(' ', $o)), 0, 160);
	}
	// уже стоящие баны по новым доверенным снимаем. Для подсети берём все текущие баны у самого
	// fail2ban (`fail2ban-client banned` → [{'sshd': ['1.2.3.4', ...]}, ...]) и снимаем попавшие в неё.
	$banned = array();
	if(preg_match_all("/'([0-9A-Fa-f:.]+)'/", implode(' ', run('fail2ban-client banned')), $bm))
		foreach($bm[1] as $bip) if(filter_var($bip, FILTER_VALIDATE_IP)) $banned[$bip] = true;
	foreach($desired as $t => $r) {
		if(!tr_fresh($r)) continue;
		if(strpos($t, '/') === false) { run('fail2ban-client unban '.escapeshellarg($t)); continue; }
		foreach($banned as $bip => $x) if(filter_var($bip, FILTER_VALIDATE_IP) && tr_in($bip, $t)) run('fail2ban-client unban '.escapeshellarg($bip));
	}
}

// --- 4) отметить применённые ---
foreach($desired as $t => $r) {
	if(isset($errors[$t])) $app->db->query("UPDATE ss_trusted_ip SET applied = 'n', note = ? WHERE id = ?", $errors[$t], (int)$r['id']);
	elseif($have_cs || $have_f2b) $app->db->query("UPDATE ss_trusted_ip SET applied = 'y', applied_at = IFNULL(applied_at, NOW()), note = NULL WHERE id = ?", (int)$r['id']);
}
foreach($rows as $r) if(!tr_valid($r['target'])) $app->db->query("UPDATE ss_trusted_ip SET applied = 'n', note = 'некорректный IP или слишком широкая подсеть, пропущено' WHERE id = ?", (int)$r['id']);
$app->db->query("REPLACE INTO ss_trusted_state (name, value, updated) VALUES ('synced', NOW(), NOW())");   // время из базы, как и остальное на странице

// --- 5) проверки «где забанен IP» (до 3 за прогон) ---
$jobs = $app->db->queryAllRecords("SELECT id, ip FROM ss_trusted_job WHERE status = 'pending' ORDER BY id ASC LIMIT 3");
foreach((array)$jobs as $job) {
	$ip = (string)$job['ip'];
	if(!filter_var($ip, FILTER_VALIDATE_IP)) {
		$app->db->query("UPDATE ss_trusted_job SET status = 'error', result = 'некорректный IP', processed = NOW() WHERE id = ?", (int)$job['id']);
		continue;
	}
	$res = array('trusted' => array(), 'crowdsec' => array(), 'alerts' => array(), 'fail2ban' => array(), 'ufw_block' => array());
	foreach($desired as $t => $r) if(tr_in($ip, $t)) $res['trusted'][] = $t.($r['comment'] !== '' ? ' ('.$r['comment'].')' : '');
	if($have_cs) {
		foreach(run('cscli allowlists check '.escapeshellarg($ip)) as $l) if(stripos($l, 'allowlisted by') !== false) $res['trusted'][] = 'CrowdSec: '.trim($l);
		foreach((array)json_decode(implode("\n", run('cscli decisions list -a -i '.escapeshellarg($ip).' -o json')), true) as $al) {
			foreach((array)(isset($al['decisions']) ? $al['decisions'] : array()) as $d)
				$res['crowdsec'][] = array('origin' => (string)@$d['origin'], 'scenario' => (string)@$d['scenario'], 'type' => (string)@$d['type'], 'duration' => (string)@$d['duration']);
		}
		foreach(array_slice((array)json_decode(implode("\n", run('cscli alerts list -i '.escapeshellarg($ip).' -o json')), true), 0, 8) as $al) {
			if(is_array($al)) $res['alerts'][] = array('scenario' => (string)@$al['scenario'], 'at' => (string)@$al['created_at'], 'events' => (int)@$al['events_count']);
		}
	}
	if($have_f2b) {
		$o = implode(' ', run('fail2ban-client banned '.escapeshellarg($ip)));
		if(preg_match_all("/'([A-Za-z0-9_.-]+)'/", $o, $m)) $res['fail2ban'] = array_values(array_unique($m[1]));
	}
	$ub = @$app->db->queryAllRecords("SELECT target, comment, active FROM ufw_block");
	if(is_array($ub)) foreach($ub as $u) if(tr_in($ip, $u['target'])) $res['ufw_block'][] = $u['target'].($u['active'] === 'y' ? '' : ' (выключено)').($u['comment'] ? ' — '.$u['comment'] : '');
	$app->db->query("UPDATE ss_trusted_job SET status = 'done', result = ?, processed = NOW() WHERE id = ?", json_encode($res, JSON_UNESCAPED_UNICODE), (int)$job['id']);
}
$app->db->query("DELETE FROM ss_trusted_job WHERE processed IS NOT NULL AND processed < (NOW() - INTERVAL 7 DAY)");

flock($lock, LOCK_UN);
exit(0);
