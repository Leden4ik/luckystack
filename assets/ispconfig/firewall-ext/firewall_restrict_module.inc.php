<?php
/*
  LuckyStack: серверный МОДУЛЬ для таблицы firewall_restrict.

  В ISPConfig события плагинов (firewall_restrict_insert/update/delete) поднимает не сам
  плагин, а МОДУЛЬ, зарегистрировавший хук на таблицу в sys_datalog. Для нашей кастомной
  таблицы firewall_restrict штатного модуля нет → при сохранении в панели запись попадает
  в таблицу и в sys_datalog, но плагин НЕ вызывается, и /etc/ufw/before.rules не пересобирается.

  Этот модуль регистрирует хук на firewall_restrict и поднимает события, на которые подписан
  firewall_restrict_plugin (он и делает rebuild before.rules). Лежит в mods-available, включается
  симлинком в mods-enabled. ОТДЕЛЬНЫЙ (не core) — переживает обновления ISPConfig.
*/

class firewall_restrict_module {

	var $module_name = 'firewall_restrict_module';
	var $class_name  = 'firewall_restrict_module';
	var $actions_available = array('firewall_restrict_insert', 'firewall_restrict_update', 'firewall_restrict_delete');

	function onInstall() {
		global $conf;
		// включаем там же, где есть веб-сервис (ufw/firewall живёт на веб-узле)
		return (isset($conf['services']['web']) && $conf['services']['web'] == true);
	}

	function onLoad() {
		global $app;
		// 1) ОБЪЯВИТЬ события доступными — иначе плагин не сможет на них подписаться
		//    (registerEvent в ISPConfig молча игнорирует не-анонсированные события).
		$app->plugins->announceEvents($this->module_name, $this->actions_available);
		// 2) при изменении строк firewall_restrict в sys_datalog → вызвать process()
		$app->modules->registerTableHook('firewall_restrict', 'firewall_restrict_module', 'process');
	}

	// $action из sys_datalog: 'i' | 'u' | 'd' (в части версий — INSERT/UPDATE/DELETE).
	function process($tablename, $action, $data) {
		global $app;
		$a = strtolower((string)$action);
		if($a === 'i' || $a === 'insert')      $app->plugins->raiseEvent('firewall_restrict_insert', $data);
		elseif($a === 'u' || $a === 'update')  $app->plugins->raiseEvent('firewall_restrict_update', $data);
		elseif($a === 'd' || $a === 'delete')  $app->plugins->raiseEvent('firewall_restrict_delete', $data);
	}
}

?>
