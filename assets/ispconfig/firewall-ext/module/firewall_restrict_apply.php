<?php
/*
  LuckyStack: кнопка «Применить сейчас» для модуля Firewall IP-rules.

  Форсирует пересборку /etc/ufw/before.rules: интерфейс работает под непривилегированным
  пользователем и сам ufw перезагрузить не может, поэтому создаём событие в sys_datalog
  (datalogUpdate) → ближайший server.sh (фон, ≤1 мин) → модуль → плагин пересобирает
  before.rules и проставляет applied=NOW. Колонка «Применено» затем покажет ✓.
  Только админ. Идемпотентно.
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

$server_id = 1;
$srow = $app->db->queryOneRecord("SELECT server_id FROM server ORDER BY server_id LIMIT 1");
if(is_array($srow) && isset($srow['server_id'])) $server_id = intval($srow['server_id']);

// взять первое активное правило и гарантированно создать датолог (тоггл applied),
// чтобы server.sh пересобрал before.rules для ВСЕХ правил.
$first = $app->db->queryOneRecord("SELECT restrict_id, applied FROM firewall_restrict WHERE server_id = ? AND active = 'y' ORDER BY restrict_id LIMIT 1", $server_id);
if(is_array($first) && !empty($first['restrict_id'])) {
	$newval = (empty($first['applied'])) ? date('Y-m-d H:i:s') : null; // тоггл → гарантированный diff → датолог
	$app->db->datalogUpdate('firewall_restrict', array('applied' => $newval), 'restrict_id', $first['restrict_id']);
}
ss_audit('firewall', 'apply');

header('Location: firewall_restrict_list.php');
exit;
?>
