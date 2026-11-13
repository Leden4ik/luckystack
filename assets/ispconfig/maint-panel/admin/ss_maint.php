<?php
/*
  LuckyStack: страница «Обслуживание сервера» (только админ). Показывает состояние сервера
  и проверки, запускает обновление по списку разрешённых пунктов, меняет настройки установщика
  и показывает журнал действий в наших панелях.

  Интерфейс работает не от root: страница только ставит задание в очередь ss_maint_job, а root-cron
  ss-maint-sync.php его проверяет и выполняет. Действия только POST с CSRF-токеном, каждое пишется
  в журнал. Локализована (en + язык пользователя).
*/

require_once '../../lib/config.inc.php';
require_once '../../lib/app.inc.php';
require_once '../../lib/ss_panel.inc.php';
$app->auth->check_module_permissions('admin');
if(!$app->auth->is_admin()) die('Allowed for administrators only.');
$app->uses('functions');

$wb = array();
$_ld = __DIR__.'/lib/lang/';
@include $_ld.'en_ss_maint.lng';
$_ul = isset($_SESSION['s']['language']) ? preg_replace('/[^a-z]/', '', $_SESSION['s']['language']) : 'en';
if($_ul && $_ul !== 'en' && file_exists($_ld.$_ul.'_ss_maint.lng')) @include $_ld.$_ul.'_ss_maint.lng';
function _mL($k) { global $wb; return isset($wb[$k]) ? $wb[$k] : $k; }
$h = function($s) { global $app; return $app->functions->htmlentities((string)$s); };

// Списки дублируют ss-maint-sync.php: здесь для показа, проверка обязательная там.
$ITEMS = array('pkgs', 'security', 'confcustom', 'mail', 'certs', 'rcplugins', 'backup', 'notify', 'tuning', 'nginx', 'ispconfig');
$ITEMS_CORE = array('nginx', 'ispconfig');
$SET_GROUPS = array(
	'set_group_nginx_txt'    => array('OPENSSL_BRANCH' => array('3.5', '4.1', '4.0'), 'NGINX_CHANNEL' => array('stable', 'mainline'),
		'NGX_BROTLI' => 0, 'NGX_ZSTD' => 0, 'NGX_ZLIBNG' => 0, 'NGX_HEADERMOD' => 0, 'NGX_CACHEPURGE' => 0, 'NGX_SETMISC' => 0, 'NGX_VTS' => 0, 'NGX_JEMALLOC' => 0, 'NGX_NATIVE_OPT' => 0,
		'NGX_QUIC_GSO' => 0, 'NGX_QUIC_RETRY' => 0),
	'set_group_security_txt' => array('NGX_TIGHT_TIMEOUTS' => 0, 'SEC_SERVICE_HARDEN' => 0, 'SEC_AUTO_UPDATES_3RD' => 0, 'SEC_USERNS_OFF' => 0, 'SSH_TCP_FORWARD' => 0, 'FTP_TLS_REQUIRED' => 0, 'RC_BRANCH' => array('1.6', '1.7')),
);

$tab = isset($_GET['tab']) ? (string)$_GET['tab'] : 'overview';
if(!in_array($tab, array('overview', 'update', 'settings', 'audit'), true)) $tab = 'overview';

$msg = '';
$pending = $app->db->queryOneRecord("SELECT id, action, status FROM ss_maint_job WHERE status IN ('pending','running') ORDER BY id ASC LIMIT 1");
$busy = (is_array($pending) && !empty($pending));

$queue = function($action, $payload = null) use ($app) {
	$app->db->query("INSERT INTO ss_maint_job (action, payload, status, created) VALUES (?, ?, 'pending', NOW())", $action, $payload === null ? null : json_encode($payload));
};

if(ss_is_action()) {
	$do = ss_post('do');
	if($busy) {
		$msg = '<div class="alert alert-info"><b>'.$h(_mL('busy_txt')).'</b></div>';
	} elseif($do === 'refresh' || $do === 'healthcheck') {
		$queue($do);
		ss_audit('maint', $do);
		$busy = true;
	} elseif($do === 'update') {
		$items = array_values(array_intersect($ITEMS, preg_split('/[\s,]+/', ss_post('items'), -1, PREG_SPLIT_NO_EMPTY)));
		if(empty($items)) $msg = '<div class="alert alert-warning">'.$h(_mL('no_items_txt')).'</div>';
		else {
			$queue('update', array('items' => $items));
			ss_audit('maint', 'update', implode(' ', $items));
			$busy = true;
		}
	} elseif($do === 'rollback') {
		$target = ss_post('target');
		if(in_array($target, array('nginx', 'roundcube'), true)) {
			$queue('rollback', array('target' => $target));
			ss_audit('maint', 'rollback', $target);
			$busy = true;
		}
	} elseif($do === 'save') {
		$p = array();
		$em = ss_post('sec_email');
		if($em !== '') {
			if(preg_match('/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/', $em)) $p['SEC_ADMIN_EMAIL'] = $em;
			else $msg = '<div class="alert alert-warning">'.$h(_mL('bad_email_txt')).'</div>';
		}
		foreach($SET_GROUPS as $g) foreach($g as $k => $vals) {
			$v = ss_post('s_'.$k);
			$allowed = is_array($vals) ? $vals : array('y', 'n');
			if(in_array($v, $allowed, true)) $p[$k] = $v;
		}
		$queue('save', $p);
		$summary = array(); foreach($p as $k => $v) $summary[] = $k.'='.$v;
		ss_audit('maint', 'save', implode(' ', $summary));
		$busy = true;
	}
}

$st = array();
foreach((array)$app->db->queryAllRecords("SELECT name, value, updated FROM ss_maint_setting") as $r) { $st[$r['name']] = $r['value']; $st[$r['name'].'__t'] = $r['updated']; }
$g = function($k, $d = '') use ($st) { return isset($st[$k]) ? $st[$k] : $d; };
$J = function($k) use ($g) { $v = json_decode($g($k, ''), true); return is_array($v) ? $v : array(); };
$problem = $g('installer_problem');
$can_run = ($problem === '' && $g('installer_dir') !== '');

$page = 'admin/ss_maint.php';
echo '<div class="page-header"><h1>'.$h(_mL('head_txt')).'</h1></div>';
echo $msg;
echo ss_action_form('maint');
if($problem !== '') echo '<div class="alert alert-danger"><b>'.$h(_mL('installer_bad_txt')).'</b> '.$h($problem).'</div>';
elseif($g('installer_dir') === '') echo '<div class="alert alert-info">'.$h(_mL('no_data_txt')).'</div>';

echo '<ul class="nav nav-tabs" style="margin-bottom:15px">';
foreach(array('overview', 'update', 'settings', 'audit') as $t) {
	echo '<li'.($t === $tab ? ' class="active"' : '').'><a href="#" class="ss-mt-nav" data-u="'.$h($page.'?tab='.$t).'">'.$h(_mL('tab_'.$t.'_txt')).'</a></li>';
}
echo '</ul>';
if($busy) echo '<div class="alert alert-warning">⏳ <b>'.$h(_mL('busy_txt')).'</b> '.$h(_mL('busy_hint_txt')).'</div>';

// Куда идти, чтобы исправить проверку. Тексты проверок приходят из ss-maint-sync.php и --healthcheck.
$FIXES = array(
	'/двухфакторн/u'                                  => 'tools/user_settings.php',
	'/Письма о безопасности/u'                        => $page.'?tab=settings',
	'/уведомления никуда/u'                           => 'admin/notify_settings.php',
	'/бэкап|\/var\/vmail/ui'                          => 'admin/backup_restore_list.php',
	'/ограничений systemd/u'                          => $page.'?tab=settings',
	'/Автообновления PHP/u'                           => $page.'?tab=settings',
	'/OpenSSL/u'                                      => $page.'?tab=settings',
	'/Пакетов к обновлению|setup\.log/u'              => $page.'?tab=update',
	'/Shell-пользовател/u'                            => 'sites/shell_user_list.php',
	'/^PHP [0-9.]+/u'                                 => 'sites/web_vhost_domain_list.php',
);
$fix = function($lvl, $text) use ($FIXES, $h) {
	if($lvl === 'ok') return '';
	foreach($FIXES as $re => $u) if(preg_match($re, $text)) return ' <a href="#" class="btn btn-default btn-xs ss-mt-nav" data-u="'.$h($u).'">'.$h(_mL('fix_btn_txt')).'</a>';
	return '';
};

$icon = array('ok' => '<span class="text-success">✓</span>', 'warn' => '<span class="text-warning">!</span>', 'fail' => '<span class="text-danger">✗</span>');
$dis = ($busy || !$can_run) ? ' style="opacity:.5;pointer-events:none"' : '';

if($tab === 'overview') {
	echo '<p><a href="#" class="btn btn-default ss-mt-act" data-do="refresh"'.$dis.'>'.$h(_mL('refresh_btn_txt')).'</a> '
		.'<a href="#" class="btn btn-default ss-mt-act" data-do="healthcheck"'.$dis.'>'.$h(_mL('health_btn_txt')).'</a></p>';

	$v = $J('versions');
	echo '<table class="table" style="max-width:820px"><tbody>';
	foreach(array('luckystack', 'os', 'kernel', 'nginx', 'openssl', 'php', 'php_default', 'mariadb', 'ispconfig', 'roundcube', 'uptime') as $k) {
		if(!empty($v[$k])) echo '<tr><th style="width:240px">'.$h(_mL('ver_'.$k.'_txt')).'</th><td>'.$h($v[$k]).'</td></tr>';
	}
	if($g('installer_dir') !== '') echo '<tr><th>'.$h(_mL('installer_txt')).'</th><td><code>'.$h($g('installer_dir')).'</code> ('.$h($g('installer_date')).')</td></tr>';
	echo '</tbody></table>';

	$order = array('fail' => 0, 'warn' => 1, 'ok' => 2);
	$checks = $J('checks');
	usort($checks, function($a, $b) use ($order) { return $order[$a[0]] - $order[$b[0]]; });
	echo '<h3>'.$h(_mL('security_head_txt')).'</h3>';
	if(empty($checks)) echo '<p class="help-block">'.$h(_mL('no_data_txt')).'</p>';
	else {
		echo '<table class="table" style="max-width:820px"><tbody>';
		foreach($checks as $c) echo '<tr><td style="width:24px">'.$icon[$c[0]].'</td><td>'.$h($c[1]).$fix($c[0], $c[1]).'</td></tr>';
		echo '</tbody></table>';
	}

	$hc = $J('health');
	echo '<h3>'.$h(_mL('health_head_txt')).'</h3>';
	if(empty($hc['groups'])) echo '<p class="help-block">'.$h(_mL('no_data_txt')).'</p>';
	else {
		$cn = $hc['counts'];
		echo '<p>'.$h(_mL('health_time_txt')).' '.$h($hc['time']).': <span class="text-success">OK '.(int)$cn['ok'].'</span>, <span class="text-warning">'.$h(_mL('warn_txt')).' '.(int)$cn['warn'].'</span>, <span class="text-danger">'.$h(_mL('fail_txt')).' '.(int)$cn['fail'].'</span></p>';
		echo '<table class="table" style="max-width:820px"><tbody>';
		$any = false;
		foreach($hc['groups'] as $gn => $rows) foreach($rows as $c) {
			if($c[0] === 'ok') continue;
			$any = true;
			echo '<tr><td style="width:24px">'.$icon[$c[0]].'</td><td style="width:220px">'.$h($gn).'</td><td>'.$h($c[1]).$fix($c[0], $c[1]).'</td></tr>';
		}
		if(!$any) echo '<tr><td>'.$icon['ok'].'</td><td colspan="2">'.$h(_mL('health_all_ok_txt')).'</td></tr>';
		echo '</tbody></table>';
	}
}

if($tab === 'update') {
	$apt = $g('apt_upgradable');
	echo '<p>'.$h(_mL('update_desc_txt')).'</p>';
	echo '<div style="max-width:820px">';
	foreach($ITEMS as $i) {
		$checked = in_array($i, array('pkgs', 'security'), true) ? ' checked' : '';
		echo '<div class="checkbox"><label><input type="checkbox" class="ss-mt-item" value="'.$h($i).'"'.$checked.'> <b>'.$h(_mL('item_'.$i.'_txt')).'</b>';
		if($i === 'pkgs' && $apt !== '' && (int)$apt > 0) echo ' <span class="label label-warning">'.(int)$apt.'</span>';
		echo '<br><span class="help-block" style="display:inline">'.$h(_mL('item_'.$i.'_hint_txt')).'</span></label></div>';
	}
	echo '<div class="alert alert-warning">'.$h(_mL('update_warn_txt')).'</div>';
	echo '<a href="#" class="btn btn-default formbutton-success" id="mt_run"'.$dis.'>'.$h(_mL('update_btn_txt')).'</a>';
	echo '</div>';

	$rb = $J('rollback');
	echo '<h3>'.$h(_mL('rollback_head_txt')).'</h3><p>'.$h(_mL('rollback_desc_txt')).'</p>';
	echo '<table class="table" style="max-width:820px"><tbody>';
	foreach(array('nginx', 'roundcube') as $t) {
		echo '<tr><th style="width:140px">'.$h(_mL('rollback_'.$t.'_txt')).'</th><td>';
		if(!empty($rb[$t])) echo $h(_mL('rollback_to_txt')).' '.$h($rb[$t]).'</td><td style="width:120px"><a href="#" class="btn btn-default btn-sm ss-mt-rollback" data-t="'.$h($t).'"'.$dis.'>'.$h(_mL('rollback_btn_txt')).'</a>';
		else echo '<span class="help-block" style="display:inline">'.$h(_mL('rollback_none_txt')).'</span></td><td>';
		echo '</td></tr>';
	}
	echo '</tbody></table>';

	$last = $app->db->queryOneRecord("SELECT id, status, result, log, started, processed FROM ss_maint_job WHERE action IN ('update','rollback') ORDER BY id DESC LIMIT 1");
	if(is_array($last) && !empty($last)) {
		$cl = ($last['status'] === 'done') ? 'text-success' : (($last['status'] === 'error') ? 'text-danger' : 'text-warning');
		echo '<h3>'.$h(_mL('log_head_txt')).' #'.(int)$last['id'].' <small class="'.$cl.'">'.$h($last['status']).'</small></h3>';
		if($last['result']) echo '<p class="'.$cl.'">'.$h($last['result']).'</p>';
		if($last['log']) {
			$lines = explode("\n", (string)$last['log']);
			echo '<pre style="max-height:420px;overflow:auto;white-space:pre-wrap">'.$h(implode("\n", array_slice($lines, -250))).'</pre>';
			echo '<p class="help-block">'.$h(_mL('log_full_txt')).' <code>/var/log/luckystack/panel/job-'.(int)$last['id'].'.log</code></p>';
		}
	}

	$jobs = $app->db->queryAllRecords("SELECT id, action, status, result, created, processed FROM ss_maint_job ORDER BY id DESC LIMIT 12");
	if(is_array($jobs) && !empty($jobs)) {
		echo '<h3>'.$h(_mL('history_head_txt')).'</h3><table class="table" style="max-width:820px"><thead class="dark"><tr><th>'.$h(_mL('col_action_txt')).'</th><th>'.$h(_mL('col_status_txt')).'</th><th>'.$h(_mL('col_when_txt')).'</th></tr></thead><tbody>';
		foreach($jobs as $j) {
			$c = ($j['status'] === 'done') ? 'text-success' : (($j['status'] === 'error') ? 'text-danger' : 'text-warning');
			echo '<tr><td>'.$h($j['action']).'</td><td class="'.$c.'"><b>'.$h($j['status']).'</b>'.($j['result'] ? ' <span class="help-block" style="display:inline">'.$h($j['result']).'</span>' : '').'</td><td>'.$h($j['processed'] ?: $j['created']).'</td></tr>';
		}
		echo '</tbody></table>';
	}
}

if($tab === 'settings') {
	$cfg = $J('cfg');
	$used = $J('module_used');
	echo '<p>'.$h(_mL('settings_desc_txt')).'</p>';
	echo '<div class="alert alert-info">'.$h(_mL('settings_apply_txt')).'</div>';
	foreach($SET_GROUPS as $gl => $keys) {
		echo '<h3>'.$h(_mL($gl)).'</h3><table class="table" style="max-width:820px"><tbody>';
		foreach($keys as $k => $vals) {
			$cur = isset($cfg[$k]) ? $cfg[$k] : '';
			echo '<tr><td style="width:300px"><b>'.$h(_mL('set_'.$k.'_txt')).'</b><br><span class="help-block" style="display:inline">'.$h(_mL('set_'.$k.'_hint_txt')).'</span>';
			if(isset($used[$k]) && $used[$k] === 'y') echo '<br><span class="text-warning">'.$h(_mL('module_in_use_txt')).'</span>';
			elseif(isset($used[$k]) && $cur === 'y') echo '<br><span class="help-block" style="display:inline">'.$h(_mL('module_unused_txt')).'</span>';
			echo '</td><td>';
			echo '<select class="form-control ss-mt-set" data-k="'.$h($k).'" style="width:auto">';
			$opts = is_array($vals) ? $vals : array('y', 'n');
			foreach($opts as $o) {
				$label = is_array($vals) ? $o : _mL($o === 'y' ? 'on_txt' : 'off_txt');
				echo '<option value="'.$h($o).'"'.($o === $cur ? ' selected' : '').'>'.$h($label).'</option>';
			}
			echo '</select></td></tr>';
		}
		echo '</tbody></table>';
	}
	echo '<h3>'.$h(_mL('set_group_mail_txt')).'</h3><table class="table" style="max-width:820px"><tbody><tr><td style="width:300px"><b>'.$h(_mL('sec_email_txt')).'</b><br><span class="help-block" style="display:inline">'.$h(_mL('sec_email_hint_txt')).'</span></td>'
		.'<td><input type="text" id="mt_sec_email" class="form-control" style="max-width:340px" value="'.$h($g('sec_email') === 'root@localhost' ? '' : $g('sec_email')).'" placeholder="admin@example.com"></td></tr></tbody></table>';
	echo '<a href="#" class="btn btn-default formbutton-success" id="mt_save"'.$dis.'>'.$h(_mL('save_btn_txt')).'</a>';
}

if($tab === 'audit') {
	echo '<p>'.$h(_mL('audit_desc_txt')).'</p>';
	$rows = $app->db->queryAllRecords("SELECT created, username, ip, panel, action, detail FROM ss_panel_audit ORDER BY id DESC LIMIT 200");
	if(!is_array($rows) || empty($rows)) echo '<p class="help-block">'.$h(_mL('audit_empty_txt')).'</p>';
	else {
		echo '<table class="table"><thead class="dark"><tr><th>'.$h(_mL('col_when_txt')).'</th><th>'.$h(_mL('col_user_txt')).'</th><th>IP</th><th>'.$h(_mL('col_panel_txt')).'</th><th>'.$h(_mL('col_action_txt')).'</th><th>'.$h(_mL('col_detail_txt')).'</th></tr></thead><tbody>';
		foreach($rows as $r) echo '<tr><td style="white-space:nowrap">'.$h($r['created']).'</td><td>'.$h($r['username']).'</td><td>'.$h($r['ip']).'</td><td>'.$h($r['panel']).'</td><td>'.$h($r['action']).'</td><td style="word-break:break-word">'.$h($r['detail']).'</td></tr>';
		echo '</tbody></table>';
	}
}
?>
<script type="text/javascript">
jQuery(function($){
	function nav(u){ if(typeof loadContent==='function')loadContent(u); else if(typeof ISPConfig!=='undefined'&&ISPConfig.loadContent)ISPConfig.loadContent(u); }
	var self = <?php echo json_encode($page.'?tab='.$tab); ?>;
	var txtUpdate = <?php echo json_encode(_mL('update_confirm_txt'), JSON_UNESCAPED_UNICODE); ?>;
	var txtCore = <?php echo json_encode(_mL('update_core_confirm_txt'), JSON_UNESCAPED_UNICODE); ?>;
	var core = <?php echo json_encode($ITEMS_CORE); ?>;
	var txtRollback = <?php echo json_encode(_mL('rollback_confirm_txt'), JSON_UNESCAPED_UNICODE); ?>;
	$(document).off('click.mtnav').on('click.mtnav','.ss-mt-nav',function(e){e.preventDefault(); nav($(this).data('u'));});
	$(document).off('click.mtact').on('click.mtact','.ss-mt-act',function(e){e.preventDefault(); ssAct(self,{do:$(this).data('do')});});
	$('#mt_run').off('click.mt').on('click.mt',function(e){e.preventDefault();
		var it=[], hasCore=false;
		$('.ss-mt-item:checked').each(function(){ it.push(this.value); if($.inArray(this.value,core)>=0)hasCore=true; });
		if(!it.length)return;
		ssAct(self,{do:'update',items:it.join(' ')},(hasCore?txtCore:txtUpdate)+'\n\n'+it.join(', '));
	});
	$(document).off('click.mtrb').on('click.mtrb','.ss-mt-rollback',function(e){e.preventDefault();
		ssAct(self,{do:'rollback',target:$(this).data('t')},txtRollback);
	});
	$('#mt_save').off('click.mt').on('click.mt',function(e){e.preventDefault();
		var p={do:'save'};
		$('.ss-mt-set').each(function(){ p['s_'+$(this).data('k')]=$(this).val(); });
		p.sec_email = $.trim($('#mt_sec_email').val());
		ssAct(self,p);
	});
	<?php if($busy) { ?>setTimeout(function(){ if($('#pageContent .ss-mt-nav').length||$('.ss-mt-nav').length) nav(self); }, 6000);<?php } ?>
});
</script>
