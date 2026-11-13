<?php
// LuckyStack: список Firewall IP-rules
$liste["name"]             = "firewall_restrict";
$liste["table"]            = "firewall_restrict";
$liste["table_idx"]        = "restrict_id";
$liste["search_prefix"]    = "search_";
$liste["records_per_page"] = "20";
$liste["file"]             = "firewall_restrict_list.php";
$liste["edit_file"]        = "firewall_restrict_edit.php";
$liste["delete_file"]      = "firewall_restrict_del.php";
$liste["paging_tpl"]       = "templates/paging.tpl.htm";
$liste["auth"]             = "yes";

$liste["item"][] = array( 'field' => "active",
	'datatype' => "VARCHAR", 'formtype' => "SELECT", 'op' => "=", 'prefix' => "", 'suffix' => "", 'width' => "",
	'value' => array('y' => $app->lng('yes_txt'), 'n' => $app->lng('no_txt')));

$liste["item"][] = array( 'field' => "server_id",
	'datatype' => "INTEGER", 'formtype' => "SELECT", 'op' => "=", 'prefix' => "", 'suffix' => "", 'width' => "",
	'datasource' => array ( 'type' => 'SQL',
		'querystring' => 'SELECT server_id,server_name FROM server WHERE {AUTHSQL} ORDER BY server_name',
		'keyfield' => 'server_id', 'valuefield' => 'server_name'),
	'value' => "");

$liste["item"][] = array( 'field' => "proto",
	'datatype' => "VARCHAR", 'formtype' => "SELECT", 'op' => "=", 'prefix' => "", 'suffix' => "", 'width' => "",
	'value' => array('' => '-', 'tcp' => 'TCP', 'udp' => 'UDP'));

$liste["item"][] = array( 'field' => "port",
	'datatype' => "VARCHAR", 'formtype' => "TEXT", 'op' => "like", 'prefix' => "%", 'suffix' => "%", 'width' => "", 'value' => "");

$liste["item"][] = array( 'field' => "allow_all",
	'datatype' => "VARCHAR", 'formtype' => "SELECT", 'op' => "=", 'prefix' => "", 'suffix' => "", 'width' => "",
	'value' => array('y' => $app->lng('scope_all_txt'), 'n' => $app->lng('scope_ip_txt')));

$liste["item"][] = array( 'field' => "allowed_ips",
	'datatype' => "VARCHAR", 'formtype' => "TEXT", 'op' => "like", 'prefix' => "%", 'suffix' => "%", 'width' => "", 'value' => "");

$liste["item"][] = array( 'field' => "description",
	'datatype' => "VARCHAR", 'formtype' => "TEXT", 'op' => "like", 'prefix' => "%", 'suffix' => "%", 'width' => "", 'value' => "");

// статус применения: NULL = ⏳ ожидает, дата = ✓ применено (ставит плагин при rebuild).
// datatype VARCHAR — чтобы значение пришло «как есть» (для tmpl_if в шаблоне), без date-форматирования.
$liste["item"][] = array( 'field' => "applied",
	'datatype' => "VARCHAR", 'formtype' => "TEXT", 'op' => "", 'prefix' => "", 'suffix' => "", 'width' => "", 'value' => "");

?>
