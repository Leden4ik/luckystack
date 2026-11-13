<?php
// LuckyStack: контроллер списка Firewall IP-rules
require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';

$list_def_file = "list/firewall_restrict.list.php";

$app->auth->check_module_permissions('admin');
if(!$app->auth->is_admin()) die('Allowed for administrators only.');

$app->uses('listform_actions');

// Токен для своих кнопок списка («Заполнить по умолчанию», «Применить сейчас», массовое
// вкл/выкл): они уходят POST-запросом с CSRF-токеном, как действия остальных наших панелей.
class ss_fw_list_actions extends listform_actions {
	public function onShow() {
		global $app;
		$t = $app->auth->csrf_token_get('ss_firewall');
		$app->tpl->setVar('ss_csrf_id', $t['csrf_id']);
		$app->tpl->setVar('ss_csrf_key', $t['csrf_key']);
		parent::onShow();
	}
}
$list = new ss_fw_list_actions();
$list->onLoad();

?>
