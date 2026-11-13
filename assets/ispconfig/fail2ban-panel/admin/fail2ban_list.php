<?php
/*
  LuckyStack: страница «Fail2ban» (только админ) — статус джейлов + забаненные IP + разбан/бан.
  Локализована: en (база) + язык пользователя (поверх).

  Только чтение кэша (таблица fail2ban_jail, её наполняет root-cron ss-fail2ban-sync.php).
  Действия (разбан/бан) — запись в очередь fail2ban_action; root-cron выполнит их ≤1 мин.
  Интерфейс работает под непривилегированным пользователем и сам fail2ban-client дёргать не может.
*/

require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';
require_once '../../lib/ss_panel.inc.php';

$app->auth->check_module_permissions('admin');
if(!$app->auth->is_admin()) die('Allowed for administrators only.');
$app->uses('functions');

// ---- локализация: en (база) + язык пользователя (поверх) ----
$wb = array();
$_ld = __DIR__.'/lib/lang/';
@include $_ld.'en_fail2ban.lng';
$_ul = isset($_SESSION['s']['language']) ? preg_replace('/[^a-z]/', '', $_SESSION['s']['language']) : 'en';
if($_ul && $_ul !== 'en' && file_exists($_ld.$_ul.'_fail2ban.lng')) @include $_ld.$_ul.'_fail2ban.lng';
function _f2L($k) { global $wb; return isset($wb[$k]) ? $wb[$k] : $k; }

$h = function($s){ global $app; return $app->functions->htmlentities((string)$s); };

// ---- действия: разбан / бан → очередь fail2ban_action (только POST + CSRF-токен) ----
$do = ''; $jail = ''; $ip = '';
$msg = '';
if(ss_is_action()) {
	$do   = ss_post('do');
	$jail = ss_post('jail');
	$ip   = ss_post('ip');
}
if(($do === 'unban' || $do === 'ban')) {
	$okj = preg_match('/^[A-Za-z0-9_.\-]+$/', $jail);
	$oki = filter_var($ip, FILTER_VALIDATE_IP);
	if($okj && $oki) {
		$app->db->query("INSERT INTO fail2ban_action (action, jail, ip, status, created) VALUES (?,?,?, 'pending', NOW())", $do, $jail, $ip);
		ss_audit('fail2ban', $do, $jail.' '.$ip);
		$msg = '<div class="alert alert-success">'.$h(_f2L($do === 'ban' ? 'queued_ban_txt' : 'queued_unban_txt')).' <code>'.$h($ip).'</code> @ <code>'.$h($jail).'</code></div>';
	} else {
		$msg = '<div class="alert alert-danger">'.$h(_f2L('bad_input_txt')).'</div>';
	}
}

$jails = $app->db->queryAllRecords("SELECT jail, banned, total, failed, banned_ips, updated FROM fail2ban_jail ORDER BY jail ASC");
if(!is_array($jails)) $jails = array();

echo '<div class="page-header"><h1>'.$h(_f2L('list_head_txt')).'</h1></div>';
echo '<p>'.$h(_f2L('list_desc_txt')).'</p>';
echo $msg;
echo ss_action_form('fail2ban');

if(empty($jails)) {
	echo '<div class="alert alert-info">'.$h(_f2L('no_data_txt')).'</div>';
} else {
	$upd = $jails[0]['updated'];
	echo '<p class="help-block">'.$h(_f2L('updated_txt')).': '.$h($upd).' · '.$h(_f2L('apply_hint_txt')).'</p>';

	// сводка по джейлам
	echo '<table class="table"><thead class="dark"><tr><th>'.$h(_f2L('jail_txt')).'</th><th>'.$h(_f2L('banned_txt')).'</th><th>'.$h(_f2L('failed_txt')).'</th><th>'.$h(_f2L('total_txt')).'</th></tr></thead><tbody>';
	foreach($jails as $j) {
		echo '<tr><td><a href="#jail_'.$h($j['jail']).'"><b>'.$h($j['jail']).'</b></a></td><td>'.(int)$j['banned'].'</td><td>'.(int)$j['failed'].'</td><td>'.(int)$j['total'].'</td></tr>';
	}
	echo '</tbody></table>';

	// забаненные IP по каждому джейлу + кнопка «разбанить»
	foreach($jails as $j) {
		$ips = preg_split('/\s+/', trim((string)$j['banned_ips']), -1, PREG_SPLIT_NO_EMPTY);
		echo '<a name="jail_'.$h($j['jail']).'"></a><p class="fieldset-legend" style="margin-top:18px;">'.$h(_f2L('jail_txt')).': '.$h($j['jail']).' ('.count($ips).')</p>';
		if(empty($ips)) { echo '<div class="alert alert-success">'.$h(_f2L('none_banned_txt')).'</div>'; continue; }
		echo '<table class="table"><thead class="dark"><tr><th>IP</th><th style="width:120px;">'.$h(_f2L('action_txt')).'</th></tr></thead><tbody>';
		foreach($ips as $bip) {
			echo '<tr><td><code>'.$h($bip).'</code></td><td><a class="btn btn-default btn-xs ss-f2b-unban" href="#" data-jail="'.$h($j['jail']).'" data-ip="'.$h($bip).'">'.$h(_f2L('unban_txt')).'</a></td></tr>';
		}
		echo '</tbody></table>';
	}
}

// ---- форма «забанить IP вручную» ----
echo '<p class="fieldset-legend" style="margin-top:18px;">'.$h(_f2L('ban_manual_txt')).'</p>';
echo '<div class="form-group" style="max-width:640px;">';
echo '<input type="text" id="f2b_ip" class="form-control" placeholder="'.$h(_f2L('ban_ip_ph_txt')).'" style="display:inline-block;width:220px;"> ';
echo '<select id="f2b_jail" class="form-control" style="display:inline-block;width:200px;">';
foreach($jails as $j) echo '<option value="'.$h($j['jail']).'">'.$h($j['jail']).'</option>';
echo '</select> ';
echo '<a href="#" class="btn btn-default" id="f2b_ban_btn">'.$h(_f2L('ban_txt')).'</a>';
echo '</div>';
?>
<script type="text/javascript">
jQuery(function($){
	$('#f2b_ban_btn').off('click.f2b').on('click.f2b', function(e){
		e.preventDefault();
		var ip = $.trim($('#f2b_ip').val()), jail = $('#f2b_jail').val();
		if(!ip || !jail) return;
		ssAct('admin/fail2ban_list.php', {do: 'ban', jail: jail, ip: ip});
	});
	$(document).off('click.f2bun').on('click.f2bun', '.ss-f2b-unban', function(e){
		e.preventDefault();
		$(this).css({opacity:.5,'pointer-events':'none'});
		ssAct('admin/fail2ban_list.php', {do: 'unban', jail: $(this).data('jail'), ip: $(this).data('ip')});
	});
});
</script>
