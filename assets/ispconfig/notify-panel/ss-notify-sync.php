<?php
/*
  LuckyStack: синхронизатор уведомлений ↔ панель ISPConfig (root-cron, раз в минуту).

  Интерфейс (ispconfig) не может ни читать /etc/server-notify.conf (root 600), ни слать тест
  (нужен root/MTA). Поэтому: панель пишет запрос в очередь notify_job, этот скрипт (root) его
  выполняет и обновляет кэш настроек notify_setting — БЕЗ секретов (токен не кэшируем, только
  флаг «задан»). Задания:
    save     — проверить и записать настройки (каналы, события, тихие часы, пороги);
    test     — отправить пробное сообщение через server-notify.sh;
    discover — найти чаты, которые писали боту (getUpdates без подтверждения, а если запущен бот
               server-tg-bot — из его списка /var/lib/server-notify/chats.json).
  Помощник /usr/local/sbin/server-notify.sh шлёт по настроенным каналам.
*/

$conf = array();
require '/usr/local/ispconfig/server/lib/config.inc.php';
require '/usr/local/ispconfig/server/lib/app.inc.php';
if(!function_exists('exec')) exit(1);

$lock = @fopen('/run/ss-notify-sync.lock', 'c');
if($lock === false) $lock = @fopen(sys_get_temp_dir().'/ss-notify-sync.lock', 'c');
if($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) exit(0);

$CONF   = '/etc/server-notify.conf';
$HELPER = '/usr/local/sbin/server-notify.sh';
$CHATS_FILE = '/var/lib/server-notify/chats.json';
$EVENTS = array('monitor', 'backup', 'malware', 'login', 'digest');

// прочитать conf в массив KEY=>value (порядок ключей сохраняется)
function nn_read($file) {
	$o = array();
	if(is_file($file)) foreach(file($file) as $l) {
		if(preg_match("/^\s*([A-Z_][A-Z0-9_]*)=(.*)$/", $l, $m)) $o[$m[1]] = trim(trim($m[2]), "'\"");
	}
	return $o;
}
// записать conf из массива (значения в одинарных кавычках, кавычки внутри вырезаем)
function nn_write($file, $kv) {
	$s = "# LuckyStack — настройки уведомлений. Правятся в панели ISPConfig (System → Дополнения → Уведомления) или вручную.\n";
	foreach($kv as $k => $v) $s .= $k."='".str_replace("'", "", (string)$v)."'\n";
	$tmp = $file.'.tmp';
	@file_put_contents($tmp, $s); @chmod($tmp, 0600); @rename($tmp, $file);
}
function nn_chats($cf) {   // список chat id (новый ключ + старый одиночный)
	$all = trim((isset($cf['NOTIFY_TG_CHATS']) ? $cf['NOTIFY_TG_CHATS'] : '').' '.(isset($cf['NOTIFY_TG_CHAT']) ? $cf['NOTIFY_TG_CHAT'] : ''));
	$out = array();
	foreach(preg_split('/[\s,;]+/', $all, -1, PREG_SPLIT_NO_EMPTY) as $c) if(preg_match('/^-?[0-9]+$/', $c)) $out[$c] = true;
	return array_keys($out);
}
function nn_api($cf) { return (isset($cf['NOTIFY_TG_API']) && preg_match('#^https?://[A-Za-z0-9.:\-]+$#', $cf['NOTIFY_TG_API'])) ? $cf['NOTIFY_TG_API'] : 'https://api.telegram.org'; }

// --- 1) кэш настроек (без токена) ---
$cf = nn_read($CONF);
$email  = isset($cf['NOTIFY_EMAIL']) ? $cf['NOTIFY_EMAIL'] : '';
$chats  = nn_chats($cf);
$tgtok  = isset($cf['NOTIFY_TG_TOKEN']) ? $cf['NOTIFY_TG_TOKEN'] : '';
$mta = (trim((string)shell_exec('command -v sendmail 2>/dev/null; command -v mail 2>/dev/null')) !== '') ? 'y' : 'n';
$set = array(
	'email'          => $email,
	'from'           => isset($cf['NOTIFY_FROM']) ? $cf['NOTIFY_FROM'] : '',
	'tg_chats'       => implode(' ', $chats),
	'tg_configured'  => ($tgtok !== '') ? 'y' : 'n',
	'events'         => isset($cf['NOTIFY_EVENTS']) ? $cf['NOTIFY_EVENTS'] : 'monitor backup malware login',
	'login_mode'     => isset($cf['NOTIFY_LOGIN_MODE']) ? $cf['NOTIFY_LOGIN_MODE'] : 'new',
	'quiet'          => isset($cf['NOTIFY_QUIET']) ? $cf['NOTIFY_QUIET'] : '',
	'disk'           => isset($cf['MON_DISK_PCT']) ? $cf['MON_DISK_PCT'] : '90',
	'cert'           => isset($cf['MON_CERT_DAYS']) ? $cf['MON_CERT_DAYS'] : '14',
	'backup'         => isset($cf['MON_BACKUP_DAYS']) ? $cf['MON_BACKUP_DAYS'] : '2',
	'helper_present' => is_file($HELPER) ? 'y' : 'n',
	'mta_present'    => $mta,
	'active'         => (($email !== '' && $mta === 'y') || ($tgtok !== '' && !empty($chats))) ? 'y' : 'n',
	'bot'            => (isset($cf['NOTIFY_TG_BOT']) && $cf['NOTIFY_TG_BOT'] === 'y') ? 'y' : 'n',
	'bot_active'     => (trim((string)shell_exec('systemctl is-active server-tg-bot 2>/dev/null')) === 'active') ? 'y' : 'n',
);
foreach($set as $k => $v) $app->db->query("REPLACE INTO notify_setting (name, value, updated) VALUES (?,?,NOW())", $k, (string)$v);

// --- 2) выполнить ОДНУ задачу ---
$job = $app->db->queryOneRecord("SELECT * FROM notify_job WHERE status='pending' ORDER BY id ASC LIMIT 1");
if(is_array($job) && !empty($job)) {
	$id = (int)$job['id']; $act = (string)$job['action'];
	$fail = function($m) use ($app,$id){ $app->db->query("UPDATE notify_job SET status='error', result=?, processed=NOW() WHERE id=?", substr($m,0,1000), $id); };
	$done = function($m) use ($app,$id){ $app->db->query("UPDATE notify_job SET status='done', result=?, processed=NOW() WHERE id=?", substr($m,0,1000), $id); };

	if($act === 'save') {
		$p = json_decode((string)$job['payload'], true); if(!is_array($p)) $p = array();
		$emails = array();
		foreach(preg_split('/[\s,;]+/', isset($p['email']) ? $p['email'] : '', -1, PREG_SPLIT_NO_EMPTY) as $e) $emails[] = $e;
		$nchats = preg_split('/[\s,;]+/', isset($p['tg_chats']) ? $p['tg_chats'] : '', -1, PREG_SPLIT_NO_EMPTY);
		$ntok   = isset($p['tg_token']) ? trim($p['tg_token']) : '';   // пусто = не менять
		$nev    = array_values(array_intersect($EVENTS, preg_split('/\s+/', isset($p['events']) ? $p['events'] : '', -1, PREG_SPLIT_NO_EMPTY)));
		$nlm    = isset($p['login_mode']) ? $p['login_mode'] : 'new';
		$nq     = isset($p['quiet']) ? trim($p['quiet']) : '';
		$disk   = isset($p['disk']) ? trim($p['disk']) : ''; $cert = isset($p['cert']) ? trim($p['cert']) : ''; $bk = isset($p['backup']) ? trim($p['backup']) : '';
		$err = '';
		foreach($emails as $e) if(!filter_var($e, FILTER_VALIDATE_EMAIL)) { $err = 'некорректный email: '.$e; break; }
		if($err === '') foreach($nchats as $c) if(!preg_match('/^-?[0-9]{1,20}$/', $c)) { $err = 'chat id — только цифры (у групп с минусом): '.$c; break; }
		if($err === '' && $ntok !== '' && !preg_match('#^[0-9]+:[A-Za-z0-9_-]+$#', $ntok)) $err = 'некорректный токен бота';
		if($err === '' && !in_array($nlm, array('new', 'all'), true)) $err = 'некорректный режим входов';
		if($err === '' && $nq !== '' && !preg_match('/^([01]?[0-9]|2[0-3]):[0-5][0-9]-([01]?[0-9]|2[0-3]):[0-5][0-9]$/', $nq)) $err = 'тихие часы: нужно ЧЧ:ММ — ЧЧ:ММ или пусто';
		if($err === '' && (!ctype_digit($disk) || (int)$disk < 50 || (int)$disk > 99)) $err = 'порог диска: число 50–99';
		if($err === '' && (!ctype_digit($cert) || (int)$cert < 1 || (int)$cert > 60)) $err = 'порог сертификата: число 1–60';
		if($err === '' && (!ctype_digit($bk) || (int)$bk < 1 || (int)$bk > 30)) $err = 'порог бэкапа: число 1–30';
		if($err !== '') { $fail($err); }
		else {
			$cur = nn_read($CONF);
			// Отправитель на DKIM-подписанном домене (SPF+DKIM+DMARC) — иначе mail.ru и пр. режут
			// как спам (root@<хост> без SPF/DKIM). Уважаем заданный вручную; иначе первый active+dkim.
			$nfrom = isset($cur['NOTIFY_FROM']) ? trim($cur['NOTIFY_FROM']) : '';
			if($nfrom === '') {
				$md = $app->db->queryOneRecord("SELECT domain FROM mail_domain WHERE active='y' AND dkim='y' ORDER BY domain LIMIT 1");
				if(is_array($md) && !empty($md['domain'])) $nfrom = 'noreply@'.$md['domain'];
			}
			$kv = array(
				'NOTIFY_EMAIL'      => implode(', ', $emails),
				'NOTIFY_FROM'       => $nfrom,
				'NOTIFY_TG_TOKEN'   => ($ntok !== '') ? $ntok : (isset($cur['NOTIFY_TG_TOKEN']) ? $cur['NOTIFY_TG_TOKEN'] : ''),
				'NOTIFY_TG_CHATS'   => implode(' ', array_unique($nchats)),
				'NOTIFY_EVENTS'     => implode(' ', $nev),
				'NOTIFY_LOGIN_MODE' => $nlm,
				'NOTIFY_QUIET'      => $nq,
				'MON_DISK_PCT'      => (int)$disk,
				'MON_CERT_DAYS'     => (int)$cert,
				'MON_BACKUP_DAYS'   => (int)$bk,
				'NOTIFY_TG_BOT'     => (isset($p['bot']) && $p['bot'] === 'y') ? 'y' : 'n',
			);
			// прочие ключи (NOTIFY_TG_API, настройки бота и т.п.) сохраняем; старый одиночный чат убираем
			foreach($cur as $k => $v) if(!isset($kv[$k]) && $k !== 'NOTIFY_TG_CHAT' && $k !== 'MON_SERVICES') $kv[$k] = $v;
			nn_write($CONF, $kv);
			// бот: включить/выключить службу по галочке (служба сама перечитывает конфиг)
			if(is_file('/etc/systemd/system/server-tg-bot.service')) {
				if($kv['NOTIFY_TG_BOT'] === 'y') exec('systemctl enable server-tg-bot >/dev/null 2>&1; systemctl restart server-tg-bot >/dev/null 2>&1');
				else exec('systemctl disable --now server-tg-bot >/dev/null 2>&1');
			}
			$done('настройки сохранены');
		}
	} elseif($act === 'test') {
		if(!is_file($HELPER)) $fail('server-notify.sh не установлен');
		else {
			$app->db->query("UPDATE notify_job SET status='running', processed=NOW() WHERE id=?", $id);
			$o=array(); $rc=0;
			exec(escapeshellarg($HELPER).' -l crit '.escapeshellarg('Тест уведомления').' '.escapeshellarg('Проверка канала из панели ISPConfig.').' 2>&1', $o, $rc);
			$app->db->query("UPDATE notify_job SET status=?, result=?, processed=NOW() WHERE id=?",
				($rc===0?'done':'error'), ($rc===0?'отправлено':('не отправлено: '.substr(trim(implode(' ',$o)),0,200))), $id);
		}
	} elseif($act === 'discover') {
		$cur = nn_read($CONF);
		$tok = isset($cur['NOTIFY_TG_TOKEN']) ? $cur['NOTIFY_TG_TOKEN'] : '';
		if($tok === '') { $fail('сначала задайте и сохраните токен бота'); }
		else {
			$found = array();
			// если работает бот (этап управления из Telegram), он сам копит список чатов
			$jf = @json_decode((string)@file_get_contents($CHATS_FILE), true);
			if(is_array($jf)) foreach($jf as $c) if(isset($c['id'])) $found[(string)$c['id']] = $c;
			// Если бот запущен, getUpdates трогать нельзя: Telegram отдаёт обновления только одному
			// получателю и ответит конфликтом. Тогда берём только список, который копит сам бот.
			$bot_running = (trim((string)shell_exec('systemctl is-active server-tg-bot 2>/dev/null')) === 'active');
			// getUpdates без offset: обновления не подтверждаются, бот (если его включат) их тоже увидит
			$ch = curl_init(nn_api($cur).'/bot'.$tok.'/getUpdates?limit=100&timeout=0');
			if($bot_running) { curl_close($ch); $ch = null; }
			$r = null;
			if($ch) { curl_setopt_array($ch, array(CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 20));
				$r = json_decode((string)curl_exec($ch), true); curl_close($ch); }
			if(is_array($r) && !empty($r['ok']) && is_array($r['result'])) {
				foreach($r['result'] as $u) {
					$m = isset($u['message']) ? $u['message'] : (isset($u['my_chat_member']) ? $u['my_chat_member'] : (isset($u['channel_post']) ? $u['channel_post'] : null));
					if(!is_array($m) || !isset($m['chat']['id'])) continue;
					$c = $m['chat'];
					$parts = array();
					foreach(array('title', 'first_name', 'last_name') as $f) if(!empty($c[$f])) $parts[] = $c[$f];
					if(!empty($c['username'])) $parts[] = '@'.$c['username'];
					$name = implode(' ', $parts);
					$found[(string)$c['id']] = array('id' => (string)$c['id'], 'type' => isset($c['type']) ? $c['type'] : '', 'name' => $name, 'date' => isset($m['date']) ? date('Y-m-d H:i', (int)$m['date']) : '');
				}
			} elseif(!is_array($jf) && !$bot_running) {
				$fail('Telegram не ответил: '.(is_array($r) && isset($r['description']) ? $r['description'] : 'нет связи или неверный токен'));
				$found = null;
			}
			if($found !== null) {
				$app->db->query("REPLACE INTO notify_setting (name, value, updated) VALUES ('discovered', ?, NOW())", json_encode(array_slice(array_values($found), -10), JSON_UNESCAPED_UNICODE));
				$done('найдено чатов: '.count($found));
			}
		}
	}
}

// В payload задания save лежит токен бота открытым текстом. После выполнения он не нужен:
// затираем сразу (и в старых заданиях тоже), чтобы секрет не жил в БД панели.
$app->db->query("UPDATE notify_job SET payload = NULL WHERE status IN ('done','error') AND payload IS NOT NULL");
$app->db->query("DELETE FROM notify_job WHERE status IN ('done','error') AND processed < (NOW() - INTERVAL 7 DAY)");
flock($lock, LOCK_UN);
exit(0);
?>
