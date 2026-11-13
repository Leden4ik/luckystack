<?php
/*
  LuckyStack: страница «Firewall: блок-лист» (только админ) — ручной блок-лист ufw (deny) для
  IP/подсетей + подсказки по подсетям-кластерам из CrowdSec.

  Интерфейс не может дёргать ufw (root) → ведём таблицу ufw_block, а root-cron ss-ufwblock-sync.php
  реконсилит реальные правила ufw и наполняет кэш подсказок ufw_block_suggest.

  Зачем: CrowdSec firewall-bouncer НЕ применяет range-решения (кладёт CIDR как одиночный сетевой
  адрес). Поэтому подсети (напр. атакующий ротирует хосты внутри /24) блокируем через ufw — он
  обрабатывает CIDR нативно, правило ставится ПЕРВЫМ (до allow-правил портов).

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
@include $_ld.'en_ufw_block_list.lng';
$_ul = isset($_SESSION['s']['language']) ? preg_replace('/[^a-z]/', '', $_SESSION['s']['language']) : 'en';
if($_ul && $_ul !== 'en' && file_exists($_ld.$_ul.'_ufw_block_list.lng')) @include $_ld.$_ul.'_ufw_block_list.lng';
function _ubL($k) { global $wb; return isset($wb[$k]) ? $wb[$k] : $k; }

$h = function($s){ global $app; return $app->functions->htmlentities((string)$s); };

// --- валидация цели (IPv4/IPv6/CIDR; маска не шире /8 IPv4, /16 IPv6) ---
function _ub_valid_target($t) {
	if(filter_var($t, FILTER_VALIDATE_IP)) return true;
	if(strpos($t, '/') !== false) {
		list($ip, $mask) = explode('/', $t, 2);
		if(!ctype_digit($mask)) return false;
		$m = (int)$mask;
		if(filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return ($m >= 8 && $m <= 32);
		if(filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) return ($m >= 16 && $m <= 128);
	}
	return false;
}
// содержит ли CIDR данный IP (анти-локаут: не дать заблокировать свой адрес)
function _ub_ip_in_cidr($ip, $cidr) {
	if(strpos($cidr, '/') === false) return $ip === $cidr;
	list($net, $mask) = explode('/', $cidr, 2); $mask = (int)$mask;
	$ipb = @inet_pton($ip); $netb = @inet_pton($net);
	if($ipb === false || $netb === false || strlen($ipb) !== strlen($netb)) return false;
	$bytes = intdiv($mask, 8); $rem = $mask % 8;
	if($bytes > 0 && substr($ipb, 0, $bytes) !== substr($netb, 0, $bytes)) return false;
	if($rem > 0) { $mb = chr((0xff << (8 - $rem)) & 0xff); if((ord($ipb[$bytes]) & ord($mb)) !== (ord($netb[$bytes]) & ord($mb))) return false; }
	return true;
}

$admin_ip = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';

// --- действия (только POST + CSRF-токен) ---
$msg = '';
$do = ss_is_action() ? ss_post('do') : '';
if($do === 'add') {
	$target = ss_post('target');
	$comment = ss_post('comment');
	$comment = preg_replace('/[^\p{L}\p{N} ._\-\/:()]+/u', '', $comment);
	$comment = function_exists('mb_substr') ? mb_substr($comment, 0, 128) : substr($comment, 0, 128);
	if(!_ub_valid_target($target)) {
		$msg = '<div class="alert alert-danger">'.$h(_ubL('bad_target_txt')).'</div>';
	} elseif($admin_ip && _ub_ip_in_cidr($admin_ip, $target)) {
		$msg = '<div class="alert alert-danger">'.$h(_ubL('lockout_txt')).' <code>'.$h($admin_ip).'</code></div>';
	} else {
		$ex = $app->db->queryOneRecord("SELECT id FROM ufw_block WHERE target = ?", $target);
		if(is_array($ex) && !empty($ex)) {
			$app->db->query("UPDATE ufw_block SET active = 'y', comment = ?, updated = NOW() WHERE id = ?", $comment, (int)$ex['id']);
		} else {
			$app->db->query("INSERT INTO ufw_block (target, comment, active, applied, created, updated) VALUES (?,?, 'y','n', NOW(), NOW())", $target, $comment);
		}
		ss_audit('ufwblock', 'add', $target.($comment !== '' ? ' ('.$comment.')' : ''));
		$msg = '<div class="alert alert-success">'.$h(_ubL('queued_txt')).' <code>'.$h($target).'</code>. '.$h(_ubL('queued_hint_txt')).'</div>';
	}
} elseif($do === 'del') {
	$id = (int)ss_post('id', '0');
	if($id > 0) {
		$r = $app->db->queryOneRecord("SELECT target FROM ufw_block WHERE id = ?", $id);
		$app->db->query("DELETE FROM ufw_block WHERE id = ?", $id);   // cron снимет правило ufw
		ss_audit('ufwblock', 'del', is_array($r) ? $r['target'] : '#'.$id);
	}
	$msg = '<div class="alert alert-info">'.$h(_ubL('removed_txt')).'</div>';
} elseif($do === 'toggle') {
	$id = (int)ss_post('id', '0');
	if($id > 0) {
		$r = $app->db->queryOneRecord("SELECT target, active FROM ufw_block WHERE id = ?", $id);
		if(is_array($r)) {
			$na = ($r['active'] === 'y') ? 'n' : 'y';
			$app->db->query("UPDATE ufw_block SET active = ?, updated = NOW() WHERE id = ?", $na, $id);
			ss_audit('ufwblock', $na === 'y' ? 'enable' : 'disable', $r['target']);
		}
	}
}

echo '<div class="page-header"><h1>'.$h(_ubL('list_head_txt')).'</h1></div>';
echo '<p>'.$h(_ubL('list_desc_txt')).'</p>';
echo $msg;
echo ss_action_form('ufwblock');

// --- форма добавления (навигация через loadContent — не form submit: в SPA уходит на index.php) ---
echo '<div class="form-group" style="max-width:720px;margin:8px 0;">';
echo '<input type="text" id="ub_target" class="form-control" placeholder="'.$h(_ubL('target_ph_txt')).'" style="display:inline-block;width:220px;"> ';
echo '<input type="text" id="ub_comment" class="form-control" placeholder="'.$h(_ubL('comment_ph_txt')).'" style="display:inline-block;width:260px;"> ';
echo '<a href="#" class="btn btn-default" id="ub_add">'.$h(_ubL('block_txt')).'</a>';
echo '</div>';
echo '<script type="text/javascript">jQuery(function($){'
	.'$("#ub_add").off("click.ub").on("click.ub",function(e){e.preventDefault();'
	.'var t=$.trim($("#ub_target").val()); if(!t){return;}'
	.'$(this).css({opacity:.5,"pointer-events":"none"});'   // анти-дубль: гасим кнопку после валидации
	.'ssAct("admin/ufw_block_list.php",{do:"add",target:t,comment:($("#ub_comment").val()||"")});});'
	.'});</script>';

// --- подсказки: подсети-кластеры из CrowdSec ---
$sug = $app->db->queryAllRecords("SELECT subnet, ip_count, sample, updated FROM ufw_block_suggest ORDER BY ip_count DESC");
if(is_array($sug) && !empty($sug)) {
	echo '<p class="fieldset-legend" style="margin-top:16px;">'.$h(_ubL('suggest_head_txt')).'</p>';
	echo '<p class="help-block">'.$h(_ubL('suggest_desc_txt')).'</p>';
	echo '<table class="table"><thead class="dark"><tr><th>'.$h(_ubL('subnet_txt')).'</th><th style="width:90px;">'.$h(_ubL('ipcount_txt')).'</th><th>'.$h(_ubL('sample_txt')).'</th><th style="width:130px;">'.$h(_ubL('action_txt')).'</th></tr></thead><tbody>';
	foreach($sug as $s) {
		echo '<tr><td><code>'.$h($s['subnet']).'</code></td><td><b>'.(int)$s['ip_count'].'</b></td>'
			.'<td><span class="help-block" style="display:inline">'.$h($s['sample']).'</span></td>'
			.'<td><a class="btn btn-warning btn-xs ss-ub-act" href="#" data-do="add" data-target="'.$h($s['subnet']).'" data-comment="'.$h('cluster '.$s['ip_count'].' IP (CrowdSec)').'">'.$h(_ubL('block_subnet_txt')).'</a></td></tr>';
	}
	echo '</tbody></table>';
}

// --- текущий блок-лист ---
$rows = $app->db->queryAllRecords("SELECT id, target, comment, active, applied, created FROM ufw_block ORDER BY created DESC");
if(!is_array($rows)) $rows = array();
// есть строки, ожидающие применения в ufw? (active=y, applied=n) → авто-обновление до «применено ✓»
$pending = false;
foreach($rows as $r) if($r['active'] === 'y' && $r['applied'] !== 'y') { $pending = true; break; }
echo '<p class="fieldset-legend" style="margin-top:16px;">'.$h(_ubL('blocklist_head_txt')).'</p>';
if(empty($rows)) {
	echo '<div class="alert alert-info">'.$h(_ubL('no_blocks_txt')).'</div>';
} else {
	echo '<table class="table"><thead class="dark"><tr>'
		.'<th>'.$h(_ubL('target_txt')).'</th><th>'.$h(_ubL('comment_txt')).'</th>'
		.'<th style="width:90px;">'.$h(_ubL('active_txt')).'</th><th style="width:110px;">'.$h(_ubL('applied_txt')).'</th>'
		.'<th>'.$h(_ubL('added_txt')).'</th><th style="width:170px;">'.$h(_ubL('action_txt')).'</th></tr></thead><tbody>';
	foreach($rows as $r) {
		$ap = ($r['applied'] === 'y')
			? '<span class="text-success">'.$h(_ubL('applied_yes_txt')).'</span>'
			: ($r['active'] === 'y' ? '<span class="text-warning">'.$h(_ubL('applied_pending_txt')).'</span>' : '<span class="help-block" style="display:inline">—</span>');
		$act = ($r['active'] === 'y') ? _ubL('disable_txt') : _ubL('enable_txt');
		echo '<tr>'
			.'<td><code>'.$h($r['target']).'</code></td>'
			.'<td>'.$h($r['comment']).'</td>'
			.'<td>'.($r['active'] === 'y' ? '<span class="text-success">'.$h(_ubL('yes_txt')).'</span>' : '<span class="help-block" style="display:inline">'.$h(_ubL('no_txt')).'</span>').'</td>'
			.'<td>'.$ap.'</td>'
			.'<td><span class="help-block" style="display:inline">'.$h($r['created']).'</span></td>'
			.'<td>'
			.'<a class="btn btn-default btn-xs ss-ub-act" href="#" data-do="toggle" data-id="'.(int)$r['id'].'">'.$h($act).'</a> '
			.'<a class="btn btn-default btn-xs ss-ub-act" href="#" data-do="del" data-id="'.(int)$r['id'].'" data-confirm="'.$h(_ubL('confirm_del_txt')).'">'.$h(_ubL('delete_txt')).'</a>'
			.'</td></tr>';
	}
	echo '</tbody></table>';
	echo '<p class="help-block">'.$h(_ubL('apply_hint_txt')).'</p>';
}
if($pending) echo '<p class="text-warning">⏳ <b>'.$h(_ubL('pending_apply_txt')).'</b></p>';
?>
<script type="text/javascript">
jQuery(function($){
	// анти-дубль: гасим кнопку-действие (подсказка/вкл-выкл/удалить) сразу на клике
	$(document).off('click.ublock').on('click.ublock','.ss-ub-act',function(e){
		e.preventDefault();
		var $b=$(this), p={do: $b.data('do')};
		if($b.data('id'))      p.id = $b.data('id');
		if($b.data('target'))  p.target = $b.data('target');
		if($b.data('comment')) p.comment = $b.data('comment');
		if(ssAct('admin/ufw_block_list.php', p, $b.data('confirm') || '')) $b.css({opacity:.5,'pointer-events':'none'});
	});
	// пока есть строки без «применено» — авто-обновляем до отметки «применено ✓» (reconcile ≤1 мин)
	<?php if($pending): ?>
	setTimeout(function(){ if(typeof loadContent==='function')loadContent('admin/ufw_block_list.php'); else if(typeof ISPConfig!=='undefined'&&ISPConfig.loadContent)ISPConfig.loadContent('admin/ufw_block_list.php'); }, 5000);
	<?php endif; ?>
});
</script>
<?php
