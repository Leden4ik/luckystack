<?php
/*
  LuckyStack: страница «Node.js / Composer» (только админ). Одна страница, режим ?tool=node|composer.
  По-сайтово: выбрать сайт + каталог проекта → список пакетов (кэш nodecomposer_pkg) + установить/
  удалить/установить все. Действия идут в очередь nodecomposer_action; root-cron выполняет их ОТ
  ИМЕНИ ЮЗЕРА САЙТА (см. ss-nodecomposer-sync.php). Локализована (en + язык пользователя).
*/

require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';
require_once '../../lib/ss_panel.inc.php';
$app->auth->check_module_permissions('admin');
if(!$app->auth->is_admin()) die('Allowed for administrators only.');
$app->uses('functions');

$wb = array();
$_ld = __DIR__.'/lib/lang/';
@include $_ld.'en_nodecomposer.lng';
$_ul = isset($_SESSION['s']['language']) ? preg_replace('/[^a-z]/', '', $_SESSION['s']['language']) : 'en';
if($_ul && $_ul !== 'en' && file_exists($_ld.$_ul.'_nodecomposer.lng')) @include $_ld.$_ul.'_nodecomposer.lng';
function _ncL($k) { global $wb; return isset($wb[$k]) ? $wb[$k] : $k; }
$h = function($s){ global $app; return $app->functions->htmlentities((string)$s); };

$tool    = (isset($_GET['tool']) && $_GET['tool'] === 'composer') ? 'composer' : 'node';
$site_raw = isset($_GET['site']) ? $_GET['site'] : '';
// глобальный режим (npm -g, системно, от root) — только для Node
$global  = ($site_raw === 'global');   // глобально: node → npm -g; composer → composer global (root)
$site    = (int)$site_raw;
$relpath = $global ? '__global__' : (isset($_GET['path']) ? trim($_GET['path']) : 'web');
// действия (установить/удалить/все/скан/устаревшие) только POST + CSRF-токен; просмотр — GET
$do      = '';
$pkg     = '';
if(ss_is_action()) { $do = ss_post('do'); $pkg = ss_post('pkg'); }
$title   = ($tool === 'composer') ? 'Composer' : 'Node.js (npm)';
$manifest = ($tool === 'composer') ? 'composer.json' : 'package.json';

// валидации (дублируют cron)
$ok_path = ($relpath === '' || (strpos($relpath,'..') === false && preg_match('#^[A-Za-z0-9._][A-Za-z0-9._/-]*$#', $relpath)));
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
$ok_pkg  = ($pkg === '' || nc_valid_pkg($pkg, $tool));

$msg = '';
if($do !== '' && ($site > 0 || $global)) {
	// маппинг «общего» действия на действие инструмента (install_all в global-режиме нет)
	$map = ($tool === 'composer')
		? array('add'=>'require','del'=>'remove','all'=>'install_all','scan'=>'scan','outdated'=>'outdated')
		: array('add'=>'install','del'=>'uninstall','all'=>'install_all','scan'=>'scan','outdated'=>'outdated');
	$action = isset($map[$do]) ? $map[$do] : '';
	$need = in_array($do, array('add','del'), true);
	$valid_site = $global ? true : is_array($app->db->queryOneRecord("SELECT domain_id FROM web_domain WHERE domain_id = ?", $site));
	if($global && $do === 'all')                     $msg = '<div class="alert alert-danger">'.$h(_ncL('bad_input_txt')).'</div>';
	elseif(!$action || !$valid_site)                 $msg = '<div class="alert alert-danger">'.$h(_ncL('bad_input_txt')).'</div>';
	elseif(!$global && !$ok_path)                    $msg = '<div class="alert alert-danger">'.$h(_ncL('bad_path_txt')).'</div>';
	elseif($need && !$ok_pkg)                         $msg = '<div class="alert alert-danger">'.$h(_ncL('bad_pkg_txt')).'</div>';
	else {
		$app->db->query("INSERT INTO nodecomposer_action (tool, action, domain_id, relpath, package, status, created) VALUES (?,?,?,?,?, 'pending', NOW())",
			$tool, $action, ($global ? 0 : $site), $relpath, ($need ? $pkg : ''));
		ss_audit('nodecomposer', $action, $tool.' '.($global ? 'global' : 'site#'.$site.' '.$relpath).($need ? ' '.$pkg : ''));
		$msg = '<div class="alert alert-warning"><b>'.$h(_ncL('queued_txt')).'</b> '.$h($do).($need?' '.$h($pkg):'').'. '.$h(_ncL('queued_hint_txt')).'</div>';
	}
}

echo '<div class="page-header"><h1>'.$h($title).'</h1></div>';
echo '<p>'.$h(_ncL('desc_txt')).'</p>';
echo '<div class="alert alert-info">'.$h(_ncL('howto_txt')).'</div>';
echo $msg;
echo ss_action_form('nodecomposer');

// --- выбор сайта + путь (навигация через loadContent — НЕ form submit: в SPA он уходит на index.php) ---
$sites = $app->db->queryAllRecords("SELECT domain_id, domain, system_user FROM web_domain WHERE active='y' AND type='vhost' ORDER BY domain");
if(!is_array($sites)) $sites = array();
echo '<div style="margin:8px 0;">';
echo '<span>'.$h(_ncL('site_txt')).': </span><select id="nc_site" class="form-control" style="display:inline-block;width:300px;">';
echo '<option value="0">— '.$h(_ncL('choose_txt')).' —</option>';
echo '<option value="global"'.($global?' selected':'').'>🌐 '.$h(_ncL('global_txt')).'</option>';
foreach($sites as $s) echo '<option value="'.(int)$s['domain_id'].'"'.((!$global && $s['domain_id']==$site)?' selected':'').'>'.$h($s['domain']).' ('.$h($s['system_user']).')</option>';
echo '</select> ';
echo '<span id="nc_pathwrap">'.$h(_ncL('path_txt')).': <input type="text" id="nc_path" value="'.$h($global?'web':$relpath).'" class="form-control" style="display:inline-block;width:150px;" placeholder="web"></span> ';
echo '<a href="#" class="btn btn-default" id="nc_open">'.$h(_ncL('open_txt')).'</a>';
echo '</div>';
echo '<script type="text/javascript">jQuery(function($){'
	.'function ncOpen(){var s=$("#nc_site").val();if(!s||s=="0")return;'
	.'var u="admin/nodecomposer.php?tool='.$tool.'&site="+encodeURIComponent(s);'
	.'if(s!="global")u+="&path="+encodeURIComponent($("#nc_path").val()||"web");'
	.'if(typeof loadContent==="function")loadContent(u);else if(typeof ISPConfig!=="undefined"&&ISPConfig.loadContent)ISPConfig.loadContent(u);}'
	.'$("#nc_open").off("click.nco").on("click.nco",function(e){e.preventDefault();ncOpen();});'
	.'$("#nc_site").off("change.nco").on("change.nco",function(){$("#nc_pathwrap").toggle($(this).val()!="global");});'
	.'$("#nc_pathwrap").toggle($("#nc_site").val()!="global");'
	.'});</script>';

if($site <= 0 && !$global) { echo '<p class="help-block">'.$h(_ncL('pick_site_txt')).'</p>'; return; }

$scope_did  = $global ? 0 : $site;                          // domain_id в таблицах
$scope_sp   = $global ? 'global' : (string)$site;           // параметр site в URL

// адрес страницы в текущей области (сайт/путь) — сюда уходит POST действия
$page_url = 'admin/nodecomposer.php?tool='.$tool.'&site='.$scope_sp.($global ? '' : '&path='.rawurlencode($relpath));
// атрибуты кнопки-действия: выполняется через ssAct (POST + CSRF-токен), не GET-ссылкой
$aact = function($do2, $pkg2='', $confirm='') use ($h) {
	return 'data-nc-do="'.$h($do2).'"'.($pkg2 !== '' ? ' data-nc-pkg="'.$h($pkg2).'"' : '').($confirm !== '' ? ' data-nc-confirm="'.$h($confirm).'"' : '');
};

// АВТО-СКАН при открытии/обновлении (do=''): если свежих данных нет — сразу ставим scan в очередь.
$scanning = false;
if($do === '') {
	$ls = $app->db->queryOneRecord("SELECT status, processed FROM nodecomposer_action WHERE tool=? AND domain_id=? AND relpath=? AND action='scan' ORDER BY id DESC LIMIT 1", $tool, $scope_did, $relpath);
	$pending = (is_array($ls) && in_array($ls['status'], array('pending','running'), true));
	$fresh   = (is_array($ls) && $ls['status'] === 'done' && strtotime((string)$ls['processed']) > (time() - 120));
	if(!$pending && !$fresh) {
		$app->db->query("INSERT INTO nodecomposer_action (tool, action, domain_id, relpath, package, status, created) VALUES (?, 'scan', ?, ?, '', 'pending', NOW())", $tool, $scope_did, $relpath);
		$pending = true;
	}
	$scanning = $pending;
}

// Незавершённые задачи по этой области: scan → просто авто-обновляемся; реальная операция
// (install/remove/all/outdated) → ещё и блокируем кнопки, чтобы не наплодить дублей.
$nc_any = $app->db->queryOneRecord("SELECT id FROM nodecomposer_action WHERE tool=? AND domain_id=? AND relpath=? AND status IN ('pending','running') LIMIT 1", $tool, $scope_did, $relpath);
$nc_refresh = (is_array($nc_any) && !empty($nc_any)) || $scanning;
$nc_op  = $app->db->queryOneRecord("SELECT id FROM nodecomposer_action WHERE tool=? AND domain_id=? AND relpath=? AND action<>'scan' AND status IN ('pending','running') LIMIT 1", $tool, $scope_did, $relpath);
$nc_busy = (is_array($nc_op) && !empty($nc_op));
$nc_dis = $nc_busy ? ' style="opacity:.5;pointer-events:none"' : '';

// кнопка «Обновить» + индикатор чтения
$view = $h('admin/nodecomposer.php?tool='.$tool.'&site='.$scope_sp.($global?'':'&path='.rawurlencode($relpath)));
echo '<p><a class="btn btn-default" href="#" data-load-content="'.$view.'">&#8635; '.$h(_ncL('refresh_txt')).'</a>';
if($scanning) echo ' &nbsp;<span class="text-warning">'.$h(_ncL('scanning_txt')).'</span>';
elseif($do !== '') echo ' &nbsp;<span class="text-warning">'.$h(_ncL('refresh_hint_txt')).'</span>';
echo '</p>';

// --- панель действий ---
if($global) {
	echo '<div class="alert alert-danger"><b>'.$h(_ncL('global_warn_head_txt')).'</b> '.$h(_ncL('global_warn_txt')).'</div>';
	echo '<p class="fieldset-legend">'.$h(_ncL('global_scope_txt')).' — <code>'.($tool==='composer'?'composer global':'npm -g').'</code></p>';
} else {
	echo '<p class="fieldset-legend">'.$h(_ncL('project_txt')).': <code>'.$h($relpath ?: '(home)').'</code> · '.$h($manifest).'</p>';
}
echo '<p>';
echo '<a class="btn btn-default ss-nc-act" href="#" '.$aact('scan').$nc_dis.'>'.$h(_ncL('rescan_txt')).'</a> ';
if(!$global) echo '<a class="btn btn-default ss-nc-act" href="#" '.$aact('all').$nc_dis.'>'.$h($tool==='composer'?_ncL('composer_install_txt'):_ncL('npm_install_txt')).'</a> ';
echo '<a class="btn btn-default ss-nc-act" href="#" '.$aact('outdated').$nc_dis.'>&#8593; '.$h(_ncL('outdated_txt')).'</a>';
if($nc_busy) echo ' &nbsp;<span class="text-warning">⏳ <b>'.$h(_ncL('op_busy_txt')).'</b></span>';
echo '</p>';

// добавить пакет
echo '<div class="form-group" style="max-width:640px;">';
echo '<input type="text" id="nc_pkg" class="form-control" placeholder="'.$h($tool==='composer'?'vendor/package (:version)':'package (@version)').'" style="display:inline-block;width:320px;"> ';
echo '<a href="#" class="btn btn-default" id="nc_add"'.$nc_dis.'>'.$h(_ncL('add_txt')).'</a>';
echo '</div>';

// список пакетов из кэша
$pkgs = $app->db->queryAllRecords("SELECT name, version, updated FROM nodecomposer_pkg WHERE domain_id=? AND tool=? AND relpath=? ORDER BY name", $scope_did, $tool, $relpath);
if(!is_array($pkgs)) $pkgs = array();
if(empty($pkgs)) {
	echo '<div class="alert alert-info">'.$h(_ncL('no_pkgs_txt')).'</div>';
} else {
	echo '<p class="help-block">'.$h(_ncL('updated_txt')).': '.$h($pkgs[0]['updated']).'</p>';
	echo '<table class="table"><thead class="dark"><tr><th>'.$h(_ncL('pkg_txt')).'</th><th>'.$h(_ncL('ver_txt')).'</th><th style="width:110px;">'.$h(_ncL('action_txt')).'</th></tr></thead><tbody>';
	foreach($pkgs as $p) {
		echo '<tr><td><code>'.$h($p['name']).'</code></td><td>'.$h($p['version']).'</td>'
			.'<td><a class="btn btn-default btn-xs ss-nc-act" href="#" '.$aact('del', $p['name'], _ncL('confirm_del_txt').' '.$p['name']).$nc_dis.'>'.$h(_ncL('remove_txt')).'</a></td></tr>';
	}
	echo '</tbody></table>';
}

// полный вывод последнего «outdated» (в таблице задач он обрезан)
$od = $app->db->queryOneRecord("SELECT result, processed FROM nodecomposer_action WHERE tool=? AND domain_id=? AND relpath=? AND action='outdated' AND status='done' ORDER BY id DESC LIMIT 1", $tool, $scope_did, $relpath);
if(is_array($od) && trim((string)$od['result']) !== '') {
	echo '<p class="fieldset-legend" style="margin-top:16px;">'.$h(_ncL('outdated_txt')).' <span class="help-block" style="display:inline">('.$h($od['processed']).')</span></p>';
	echo '<pre style="max-height:340px;overflow:auto;">'.$h((string)$od['result']).'</pre>';
}

// последние задачи
$jobs = $app->db->queryAllRecords("SELECT action, package, status, result, processed FROM nodecomposer_action WHERE tool=? AND domain_id=? ORDER BY id DESC LIMIT 8", $tool, $scope_did);
if(is_array($jobs) && !empty($jobs)) {
	echo '<p class="fieldset-legend" style="margin-top:16px;">'.$h(_ncL('jobs_txt')).'</p><table class="table"><thead class="dark"><tr><th>'.$h(_ncL('action_txt')).'</th><th>'.$h(_ncL('pkg_txt')).'</th><th>'.$h(_ncL('status_txt')).'</th><th>'.$h(_ncL('when_txt')).'</th></tr></thead><tbody>';
	foreach($jobs as $j) {
		$cls = ($j['status']==='done')?'text-success':(($j['status']==='error')?'text-danger':(($j['status']==='running')?'text-warning':''));
		echo '<tr><td>'.$h($j['action']).'</td><td><code>'.$h($j['package']).'</code></td><td class="'.$cls.'"><b>'.$h($j['status']).'</b>'.($j['result']?' <span class="help-block" style="display:inline">'.$h(mb_substr((string)$j['result'],-90)).'</span>':'').'</td><td>'.$h($j['processed']).'</td></tr>';
	}
	echo '</tbody></table>';
}
?>
<script type="text/javascript">
jQuery(function($){
	function nav(u){ if(typeof loadContent==='function')loadContent(u); else if(typeof ISPConfig!=='undefined'&&ISPConfig.loadContent)ISPConfig.loadContent(u); }
	var ncBusy = <?php echo $nc_busy ? 'true' : 'false'; ?>;
	var ncPage = <?php echo json_encode($page_url); ?>;
	// кнопки-действия: POST + CSRF-токен через ssAct; анти-дубль — гасим кнопку после отправки
	$(document).off('click.nclock').on('click.nclock','.ss-nc-act',function(e){
		e.preventDefault();
		if(ncBusy && $(this).data('nc-do') !== 'scan') return;
		var $b=$(this), p={do: $b.data('nc-do')};
		if($b.data('nc-pkg')) p.pkg = String($b.data('nc-pkg'));
		if(ssAct(ncPage, p, $b.data('nc-confirm') || '')) $b.css({opacity:.5,'pointer-events':'none'});
	});
	$('#nc_add').off('click.nc').on('click.nc', function(e){
		e.preventDefault();
		if(ncBusy) return;                       // идёт операция — не ставим ещё одну
		var p = $.trim($('#nc_pkg').val());
		if(!p) return;
		$(this).css({opacity:.5,'pointer-events':'none'});
		ssAct(ncPage, {do: 'add', pkg: p});
	});
	// пока задача (скан/установка/удаление) выполняется — сами обновляем до результата
	<?php if($nc_refresh): ?>
	setTimeout(function(){ nav('admin/nodecomposer.php?tool=<?php echo $tool; ?>&site=<?php echo $scope_sp; ?><?php echo $global?'':'&path='.rawurlencode($relpath); ?>'); }, 5000);
	<?php endif; ?>
});
</script>
