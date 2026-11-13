<?php
/*
  LuckyStack: «заморозка» vhost сайта — галочка «Не обновлять vhost» в панели ISPConfig.

  Зачем: при любом сохранении сайта core-плагин ISPConfig (nginx_plugin/apache2_plugin)
  ПОЛНОСТЬЮ перегенерирует /etc/nginx/sites-available/<домен>.vhost из шаблона, затирая
  ручные правки. Этот плагин даёт per-site заморозку: если у сайта стоит freeze_vhost='y',
  после регенерации мы возвращаем «замороженную» версию из /etc/nginx/sites-frozen/<домен>.vhost.

  Источник правды — колонка web_domain.freeze_vhost_content (правится textarea в панели,
  вкладка Options, ТОЛЬКО для админа). Интерфейс ISPConfig работает под непривилегированным
  пользователем и не может писать в /etc/nginx/sites-frozen (root:root) — поэтому контент
  хранится в БД, а на диск его кладёт этот серверный плагин (root).

  Как работает (snapshot + restore, БЕЗ модификации core):
    - плагин назван 'zzz_…' → в plugins-enabled грузится ПОСЛЕ nginx_plugin, поэтому его
      обработчик web_domain_update срабатывает ПОСЛЕ того, как core записал свежий vhost;
    - freeze_vhost='y' и контент пуст → загружаем текущий сгенерированный vhost в БД-поле
      (чтобы в панели было что править); live-vhost не трогаем (он и есть этот снимок);
    - freeze_vhost='y' и контент есть → пишем его поверх сгенерированного, `<srv> -t`
      (проверка конфигурации), reload. Если не прошла — ОТКАТ к сгенерированному
      (чтобы кривой контент не уронил весь веб-сервер). Заодно пишем зеркало в sites-frozen;
    - сайт отключён (active='n') → не вмешиваемся (пусть core поставит заглушку);
    - freeze_vhost='n' → чистим контент в БД (повторная заморозка снимет свежий снимок) и зеркало;
    - web_domain_delete → удаляем зеркало (не воскрешаем удалённый сайт).

  ОТДЕЛЬНЫЙ (не core) плагин — переживает обновления ISPConfig. Имя файла = имя класса
  (так ISPConfig инстанцирует плагин), префикс 'zzz_' критичен для порядка загрузки.
*/

class zzz_freeze_vhost_plugin {

	var $plugin_name = 'zzz_freeze_vhost_plugin';
	var $class_name  = 'zzz_freeze_vhost_plugin';
	var $frozen_dir  = '/etc/nginx/sites-frozen';

	function onInstall() {
		return false;
	}

	function onLoad() {
		global $app;
		$app->plugins->registerEvent('web_domain_insert', $this->plugin_name, 'apply');
		$app->plugins->registerEvent('web_domain_update', $this->plugin_name, 'apply');
		$app->plugins->registerEvent('web_domain_delete', $this->plugin_name, 'remove');
	}

	// Применить заморозку (вернуть frozen-vhost поверх сгенерированного) после core-плагина.
	function apply($event_name, $data) {
		global $app, $conf;

		$rec = (isset($data['new']) && is_array($data['new'])) ? $data['new'] : null;
		if($rec === null) return;

		$domain = isset($rec['domain']) ? $rec['domain'] : '';
		if(!$this->valid_domain($domain)) return;

		// тип записи: отдельный файл vhost есть только у vhost/vhostsubdomain/vhostalias.
		if(isset($rec['type']) && !in_array($rec['type'], array('vhost', 'vhostsubdomain', 'vhostalias'))) return;

		list($srv, $vhost_dir, $test_cmd, $reload_cmd) = $this->server_info();
		$vhost_file  = rtrim($vhost_dir, '/').'/'.$domain.'.vhost';
		$mirror      = $this->frozen_dir.'/'.$domain.'.vhost';
		$domain_id   = isset($rec['domain_id']) ? (int)$rec['domain_id'] : 0;

		// не заморожен — очистить контент в БД (свежий снимок при повторной заморозке) и зеркало
		if(!isset($rec['freeze_vhost']) || $rec['freeze_vhost'] !== 'y') {
			if($domain_id > 0 && isset($rec['freeze_vhost_content']) && trim((string)$rec['freeze_vhost_content']) !== '')
				$app->db->query("UPDATE web_domain SET freeze_vhost_content = '' WHERE domain_id = ?", $domain_id);
			if(is_file($mirror)) @unlink($mirror);
			return;
		}

		// отключённый сайт — не трогаем (пусть стоит заглушка core)
		if(isset($rec['active']) && $rec['active'] === 'n') return;

		if(!is_dir($this->frozen_dir)) @mkdir($this->frozen_dir, 0750, true);

		$content = isset($rec['freeze_vhost_content']) ? (string)$rec['freeze_vhost_content'] : '';
		$content = str_replace("\r\n", "\n", $content);

		// Новый текст vhost принимаем только от админа панели. Поля пишет только админский
		// контроллер формы (в tform их нет), здесь проверка на случай любого другого пути записи.
		// Не админ → оставляем прежний одобренный текст, пишем статус «отклонено».
		$old_content = (isset($data['old']) && is_array($data['old']) && isset($data['old']['freeze_vhost_content']))
			? str_replace("\r\n", "\n", (string)$data['old']['freeze_vhost_content']) : '';
		// Плагин захвата (aaa_freeze_vhost_capture_plugin) срабатывает ДО генератора ISPConfig и,
		// если файл правили вручную, уже забрал его текст в базу. Этот текст пришёл от root из файла
		// на диске, проверка автора-админа к нему не относится. Пометку для статуса берём оттуда же.
		$note = isset($GLOBALS['ss_fz_note'][$domain_id]) ? $GLOBALS['ss_fz_note'][$domain_id] : '';
		// Пришёл ровно тот текст, что уже применён (копия в sites-frozen), например второе событие от
		// того же сохранения формы: ничего нового, оставляем пометку из прежнего статуса, чтобы
		// предупреждение не затёрлось простым «ok».
		$applied_now = is_file($mirror) ? str_replace("\r\n", "\n", (string)@file_get_contents($mirror)) : null;
		if($note === '' && $domain_id > 0 && !isset($GLOBALS['ss_fz_captured'][$domain_id])
			&& $applied_now !== null && $content === $applied_now) {
			$prev = $app->db->queryOneRecord("SELECT freeze_vhost_status FROM web_domain WHERE domain_id = ?", $domain_id);
			if(is_array($prev) && preg_match('/^ok .*?( \(.+\))$/s', (string)$prev['freeze_vhost_status'], $pm)) $note = $pm[1];
		}
		$captured = isset($GLOBALS['ss_fz_captured'][$domain_id]);
		if($captured) $content = $old_content = $GLOBALS['ss_fz_captured'][$domain_id];
		unset($GLOBALS['ss_fz_captured'][$domain_id], $GLOBALS['ss_fz_note'][$domain_id]);
		if(!$captured && trim($content) !== '' && $content !== $old_content && !$this->author_is_admin()) {
			$note = ' (изменение текста не админом панели отклонено, оставлен прежний)';
			if($domain_id > 0) $app->db->query("UPDATE web_domain SET freeze_vhost_content = ?, freeze_vhost_status = ? WHERE domain_id = ?",
				$old_content, 'error: текст vhost изменён не админом панели, отклонено '.date('Y-m-d H:i'), $domain_id);
			$this->log("freeze_vhost: $domain — текст vhost изменён не админом панели, изменение отклонено.", LOGLEVEL_WARN);
			$content = $old_content;
			if(trim($content) === '') return;
		}

		// первый раз (контент пуст) — загрузить текущий сгенерированный vhost в редактор (БД),
		// чтобы в панели было что править. Сам live-vhost не трогаем (он и есть этот снимок).
		if(trim($content) === '') {
			if($domain_id > 0 && is_file($vhost_file)) {
				$seed = @file_get_contents($vhost_file);
				if($seed !== false && trim($seed) !== '') {
					// снимок = и контент (правится), и «сгенерированное» (для diff/re-seed/дрейфа)
					$app->db->query("UPDATE web_domain SET freeze_vhost_content = ?, freeze_vhost_generated = ?, freeze_vhost_status = ? WHERE domain_id = ?", $seed, $seed, 'ok '.date('Y-m-d H:i').' (snapshot)', $domain_id);
					@file_put_contents($mirror, $seed); @chmod($mirror, 0640);
					$this->log("freeze_vhost: $domain — текущий vhost загружен в редактор панели (правьте поле в Options).", LOGLEVEL_WARN);
				}
			}
			return;
		}

		// применить контент из БД поверх сгенерированного, с проверкой конфигурации и откатом
		if(!is_file($vhost_file)) return;
		if($srv === 'nginx') {
			$old_gen = (isset($data['old']) && is_array($data['old']) && isset($data['old']['freeze_vhost_generated'])) ? (string)$data['old']['freeze_vhost_generated'] : '';
			$this->sync_php_target($content, (string)@file_get_contents($vhost_file), $old_gen, $rec, $domain_id, $note);
		}
		$this->archive_prev($mirror, $content);
		@file_put_contents($mirror, $content); @chmod($mirror, 0640);
		$cur = @file_get_contents($vhost_file);
		// сохранить «что сгенерировал бы core» (он только что это и записал) — для diff/re-seed/
		// детектора дрейфа в панели.
		if($domain_id > 0 && $cur !== false) $app->db->query("UPDATE web_domain SET freeze_vhost_generated = ? WHERE domain_id = ?", $cur, $domain_id);
		if($cur === $content) { // уже совпадает — применять нечего, но статус «ок»
			if($domain_id > 0) $app->db->query("UPDATE web_domain SET freeze_vhost_status = ? WHERE domain_id = ?", 'ok '.date('Y-m-d H:i').$note, $domain_id);
			return;
		}

		@copy($vhost_file, $vhost_file.'.prefreeze');
		@file_put_contents($vhost_file, $content);

		$out = array(); $ret = 0;
		exec($test_cmd.' 2>&1', $out, $ret);
		if($ret !== 0) {
			@copy($vhost_file.'.prefreeze', $vhost_file);
			@unlink($vhost_file.'.prefreeze');
			if($domain_id > 0) $app->db->query("UPDATE web_domain SET freeze_vhost_status = ? WHERE domain_id = ?", 'error: '.substr(trim(implode(' ', $out)), 0, 240), $domain_id);
			$this->log("freeze_vhost: контент vhost $domain не прошёл проверку конфигурации — ОТКАТ к сгенерированному. ".implode(' ', $out), LOGLEVEL_ERROR);
			return;
		}
		@unlink($vhost_file.'.prefreeze');
		exec($reload_cmd.' >/dev/null 2>&1');
		if($domain_id > 0) $app->db->query("UPDATE web_domain SET freeze_vhost_status = ? WHERE domain_id = ?", 'ok '.date('Y-m-d H:i').$note, $domain_id);
		$this->log("freeze_vhost: применён замороженный vhost для $domain.", LOGLEVEL_DEBUG);
	}

	// Адреса PHP в vhost, без CGI и HHVM: у них своя жизнь.
	function php_targets($text) {
		$out = array();
		if(preg_match_all('/^[ \t]*fastcgi_pass[ \t]+([^\s;]+)[ \t]*;/m', (string)$text, $m)) {
			foreach($m[1] as $t) if(strpos($t, 'fcgiwrap') === false && strpos($t, 'hhvm') === false) $out[$t] = true;
		}
		return array_keys($out);
	}

	// Смена версии PHP адрес не меняет: сокет один на все версии, порт зависит от номера сайта. Но смена
	// сокета на порт меняет, и замороженный текст остался бы со старым адресом: на каждый .php был бы 502,
	// а статус говорил бы «ok». Свой адрес обновляем сами, потому что его только что выдала сама панель.
	// Адрес, вписанный вручную, не трогаем и пишем об этом в статусе.
	function sync_php_target(&$content, $generated, $old_generated, $rec, $domain_id, &$note) {
		global $app;
		// эти пометки считаем заново при каждом применении
		$note = preg_replace('/ \((PHP у сайта выключен|адрес PHP задан вручную)[^)]*\)/u', '', (string)$note);
		$in = $this->php_targets($content);
		if(empty($in)) return;
		$want = $this->php_targets($generated);
		if(isset($rec['php']) && ($rec['php'] === 'no' || $rec['php'] === '')) {
			$note .= ' (PHP у сайта выключен, а в замороженном тексте он остался: на .php будет 502)';
			return;
		}
		if(count($want) !== 1) return;
		$want = $want[0];
		$old = $this->php_targets($old_generated);
		$user = isset($rec['system_user']) ? (string)$rec['system_user'] : '';
		$changed = array(); $manual = array();
		foreach($in as $t) {
			if($t === $want) continue;
			$ours = in_array($t, $old, true)
				|| ($user !== '' && preg_match('#^unix:.*/'.preg_quote($user, '#').'\.sock$#', $t))
				|| preg_match('#^(127\.0\.0\.1|localhost):[0-9]+$#', $t);
			if($ours) $changed[] = $t; else $manual[] = $t;
		}
		if($changed) {
			foreach($changed as $t) $content = preg_replace('/^([ \t]*fastcgi_pass[ \t]+)'.preg_quote($t, '/').'([ \t]*;)/m', '${1}'.$want.'${2}', $content);
			if($domain_id > 0) $app->db->query("UPDATE web_domain SET freeze_vhost_content = ? WHERE domain_id = ?", $content, $domain_id);
			$note .= ' (адрес PHP обновлён '.date('Y-m-d').': '.implode(', ', $changed).' на '.$want.')';
			$this->log("freeze_vhost: {$rec['domain']} — адрес PHP в замороженном тексте обновлён на $want.", LOGLEVEL_WARN);
		}
		if($manual) $note .= ' (адрес PHP задан вручную и не менялся: '.implode(', ', $manual).'. Панель ждёт '.$want.')';
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

	// Удаление сайта — снять frozen-копию.
	function remove($event_name, $data) {
		$rec = (isset($data['old']) && is_array($data['old'])) ? $data['old'] : null;
		if($rec === null) return;
		$domain = isset($rec['domain']) ? $rec['domain'] : '';
		if(!$this->valid_domain($domain)) return;
		$frozen_file = $this->frozen_dir.'/'.$domain.'.vhost';
		if(is_file($frozen_file)) @unlink($frozen_file);
	}

	// nginx или apache: каталог vhost + команды проверки/reload.
	function server_info() {
		global $app, $conf;
		$type = 'nginx';
		if(isset($app->getconf)) {
			$wc = $app->getconf->get_server_config(isset($conf['server_id']) ? $conf['server_id'] : 1, 'web');
			if(is_array($wc) && !empty($wc['server_type'])) $type = $wc['server_type'];
		}
		if($type === 'apache') {
			$dir = is_dir('/etc/apache2/sites-available') ? '/etc/apache2/sites-available' : '/etc/httpd/conf.d';
			$test = file_exists('/usr/sbin/apache2ctl') ? 'apache2ctl -t' : 'apachectl -t';
			$reload = file_exists('/usr/sbin/apache2ctl') ? 'systemctl reload apache2' : 'systemctl reload httpd';
			return array('apache', $dir, $test, $reload);
		}
		return array('nginx', '/etc/nginx/sites-available', 'nginx -t', 'systemctl reload nginx');
	}

	// Автор текущей записи sys_datalog — пользователь панели с типом admin?
	// Remote API пишет от имени 'admin' (client_id=0) или клиента. Клиенты и реселлеры не проходят.
	function author_is_admin() {
		global $app;
		$id = (isset($app->modules) && isset($app->modules->current_datalog_id)) ? (int)$app->modules->current_datalog_id : 0;
		if($id <= 0) return false;
		$db = (isset($app->dbmaster) && is_object($app->dbmaster)) ? $app->dbmaster : $app->db;
		$d = $db->queryOneRecord("SELECT user FROM sys_datalog WHERE datalog_id = ?", $id);
		if(!is_array($d) || (string)$d['user'] === '') return false;
		$u = $db->queryOneRecord("SELECT typ FROM sys_user WHERE username = ?", $d['user']);
		return is_array($u) && $u['typ'] === 'admin';
	}

	function valid_domain($d) {
		return is_string($d) && $d !== '' && preg_match('/^[A-Za-z0-9._-]+$/', $d);
	}

	function log($msg, $level) {
		global $app;
		if(isset($app) && method_exists($app, 'log')) $app->log($msg, $level);
	}
}

?>
