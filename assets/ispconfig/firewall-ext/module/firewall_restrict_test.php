<?php
/*
  LuckyStack: «тест порта» для правила Firewall IP-rules.
  Проверяет, СЛУШАЕТ ли кто-то локально этот порт (fsockopen 127.0.0.1) — отвечает на
  частый вопрос «порт открыт в firewall, но не отвечает» (обычно служба не запущена).
  Локализовано: грузим en как базу + язык пользователя поверх (отсутствующие ключи → en).
  Только админ.
*/

require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';

$app->auth->check_module_permissions('admin');
if(!isset($_SESSION['s']['user']['typ']) || $_SESSION['s']['user']['typ'] != 'admin') {
	header('Location: firewall_restrict_list.php');
	exit;
}
$app->uses('functions');

// ---- локализация: en (база) + язык пользователя (поверх) ----
$wb = array();
$_ld = __DIR__.'/lib/lang/';
@include $_ld.'en_firewall_restrict_list.lng';
$_ul = isset($_SESSION['s']['language']) ? preg_replace('/[^a-z]/', '', $_SESSION['s']['language']) : 'en';
if($_ul && $_ul !== 'en' && file_exists($_ld.$_ul.'_firewall_restrict_list.lng')) @include $_ld.$_ul.'_firewall_restrict_list.lng';
function _fwL($k) { global $wb; return isset($wb[$k]) ? $wb[$k] : $k; }

$id  = isset($_GET['id']) ? intval($_GET['id']) : 0;
$rec = $app->db->queryOneRecord("SELECT proto, port, description FROM firewall_restrict WHERE restrict_id = ?", $id);

$cls = 'alert-warning'; $msg = _fwL('test_not_found_txt');
if(is_array($rec) && $rec['port'] !== '') {
	$port  = $rec['port'];
	$proto = $rec['proto'];
	$label = $app->functions->htmlentities($proto.'/'.$port.($rec['description'] !== '' ? ' — '.$rec['description'] : ''));
	if(strpos($port, ':') !== false) {
		$cls = 'alert-info'; $msg = $label.': '._fwL('test_range_txt');
	} elseif($proto === 'udp') {
		$cls = 'alert-info'; $msg = $label.': '._fwL('test_udp_txt');
	} else {
		$errno = 0; $errstr = '';
		$fp = @fsockopen('127.0.0.1', (int)$port, $errno, $errstr, 2);
		if($fp) {
			fclose($fp);
			$cls = 'alert-success'; $msg = $label.': '._fwL('test_listener_yes_txt');
		} else {
			$cls = 'alert-warning'; $msg = $label.': '._fwL('test_listener_no_txt');
		}
	}
}

echo '<div class="page-header"><h1>'.$app->functions->htmlentities(_fwL('test_title_txt')).'</h1></div>';
echo '<div class="alert '.$cls.'">'.$msg.'</div>';
echo '<button class="btn btn-default" type="button" data-load-content="admin/firewall_restrict_list.php">&larr; '.$app->functions->htmlentities(_fwL('back_txt')).'</button>';
?>
