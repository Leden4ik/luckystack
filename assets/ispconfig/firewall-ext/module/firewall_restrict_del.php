<?php
// LuckyStack: контроллер удаления правила Firewall IP-rules
require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';

$tform_def_file = "form/firewall_restrict.tform.php";

$app->auth->check_module_permissions('admin');
if(!$app->auth->is_admin()) die('Allowed for administrators only.');

$app->uses("tform_actions");
$app->tform_actions->onDelete();

?>
