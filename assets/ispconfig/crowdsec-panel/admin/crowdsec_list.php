<?php
/*
  LuckyStack: страница «CrowdSec» (только админ) — активные решения (баны) + снятие.
  Аналог лог-вьюшек ISPConfig Monitor, но структурировано: кэш crowdsec_decision
  (наполняет root-cron ss-crowdsec-sync.php) + очередь crowdsec_action (снять бан).
  Локализована: en (база) + язык пользователя (поверх).
*/

require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';
require_once '../../lib/ss_panel.inc.php';

$app->auth->check_module_permissions('admin');
if(!$app->auth->is_admin()) die('Allowed for administrators only.');
$app->uses('functions');

$wb = array();
$_ld = __DIR__.'/lib/lang/';
@include $_ld.'en_crowdsec.lng';
$_ul = isset($_SESSION['s']['language']) ? preg_replace('/[^a-z]/', '', $_SESSION['s']['language']) : 'en';
if($_ul && $_ul !== 'en' && file_exists($_ld.$_ul.'_crowdsec.lng')) @include $_ld.$_ul.'_crowdsec.lng';
function _csL($k) { global $wb; return isset($wb[$k]) ? $wb[$k] : $k; }

$h = function($s){ global $app; return $app->functions->htmlentities((string)$s); };

// ---- действие: снять бан по IP → очередь (только POST + CSRF-токен) ----
$msg = '';
$do = ''; $ip = '';
if(ss_is_action()) { $do = ss_post('do'); $ip = ss_post('ip'); }
if($do === 'remove') {
	if(filter_var($ip, FILTER_VALIDATE_IP)) {
		$app->db->query("INSERT INTO crowdsec_action (action, value, status, created) VALUES ('delete_ip', ?, 'pending', NOW())", $ip);
		ss_audit('crowdsec', 'remove', $ip);
		$msg = '<div class="alert alert-success">'.$h(_csL('queued_txt')).' <code>'.$h($ip).'</code>. '.$h(_csL('queued_hint_txt')).'</div>';
	} else {
		$msg = '<div class="alert alert-danger">'.$h(_csL('bad_ip_txt')).'</div>';
	}
}

$rows = $app->db->queryAllRecords("SELECT value, scope, scenario, origin, type, country, as_name, duration, updated FROM crowdsec_decision ORDER BY origin, value");
if(!is_array($rows)) $rows = array();

// есть незавершённые снятия? (для авто-обновления, пока cron их применит ≤1 мин)
$pj = $app->db->queryOneRecord("SELECT id FROM crowdsec_action WHERE status IN ('pending','running') LIMIT 1");
$pending = (is_array($pj) && !empty($pj));

// сводка по origin
$by = array(); $upd = '';
foreach($rows as $r) { $o = $r['origin'] ?: '?'; $by[$o] = (isset($by[$o]) ? $by[$o] : 0) + 1; $upd = $r['updated']; }

echo '<div class="page-header"><h1>'.$h(_csL('list_head_txt')).'</h1></div>';
echo '<p>'.$h(_csL('list_desc_txt')).'</p>';
echo $msg;
echo ss_action_form('crowdsec');

// --- сводка всех заблокированных IP по источнику (вкл. community blocklist CAPI) ---
$origins = $app->db->queryAllRecords("SELECT origin, cnt FROM crowdsec_origin ORDER BY cnt DESC");
if(is_array($origins) && !empty($origins)) {
	$total = 0; $parts = array();
	foreach($origins as $o) {
		$total += (int)$o['cnt'];
		$lbl = (strcasecmp($o['origin'], 'CAPI') === 0) ? _csL('capi_txt') : (($o['origin'] === 'crowdsec') ? _csL('local_txt') : $o['origin']);
		$parts[] = $h($lbl).': <b>'.(int)$o['cnt'].'</b>';
	}
	echo '<div class="alert alert-info"><b>'.$h(_csL('blocked_total_txt')).': '.$total.'</b> &nbsp; ('.implode(' · ', $parts).')'
		.'<br><span class="help-block" style="display:inline">'.$h(_csL('capi_hint_txt')).'</span></div>';
}

if(empty($rows)) {
	echo '<div class="alert alert-info">'.$h(_csL('no_data_txt')).'</div>';
	return;
}

$sum = array();
foreach($by as $o => $n) $sum[] = $h($o).': '.(int)$n;
echo '<p class="help-block">'.$h(_csL('total_txt')).': <b>'.count($rows).'</b> ('.implode(' · ', $sum).') · '.$h(_csL('updated_txt')).': '.$h($upd).' · '.$h(_csL('apply_hint_txt')).'</p>';

echo '<table class="table"><thead class="dark"><tr>'
	.'<th>IP</th><th>'.$h(_csL('country_txt')).'</th><th>'.$h(_csL('as_txt')).'</th>'
	.'<th>'.$h(_csL('scenario_txt')).'</th><th>'.$h(_csL('origin_txt')).'</th>'
	.'<th>'.$h(_csL('expires_txt')).'</th><th style="width:110px;">'.$h(_csL('action_txt')).'</th></tr></thead><tbody>';
foreach($rows as $r) {
	$isip = (strcasecmp($r['scope'], 'Ip') === 0) && filter_var($r['value'], FILTER_VALIDATE_IP);
	echo '<tr>'
		.'<td><code>'.$h($r['value']).'</code>'.(strcasecmp($r['scope'],'Ip')!==0 ? ' <span class="help-block" style="display:inline">('.$h($r['scope']).')</span>' : '').'</td>'
		.'<td>'.$h($r['country']).'</td>'
		.'<td><span class="help-block" style="display:inline">'.$h($r['as_name']).'</span></td>'
		.'<td>'.$h($r['scenario']).'</td>'
		.'<td>'.$h($r['origin']).'</td>'
		.'<td>'.$h($r['duration']).'</td>'
		.'<td>'.($isip ? '<a class="btn btn-default btn-xs ss-cs-remove" href="#" data-ip="'.$h($r['value']).'">'.$h(_csL('remove_txt')).'</a>' : '').'</td>'
		.'</tr>';
}
echo '</tbody></table>';
if($pending) echo '<p class="text-warning">⏳ <b>'.$h(_csL('applying_txt')).'</b></p>';
?>
<script type="text/javascript">
jQuery(function($){
	// анти-дубль: блокируем кнопку «снять» сразу на клике (loadContent уже ушёл)
	$(document).off('click.cslock').on('click.cslock','.ss-cs-remove',function(e){
		e.preventDefault();
		var $b=$(this); $b.css({opacity:.5,'pointer-events':'none'});
		ssAct('admin/crowdsec_list.php', {do: 'remove', ip: $b.data('ip')});
	});
	// пока снятие в очереди — сами обновляем список (строка исчезнет, когда cron применит ≤1 мин)
	<?php if($pending): ?>
	setTimeout(function(){ if(typeof loadContent==='function')loadContent('admin/crowdsec_list.php'); else if(typeof ISPConfig!=='undefined'&&ISPConfig.loadContent)ISPConfig.loadContent('admin/crowdsec_list.php'); }, 5000);
	<?php endif; ?>
});
</script>
<?php
