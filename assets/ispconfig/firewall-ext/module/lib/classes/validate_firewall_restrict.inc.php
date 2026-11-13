<?php
/*
  LuckyStack: CUSTOM-валидатор поля allowed_ips модуля Firewall IP-rules.
  Проверяет, что каждый элемент — корректный IPv4/IPv6 или CIDR. Если «Открыть всем»
  отмечено — поле игнорируется (не валидируем). Пусто допустимо (правило просто не действует).
  Кладётся в interface/lib/classes/ — оттуда $app->uses('validate_firewall_restrict') его берёт.
*/

class validate_firewall_restrict {

	function valid_ips($field_name, $field_value, $validator) {
		global $app;
		// «открыть всем» — список IP не используется
		if(isset($_POST['allow_all']) && $_POST['allow_all'] === 'y') return '';
		$val = trim((string)$field_value);
		if($val === '') return ''; // пусто разрешено (правило ничего не делает)
		foreach(preg_split('/[,\s]+/', $val) as $ip) {
			$ip = trim($ip);
			if($ip === '') continue;
			if(!$this->_ip_or_cidr($ip)) {
				$msg = isset($validator['errmsg']) ? $validator['errmsg'] : 'allowed_ips_error';
				if(isset($app->tform->wordbook[$msg])) $msg = $app->tform->wordbook[$msg];
				return $msg."<br>\r\n";
			}
		}
		return '';
	}

	// Список стран ISO-3166 alpha-2 (через запятую/пробел). Пусто допустимо.
	// Нужен только при geo_mode != off, но валидируем формат всегда (лишний мусор не пройдёт).
	function valid_countries($field_name, $field_value, $validator) {
		global $app;
		$val = trim((string)$field_value);
		if($val === '') return '';
		foreach(preg_split('/[,\s]+/', $val) as $cc) {
			$cc = trim($cc);
			if($cc === '') continue;
			if(!preg_match('/^[A-Za-z]{2}$/', $cc)) {
				$msg = isset($validator['errmsg']) ? $validator['errmsg'] : 'geo_countries_error';
				if(isset($app->tform->wordbook[$msg])) $msg = $app->tform->wordbook[$msg];
				return $msg."<br>\r\n";
			}
		}
		return '';
	}

	// Те же правила, что в серверном плагине: слишком широкие сети (IPv4 шире /8, IPv6 шире /16)
	// не принимаем, «открыть всем» — отдельная галочка, а не /0.
	function _ip_or_cidr($s) {
		if(strpos($s, '/') !== false) {
			$parts = explode('/', $s, 2);
			if(count($parts) !== 2 || !ctype_digit($parts[1])) return false;
			$m = (int)$parts[1];
			if(filter_var($parts[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return ($m >= 8 && $m <= 32);
			if(filter_var($parts[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) return ($m >= 16 && $m <= 128);
			return false;
		}
		return (bool)filter_var($s, FILTER_VALIDATE_IP);
	}
}

?>
