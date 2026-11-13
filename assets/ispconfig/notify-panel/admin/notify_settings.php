<?php
/*
  LuckyStack: страница «Уведомления» (только админ). Каналы (email, Telegram), какие события
  слать, тихие часы, пороги монитора, тест и поиск chat id. Интерфейс не root → очередь notify_job
  (save/test/discover) → root-cron ss-notify-sync.php правит /etc/server-notify.conf, шлёт тест
  через server-notify.sh и ищет чаты, которые писали боту. Действия только POST с CSRF-токеном.
  Токен бота не показывается (пусто = оставить прежний) и в кэше не хранится.
  Локализована (en + язык пользователя).
*/

require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';
require_once '../../lib/ss_panel.inc.php';
$app->auth->check_module_permissions('admin');
if(!$app->auth->is_admin()) die('Allowed for administrators only.');
$app->uses('functions');

$wb = array();
$_ld = __DIR__.'/lib/lang/';
@include $_ld.'en_notify.lng';
$_ul = isset($_SESSION['s']['language']) ? preg_replace('/[^a-z]/', '', $_SESSION['s']['language']) : 'en';
if($_ul && $_ul !== 'en' && file_exists($_ld.$_ul.'_notify.lng')) @include $_ld.$_ul.'_notify.lng';
function _nL($k) { global $wb; return isset($wb[$k]) ? $wb[$k] : $k; }
$h = function($s){ global $app; return $app->functions->htmlentities((string)$s); };

$EVENTS = array('monitor', 'backup', 'malware', 'login', 'digest');

// действия только POST + CSRF-токен; токен бота идёт в теле запроса, а не в адресе
$do = ss_is_action() ? ss_post('do') : '';
$msg = '';
// Защита от дублей: ставим новую задачу только если в очереди нет ожидающей/выполняющейся.
$pending = $app->db->queryOneRecord("SELECT id, action FROM notify_job WHERE status IN ('pending','running') ORDER BY id ASC LIMIT 1");
$busy = (is_array($pending) && !empty($pending));

if($do === 'save' && !$busy) {
	$ev = array();
	foreach($EVENTS as $e) if(ss_post('ev_'.$e) === 'y') $ev[] = $e;
	$pl = array(
		'email'      => ss_post('email'),
		'tg_chats'   => ss_post('chats'),
		'tg_token'   => ss_post('token'),
		'events'     => implode(' ', $ev),
		'login_mode' => ss_post('login_mode', 'new'),
		'quiet'      => (ss_post('q_from') !== '' || ss_post('q_to') !== '') ? ss_post('q_from').'-'.ss_post('q_to') : '',
		'disk'       => ss_post('disk'),
		'cert'       => ss_post('cert'),
		'backup'     => ss_post('backup'),
		'bot'        => (ss_post('bot') === 'y') ? 'y' : 'n',
	);
	// что именно уйдёт в очередь (без токена — он write-only)
	$what = _nL('email_txt').'='.($pl['email'] !== '' ? $pl['email'] : '—')
		.'; chat='.($pl['tg_chats'] !== '' ? $pl['tg_chats'] : '—')
		.($pl['tg_token'] !== '' ? '; '._nL('token_txt').'=•••' : '')
		.'; events='.$pl['events'].'; login='.$pl['login_mode'].'; quiet='.($pl['quiet'] !== '' ? $pl['quiet'] : '—')
		.'; disk='.$pl['disk'].'; cert='.$pl['cert'].'; backup='.$pl['backup'].'; bot='.$pl['bot'];
	$app->db->query("INSERT INTO notify_job (action, payload, status, created) VALUES ('save', ?, 'pending', NOW())", json_encode($pl));
	ss_audit('notify', 'save', $what);
	$busy = true;
	$msg = '<div class="alert alert-warning"><b>'.$h(_nL('saved_txt')).'</b> '.$h(_nL('hint_txt')).'</div>';
} elseif(($do === 'test' || $do === 'discover') && !$busy) {
	$app->db->query("INSERT INTO notify_job (action, status, created) VALUES (?, 'pending', NOW())", $do);
	ss_audit('notify', $do);
	$busy = true;
	$msg = '<div class="alert alert-warning"><b>'.$h(_nL($do === 'test' ? 'test_queued_txt' : 'discover_queued_txt')).'</b> '.$h(_nL('hint_txt')).'</div>';
} elseif(in_array($do, array('save', 'test', 'discover'), true) && $busy) {
	$msg = '<div class="alert alert-info"><b>'.$h(_nL('busy_txt')).'</b> '.$h(_nL('busy_hint_txt')).'</div>';
}

$st = array();
foreach((array)$app->db->queryAllRecords("SELECT name, value FROM notify_setting") as $r) $st[$r['name']] = $r['value'];
$g = function($k,$d='') use ($st){ return isset($st[$k]) ? $st[$k] : $d; };
$jobs = $app->db->queryAllRecords("SELECT action, status, result, processed FROM notify_job ORDER BY id DESC LIMIT 6");
if(!is_array($jobs)) $jobs = array();

echo '<div class="page-header"><h1>'.$h(_nL('head_txt')).'</h1></div>';
echo '<p>'.$h(_nL('desc_txt')).'</p>';
echo $msg;
echo ss_action_form('notify');

$active = ($g('active','n') === 'y');
echo '<div class="alert '.($active?'alert-success':'alert-info').'">'.$h(_nL($active?'active_txt':'inactive_txt')).'</div>';
if($g('tg_configured','n') === 'y' && trim($g('tg_chats')) === '') echo '<div class="alert alert-warning">'.$h(_nL('tg_no_chat_txt')).'</div>';
if($g('mta_present','y') !== 'y') echo '<div class="alert alert-warning">'.$h(_nL('nomta_txt')).'</div>';
if($g('helper_present','y') !== 'y') echo '<div class="alert alert-warning">'.$h(_nL('nohelper_txt')).'</div>';
$from = $g('from','');
if($from !== '') echo '<p class="help-block">'.$h(_nL('sender_txt')).': <code>'.$h($from).'</code> — '.$h(_nL('sender_hint_txt')).'</p>';

$events_on = ' '.$g('events', 'monitor backup malware login').' ';
$quiet = $g('quiet'); $qf = ''; $qt = '';
if(preg_match('/^(\d{1,2}:\d{2})-(\d{1,2}:\d{2})$/', $quiet, $qm)) { $qf = $qm[1]; $qt = $qm[2]; }
$row = function($label, $html, $hint = '') use ($h) {
	return '<div class="form-group"><label class="col-sm-3 control-label">'.$h($label).'</label><div class="col-sm-9">'.$html.($hint !== '' ? '<p class="help-block">'.$h($hint).'</p>' : '').'</div></div>';
};

echo '<div style="max-width:820px;">';
echo $row(_nL('email_txt'), '<input type="text" id="nt_email" class="form-control" value="'.$h($g('email')).'" placeholder="admin@example.com, ops@example.com">', _nL('email_hint_txt'));
echo $row(_nL('token_txt'), '<input type="text" id="nt_token" class="form-control" value="" placeholder="'.$h($g('tg_configured','n')==='y'?_nL('token_set_txt'):_nL('token_none_txt')).'">', _nL('token_hint_txt'));
echo $row(_nL('chat_txt'), '<input type="text" id="nt_chats" class="form-control" style="display:inline-block;width:340px" value="'.$h($g('tg_chats')).'" placeholder="123456789"> '
	.'<a href="#" class="btn btn-default btn-sm ss-nt-act" data-do="discover">'.$h(_nL('discover_btn_txt')).'</a>', _nL('chat_hint_txt'));

// найденные чаты (после «Найти chat id»)
$disc = json_decode($g('discovered', ''), true);
if(is_array($disc)) {
	$html = '';
	if(empty($disc)) $html = '<div class="alert alert-info" style="margin:0">'.$h(_nL('discover_none_txt')).'</div>';
	else {
		$html = '<table class="table" style="margin:0"><tbody>';
		foreach($disc as $c) {
			$html .= '<tr><td><code>'.$h($c['id']).'</code></td><td>'.$h($c['type']).'</td><td>'.$h($c['name']).'</td><td><span class="help-block" style="display:inline">'.$h($c['date']).'</span></td>'
				.'<td><a href="#" class="btn btn-default btn-xs ss-nt-addchat" data-id="'.$h($c['id']).'">'.$h(_nL('discover_add_txt')).'</a></td></tr>';
		}
		$html .= '</tbody></table>';
	}
	echo $row(_nL('discover_head_txt'), $html);
}

$ev = '';
foreach($EVENTS as $e) {
	$ev .= '<div><label style="font-weight:normal"><input type="checkbox" id="nt_ev_'.$e.'"'.(strpos($events_on, ' '.$e.' ') !== false ? ' checked' : '').'> '.$h(_nL('ev_'.$e.'_txt')).'</label>';
	if($e === 'login') {
		$lm = $g('login_mode', 'new');
		$ev .= ' <select id="nt_login_mode" class="form-control input-sm" style="display:inline-block;width:auto;margin-left:8px">'
			.'<option value="new"'.($lm === 'new' ? ' selected' : '').'>'.$h(_nL('login_new_txt')).'</option>'
			.'<option value="all"'.($lm === 'all' ? ' selected' : '').'>'.$h(_nL('login_all_txt')).'</option></select>';
	}
	$ev .= '</div>';
}
echo $row(_nL('events_txt'), $ev);
echo $row(_nL('quiet_txt'), '<input type="text" id="nt_qfrom" class="form-control" style="display:inline-block;width:90px" value="'.$h($qf).'" placeholder="23:00"> — '
	.'<input type="text" id="nt_qto" class="form-control" style="display:inline-block;width:90px" value="'.$h($qt).'" placeholder="08:00">', _nL('quiet_hint_txt'));
echo $row(_nL('thresholds_txt'),
	$h(_nL('disk_txt')).' <input type="text" id="nt_disk" class="form-control" style="display:inline-block;width:70px" value="'.$h($g('disk','90')).'"> &nbsp; '
	.$h(_nL('cert_txt')).' <input type="text" id="nt_cert" class="form-control" style="display:inline-block;width:70px" value="'.$h($g('cert','14')).'"> &nbsp; '
	.$h(_nL('backup_days_txt')).' <input type="text" id="nt_backup" class="form-control" style="display:inline-block;width:70px" value="'.$h($g('backup','2')).'">');

// управление из Telegram (служба server-tg-bot)
$bot_on = ($g('bot', 'n') === 'y');
$bot_html = '<label style="font-weight:normal"><input type="checkbox" id="nt_bot"'.($bot_on ? ' checked' : '').'> '.$h(_nL('bot_enable_txt')).'</label>';
if($bot_on) $bot_html .= ' &nbsp; <span class="'.($g('bot_active', 'n') === 'y' ? 'text-success' : 'text-danger').'">'.$h(_nL($g('bot_active', 'n') === 'y' ? 'bot_running_txt' : 'bot_stopped_txt')).'</span>';
echo $row(_nL('bot_txt'), $bot_html, _nL('bot_hint_txt'));

$dstyle = $busy ? ' style="opacity:.5;pointer-events:none"' : '';
echo '<div class="form-group"><div class="col-sm-offset-3 col-sm-9">'
	.'<a href="#" class="btn btn-default formbutton-success" id="nt_save"'.$dstyle.'>'.$h(_nL('save_btn_txt')).'</a> '
	.'<a href="#" class="btn btn-default ss-nt-act" data-do="test"'.$dstyle.'>'.$h(_nL('test_btn_txt')).'</a>';
if($busy) echo ' <span class="text-warning">⏳ <b>'.$h(_nL('busy_txt')).'</b></span>';
echo '<p class="help-block">'.$h(_nL('actions_hint_txt')).'</p>';
echo '</div></div>';
echo '</div>';

if(!empty($jobs)) {
	echo '<table class="table" style="max-width:820px"><thead class="dark"><tr><th>'.$h(_nL('col_action_txt')).'</th><th>'.$h(_nL('col_status_txt')).'</th><th>'.$h(_nL('col_when_txt')).'</th></tr></thead><tbody>';
	foreach($jobs as $j){ $c=($j['status']==='done')?'text-success':(($j['status']==='error')?'text-danger':'text-warning');
		echo '<tr><td>'.$h($j['action']).'</td><td class="'.$c.'"><b>'.$h($j['status']).'</b>'.($j['result']?' <span class="help-block" style="display:inline">'.$h($j['result']).'</span>':'').'</td><td>'.$h($j['processed']).'</td></tr>'; }
	echo '</tbody></table>';
}
?>
<script type="text/javascript">
jQuery(function($){
	function nav(u){ if(typeof loadContent==='function')loadContent(u); else if(typeof ISPConfig!=='undefined'&&ISPConfig.loadContent)ISPConfig.loadContent(u); }
	var page = 'admin/notify_settings.php';
	var busy = <?php echo $busy ? 'true' : 'false'; ?>;
	function lock(){ busy=true; $('#nt_save,.ss-nt-act').css({opacity:.5,'pointer-events':'none'}); }
	$('#nt_save').off('click.nt').on('click.nt',function(e){e.preventDefault(); if(busy)return; lock();
		var p = {do: 'save', email: $('#nt_email').val(), chats: $('#nt_chats').val(), token: $('#nt_token').val(),
			login_mode: $('#nt_login_mode').val(), q_from: $.trim($('#nt_qfrom').val()), q_to: $.trim($('#nt_qto').val()),
			disk: $('#nt_disk').val(), cert: $('#nt_cert').val(), backup: $('#nt_backup').val(),
			bot: ($('#nt_bot').is(':checked') ? 'y' : 'n')};
		$.each(['monitor','backup','malware','login','digest'], function(i, e){ p['ev_'+e] = $('#nt_ev_'+e).is(':checked') ? 'y' : 'n'; });
		ssAct(page, p);
	});
	$(document).off('click.ntact').on('click.ntact','.ss-nt-act',function(e){e.preventDefault(); if(busy)return; lock();
		ssAct(page, {do: $(this).data('do')});
	});
	// «Добавить» найденный чат в поле chat id (сохранить — кнопкой «Сохранить»)
	$(document).off('click.ntadd').on('click.ntadd','.ss-nt-addchat',function(e){e.preventDefault();
		var id = String($(this).data('id')), cur = $.trim($('#nt_chats').val());
		if((' '+cur+' ').indexOf(' '+id+' ') === -1) $('#nt_chats').val(cur ? cur+' '+id : id);
		$(this).css({opacity:.5,'pointer-events':'none'});
	});
	// пока задача в очереди/выполняется — сами обновляем контент, чтобы показать результат
	if(busy){ setTimeout(function(){ nav(page); }, 5000); }
});
</script>
