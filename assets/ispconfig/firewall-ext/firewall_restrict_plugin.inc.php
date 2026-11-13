<?php
/*
  LuckyStack: единый firewall ISPConfig — модуль «Firewall IP-rules».

  Заменяет встроенный firewall ISPConfig (тот умеет только «открыть всем»). Дружелюбный
  модуль (таблица firewall_restrict, отдельные поля: сервер/протокол/порт/IP/описание/
  «открыть всем»/rate-limit/гео/вкл) задаёт на КАЖДЫЙ порт одно из двух:
    - allow_all='y' → публичный порт, открыт ВСЕМ (ACCEPT, без DROP);
    - allow_all='n' → открыт ТОЛЬКО перечисленным IP (ACCEPT + DROP остальным).
  port — число или диапазон A:B (напр. 40110:40210, passive FTP).

  Дополнительно на каждое правило:
    - rate_limit='y' → ограничение частоты новых соединений с одного IP (hashlimit);
    - geo_mode='block' → DROP трафика из указанных стран (поверх обычной логики);
    - geo_mode='allow' → порт открыт ТОЛЬКО указанным странам (белый список; IP/allow_all
      игнорируются). Диапазоны стран — ipset'ы ss_geo_<cc>/ss_geo6_<cc>, наполняются из
      /etc/ss-firewall/geoip/<cc>.zone (ipdeny.com) скриптом ss-firewall-geo-refresh и
      пересобираются в ipset через хук /etc/ufw/before.init на старте/reload ufw.

  Плагин по событию модуля ПЕРЕСОБИРАЕТ единый блок в /etc/ufw/before.rules
  (chain ufw-before-input, ДО user-правил): публичные порты, IP-ограничения, rate-limit, гео.
  before.rules переживает и ufw reload, и обновления ISPConfig. Родной firewall ISPConfig
  установщик гасит (active=n в БД, его user.rules вычищаются), чтобы движок был один.

  ОТДЕЛЬНЫЙ (не core) плагин — переживает обновления ISPConfig.
*/

class firewall_restrict_plugin {

	var $plugin_name = 'firewall_restrict_plugin';
	var $class_name  = 'firewall_restrict_plugin';

	var $geo_dir = '/etc/ss-firewall/geoip';

	function onInstall() {
		return false;
	}

	function onLoad() {
		global $app;
		// отдельные правила (модуль Firewall IP-rules)
		$app->plugins->registerEvent('firewall_restrict_insert', $this->plugin_name, 'rebuild');
		$app->plugins->registerEvent('firewall_restrict_update', $this->plugin_name, 'rebuild');
		$app->plugins->registerEvent('firewall_restrict_delete', $this->plugin_name, 'rebuild');
		// базы с галочкой Remote access: порт 3306 следует за ними (см. remote_db_rule)
		$app->plugins->registerEvent('database_insert', $this->plugin_name, 'rebuild');
		$app->plugins->registerEvent('database_update', $this->plugin_name, 'rebuild');
		$app->plugins->registerEvent('database_delete', $this->plugin_name, 'rebuild');
	}

	// Галочка Remote access у базы: ISPConfig выдаёт пользователю базы доступ с указанных IP, а если
	// список пуст — с любого ('%'). Чтобы галочка реально работала, порт 3306 открываем тем же IP:
	// дописываем их к правилу 3306 из панели (или создаём такое правило, если его нет). Пустой список
	// хоть у одной базы = 3306 открыт всем, в лог пишется предупреждение.
	function remote_db_rule(&$rows) {
		global $app, $conf;
		$dbs = $app->db->queryAllRecords("SELECT database_name, remote_ips FROM web_database WHERE server_id = ? AND active = 'y' AND remote_access = 'y'", $conf['server_id']);
		if(!is_array($dbs) || empty($dbs)) return;
		$ips = array(); $open_all = array();
		foreach($dbs as $d) {
			$list = $this->parse_ips($d['remote_ips']);
			if(trim((string)$d['remote_ips']) === '') $open_all[] = $d['database_name'];
			foreach($list as $ip) $ips[$ip] = true;
		}
		if($open_all && method_exists($app, 'log'))
			$app->log('firewall_restrict_plugin: у баз '.implode(', ', array_slice($open_all, 0, 5)).' включён Remote access без списка IP — порт 3306 открыт всем. Укажите IP в настройках базы.', LOGLEVEL_WARN);
		$found = false;
		foreach($rows as $k => $r) {
			if($r['proto'] !== 'tcp' || (string)$r['port'] !== '3306') continue;
			$found = true;
			if($open_all) $rows[$k]['allow_all'] = 'y';
			else $rows[$k]['allowed_ips'] = trim($r['allowed_ips'].' '.implode(' ', array_keys($ips)));
		}
		if(!$found) $rows[] = array('restrict_id' => 0, 'proto' => 'tcp', 'port' => '3306', 'allowed_ips' => implode(' ', array_keys($ips)),
			'description' => 'MySQL — базы с Remote access', 'allow_all' => $open_all ? 'y' : 'n', 'rate_limit' => 'n', 'geo_mode' => 'off', 'geo_countries' => '');
	}

	// Пересобрать блок before.rules из таблицы firewall_restrict
	function rebuild($event_name, $data) {
		global $app, $conf;

		$server_config = $app->getconf->get_server_config($conf['server_id'], 'server');
		if(isset($server_config['firewall']) && $server_config['firewall'] != 'ufw') return;
		if(!$app->system->is_installed('ufw')) return;

		$rows = $app->db->queryAllRecords("SELECT restrict_id, proto, port, allowed_ips, description, allow_all, rate_limit, geo_mode, geo_countries FROM firewall_restrict WHERE server_id = ? AND active = 'y'", $conf['server_id']);
		if(!is_array($rows)) $rows = array();
		$this->remote_db_rule($rows);

		// 1) собрать множество стран, нужных активным гео-правилам, и докачать недостающие зоны
		$want_cc = array();
		foreach($rows as $r) {
			if(isset($r['geo_mode']) && $r['geo_mode'] !== 'off' && $r['geo_mode'] !== '') {
				foreach($this->parse_cc($r['geo_countries']) as $cc) $want_cc[$cc] = true;
			}
		}
		$this->sync_geo(array_keys($want_cc));

		// 2) подготовить правила (с учётом доступных гео-зон) для обоих семейств
		$rules = array();
		foreach($rows as $r) {
			if(!$this->valid_port($r['port'])) {
				if(method_exists($app, 'log')) $app->log('firewall_restrict_plugin: правило #'.intval($r['restrict_id']).' пропущено, некорректный порт.', LOGLEVEL_WARN);
				continue;
			}
			$proto = ($r['proto'] === 'udp') ? 'udp' : 'tcp';
			$all   = (isset($r['allow_all']) && $r['allow_all'] === 'y');
			$ips   = $this->parse_ips($r['allowed_ips']);
			$geo_mode = isset($r['geo_mode']) ? $r['geo_mode'] : 'off';
			$cc       = ($geo_mode !== 'off') ? $this->parse_cc($r['geo_countries']) : array();
			// gео=allow без единого IP-ограничения и без публичности — это и есть белый список;
			// gео=block — наложение поверх обычной логики (нужны IP/all, чтобы было что фильтровать).
			if($geo_mode === 'off' && !$all && !$ips) continue; // ограниченное правило без IP — ничего не делает
			$rules[] = array(
				'id'    => intval($r['restrict_id']),
				'proto' => $proto,
				'port'  => $r['port'],
				'all'   => $all,
				'ips'   => $ips,
				'rate'  => (isset($r['rate_limit']) && $r['rate_limit'] === 'y'),
				'geo'   => $geo_mode,
				'cc'    => $cc,
				'desc'  => $this->clean($r['description'])
			);
		}

		$this->write_file('/etc/ufw/before.rules',  'ufw-before-input',  4, $rules);
		if(file_exists('/etc/ufw/before6.rules'))
			$this->write_file('/etc/ufw/before6.rules', 'ufw6-before-input', 6, $rules);

		if(method_exists($app, 'log')) $app->log('firewall_restrict_plugin: правила firewall пересобраны (before.rules).', LOGLEVEL_DEBUG);

		// Применить в ядро. Если ufw активен — reload. Если ВЫКЛЮЧЕН — `ufw reload` молча
		// пропускается («Firewall not enabled»), и правило НЕ применяется. Раз ufw — движок
		// firewall (иначе мы бы сюда не дошли, см. проверку выше), а он выключен, то не работает
		// ВЕСЬ порт-firewall. Правильное действие — включить ufw: before.rules уже содержит
		// SSH-allow (base-блок + SSH-правила панели), поэтому включение безопасно (анти-локаут).
		$ust = array(); $ufw_active = false;
		exec('ufw status 2>/dev/null', $ust);
		foreach($ust as $l) { if(stripos($l, 'Status: active') !== false) { $ufw_active = true; break; } }
		// «ufw status» пишет active и при ENABLED=no (правила остались в ядре), но reload тогда молча пропускается
		if($ufw_active && !preg_match('/^ENABLED=yes/m', (string)@file_get_contents('/etc/ufw/ufw.conf'))) $ufw_active = false;

		if(!$ufw_active) {
			// Страховка от лок-аута: включаем ТОЛЬКО если в before.rules есть SSH-allow
			// (правило ACCEPT c источником на порт SSH) ИЛИ SSH нигде не дропается. Иначе — не рискуем.
			$br = @file_get_contents('/etc/ufw/before.rules');
			$ssh_safe = ($br === false)
				|| (bool)preg_match('/--dport \d+ -s \S+ -j ACCEPT/', $br)   // есть whitelisted-IP (SSH/панель)
				|| (strpos($br, '-j DROP') === false);                       // вообще нет DROP → всё открыто
			if($ssh_safe) {
				exec('ufw --force enable 2>/dev/null');
				$ust = array(); $ufw_active = false;
				exec('ufw status 2>/dev/null', $ust);
				foreach($ust as $l) { if(stripos($l, 'Status: active') !== false) { $ufw_active = true; break; } }
				if($ufw_active && method_exists($app, 'log'))
					$app->log('firewall_restrict_plugin: ufw был выключен — включил его, чтобы правила применились.', LOGLEVEL_WARN);
			} elseif(method_exists($app, 'log')) {
				$app->log('firewall_restrict_plugin: ufw выключен, а в before.rules нет SSH-allow — НЕ включаю во избежание лок-аута. Проверьте SSH-правила и включите ufw вручную.', LOGLEVEL_WARN);
			}
		}

		if($ufw_active) {
			exec('ufw reload 2>/dev/null');
			// before.rules теперь отражает ТЕКУЩЕЕ состояние ВСЕХ правил сервера: активные —
			// в блоке, выключенные — корректно отсутствуют. Значит применены и те, и другие.
			// Метим applied у всех (иначе выключенное правило навсегда зависает в ⏳ «ожидает»,
			// т.к. по нему больше не пройдёт active='y'-апдейт).
			$app->db->query("UPDATE firewall_restrict SET applied = NOW() WHERE server_id = ?", $conf['server_id']);
		} else {
			// не удалось поднять ufw — честно НЕ помечаем applied у активных (панель покажет
			// «ожидает»); выключенные не трогаем — им нечего применять.
			$app->db->query("UPDATE firewall_restrict SET applied = NULL WHERE server_id = ? AND active = 'y'", $conf['server_id']);
			if(method_exists($app, 'log')) $app->log('firewall_restrict_plugin: ufw не активен — правила записаны, но НЕ применены (ufw enable вручную).', LOGLEVEL_WARN);
		}
	}

	// --- гео: список стран → зоны на диске → ipset'ы (через before.init) ------------------
	// Записывает countries.list, докачивает недостающие зоны скриптом, (пере)создаёт before.init
	// и сразу строит ipset'ы, чтобы before.rules мог на них ссылаться при ufw reload.
	function sync_geo($cc_list) {
		$cc_list = array_values(array_unique(array_filter(array_map(array($this, 'norm_cc'), $cc_list))));
		@mkdir($this->geo_dir, 0755, true);

		$this->write_before_init();

		// всегда переписываем список нужных стран (пусто → еженедельный refresh уберёт лишние зоны)
		@file_put_contents($this->geo_dir.'/countries.list', $cc_list ? (implode("\n", $cc_list)."\n") : '');

		if(empty($cc_list)) {
			// гео-правил нет — просто пересоберём (возможно пустые) наборы и выйдем
			if(is_executable('/etc/ufw/before.init')) exec('/etc/ufw/before.init flush-on-reload 2>/dev/null');
			return;
		}

		// нужно ли качать? если хотя бы для одной страны нет v4-зоны — запустить refresh (best-effort)
		$need = false;
		foreach($cc_list as $cc) { if(!is_file($this->geo_dir.'/'.$cc.'.zone')) { $need = true; break; } }
		if($need && is_executable('/usr/local/sbin/ss-firewall-geo-refresh'))
			exec('/usr/local/sbin/ss-firewall-geo-refresh >/dev/null 2>&1');

		// построить ipset'ы из имеющихся зон сейчас (before.rules будет на них ссылаться)
		if(is_executable('/etc/ufw/before.init')) exec('/etc/ufw/before.init flush-on-reload 2>/dev/null');

		// предупредить, если для какой-то страны зона так и не появилась (нет сети/ipdeny недоступен):
		// для geo=allow такое правило применено не будет (fail-closed), для geo=block — просто без этой страны.
		global $app;
		$missing = array();
		foreach($cc_list as $cc) { if(!is_file($this->geo_dir.'/'.$cc.'.zone')) $missing[] = $cc; }
		if($missing && method_exists($app, 'log'))
			$app->log('firewall_restrict_plugin: нет гео-зон для: '.implode(',', $missing).' (ipdeny недоступен?). geo=allow-правила этих стран не применятся.', LOGLEVEL_WARN);
	}

	// Доступна ли гео-зона страны для семейства (v4/v6) — есть непустой файл зоны
	function geo_available($cc, $fam) {
		$f = $this->geo_dir.'/'.$cc.($fam == 6 ? '6' : '').'.zone';
		return (is_file($f) && filesize($f) > 0);
	}

	function geo_set($cc, $fam) {
		return ($fam == 6 ? 'ss_geo6_' : 'ss_geo_').$cc;
	}

	// Хук ufw: на старте/перезагрузке firewall (пере)создаёт ipset'ы из файлов зон.
	function write_before_init() {
		$f = '/etc/ufw/before.init';
		$sh = "#!/bin/sh\n".
			"# luckystack: гео-ipset'ы для firewall_restrict. Управляется ISPConfig-плагином, не редактируйте.\n".
			"GEODIR=".$this->geo_dir."\n".
			"case \"\$1\" in\n".
			"  start|flush-on-reload)\n".
			"    command -v ipset >/dev/null 2>&1 || exit 0\n".
			"    [ -d \"\$GEODIR\" ] || exit 0\n".
			"    for f in \"\$GEODIR\"/*.zone; do\n".
			"      [ -f \"\$f\" ] || continue\n".
			"      base=\$(basename \"\$f\" .zone)\n".
			"      case \"\$base\" in\n".
			"        *6) fam=inet6; set=\"ss_geo6_\${base%6}\" ;;\n".
			"        *)  fam=inet;  set=\"ss_geo_\${base}\" ;;\n".
			"      esac\n".
			"      ipset create \"\$set\" hash:net family \$fam -exist 2>/dev/null\n".
			"      ipset flush \"\$set\" 2>/dev/null\n".
			"      while IFS= read -r net; do\n".
			"        [ -n \"\$net\" ] || continue\n".
			"        case \"\$net\" in \\#*) continue ;; esac\n".
			"        ipset add \"\$set\" \"\$net\" -exist 2>/dev/null\n".
			"      done < \"\$f\"\n".
			"    done\n".
			"    ;;\n".
			"esac\n".
			"exit 0\n";
		$cur = @file_get_contents($f);
		if($cur !== $sh) { @file_put_contents($f, $sh); }
		@chmod($f, 0755);
	}

	// Список IP из строки (запятая/пробел/перевод строки). Каждый элемент проверяем и здесь, а не
	// только в форме: запись могла прийти мимо формы (Remote API, правка БД). Мусор в `-s` уронил
	// бы iptables-restore на всём файле, и не загрузились бы вообще все наши правила.
	function parse_ips($s) {
		global $app;
		$out = array();
		foreach(preg_split('/[,\s]+/', (string)$s) as $ip) {
			$ip = trim($ip);
			if($ip === '') continue;
			if($this->valid_ip_or_cidr($ip)) $out[] = $ip;
			elseif(method_exists($app, 'log')) $app->log('firewall_restrict_plugin: пропущен некорректный IP/подсеть «'.substr($this->clean($ip), 0, 60).'».', LOGLEVEL_WARN);
		}
		return $out;
	}

	// IPv4/IPv6 или подсеть. Слишком широкие сети не принимаем (IPv4 шире /8, IPv6 шире /16):
	// «открыть всем» делается отдельной галочкой allow_all, а не /0.
	function valid_ip_or_cidr($s) {
		if(strpos($s, '/') === false) return (bool)filter_var($s, FILTER_VALIDATE_IP);
		$p = explode('/', $s, 2);
		if(!ctype_digit($p[1])) return false;
		$m = (int)$p[1];
		if(filter_var($p[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return ($m >= 8 && $m <= 32);
		if(filter_var($p[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) return ($m >= 16 && $m <= 128);
		return false;
	}

	// Порт или диапазон A:B в пределах 1..65535 (A <= B).
	function valid_port($s) {
		if(!preg_match('/^(\d{1,5})(?::(\d{1,5}))?$/', (string)$s, $m)) return false;
		$a = (int)$m[1]; $b = isset($m[2]) && $m[2] !== '' ? (int)$m[2] : $a;
		return $a >= 1 && $b <= 65535 && $a <= $b;
	}

	// Список кодов стран (нормализованных) из строки
	function parse_cc($s) {
		$out = array();
		foreach(preg_split('/[,\s]+/', (string)$s) as $cc) { $cc = $this->norm_cc($cc); if($cc !== '') $out[] = $cc; }
		return array_values(array_unique($out));
	}
	function norm_cc($s) {
		$s = strtolower(trim((string)$s));
		return preg_match('/^[a-z]{2}$/', $s) ? $s : '';
	}

	function clean($s) {
		return trim(preg_replace('/[\r\n]+/', ' ', (string)$s));
	}

	// hashlimit-имя ≤15 символов, уникальное на правило
	function rl_name($id) { return 'ssr'.intval($id); }

	function write_file($file, $chain, $fam, $rules) {
		if(!is_writable($file) && !is_writable(dirname($file))) return;
		$content = @file_get_contents($file);
		if($content === false) return;

		$start = '# luckystack: restrict-isp START';
		$end   = '# luckystack: restrict-isp END';

		// убрать прежний блок
		$content = preg_replace('/^'.preg_quote($start, '/').'.*?'.preg_quote($end, '/').'\n?/ms', '', $content);

		// нет правил — оставляем before.rules без нашего блока
		if(empty($rules)) { @file_put_contents($file, $content); return; }

		$body = '';
		foreach($rules as $r) {
			$pp   = "-p {$r['proto']} --dport {$r['port']}";
			$lines = '';

			// --- гео: список доступных стран для этого семейства ---
			$geo_sets = array();
			if($r['geo'] !== 'off') {
				foreach($r['cc'] as $cc) { if($this->geo_available($cc, $fam)) $geo_sets[] = $this->geo_set($cc, $fam); }
			}

			// rate-limit: дропать source свыше порога (established уже принят выше в цепочке)
			$rl = '';
			if($r['rate']) {
				$nm = $this->rl_name($r['id']);
				$rl = "-A $chain $pp -m hashlimit --hashlimit-name $nm --hashlimit-above 30/min --hashlimit-burst 60 --hashlimit-mode srcip -j DROP\n";
			}

			if($r['geo'] === 'allow') {
				// белый список стран: открыть порт ТОЛЬКО из этих стран (IP/all игнорируются).
				// если для семейства нет ни одной доступной зоны — НЕ трогаем (иначе заперли бы всех).
				if(empty($geo_sets)) continue;
				$lines .= $rl;
				foreach($geo_sets as $set)
					$lines .= "-A $chain $pp -m set --match-set $set src -j ACCEPT\n";
				$lines .= "-A $chain $pp -j DROP\n";
			} else {
				// geo=block: сперва DROP из указанных стран, затем обычная логика
				if($r['geo'] === 'block') {
					foreach($geo_sets as $set)
						$lines .= "-A $chain $pp -m set --match-set $set src -j DROP\n";
				}
				if($r['all']) {
					// публичный порт — открыть всем (с учётом rate-limit)
					$lines .= $rl;
					$lines .= "-A $chain $pp -j ACCEPT\n";
				} else {
					$fips = array();
					foreach($r['ips'] as $ip) {
						$is6 = (strpos($ip, ':') !== false);
						if(($fam == 6) === $is6) $fips[] = $ip;
					}
					if(!$fips && $r['geo'] !== 'block') continue; // нет IP нужного семейства и нет гео-DROP — это правило для другого файла
					if($fips) {
						$lines .= $rl;
						foreach($fips as $ip)
							$lines .= "-A $chain $pp -s $ip -j ACCEPT\n";
						$lines .= "-A $chain $pp -j DROP\n";
					}
				}
			}

			if($lines === '') continue;
			if($r['desc'] !== '') $body .= "# ".$r['desc']."\n";
			$body .= $lines;
		}

		// после фильтра по семейству могло не остаться ни одной строки
		if($body === '') { @file_put_contents($file, $content); return; }

		$block = $start."\n# Правила firewall (ISPConfig Firewall IP-rules). Правит плагин, не редактируйте.\n".$body.$end."\n";

		if(strpos($content, 'COMMIT') !== false)
			$content = preg_replace('/^COMMIT/m', $block.'COMMIT', $content, 1);
		@file_put_contents($file, $content);
	}
}

?>
