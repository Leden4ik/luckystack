<?php
/*
  LuckyStack: страница «Бэкап / Восстановление» (только админ).
  Список снимков (кэш backup_snapshot, наполняет root-cron ss-backup-sync.php) + выбор
  компонентов + грозное подтверждение → запись в очередь backup_restore → root-cron
  выполняет server-backup.sh --restore ≤1 мин. Локализована (en + язык пользователя).

  ВОССТАНОВЛЕНИЕ НЕОБРАТИМО перезаписывает данные. Поэтому: db выбран по умолчанию,
  опасные компоненты (etc/www/vmail/ispconfig) — только явно + обязательная галочка-согласие.
*/

require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';
require_once '../../lib/ss_panel.inc.php';

$app->auth->check_module_permissions('admin');
if(!$app->auth->is_admin()) die('Allowed for administrators only.');
$app->uses('functions');

$wb = array();
$_ld = __DIR__.'/lib/lang/';
@include $_ld.'en_backup_restore.lng';
$_ul = isset($_SESSION['s']['language']) ? preg_replace('/[^a-z]/', '', $_SESSION['s']['language']) : 'en';
if($_ul && $_ul !== 'en' && file_exists($_ld.$_ul.'_backup_restore.lng')) @include $_ld.$_ul.'_backup_restore.lng';
function _bL($k) { global $wb; return isset($wb[$k]) ? $wb[$k] : $k; }

$h = function($s){ global $app; return $app->functions->htmlentities((string)$s); };
$ALLOWED = array('db','etc','ispconfig','www','vmail');

// ---- действие: поставить restore/бэкап/конфиг в очередь (только POST + CSRF-токен) ----
$msg = '';
$do = ''; $snap = ''; $comp = '';
if(ss_is_action()) {
	$do   = ss_post('do');
	$snap = ss_post('snap');
	$comp = ss_post('components');
}

// Анти-дубль: не ставим новую операцию, пока прошлая (бэкап/конфиг/восстановление) не завершилась.
$pj = $app->db->queryOneRecord("SELECT id FROM backup_job WHERE status IN ('pending','running') LIMIT 1");
$pr = $app->db->queryOneRecord("SELECT id FROM backup_restore WHERE status IN ('pending','running') LIMIT 1");
$busy = ((is_array($pj) && !empty($pj)) || (is_array($pr) && !empty($pr)));
$attempted = in_array($do, array('restore','runbackup','savecfg'), true);

if($attempted && $busy) {
	// повторное нажатие, пока прошлая задача не выполнена — дубль не создаём
	$msg = '<div class="alert alert-info"><b>'.$h(_bL('busy_txt')).'</b> '.$h(_bL('busy_hint_txt')).'</div>';
} else {
	if($do === 'restore') {
		$oks = preg_match('/^[0-9]{8}-[0-9]{6}$/', $snap);
		$row = $oks ? $app->db->queryOneRecord("SELECT snapshot FROM backup_snapshot WHERE snapshot = ?", $snap) : null;
		$sel = array();
		foreach(explode(',', $comp) as $c) { $c = trim($c); if(in_array($c, $ALLOWED, true)) $sel[] = $c; }
		if($oks && is_array($row) && !empty($row) && !empty($sel)) {
			$app->db->query("INSERT INTO backup_restore (snapshot, components, status, created) VALUES (?,?, 'pending', NOW())", $snap, implode(',', $sel));
			ss_audit('backup', 'restore', $snap.': '.implode(',', $sel));
			$busy = true;
			$msg = '<div class="alert alert-warning"><b>'.$h(_bL('queued_txt')).'</b> '.$h($snap).' — '.$h(implode(', ', $sel)).'. '.$h(_bL('queued_hint_txt')).'</div>';
		} else {
			$msg = '<div class="alert alert-danger">'.$h(_bL('bad_input_txt')).'</div>';
		}
	}
	if($do === 'runbackup') {
		$app->db->query("INSERT INTO backup_job (action, status, created) VALUES ('run', 'pending', NOW())");
		ss_audit('backup', 'run');
		$busy = true;
		$msg = '<div class="alert alert-warning"><b>'.$h(_bL('run_queued_txt')).'</b> '.$h(_bL('queued_hint_txt')).'</div>';
	}
	if($do === 'savecfg') {
		$pl = array(
			'backup_dir'   => ss_post('dir'),
			'retention'    => ss_post('ret'),
			'time'         => ss_post('time'),
			'include_www'  => (ss_post('www') === 'y')  ? 'y' : 'n',
			'include_mail' => (ss_post('mail') === 'y') ? 'y' : 'n',
			'remote_type'  => ss_post('rt', 'none'),
			'remote'       => ss_post('rem'),
			'timer'        => (ss_post('timer') === 'y') ? 'y' : 'n',
		);
		$app->db->query("INSERT INTO backup_job (action, payload, status, created) VALUES ('config', ?, 'pending', NOW())", json_encode($pl));
		ss_audit('backup', 'config', 'dir='.$pl['backup_dir'].' ret='.$pl['retention'].' time='.$pl['time'].' www='.$pl['include_www'].' mail='.$pl['include_mail'].' remote='.$pl['remote_type'].' '.$pl['remote'].' timer='.$pl['timer']);
		$busy = true;
		$msg = '<div class="alert alert-warning"><b>'.$h(_bL('cfg_queued_txt')).'</b> '.$h(_bL('queued_hint_txt')).'</div>';
	}
}

// текущие настройки (кэш от root-cron) + последние job'ы
$st = array();
foreach((array)$app->db->queryAllRecords("SELECT name, value FROM backup_setting") as $r) $st[$r['name']] = $r['value'];
$bjobs = $app->db->queryAllRecords("SELECT action, status, result, processed FROM backup_job ORDER BY id DESC LIMIT 6");
if(!is_array($bjobs)) $bjobs = array();

$snaps = $app->db->queryAllRecords("SELECT snapshot, size, components, created FROM backup_snapshot ORDER BY snapshot DESC");
if(!is_array($snaps)) $snaps = array();
$jobs = $app->db->queryAllRecords("SELECT id, snapshot, components, status, result, created, processed FROM backup_restore ORDER BY id DESC LIMIT 10");
if(!is_array($jobs)) $jobs = array();

echo '<div class="page-header"><h1>'.$h(_bL('list_head_txt')).'</h1></div>';
echo '<p>'.$h(_bL('list_desc_txt')).'</p>';
echo $msg;
echo ss_action_form('backup');

// ===== НАСТРОЙКИ БЭКАПА + «Бэкап сейчас» =====
$g = function($k,$d='') use ($st){ return isset($st[$k]) ? $st[$k] : $d; };
$script_ok = ($g('script_present','n') === 'y');
echo '<p class="fieldset-legend">'.$h(_bL('settings_txt')).'</p>';
if(!$script_ok) echo '<div class="alert alert-warning">'.$h(_bL('noscript_txt')).'</div>';
// статус: таймер + последний снимок
$tmr_on = ($g('timer_enabled','n') === 'y');
echo '<p class="help-block">'
	.$h(_bL('timer_txt')).': <b class="'.($tmr_on?'text-success':'text-danger').'">'.$h($tmr_on?_bL('on_txt'):_bL('off_txt')).'</b> ('.$h($g('time','03:30')).') · '
	.$h(_bL('last_backup_txt')).': '.$h($g('last_snapshot','—')).($g('last_size')!==''?' ('.$h($g('last_size')).')':'').'</p>';
echo '<div style="max-width:720px;">';
echo '<div class="form-group"><label class="col-sm-3 control-label">'.$h(_bL('dir_txt')).'</label><div class="col-sm-9"><input type="text" id="bk_dir" class="form-control" value="'.$h($g('backup_dir','/var/backups/server')).'"></div></div>';
echo '<div class="form-group"><label class="col-sm-3 control-label">'.$h(_bL('ret_txt')).'</label><div class="col-sm-9"><input type="text" id="bk_ret" class="form-control" style="width:100px" value="'.$h($g('retention','7')).'"></div></div>';
echo '<div class="form-group"><label class="col-sm-3 control-label">'.$h(_bL('time_txt')).'</label><div class="col-sm-9"><input type="text" id="bk_time" class="form-control" style="width:100px" value="'.$h($g('time','03:30')).'" placeholder="03:30"></div></div>';
echo '<div class="form-group"><label class="col-sm-3 control-label">'.$h(_bL('include_txt')).'</label><div class="col-sm-9">'
	.'<label style="font-weight:normal"><input type="checkbox" id="bk_www"'.($g('include_www')==='y'?' checked':'').'> /var/www</label> &nbsp; '
	.'<label style="font-weight:normal"><input type="checkbox" id="bk_mail"'.($g('include_mail')==='y'?' checked':'').'> /var/vmail</label></div></div>';
echo '<div class="form-group"><label class="col-sm-3 control-label">'.$h(_bL('offsite_txt')).'</label><div class="col-sm-9">'
	.'<select id="bk_rt" class="form-control" style="display:inline-block;width:130px">';
foreach(array('none','rsync','rclone') as $o) echo '<option value="'.$o.'"'.($g('remote_type','none')===$o?' selected':'').'>'.$o.'</option>';
echo '</select> <input type="text" id="bk_rem" class="form-control" style="display:inline-block;width:340px" value="'.$h($g('remote')).'" placeholder="user@host:/path  |  remote:bucket/path"></div></div>';
echo '<div class="form-group"><label class="col-sm-3 control-label">'.$h(_bL('timer_txt')).'</label><div class="col-sm-9"><label style="font-weight:normal"><input type="checkbox" id="bk_timer"'.($tmr_on?' checked':'').'> '.$h(_bL('timer_on_txt')).'</label></div></div>';
$dstyle = $busy ? ' style="opacity:.5;pointer-events:none"' : '';
echo '<div class="form-group"><div class="col-sm-offset-3 col-sm-9">'
	.'<a href="#" class="btn btn-default formbutton-success" id="bk_save"'.$dstyle.'>'.$h(_bL('save_txt')).'</a> '
	.'<a href="#" class="btn btn-default" id="bk_run"'.$dstyle.'>'.$h(_bL('run_now_txt')).'</a>';
if($busy) echo ' <span class="text-warning">⏳ <b>'.$h(_bL('busy_txt')).'</b></span>';
echo '</div></div>';
echo '</div>';
// последние backup-задачи
if(!empty($bjobs)) {
	echo '<table class="table" style="max-width:720px"><thead class="dark"><tr><th>'.$h(_bL('col_action_txt')).'</th><th>'.$h(_bL('col_status_txt')).'</th><th>'.$h(_bL('col_when_txt')).'</th></tr></thead><tbody>';
	foreach($bjobs as $j) { $c=($j['status']==='done')?'text-success':(($j['status']==='error')?'text-danger':'text-warning');
		echo '<tr><td>'.$h($j['action']).'</td><td class="'.$c.'"><b>'.$h($j['status']).'</b>'.($j['result']?' <span class="help-block" style="display:inline">'.$h(mb_substr((string)$j['result'],-80)).'</span>':'').'</td><td>'.$h($j['processed']).'</td></tr>'; }
	echo '</tbody></table>';
}
?>
<script type="text/javascript">
jQuery(function($){
	function nav(u){ if(typeof loadContent==='function')loadContent(u); else if(typeof ISPConfig!=='undefined'&&ISPConfig.loadContent)ISPConfig.loadContent(u); }
	window.ssBackupBusy = <?php echo $busy ? 'true' : 'false'; ?>;
	function lock(){ window.ssBackupBusy=true; $('#bk_save,#bk_run,.ss-restore-btn').css({opacity:.5,'pointer-events':'none'}); }
	$('#bk_save').off('click.bk').on('click.bk',function(e){e.preventDefault(); if(window.ssBackupBusy)return; lock();
		ssAct('admin/backup_restore_list.php', {do: 'savecfg',
			dir: $('#bk_dir').val(), ret: $('#bk_ret').val(), time: $('#bk_time').val(),
			www: ($('#bk_www').is(':checked')?'y':'n'), mail: ($('#bk_mail').is(':checked')?'y':'n'),
			rt: $('#bk_rt').val(), rem: $('#bk_rem').val(), timer: ($('#bk_timer').is(':checked')?'y':'n')});
	});
	$('#bk_run').off('click.bk').on('click.bk',function(e){e.preventDefault(); if(window.ssBackupBusy)return;
		if(!confirm(<?php echo json_encode(_bL('run_confirm_txt')); ?>))return;
		lock(); ssAct('admin/backup_restore_list.php', {do: 'runbackup'});
	});
	// пока задача (бэкап/конфиг/восстановление) выполняется — авто-обновляем контент
	// до результата и разблокировки кнопок (крон обрабатывает раз/мин; бэкап может идти минуты).
	if(window.ssBackupBusy){ setTimeout(function(){ nav('admin/backup_restore_list.php'); }, 5000); }
});
</script>
<?php
echo '<div class="alert alert-danger" style="margin-top:18px"><b>'.$h(_bL('warn_title_txt')).'</b> '.$h(_bL('warn_body_txt')).'</div>';

// последние задачи восстановления
if(!empty($jobs)) {
	echo '<p class="fieldset-legend">'.$h(_bL('jobs_txt')).'</p><table class="table"><thead class="dark"><tr><th>#</th><th>'.$h(_bL('col_snapshot_txt')).'</th><th>'.$h(_bL('col_components_txt')).'</th><th>'.$h(_bL('col_status_txt')).'</th><th>'.$h(_bL('col_when_txt')).'</th></tr></thead><tbody>';
	foreach($jobs as $j) {
		$st = $j['status'];
		$cls = ($st === 'done') ? 'text-success' : (($st === 'error') ? 'text-danger' : (($st === 'running') ? 'text-warning' : ''));
		echo '<tr><td>'.(int)$j['id'].'</td><td><code>'.$h($j['snapshot']).'</code></td><td>'.$h($j['components']).'</td><td class="'.$cls.'"><b>'.$h($st).'</b>'.($j['result'] ? ' <span class="help-block" style="display:inline">'.$h(substr($j['result'],0,80)).'</span>' : '').'</td><td>'.$h($j['processed'] ?: $j['created']).'</td></tr>';
	}
	echo '</tbody></table>';
}

if(empty($snaps)) {
	echo '<div class="alert alert-info">'.$h(_bL('no_snaps_txt')).'</div>';
	return;
}

echo '<p class="fieldset-legend" style="margin-top:18px;">'.$h(_bL('snaps_txt')).'</p>';
echo '<table class="table"><thead class="dark"><tr><th>'.$h(_bL('col_snapshot_txt')).'</th><th>'.$h(_bL('col_size_txt')).'</th><th>'.$h(_bL('col_components_txt')).'</th><th style="width:46%;">'.$h(_bL('col_restore_txt')).'</th></tr></thead><tbody>';
foreach($snaps as $i => $s) {
	$present = array_filter(array_map('trim', explode(',', (string)$s['components'])));
	$sid = 'r'.$i;
	echo '<tr><td><code>'.$h($s['snapshot']).'</code><br><span class="help-block">'.$h($s['created']).'</span></td><td>'.$h($s['size']).'</td><td>'.$h(implode(', ', $present)).'</td><td>';
	if(empty($present)) { echo '<span class="help-block">'.$h(_bL('empty_snap_txt')).'</span></td></tr>'; continue; }
	// чекбоксы доступных компонентов (db по умолчанию вкл)
	echo '<div class="ss-restore" data-snap="'.$h($s['snapshot']).'" data-sid="'.$sid.'">';
	foreach($present as $c) {
		$danger = in_array($c, array('etc','www','vmail','ispconfig'), true);
		$chk = ($c === 'db') ? ' checked' : '';
		echo '<label style="margin-right:10px;font-weight:normal;'.($danger?'color:#c0392b;':'').'"><input type="checkbox" class="'.$sid.'_c" value="'.$h($c).'"'.$chk.'> '.$h($c).($danger?' ⚠':'').'</label>';
	}
	echo '<div style="margin-top:6px;"><label style="font-weight:normal;"><input type="checkbox" class="'.$sid.'_ack"> '.$h(_bL('ack_txt')).'</label></div>';
	echo '<button type="button" class="btn btn-default btn-xs ss-restore-btn" data-sid="'.$sid.'" data-snap="'.$h($s['snapshot']).'" style="margin-top:6px;'.($busy?'opacity:.5;pointer-events:none;':'').'">'.$h(_bL('restore_btn_txt')).'</button>';
	echo '</div></td></tr>';
}
echo '</tbody></table>';
?>
<script type="text/javascript">
jQuery(function($){
	$('.ss-restore-btn').off('click.ssb').on('click.ssb', function(e){
		e.preventDefault();
		if(window.ssBackupBusy){ alert(<?php echo json_encode(_bL('busy_hint_txt')); ?>); return; }
		var sid = $(this).data('sid'), snap = $(this).data('snap');
		if(!$('.'+sid+'_ack').is(':checked')){ alert(<?php echo json_encode(_bL('need_ack_txt')); ?>); return; }
		var comps = $('.'+sid+'_c:checked').map(function(){ return $(this).val(); }).get();
		if(!comps.length){ alert(<?php echo json_encode(_bL('need_comp_txt')); ?>); return; }
		if(!confirm(<?php echo json_encode(_bL('confirm_txt')); ?> + "\n\n" + snap + ": " + comps.join(', '))) return;
		ssAct('admin/backup_restore_list.php', {do: 'restore', snap: snap, components: comps.join(',')});
	});
});
</script>
