<?php
/*
  LuckyStack: общее для наших панелей ISPConfig.

  Действие, которое что-то меняет (бан, удаление, бэкап, установка пакета...), принимается
  только POST-запросом с одноразовым CSRF-токеном ISPConfig. Это тот же механизм, что у её
  собственных форм (csrf_token_get / csrf_token_check). Обычные GET-ссылки только показывают
  страницу, поэтому чужая ссылка или картинка на другом сайте больше ничего не сделает от
  имени залогиненного админа.

  Каждое принятое действие пишется в таблицу ss_panel_audit: когда, кто, с какого IP, что.

  Как пользоваться в странице:
    require_once '../../lib/ss_panel.inc.php';
    if(ss_is_action()) { $do = ss_post('do'); ... ss_audit('panel', $do, 'детали'); }
    echo ss_action_form('panel');                       // скрытая форма с токеном + JS
    JS: ssAct('admin/page.php', {do: 'ban', ip: ip}, 'Точно?');
*/

if(!function_exists('ss_is_action')) {

// Пришло ли действие. GET с do= больше ничего не меняет. Если токен неверный или устарел,
// csrf_token_check сам пишет предупреждение в лог ISPConfig и останавливает запрос.
function ss_is_action() {
	global $app;
	if(!isset($_SERVER['REQUEST_METHOD']) || $_SERVER['REQUEST_METHOD'] !== 'POST') return false;
	if(!isset($_POST['do']) || $_POST['do'] === '') return false;
	$app->auth->csrf_token_check('POST');
	return true;
}

// Параметр действия (только из POST).
function ss_post($k, $def = '') {
	return isset($_POST[$k]) ? trim((string)$_POST[$k]) : $def;
}

// Запись в журнал действий. Ошибка записи действие не ломает.
function ss_audit($panel, $action, $detail = '') {
	global $app;
	$user = isset($_SESSION['s']['user']['username']) ? (string)$_SESSION['s']['user']['username'] : '?';
	$ip   = isset($_SERVER['REMOTE_ADDR']) ? (string)$_SERVER['REMOTE_ADDR'] : '';
	$detail = (string)$detail;
	if(strlen($detail) > 500) $detail = substr($detail, 0, 500);
	@$app->db->query("INSERT INTO ss_panel_audit (created, username, ip, panel, action, detail) VALUES (NOW(), ?, ?, ?, ?, ?)",
		substr($user, 0, 64), substr($ip, 0, 45), substr((string)$panel, 0, 32), substr((string)$action, 0, 32), $detail);
}

// Скрытая форма с токеном (одна на страницу) + функция ssAct(). Токен одноразовый: после
// действия страница перерисовывается и получает новый.
function ss_action_form($panel) {
	global $app;
	$t = $app->auth->csrf_token_get('ss_'.preg_replace('/[^a-z0-9_]/', '', strtolower($panel)));
	$e = function($s) { return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8'); };
	return '<form id="ss_act_form" onsubmit="return false;" style="display:none">'
		.'<input type="hidden" name="_csrf_id" value="'.$e($t['csrf_id']).'">'
		.'<input type="hidden" name="_csrf_key" value="'.$e($t['csrf_key']).'">'
		.'</form>'
		.ss_action_js();
}

// ssAct(url, params, confirm): дописать параметры в скрытую форму и отправить POST через
// ISPConfig.submitForm. Ответ (перерисованная страница) встаёт на место контента.
function ss_action_js() {
	return '<script type="text/javascript">'
		.'window.ssAct=function(url,params,confirmMsg){'
		.'if(confirmMsg&&!window.confirm(confirmMsg))return false;'
		.'var $f=jQuery("#ss_act_form");if(!$f.length)return false;'
		.'$f.find("input.ss-p").remove();'
		.'jQuery.each(params||{},function(k,v){jQuery("<input type=\"hidden\" class=\"ss-p\">").attr("name",k).val(v==null?"":String(v)).appendTo($f);});'
		.'ISPConfig.submitForm("ss_act_form",url);return true;};'
		.'</script>';
}

}
