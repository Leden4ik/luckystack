<?php
/*
  LuckyStack: кнопка «Заполнить значения по умолчанию» для модуля Firewall IP-rules.

  Заносит дефолтные правила в firewall_restrict ИДЕМПОТЕНТНО (по server_id+proto+port —
  существующие не трогает). Вставка через datalogInsert → серверный модуль firewall_restrict_module
  поднимает событие → плагин firewall_restrict_plugin пересобирает /etc/ufw/before.rules.

  Источник дефолтов (панель не видит setup.conf, поэтому берём из самой ISPConfig):
    - публичные порты (allow_all=y): из таблицы родного firewall (tcp_port/udp_port) + типовой
      веб/почта-набор как fallback;
    - IP-ограничения (allow_all=n): SSH(22), панель(текущий порт), MySQL(3306) — стартово на
      IP текущего администратора (анти-локаут). Доп. IP и нестандартный порт SSH — вручную.
  Только админ.
*/

require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';
require_once '../../lib/ss_panel.inc.php';

$app->auth->check_module_permissions('admin');
if(!isset($_SESSION['s']['user']['typ']) || $_SESSION['s']['user']['typ'] != 'admin') {
	header('Location: firewall_restrict_list.php');
	exit;
}
// только POST + CSRF-токен (кнопка со списка); прямой GET ничего не меняет
if(!ss_is_action()) {
	header('Location: firewall_restrict_list.php');
	exit;
}

// ---- локализация описаний: en (база) + язык пользователя (поверх) ----
$wb = array();
$_ld = __DIR__.'/lib/lang/';
@include $_ld.'en_firewall_restrict_list.lng';
$_ul = isset($_SESSION['s']['language']) ? preg_replace('/[^a-z]/', '', $_SESSION['s']['language']) : 'en';
if($_ul && $_ul !== 'en' && file_exists($_ld.$_ul.'_firewall_restrict_list.lng')) @include $_ld.$_ul.'_firewall_restrict_list.lng';
function _fwL($k, $def) { global $wb; return isset($wb[$k]) ? $wb[$k] : $def; }

$server_id = 1;
$srow = $app->db->queryOneRecord("SELECT server_id FROM server ORDER BY server_id LIMIT 1");
if(is_array($srow) && isset($srow['server_id'])) $server_id = intval($srow['server_id']);

$admin_ip = isset($_SERVER['REMOTE_ADDR']) ? preg_replace('/[^0-9A-Fa-f:.]/', '', $_SERVER['REMOTE_ADDR']) : '';
$panel_port = isset($_SERVER['SERVER_PORT']) ? intval($_SERVER['SERVER_PORT']) : 0;
if($panel_port < 1 || $panel_port > 65535) $panel_port = 8080;

$GLOBALS['fw_added'] = 0;

function fw_seed($proto, $port, $ips, $all, $desc) {
	global $app, $server_id;
	$port = (string)$port;
	if(!preg_match('/^\d{1,5}(:\d{1,5})?$/', $port)) return;
	$proto = ($proto === 'udp') ? 'udp' : 'tcp';
	$ex = $app->db->queryOneRecord("SELECT restrict_id FROM firewall_restrict WHERE server_id = ? AND proto = ? AND port = ?", $server_id, $proto, $port);
	if(is_array($ex) && !empty($ex)) return; // уже есть — не дублируем
	$insert = array(
		'sys_userid'     => 1,
		'sys_groupid'    => 1,
		'sys_perm_user'  => 'riud',
		'sys_perm_group' => 'riud',
		'sys_perm_other' => '',
		'server_id'      => $server_id,
		'proto'          => $proto,
		'port'           => $port,
		'allowed_ips'    => $ips,
		'allow_all'      => ($all === 'y') ? 'y' : 'n',
		'description'    => $desc,
		'active'         => 'y'
	);
	$app->db->datalogInsert('firewall_restrict', $insert, 'restrict_id');
	$GLOBALS['fw_added']++;
}

$names = array(
	'20' => 'FTP', '21' => 'FTP', '25' => 'SMTP', '53' => 'DNS', '80' => 'HTTP',
	'110' => 'POP3', '143' => 'IMAP', '443' => 'HTTPS', '465' => 'SMTPS', '587' => 'Submission',
	'993' => 'IMAPS', '995' => 'POP3S', '4190' => 'ManageSieve'
);
// Порты SSH: из sshd_config и sshd_config.d/*.conf (файлы читаются всеми, 644). Если Port
// нигде не задан, sshd слушает 22. Раньше здесь был жёстко 22, и при SSH на другом порту
// кнопка ограничивала не тот порт.
$ssh_ports = array();
$sshd_files = array_merge(array('/etc/ssh/sshd_config'), (array)glob('/etc/ssh/sshd_config.d/*.conf'));
foreach($sshd_files as $sf) {
	if(!is_readable($sf)) continue;
	foreach((array)@file($sf) as $l) {
		if(preg_match('/^\s*Port\s+(\d{1,5})\s*$/i', $l, $m) && (int)$m[1] >= 1 && (int)$m[1] <= 65535) $ssh_ports[$m[1]] = true;
	}
}
$ssh_ports = $ssh_ports ? array_keys($ssh_ports) : array('22');
$ssh_ports = array_map('strval', $ssh_ports);

$restricted_ports = array_merge($ssh_ports, array((string)$panel_port, '3306')); // их НЕ как публичные

// 1) публичные порты из родного firewall ISPConfig
$fw = $app->db->queryOneRecord("SELECT tcp_port, udp_port FROM firewall WHERE server_id = ?", $server_id);
if(is_array($fw)) {
	$lists = array('tcp' => $fw['tcp_port'], 'udp' => $fw['udp_port']);
	foreach($lists as $proto => $list) {
		foreach(explode(',', (string)$list) as $p) {
			$p = trim($p);
			if($p === '') continue;
			if(in_array($p, $restricted_ports)) continue;
			$nm = isset($names[$p]) ? $names[$p] : _fwL('seed_desc_public_txt', 'Public port');
			fw_seed($proto, $p, '', 'y', $nm);
		}
	}
}

// 2) типовой веб/почта-набор (fallback, если родной firewall пуст)
$common = array('80' => 'HTTP', '443' => 'HTTPS', '25' => 'SMTP', '587' => 'Submission',
	'465' => 'SMTPS', '143' => 'IMAP', '993' => 'IMAPS', '110' => 'POP3', '995' => 'POP3S');
foreach($common as $p => $nm) {
	if(in_array($p, $restricted_ports)) continue;
	fw_seed('tcp', $p, '', 'y', $nm);
}
fw_seed('udp', '443', '', 'y', 'HTTPS (HTTP/3)');

// 3) базовые IP-ограничения на IP текущего админа (анти-локаут; доп. IP — вручную)
if($admin_ip !== '') {
	foreach($ssh_ports as $sp) fw_seed('tcp', $sp, $admin_ip, 'n', _fwL('seed_desc_ssh_txt', 'SSH — admins'));
	fw_seed('tcp', (string)$panel_port, $admin_ip, 'n', _fwL('seed_desc_panel_txt', 'ISPConfig panel — admins'));
	fw_seed('tcp', '3306', $admin_ip, 'n', _fwL('seed_desc_mysql_txt', 'MySQL — remote access'));
}

ss_audit('firewall', 'seed', 'добавлено правил: '.$GLOBALS['fw_added']);

header('Location: firewall_restrict_list.php');
exit;
?>
