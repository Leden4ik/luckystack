<?php
// LuckyStack: контроллер формы правила Firewall IP-rules
$tform_def_file = "form/firewall_restrict.tform.php";

require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';

$app->auth->check_module_permissions('admin');
if(!$app->auth->is_admin()) die('Allowed for administrators only.');

$app->uses('tpl,tform,tform_actions');
$app->load('tform_actions');

class page_action extends tform_actions {

	function onShowEnd() {
		global $app;
		//* IP текущего админа — для кнопки «мой IP» и анти-локаут подсказки
		$myip = isset($_SERVER['REMOTE_ADDR']) ? preg_replace('/[^0-9A-Fa-f:.]/', '', $_SERVER['REMOTE_ADDR']) : '';
		$app->tpl->setVar('my_ip', $myip);
		if($this->id == 0) { //* новая запись — заполнить список серверов
			$server_list = $app->db->queryAllRecords("SELECT server_id, server_name FROM server ORDER BY server_name");
			$server_select = '';
			if(is_array($server_list)) {
				foreach($server_list as $s) {
					$server_select .= "<option value='".$s['server_id']."'>".$app->functions->htmlentities($s['server_name'])."</option>\r\n";
				}
			}
			$app->tpl->setVar('server_id', $server_select);
		}
		parent::onShowEnd();
	}

	//* Сбросить отметку «применено» при создании/изменении правила — оно станет ⏳ «ожидает»,
	//  пока server.sh не обработает датолог и плагин не пересоберёт before.rules (applied=NOW).
	//  Raw-query (не datalog) — не создаёт лишних событий.
	function onAfterInsert() {
		global $app;
		$app->db->query("UPDATE firewall_restrict SET applied = NULL WHERE restrict_id = ?", $this->id);
	}
	function onAfterUpdate() {
		global $app;
		$app->db->query("UPDATE firewall_restrict SET applied = NULL WHERE restrict_id = ?", $this->id);
	}
}

$page = new page_action;
$page->onLoad();

?>
