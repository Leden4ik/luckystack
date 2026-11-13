<?php
/*
  LuckyStack: наши панели отдельной группой в меню System, чтобы не путать их с родными пунктами
  ISPConfig. Файл из lib/menu.d читается каждый раз при открытии модуля и переживает обновление
  ISPConfig, в отличие от правок module.conf.php. Показываем только то, что реально установлено.
*/
if($app->auth->is_admin()) {
	$ss_ru = (isset($_SESSION['s']['language']) && $_SESSION['s']['language'] === 'ru');
	$ss_dir = ISPC_WEB_PATH.'/admin/';
	// страница, адрес в меню, html_id, название, название по-русски, условие показа
	$ss_all = array(
		array('ss_maint.php', 'admin/ss_maint.php', 'ss_maint', 'Server maintenance', 'Обслуживание сервера', true),
		array('notify_settings.php', 'admin/notify_settings.php', 'notify_settings', 'Notifications', 'Уведомления', true),
		array('backup_restore_list.php', 'admin/backup_restore_list.php', 'backup_restore_list', 'Backup / Restore', 'Бэкап и восстановление', true),
		array('firewall_restrict_list.php', 'admin/firewall_restrict_list.php', 'firewall_restrict_list', 'Firewall IP-rules', 'Firewall: правила по IP', true),
		array('ufw_block_list.php', 'admin/ufw_block_list.php', 'ufw_block_list', 'Firewall block-list', 'Firewall: блок-лист', true),
		array('trusted_ips.php', 'admin/trusted_ips.php', 'trusted_ips', 'Trusted IPs', 'Доверенные IP', true),
		array('crowdsec_list.php', 'admin/crowdsec_list.php', 'crowdsec_list', 'CrowdSec', 'CrowdSec', true),
		array('fail2ban_list.php', 'admin/fail2ban_list.php', 'fail2ban_list', 'Fail2ban', 'Fail2ban', true),
		array('nodecomposer.php', 'admin/nodecomposer.php?tool=node', 'node_apps', 'Node.js', 'Node.js', '@@NODE@@' === 'y'),
		array('nodecomposer.php', 'admin/nodecomposer.php?tool=composer', 'composer_apps', 'Composer', 'Composer', '@@COMPOSER@@' === 'y'),
	);
	$ss_items = array();
	foreach($ss_all as $ss_i) {
		if(!$ss_i[5] || !is_file($ss_dir.$ss_i[0])) continue;
		$ss_items[] = array('title' => $ss_ru ? $ss_i[4] : $ss_i[3], 'target' => 'content', 'link' => $ss_i[1], 'html_id' => $ss_i[2]);
	}

	$ss_pos = count($module['nav']);
	foreach($module['nav'] as $ss_k => $ss_nav) {
		// Родной пункт Firewall прячем при нашем модуле: он отключает ufw, а обновление ISPConfig его возвращает.
		if(is_file($ss_dir.'firewall_restrict_list.php') && isset($ss_nav['items'])) {
			foreach($ss_nav['items'] as $ss_n => $ss_it) {
				if(isset($ss_it['link']) && $ss_it['link'] === 'admin/firewall_list.php') unset($module['nav'][$ss_k]['items'][$ss_n]);
			}
			$module['nav'][$ss_k]['items'] = array_values($module['nav'][$ss_k]['items']);
		}
		if(isset($ss_nav['title']) && $ss_nav['title'] === 'System') $ss_pos = array_search($ss_k, array_keys($module['nav'])) + 1;
	}
	if($ss_items) {
		array_splice($module['nav'], $ss_pos, 0, array(array(
			'title' => $ss_ru ? 'Дополнения' : 'Add-ons',
			'open'  => 1,
			'items' => $ss_items,
		)));
	}
	unset($ss_ru, $ss_dir, $ss_all, $ss_i, $ss_items, $ss_pos, $ss_k, $ss_nav, $ss_n, $ss_it);
}
