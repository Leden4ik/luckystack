<?php
/*
  LuckyStack: заморозка vhost, захват ручных правок файла.

  Источник правды замороженного vhost — поле web_domain.freeze_vhost_content. При сохранении сайта
  в панели или Resync генератор ISPConfig (nginx_plugin) сначала перезаписывает файл vhost по
  шаблону, потом zzz_freeze_vhost_plugin пишет поверх текст из базы. Правки, сделанные прямо в
  файле, при этом терялись: к моменту работы zzz их на диске уже нет.

  Этот плагин назван 'aaa_…', ISPConfig грузит плагины по имени, поэтому он срабатывает на
  web_domain_update ДО генератора, пока на диске ещё лежит файл с ручными правками:
    - заморозку только что включили и текста нет → снимком становится текущий файл (с ручными
      правками), а не то, что сейчас сгенерирует ISPConfig;
    - сайт уже заморожен и файл отличается от последнего применённого (копия в sites-frozen,
      а если её нет — текст в базе) → файл правили вручную:
        * текст в панели в этом сохранении не меняли → забираем файл в базу, он и применится;
        * в панели тоже правили (и иначе, чем в файле) → побеждает панель, ручная версия файла
          сохраняется рядом (sites-frozen/<домен>.vhost.manual-<время>), в статусе предупреждение.
  Забранный текст и пометку передаём zzz_freeze_vhost_plugin через $GLOBALS (тот же процесс
  server.sh, плагины вызываются по очереди).
*/

class aaa_freeze_vhost_capture_plugin {

	var $plugin_name = 'aaa_freeze_vhost_capture_plugin';
	var $class_name  = 'aaa_freeze_vhost_capture_plugin';
	var $frozen_dir  = '/etc/nginx/sites-frozen';

	function onInstall() {
		return false;
	}

	function onLoad() {
		global $app;
		$app->plugins->registerEvent('web_domain_update', $this->plugin_name, 'capture');
	}

	function capture($event_name, $data) {
		$new = (isset($data['new']) && is_array($data['new'])) ? $data['new'] : null;
		$old = (isset($data['old']) && is_array($data['old'])) ? $data['old'] : array();
		if($new === null || !isset($new['freeze_vhost']) || $new['freeze_vhost'] !== 'y') return;
		if(isset($new['active']) && $new['active'] === 'n') return;   // у выключенного сайта в файле заглушка
		if(isset($new['type']) && !in_array($new['type'], array('vhost', 'vhostsubdomain', 'vhostalias'))) return;
		$domain = isset($new['domain']) ? (string)$new['domain'] : '';
		if(!preg_match('/^[A-Za-z0-9._-]+$/', $domain)) return;
		$id = isset($new['domain_id']) ? (int)$new['domain_id'] : 0;
		if($id <= 0) return;

		$file = $this->vhost_dir().'/'.$domain.'.vhost';
		if(!is_file($file)) return;
		$live = str_replace("\r\n", "\n", (string)@file_get_contents($file));
		if(trim($live) === '') return;

		$mirror_file = $this->frozen_dir.'/'.$domain.'.vhost';
		$mirror = is_file($mirror_file) ? str_replace("\r\n", "\n", (string)@file_get_contents($mirror_file)) : null;
		$db_new = str_replace("\r\n", "\n", (string)(isset($new['freeze_vhost_content']) ? $new['freeze_vhost_content'] : ''));
		$db_old = str_replace("\r\n", "\n", (string)(isset($old['freeze_vhost_content']) ? $old['freeze_vhost_content'] : ''));
		$was_frozen = (isset($old['freeze_vhost']) && $old['freeze_vhost'] === 'y');

		// 1) заморозку только что включили
		if(!$was_frozen) {
			if(trim($db_new) !== '') return;   // админ сразу вписал свой текст — его и применит zzz
			$this->take($id, $domain, $live, 'снимок текущего файла');
			return;
		}

		// 2) уже заморожен: правили ли файл после последнего применения?
		$ref = ($mirror !== null) ? $mirror : $db_old;
		if($live === $ref) return;
		if($db_new === $db_old || $db_new === $live) {
			$this->take($id, $domain, $live, 'забраны правки из файла');
			return;
		}

		// 3) правили и файл, и текст в панели: побеждает панель, ручную версию файла сохраняем
		if(!is_dir($this->frozen_dir)) @mkdir($this->frozen_dir, 0750, true);
		$bak = $mirror_file.'.manual-'.date('Ymd-His');
		@file_put_contents($bak, $live); @chmod($bak, 0640);
		$GLOBALS['ss_fz_note'][$id] = ' (в файле были ручные правки, их перекрыла правка из панели; ручная версия: '.$bak.')';
		$this->log("freeze_vhost: $domain — файл правили вручную и одновременно текст в панели; применён текст из панели, ручная версия сохранена в $bak.", LOGLEVEL_WARN);
	}

	// забрать текст файла в базу и в копию последнего применённого
	function take($id, $domain, $content, $why) {
		global $app;
		$app->db->query("UPDATE web_domain SET freeze_vhost_content = ? WHERE domain_id = ?", $content, $id);
		if(!is_dir($this->frozen_dir)) @mkdir($this->frozen_dir, 0750, true);
		$m = $this->frozen_dir.'/'.$domain.'.vhost';
		$this->archive_prev($m, $content);
		@file_put_contents($m, $content); @chmod($m, 0640);
		$GLOBALS['ss_fz_captured'][$id] = $content;
		$GLOBALS['ss_fz_note'][$id] = ' ('.$why.')';
		$this->log("freeze_vhost: $domain — $why.", LOGLEVEL_WARN);
	}

	// История применённых версий: прежний текст кладём в <копия>.prev-<время>, храним последние 10.
	// Так ни ручная правка из файла, ни правка из панели не пропадают молча при любом порядке событий.
	function archive_prev($mirror, $new_content) {
		if(!is_file($mirror)) return;
		$old = (string)@file_get_contents($mirror);
		if($old === '' || str_replace("\r\n", "\n", $old) === str_replace("\r\n", "\n", (string)$new_content)) return;
		$dst = $mirror.'.prev-'.date('Ymd-His');
		if(is_file($dst)) $dst .= '-'.substr(md5($old), 0, 6);
		@copy($mirror, $dst); @chmod($dst, 0640);
		$all = glob($mirror.'.prev-*');
		if(is_array($all) && count($all) > 10) { sort($all); foreach(array_slice($all, 0, count($all) - 10) as $f) @unlink($f); }
	}

	function vhost_dir() {
		global $app, $conf;
		$type = 'nginx';
		if(isset($app->getconf)) {
			$wc = $app->getconf->get_server_config(isset($conf['server_id']) ? $conf['server_id'] : 1, 'web');
			if(is_array($wc) && !empty($wc['server_type'])) $type = $wc['server_type'];
		}
		if($type === 'apache') return is_dir('/etc/apache2/sites-available') ? '/etc/apache2/sites-available' : '/etc/httpd/conf.d';
		return '/etc/nginx/sites-available';
	}

	function log($msg, $level) {
		global $app;
		if(isset($app) && method_exists($app, 'log')) $app->log($msg, $level);
	}
}

?>
