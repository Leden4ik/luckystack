<?php
/*
  LuckyStack: форма правила «Firewall IP-rules» (отдельные поля, дружелюбный UI).
  Каждое правило = порт(/диапазон) + протокол + «открыть всем» ИЛИ список IP + описание + вкл.
  Серверный плагин firewall_restrict_plugin читает таблицу firewall_restrict и пишет
  /etc/ufw/before.rules: allow_all=y → порт открыт всем (публичный); allow_all=n → только
  перечисленным IP (остальным DROP). Переживает правки/обновления ISPConfig.
*/

$form["title"]        = "Firewall IP-rule";
$form["description"]  = "";
$form["name"]         = "firewall_restrict";
$form["action"]       = "firewall_restrict_edit.php";
$form["db_table"]     = "firewall_restrict";
$form["db_table_idx"] = "restrict_id";
$form["db_history"]   = "yes";
$form["tab_default"]  = "rule";
$form["list_default"] = "firewall_restrict_list.php";
$form["auth"]         = 'yes';

$form["auth_preset"]["userid"]     = 0;
$form["auth_preset"]["groupid"]    = 0;
$form["auth_preset"]["perm_user"]  = 'riud';
$form["auth_preset"]["perm_group"] = 'riud';
$form["auth_preset"]["perm_other"] = '';

$form["tabs"]['rule'] = array (
	'title'    => "IP-rule",
	'width'    => 100,
	'template' => "templates/firewall_restrict_edit.htm",
	'fields'   => array (
		'server_id' => array (
			'datatype'  => 'INTEGER',
			'formtype'  => 'SELECT',
			'default'   => '',
			'datasource' => array ( 'type' => 'SQL',
				'querystring' => 'SELECT server_id,server_name FROM server WHERE {AUTHSQL} ORDER BY server_name',
				'keyfield'    => 'server_id',
				'valuefield'  => 'server_name'
			),
			'value' => ''
		),
		'proto' => array (
			'datatype' => 'VARCHAR',
			'formtype' => 'SELECT',
			'default'  => 'tcp',
			'value'    => array('tcp' => 'TCP', 'udp' => 'UDP')
		),
		'port' => array (
			'datatype' => 'VARCHAR',
			'formtype' => 'TEXT',
			'validators' => array ( 0 => array ( 'type' => 'REGEX',
					'regex' => '/^\d{1,5}(:\d{1,5})?$/',
					'errmsg'=> 'port_error_regex'),
			),
			'default'   => '',
			'value'     => '',
			'width'     => '14',
			'maxlength' => '11'
		),
		'allow_all' => array (
			'datatype' => 'VARCHAR',
			'formtype' => 'CHECKBOX',
			'default'  => 'n',
			'value'    => array(0 => 'n', 1 => 'y')
		),
		'allowed_ips' => array (
			'datatype' => 'TEXT',
			'formtype' => 'TEXTAREA',
			'validators' => array ( 0 => array ( 'type' => 'CUSTOM',
					'class'    => 'validate_firewall_restrict',
					'function' => 'valid_ips',
					'errmsg'   => 'allowed_ips_error'),
			),
			'default'  => '',
			'value'    => ''
		),
		'rate_limit' => array (
			'datatype' => 'VARCHAR',
			'formtype' => 'CHECKBOX',
			'default'  => 'n',
			'value'    => array(0 => 'n', 1 => 'y')
		),
		'geo_mode' => array (
			'datatype' => 'VARCHAR',
			'formtype' => 'SELECT',
			'default'  => 'off',
			'value'    => array('off' => 'geo_off_txt', 'allow' => 'geo_allow_txt', 'block' => 'geo_block_txt')
		),
		'geo_countries' => array (
			'datatype' => 'VARCHAR',
			'formtype' => 'TEXT',
			'validators' => array ( 0 => array ( 'type' => 'CUSTOM',
					'class'    => 'validate_firewall_restrict',
					'function' => 'valid_countries',
					'errmsg'   => 'geo_countries_error'),
			),
			'default'   => '',
			'value'     => '',
			'width'     => '40',
			'maxlength' => '255'
		),
		'description' => array (
			'datatype'  => 'VARCHAR',
			'formtype'  => 'TEXT',
			'default'   => '',
			'value'     => '',
			'width'     => '40',
			'maxlength' => '255'
		),
		'active' => array (
			'datatype' => 'VARCHAR',
			'formtype' => 'CHECKBOX',
			'default'  => 'y',
			'value'    => array(0 => 'n', 1 => 'y')
		),
	)
);

?>
