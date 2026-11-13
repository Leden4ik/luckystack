<?php
/*
  LuckyStack: страница «Заморозка vhost — статус и diff» (только админ).
  Локализована: грузим en как базу + язык пользователя поверх (отсутствующие ключи → en).
  Данные кладёт плагин-root в БД (freeze_vhost_generated, freeze_vhost_status). Действия
  (re-seed / apply) идут через datalogUpdate(web_domain) → server.sh → плагин.
*/

require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';
require_once '../../lib/ss_panel.inc.php';

$app->auth->check_module_permissions('sites');
if(!isset($_SESSION['s']['user']['typ']) || $_SESSION['s']['user']['typ'] != 'admin') {
	die('Allowed for administrators only.');
}
$app->uses('functions');

// ---- локализация: en (база) + язык пользователя (поверх) ----
$wb = array();
$_ld = __DIR__.'/lib/lang/';
@include $_ld.'en_web_vhost_freeze.lng';
$_ul = isset($_SESSION['s']['language']) ? preg_replace('/[^a-z]/', '', $_SESSION['s']['language']) : 'en';
if($_ul && $_ul !== 'en' && file_exists($_ld.$_ul.'_web_vhost_freeze.lng')) @include $_ld.$_ul.'_web_vhost_freeze.lng';
function _fzL($k) { global $wb; return isset($wb[$k]) ? $wb[$k] : $k; }

$id = isset($_GET['id']) ? intval($_GET['id']) : 0;
// действия (re-seed / apply) только POST + CSRF-токен; просмотр по GET ?id=
$do = ss_is_action() ? ss_post('do') : '';
$row = $app->db->queryOneRecord("SELECT domain_id, domain, freeze_vhost, freeze_vhost_content, freeze_vhost_generated, freeze_vhost_status FROM web_domain WHERE domain_id = ?", $id);

if(!is_array($row)) { echo '<div class="page-header"><h1>'.$app->functions->htmlentities(_fzL('freeze_title_txt')).'</h1></div><div class="alert alert-warning">'.$app->functions->htmlentities(_fzL('freeze_not_found_txt')).'</div>'; exit; }

// действия
if($do === 'reseed' && (string)$row['freeze_vhost_generated'] !== '') {
	$app->db->datalogUpdate('web_domain', array('freeze_vhost_content' => $row['freeze_vhost_generated']), 'domain_id', $id);
	ss_audit('vhost_freeze', 'reseed', $row['domain']);
	header('Location: web_vhost_freeze_info.php?id='.$id); exit;
}
// забрать текст файла с диска в базу (файл правили вручную). Сохранение через datalog: дальше
// плагины применят его как обычную правку админа, файл при этом не меняется.
if($do === 'import' && $row['freeze_vhost'] === 'y' && preg_match('/^[A-Za-z0-9._-]+$/', (string)$row['domain'])) {
	$vf = '/etc/nginx/sites-available/'.$row['domain'].'.vhost';
	$live = is_readable($vf) ? str_replace("\r\n", "\n", (string)@file_get_contents($vf)) : '';
	if(trim($live) !== '') {
		$app->db->datalogUpdate('web_domain', array('freeze_vhost_content' => $live), 'domain_id', $id);
		ss_audit('vhost_freeze', 'import', $row['domain']);
	}
	header('Location: web_vhost_freeze_info.php?id='.$id); exit;
}
if($do === 'apply') {
	$app->db->datalogUpdate('web_domain', array('freeze_vhost_status' => 'applying '.date('H:i:s')), 'domain_id', $id);
	ss_audit('vhost_freeze', 'apply', $row['domain']);
	header('Location: web_vhost_freeze_info.php?id='.$id); exit;
}

$h = function($s){ global $app; return $app->functions->htmlentities((string)$s); };
$domain = $h($row['domain']);
$content = (string)$row['freeze_vhost_content'];
$gen = (string)$row['freeze_vhost_generated'];
$status = (string)$row['freeze_vhost_status'];

echo '<div class="page-header"><h1>'.$h(_fzL('freeze_title_txt')).' — '.$domain.'</h1></div>';

if($row['freeze_vhost'] !== 'y') {
	echo '<div class="alert alert-info">'.$h(_fzL('freeze_not_frozen_txt')).'</div>';
}

// статус последнего применения
if($status !== '') {
	$ok = (stripos($status, 'error') === false);
	echo '<div class="alert '.($ok ? 'alert-success' : 'alert-danger').'"><strong>'.$h(_fzL('freeze_status_txt')).'</strong> '.$h($status).'</div>';
}

// детектор дрейфа PHP-сокета
$sock = function($s){ return preg_match('/fastcgi_pass\s+(unix:[^;\s]+|[0-9A-Fa-f:.\[\]]+:[0-9]+)\s*;/', $s, $m) ? $m[1] : ''; };
if($content !== '' && $gen !== '') {
	$sc = $sock($content); $sg = $sock($gen);
	if($sc !== '' && $sg !== '' && $sc !== $sg) {
		echo '<div class="alert alert-danger"><strong>'.$h(_fzL('freeze_drift_txt')).'</strong> <code>'.$h($sc).'</code> ≠ <code>'.$h($sg).'</code></div>';
	}
	echo '<div class="alert '.($content !== $gen ? 'alert-warning' : 'alert-success').'">'.$h($content !== $gen ? _fzL('freeze_differs_txt') : _fzL('freeze_same_txt')).'</div>';
}

// файл на диске отличается от текста в базе: его правили вручную (или правки ещё применяются).
// При следующем сохранении сайта правки из файла заберутся сами (aaa_freeze_vhost_capture_plugin),
// кнопкой можно забрать сразу.
$live = null;
if($row['freeze_vhost'] === 'y' && preg_match('/^[A-Za-z0-9._-]+$/', (string)$row['domain'])) {
	$vf = '/etc/nginx/sites-available/'.$row['domain'].'.vhost';
	if(is_readable($vf)) $live = str_replace("\r\n", "\n", (string)@file_get_contents($vf));
}
$file_drift = ($live !== null && trim($live) !== '' && $live !== str_replace("\r\n", "\n", $content));
if($file_drift) echo '<div class="alert alert-warning"><strong>'.$h(_fzL('freeze_file_drift_txt')).'</strong> '.$h(_fzL('freeze_file_drift_hint_txt')).'</div>';

// кнопки (действия — POST через ssAct)
echo ss_action_form('vhost_freeze');
echo '<p style="margin:12px 0;">';
if($file_drift) echo '<a class="btn btn-warning ss-fz-act" href="#" data-do="import">'.$h(_fzL('freeze_import_txt')).'</a> ';
if($gen !== '') echo '<a class="btn btn-default ss-fz-act" href="#" data-do="reseed">'.$h(_fzL('freeze_reseed_txt')).'</a> ';
echo '<a class="btn btn-default ss-fz-act" href="#" data-do="apply">'.$h(_fzL('freeze_apply_txt')).'</a> ';
echo '<a class="btn btn-default" href="#" data-load-content="sites/web_vhost_domain_edit.php?id='.$id.'">&larr; '.$h(_fzL('freeze_tosite_txt')).'</a>';
echo '</p>';

if($file_drift) {
	echo '<p class="fieldset-legend">'.$h(_fzL('freeze_live_label_txt')).'</p>';
	echo '<textarea class="form-control" rows="20" readonly style="font-family:monospace;white-space:pre;margin-bottom:16px">'.$h($live).'</textarea>';
}

// сгенерированный core vhost (read-only)
echo '<p class="fieldset-legend">'.$h(_fzL('freeze_generated_label_txt')).'</p>';
echo '<textarea class="form-control" rows="20" readonly style="font-family:monospace;white-space:pre">'.$h($gen !== '' ? $gen : _fzL('freeze_generated_empty_txt')).'</textarea>';
echo '<script type="text/javascript">jQuery(function($){'
	.'$(document).off("click.fz").on("click.fz",".ss-fz-act",function(e){e.preventDefault();'
	.'$(this).css({opacity:.5,"pointer-events":"none"});'
	.'ssAct("sites/web_vhost_freeze_info.php?id='.(int)$id.'",{do:$(this).data("do")});});'
	.'});</script>';
?>
