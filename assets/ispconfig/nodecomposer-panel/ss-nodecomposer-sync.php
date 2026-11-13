<?php
/*
  LuckyStack: синхронизатор Node/Composer ↔ панель ISPConfig (root-cron, раз в минуту).

  Интерфейс ISPConfig (пользователь ispconfig) не может ни читать файлы сайтов (web-рут 0710),
  ни запускать npm/composer от имени юзера сайта. Поэтому:
    1) панель пишет запрос в очередь nodecomposer_action (scan/install/uninstall/install_all …);
    2) этот скрипт (root) выполняет его ОТ ИМЕНИ СИСТЕМНОГО ЮЗЕРА САЙТА (su - webX -s /bin/bash -c)
       в каталоге проекта, затем перечитывает манифест и обновляет кэш пакетов (nodecomposer_pkg).

  Безопасность: юзер/путь/имя пакета жёстко валидируются + escapeshellarg (отбой инъекций);
  путь проекта обязан быть ВНУТРИ домашнего каталога сайта (realpath). flock — не наложить долгий
  npm install следующим тиком cron.
*/

$conf = array();
require '/usr/local/ispconfig/server/lib/config.inc.php';
require '/usr/local/ispconfig/server/lib/app.inc.php';
if(!function_exists('exec')) exit(1);

$lock = @fopen('/run/ss-nodecomposer.lock', 'c');
if($lock === false) $lock = @fopen(sys_get_temp_dir().'/ss-nodecomposer.lock', 'c');
if($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) exit(0);

$have_npm      = trim((string)shell_exec('command -v npm 2>/dev/null')) !== '';
$have_composer = is_executable('/usr/local/bin/composer') || trim((string)shell_exec('command -v composer 2>/dev/null')) !== '';

// --- helpers ---------------------------------------------------------------
function nc_valid_user($u)    { return (bool)preg_match('/^[a-z][a-z0-9]{0,31}$/', (string)$u); }
function nc_valid_relpath($p) {
	$p = trim((string)$p);
	if($p === '') return true;                                   // корень home допустим
	if(strpos($p, '..') !== false) return false;
	return (bool)preg_match('#^[A-Za-z0-9._][A-Za-z0-9._/-]*$#', $p);
}
// Имя пакета. Разрешаем только пакеты из реестра: npm `name` или `@scope/name` (+ `@версия`),
// composer `vendor/name` (+ `:ограничение`). URL, git+https, github:, `user/repo`, локальные
// пути и алиасы npm: не проходят, иначе `npm -g` от root поставил бы что угодно откуда угодно.
// Те же правила в панели (admin/nodecomposer.php) и в cron (ss-nodecomposer-sync.php).
function nc_valid_pkg($p, $tool) {
	$p = trim((string)$p);
	if($p === '' || strlen($p) > 214) return false;
	if($tool === 'composer')
		return (bool)preg_match('#^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*(:[A-Za-z0-9._^~*<>=|@!, -]+)?$#', $p);
	return (bool)preg_match('#^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*(@[A-Za-z0-9._^~*<>=|+-]+)?$#', $p);
}

// собрать домашний каталог + каталог проекта, проверить что внутри home
function nc_project_dir($docroot, $relpath) {
	$home = rtrim((string)$docroot, '/');
	if($home === '' || !is_dir($home)) return null;
	$rp = trim((string)$relpath, '/');
	$dir = ($rp === '') ? $home : $home.'/'.$rp;
	$real = realpath($dir);
	$rhome = realpath($home);
	if($real === false || $rhome === false) return null;
	if($real !== $rhome && strpos($real, $rhome.'/') !== 0) return null;   // строго внутри home
	return $real;
}

// перечитать манифест (как root) и обновить кэш пакетов проекта
function nc_refresh_cache($app, $domain_id, $tool, $relpath, $projdir) {
	$manifest = $projdir.'/'.($tool === 'composer' ? 'composer.json' : 'package.json');
	$app->db->query("DELETE FROM nodecomposer_pkg WHERE domain_id = ? AND tool = ? AND relpath = ?", $domain_id, $tool, $relpath);
	if(!is_file($manifest)) return;
	$j = json_decode((string)@file_get_contents($manifest), true);
	if(!is_array($j)) return;
	$deps = array();
	if($tool === 'composer') {
		foreach(array('require','require-dev') as $k) if(isset($j[$k]) && is_array($j[$k])) $deps += $j[$k];
	} else {
		foreach(array('dependencies','devDependencies') as $k) if(isset($j[$k]) && is_array($j[$k])) $deps += $j[$k];
	}
	foreach($deps as $name => $ver) {
		$app->db->query("INSERT INTO nodecomposer_pkg (domain_id, tool, relpath, name, version, updated) VALUES (?,?,?,?,?,NOW())",
			$domain_id, $tool, $relpath, substr((string)$name,0,128), substr((string)$ver,0,64));
	}
}

// --- выполнить ОДНУ ожидающую задачу ---------------------------------------
$job = $app->db->queryOneRecord("SELECT * FROM nodecomposer_action WHERE status = 'pending' ORDER BY id ASC LIMIT 1");
if(is_array($job) && !empty($job)) {
	$id = (int)$job['id'];
	$tool = ($job['tool'] === 'composer') ? 'composer' : 'node';
	$act  = (string)$job['action'];
	$relpath = (string)$job['relpath'];
	$pkg  = (string)$job['package'];
	$fail = function($msg) use ($app, $id) {
		$app->db->query("UPDATE nodecomposer_action SET status='error', result=?, processed=NOW() WHERE id=?", substr($msg,0,4000), $id);
	};

	// ---- ГЛОБАЛЬНЫЙ режим (системно, от ROOT). node → npm -g; composer → composer global. ----
	if((int)$job['domain_id'] === 0 && $relpath === '__global__') {
		$needpkg = in_array($act, array('install','uninstall','require','remove'), true);
		$toolok  = ($tool === 'node') ? $GLOBALS['have_npm'] : $GLOBALS['have_composer'];
		if(!$toolok)                                  { $fail($tool.' not installed'); }
		elseif($needpkg && !nc_valid_pkg($pkg, $tool)) { $fail('invalid package name'); }
		else {
			$cmd = '';
			if($tool === 'node') {
				switch($act) {
					case 'install':   $cmd = 'npm install -g --no-fund --no-audit --no-progress '.escapeshellarg($pkg); break;
					case 'uninstall': $cmd = 'npm uninstall -g --no-fund --no-audit --no-progress '.escapeshellarg($pkg); break;
					// npm outdated -g завершается кодом 1, когда есть устаревшие — трактуем как «выполнено».
					case 'outdated':  $cmd = 'npm outdated -g --no-fund --no-audit --no-progress || true'; break;
					case 'scan':      $cmd = 'true'; break;
				}
			} else {
				// глобальный composer от ROOT — осознанно разрешаем суперюзера (иначе предупреждения/отказ плагинов).
				$env = 'export COMPOSER_MEMORY_LIMIT=-1 COMPOSER_NO_INTERACTION=1 COMPOSER_ALLOW_SUPERUSER=1; ';
				switch($act) {
					case 'require':   $cmd = $env.'composer global require --no-progress '.escapeshellarg($pkg); break;
					case 'remove':    $cmd = $env.'composer global remove --no-progress '.escapeshellarg($pkg); break;
					case 'outdated':  $cmd = $env.'composer global outdated --direct || true'; break;
					case 'scan':      $cmd = 'true'; break;
				}
			}
			if($cmd === '')                           { $fail('unknown action'); }
			else {
				$app->db->query("UPDATE nodecomposer_action SET status='running', processed=NOW() WHERE id=?", $id);
				$out = array(); $rc = 0;
				if($cmd !== 'true') exec('HOME=/root '.$cmd.' 2>&1', $out, $rc);
				// кэш глобальных пакетов (только для install/uninstall/require/remove/scan; outdated не трогает список)
				if($act !== 'outdated') {
					$app->db->query("DELETE FROM nodecomposer_pkg WHERE domain_id=0 AND tool=? AND relpath='__global__'", $tool);
					if($tool === 'node') {
						$gj = json_decode((string)shell_exec('HOME=/root npm ls -g --depth=0 --json 2>/dev/null'), true);
						if(is_array($gj) && isset($gj['dependencies']) && is_array($gj['dependencies'])) {
							foreach($gj['dependencies'] as $nm => $info) {
								$ver = (is_array($info) && isset($info['version'])) ? $info['version'] : '';
								$app->db->query("INSERT INTO nodecomposer_pkg (domain_id, tool, relpath, name, version, updated) VALUES (0,'node','__global__',?,?,NOW())",
									substr((string)$nm,0,128), substr((string)$ver,0,64));
							}
						}
					} else {
						$gj = json_decode((string)shell_exec('HOME=/root COMPOSER_NO_INTERACTION=1 COMPOSER_ALLOW_SUPERUSER=1 composer global show --direct --format=json 2>/dev/null'), true);
						if(is_array($gj) && isset($gj['installed']) && is_array($gj['installed'])) {
							foreach($gj['installed'] as $info) {
								$nm  = (is_array($info) && isset($info['name']))    ? $info['name']    : '';
								$ver = (is_array($info) && isset($info['version'])) ? $info['version'] : '';
								if($nm === '') continue;
								$app->db->query("INSERT INTO nodecomposer_pkg (domain_id, tool, relpath, name, version, updated) VALUES (0,'composer','__global__',?,?,NOW())",
									substr((string)$nm,0,128), substr((string)$ver,0,64));
							}
						}
					}
				}
				$res = trim(implode("\n", $out));
				$app->db->query("UPDATE nodecomposer_action SET status=?, result=?, processed=NOW() WHERE id=?",
					($rc === 0 ? 'done' : 'error'), substr($res, -4000), $id);
			}
		}
		$app->db->query("DELETE FROM nodecomposer_action WHERE status IN ('done','error') AND processed < (NOW() - INTERVAL 7 DAY)");
		flock($lock, LOCK_UN);
		exit(0);
	}

	$site = $app->db->queryOneRecord("SELECT domain_id, system_user, document_root FROM web_domain WHERE domain_id = ?", (int)$job['domain_id']);
	if(!is_array($site) || empty($site))                 { $fail('site not found'); }
	elseif(!nc_valid_user($site['system_user']))         { $fail('invalid system user'); }
	elseif(!nc_valid_relpath($relpath))                  { $fail('invalid path'); }
	else {
		$projdir = nc_project_dir($site['document_root'], $relpath);
		if($projdir === null)                            { $fail('project dir not found / outside home'); }
		elseif(($tool==='node' && !$GLOBALS['have_npm']) || ($tool==='composer' && !$GLOBALS['have_composer'])) { $fail($tool.' not installed'); }
		else {
			// собрать команду инструмента
			$needpkg = in_array($act, array('install','uninstall','require','remove'), true);
			if($needpkg && !nc_valid_pkg($pkg, $tool))   { $fail('invalid package name'); }
			else {
				$cmd = '';
				if($tool === 'node') {
					switch($act) {
						case 'install':     $cmd = 'npm install --no-fund --no-audit --no-progress '.escapeshellarg($pkg); break;
						case 'uninstall':   $cmd = 'npm uninstall --no-fund --no-audit --no-progress '.escapeshellarg($pkg); break;
						case 'install_all': $cmd = 'npm install --no-fund --no-audit --no-progress'; break;
						// npm outdated завершается кодом 1, когда есть устаревшие — трактуем как «выполнено».
						case 'outdated':    $cmd = 'npm outdated --no-fund --no-audit --no-progress || true'; break;
						case 'scan':        $cmd = 'true'; break;
					}
				} else {
					$env = 'export COMPOSER_MEMORY_LIMIT=-1 COMPOSER_NO_INTERACTION=1; ';
					switch($act) {
						case 'require':     $cmd = $env.'composer require --no-progress '.escapeshellarg($pkg); break;
						case 'remove':      $cmd = $env.'composer remove --no-progress '.escapeshellarg($pkg); break;
						case 'install_all': $cmd = $env.'composer install --no-progress --no-dev --optimize-autoloader'; break;
						case 'outdated':    $cmd = $env.'composer outdated --direct || true'; break;
						case 'scan':        $cmd = 'true'; break;
					}
				}
				if($cmd === '')                          { $fail('unknown action'); }
				else {
					$app->db->query("UPDATE nodecomposer_action SET status='running', processed=NOW() WHERE id=?", $id);
					// HOME для кэшей npm/composer (~/.npm, ~/.composer): домашний каталог сайта обычно
					// immutable (ISPConfig web_folder_protection) → npm/composer падают с EPERM. Даём им
					// писать в tmp сайта (web4-writable, не immutable, не веб-раздаётся), иначе — в проект.
					$sitehome = rtrim((string)$site['document_root'], '/');
					$hdir = is_dir($sitehome.'/tmp') ? $sitehome.'/tmp' : $projdir;
					$full = 'export HOME='.escapeshellarg($hdir).'; cd '.escapeshellarg($projdir).' && '.$cmd;
					$su = 'su - '.escapeshellarg($site['system_user']).' -s /bin/bash -c '.escapeshellarg($full).' 2>&1';
					$out = array(); $rc = 0;
					exec($su, $out, $rc);
					$res = trim(implode("\n", $out));
					nc_refresh_cache($app, (int)$site['domain_id'], $tool, $relpath, $projdir);
					$app->db->query("UPDATE nodecomposer_action SET status=?, result=?, processed=NOW() WHERE id=?",
						($rc === 0 ? 'done' : 'error'), substr($res, -4000), $id);
				}
			}
		}
	}
}

// подчистить старые завершённые задачи (>7 дней)
$app->db->query("DELETE FROM nodecomposer_action WHERE status IN ('done','error') AND processed < (NOW() - INTERVAL 7 DAY)");
flock($lock, LOCK_UN);
exit(0);
?>
