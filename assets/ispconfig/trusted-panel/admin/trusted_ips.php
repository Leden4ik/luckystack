<?php
/*
  LuckyStack: страница «Доверенные IP» (только админ).

  Один список IP и подсетей, которые не банятся: CrowdSec (allowlist) и fail2ban (ignoreip).
  Интерфейс не root, поэтому ведём таблицу ss_trusted_ip (желаемый список), а root-cron
  ss-trusted-sync.php приводит к ней CrowdSec и fail2ban, снимает уже стоящие баны и чистит
  истёкшие записи. Проверка «где забанен IP» идёт через очередь ss_trusted_job (cscli и
  fail2ban-client требуют root). Действия только POST с CSRF-токеном, всё пишется в журнал.
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
@include $_ld.'en_trusted_ips.lng';
$_ul = isset($_SESSION['s']['language']) ? preg_replace('/[^a-z]/', '', $_SESSION['s']['language']) : 'en';
if($_ul && $_ul !== 'en' && file_exists($_ld.$_ul.'_trusted_ips.lng')) @include $_ld.$_ul.'_trusted_ips.lng';
function _tL($k) { global $wb; return isset($wb[$k]) ? $wb[$k] : $k; }
$h = function($s){ global $app; return $app->functions->htmlentities((string)$s); };

// Те же правила, что в cron: IPv4/IPv6 или подсеть не шире /16 (IPv4) и /32 (IPv6).
function _tr_valid($t) {
	if(strpos($t, '/') === false) return (bool)filter_var($t, FILTER_VALIDATE_IP);
	$p = explode('/', $t, 2);
	if(!ctype_digit($p[1])) return false;
	$m = (int)$p[1];
	if(filter_var($p[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return ($m >= 16 && $m <= 32);
	if(filter_var($p[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) return ($m >= 32 && $m <= 128);
	return false;
}
function _tr_in($ip, $cidr) {
	if(strpos($cidr, '/') === false) return $ip === $cidr;
	list($net, $mask) = explode('/', $cidr, 2); $mask = (int)$mask;
	$ipb = @inet_pton($ip); $nb = @inet_pton($net);
	if($ipb === false || $nb === false || strlen($ipb) !== strlen($nb)) return false;
	$bytes = intdiv($mask, 8); $rem = $mask % 8;
	if($bytes > 0 && substr($ipb, 0, $bytes) !== substr($nb, 0, $bytes)) return false;
	if($rem > 0) { $mb = (0xff << (8 - $rem)) & 0xff; if((ord($ipb[$bytes]) & $mb) !== (ord($nb[$bytes]) & $mb)) return false; }
	return true;
}

$my_ip = isset($_SERVER['REMOTE_ADDR']) ? (string)$_SERVER['REMOTE_ADDR'] : '';
$durations = array('0' => 0, '1h' => 3600, '24h' => 86400, '7d' => 604800, '30d' => 2592000);
$user = isset($_SESSION['s']['user']['username']) ? (string)$_SESSION['s']['user']['username'] : '';

// ---- действия (только POST + CSRF-токен) ----
$msg = '';
if(ss_is_action()) {
	$do = ss_post('do');
	if($do === 'add') {
		$t = ss_post('target');
		$c = function_exists('mb_substr') ? mb_substr(ss_post('comment'), 0, 120) : substr(ss_post('comment'), 0, 120);
		$d = ss_post('dur', '0');
		if(!_tr_valid($t) || !isset($durations[$d])) {
			$msg = '<div class="alert alert-danger">'.$h(_tL('bad_target_txt')).'</div>';
		} else {
			// срок считает база (NOW() + INTERVAL): PHP панели в UTC, а MariaDB в поясе сервера,
			// и срок из date() получался в прошлом, запись сразу удалялась как истёкшая
			$sec = (int)$durations[$d];
			$ex = $app->db->queryOneRecord("SELECT id FROM ss_trusted_ip WHERE target = ?", $t);
			if(is_array($ex) && !empty($ex)) {
				// повторное добавление: обновить комментарий и срок, применить заново
				$app->db->query("UPDATE ss_trusted_ip SET comment = ?, expires = IF(? > 0, NOW() + INTERVAL ? SECOND, NULL), applied = 'n', applied_at = NULL, note = NULL WHERE id = ?", $c, $sec, $sec, (int)$ex['id']);
			} else {
				$app->db->query("INSERT INTO ss_trusted_ip (target, comment, expires, source, created, created_by, applied) VALUES (?, ?, IF(? > 0, NOW() + INTERVAL ? SECOND, NULL), 'panel', NOW(), ?, 'n')", $t, $c, $sec, $sec, $user);
			}
			ss_audit('trusted', 'add', $t.($c !== '' ? ' ('.$c.')' : '').' срок '.($d === '0' ? 'навсегда' : $d));
			$msg = '<div class="alert alert-success">'.$h(_tL('added_txt')).' <code>'.$h($t).'</code>. '.$h(_tL('queued_hint_txt')).'</div>';
		}
	} elseif($do === 'del') {
		$id = (int)ss_post('id', '0');
		$r = $id > 0 ? $app->db->queryOneRecord("SELECT target FROM ss_trusted_ip WHERE id = ?", $id) : null;
		if(is_array($r) && !empty($r)) {
			$app->db->query("DELETE FROM ss_trusted_ip WHERE id = ?", $id);
			ss_audit('trusted', 'del', $r['target']);
			$msg = '<div class="alert alert-info">'.$h(_tL('removed_txt')).' <code>'.$h($r['target']).'</code>. '.$h(_tL('queued_hint_txt')).'</div>';
		}
	} elseif($do === 'lookup') {
		$ip = ss_post('ip');
		if(!filter_var($ip, FILTER_VALIDATE_IP)) {
			$msg = '<div class="alert alert-danger">'.$h(_tL('lookup_bad_txt')).'</div>';
		} else {
			$app->db->query("INSERT INTO ss_trusted_job (ip, status, created) VALUES (?, 'pending', NOW())", $ip);
			ss_audit('trusted', 'lookup', $ip);
		}
	}
}

// ---- данные ----
$st = array();
foreach((array)$app->db->queryAllRecords("SELECT name, value FROM ss_trusted_state") as $r) $st[$r['name']] = $r['value'];
$have_cs  = (isset($st['have_crowdsec']) && $st['have_crowdsec'] === 'y');
$have_f2b = (isset($st['have_fail2ban']) && $st['have_fail2ban'] === 'y');
$rows = $app->db->queryAllRecords("SELECT id, target, comment, expires, source, created, created_by, applied, note FROM ss_trusted_ip ORDER BY created ASC, id ASC");
if(!is_array($rows)) $rows = array();
$jobs = $app->db->queryAllRecords("SELECT id, ip, status, result, created, processed FROM ss_trusted_job ORDER BY id DESC LIMIT 5");
if(!is_array($jobs)) $jobs = array();

$pending = false;
foreach($rows as $r) if($r['applied'] !== 'y' && (string)$r['note'] === '') { $pending = true; break; }
foreach($jobs as $j) if($j['status'] === 'pending') { $pending = true; break; }

$me_covered = false;
foreach($rows as $r) if($my_ip !== '' && _tr_in($my_ip, $r['target'])) { $me_covered = true; break; }

// ---- вывод ----
echo '<div class="page-header"><h1>'.$h(_tL('head_txt')).'</h1></div>';
echo '<p>'.$h(_tL('desc_txt')).'</p>';
echo $msg;
echo ss_action_form('trusted');

if(!$have_cs && !$have_f2b && isset($st['synced'])) {
	echo '<div class="alert alert-warning">'.$h(_tL('no_engines_txt')).'</div>';
} else {
	$eng = array(); if($have_cs) $eng[] = 'CrowdSec'; if($have_f2b) $eng[] = 'fail2ban';
	if($eng) echo '<p class="help-block">'.$h(_tL('engines_txt')).': <b>'.$h(implode(', ', $eng)).'</b>'
		.(isset($st['synced']) ? ' · '.$h(_tL('synced_txt')).': '.$h($st['synced']) : '').'</p>';
}

if($my_ip !== '' && !$me_covered) {
	echo '<div class="alert alert-warning">'.$h(_tL('you_missing_txt')).' <code>'.$h($my_ip).'</code> '
		.'<a href="#" class="btn btn-default btn-xs ss-tr-addme">'.$h(_tL('you_add_txt')).'</a></div>';
}

// форма добавления
echo '<div class="form-group" style="max-width:900px;margin:8px 0;">';
echo '<input type="text" id="tr_target" class="form-control" placeholder="'.$h(_tL('target_ph_txt')).'" style="display:inline-block;width:280px;"> ';
echo '<a href="#" class="btn btn-default btn-sm" id="tr_myip" title="'.$h($my_ip).'">'.$h(_tL('my_ip_txt')).'</a> ';
echo '<input type="text" id="tr_comment" class="form-control" placeholder="'.$h(_tL('comment_ph_txt')).'" style="display:inline-block;width:240px;"> ';
echo '<select id="tr_dur" class="form-control" style="display:inline-block;width:120px;" title="'.$h(_tL('dur_txt')).'">';
foreach(array('0','1h','24h','7d','30d') as $d) echo '<option value="'.$d.'">'.$h(_tL('dur_'.$d.'_txt')).'</option>';
echo '</select> ';
echo '<a href="#" class="btn btn-default formbutton-success" id="tr_add">'.$h(_tL('add_txt')).'</a>';
echo '</div>';

// список
echo '<p class="fieldset-legend" style="margin-top:16px;">'.$h(_tL('list_head_txt')).'</p>';
if(empty($rows)) {
	echo '<div class="alert alert-info">'.$h(_tL('empty_txt')).'</div>';
} else {
	echo '<table class="table"><thead class="dark"><tr><th>'.$h(_tL('col_target_txt')).'</th><th>'.$h(_tL('col_comment_txt')).'</th><th>'.$h(_tL('col_until_txt')).'</th><th>'.$h(_tL('col_added_txt')).'</th><th>'.$h(_tL('col_status_txt')).'</th><th style="width:100px;">'.$h(_tL('col_action_txt')).'</th></tr></thead><tbody>';
	foreach($rows as $r) {
		$mine = ($my_ip !== '' && _tr_in($my_ip, $r['target']));
		if((string)$r['note'] !== '') $stt = '<span class="text-danger">'.$h($r['note']).'</span>';
		elseif($r['applied'] === 'y') $stt = '<span class="text-success">'.$h(_tL('applied_txt')).'</span>';
		else $stt = '<span class="text-warning">⏳ '.$h(_tL('pending_txt')).'</span>';
		echo '<tr><td><code>'.$h($r['target']).'</code>'.($mine ? ' <span class="label label-info">'.$h(_tL('you_txt')).'</span>' : '').'</td>'
			.'<td>'.$h($r['comment']).'</td>'
			.'<td>'.($r['expires'] ? $h($r['expires']) : '<span class="help-block" style="display:inline">'.$h(_tL('forever_txt')).'</span>').'</td>'
			.'<td><span class="help-block" style="display:inline">'.$h($r['created']).($r['created_by'] !== '' ? ' · '.$h($r['created_by']) : '').'</span></td>'
			.'<td>'.$stt.'</td>'
			.'<td><a href="#" class="btn btn-default btn-xs ss-tr-del" data-id="'.(int)$r['id'].'" data-confirm="'.$h(_tL($mine ? 'confirm_del_self_txt' : 'confirm_del_txt')).'">'.$h(_tL('delete_txt')).'</a></td></tr>';
	}
	echo '</tbody></table>';
}

// другие allowlist CrowdSec (только чтение)
$other = isset($st['other_allowlists']) ? json_decode($st['other_allowlists'], true) : array();
if(is_array($other) && !empty($other)) {
	echo '<p class="fieldset-legend" style="margin-top:16px;">'.$h(_tL('other_head_txt')).'</p><ul>';
	foreach($other as $o) echo '<li><b>'.$h($o['name']).'</b>'.($o['description'] !== '' ? ' — '.$h($o['description']) : '').': <code>'.$h(implode(', ', (array)$o['values'])).'</code></li>';
	echo '</ul>';
}

// проверка IP
echo '<p class="fieldset-legend" style="margin-top:16px;">'.$h(_tL('lookup_head_txt')).'</p>';
echo '<div class="form-group" style="max-width:640px;">';
echo '<input type="text" id="tr_lookup" class="form-control" placeholder="'.$h(_tL('lookup_ph_txt')).'" style="display:inline-block;width:240px;"> ';
echo '<a href="#" class="btn btn-default" id="tr_lookup_btn">'.$h(_tL('lookup_btn_txt')).'</a>';
echo '</div>';
foreach($jobs as $j) {
	echo '<div class="panel panel-default" style="max-width:900px;"><div class="panel-heading"><b><code>'.$h($j['ip']).'</code></b> <span class="help-block" style="display:inline">'.$h($j['processed'] ?: $j['created']).'</span></div><div class="panel-body">';
	if($j['status'] === 'pending') { echo '<span class="text-warning">⏳ '.$h(_tL('lookup_wait_txt')).'</span></div></div>'; continue; }
	$res = json_decode((string)$j['result'], true);
	if(!is_array($res)) { echo '<span class="text-danger">'.$h($j['result']).'</span></div></div>'; continue; }
	$line = function($label, $items) use ($h) {
		echo '<div><b>'.$h($label).':</b> '.(empty($items) ? '<span class="help-block" style="display:inline">'.$h(_tL('lk_none_txt')).'</span>' : $h(implode('; ', $items))).'</div>';
	};
	$cs = array(); foreach((array)$res['crowdsec'] as $d) $cs[] = $d['type'].' '.$d['origin'].' / '.$d['scenario'].' ('.$d['duration'].')';
	$al = array(); foreach((array)$res['alerts'] as $a) $al[] = $a['scenario'].' '.$a['at'];
	$line(_tL('lk_trusted_txt'), (array)$res['trusted']);
	$line(_tL('lk_cs_txt'), $cs);
	$line(_tL('lk_f2b_txt'), (array)$res['fail2ban']);
	$line(_tL('lk_ufw_txt'), (array)$res['ufw_block']);
	$line(_tL('lk_alerts_txt'), $al);
	if(empty($cs) && empty($res['fail2ban']) && empty($res['ufw_block'])) echo '<div class="text-success" style="margin-top:6px;">'.$h(_tL('lk_clean_txt')).'</div>';
	echo '</div></div>';
}
?>
<script type="text/javascript">
jQuery(function($){
	var page = 'admin/trusted_ips.php', myip = <?php echo json_encode($my_ip); ?>;
	function lock($b){ $b.css({opacity:.5,'pointer-events':'none'}); }
	$('#tr_myip').off('click.tr').on('click.tr', function(e){ e.preventDefault(); $('#tr_target').val(myip); });
	$('#tr_add').off('click.tr').on('click.tr', function(e){
		e.preventDefault();
		var t = $.trim($('#tr_target').val()); if(!t) return;
		lock($(this));
		ssAct(page, {do: 'add', target: t, comment: $('#tr_comment').val(), dur: $('#tr_dur').val()});
	});
	$(document).off('click.traddme').on('click.traddme', '.ss-tr-addme', function(e){
		e.preventDefault(); lock($(this));
		ssAct(page, {do: 'add', target: myip, comment: '', dur: '0'});
	});
	$(document).off('click.trdel').on('click.trdel', '.ss-tr-del', function(e){
		e.preventDefault();
		if(ssAct(page, {do: 'del', id: $(this).data('id')}, $(this).data('confirm'))) lock($(this));
	});
	$('#tr_lookup_btn').off('click.tr').on('click.tr', function(e){
		e.preventDefault();
		var ip = $.trim($('#tr_lookup').val()); if(!ip) return;
		lock($(this)); ssAct(page, {do: 'lookup', ip: ip});
	});
	// пока что-то ожидает применения или проверки — обновляемся сами
	<?php if($pending): ?>
	setTimeout(function(){ if(typeof loadContent==='function')loadContent(page); else if(typeof ISPConfig!=='undefined'&&ISPConfig.loadContent)ISPConfig.loadContent(page); }, 5000);
	<?php endif; ?>
});
</script>
