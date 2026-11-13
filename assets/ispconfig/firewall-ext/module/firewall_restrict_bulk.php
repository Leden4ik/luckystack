<?php
/*
  LuckyStack: массовое включение/выключение правил Firewall IP-rules.
  Со списка приходят отмеченные restrict_id (POST do=enable/disable, ids=1,2,3 + CSRF-токен). Меняем active
  через datalogUpdate → серверный модуль поднимает событие → плагин пересобирает before.rules.
  Только админ. Идемпотентно (меняем только если active реально отличается).
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

$do     = ss_post('do');
$active = ($do === 'enable') ? 'y' : (($do === 'disable') ? 'n' : '');
$ids    = ss_post('ids');

$n = 0;
if($active !== '' && $ids !== '') {
	foreach(explode(',', $ids) as $id) {
		$id = intval($id);
		if($id <= 0) continue;
		$cur = $app->db->queryOneRecord("SELECT restrict_id, active FROM firewall_restrict WHERE restrict_id = ?", $id);
		if(is_array($cur) && !empty($cur) && (string)$cur['active'] !== $active) {
			$app->db->datalogUpdate('firewall_restrict', array('active' => $active), 'restrict_id', $id);
			$n++;
		}
	}
	if($n > 0) ss_audit('firewall', $active === 'y' ? 'bulk_enable' : 'bulk_disable', 'правил: '.$n.' (ids '.$ids.')');
}

header('Location: firewall_restrict_list.php');
exit;
?>
