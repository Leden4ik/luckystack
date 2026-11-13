<?php
/*
  LuckyStack: забрать ручные правки файлов замороженных vhost в базу (запуск от root установщиком).

  Для каждого замороженного включённого сайта сравнивает файл vhost на диске с последним
  применённым текстом (копия в /etc/nginx/sites-frozen, а если её нет — текст в базе). Если файл
  отличается, его правили вручную или их поменял сам установщик (например миграция пути
  CrowdSec-лога): текст файла записывается в web_domain.freeze_vhost_content и в копию. Файл и
  nginx не трогаются, событий ISPConfig не создаётся.

  Вызывается при развёртывании заморозки, в --update и после правок vhost установщиком, чтобы
  следующее сохранение сайта в панели или Resync не вернули старый текст из базы.
  Запуск: php ss-freeze-drift.php [--dry-run]. Печатает по строке на каждый забранный сайт.
*/

$dry = in_array('--dry-run', $argv, true);
$conf = array();
require '/usr/local/ispconfig/server/lib/config.inc.php';
$db = @new mysqli($conf['db_host'], $conf['db_user'], $conf['db_password'], $conf['db_database']);
if($db->connect_errno) { fwrite(STDERR, "нет подключения к БД\n"); exit(1); }
$db->set_charset('utf8mb4');

$has = $db->query("SHOW COLUMNS FROM web_domain LIKE 'freeze_vhost_content'");
if(!$has || $has->num_rows === 0) exit(0);   // заморозка не установлена

$type = 'nginx';
$r = $db->query("SELECT config FROM server ORDER BY server_id LIMIT 1");
if($r && ($row = $r->fetch_assoc()) && preg_match('/^server_type=apache\s*$/m', (string)$row['config'])) $type = 'apache';
$vdir = ($type === 'apache') ? (is_dir('/etc/apache2/sites-available') ? '/etc/apache2/sites-available' : '/etc/httpd/conf.d') : '/etc/nginx/sites-available';
$fdir = '/etc/nginx/sites-frozen';

$n = 0;
$res = $db->query("SELECT domain_id, domain, freeze_vhost_content FROM web_domain WHERE freeze_vhost = 'y' AND active = 'y' AND type IN ('vhost','vhostsubdomain','vhostalias')");
while($res && ($s = $res->fetch_assoc())) {
	$domain = (string)$s['domain'];
	if(!preg_match('/^[A-Za-z0-9._-]+$/', $domain)) continue;
	$file = $vdir.'/'.$domain.'.vhost';
	if(!is_file($file)) continue;
	$live = str_replace("\r\n", "\n", (string)@file_get_contents($file));
	if(trim($live) === '') continue;
	$db_text = str_replace("\r\n", "\n", (string)$s['freeze_vhost_content']);
	$mf = $fdir.'/'.$domain.'.vhost';
	$ref = is_file($mf) ? str_replace("\r\n", "\n", (string)@file_get_contents($mf)) : $db_text;
	if($live === $ref && $live === $db_text) continue;
	if($live === $ref && $live !== $db_text) {
		// копия совпадает с файлом, а база нет: в панели правили, но ещё не применили — не трогаем
		continue;
	}
	$n++;
	echo "$domain: файл отличается от последнего применённого, забираю в базу\n";
	if($dry) continue;
	$st = $db->prepare("UPDATE web_domain SET freeze_vhost_content = ?, freeze_vhost_status = CONCAT('ok ', DATE_FORMAT(NOW(), '%Y-%m-%d %H:%i'), ' (забраны правки из файла)') WHERE domain_id = ?");
	$id = (int)$s['domain_id'];
	$st->bind_param('si', $live, $id);
	$st->execute();
	if(!is_dir($fdir)) @mkdir($fdir, 0750, true);
	if(is_file($mf) && (string)@file_get_contents($mf) !== '') { $dst = $mf.'.prev-'.date('Ymd-His'); @copy($mf, $dst); @chmod($dst, 0640); }
	@file_put_contents($mf, $live); @chmod($mf, 0640);
}
exit(0);
