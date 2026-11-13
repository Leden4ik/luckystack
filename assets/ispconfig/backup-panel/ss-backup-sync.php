<?php
/*
  LuckyStack: синхронизатор бэкапов ↔ панель ISPConfig (root-cron, раз в минуту).

  Интерфейс ISPConfig (непривилегированный пользователь) не может ни читать каталог
  снимков (/var/backups/server, root 700), ни запускать восстановление (нужен root).
  Поэтому:
    1) панель пишет запрос восстановления в очередь backup_restore (status='pending');
    2) этот скрипт (root) обновляет кэш списка снимков (таблица backup_snapshot) и
       выполняет ОДИН ожидающий restore через /usr/local/sbin/server-backup.sh --restore.

  Восстановление НЕОБРАТИМО. Имя снимка и компоненты валидируются здесь же (whitelist).
  flock — чтобы длинный restore не запускался повторно следующим тиком cron.
*/

$conf = array();
require '/usr/local/ispconfig/server/lib/config.inc.php';
require '/usr/local/ispconfig/server/lib/app.inc.php';

if(!function_exists('exec')) exit(1);

// блокировка от наложения (restore может идти минуты)
// Можно ли использовать каталог под бэкапы. Ниже по нему делается chmod 700, а server-backup.sh
// чистит в нём старые снимки, поэтому системные каталоги, сайты, почта и корни вроде /var или /mnt
// запрещены. Правила те же, что в установщике (lib/backup.sh) и в самом server-backup.sh.
function bk_dir_ok($d) {
	$d = rtrim((string)$d, '/');
	if(!preg_match('#^/[A-Za-z0-9._/-]+$#', $d) || strpos($d, '..') !== false || strpos($d, '//') !== false) return false;
	$exact = array('/bin','/boot','/dev','/etc','/home','/lib','/lib32','/lib64','/media','/mnt','/opt','/proc','/root','/run','/sbin',
		'/srv','/sys','/tmp','/usr','/usr/local','/var','/var/backups','/var/cache','/var/lib','/var/log','/var/mail','/var/spool',
		'/var/tmp','/var/www','/var/vmail');
	if(in_array($d, $exact, true)) return false;
	foreach(array('/bin/','/boot/','/dev/','/etc/','/lib/','/lib32/','/lib64/','/proc/','/run/','/sbin/','/sys/','/tmp/','/usr/',
		'/var/cache/','/var/lib/','/var/log/','/var/mail/','/var/spool/','/var/tmp/','/var/www/','/var/vmail/') as $p) {
		if(strpos($d, $p) === 0) return false;
	}
	return true;
}

$lock = @fopen('/run/ss-backup-sync.lock', 'c');
if($lock === false) $lock = @fopen(sys_get_temp_dir().'/ss-backup-sync.lock', 'c');
if($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) exit(0);

$BKDIR  = '/var/backups/server';
$SCRIPT = '/usr/local/sbin/server-backup.sh';
if(is_file('/etc/server-backup.conf')) {
	foreach(file('/etc/server-backup.conf') as $l) {
		if(preg_match('/^\s*BACKUP_DIR=(.*)$/', $l, $m)) $BKDIR = trim(trim($m[1]), "'\"");
	}
}
$ALLOWED = array('db','etc','ispconfig','www','vmail');

// --- 1) обновить кэш списка снимков ---------------------------------------------------
$app->db->query("DELETE FROM backup_snapshot");
$dirs = glob(rtrim($BKDIR, '/').'/*', GLOB_ONLYDIR);
if(is_array($dirs)) {
	foreach($dirs as $d) {
		$snap = basename($d);
		if(!preg_match('/^[0-9]{8}-[0-9]{6}$/', $snap)) continue;
		$size = @file_get_contents($d.'/.size'); $size = $size !== false ? trim($size) : '?';
		$comp = array();
		if(glob($d.'/mysql/*.sql.gz'))     $comp[] = 'db';
		if(is_file($d.'/etc.tar.gz'))       $comp[] = 'etc';
		if(is_file($d.'/ispconfig.tar.gz')) $comp[] = 'ispconfig';
		if(is_file($d.'/www.tar.gz'))       $comp[] = 'www';
		if(is_file($d.'/vmail.tar.gz'))     $comp[] = 'vmail';
		$app->db->query("INSERT INTO backup_snapshot (snapshot, size, components, created) VALUES (?,?,?,NOW())",
			$snap, substr($size, 0, 32), implode(',', $comp));
	}
}

// --- 1b) кэш НАСТРОЕК бэкапа (conf + состояние таймера + последний снимок) — их читает страница ---
$cf = array();
if(is_file('/etc/server-backup.conf')) foreach(file('/etc/server-backup.conf') as $l) {
	if(preg_match('/^\s*([A-Z_]+)=(.*)$/', $l, $m)) $cf[$m[1]] = trim(trim($m[2]), "'\"");
}
$timer_on = (trim((string)shell_exec('systemctl is-enabled server-backup.timer 2>/dev/null')) === 'enabled') ? 'y' : 'n';
$last = $app->db->queryOneRecord("SELECT snapshot, size FROM backup_snapshot ORDER BY snapshot DESC LIMIT 1");
$G = function($k,$d='') use ($cf){ return isset($cf[$k]) ? $cf[$k] : $d; };
$set = array(
	'backup_dir'     => $G('BACKUP_DIR', $BKDIR),
	'retention'      => $G('BACKUP_RETENTION_DAYS','7'),
	'time'           => $G('BACKUP_TIME','03:30'),
	'include_www'    => $G('BACKUP_INCLUDE_WWW','n'),
	'include_mail'   => $G('BACKUP_INCLUDE_MAIL','n'),
	'remote_type'    => $G('BACKUP_REMOTE_TYPE','none'),
	'remote'         => $G('BACKUP_REMOTE',''),
	'timer_enabled'  => $timer_on,
	'script_present' => is_file($SCRIPT) ? 'y' : 'n',
	'last_snapshot'  => is_array($last) ? (string)$last['snapshot'] : '',
	'last_size'      => is_array($last) ? (string)$last['size'] : '',
);
$app->db->query("DELETE FROM backup_setting");
foreach($set as $k => $v) $app->db->query("INSERT INTO backup_setting (name, value, updated) VALUES (?,?,NOW())", $k, substr((string)$v, 0, 255));

// --- 1c) выполнить ОДНУ задачу backup_job (run = бэкап сейчас; config = сохранить настройки+таймер) ---
$bj = $app->db->queryOneRecord("SELECT * FROM backup_job WHERE status='pending' ORDER BY id ASC LIMIT 1");
if(is_array($bj) && !empty($bj)) {
	$bid = (int)$bj['id']; $bact = (string)$bj['action'];
	$bfail = function($m) use ($app,$bid){ $app->db->query("UPDATE backup_job SET status='error', result=?, processed=NOW() WHERE id=?", substr($m,0,2000), $bid); };
	if($bact === 'run') {
		if(!is_file($SCRIPT)) $bfail('server-backup.sh не установлен (прогоните этап backup)');
		else {
			$app->db->query("UPDATE backup_job SET status='running', processed=NOW() WHERE id=?", $bid);
			$o=array(); $rc=0; exec(escapeshellarg($SCRIPT).' 2>&1', $o, $rc);
			$app->db->query("UPDATE backup_job SET status=?, result=?, processed=NOW() WHERE id=?",
				($rc===0?'done':'error'), substr(trim(implode("\n",$o)),-2000), $bid);
		}
	} elseif($bact === 'config') {
		$p = json_decode((string)$bj['payload'], true); if(!is_array($p)) $p = array();
		$dir  = isset($p['backup_dir']) ? trim($p['backup_dir']) : '';
		$ret  = isset($p['retention']) ? trim($p['retention']) : '';
		$tm   = isset($p['time']) ? trim($p['time']) : '';
		$www  = (isset($p['include_www']) && $p['include_www']==='y') ? 'y' : 'n';
		$mail = (isset($p['include_mail']) && $p['include_mail']==='y') ? 'y' : 'n';
		$rt   = (isset($p['remote_type']) && in_array($p['remote_type'],array('none','rsync','rclone'),true)) ? $p['remote_type'] : 'none';
		$rem  = isset($p['remote']) ? trim($p['remote']) : '';
		$tmr  = (isset($p['timer']) && $p['timer']==='y') ? 'y' : 'n';
		if(!bk_dir_ok($dir))                                            $bfail('каталог не подходит: системный, сайты или почта (нужен отдельный, например /var/backups/server)');
		elseif(!preg_match('/^[0-9]{1,4}$/', $ret) || (int)$ret < 1)   $bfail('некорректное число дней');
		elseif(!preg_match('/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/', $tm)) $bfail('некорректное время (ЧЧ:ММ)');
		elseif($rem !== '' && !preg_match('#^[A-Za-z0-9@._:/ -]+$#', $rem)) $bfail('некорректная удалёнка');
		else {
			$app->db->query("UPDATE backup_job SET status='running', processed=NOW() WHERE id=?", $bid);
			@mkdir($dir, 0700, true); @chmod($dir, 0700);
			$conf = "# LuckyStack — настройки серверного бэкапа (правится из панели ISPConfig).\n"
				."BACKUP_DIR=".$dir."\nBACKUP_RETENTION_DAYS=".$ret."\nBACKUP_INCLUDE_WWW=".$www."\nBACKUP_INCLUDE_MAIL=".$mail."\n"
				."BACKUP_TIME=".$tm."\nBACKUP_REMOTE_TYPE=".$rt."\nBACKUP_REMOTE='".$rem."'\n";
			// сохранить прочие BACKUP_REMOTE_* (ключи/порт rclone-sftp), если были — не теряем
			foreach($cf as $k=>$v){ if(preg_match('/^BACKUP_REMOTE_(SSHPORT|SSHKEY|OPTS|RCLONE_)/',$k) || strpos($k,'BACKUP_RCLONE_')===0) $conf .= $k."='".$v."'\n"; }
			@file_put_contents('/etc/server-backup.conf', $conf); @chmod('/etc/server-backup.conf', 0600);
			// systemd service + timer (OnCalendar из времени), вкл/выкл по флагу
			@file_put_contents('/etc/systemd/system/server-backup.service',
				"[Unit]\nDescription=Server backup (databases + configs)\nAfter=mariadb.service\n\n[Service]\nType=oneshot\nExecStart=".$SCRIPT."\nNice=10\nIOSchedulingClass=best-effort\n");
			@file_put_contents('/etc/systemd/system/server-backup.timer',
				"[Unit]\nDescription=Daily server backup\n\n[Timer]\nOnCalendar=*-*-* ".$tm.":00\nPersistent=true\nRandomizedDelaySec=300\n\n[Install]\nWantedBy=timers.target\n");
			exec('systemctl daemon-reload 2>&1');
			if($tmr === 'y') exec('systemctl enable --now server-backup.timer 2>&1', $o1, $r1);
			else             exec('systemctl disable --now server-backup.timer 2>&1');
			$app->db->query("UPDATE backup_job SET status='done', result='настройки сохранены; таймер: ".($tmr==='y'?'вкл':'выкл')."', processed=NOW() WHERE id=?", $bid);
		}
	}
}

// --- 2) выполнить ОДИН ожидающий restore ----------------------------------------------
// не начинать новый, если какой-то уже выполняется (страховка помимо flock)
$running = $app->db->queryOneRecord("SELECT id FROM backup_restore WHERE status = 'running' LIMIT 1");
if(!is_array($running) || empty($running)) {
	$job = $app->db->queryOneRecord("SELECT id, snapshot, components FROM backup_restore WHERE status = 'pending' ORDER BY id ASC LIMIT 1");
	if(is_array($job) && !empty($job)) {
		$snap = (string)$job['snapshot'];
		if(!preg_match('/^[0-9]{8}-[0-9]{6}$/', $snap) || !is_dir($BKDIR.'/'.$snap)) {
			$app->db->query("UPDATE backup_restore SET status='error', result='invalid snapshot', processed=NOW() WHERE id=?", $job['id']);
		} else {
			$flags = array();
			foreach(explode(',', (string)$job['components']) as $c) {
				$c = trim($c);
				if(in_array($c, $ALLOWED, true)) $flags[] = '--'.$c;
			}
			if(empty($flags)) $flags = array('--db'); // по умолчанию — только БД
			$app->db->query("UPDATE backup_restore SET status='running', processed=NOW() WHERE id=?", $job['id']);
			$cmd = escapeshellarg($SCRIPT).' --restore '.escapeshellarg($snap).' '.implode(' ', $flags).' --yes 2>&1';
			$out = array(); $rc = 0;
			exec($cmd, $out, $rc);
			$res = trim(implode("\n", $out));
			$app->db->query("UPDATE backup_restore SET status=?, result=?, processed=NOW() WHERE id=?",
				($rc === 0 ? 'done' : 'error'), substr($res, -255), $job['id']);
		}
	}
}

// подчистить старые завершённые задачи (>14 дней)
$app->db->query("DELETE FROM backup_restore WHERE status IN ('done','error') AND processed < (NOW() - INTERVAL 14 DAY)");
$app->db->query("DELETE FROM backup_job WHERE status IN ('done','error') AND processed < (NOW() - INTERVAL 14 DAY)");

flock($lock, LOCK_UN);
exit(0);
?>
