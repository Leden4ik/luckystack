<?php
/*
  LuckyStack: панель «Обслуживание сервера» ↔ установщик (root-cron, раз в минуту).

  Интерфейс ISPConfig работает не от root, поэтому панель только пишет задание в ss_maint_job,
  а этот скрипт его проверяет и выполняет. Панель не передаёт команды: только название действия,
  пункты обновления и настройки из списков ниже. Всё, чего нет в списках, отклоняется здесь,
  даже если страницу обошли.

  Перед запуском установщика проверяется, что его файлы принадлежат root и не открыты на запись
  группе и всем: иначе взломанный сайт мог бы подменить скрипт, а этот cron запустил бы его от root.

  Задания:
    refresh     — обновить сведения о сервере и проверки;
    healthcheck — запустить server-setup.sh --healthcheck;
    save        — записать настройки в setup.conf;
    update      — запустить server-setup.sh --update с выбранными пунктами. Идёт отдельной службой
                  systemd, поэтому переживает перезапуск nginx и обновление самой панели. Перед
                  обновлением nginx или ISPConfig сначала делается бэкап: снимков на сервере нет,
                  и если бэкап не удался, обновление не запускается;
    rollback    — вернуть прошлую версию nginx или Roundcube (server-setup.sh --rollback).

  Оповещения идут через server-notify.sh: итог обновления и новые проблемы в проверках.
*/

$conf = array();
require '/usr/local/ispconfig/server/lib/config.inc.php';
require '/usr/local/ispconfig/server/lib/app.inc.php';
if(!function_exists('exec')) exit(1);

// В cron PATH без /usr/sbin: nginx, ufw и postfix не нашлись бы, а проверка сочла бы их не установленными.
putenv('PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin');
putenv('HOME=/root');
putenv('LC_ALL=C.UTF-8');
// app.inc.php ставит пояс из настроек ISPConfig, а панель показывает время сервера.
$_tz = trim((string)@file_get_contents('/etc/timezone'));
if($_tz !== '' && in_array($_tz, timezone_identifiers_list(), true)) date_default_timezone_set($_tz);

$lock = @fopen('/run/ss-maint-sync.lock', 'c');
if($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) exit(0);

$CFG     = '/usr/local/ispconfig/server/scripts/ss-maint.conf';
$LOGDIR  = '/var/log/luckystack/panel';
$PIDFILE = '/run/luckystack-update.pid';
$NOTIFY  = '/usr/local/sbin/server-notify.sh';
$BACKUP  = '/usr/local/sbin/server-backup.sh';
$ROLLBACK_TARGETS = array('nginx', 'roundcube');
$ITEMS_CORE = array('nginx', 'ispconfig');
$RC_BACKUP_FAILED = 90;   // код: бэкап не удался, обновление не запускалось

// Пункты --update, которые можно запускать из панели.
$ITEMS = array('pkgs', 'security', 'confcustom', 'tuning', 'mail', 'certs', 'rcplugins', 'backup', 'notify', 'nginx', 'ispconfig');

// Настройки, которые можно менять из панели: ключ => допустимые значения (первое = по умолчанию,
// как в установщике). Смены пароля SSH здесь намеренно нет: ошибка заперла бы вход на сервер.
$yn = array('y', 'n'); $ny = array('n', 'y');
$SETTINGS = array(
	'OPENSSL_BRANCH'       => array('3.5', '4.1', '4.0'),
	'NGINX_CHANNEL'        => array('stable', 'mainline'),
	'NGX_BROTLI'           => $yn,
	'NGX_ZSTD'             => $yn,
	'NGX_ZLIBNG'           => $yn,
	'NGX_HEADERMOD'        => $yn,
	'NGX_CACHEPURGE'       => $yn,
	'NGX_SETMISC'          => $yn,
	'NGX_VTS'              => $ny,
	'NGX_JEMALLOC'         => $yn,
	'NGX_NATIVE_OPT'       => $ny,
	'NGX_QUIC_GSO'         => $ny,
	'NGX_QUIC_RETRY'       => $ny,
	'NGX_TIGHT_TIMEOUTS'   => $yn,
	'SEC_AUTO_UPDATES_3RD' => $yn,
	'SEC_USERNS_OFF'       => $ny,
	'SEC_SERVICE_HARDEN'   => $ny,
	'SSH_TCP_FORWARD'      => $ny,
	'FTP_TLS_REQUIRED'     => $yn,
	'RC_BRANCH'            => array('1.6', '1.7'),
);

// Модули сборки nginx и директивы конфига, которым они нужны: панель предупредит перед отключением.
$MODULE_USE = array(
	'NGX_BROTLI'     => 'brotli',
	'NGX_ZSTD'       => 'zstd',
	'NGX_HEADERMOD'  => 'more_set_headers|more_clear_headers',
	'NGX_CACHEPURGE' => 'fastcgi_cache_purge|proxy_cache_purge',
	'NGX_SETMISC'    => 'set_escape_uri|set_unescape_uri|set_md5|set_sha1|set_encode_base64|set_decode_base64|set_if_empty',
	'NGX_VTS'        => 'vhost_traffic_status',
);

// Сроки поддержки, проверено 2026-11-06 (php.net, openssl-library.org).
$PHP_EOL_DATES = array('5.6'=>'2018-12-31','7.0'=>'2019-01-10','7.1'=>'2019-12-01','7.2'=>'2020-11-30','7.3'=>'2021-12-06','7.4'=>'2022-11-28',
	'8.0'=>'2023-11-26','8.1'=>'2025-12-31','8.2'=>'2026-12-31','8.3'=>'2027-12-31','8.4'=>'2028-12-31','8.5'=>'2029-12-31');
$OPENSSL_EOL_DATES = array('3.5'=>'2030-04-08','4.0'=>'2027-05-14','4.1'=>'2027-11-23');

function mm_set($k, $v) { global $app; $app->db->query("REPLACE INTO ss_maint_setting (name, value, updated) VALUES (?,?,NOW())", $k, (string)$v); }
function mm_get($k, $d = '') { global $app; $r = $app->db->queryOneRecord("SELECT value FROM ss_maint_setting WHERE name=?", $k); return (is_array($r) && isset($r['value'])) ? $r['value'] : $d; }
function mm_age($k) { global $app; $r = $app->db->queryOneRecord("SELECT TIMESTAMPDIFF(SECOND, updated, NOW()) AS a FROM ss_maint_setting WHERE name=?", $k); return (is_array($r) && isset($r['a'])) ? (int)$r['a'] : PHP_INT_MAX; }
function mm_sh($cmd) { $o = array(); @exec('( '.$cmd.' ) 2>/dev/null', $o); return trim(implode("\n", $o)); }

// Вывод установщика в читаемый текст: без цветов и спиннера, секреты скрыты.
function mm_clean($s) {
	$s = preg_replace('/\x1b\[[0-9;?]*[A-Za-z]/', '', (string)$s);
	$s = str_replace("\r", "\n", $s);
	$s = preg_replace('/\b([A-Z0-9_]*(?:PW|PASS|PASSWORD|SECRET|TOKEN|KEY))=\S+/', '$1=<скрыто>', $s);
	$s = preg_replace("/\n{3,}/", "\n\n", $s);
	return function_exists('mb_scrub') ? mb_scrub($s, 'UTF-8') : $s;
}
function mm_tail($file, $bytes = 60000) {
	if(!is_file($file)) return '';
	$sz = filesize($file);
	$fp = @fopen($file, 'r'); if(!$fp) return '';
	if($sz > $bytes) fseek($fp, $sz - $bytes);
	$d = (string)stream_get_contents($fp); fclose($fp);
	if($sz > $bytes) { $p = strpos($d, "\n"); if($p !== false) $d = substr($d, $p + 1); }
	return mm_clean($d);
}

// Оповещение. Ошибки канала панель не ломают. Событие monitor: «проблемы сервера» в настройках уведомлений.
function mm_notify($level, $subj, $body) {
	global $NOTIFY;
	if(!is_file($NOTIFY)) return;
	@exec(escapeshellarg($NOTIFY).' -e monitor -l '.escapeshellarg($level).' '.escapeshellarg($subj).' '.escapeshellarg($body).' >/dev/null 2>&1');
}

// Новые проблемы по сравнению с прошлым разом. Числа убираем из сравнения, иначе «занято 81%» и
// «занято 82%» считались бы разными проблемами. Первый запуск только запоминает состояние.
function mm_alerts() {
	$now = array();
	$add = function($c) use (&$now) { if(is_array($c) && isset($c[0], $c[1]) && $c[0] !== 'ok') $now[preg_replace('/[0-9]+/', '#', $c[1])] = $c; };
	foreach((array)json_decode(mm_get('checks', '[]'), true) as $c) $add($c);
	$hc = json_decode(mm_get('health', '{}'), true);
	if(is_array($hc) && !empty($hc['groups'])) foreach($hc['groups'] as $rows) foreach($rows as $c) $add($c);
	$raw = mm_get('alert_state', '');
	$keys = array_keys($now);
	if($raw === '') { mm_set('alert_state', json_encode($keys, JSON_UNESCAPED_UNICODE)); return; }
	$prev = json_decode($raw, true); if(!is_array($prev)) $prev = array();
	$new = array_diff($keys, $prev);
	if($new) {
		$lines = array(); $level = 'warn';
		foreach($new as $k) { $lines[] = ($now[$k][0] === 'fail' ? 'ОШИБКА: ' : 'Внимание: ').$now[$k][1]; if($now[$k][0] === 'fail') $level = 'crit'; }
		mm_notify($level, 'Новые проблемы на сервере: '.count($new), implode("\n", $lines));
	}
	mm_set('alert_state', json_encode($keys, JSON_UNESCAPED_UNICODE));
}

// Где установщик, его настройки и журнал (ss-maint.conf пишет установщик), и можно ли ему доверять.
function mm_paths() {
	global $CFG;
	$o = array('dir' => '', 'conf' => '', 'log' => '');
	if(!is_file($CFG) || fileowner($CFG) !== 0) return $o;
	foreach(file($CFG) as $l) {
		if(preg_match("/^INSTALLER_DIR='([^']+)'\s*$/", $l, $m)) $o['dir'] = $m[1];
		elseif(preg_match("/^SETUP_CONF='([^']+)'\s*$/", $l, $m)) $o['conf'] = $m[1];
		elseif(preg_match("/^SETUP_LOG='([^']+)'\s*$/", $l, $m)) $o['log'] = $m[1];
	}
	return $o;
}
function mm_installer_dir() { $p = mm_paths(); return $p['dir']; }
function mm_setup_conf() { $p = mm_paths(); return $p['conf']; }
function mm_setup_log() { $p = mm_paths(); return $p['log']; }
function mm_unsafe($path) { clearstatcache(true, $path); $p = @fileperms($path); return ($p === false || @fileowner($path) !== 0 || ($p & 0022)); }
function mm_unsafe_parent($path) {
	for($d = dirname($path); $d !== '/' && $d !== '.'; $d = dirname($d)) if(mm_unsafe($d)) return $d;
	return '';
}
function mm_installer_problem($dir) {
	if($dir === '' || $dir[0] !== '/') return 'каталог установщика не задан';
	if(!is_file($dir.'/server-setup.sh')) return 'не найден '.$dir.'/server-setup.sh';
	$conf = mm_setup_conf();
	if($conf === '' || $conf[0] !== '/' || !is_file($conf)) return 'нет setup.conf: сервер настраивался не этим установщиком';
	$check = array($dir, $dir.'/server-setup.sh', $dir.'/lib', $dir.'/assets', $conf);
	foreach((array)glob($dir.'/lib/*') as $f) $check[] = $f;
	foreach($check as $f) if(mm_unsafe($f)) return 'небезопасные права или владелец: '.$f;
	// и путь по ссылке (/opt/luckystack/current), и настоящий каталог выпуска за ней, и каталог настроек
	$real = realpath($dir);
	foreach(array($dir, ($real === false) ? $dir : $real.'/x', $conf) as $p) {
		$bad = mm_unsafe_parent($p);
		if($bad !== '') return 'небезопасные права или владелец: '.$bad;
	}
	return '';
}
function mm_conf_read($file) {
	$o = array();
	if(is_file($file)) foreach(file($file) as $l) if(preg_match('/^([A-Z_][A-Z0-9_]*)=(.*)$/', rtrim($l, "\r\n"), $m)) $o[$m[1]] = trim($m[2], "'\"");
	return $o;
}

// Идёт ли установщик сейчас (из терминала или из панели).
function mm_installer_running() {
	global $PIDFILE;
	$p = (int)@file_get_contents($PIDFILE);
	if($p > 1 && is_file('/proc/'.$p.'/cmdline') && strpos((string)@file_get_contents('/proc/'.$p.'/cmdline'), 'server-setup') !== false) return true;
	return mm_sh("pgrep -f '^(/usr)?(/bin/)?bash [^ ]*server-setup\\.sh'") !== '';
}

// --- Сведения о сервере ------------------------------------------------------
function mm_collect() {
	global $app, $SETTINGS, $MODULE_USE, $PHP_EOL_DATES, $OPENSSL_EOL_DATES, $PIDFILE;
	$dir = mm_installer_dir();
	$prob = mm_installer_problem($dir);
	mm_set('installer_dir', $dir);
	mm_set('installer_problem', $prob);
	mm_set('installer_date', ($dir !== '' && is_file($dir.'/server-setup.sh')) ? date('Y-m-d H:i', filemtime($dir.'/server-setup.sh')) : '');

	$v = array();
	// версия LuckyStack из рабочего выпуска (VERSION="…" в server-setup.sh)
	$v['luckystack'] = ($dir !== '' && is_file($dir.'/server-setup.sh')
		&& preg_match('/^VERSION="([^"]+)"/m', (string)file_get_contents($dir.'/server-setup.sh'), $m)) ? $m[1] : '';
	$v['os'] =mm_sh(". /etc/os-release; echo \"\$PRETTY_NAME\"");
	$v['kernel'] = mm_sh('uname -r');
	$nv = mm_sh('nginx -V 2>&1');
	$v['nginx'] = preg_match('#nginx/([0-9.]+)#', $nv, $m) ? $m[1] : '';
	$ossl = preg_match('/built with OpenSSL ([0-9.]+)/', $nv, $m) ? $m[1] : '';
	$v['openssl'] = $ossl;
	$v['mariadb'] = mm_sh("mariadb --version | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+-MariaDB' | head -1");
	$r = $app->db->queryOneRecord("SELECT dbversion FROM server ORDER BY server_id LIMIT 1");
	$v['ispconfig'] = (defined('ISPC_APP_VERSION') ? ISPC_APP_VERSION : '').(is_array($r) ? ' (БД '.$r['dbversion'].')' : '');
	$v['roundcube'] = mm_sh("grep -oP \"RCMAIL_VERSION.,\\s*.\\K[^'\\\"]+\" /opt/roundcube/program/include/iniset.php /usr/share/roundcube/program/include/iniset.php | head -1 | cut -d: -f2");
	$v['php'] = implode(', ', array_map('basename', array_filter((array)glob('/etc/php/*'), 'is_dir')));
	$v['php_default'] = mm_sh("php -r 'echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;'");
	$v['uptime'] = mm_sh('uptime -p');
	mm_set('versions', json_encode($v, JSON_UNESCAPED_UNICODE));

	// текущие значения настроек (только разрешённые ключи, секреты сюда не попадают)
	$cf = ($dir !== '') ? mm_conf_read(mm_setup_conf()) : array();
	$cur = array();
	foreach($SETTINGS as $k => $vals) $cur[$k] = (isset($cf[$k]) && in_array($cf[$k], $vals, true)) ? $cf[$k] : $vals[0];
	mm_set('cfg', json_encode($cur));

	// что можно откатить
	$rb = array();
	if(is_file('/usr/sbin/nginx.backup') && is_executable('/usr/sbin/nginx.backup') && md5_file('/usr/sbin/nginx.backup') !== md5_file('/usr/sbin/nginx')) {
		$bv = mm_sh('/usr/sbin/nginx.backup -V 2>&1');
		$rb['nginx'] = (preg_match('#nginx/([0-9.]+)#', $bv, $m) ? $m[1] : '?').(preg_match('/built with OpenSSL ([0-9.]+)/', $bv, $m) ? ', OpenSSL '.$m[1] : '').' ('.date('Y-m-d H:i', filemtime('/usr/sbin/nginx.backup')).')';
	}
	$rcp = '/opt/roundcube.prev/program/include/iniset.php';
	if(is_file($rcp) && preg_match("/RCMAIL_VERSION'?,\s*'([0-9.a-z-]+)'/", (string)file_get_contents($rcp), $m)) $rb['roundcube'] = $m[1].' ('.date('Y-m-d H:i', filemtime('/opt/roundcube.prev')).')';
	mm_set('rollback', json_encode($rb, JSON_UNESCAPED_UNICODE));

	// какие модули реально используются в конфиге nginx
	$ngx = mm_sh('nginx -T');
	$used = array();
	foreach($MODULE_USE as $k => $re) $used[$k] = preg_match('/^\s*('.$re.')\b/m', $ngx) ? 'y' : 'n';
	mm_set('module_used', json_encode($used));

	// --- проверки сверх --healthcheck ---
	$c = array();
	$add = function($lvl, $txt) use (&$c) { $c[] = array($lvl, $txt); };
	$today = time();
	$due = function($date) use ($today) { return (int)floor((strtotime($date) - $today) / 86400); };

	if($prob !== '') $add('fail', 'Установщик: '.$prob);

	$cols = $app->db->queryAllRecords("SHOW COLUMNS FROM sys_user LIKE 'otp_type'");
	if(!empty($cols)) {
		$no = array();
		foreach((array)$app->db->queryAllRecords("SELECT username, otp_type FROM sys_user WHERE typ='admin' AND active='1'") as $u)
			if($u['otp_type'] === '' || $u['otp_type'] === 'none' || $u['otp_type'] === null) $no[] = $u['username'];
		if($no) $add('warn', 'Нет двухфакторного входа у администраторов: '.implode(', ', $no).'. Включается в Tools → User Settings');
		else $add('ok', 'Двухфакторный вход у администраторов включён');
	}
	$sec = @parse_ini_file('/usr/local/ispconfig/security/security_settings.ini');
	if(is_array($sec) && isset($sec['security_admin_email'])) {
		mm_set('sec_email', $sec['security_admin_email']);
		if(in_array($sec['security_admin_email'], array('', 'root@localhost'), true)) $add('warn', 'Письма о безопасности ISPConfig уходят на '.($sec['security_admin_email'] ?: '(пусто)').', их никто не читает');
		else $add('ok', 'Письма о безопасности ISPConfig уходят на '.$sec['security_admin_email']);
	}

	// PHP с истёкшей поддержкой по сайтам
	$names = array();
	foreach((array)$app->db->queryAllRecords("SELECT server_php_id, name FROM server_php") as $p) $names[(int)$p['server_php_id']] = $p['name'];
	$by = array();
	foreach((array)$app->db->queryAllRecords("SELECT domain, server_php_id FROM web_domain WHERE type='vhost' AND active='y' AND php NOT IN ('no','')") as $s) {
		$ver = (isset($names[(int)$s['server_php_id']]) && preg_match('/([0-9]+\.[0-9]+)/', $names[(int)$s['server_php_id']], $m)) ? $m[1] : $v['php_default'];
		$by[$ver][] = $s['domain'];
	}
	ksort($by, SORT_NATURAL);
	foreach($by as $ver => $sites) {
		$list = implode(', ', array_slice($sites, 0, 5)).(count($sites) > 5 ? ' и ещё '.(count($sites) - 5) : '');
		if(!isset($PHP_EOL_DATES[$ver])) { $add('warn', 'PHP '.$ver.': срок поддержки неизвестен ('.$list.')'); continue; }
		$d = $due($PHP_EOL_DATES[$ver]);
		if($d < 0) $add('fail', 'PHP '.$ver.' без исправлений безопасности с '.$PHP_EOL_DATES[$ver].': '.$list);
		elseif($d < 90) $add('warn', 'PHP '.$ver.': поддержка заканчивается '.$PHP_EOL_DATES[$ver].' (осталось '.$d.' дн.): '.$list);
		else $add('ok', 'PHP '.$ver.' поддерживается до '.$PHP_EOL_DATES[$ver].' (сайтов: '.count($sites).')');
	}

	if($ossl !== '') {
		$br = implode('.', array_slice(explode('.', $ossl), 0, 2));
		if(!isset($OPENSSL_EOL_DATES[$br])) $add('fail', 'nginx собран с OpenSSL '.$ossl.', ветка без поддержки. Смените ветку и пересоберите nginx');
		else {
			$d = $due($OPENSSL_EOL_DATES[$br]);
			if($d < 90) $add('warn', 'OpenSSL '.$ossl.': поддержка заканчивается '.$OPENSSL_EOL_DATES[$br]);
			else $add('ok', 'OpenSSL '.$ossl.' поддерживается до '.$OPENSSL_EOL_DATES[$br]);
		}
	}

	foreach(array('nginx' => 'nginx', 'mariadb' => 'MariaDB') as $svc => $label) {
		$a = mm_sh('systemd-analyze security '.$svc.'.service --no-pager | tail -1');
		if(preg_match('/level for [^:]+:\s*([0-9.]+)/', $a, $m)) {
			$sc = (float)$m[1];
			if($sc >= 8) $add('warn', $label.': служба почти без ограничений systemd (оценка '.$sc.' из 10), см. настройку ограничений служб');
			else $add('ok', $label.': ограничения systemd, оценка '.$sc.' из 10');
		}
	}

	$cols = $app->db->queryAllRecords("SHOW TABLES LIKE 'shell_user'");
	if(!empty($cols)) {
		$open = array();
		foreach((array)$app->db->queryAllRecords("SELECT username FROM shell_user WHERE active='y' AND (chroot='' OR chroot='no')") as $u) $open[] = $u['username'];
		if($open) $add('warn', 'Shell-пользователи без jail: '.implode(', ', array_slice($open, 0, 8)));
		else $add('ok', 'Все shell-пользователи ISPConfig в jail');
	}

	$ww = '/root/world-writable-files.txt';
	if(is_file($ww)) {
		$n = 0; foreach(file($ww) as $l) if(trim($l) !== '' && $l[0] === '/') $n++;
		if($n > 0) $add('warn', 'Файлов сайтов с записью для всех: '.$n.' (список '.$ww.')');
	}

	$slog = mm_setup_log();
	if($dir !== '' && $slog !== '' && is_file($slog)) {
		$n = (int)mm_sh("grep -cE '\\b[A-Z0-9_]*(PW|PASS|PASSWORD|SECRET|TOKEN|KEY)=[^< ]' ".escapeshellarg($slog));
		if($n > 0) $add('warn', 'В setup.log есть строки с секретами открытым текстом: '.$n.'. Уберёт любое обновление (здесь или luckyctl update)');
		$pm = fileperms($slog) & 0777;
		if($pm & 0077) $add('warn', 'setup.log доступен не только root (права '.decoct($pm).')');
	}

	$up = (int)mm_sh("apt list --upgradable 2>/dev/null | grep -c upgradable");
	mm_set('apt_upgradable', (string)$up);
	if($up > 0) $add('warn', 'Пакетов к обновлению: '.$up.'. Пункт «Системные пакеты»');
	if(isset($cur['SEC_AUTO_UPDATES_3RD']) && $cur['SEC_AUTO_UPDATES_3RD'] !== 'y') $add('warn', 'Автообновления PHP и MariaDB выключены, новые выпуски ставятся только вручную');

	mm_set('checks', json_encode($c, JSON_UNESCAPED_UNICODE));
}

// --- Проверка здоровья: разбор вывода --healthcheck --------------------------
function mm_healthcheck() {
	$dir = mm_installer_dir();
	if(mm_installer_problem($dir) !== '') return 'установщик недоступен: '.mm_installer_problem($dir);
	$o = array(); $rc = 0;
	exec('cd '.escapeshellarg($dir).' && HC_NO_CLEAR=1 TERM=dumb timeout 170 ./server-setup.sh --healthcheck </dev/null 2>&1', $o, $rc);
	$groups = array(); $g = ''; $counts = array('ok' => 0, 'warn' => 0, 'fail' => 0);
	foreach(explode("\n", mm_clean(implode("\n", $o))) as $l) {
		if(preg_match('/^┌─\s*(.+?)\s*─+/u', $l, $m)) { $g = $m[1]; continue; }
		if(preg_match('/^│\s+(✓|!|✗)\s+(.*?)\s*│?\s*$/u', $l, $m)) {
			$lvl = ($m[1] === '✓') ? 'ok' : (($m[1] === '!') ? 'warn' : 'fail');
			$counts[$lvl]++;
			$groups[$g][] = array($lvl, $m[2]);
		}
	}
	if(array_sum($counts) === 0) return 'не удалось разобрать вывод проверки';
	mm_set('health', json_encode(array('groups' => $groups, 'counts' => $counts, 'time' => date('Y-m-d H:i')), JSON_UNESCAPED_UNICODE));
	return '';
}

// --- Запись настроек в setup.conf ------------------------------------------
function mm_save_settings($payload) {
	global $SETTINGS;
	$dir = mm_installer_dir();
	$prob = mm_installer_problem($dir);
	if($prob !== '') return array(false, $prob);
	if(!is_array($payload)) return array(false, 'пустые настройки');
	// Адрес писем о безопасности. setup.conf читается bash-ем, поэтому только простые символы:
	// проверка filter_var пропустила бы $ и обратные кавычки.
	$sec_email = null;
	if(array_key_exists('SEC_ADMIN_EMAIL', $payload)) {
		$sec_email = $payload['SEC_ADMIN_EMAIL'];
		unset($payload['SEC_ADMIN_EMAIL']);
		if(!is_string($sec_email) || !preg_match('/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/', $sec_email)) return array(false, 'некорректный адрес писем о безопасности');
	}
	foreach($payload as $k => $val) {
		if(!isset($SETTINGS[$k])) return array(false, 'неизвестная настройка: '.substr((string)$k, 0, 40));
		if(!in_array($val, $SETTINGS[$k], true)) return array(false, 'недопустимое значение '.$k);
	}
	$file = mm_setup_conf();
	$cf = mm_conf_read($file);
	$lines = file($file);
	$changed = array();
	foreach($payload as $k => $val) {
		$old = isset($cf[$k]) ? $cf[$k] : $SETTINGS[$k][0];
		if($old === $val) continue;
		$changed[] = $k.'='.$val;
		$found = false;
		foreach($lines as $i => $l) if(strpos($l, $k.'=') === 0) { $lines[$i] = $k.'='.$val."\n"; $found = true; }
		if(!$found) $lines[] = $k.'='.$val."\n";
	}
	if($sec_email !== null && (!isset($cf['SEC_ADMIN_EMAIL']) || $cf['SEC_ADMIN_EMAIL'] !== $sec_email)) {
		$changed[] = 'SEC_ADMIN_EMAIL='.$sec_email;
		$found = false;
		foreach($lines as $i => $l) if(strpos($l, 'SEC_ADMIN_EMAIL=') === 0) { $lines[$i] = 'SEC_ADMIN_EMAIL='.$sec_email."\n"; $found = true; }
		if(!$found) $lines[] = 'SEC_ADMIN_EMAIL='.$sec_email."\n";
	}
	if($sec_email !== null) {
		$ini = '/usr/local/ispconfig/security/security_settings.ini';
		$txt = (string)@file_get_contents($ini);
		$new = preg_replace('/^security_admin_email=.*$/m', 'security_admin_email='.$sec_email, $txt);
		if($new !== null && $new !== $txt && $txt !== '') {
			$t = $ini.'.tmp';
			@unlink($t);
			if(file_put_contents($t, $new) !== false) {
				chmod($t, fileperms($ini) & 0777); chown($t, fileowner($ini)); chgrp($t, filegroup($ini));
				rename($t, $ini);
			}
		}
	}
	if(!$changed) return array(true, 'изменений нет');
	$tmp = $file.'.tmp';
	$fp = @fopen($tmp, 'x');
	if(!$fp) { @unlink($tmp); return array(false, 'не удалось записать setup.conf'); }
	fclose($fp); chmod($tmp, 0600);
	file_put_contents($tmp, implode('', $lines));
	if(!rename($tmp, $file)) return array(false, 'не удалось заменить setup.conf');
	return array(true, 'сохранено: '.implode(', ', $changed));
}

// --- Запуск и завершение обновления ----------------------------------------
function mm_finish_update($job) {
	global $app, $LOGDIR;
	$id = (int)$job['id'];
	$log = $LOGDIR.'/job-'.$id.'.log';
	$rcf = $LOGDIR.'/job-'.$id.'.rc';
	$text = mm_tail($log);
	if(is_file($rcf)) $rc = (int)trim((string)file_get_contents($rcf));
	else {
		if(mm_sh('systemctl is-active ss-maint-job-'.$id) === 'active') {
			$app->db->query("UPDATE ss_maint_job SET log=? WHERE id=?", $text, $id);
			return false;
		}
		$rc = -1;
	}
	$fail = array();
	if(preg_match_all('/^\[!\]\s+•\s+(.+)$/mu', $text, $m)) $fail = $m[1];
	$cross = preg_match_all('/^\[✗\]/mu', $text);
	global $RC_BACKUP_FAILED;
	if($rc === $RC_BACKUP_FAILED) { $st = 'error'; $res = 'бэкап не удался, обновление не запускалось. Сервер не менялся'; }
	elseif($rc === -1) { $st = 'error'; $res = 'прервано: служба обновления остановилась без результата'; }
	elseif($rc !== 0) { $st = 'error'; $res = 'установщик завершился с кодом '.$rc; }
	elseif($fail) { $st = 'error'; $res = 'с ошибками в шагах: '.implode('; ', $fail); }
	else { $st = 'done'; $res = 'завершено'.($cross ? ', есть замечания [✗]: '.$cross : ''); }
	$app->db->query("UPDATE ss_maint_job SET status=?, result=?, log=?, processed=NOW() WHERE id=?", $st, substr($res, 0, 255), $text, $id);
	$act = ($job['action'] === 'rollback') ? 'Откат' : 'Обновление';
	mm_notify($st === 'done' ? 'info' : 'crit', $act.' сервера: '.($st === 'done' ? 'завершено' : 'ошибка'), $res);
	mm_collect();
	mm_healthcheck();
	return true;
}

function mm_start_update($job, $payload) {
	global $app, $ITEMS, $ITEMS_CORE, $LOGDIR, $BACKUP, $ROLLBACK_TARGETS, $RC_BACKUP_FAILED;
	$id = (int)$job['id'];
	$fail = function($m) use ($app, $id) { $app->db->query("UPDATE ss_maint_job SET status='error', result=?, processed=NOW() WHERE id=?", substr($m, 0, 255), $id); };
	$dir = mm_installer_dir();
	$prob = mm_installer_problem($dir);
	if($prob !== '') { $fail($prob); return; }
	$items = array(); $target = '';
	$is_rollback = ($job['action'] === 'rollback');
	if($is_rollback) {
		$target = (is_array($payload) && isset($payload['target'])) ? $payload['target'] : '';
		if(!in_array($target, $ROLLBACK_TARGETS, true)) { $fail('неизвестная цель отката'); return; }
	} else {
		foreach((array)(is_array($payload) && isset($payload['items']) ? $payload['items'] : array()) as $i) {
			if(!in_array($i, $ITEMS, true)) { $fail('неизвестный пункт обновления'); return; }
			$items[] = $i;
		}
		if(!$items) { $fail('не выбрано ни одного пункта'); return; }
	}
	$need_backup = (bool)array_intersect($items, $ITEMS_CORE);
	if($need_backup && !is_executable($BACKUP)) { $fail('нет '.$BACKUP.': обновление ядра без бэкапа не запускаю. Сначала запустите пункт «Бэкап»'); return; }
	if(mm_installer_running()) { $fail('установщик уже запущен (в терминале или другим заданием), повторите позже'); return; }
	if(!is_dir($LOGDIR)) { mkdir($LOGDIR, 0700, true); }
	chmod($LOGDIR, 0700);
	$log = $LOGDIR.'/job-'.$id.'.log';
	$rcf = $LOGDIR.'/job-'.$id.'.rc';
	@unlink($log); @unlink($rcf);
	$pre = '';
	if($need_backup) {
		$pre = 'echo "[i] Бэкап перед обновлением ядра" >'.escapeshellarg($log).'; '
			.escapeshellarg($BACKUP).' </dev/null >>'.escapeshellarg($log).' 2>&1'
			.' || { echo "[✗] Бэкап не удался, обновление не запускается" >>'.escapeshellarg($log).'; echo '.(int)$RC_BACKUP_FAILED.' >'.escapeshellarg($rcf).'; exit 0; }; '
			.'echo "[✓] Бэкап сделан" >>'.escapeshellarg($log).'; ';
	}
	$run = $is_rollback ? './server-setup.sh --rollback '.escapeshellarg($target) : './server-setup.sh --update';
	$script = $pre.'cd '.escapeshellarg($dir).' && '.$run.' </dev/null >>'.escapeshellarg($log).' 2>&1; echo $? >'.escapeshellarg($rcf);
	$cmd = 'systemd-run --quiet --collect --unit=ss-maint-job-'.$id
		.($is_rollback ? '' : ' --setenv=UPDATE_ITEMS='.escapeshellarg(implode(' ', $items)))
		.' --setenv=HOME=/root --setenv=TERM=dumb --setenv=LC_ALL=C.UTF-8'
		.' /bin/bash -c '.escapeshellarg($script).' 2>&1';
	$o = array(); $rc = 0;
	exec($cmd, $o, $rc);
	if($rc !== 0) { $fail('не удалось запустить: '.mm_clean(implode(' ', $o))); return; }
	$app->db->query("UPDATE ss_maint_job SET status='running', started=NOW() WHERE id=?", $id);
}

// --- Основной проход ---------------------------------------------------------
$force = false;
$running = $app->db->queryOneRecord("SELECT * FROM ss_maint_job WHERE status='running' ORDER BY id ASC LIMIT 1");
if(is_array($running) && !empty($running)) mm_finish_update($running);

$busy = $app->db->queryOneRecord("SELECT id FROM ss_maint_job WHERE status='running' LIMIT 1");
if(!is_array($busy) || empty($busy)) {
	$job = $app->db->queryOneRecord("SELECT * FROM ss_maint_job WHERE status='pending' ORDER BY id ASC LIMIT 1");
	if(is_array($job) && !empty($job)) {
		$id = (int)$job['id'];
		$act = (string)$job['action'];
		$payload = json_decode((string)$job['payload'], true);
		$res = function($st, $m) use ($app, $id) { $app->db->query("UPDATE ss_maint_job SET status=?, result=?, processed=NOW() WHERE id=?", $st, substr((string)$m, 0, 255), $id); };
		if($act === 'refresh') {
			mm_collect();
			$res('done', 'сведения обновлены');
		} elseif($act === 'healthcheck') {
			$app->db->query("UPDATE ss_maint_job SET status='running', started=NOW() WHERE id=?", $id);
			$e = mm_healthcheck();
			mm_collect();
			$res($e === '' ? 'done' : 'error', $e === '' ? 'проверка выполнена' : $e);
		} elseif($act === 'save') {
			list($ok, $m) = mm_save_settings($payload);
			mm_collect();
			$res($ok ? 'done' : 'error', $m);
		} elseif($act === 'update' || $act === 'rollback') {
			mm_start_update($job, $payload);
		} else {
			$res('error', 'неизвестное действие');
		}
	}
}

// Пока идёт обновление, каждые несколько секунд переносим хвост журнала в панель.
$until = time() + 50;
while(time() < $until) {
	$r = $app->db->queryOneRecord("SELECT * FROM ss_maint_job WHERE status='running' AND action IN ('update','rollback') ORDER BY id ASC LIMIT 1");
	if(!is_array($r) || empty($r)) break;
	if(mm_finish_update($r)) break;
	sleep(3);
}

// Плановое обновление сведений: не во время обновления сервера.
$busy = $app->db->queryOneRecord("SELECT id FROM ss_maint_job WHERE status='running' LIMIT 1");
if(!is_array($busy) || empty($busy)) {
	if(mm_age('versions') > 600) mm_collect();
	if(mm_age('health') > 21600) mm_healthcheck();
	mm_alerts();
}

// Старые задания и журналы. Журналы только в корне своего каталога и только по маске.
$app->db->query("DELETE FROM ss_maint_job WHERE status IN ('done','error') AND processed < (NOW() - INTERVAL 90 DAY)");
foreach((array)glob($LOGDIR.'/job-*') as $f) if(is_file($f) && filemtime($f) < time() - 90 * 86400) @unlink($f);

flock($lock, LOCK_UN);
exit(0);
