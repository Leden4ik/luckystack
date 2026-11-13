# LuckyStack — техническая документация

Установщик и обслуживание сервера хостинга: nginx (сборка из исходников) + многоверсионный
PHP-FPM + MariaDB + Postfix/Dovecot + Rspamd/ClamAV + BIND + PureFTPd + Let's Encrypt +
firewall + Roundcube + ISPConfig. Движок — `server-setup.sh`, на сервере им управляет команда
`luckyctl` (раскладку см. ниже). Пользовательская документация: https://luckystack.luckyman.name

Свои файлы в системе установщик называет с `luckystack` (`90-luckystack-hardening.conf`,
`00-luckystack.conf` и т.п.), а вставки в чужие конфиги помечает строкой `# luckystack: <что>`.
По этим пометкам он находит свои вставки и не дублирует их, поэтому руками их не трогать.
Копии оригиналов перед правкой лежат рядом с суффиксом `.luckystack.bak`.

> Это **живая** документация — обновляется по мере добавления функций и изменений.
> Последнее обновление: 2026-11-09.

---

## Содержание
1. [Поддерживаемые ОС](#поддерживаемые-ос)
2. [Быстрый старт (чистый сервер)](#быстрый-старт)
3. [Раскладка на сервере и luckyctl](#раскладка-на-сервере-и-luckyctl)
4. [Все команды и флаги](#все-команды-и-флаги)
5. [Этапы установки](#этапы-установки)
6. [`--only` — применить один этап](#only)
7. [Режим обновления `--update`](#режим-обновления)
8. [Предохранитель для уже настроенного сервера](#предохранитель)
9. [Бэкапы и восстановление](#бэкапы-и-восстановление)
10. [Сертификаты (как устроено)](#сертификаты)
11. [Типовые сценарии сопровождения](#сценарии)
12. [Конфигурация (setup.conf)](#конфигурация)
13. [Удаление](#удаление)
14. [Заметки/особенности](#заметки)

---

## Поддерживаемые ОС
Debian 11/12/13, Ubuntu 22.04/24.04. Debian 12/13 — основные (полностью оттестированы);
Debian 11 — экспериментально. Запуск — от **root**.

---

## Быстрый старт
```bash
cd server-installer
sudo bash server-setup.sh
```
Откроется **главное меню** → «Установить / настроить сервер» → пошаговый мастер → установка.
На чистом сервере установщик сначала ставит себя в `/opt/luckystack` и перезапускается оттуда.
Ответы сохраняются в `/etc/luckystack/setup.conf`, прогресс в `/var/lib/luckystack/setup.state`,
журнал в `/var/log/luckystack/setup.log`. Дальше сервер обслуживается командой `luckyctl`.

---

## Раскладка на сервере и luckyctl

```
/opt/luckystack/releases/<версия>-<время>   код, каждый выпуск отдельно (хранятся 3 последних)
/opt/luckystack/current                     ссылка на рабочий выпуск
/etc/luckystack/setup.conf                  настройки и пароли (каталог 700, файл 600)
/var/lib/luckystack/setup.state             отметки пройденных этапов
/var/log/luckystack/setup.log               журнал (600)
/usr/local/sbin/luckyctl                    команда, ссылка на current/luckyctl
```

Код должен работать из `/opt/luckystack` (`lib/layout.sh`). Копия, запущенная из другого каталога,
отказывается работать и подсказывает `--install-code`. Исключения: `--dry-run`, `LS_ALLOW_FOREIGN=1`
и чистый сервер, где кода в `/opt` ещё нет: полная установка ставит код туда и перезапускается
(`exec` с теми же аргументами), а режимы вроде `--status` работают прямо на месте.
Каталоги можно переопределить переменными `LS_OPT_DIR`, `LS_ETC_DIR`, `LS_VAR_DIR`, `LS_LOG_DIR`,
`LS_BIN` (так проверялся сценарий чистого сервера на рабочем тестовом).

**Версии и выпуски.** Версия одна, `VERSION` в `server-setup.sh`, вида `0.1.0`: последняя цифра
растёт с исправлениями, средняя с новыми возможностями. Каждая версия выходит релизом на GitHub
с тегом `v0.1.0`, список изменений лежит в `CHANGELOG.md` и в описании релиза. Выпуск на сервере
называется по версии (`releases/0.1.0`, если такой уже есть, к имени добавляется время), внутри
лежит `.release`: версия, откуда взят код и когда поставлен. Версия пишется и в начало каждого
запуска в журнале.

**Новый выпуск из локальной копии**: `./server-setup.sh --install-code` из распакованного каталога
ставит его выпуском, переключает `current`, обновляет скрипт панели. Вернуть прошлый выпуск:
`--rollback luckystack` (повтор возвращает обратно).

**Обновление LuckyStack** (`lib/selfupdate.sh`). `luckyctl version` (`--check-update`) показывает,
что стоит и откуда, спрашивает у API GitHub последний релиз и, если он новее (сравнение `sort -V`),
печатает его список изменений. `luckyctl self-update` (`--self-update`) скачивает архив этого тега,
проверяет, что версия внутри совпадает с тегом, и ставит его выпуском; повтор той же версии только
с `--force`. Ветка `main` к пользователям не попадает, пока не выпущена релизом. Переменные:
`SELF_UPDATE_REPO` (по умолчанию `Leden4ik/luckystack`), `SELF_UPDATE_REF` (поставить конкретный
тег или ветку), `SELF_UPDATE_API` (адрес API, для проверок), `GITHUB_TOKEN` (приватный форк).
После обновления самого LuckyStack настройки сервера не меняются, новое применяет `luckyctl update`.

**Панель обслуживания** читает пути из `/usr/local/ispconfig/server/scripts/ss-maint.conf`
(`INSTALLER_DIR`, `SETUP_CONF`, `SETUP_LOG`).
Проверка доверия смотрит и путь по ссылке, и настоящий каталог выпуска, и каталог настроек.

**luckyctl** (`luckyctl help`) переводит подкоманды в ключи `server-setup.sh`:

| Команда | Ключ |
|---|---|
| `luckyctl` без команды | главное меню (нужен терминал; без него печатает справку). Действия, которые меняют сервер, идут отдельным процессом, после них итог и возврат в меню; Ctrl+C прерывает только действие |
| `install [--resume\|--only Э\|--from Э\|--unattended\|--reconfigure\|--force\|--dry-run]` | без ключа |
| `status`, `check`, `diagnostics`, `restore`, `adopt`, `uninstall`, `remove-php`, `self-update` | `--status`, `--healthcheck`, `--diagnostics`, … |
| `update [пункты] [--dry-run]` | `--update`, пункты уходят в `UPDATE_ITEMS` (без вопросов) |
| `rollback nginx\|roundcube\|luckystack` | `--rollback X` |
| `add-php [X.Y]`, `timezone [пояс]` | `--add-php`, `--timezone` |
| `backup`, `backup list` | `/usr/local/sbin/server-backup.sh [--list]` |
| `log [N]`, `paths`, `version` | хвост журнала, где что лежит, версия и `--check-update` |

Подсказки в выводе установщика (`ls_hint`) пишут команды `luckyctl`.

---

## Все команды и флаги

| Флаг | Назначение |
|---|---|
| (без флагов) | Главное меню (установка / проверки / обновление / восстановление) |
| `--resume` | Продолжить прерванную установку с первого незавершённого этапа |
| `--reconfigure` | Заново пройти мастер (перезаписать `setup.conf`) |
| `--unattended` | Без вопросов: использовать готовый `setup.conf` |
| `--from <этап>` | Начать с указанного этапа и идти до конца |
| `--only <этап>` | Выполнить РОВНО один этап и выйти (см. ниже) |
| `--update` | Режим обновления/патчей: обновить пакеты + переприменить аддитивные улучшения, ядро — по запросу |
| `--add-php [X.Y]` | Доустановить версию PHP на работающий сервер (выбор из списка или версия аргументом) и выйти; есть пункт меню. `run_php_add` (lib/php.sh): как этап PHP (FPM + модули, пул, OPcache, сниппет), затем часовой пояс, `98-luckystack-security.ini`, добавление в `PHP_VERSIONS` (иначе `_php_drop_stray` счёл бы её лишней), регистрация в ISPConfig (`server_php`). Проверено на 8.5 |
| `--remove-php` | Удалить ВЫБРАННЫЕ версии PHP (интерактивный checklist или пункт меню). `run_php_remove` (lib/php.sh): apt purge `phpX.Y-*` + останов/выкл fpm + `/etc/php/X.Y` + запись в `server_php` (выпадашка «PHP Version» у сайтов). **Защита:** не даёт снести версию, на которой работает панель ISPConfig, системный CLI-дефолт (`/usr/bin/php`), и версии, используемые сайтами (`web_domain.fastcgi_php_version`) — они показываются как «оставляем». E2E: 8.2(панель)/8.3(CLI) защищены, 7.4/8.0/8.1/8.4/8.5 — удаляемы |
| `--adopt` | Подключить наши аддоны к СТОРОННЕ установленному серверу (вручную/по гайду): обяз. бэкап (или ручное подтверждение) + повторное подтверждение `APPLY`, только server-agnostic; ядро/сборку nginx/шаблоны и БД ISPConfig НЕ трогает |
| `--timezone [пояс]` | Сменить часовой пояс везде и выйти: система (`timedatectl` + `/etc/timezone`), `date.timezone` во всех версиях PHP (FPM, CLI, CGI; файл `99-luckystack-timezone.ini`), перезапуск cron/rsyslog, reload nginx/Apache, перезапуск MariaDB (берёт пояс системы), `TIMEZONE` в setup.conf. Без пояса спрашивает. Есть пункт в главном меню. `run_timezone_mode` / `apply_timezone_everywhere` (lib/preflight.sh) |
| `--status` | Что установлено и какие версии (+ доступные обновления) — и выйти |
| `--healthcheck` | Проверка здоровья (сервисы/порты/TLS/панель/диск) — и выйти |
| `--diagnostics` | Собрать обезличенный архив `/root/server-diagnostics-<ts>.tar.gz` (система/конфиг-без-паролей/хвост лога/статус служб/configtest/порты/firewall/ошибки журнала/healthcheck/версии) для поддержки — и выйти |
| `--restore` | Восстановление из резервной копии (интерактивно) |
| `--dry-run` | Демо-режим: этапы только имитируются, изменений нет |
| `--force` | Выполнять заново даже уже завершённые этапы |
| `--uninstall` | Режим удаления компонентов (полное/частичное) |
| `--purge` | Удаление вместе с ДАННЫМИ (БД/почта/сайты) — НЕОБРАТИМО |
| `--clean-build` | Очистить кеш сборки (исходники nginx/ISPConfig прошлых попыток) |
| `--lang <код>` | Язык интерфейса CLI (`ru` по умолч.; `en` — частичный перевод). См. ниже |
| `--install-code` | Поставить эту копию кода новым выпуском в `/opt/luckystack` |
| `--help` | Справка |

Read-only и безопасные команды (можно гонять в любой момент): `--status`, `--healthcheck`,
`--dry-run`, `--restore`, `--update`.

### Язык интерфейса (каркас i18n)
`lib/i18n.sh` — механизм `t()` по модели gettext: **ключ перевода = сама исходная русская
строка**, перевод берётся из `lang/<код>.lng`, а если файла/ключа нет — показывается русский
оригинал. Поэтому строки оборачиваются `t()` **постепенно**, ничего не ломая (непереведённое
остаётся русским; русский — исходный язык, `ru.lng` не нужен). Выбор языка (по приоритету):
флаг `--lang` → `UI_LANG` в `setup.conf` → умолчание `ru`. **При ПЕРВОМ интерактивном запуске**
(`_ensure_language`, до всех режимов) показывается меню «Выберите язык / Choose language» и выбор
**сохраняется в `setup.conf`** — повторно не спрашивает; `--lang <код>` перекрывает без вопроса; в
`--unattended`/не-tty молча `ru`. `$LANG` окружения НЕ используется (у VDS часто `en_US.UTF-8`). Добавить язык = положить `lang/<код>.lng` со строками
`_I18N["<русский оригинал>"]="<перевод>"`. Сейчас `lang/en.lng` покрывает блоки мастера
анти-malware и «Панели-расширения» (демо каркаса); остальной CLI дополняется по мере надобности.
Веб-панели ISPConfig двуязычны независимо (свои `*_*.lng`).

---

## Этапы установки

`core` — выполняются всегда в полном прогоне (нельзя снять галочкой). `opt` — опциональные
(чеклист в мастере). Колонка «повтор» — безопасно ли перезапускать на рабочем сервере.

| # | Этап (`--only` ключ) | Тип | Что делает | Повтор |
|---|---|---|---|---|
| 1 | `preflight` | core | hostname, время, /etc/hosts, базовые пакеты | ⚠ меняет hostname |
| 2 | `database` | core | MariaDB (+ Redis); **adopt-safe** — не сбрасывает существующий root-пароль | ⚠ |
| 3 | `webserver` (`nginx`) | core | nginx из исходников / Apache; перезапишет nginx.conf | ⚠ пересборка |
| 4 | `php` | core | многоверсионный PHP-FPM (Sury/ppa) | ~идемпотентно |
| 5 | `nodejs` | opt | Node.js (NodeSource) | ✓ |
| 6 | `phpmyadmin` | opt | веб-админка БД (phpMyAdmin / Adminer) | ✓ |
| 7 | `postgresql` | opt | PostgreSQL + pgAdmin/Adminer | ✓ |
| 8 | `mail` | opt | Postfix + Dovecot | ⚠ конфиги |
| 9 | `rspamd` | opt | Rspamd + ClamAV | ✓ |
| 10 | `dns` | opt | BIND9 | ⚠ конфиги |
| 11 | `ftp` | opt | PureFTPd + квоты | ⚠ конфиги |
| 12 | `ssl` | core | ACME-клиент (acme.sh/certbot) для LE | ✓ |
| 13 | `security` | opt | fail2ban, firewall (UFW/CrowdSec), Lynis, sysctl-харденинг, автообновления, world-writable | ⚠ firewall/SSH |
| 14 | `monit` | opt | Monit | ✓ |
| 15 | `webmail` | opt | RoundCube + статистика | ⚠ |
| 16 | `ispconfig` | core | панель ISPConfig | ⚠ переустановка |
| 17 | `hostcert` | opt | реальный LE-серт для FQDN (панель + почта) | ✓ |
| 18 | `rcplugins` | opt | плагины ISPConfig для Roundcube + remote API user | ✓ |
| 19 | `maildeliver` | opt | TLS-харденинг Postfix + DNS-записи (SPF/DMARC/MTA-STS) | ✓ |
| 20 | `mailsni` | opt | per-domain TLS почты (SNI из Let's Encrypt) | ✓ |
| 21 | `tuning` | opt | авто-тюнинг MariaDB/PHP/Postfix под RAM/CPU | ✓ |
| 22 | `backup` | opt | резервное копирование (БД + конфиги) по таймеру | ✓ |
| 23 | `malware` | opt | анти-malware: rkhunter + LMD + ежедневный скан с алертом | ✓ |

---

## `--only`

Выполнить **ровно один этап** на уже настроенной системе. Переиспользует существующий
`setup.conf` (мастер НЕ запускается), применяет `--force` к этапу.

```bash
sudo ./server-setup.sh --only <этап>
sudo ./server-setup.sh --only <этап> --dry-run     # предпросмотр без изменений
```

**Безопасные (аддитивные) для рабочего сервера:**
```bash
sudo ./server-setup.sh --only hostcert     # выпустить LE-серт хоста (после настройки DNS)
sudo ./server-setup.sh --only mailsni       # подтянуть per-domain серты почты
sudo ./server-setup.sh --only maildeliver   # перегенерить DNS-записи + TLS-харденинг Postfix
sudo ./server-setup.sh --only tuning        # перетюнить под железо
sudo ./server-setup.sh --only backup        # настроить/обновить бэкап-таймер
sudo ./server-setup.sh --only rcplugins     # плагины Roundcube + remote API user
sudo ./server-setup.sh --only monit
sudo ./server-setup.sh --only nodejs
```

**Опасные на рабочем сервере (только с пониманием последствий):**
```bash
sudo ./server-setup.sh --only nginx         # ПЕРЕСБОРКА nginx + перезапись nginx.conf; на работающем nginx
                                            # новый бинарник активируется через nginx -t + рестарт (с подтверждением,
                                            # откат бинарника/конфига при провале) — без этого апдейт был бы неактивен
sudo ./server-setup.sh --only database      # adopt-safe, но трогает БД
sudo ./server-setup.sh --only ispconfig     # переустановка панели (лучше --update → офиц. апдейтер)
sudo ./server-setup.sh --only mail|dns|ftp  # перезаписывают конфиги служб
```

> Совет: всегда сначала `--only <этап> --dry-run`, чтобы увидеть, что будет сделано.

---

## Режим обновления

`--update` — безопасное **сопровождение** уже настроенного сервера (в т.ч. собранного вручную
по гайду Perfect Server).

```bash
sudo ./server-setup.sh --update
sudo ./server-setup.sh --update --dry-run   # план без изменений
```

Делает **автоматически** (аддитивно, ядро не трогает):
- `apt update && apt upgrade` (по подтверждению);
- автообновления безопасности, sysctl-харденинг, fail2ban-jail'ы, права конфигов стека (снимается запись для всех), world-writable аудит;
- усиление шаблонов ISPConfig (conf-custom) — по подтверждению;
- **блокировку доступа по IP — те же патчи, что при установке** (default-сервер nginx по
  `HTTP_IP_POLICY` + `:443 ssl_reject_handshake`; панель только по FQDN при `PANEL_FQDN_ONLY`;
  ограничение веб-админки БД по `DBADMIN_FQDN_ONLY`/IP). Переприменяются всегда (ISPConfig resync
  или ручные правки могли их размыть); идемпотентно, с `nginx -t` и откатом. На adopt-сервере — пропуск;
- авто-тюнинг, доставляемость почты, per-domain TLS (SNI), LE-серт хоста, плагины Roundcube, бэкапы
  (каждый сам пропускается, если не применим).

**Ядро — только по явному подтверждению:**
- **Пересборка nginx** до последней версии (с бэкапом бинаря и `nginx.conf`);
- **Обновление ISPConfig** официальным апдейтером `ispconfig_update.sh`
  (см. faqforge: how-to-update-ispconfig-3) — НЕ переустановкой.

Пароль root MariaDB и базовые конфиги служб в режиме `--update` не трогаются.

### `--adopt` — аддоны на СТОРОННЕ установленный сервер

Для сервера, собранного **не нашим установщиком** (вручную / по гайду / другими скриптами вроде
`nginx-autoinstall.sh`), где уже есть ISPConfig и проекты. Подключает только **server-agnostic**
аддоны (бэкап+оффсайт, уведомления+монитор, тюнинг, доставляемость почты, security-доп) и
**НЕ трогает**: сборку nginx, переустановку/шаблоны/vhost'ы/БД ISPConfig, firewall/SSH.

```bash
sudo ./server-setup.sh --adopt
sudo ./server-setup.sh --adopt --dry-run   # предпросмотр без бэкапа/изменений
```

Порядок (жёстко):
1. **Детект** обжитого сервера (`_detect_existing_install`) + баннер «воспринимается как внешний».
2. **Бэкап-гейт** — `_adopt_backup`: дамп всех БД (вкл. `dbispconfig`) + `/etc` + `/usr/local/ispconfig`
   в `/var/backups/luckystack-preadopt-<ts>/`. Если авто-бэкап не удался/неполон или мало места —
   **громкое предупреждение** и требование ручного подтверждения `BACKUP-OK` (в неинтерактиве — стоп).
3. **Повторное подтверждение** `APPLY`.
4. Применение через update-режим с `UPD_ADOPTED=1` — меню показывает только безопасные аддоны;
   блоки, мутирующие шаблоны/БД ISPConfig (модернизация vhost, регистрация PHP, Monit→ISPConfig),
   **пропускаются**.

`UPD_ADOPTED=1` также можно задать вручную перед `--update`, чтобы получить ту же adopt-постуру.

---

## Предохранитель

Если запустить **полную установку** на сервере, который уже выглядит настроенным (стоит
ISPConfig, или работают веб-сервер+PHP-FPM+MariaDB), а нашего `setup.state` нет — установщик
**не сносит молча**, а предлагает:
1. **Режим обновления** (`--update`) — безопасно;
2. Применить один этап (`--only`);
3. Полная установка ПОВЕРХ — только после ввода `OVERWRITE`.

В неинтерактивном режиме полный прогон на таком сервере **отклоняется** (exit 2) с подсказкой.

---

## Бэкапы и восстановление

Настройка (этап `backup` или `--only backup`): ежедневный дамп всех БД + архив `/etc` и конфигов
ISPConfig по systemd-таймеру, ротация по дням; опц. `/var/www` и `/var/vmail`.

Каталог бэкапов должен быть отдельным. Системные каталоги, `/var/www`, `/var/vmail` и корни вроде `/var`,
`/mnt`, `/home` запрещены: скрипт делает на каталог `chmod 700` и чистит в нём старые снимки. Проверка стоит
в мастере, в этапе backup, в самом `server-backup.sh` (с плохим каталогом выходит с кодом 2) и в cron панели.
Ротация удаляет только каталоги снимков с именем вида `20261105-033000`, только после бэкапа без ошибок и
всегда оставляет 3 последних снимка. Чужие каталоги рядом не трогает.

```bash
/usr/local/sbin/server-backup.sh            # сделать бэкап сейчас
/usr/local/sbin/server-backup.sh --list     # список снимков
systemctl list-timers server-backup.timer   # расписание
```

**Восстановление:**
```bash
sudo ./server-setup.sh --restore            # интерактивно: выбор снимка + компонентов
# или напрямую (для disaster recovery без установщика):
/usr/local/sbin/server-backup.sh --restore [СНИМОК] [--db --etc --ispconfig --www --vmail | --all] [--yes]
```
По умолчанию — последний снимок, только БД. Восстановление **необратимо** перезаписывает данные.

**Оффсайт-копия (вторая копия вне сервера — защита от потери диска/сервера).** В мастере на шаге
бэкапа: `rsync по SSH` на другой сервер, либо `rclone` в облако. Для rclone установщик **создаёт
remote за вас** (не нужно вручную гонять `rclone config`) — спрашивает бэкенд и реквизиты:
- **Amazon S3 / S3-совместимый** (AWS, Wasabi, Storj, MinIO/Other): provider + Access Key/Secret +
  регион + endpoint;
- **Backblaze B2**: keyID + applicationKey;
- **SFTP**: хост/пользователь/порт + ключ или пароль (пароль шифруется `rclone obscure`).

Remote называется `offsite`, реквизиты сохраняются в `setup.conf` (chmod 600) и `rclone.conf`.
`_backup_setup_rclone_remote` (lib/backup.sh) выполняет `rclone config create`, делает `rclone mkdir`
назначения и **проверяет связь** (`rclone lsd`/`about`) — при провале выдаёт предупреждение, не молчит.
Дальше каждый бэкап в конце зеркалит каталог снимков наружу: `rclone sync "$DEST" "$BACKUP_REMOTE"`
(или `rsync -az --delete`). Сбой выгрузки → `rc!=0` → уведомление через `server-notify.sh`.
Ключи: `BACKUP_REMOTE_TYPE` (none|rsync|rclone), `BACKUP_REMOTE`, `BACKUP_RCLONE_BACKEND`
(s3|b2|sftp|manual) + `BACKUP_RCLONE_*`. `manual` = настроить rclone самому. E2E (SFTP self-test):
remote создан, связь подтверждена, `rclone sync` выгрузил файл.

**Восстановление из панели ISPConfig** (`ISPC_BACKUP_PANEL=y`, по умолч. y; `_ispconfig_deploy_backup_panel`):
пункт меню **System → Дополнения → Backup / Restore** со списком снимков (имя/размер/компоненты) и выбором компонентов
(`db` по умолчанию; `etc/www/vmail/ispconfig` помечены ⚠ и требуют явного выбора + обязательной галочки-
согласия + JS-confirm). Интерфейс (под `ispconfig`) не может ни читать `/var/backups/server` (root 700),
ни запускать restore (root), поэтому: панель пишет запрос в очередь `backup_restore`, а **root-cron**
`ss-backup-sync.php` (`/etc/cron.d/ss-backup-panel`, раз в минуту) обновляет кэш снимков (`backup_snapshot`)
и выполняет **ОДИН** ожидающий restore через `server-backup.sh --restore <снимок> <флаги> --yes`. Защита:
`flock` от наложения + пропуск при наличии `running`-задачи; имя снимка (`^\d{8}-\d{6}$`) и компоненты
(whitelist) валидируются и в странице, и в cron. Восстановление **необратимо** и перезапускает службы.
Страница/меню затираются обновлением ISPConfig → переналиваются в `--update` (3.2.5); таблицы/cron —
идемпотентно. E2E на проде: queue→cron→restore тестовой БД = `done` (маркер восстановлен), битый снимок =
`error`, службы поднялись, сайт/панель 200/302.
**Настройки бэкапа + «Бэкап сейчас» в панели** (A1): та же страница вверху даёт **редактировать настройки**
`server-backup.conf` (каталог, хранение, время, /var/www и /var/vmail, оффсайт rsync/rclone) и **включать
ежедневный таймер** — всё через очередь `backup_job` (action `config`) → root-cron пишет conf + (пере)создаёт
`server-backup.service`+`.timer` (OnCalendar из времени) + `systemctl enable/disable --now`. Кнопка **«Сделать
бэкап сейчас»** (`backup_job` action `run`) запускает `server-backup.sh`. Текущие настройки/статус таймера/
последний снимок панель читает из кэша `backup_setting` (наполняет тот же cron). Значения валидируются в
странице и в cron (каталог — абс.путь, дни — число, время — `ЧЧ:ММ`). Deploy панели сам ставит `server-backup.sh`,
если этап backup не прогонялся (ручной сервер) — «Бэкап сейчас»/restore работают из коробки. E2E на проде:
сохранение настроек → conf+таймер `enabled`; «бэкап сейчас» → снимок создан.
**Анти-дубль-клик** (как в notify-панели): пока в `backup_job`/`backup_restore` есть `pending`/`running`,
кнопки Сохранить/«Бэкап сейчас»/Восстановить блокируются (гейт и на сервере — новую задачу не ставим, и в JS —
`lock()` на клике), при занятости страница **сама авто-обновляется** (5с) до результата и разблокировки. Важно
для restore (необратим) и долгого бэкапа (идёт минуты — авто-рефреш ждёт `running`→`done`).

---

## Сертификаты

Три независимых уровня (часто путают):

| Что | Чей серт | Кто делает |
|---|---|---|
| `hostcert` (этап 17) | hostname сервера (1 шт) | наш установщик (acme.sh) → панель + почта (default) |
| `mailsni` (этап 20) | **per-почтовый-домен** (SNI) | наш установщик (берёт LE из `/etc/letsencrypt/live`) |
| сайты | per-сайт | сам **ISPConfig** (галочка LE при создании сайта) |

`hostcert` требует: A-запись **hostname** → IP сервера + открытый порт 80 (домены в панели
заводить НЕ нужно). На тестовых стендах/непубличных доменах мягко пропускается.

---

## Сценарии

**Боевой VPS, после установки настроил DNS:**
```bash
# 1. A-запись server1.домен.ru → IP сервера, порт 80 открыт
sudo ./server-setup.sh --only hostcert     # валидный серт на панель + почту
# 2. Завёл клиентские домены/сайты в панели с галочкой LE
sudo ./server-setup.sh --only mailsni       # (или подождать сутки — таймер сам подтянет)
```

**Регулярное обслуживание:**
```bash
sudo ./server-setup.sh --update             # пакеты + патчи; nginx/ISPConfig — по запросу
sudo ./server-setup.sh --healthcheck        # проверить здоровье
sudo ./server-setup.sh --status             # версии + доступные обновления
```

**Обновить только nginx / только ISPConfig:**
```bash
sudo ./server-setup.sh --update             # → подтвердить «Пересобрать nginx» / «Обновить ISPConfig»
# либо напрямую nginx:
sudo ./server-setup.sh --only nginx
```

---

## Конфигурация

`/etc/luckystack/setup.conf` — ключ=значение, читается при `--resume`/`--only`/`--unattended`.
Можно править вручную. Полезные ключи:

| Ключ | Значение |
|---|---|
| `SERVER_FQDN`, `TIMEZONE` | имя хоста, часовой пояс |
| `WEBSERVER` | `nginx` / `apache`. Apache в мастере скрыт до выпуска с полной поддержкой: выбор показывается с `LS_APACHE=1` или если сервер уже на Apache; код Apache и `WEBSERVER=apache` в setup.conf работают как раньше |
| `NGINX_CHANNEL` | `stable` / `mainline` |
| `NGINX_AUTO_VERSION` | `y` (по умолч.) — авто-последняя версия; `n` — пин `NGINX_STABLE_VER`/`NGINX_MAINLINE_VER` |
| `MARIADB_SOURCE` | `official` / `debian` |
| `MARIADB_AUTO_VERSION` | `y` — последняя LTS; `n` — пин `MARIADB_VERSION` (напр. `11.4`) |
| `ISPCONFIG_BRANCH` | `nightly` / `stable` |
| `ISPCONFIG_PANEL_PORT` | порт панели (по умолч. 8080) |
| `SERVER_HAS_IPV6` (y/n) | **единая «истина» про IPv6**: автодетект в preflight (глобальный адрес + default-маршрут), переопределяемо вручную. На неё завязаны IPv6-зависимые фиксы через `_has_ipv6` (lib/core.sh) — напр. `named -4` (IPv4-only исходящие при отсутствии IPv6, иначе BIND засоряет лог «address not available»), проверка почтовых портов в `--healthcheck`. Применяется на этапе DNS и в `--update`. Если IPv6-адрес у сервера есть, а наружу по IPv6 ничего не открывается (бывает у хостеров), preflight в самом начале дописывает в `/etc/gai.conf` строку `# luckystack: ipv4-first` с `precedence ::ffff:0:0/96 100`, ставит `SERVER_HAS_IPV6=n` (если не задано) и этап maildeliver переводит Postfix на `smtp_address_preference = ipv4`. Иначе wget, PHP и Postfix сначала ждут IPv6 до таймаута. Сам IPv6 не выключаю: при секции `inet6` в `/etc/network/interfaces` это может уронить сеть после перезагрузки. Заработает у хостера IPv6, повторный preflight строку уберёт |
| `FIREWALL` | `crowdsec` / `ufw` / `none` |
| `CROWDSEC_WITH_UFW` (y/n) | при `FIREWALL=crowdsec` дополнительно поднять **ufw (default-deny по портам)** поверх — CrowdSec банит IP, но порты НЕ закрывает; ufw закрывает лишнее. По умолч. y (secure-by-default). `n` → только CrowdSec (тогда чувствительные сервисы обязаны слушать localhost) |
| `SSH_PORT`, `SSH_HARDEN`, `SSH_PUBKEY` | порт SSH, харденинг, публичный ключ. Порт пишется в **приоритетный drop-in** `/etc/ssh/sshd_config.d/00-luckystack-ssh.conf` (sshd берёт первое значение Port — иначе cloud-init drop-in перебивал бы наш Port, и демон оставался на 22). После правки проверяется `sshd -T` (эффективный порт). Применить отдельно: `--only ssh` |
| `SSH_NETSAFE` (y/n), `NETSAFE_MINUTES` | анти-лок-аут: при рискованных правках (смена SSH-порта, активный firewall, харденинг, SSH-по-IP) взводится таймер отката. Если за `NETSAFE_MINUTES` (по умолч. 5) не подтвердить доступ из НОВОГО соединения (`touch /run/luckystack-net-ok`) — `ufw disable` + откат sshd_config/порта. По умолч. y; **только интерактив** (не для `--unattended`) |
| `SSH_ALLOW_IPS` | вход по SSH только с этих IP (через пробел; пусто = со всех). Применяется через **firewall** (UFW: `allow from IP` для 22 и `SSH_PORT`); ufw поднимается и при `FIREWALL=crowdsec`, если `CROWDSEC_WITH_UFW=y`. **Самозащита от лок-аута**: если текущий SSH-адрес не в списке — порт открывается со ВСЕХ (не отрезаем сессию, из которой ставим). Можно указать несколько IP. ⚠ при `FIREWALL=none` не применяется. _(sshd-уровневый Match убран: `Match Address *,!IP` на практике блокировал даже разрешённый адрес.)_ |
| `SEC_LYNIS`, `SEC_RKHUNTER`, `SEC_AUTO_UPDATES`, `SEC_SYSCTL`, `SEC_WORLDWRITABLE` | подсистемы security |
| `FTP_TLS_REQUIRED` (y/n) | PureFTPd: `y` (по умолчанию) — вход только по FTPS (`TLS=2`), `n` — TLS по желанию клиента (`TLS=1`) |
| `SSH_SAFE` (y/n), `SSH_TCP_FORWARD` (y/n) | безопасные настройки SSH drop-in-файлом `sshd_config.d/10-luckystack-harden.conf` (по умолчанию y): X11 и проброс агента off, TCP-проброс по `SSH_TCP_FORWARD` (по умолчанию n; y — если нужны SSH-туннели), ClientAlive 300×2, LoginGraceTime 30. `SSH_HARDEN=y` — дополнительно вход только по ключу (если ключ есть) |
| `SEC_AUTO_UPDATES_3RD` (y/n), `SEC_USERNS_OFF` (y/n), `SEC_AIDE` (y/n), `JOURNAL_MAX` | автообновления и из сторонних репозиториев стека (по умолчанию y); запрет непривилегированных user namespaces (n); AIDE (n); предел журнала systemd (500M) |
| `ISPC_SESSION_TIMEOUT`, `ISPC_IDS_ADMIN` (y/n), `ISPC_SITE_BACKUPS` (y/n), `ISPC_SITE_BACKUP_COPIES` | панель: тайм-аут сессии вместо «никогда» (60 мин), IDS и для admin (y), включить ли бэкапы ISPConfig у сайтов без них (спрашивает `--update`, ответ запоминается), сколько копий (3) |
| `RC_SOURCE` (upstream/debian), `RC_BRANCH` (1.6/1.7) | откуда Roundcube: `upstream` (по умолчанию) — с сайта разработчиков в `/opt/roundcube`, обновляет `--update`; `debian` — пакет. Ветка: 1.6 LTS (по умолчанию) или 1.7. Спрашивается в мастере при выбранном Webmail |
| `HARDEN_CONF_CUSTOM`, `HARDEN_HSTS` | усиление шаблонов ISPConfig; HSTS |
| `GEOIP`, `GEOIP2_ACCOUNT_ID`, `GEOIP2_LICENSE_KEY` | GeoIP2 (только nginx) |
| `BACKUP_DIR`, `BACKUP_RETENTION_DAYS`, `BACKUP_TIME`, `BACKUP_INCLUDE_WWW`, `BACKUP_INCLUDE_MAIL` | бэкапы |
| `BACKUP_REMOTE_TYPE` (none/rsync/rclone), `BACKUP_REMOTE` | оффсайт-копия бэкапов (вторая копия вне сервера). `rsync`: `BACKUP_REMOTE='user@host:/path/'` (+опц. `BACKUP_REMOTE_SSHPORT`, `BACKUP_REMOTE_SSHKEY`; нужен SSH-ключ к удалёнке). `rclone`: `BACKUP_REMOTE='remote:bucket/path'` (предварительно `rclone config`; пакет ставится автоматически). Выгрузка после локального снимка; ошибка оффсайта → rc≠0 (попадёт в уведомления). Доп. флаги — `BACKUP_REMOTE_OPTS` |
| `NOTIFY_EMAIL`, `NOTIFY_FROM`, `NOTIFY_TG_TOKEN`, `NOTIFY_TG_CHAT` | уведомления админу: email (нужен компонент mail / MTA) и/или Telegram-бот. Ставит `server-notify.sh` (отправка) + `server-monitor.sh` с ежедневным таймером (08:00). Шлёт при: сбое бэкапа, диске ≥ `MON_DISK_PCT` (90%), TLS-серте < `MON_CERT_DAYS` дн. (14), упавшей службе, **протухшем бэкапе** (последний снимок старше `MON_BACKUP_DAYS`, по умолч. 2 дн., или снимков нет). Настройки — `/etc/server-notify.conf`. **`NOTIFY_FROM` — отправитель email**: адрес на DKIM-подписанном почтовом домене ISPConfig (авто: `noreply@<первый active+dkim mail_domain>`), шлём через `sendmail -f` (envelope→SPF) + заголовок `From` (→DKIM/DMARC-alignment). Без этого письма уходят от `root@<хост>` без SPF/DKIM → **mail.ru и пр. режут как спам** (`550 spam message rejected`). E2E на проде: смена на `noreply@example.com` → mail.ru принял (`250 OK`), до этого bounced. При установке шлёт тестовое сообщение. **Настраивается и из панели** (см. `ISPC_NOTIFY_PANEL`) |
| `ISPC_NOTIFY_PANEL` (y/n) | Панель **Уведомления** (`_ispconfig_deploy_notify_panel`, A2): пункт меню System → Дополнения → Notifications — настроить **email/Telegram** и **отправить тест** прямо из ISPConfig. Интерфейс не root → очередь `notify_job` (save/test) + root-cron `ss-notify-sync.php` правит `/etc/server-notify.conf` и шлёт тест через `server-notify.sh`. **Токен бота write-only** (не показывается/не кэшируется; пусто = оставить прежний). Статус «активно/нет» + наличие MTA + **отправитель писем** (`NOTIFY_FROM`, авто из `mail_domain` с DKIM). **Анти-дубль-клик**: кнопки Сохранить/Тест блокируются, пока прошлая задача в очереди/выполняется (гейт по `notify_job` status pending/running — и на сервере, и в JS); при занятости страница **сама авто-обновляется** (5с) до результата, повторное нажатие дубль не создаёт; сообщение показывает, ЧТО именно уйдёт (email/chat), а «Тест» помечен как отправка по УЖЕ сохранённым настройкам. Deploy сам ставит `server-notify.sh`, если уведомления не настраивались. По умолч. y. Install (8.16) + `--update` (3.2.10). E2E: save email → active + авто-`NOTIFY_FROM=noreply@example.com`; тест → mail.ru принял (250 OK); write-only токен |
| `MONIT_EXPOSE` (y/n), `MONIT_ALLOW_IP` | открыть Monit :2812 наружу только для указанного IP (по умолч. localhost). При выносе наружу включается **HTTPS** (PEM из LE-серта хоста, иначе self-signed; hostcert обновляет на LE при выпуске/продлении) |
| `MONIT_ISPC_INTEGRATE` (y/n) | авто-вписывание Monit в ISPConfig (System → Server Config → Monitor): `monit_url`/`monit_user`/`monit_password` в `server.config` (ISPConfig хранит их в секции `[server]` — заменяем по имени ключа; ошибочную секцию `[monitor]` выкидываем). По умолч. y. После установки ISPConfig + в `--update`; бэкап `/root/.ispconfig-server-config.pre-monit.bak`, запись через `FROM_BASE64` |
| `DBADMIN_FQDN_ONLY` (y/n), `DBADMIN_ALLOW_IPS` | ограничение доступа к веб-админке БД (/phpmyadmin, /adminer): только по FQDN (по умолч. y — закрыть по IP/чужому домену) и/или только с указанных IP. nginx → сниппет `default-locations/dbadmin-restrict.conf`; Apache → `RequireAll` в conf-drop-in. С `nginx -t`/`configtest` + откатом |
| `TUNE_SWAP` (y/n), `TUNE_SWAP_SIZE` | swap-файл в preflight (защита от OOM, напр. clamd). Спрашивается в мастере, только если RAM<4G и swap нет; размер 1–16G (по умолч. 2G). Удаляется при uninstall ядра по маркеру `# luckystack-swap` в fstab |
| `INSTALL_CLAMAV` (y/n) | ставить ли ClamAV в составе rspamd. По умолч. y; на малой памяти (RAM+swap < ~1.5G) мастер предлагает отключить — Rspamd работает без антивируса |
| `ISPCONFIG_ADMIN_IPS` | вход в панель только с этих IP (через firewall; пусто = со всех) |
| `HOST_FQDN_SITE` (y/n) | отдавать стартовый сайт хоста (`/var/www/html`: roundcube, phpmyadmin) по FQDN на :443 с LE-сертом + редирект http→https (`conf.d/10-host-fqdn.conf`). По умолч. y. Без него `https://FQDN/roundcube` упирается в default :443 `ssl_reject_handshake` и не открывается. Ставится в hostcert; отключить — `HOST_FQDN_SITE=n` |
| `PANEL_FQDN_ONLY` (y/n) | запрет входа в панель по IP — только по FQDN (nginx `if ($host!=fqdn) return 444`). Включается в hostcert после проверки, что A-запись FQDN указывает на сервер. Аварийное снятие: `ispconfig-panel-allow-ip.sh` или `PANEL_FQDN_ONLY=n` + `--only hostcert` |
| `HTTP_IP_POLICY` | поведение **default-сервера nginx на :80** по IP/неизвестному домену: `landing` (по умолч. — отдаёт `/var/www/html` с roundcube/phpmyadmin по IP) / `redirect` (301 на `SERVER_FQDN`, нужен публичный FQDN) / `deny` (444 — по IP ничего). Это про сайт на :80; панель (:3333) закрывается отдельно через `PANEL_FQDN_ONLY`, :443-дефолт всегда `ssl_reject_handshake`. Пишется в `conf.d/00-default.conf` на этапе nginx |
| `LE_STAGING` (y/n) | выпуск LE-серта хоста на **staging-CA** (`letsencrypt_test`): серт НЕ доверенный, но БЕЗ rate-limit — для тестов/частых прогонов. По умолч. n. Прод: `LE_STAGING=n` (или не задавать) |
| `PANEL_HTTP3` (y/n) | HTTP/3 (QUIC) для vhost панели/apps (нужен nginx с `--with-http_v3_module`; открывает UDP-порт). По умолч. n. **Всегда** (этап ispconfig + переприменяется в `--update`): `listen … ssl http2;` → `listen … ssl; http2 on;`, `ssl_protocols TLSv1.2` → `TLSv1.2 TLSv1.3`, легаси `ssl_ciphers` (3DES/!DSS) → современный Mozilla intermediate. Живые файлы с `nginx -t`+откатом (идемпотентно), мастера дублируются в `conf-custom` |
| HTTP/3 и firewall (UDP/443) | QUIC идёт по **UDP/443** (сайты) и UDP порта панели. При `NGX_HTTP3=y` ufw открывает `443/udp` (и `<panel>/udp` при `PANEL_HTTP3=y`) — **иначе** браузер видит `Alt-Svc: h3`, не достучится по UDP и молча откатится на HTTP/2 (собранный HTTP/3 не работает). `--healthcheck` проверяет, что nginx слушает UDP/443 и порт открыт в ufw. Сборка: OpenSSL ≥3.5 (у нас 3.6.3 → нативный QUIC); 0-RTT (`ssl_early_data`) намеренно НЕ включаем (риск replay) |
| `OPENSSL_BRANCH` (3.5/4.1/4.0) | С какой веткой OpenSSL собирать nginx при HTTP/3. По умолч. **3.5** (LTS, поддержка до 04.2030), 4.1 до 11.2027, 4.0 до 05.2027. Спрашивается в мастере и в `--update` при пересборке nginx. `OPENSSL_VER` в setup.conf закрепляет точную версию и важнее ветки. |
| `ISPC_MAINT_PANEL` (y/n) | Панель **Обслуживание сервера** (`_ispconfig_deploy_maint_panel`, меню System → Дополнения → Server maintenance), по умолч. **y**. Состояние и проверки, запуск `--update` по списку пунктов с журналом в панели, настройки установщика из разрешённого списка, журнал действий. Страница только ставит задание в `ss_maint_job`, root-cron `ss-maint-sync.php` его проверяет. Установщик запускается, только если его файлы принадлежат root и не открыты на запись группе и всем. Обновление идёт отдельной службой `ss-maint-job-N`, журналы в `/var/log/luckystack-panel`. Два обновления одновременно не запустятся (`/run/luckystack-update.pid`). Смены входа по паролю SSH в панели нет намеренно. |
| `SEC_SERVICE_HARDEN` (y/n) | Ограничения systemd для nginx и MariaDB (`_security_service_hardening`, drop-in `50-luckystack-harden.conf`). По умолч. **n**. Если служба с ними не запускается, ограничения снимаются сами. PHP-FPM не трогаем: sendmail с setgid несовместим с NoNewPrivileges. |
| `NGX_TIGHT_TIMEOUTS` (y/n) | Короткие таймауты клиентов nginx (`conf.d/05-luckystack-timeouts.conf`): заголовки 15 с, сброс зависших соединений. По умолч. **y**. |
| Часовой пояс ISPConfig | В `config.inc.php` у ISPConfig свой `$conf['timezone']`, он задаётся при установке и может не совпасть с системным (на тестовом был Europe/Warsaw при системном Europe/Moscow). `--update` (пункт безопасности) и `--timezone` приводят его к поясу системы (`_tz_ispconfig`). |
| `--rollback nginx\|roundcube\|luckystack` | Вернуть прошлую версию (`_nginx_rollback`, `_rcu_rollback`, `ls_rollback_code`), повтор отменяет откат. Прошлая сборка nginx сначала проверяет текущий конфиг. БД Roundcube возвращается из дампа, только если её схема менялась. То же есть в панели обслуживания. ISPConfig и базы откатываются из бэкапа вручную. |
| Панель обслуживания: страховка | Перед `nginx` и `ispconfig` панель запускает `server-backup.sh`. Если бэкап не удался или скрипта нет, обновление не запускается. Итог обновления и новые проблемы в проверках уходят через `server-notify.sh` (событие monitor, повторно об известной проблеме не пишет). `SEC_ADMIN_EMAIL` задаёт адрес писем о безопасности ISPConfig и переживает обновления. |
| Меню «Дополнения» | Все наши панели отдельной группой в модуле System (`assets/ispconfig/common/ss_panels.menu.php` ставится в `admin/lib/menu.d/`, `_ispc_menu_deploy`). Файл переживает обновление ISPConfig, поэтому `module.conf.php` больше не правим, старые вставки оттуда убираются сами. Родной пункт Firewall при нашем модуле скрыт: он отключает ufw. |
| Заморозка vhost и PHP | Смена версии PHP у замороженного сайта работает без правок: адрес сокета один на все версии, ISPConfig переносит только пул. При смене сокета на порт (и обратно) адрес в замороженном тексте обновляется сам, вручную вписанный адрес не меняется, об этом пишет статус. При выключенном PHP на `.php` будет 502, статус об этом предупреждает. Только для nginx. |
| `NGX_QUIC_GSO` (y/n) | QUIC `quic_gso` (UDP-сегментация на ядре). По умолч. **n** — как у самого nginx: на части virtio-NIC GSO роняет HTTP/3 (чёрная дыра больших UDP-пакетов). Включать, только если на конкретном VDS QUIC стабилен. Действует лишь при `NGX_HTTP3=y` |
| `NGX_QUIC_RETRY` (y/n) | QUIC `quic_retry` (валидация адреса клиента — защита от амплификации/спуфинга, ценой +1 RTT на первое соединение). По умолч. **n**. Действует лишь при `NGX_HTTP3=y` |
| `$http3` в логах | при `NGX_HTTP3=y` в `log_format anonymized` добавляется `h3=$http3` (`h3`/`hq`/пусто) — видно долю HTTP/3 vs HTTP/2 в `/var/log/nginx/access.log`. Идемпотентно и обратимо (при `n` убирается, иначе `nginx -t` упал бы на неизвестной переменной без http_v3) |
| `ISPC_REGISTER_PHP` (y/n) | авто-регистрация всех установленных версий PHP-FPM в ISPConfig (System → Additional PHP Versions) через `dbispconfig.server_php`. По умолч. y. Заполняет FPM + CLI (`php_cli_binary`, `php_jk_section=phpX_Y` — оба обязательны в форме) + опц. FastCGI. Идемпотентный UPSERT; переприменяется в `--update` |
| `ISPC_PHP_CGI` (y/n) | дополнительно заполнять FastCGI-поля версии (`php_fastcgi_binary=/usr/bin/php-cgiX.Y`), доустанавливая пакет `phpX.Y-cgi`. По умолч. y. Нужно для Apache и выбора версии PHP в shell/cron клиента; на nginx сайты используют только PHP-FPM. Выкл (`n`) → чистый FPM, FastCGI-поля пустые |
| `INSTALL_COMPOSER` (y/n) | Composer глобально (`/usr/local/bin/composer`, `_ispconfig_install_composer` — офиц. установка с проверкой sha384-подписи, идемпотентно/`self-update`) + добавление `composer php node` в `jailkit_chroot_app_sections` ISPConfig (`_ispconfig_jailkit_apps`, правит `server.config` через PHP-регэксп, только дополняет). По умолч. y. Тогда **jailed shell-юзеры сайтов получают composer/php/node в chroot** (jk_init копирует их из jk_init.ini-секций при сборке jail) — для SSH-деплоя `composer install`. Install (шаг 8.4) + `--update` (3.2.8). Существующие jail'ы подхватят при обновлении shell-юзера. E2E: composer 2.10.2, jk_init копирует composer/php8.3/node/npm в jail |
| `ISPC_NODECOMPOSER_PANEL` (y/n) | Панель **Node.js / Composer** (`_ispconfig_deploy_nodecomposer_panel`): пункты меню System → **Node.js** и **Composer** (каждый показывается ТОЛЬКО если инструмент реально установлен). По-сайтово: выбрать сайт + каталог проекта → список пакетов из манифеста (кэш `nodecomposer_pkg`) + установить/удалить/установить-все/**устаревшие**. Интерфейс не может запускать npm/composer от юзера сайта → очередь `nodecomposer_action` + root-cron `ss-nodecomposer-sync.php` (раз/мин) выполняет `su - webX -s /bin/bash -c 'cd <проект> && npm/composer …'` с жёсткой валидацией (юзер/путь-внутри-home/имя пакета + escapeshellarg, flock). «Открыть»/действия — через `loadContent()` (НЕ form-submit: в SPA он уходит на index.php). «Открыть» авто-ставит scan (список без лишней кнопки). **Глобальный режим** (пункт «🌐 Global» в списке сайтов, оба инструмента): Node → `npm -g`; Composer → `composer global` (с `COMPOSER_ALLOW_SUPERUSER=1`) — системно **от root** (админ, с предупреждением), для pm2/yarn, laravel/installer и т.п. Кнопка **«Устаревшие пакеты»** (`npm/composer outdated --direct`; выход-код 1 при наличии устаревших трактуется как «выполнено») — полный вывод показывается отдельным `<pre>`-блоком (в таблице задач он обрезан). **Фикс HOME→tmp сайта** (home immutable из-за web_folder_protection → npm/composer EPERM). en+ru. Install (8.15) + `--update` (3.2.9). По умолч. y (гейт по наличию node/composer). Мастер спрашивает в блоке **«Панели-расширения ISPConfig»** (единый вопрос «ставить все?» → при «нет» — по-панельно: `INSTALL_COMPOSER`, `ISPC_NODECOMPOSER_PANEL`, `ISPC_NOTIFY_PANEL`, `ISPC_BACKUP_PANEL` при выбранном backup, `ISPC_CROWDSEC_PANEL` при `FIREWALL=crowdsec`). E2E на проде: per-site npm/composer install/remove/outdated (от юзера сайта) + global npm -g / composer global require/outdated/remove (от root) + инъекции отбиты |
| `PHP_DEFAULT` | версия PHP по умолчанию: обработчик `.php` стартовой страницы (phpMyAdmin/RoundCube) + дефолт для CLI, если `PHP_CLI_DEFAULT` не задан. Сайты в ISPConfig выбирают версию отдельно; **панель ISPConfig** работает на нативной для дистрибутива версии (Debian 12 → 8.2, Debian 13 → 8.4, Ubuntu 22.04 → 8.1, 24.04 → 8.3), а не на `PHP_DEFAULT` |
| **PHP панели ISPConfig (обязательна)** | Панель ISPConfig — само по себе PHP-приложение и работает на **нативной версии дистрибутива** (её FPM обязателен, иначе панель = **HTTP 502**). Мастер это учитывает: нативная версия помечена «нужна панели ISPConfig», предвыбрана и **авто-добавляется в `PHP_VERSIONS`, даже если снять галочку** (`_distro_native_php` по релизу). Определение по релизу, НЕ через `apt-cache depends php` — репо **sury** перебивает метапакет `php` на свою свежайшую (на bookworm вернул бы 8.4 вместо 8.2 → и был баг: панель на 8.2, а `php8.2-fpm` не ставился → 502). **Двойная гарантия** (`_ispconfig_ensure_panel_php`): до `install.php` — предсказание по релизу; ПОСЛЕ — по факту из vhost панели (`fastcgi_pass unix:/var/lib/phpX.Y-fpm/ispconfig.sock`) доустанавливает FPM+модули нужной версии. Self-heal в `--update` (блок 3.0). E2E на проде (Debian 12): детект=8.2, vhost=8.2, старый метод давал 8.4 |
| `PHP_CLI_DEFAULT` | какая версия запускается командой `php` (shell/cron) через `update-alternatives`. По умолч. = `PHP_DEFAULT`; `system` = не трогать дефолт Debian; либо конкретная версия. Все версии всегда доступны явно (`php8.2`, `php8.3`…). Переприменяется в `--update` |

---

## Удаление
```bash
sudo ./server-setup.sh --uninstall          # выбор компонентов (конфиги)
sudo ./server-setup.sh --purge              # + ДАННЫЕ (БД/почта/сайты) — НЕОБРАТИМО
```

**Админ-утилиты НЕ удаляются.** Пакеты из `UTILS` (`nano vim mc htop git sudo rsync unzip tar
bzip2 perl net-tools bash-completion`) при установке помечаются `apt-mark manual` и при
`--uninstall`/`--purge` остаются всегда (их не трогает ни одна `uninstall_*`, а `apt autoremove`
чистит только осиротевшие зависимости).

Пакеты удаляются по списку реально установленных (`dpkg-query`), поэтому шаблон вроде `php*` и
отсутствующее в релизе имя (getmail на Debian 13) не ломают весь вызов apt. Вместе с панелью уходят
строки ISPConfig из crontab root и наши `/etc/cron.d/ss-*`, иначе без панели они падали бы каждую
минуту. Анти-malware (таймер скана, LMD, `rkhunter.conf.local`) снимается отдельным пунктом.

Без `--purge` вместе с данными остаются и ключи к ним: `/root/.my.cnf` (пароль root от сохранённых баз,
иначе новая установка в них не попадёт) и `/root/.acme.sh` (сертификаты Let's Encrypt, иначе новая
установка выпускает их заново и упирается в лимит 5 в неделю). Этап SSL при повторной установке
возвращает задание продления acme.sh. Базу панели `dbispconfig` от прошлой установки новая установка
не подхватывает: перед заменой она сохраняется в `/var/backups/luckystack-dbispconfig-*.sql.gz`.

Все вызовы apt ждут чужой apt до 10 минут (`/etc/apt/apt.conf.d/50luckystack-lock`,
`DPkg::Lock::Timeout`). Без этого на свежем сервере установка и удаление падали, если в ту же
секунду работали apt-daily или unattended-upgrades. Файл убирается при полном удалении.

---

## Управление swap

Ставится в этапе **preflight** (`lib/core.sh`, `_ensure_swap`) — защита от OOM (clamd, сборка) на малых VPS.

- **Когда создаётся:** `TUNE_SWAP=y` (по умолч.) и `/swapfile` ещё нет. В мастере вопрос всплывает,
  только если RAM < 4G и swap отсутствует. Размер — `TUNE_SWAP_SIZE` (1–16G, по умолч. 2G).
- **Что делает:** создаёт `/swapfile` (`fallocate`/`dd`), `mkswap`+`swapon`, ставит `vm.swappiness=10`,
  и дописывает в `/etc/fstab` с **маркером** `# luckystack-swap`.
- **Идемпотентность:** если `/swapfile` уже есть — `_ensure_swap` ничего не делает (**не меняет размер**).
  Чужой `/swapfile` без нашего маркера установщик не трогает и при удалении не сносит.
- **Удаление:** `_un_remove_swap` снимает `/swapfile` + строку fstab **только при нашем маркере** и
  только когда удаляется компонент `database` (разбор стека).

**Вручную:**
```bash
swapon --show ; free -h                       # текущее состояние
# изменить размер (установщик существующий swap НЕ ресайзит — делаем сами):
swapoff /swapfile && rm -f /swapfile
fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
# (строка в /etc/fstab уже есть с маркером # luckystack-swap — менять не нужно)
# удалить совсем:
swapoff /swapfile && rm -f /swapfile && sed -i '/# luckystack-swap/d; \|^/swapfile |d' /etc/fstab
# подкрутить swappiness (установщик уже ставит 10 персистентно в /etc/sysctl.d/99-luckystack-perf.conf):
sed -i 's/^vm.swappiness.*/vm.swappiness = 1/' /etc/sysctl.d/99-luckystack-perf.conf && sysctl --system
```

### Авто-оптимизация ядра/служб (по итогам аудита настроек)
- **Перф-sysctl** (`/etc/sysctl.d/99-luckystack-perf.conf`, этап preflight, персистентно):
  `vm.swappiness=10` (раньше ставился только в рантайме и сбрасывался после ребута — баг исправлен)
  + **TCP BBR** (`net.core.default_qdisc=fq` + `tcp_congestion_control=bbr`, если ядро поддерживает).
- **Redis** (`_redis_tune`): `maxmemory` = 15% RAM (256M–2G) + `maxmemory-policy noeviction` —
  предохранитель от раздувания/OOM на общей с БД машине. `noeviction` (а не *-lru) намеренно:
  Redis шарится с rspamd (bayes/fuzzy/history), вытеснение испортило бы антиспам.
- **MariaDB**: `innodb_buffer_pool_instances` больше НЕ задаётся (deprecated 10.5 / удалён 10.6 —
  на 12.x no-op + warning). `innodb_log_file_size` оставлен (в MariaDB актуален, это не MySQL'ный
  `innodb_redo_log_capacity`). buffer_pool 25/40/50% и `max_connections=vCPU*40` подтверждены адекватными.
- **nginx**: глобальный `ssl_session_cache shared:SSL:10m` + `ssl_session_timeout 1d` (меньше TLS-handshake).
- **PHP**: OPcache JIT (`tracing`, буфер 128M) включён осознанно (off-switch — `opcache.jit=off`).

---

## SSH-доступ и авторизация

Управляется ключами `SSH_HARDEN`, `SSH_PORT`, `SSH_ALLOW_IPS`, `SSH_PUBKEY` (этап **security**, `lib/security.sh`).

### Создание SSH-ключа и привязка к серверу

**Ключевое понимание (частая путаница):** пара ключей создаётся на **твоём компьютере (клиенте)**.
На сервер кладётся только **публичная** часть — в `/root/.ssh/authorized_keys`; именно этот файл
пускает тебя по ключу. Приватный ключ (`id_ed25519` без `.pub`) **никогда** не покидает клиент.
> ⚠️ `ssh-keygen`, запущенный **на сервере**, создаёт ключ для **исходящих** подключений (с сервера
> куда-то) и на вход по SSH **не влияет**. Для входа нужен именно твой клиентский публичный ключ в
> `authorized_keys` сервера.

**1. Создать пару ключей на клиенте** (один раз; если уже есть `id_ed25519` — пропусти):
```bash
# Linux / macOS:
ssh-keygen -t ed25519 -C "me@my-laptop"
# Enter — путь по умолчанию ~/.ssh/id_ed25519 ; passphrase по желанию
```
```powershell
# Windows 10/11 (PowerShell, OpenSSH встроен):
ssh-keygen -t ed25519 -C "me@windows"
# Enter — путь по умолчанию C:\Users\<Имя>\.ssh\id_ed25519
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub   # посмотреть публичный ключ
```
Создаются два файла рядом: `id_ed25519` — **приватный** (остаётся на ПК, никому не отдавать) и
`id_ed25519.pub` — **публичный** (его кладём на сервер на шаге 2).
Нет `ssh-keygen` в Windows? Включить *Параметры → Приложения → Доп. компоненты → OpenSSH Client*.

**2. Скопировать ПУБЛИЧНЫЙ ключ на сервер** (в `authorized_keys`):
```bash
# Linux / macOS:
ssh-copy-id -p <порт> root@<сервер>
# если ssh-copy-id нет — вручную:
cat ~/.ssh/id_ed25519.pub | ssh -p <порт> root@<сервер> 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```
```powershell
# Windows PowerShell (ssh-copy-id обычно отсутствует) — отдать .pub по конвейеру:
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh -p <порт> root@<сервер> "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```
(Пароль root спросят один раз — это последний вход по паролю перед переходом на ключ.)

**3. Проверить вход по ключу** (в новом окне, не закрывая текущее):
```bash
ssh -p <порт> root@<сервер>          # должен пустить без пароля
```

**4. Только убедившись, что ключ работает** — отключить пароль: поставить `SSH_HARDEN=y` в
`setup.conf` (этап security сделает это сам и безопасно — см. ниже), либо задать `SSH_PUBKEY` в
`setup.conf` ДО установки, чтобы ключ вписался автоматически перед отключением пароля.

### Что делает `SSH_HARDEN=y`
- **Всегда (безопасно):** `X11Forwarding no`, `MaxAuthTries 4`, `LoginGraceTime 30`.
- **Только если на сервере уже есть рабочий ключ** (`/root/.ssh/authorized_keys` непустой):
  `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `ChallengeResponseAuthentication no`,
  `PermitRootLogin prohibit-password` (root — **только по ключу**).
- Если ключа нет — пароль **НЕ** отключается (чтобы не потерять доступ), выводится предупреждение.
- Перед рестартом sshd — валидация `sshd -t`; при ошибке конфиг откатывается из `*.harden.bak`.
- `SSH_PUBKEY` — можно передать публичный ключ, он впишется в `authorized_keys` до отключения пароля.

### Важные предостережения
- ⚠️ **Uninstall/purge НЕ откатывают харденинг sshd.** После `--purge` сервер остаётся в режиме
  «только по ключу», если ставился с `SSH_HARDEN=y`. Симптом: вход по паролю отлетает с
  *«нет поддерживаемого метода авторизации»* (`no supported authentication method`).
- ⚠️ **`SSH_PORT` меняется в самом КОНЦЕ установки** (после всех этапов), чтобы обрыв/повтор не
  оставил сервер на нестандартном порту раньше времени. На время установки открыты и `22`, и `SSH_PORT`.
- ⚠️ **`SSH_ALLOW_IPS`** ограничивает вход по SSH указанными IP через UFW — ошибка/смена IP отрежет
  доступ, понадобится консоль VPS.
- Бэкап sshd-конфига до харденинга: `/etc/ssh/sshd_config.harden.bak`.

### Вернуть вход по паролю (если залочились на ключ)
Зайти по ключу (или через консоль VPS) и:
```bash
sed -i -E 's/^[#[:space:]]*PasswordAuthentication\b.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i -E 's/^[#[:space:]]*PermitRootLogin\b.*/PermitRootLogin yes/'               /etc/ssh/sshd_config
sed -i -E 's/^[#[:space:]]*KbdInteractiveAuthentication\b.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
# некоторые образы кладут override в drop-in:
grep -RIl -E 'PasswordAuthentication[[:space:]]+no' /etc/ssh/sshd_config.d/ 2>/dev/null \
  | xargs -r sed -i -E 's/^[#[:space:]]*PasswordAuthentication\b.*/PasswordAuthentication yes/'
sshd -t && { systemctl restart ssh || systemctl restart sshd; }   # валидация ДО рестарта
passwd -S root    # убедиться, что у root задан пароль (статус P), иначе passwd root
```
Проверить итог: `sshd -T | grep -Ei 'passwordauthentication|permitrootlogin'`.

> ⚠️ Это **ослабляет** SSH (пароль + root-логин наружу). Вернуть key-only — заменить `yes` на `no`
> (`PermitRootLogin prohibit-password`), `sshd -t`, рестарт. Или восстановить `sshd_config.harden.bak`.

### Вход только по ключу (рекомендуется)
Положить публичный ключ в `/root/.ssh/authorized_keys` (или задать `SSH_PUBKEY` в `setup.conf`) и
оставить `SSH_HARDEN=y`. Тогда пароль отключён, root — по ключу, brute-force по SSH невозможен.

---

## Анти-malware (этап 23, `lib/malware.sh`)
Опциональный этап `malware` (`MALWARE_SCAN=y`, по умолч. y) ставит **rkhunter** (apt — rootkit/
integrity) и **Linux Malware Detect / LMD (maldet)** из upstream-тарбола rfxn.com (веб-шеллы и malware
в `/var/www`), плюс **ежедневный скан с уведомлением** администратору ТОЛЬКО при находках.
- **Обёртка** `/usr/local/sbin/ss-malware-scan [пути]` гоняет три движка и шлёт алерт через
  `/usr/local/sbin/server-notify.sh` (email/Telegram из `lib/notify.sh`), а находки всегда пишет в
  `/var/log/ss-malware-scan.log` (даже если уведомления не настроены). Запуск — `systemd`-таймер
  `ss-malware-scan.timer` (по умолч. `MALWARE_SCAN_TIME=03:30`, `Persistent`, idle-IO). Штатные cron
  rkhunter (`CRON_DAILY_RUN=false`) и LMD (`/etc/cron.daily/maldet` снят с +x) отключены — чтобы скан
  был один и с нашим алертом.
- **Три движка, каждый по делу:** (1) **LMD** — своими сигнатурами на веб-шеллы (`maldet -a <пути>`);
  (2) **ClamAV** — известное malware **через `clamdscan --fdpass --multiscan --infected`**: важный нюанс —
  штатная интеграция LMD↔clamd гоняет демон под пользователем `clamav`, который не может читать файлы
  сайтов → даёт ложные `0 hits` (проверено на проде: EICAR не виден). Поэтому `scan_clamscan="0"` в
  `conf.maldet`, а ClamAV мы вызываем сами с `--fdpass` (root открывает дескриптор, демон сканит
  содержимое) — E2E: EICAR детектируется (`Infected files: 1`); (3) **rkhunter** —
  `--cronjob --report-warnings-only` (rootkit/целостность).
- **Карантин:** по умолчанию `MALWARE_QUARANTINE=n` — только алерт (не трогаем легитимные файлы сайтов);
  `=y` включает `quarantine_hits/clean=1` в LMD. `MALWARE_PATHS` (по умолч. `/var/www`) — что сканировать.
  `MALWARE_PATHS` / `MALWARE_SCAN_TIME` / `MALWARE_QUARANTINE` / `MALWARE_CLAMAV` **спрашиваются в мастере**
  (если выбран компонент `malware`); ClamAV-движок предлагается только когда ClamAV ставится (часть rspamd).
- **Юнит не «failed» на находках:** сканер возвращает `exit 1`, когда что-то найдено (rkhunter почти
  всегда даёт пару warning'ов) — это сигнал «есть находки» (алерт уже ушёл), а не сбой. В `.service`
  стоит `SuccessExitStatus=1`, иначе systemd красит юнит в `failed` (ложная тревога в статусе).
- Установка устойчива: если rfxn.com недоступен — продолжаем с rkhunter (и ClamAV), без LMD; если не
  встало ничего — этап пропускается с предупреждением. E2E на живом сервере: EICAR/rkhunter-warnings →
  `exit 1` + строки в логе; полный скан `/var/www` → 0 заражений.

## Сверка с гайдом Perfect Server
Установщик построчно сверен с эталонным гайдом howtoforge (что реализовано, что
делегировано ISPConfig, что намеренно пропущено). Ключевые добавки паритета: история Rspamd в Redis (`history_redis.conf`), отключение дефолтного cron awstats,
базовый jail fail2ban в `jail.d/` (всегда применяется), `LimitNOFILE=65535` для
mariadb/postfix/dovecot (systemd-override + `limits.conf`), журналируемые квоты
(`usrjquota/grpjquota,jqfmt=vfsv0`) с предохранителями (контейнер/тип ФС/бэкап fstab).

## Заметки
- **Генеральная репетиция на копии прода (ноябрь 2026).** Чистый Debian 12 + установщик cf8aae6 + ISPConfig develop
  25d25c39 (все 224 стандартных PHP-файла совпали с продом по md5) + setup.conf прода, затем новый установщик и полный
  `--update`. Найдено и исправлено:
  - Шаг `--update` падал целиком: `${NOTIFY_EMAIL%%,*}` при незаданной переменной и `set -u` завершал процесс, и сервер
    оставался с новым ISPConfig без патчей. Исправлены такие обращения (`NOTIFY_EMAIL`, `SSH_CLIENT`/`SSH_CONNECTION` в
    `_detect_ssh_ip` — они падали бы из cron, консоли и под sudo, `BACKUP_REMOTE`). `_upd_run` теперь выполняет шаг в
    подоболочке: сбой одного шага не обрывает остальные, в конце выводится список неудавшихся. Патчи накладываются и после
    неудачной попытки обновить ISPConfig.
  - ufw с `ENABLED=no`: штатный firewall_plugin ISPConfig при установке вызывает `ufw --force disable`. Правила остаются в
    ядре, `ufw status` пишет active, но `ufw reload` молча пропускается: новые правила не применяются, а после перезагрузки
    фаервола нет. `_ufw_ensure_enabled` (после этапа ISPConfig, в `--update` дважды) включает ufw, если адрес админа
    не окажется отрезан; плагин Firewall IP-rules проверяет и `ENABLED`; `--healthcheck` и монитор сообщают о таком состоянии.
    Прод в этом состоянии не был (`ENABLED=yes`).
  - `umask 022` в начале `server-setup.sh`: при umask 077 в профиле root ключ репозитория выходил 600, apt его не читал, и
    установка падала на этапе PHP, а конфиги и исходники становились закрытыми для служб.
  - Дубль адреса админа в правилах панели и базовом блоке.
  - Итог: схема БД 104 → 107, исправления 3.3.2p1 есть, nginx с OpenSSL 3.6.5, Roundcube 1.6.5 → 1.6.20, PHP 8.5 убрана.
    252 проверки без провалов (патчи 34, панели 32, SSH/система 38, почта/PHP 50, ISPConfig 21, вебмейл 13, переезд 25,
    фаервол 13, заморозка 10 и 16), письмо через вебмейл доставлено. После перезагрузки фаервол, sysctl, службы и панель на месте.
- **Обновление ISPConfig и порядок `--update` (шаг 4, ноябрь 2026).**
  - Порядок: раньше ядро (пересборка nginx и апдейтер ISPConfig) шло последним, после наших патчей, и апдейтер
    их затирал. На тестовом голый апдейтер снёс 14 вещей: все пункты меню наших панелей, тёмную тему, форму
    заморозки и строку в ids.whitelist, «панель только по FQDN» (панель снова открывалась по IP), ограничение
    phpMyAdmin в apps-vhost, include sni.conf в dovecot.conf и security_settings.ini (IDS для admin). Теперь шаг 1.5:
    пакеты → ядро (ISPConfig, затем nginx) → сверка conf-custom → все патчи. Если ISPConfig обновлялся, в набор
    принудительно добавляются security, confcustom, mail, certs, rcplugins.
  - `_update_ispconfig` без вопросов: `ispconfig_update.sh --update-source=<ветка> --autoinstall=<ini>` с секцией
    [update]: do_backup=yes, reconfigure_services=yes, create_new_ispconfig_ssl_cert=no (иначе заменит LE-
    сертификат), create_ssl_server_certs=n, симлинки Postfix/PureFTPd сохраняются, ispconfig_port — из
    ispconfig.vhost, пароль root — из /root/.my.cnf. ini под umask 077 и удаляется сразу. Ветка — `ISPCONFIG_BRANCH`,
    а если не задана, по текущей версии (`*dev` → nightly). Журнал `/var/log/luckystack/ispconfig-update.log`.
    Успех = код 0 и страница входа панели отвечает 200. `ISPC_UPDATE_INTERACTIVE=y` — старый режим с вопросами.
  - conf-custom: копии шаблонов делались один раз и после обновления ISPConfig оставались от старой версии.
    `_ispconfig_confcustom_record` запоминает sha256 стандартного шаблона (`conf-custom/.luckystack-stock.sha256`)
    до обновления; `_ispconfig_confcustom_refresh` после него при изменении: бэкап копии в
    `conf-custom/.luckystack-backup/`, свежий стандартный шаблон, заново наши правки (усиление при наличии
    deny-secrets, журнал CrowdSec, удаление устаревших заголовков, http2 мастеров панели/apps, ограничение
    phpMyAdmin). Существующие vhost сайтов переходят на новый шаблон после Tools → Resync (или сохранения сайта).
  - `UPDATE_ITEMS="pkgs security … nginx ispconfig"` — набор пунктов `--update` без вопросов (cron, проверки).
  - `--status`: есть ли исправления безопасности 3.3.2p1 (#7051 SQLi в Remote API, #7052, #7044). Тег 3.3.2p1 —
    слияние в develop 2026-09-21, поэтому nightly после этой даты их содержит; признак — проверка ID в
    remoting.inc.php. Прод на nightly от 2026-07-02 (dbversion 104) их не содержит, тестовый (25.10, 107) — да.
  - Проверено на тестовом: голый апдейтер (ничего не спросил, панель жива, LE-сертификат на месте) → 20/34
    патчей; полный `--update` с ispconfig и подменённым хешем шаблона → conf-custom пересобран (все метки как
    были), 34/34; повтор всех наборов: панели 32, SSH/система 38, почта/PHP 50, ISPConfig 21, вебмейл 13 +
    отправка письма, заморозка 10 и 16, фаервол 13.
- **ISPConfig и проверки (шаг 3, ноябрь 2026).**
  - `_ispconfig_security_settings` (конец этапа ISPConfig и `--update`), меняет только заводские значения:
    `sys_ini` session_timeout=0 (сессия панели не истекала) → 60, min_password_length < 12 → 12;
    `security_settings.ini`: security_admin_email root@localhost → первый адрес `NOTIFY_EMAIL`,
    warn_passwd_change=yes, ids_admin_enabled=yes (`ISPC_IDS_ADMIN=n` — оставить выкл.). Поля, куда админ пишет
    директивы (nginx/apache/php.ini/open_basedir) и наше поле заморозки, уже в ids.whitelist; наши панели с
    IDS для admin проходят тест 32/32.
  - Бэкапы. Сайты удобнее бэкапить средствами ISPConfig (по сайту, ротация, восстановление из панели):
    `_ispconfig_site_backups` в `--update` спрашивает и включает daily + `ISPC_SITE_BACKUP_COPIES` (3) у сайтов с
    backup_interval=none, показывая размер /var/www и свободное место; без терминала только подсказка. Почта в
    серверном бэкапе теперь по умолчанию «да» (обычно маленькая). `server-backup.sh` перед архивом сайтов и
    почты проверяет место (размер исходника + 1 ГБ), иначе пропускает с ошибкой и уведомлением.
  - `--healthcheck`, блок «Безопасность и бэкапы»: нужна перезагрузка, вход в SSH по паролю, X11/агент в SSH,
    уведомления не настроены, файлы в /etc с записью для всех, таймер серверного бэкапа, нет оффсайта, почта не
    в бэкапе, сайты без бэкапа.
  - `ispserver.pem` и `monit.pem` (там приватный ключ) пишутся под umask 077 (pem через .new + mv): раньше файл
    на мгновение создавался 644, а потом получал 600.
  - `mv_keep` (core.sh): «awk … > f.new && mv f.new f» в 20 местах (vhost панели, conf-custom мастера, fstab,
    before.rules…) теперь сохраняет владельца и права заменяемого файла, а не ставит root:root 644 по umask.
  - Проверено на тестовом сервере: 21/21 (mv_keep, pem и umask по strace, бэкапы сайтов: подсказка без tty,
    включение, настоящий прогон бэкапа ISPConfig — архив сайта создан и виден в панели; проверка места на
    tmpfs 8 МБ; новые пункты healthcheck) + повтор прошлых наборов: SSH/система 38, панели 32, вебмейл 11.
- **SSH и система (шаг 3, ноябрь 2026).**
  - SSH: прежний `apply_ssh_hardening` правил основной `sshd_config`, а sshd берёт первое значение параметра, и
    любой drop-in выше по порядку (cloud-init) его перебивал; запускался только в конце установки и только при
    `SSH_HARDEN=y` (на проде было n — X11, проброс агента и TCP оставались включены). Теперь `apply_ssh_safe`
    (установка и `--update`) пишет `sshd_config.d/10-luckystack-harden.conf`, проверяет `sshd -t` и что каждое
    значение реально действует по `sshd -T`, иначе откат; затем reload (сессии не рвутся). Вход по паролю не
    трогается: его выключает только `SSH_HARDEN=y` и только при наличии ключа. Ключи с опциями в authorized_keys
    (`from="…" ssh-ed25519 …`) теперь распознаются. MaxAuthTries не уменьшается: при многих ключах в агенте клиент
    не дошёл бы до пароля. Откат анти-локаута и `--uninstall` удаляют и этот drop-in.
  - sysctl (`90-luckystack-hardening.conf`): kptr_restrict=2, dmesg_restrict=1, yama.ptrace_scope=1,
    protected_fifos=2, protected_regular=2, suid_dumpable=0, bpf_jit_harden=2, ldisc_autoload=0, sysrq=0.
    `/usr/lib/sysctl.d/99-protect-links.conf` (protected_fifos=1) идёт по алфавиту после нашего и перебивал его —
    кладётся одноимённый `/etc/sysctl.d/99-protect-links.conf`. `SEC_USERNS_OFF=y` (вопрос в мастере, по умолчанию
    нет) — `kernel.unprivileged_userns_clone=0` отдельным файлом; при выключении значение возвращается.
  - Автообновления: кроме Debian-security — sury, MariaDB, Rspamd, CrowdSec, NodeSource (`53luckystack-
    unattended-3rd`). Неверсионные метапакеты `php-*` в Package-Blacklist: когда sury меняет версию PHP по
    умолчанию, их обновление притянуло бы целую новую версию (`php-common` не в списке — от него зависят
    `php8.x-common`). Отчёт на почту (`NOTIFY_EMAIL`, иначе root) только при ошибках. needrestart с
    `$nrconf{restart}='a'` перезапускает службы после обновления библиотек.
  - Журнал systemd: `journald.conf.d/50-luckystack.conf` SystemMaxUse=500M (`JOURNAL_MAX`) + vacuum (на проде было 4 ГБ).
  - rkhunter (если стоит): `APT_AUTOGEN="true"` — база свойств файлов обновляется после каждого apt (ложные
    тревоги на проде после обновлений curl/perl), и `--propupd` сразу.
  - AIDE (`SEC_AIDE=y`): исключены /var/www, почта, БД, журналы, кэши; первая база строится в фоне
    (`/var/log/aide-init.log`), дальше ежедневный cron пакета.
  - Проверено на тестовом сервере: 38/38 (значения `sshd -T`, пароль по-прежнему предлагается, новое соединение
    по ключу; все sysctl; dry-run unattended-upgrade видит все источники и чёрный список; needrestart; журнал;
    rkhunter; повторный прогон тихий), user namespaces вкл/выкл.
- **Roundcube с сайта разработчиков и плагины ISPConfig (шаг 3, ноябрь 2026).**
  - Зачем: в bookworm у пакета Roundcube 1.6.5 на 2026-11-05 открыты 20 уязвимостей (исправлены у разработчиков
    в 1.6.20 / 1.7.5, в trixie и sid тоже). Источник выбирается в мастере (`RC_SOURCE`, `RC_BRANCH`).
  - Установка (`lib/webmail.sh`, `_rcu_*`): архив «complete» с GitHub-релизов, подпись `.asc` проверяется `gpgv`
    ключом `assets/roundcube/signing-key.asc` с закреплённым отпечатком `F3E4C04BB3DB5D4215C45F7F5AB2BAA141C4F7D5`
    (сверен по roundcube.net, keyserver.ubuntu.com и debian/upstream/signing-key.asc пакета Debian). Без сети
    версия берётся из пина `RC_FALLBACK_1_6/1_7`. Код root, `config.inc.php` и конфиги плагинов `root:www-data 640`,
    `temp` у www-data, `installer/` и `public_html/installer.php` удаляются, журналы в `/var/log/roundcube`.
  - Раздача: `/var/www/html/roundcube` → `/opt/roundcube/public_html`, плюс сниппет
    `snippets/default-locations/roundcube.conf` (alias на public_html, PHP только для файлов корня public_html и с
    PATH_INFO, статика из skins/plugins/program/js только по расширениям, остальное в подкаталогах deny). Это
    обязательно для 1.7: там корнем должна быть public_html, а картинки и стили идут через `static.php/<путь>`;
    с прежней раздачей 1.7 отвечала «configure your HTTP server to point to /public_html». В 1.6 public_html/plugins —
    симлинк на код, поэтому без белого списка nginx отдал бы исходник конфига плагина с паролем API.
  - Обновление (`_rcu_update`, шаг `--update`): последняя версия ветки → проверка подписи → дамп БД
    (`/var/backups/roundcube`, 3 последних) → копия каталога → штатный `bin/installto.sh -y` на копии → подмена
    каталога. `installto.sh` завершается успехом, даже если упало обновление схемы, поэтому вывод проверяется на
    `[FAILED]`/`ERROR`. Если страница входа не открылась — возвращается прежний каталог, и если схема БД
    изменилась (версия в `system` + таблицы и число колонок), БД возвращается из дампа; перед заливкой удаляются
    все таблицы, иначе новая таблица (`uploads` из 1.7) ломала следующую попытку. Смена ветки 1.6 → 1.7 — тот же путь.
  - Переезд с пакета Debian (`_rcu_migrate_debian`; в `--update` спрашивает, без tty — только подсказка):
    итоговый `$config` пакета (с debian-db*.php) выгружается в один файл, `des_key` тот же (сессии и сохранённые
    пароли не ломаются), нестандартные плагины копируются, `bin/update.sh --version=<пакет>`, проверка страницы
    входа; не открылась — симлинк обратно на пакет. Пакеты удаляются `apt-get remove` (не purge, БД не трогается).
  - Монитор раз в сутки сверяет версию с GitHub и один раз на версию шлёт «Roundcube: вышла версия X».
  - Плагины ISPConfig в вебмейле (w2c) не работали вообще, четыре независимые причины (на проде все четыре):
    1) конфиг писал `remote_soap_url`/`remote_soap_password`, а плагины читают `soap_url`/`remote_soap_pass` — брали
    адрес-заглушку из .dist и висели 60 с до 504; 2) адрес `https://127.0.0.1:<порт>/remote/` при «панель только по
    FQDN» получает 444 — теперь FQDN (`_rc_soap_url`); 3) у пользователя API в `remote_functions` были названия
    групп, а ISPConfig сверяет точные имена функций (`checkPerm`: in_array) — ни одного права; теперь штатный набор
    «Roundcube plugins functions»; 4) конфиги плагинов `root:root 640` (группа бралась от каталога plugins) — веб-
    процесс их не читал. `_rc_fix_plugin_perms` в `--update` чинит все четыре на установленных серверах.
  - SMTP: пакет Debian ставит `smtp_host = 'localhost:587'` без шифрования, а 587 требует STARTTLS — отправка из
    вебмейла не работала. `_rcu_fix_smtp` (переезд, ставка из пакета, `--update`) меняет на `tls://<FQDN>:587`;
    если сертификат на FQDN не проходит проверку — с `smtp_conn_options` без проверки (соединение локальное).
  - fail2ban `roundcube-auth` с backend=systemd не читал ничего (Roundcube пишет в файл) — теперь `backend = auto`,
    `logpath = /var/log/roundcube/errors.log`, плюс `filter.d/roundcube-auth.local` с вариантом строки
    «(X-Forwarded-For: …)»: штатный фильтр её не ловил, и бан обходился этим заголовком; IP берётся из адреса соединения.
  - Пакет Debian (если оставлен) раздаётся каталогом, поэтому `roundcube-deny.conf` закрывает logs/, SQL/, config/,
    program/include… — до этого `https://<FQDN>/roundcube/logs/errors.log` отдавался всем.
  - На apps-порту `/roundcube` и `/webmail` теперь перенаправляют на `https://<FQDN>/roundcube/`: пул apps работает от
    ispapps и не может прочитать конфиг Roundcube.
  - Проверено на тестовом сервере: переезд 1.6.5 → 1.6.19 → обновление до 1.6.20 → 1.7.5 (вход, 7 страниц плагинов,
    смена пароля через плагин до Dovecot, отправка письма), откат с возвратом БД, свежая установка + этап плагинов,
    полный сценарий прода с нуля (до: плагины и отправка не работают; после: 25/25 + письмо доставлено).
- **Почта, FTP, PHP, часовой пояс (шаг 3, ноябрь 2026).**
  - Часовой пояс: PHP раньше работал в UTC, а система и MariaDB в поясе сервера (истечения, посчитанные в PHP,
    расходились с БД на 3 часа). Этап PHP пишет `date.timezone` для всех версий, `--update` выравнивает его по
    системе (`_tz_php_sync`) и заодно чинит устаревший `/etc/timezone` (timedatectl меняет только `/etc/localtime`).
    Смена пояса целиком: `--timezone` или пункт меню.
  - PHP: `assets/php/security.ini` кладётся как `98-luckystack-security.ini` во все версии (FPM, CLI, CGI):
    `expose_php=Off`, `session.cookie_httponly`, `use_strict_mode`, `use_only_cookies`,
    `session.upload_progress.enabled=0` (им пользуются при эксплуатации LFI), `opcache.validate_permission` и
    `validate_root` (OPcache общий у всех пулов версии). Сайту любое значение можно вернуть в его php.ini в панели.
    SameSite глобально не ставим: ломает возврат POST с платёжных шлюзов.
  - Откуда бралась PHP 8.5: phpmyadmin рекомендует php-tcpdf, тот рекомендует php-mcrypt, а php-mcrypt из sury
    зависит от самой новой PHP. phpMyAdmin теперь ставится без рекомендуемых (`APT_NO_RECOMMENDS=1 apt_install`,
    php-tcpdf явно). Уже притянутую версию убирает `_php_drop_stray` (и в `--update`): только если её нет в
    `PHP_VERSIONS`, у неё нет PHP-FPM и `php` указывает не на неё; сначала `apt-get -s purge`, и если apt заодно
    снёс бы что-то кроме `phpX.Y-*`/php-mcrypt (например phpmyadmin) — версия остаётся с предупреждением.
  - OPcache: при включённом авто-тюнинге размер кэша задаёт `99-zz-luckystack-tuning.ini` (по RAM), он грузится
    после `99-opcache-jit.ini`. Об этом теперь написано в шапке `assets/php/opcache.ini`.
  - Почта, пароль только поверх TLS (`_mail_auth_tls_only`, этап maildeliver и `--update`): Postfix
    `smtpd_tls_auth_only=yes` (на 25 AUTH только после STARTTLS); Dovecot 2.3 `disable_plaintext_auth=yes`, 2.4
    `auth_allow_cleartext=no`. Dovecot-строка пишется блоком с маркерами в `conf.d/99-ispconfig-custom-config.conf`
    (его подключает dovecot.conf ISPConfig) и в мастер `conf-custom/install/dovecot_custom.conf.master`, проверка
    `doveconf -n` с откатом. С localhost Dovecot пускает как раньше, Roundcube (localhost:143) работает. Проверять
    надо с другой машины: подключение с самого сервера на его внешний IP Dovecot тоже считает защищённым.
  - FTP: `TLS=2`, вход только по FTPS (`FTP_TLS_REQUIRED=n` возвращает `TLS=1`). `_ftp_tls_mode` вызывается в
    этапе ftp, ещё раз после установки ISPConfig и в `--update`; без `/etc/ssl/private/pure-ftpd.pem` не включает.
  - Проверено на тестовом сервере: 50/50 проверок (значения PHP во всех FPM, 8.5 удалена при живом phpMyAdmin,
    IMAP/POP3 снаружи отвечают LOGINDISABLED / PRIVACYREQUIRED, 25 без TLS не предлагает AUTH, FTP без TLS — 421,
    FTPS работает), повторный прогон ничего не меняет.
- **Сборка nginx и загрузки (шаг 3, ноябрь 2026).**
  - Версии: nginx берётся с nginx.org (последний stable/mainline), OpenSSL — последний выпуск ветки `OPENSSL_BRANCH`
    с GitHub, PCRE2 — последний с GitHub (`_nginx_autoset_deps`). Пин в setup.conf уважается, без сети —
    фолбэк в шапке `lib/nginx.sh` (на 2026-11-05: nginx 1.30.6/1.31.8, OpenSSL 3.5.9/4.1.0/4.0.3, PCRE2 10.49, libmaxminddb 1.14.1).
  - Пересборка больше не оставляет старое: OpenSSL пропускается только если `quictls/.openssl/.ss-version` совпадает
    с нужной версией (раньше хватало наличия `libssl.a`, и на проде так и стоял 3.6.3), git-модули обновляются
    (`_ngx_clone`: fetch + reset), brotli пересобирается при смене коммита (`out/.ss-rev`).
  - libmaxminddb с 1.14 требует `pkg-config`, он теперь в зависимостях сборки. Если библиотека всё же не собралась:
    при уже установленной версии будет предупреждение и сборка с ней, без установленной сборка nginx останавливается.
  - Патчи nginx (`use_openssl_md5_sha1`, `nginx_zlib-ng`) лежат в `assets/nginx/patches`, проверенные копии с
    указанием источника и sha256. Раньше они качались с master чужих репозиториев при каждой сборке во временные
    файлы `/tmp` с постоянными именами.
  - Плагины Roundcube — с закреплённого коммита `RCPLUGINS_COMMIT` и сверкой `RCPLUGINS_SHA256`; не совпало —
    не ставятся.
  - Архив ISPConfig: уже лежащий `/tmp/ispconfig.tar.gz` берётся, только если он принадлежит root и другие не
    могут его менять, иначе удаляется до скачивания; каталог распаковки создаётся атомарно (`mkdir -m 700` без
    `-p`), при гонке установка прерывается. `ISPC_LOCAL_TARBALL` по-прежнему принимается.
  - Заголовки X-XSS-Protection и Expect-CT убраны (браузеры их не поддерживают, первый давал XS-Leak):
    из `assets/nginx/nginx.conf`, примеров в `security-headers.conf` и списка заголовков conf-custom. На
    установленных серверах их убирает `_nginx_drop_legacy_headers` в `--update` (nginx.conf, conf-custom шаблон,
    готовые vhost; nginx -t с откатом; замороженные сайты забираются в базу).
- **Фаервол и доступ (шаг 3, ноябрь 2026).**
  - Базовый блок `restrict` в `before.rules` пишется на этапе security, ещё до панели. Раньше он оставался
    навсегда и перехватывал правила панели (его «udp <порт панели> ACCEPT всем» срабатывал раньше ограничения
    панели по IP). Теперь `_security_ufw_restrict_persist` вызывается и в конце установки модуля «Firewall
    IP-rules» и снимает базовый блок, когда блок панели `restrict-isp` уже записан. Пустую рамку из маркеров не пишет.
  - UDP панели (HTTP/3) открывается только админским IP, как TCP; прежнее «UDP панели всем» удаляется.
    UDP apps-порта открыт всем, как и его TCP (webmail для пользователей).
  - phpMyAdmin: файл `snippets/default-locations/dbadmin-restrict.conf` раньше не подключал ни один vhost, и
    phpMyAdmin был открыт всем. Теперь его подключает vhost домена (`hostcert.sh`), а в apps-vhost ISPConfig внутри
    `location /phpmyadmin` подключается `snippets/dbadmin-acl.conf` (при `DBADMIN_FQDN_ONLY=y` там `deny all`, иначе
    allow по `DBADMIN_ALLOW_IPS`) — в живом файле и в conf-custom мастере. В конце этапа ISPConfig ограничение
    применяется ещё раз (на этапе phpmyadmin apps-vhost ещё не было).
  - 3306 следует за галочкой Remote access: плагин фаервола подписан на `database_insert/update/delete` и
    дописывает к правилу 3306 IP баз с Remote access (нет правила — создаёт). У базы пустой список IP = 3306
    открыт всем (ISPConfig в этом случае выдаёт доступ с `%`); монитор присылает об этом предупреждение.
  - Подбор пароля: fail2ban `mysqld-auth` по журналу MariaDB (встроенные разборщики CrowdSec формат MariaDB 12
    не понимают) и свой jail `ispconfig-auth` по `/var/log/ispconfig/auth.log` (5 неудач за 10 минут). jail
    панели включается, когда лог уже есть, поэтому настройка jail’ов повторяется в конце этапа ISPConfig.
  - `skip-name-resolve` у MariaDB сознательно НЕ включаем: все пользователи баз заведены как `@localhost`, и
    сайты, которые ходят к базе по `127.0.0.1` (Laravel по умолчанию), перестали бы проходить авторизацию.
  - Тест на тестовом сервере 13/13 + 3306 с Remote access через Remote API.
- **Уведомления (lib/notify.sh).** Конфиг `/etc/server-notify.conf` (600): `NOTIFY_EMAIL` (несколько через
  запятую), `NOTIFY_TG_TOKEN`, `NOTIFY_TG_CHATS` (несколько через пробел, старый `NOTIFY_TG_CHAT` тоже читается),
  `NOTIFY_EVENTS` (monitor backup malware login digest), `NOTIFY_LOGIN_MODE` (new|all), `NOTIFY_QUIET`
  (`23:00-08:00`: в Telegram без звука, кроме `-l crit`), `MON_*` пороги, `NOTIFY_TG_BOT` (y|n), `NOTIFY_TG_API`
  (адрес Telegram API, для тестов). `apply_notifications` (финал установки и `--update`) ставит helper, монитор,
  таймер, службу входов и бота ВСЕГДА, а конфиг дописывает: что настроено в панели, не затирается. Токен без chat
  id даёт предупреждение. `server-notify.sh [-e событие] [-l info|warn|crit] тема тело`: выключенное событие не
  шлётся. `server-monitor.sh` (08:00): диск, сертификат хоста, все включённые службы (включая все PHP-FPM, CrowdSec,
  fail2ban, ClamAV), свежесть бэкапа по каталогам снимков, нужна ли перезагрузка; при `digest` — ежедневная сводка.
  Панель System → Дополнения → Notifications: всё это плюс кнопка «Найти chat id» (getUpdates без подтверждения, а при
  работающем боте — его список `/var/lib/server-notify/chats.json`). Тест на тестовом сервере 23/23 (Telegram —
  заглушка `tg-mock.php`).
- **Оповещения о входах.** Служба `server-login-watch` читает журнал sshd (`journalctl -f _COMM=sshd _COMM=sshd-session`, на Debian 13 входы пишет `sshd-session`) и
  `/var/log/ispconfig/auth.log` (`tail -F`), PAM и sshd_config не трогает. Сообщает о входе в панель и по SSH
  (режим new — только с IP, которого не было 180 дней, all — каждый, повтор за 10 минут не дублируется), с именем
  SSH-ключа из `authorized_keys`, обратным DNS и пометкой доверенного IP; 5 неудачных входов в панель с IP за 10
  минут — «подбор пароля» (не чаще раза в час на IP). При первом запуске входы за 30 дней считаются известными.
  Журнал входов `/var/log/server-login-watch.log`, известные IP `/var/lib/server-notify/known-logins`.
- **Управление из Telegram.** Служба `server-tg-bot` (`assets/notify/server-tg-bot.php`, от root) работает только
  при `NOTIFY_TG_BOT=y` (галочка в панели). Команды: `/status`, `/bans`, `/check IP`, `/unban IP`, `/allow IP
  [часы]`, `/backup`. Shell нет. Командовать может только пользователь, чей личный chat id есть в `NOTIFY_TG_CHATS`
  (проверяется `from.id`, в группе посторонний ничего не сделает). `/unban`, `/allow`, `/backup` — только после
  кнопки «Подтвердить» (2 минуты, только тот, кто вызвал). Незнакомцу на `/start` бот отвечает только его chat id.
  Действия пишутся в `ss_panel_audit` (панель `telegram`). Тест 23/23 на заглушке Telegram.
- **Заморозка vhost: правки прямо в файле не теряются.** Раньше при сохранении сайта или Resync генератор
  ISPConfig перезаписывал файл по шаблону, а `zzz_freeze_vhost_plugin` клал поверх текст из базы, и правки,
  сделанные прямо в `/etc/nginx/sites-available/<домен>.vhost`, пропадали. Теперь плагин
  `aaa_freeze_vhost_capture_plugin` (грузится по имени раньше `nginx_plugin`) на `web_domain_update` смотрит на файл
  до генерации: если он отличается от последнего применённого (копия `/etc/nginx/sites-frozen/<домен>.vhost`),
  текст файла забирается в базу и применяется. Если в том же сохранении поменяли и текст в панели, побеждает
  панель, ручная версия файла сохраняется в `<копия>.manual-<время>`, в статусе предупреждение. При включении
  заморозки снимком становится текущий файл, а не свежесгенерированный. Каждая заменённая версия кладётся в
  `<копия>.prev-<время>` (последние 10), так что ничего не пропадает молча при любом порядке событий. Страница
  «Заморозка: статус и diff» показывает расхождение файла с базой, текст файла и кнопку «Забрать правки из
  файла». Установщик запускает `ss-freeze-drift.php` (забрать расхождения всех замороженных сайтов в базу,
  файлы и nginx не трогает) при развёртывании заморозки, в `--update` и после того, как сам правит vhost
  (миграция пути CrowdSec-лога). Тест на тестовом сервере 16/16, три прогона подряд.
- **Заморозка vhost: поля пишет только админ.** Сырой vhost пишется на диск от root, поэтому поля
  `freeze_vhost`/`freeze_vhost_content` больше не кладутся в tform сайта: по tform работают обычное сохранение
  формы (вкладку Options видит и реселлер при `reseller_can_use_options`) и Remote API (он выставляет себе
  typ=admin). Поля пишет только патч контроллера `web_vhost_domain_edit.php` в `onAfterUpdate` (маркер
  `ss_fz_write`), только для админа и только если форма пришла с вкладки Options (`ss_fz_present`). Блок на
  вкладке рисуется по `ss_fz_admin` из того же патча (`onShowEnd`), так что если патч не встал, функции нет, а
  дыры нет. Старые установки мигрируют: поля удаляются из tform, старый блок шаблона заменяется. Серверный
  плагин дополнительно проверяет автора изменения текста по `sys_datalog` (должен быть пользователь панели с
  typ=admin), иначе оставляет прежний текст и пишет в статус «отклонено». Сквозной тест на тестовом сервере
  10/10: Remote API не может записать vhost, админ через панель может, подложенное изменение от не-админа
  отклоняется.
- **Firewall IP-rules: проверка на стороне сервера.** Плагин сам проверяет каждый IP/подсеть и порт из БД
  (`valid_ip_or_cidr`, `valid_port`), мусор пропускает с записью в лог. Раньше одна плохая запись (пришедшая
  мимо формы) роняла `iptables-restore` на всём `before.rules`. Подсети шире /8 (IPv4) и /16 (IPv6) не
  принимаются ни формой, ни плагином: «открыть всем» делается галочкой. Кнопка «Заполнить по умолчанию» берёт
  порты SSH из `sshd_config` и `sshd_config.d/*.conf` (раньше был жёстко 22).
- **Действия в наших панелях ISPConfig только POST с CSRF-токеном.** Раньше кнопки панелей были обычными
  GET-ссылками (`?do=ban&ip=...`), и чужая страница могла выполнить их от имени залогиненного админа
  (поставить пакет `npm -g` от root, отправить бэкапы на чужой сервер, выключить правило SSH). Теперь общий
  файл `assets/ispconfig/common/ss_panel.inc.php` (ставится в `interface/lib/`, функция
  `_ispconfig_deploy_panel_common` в начале каждой панели) даёт: `ss_is_action()` принимает действие только
  POST-запросом с одноразовым токеном ISPConfig (`csrf_token_get`/`csrf_token_check`, как у её собственных форм),
  `ss_action_form()` рисует скрытую форму с токеном и JS `ssAct(url, params, confirm)` (отправка через
  `ISPConfig.submitForm`), `ss_audit()` пишет каждое действие в таблицу `ss_panel_audit` (время, логин, IP,
  панель, действие, детали). GET теперь только показывает страницу. Так переделаны fail2ban, CrowdSec,
  блок-лист ufw, уведомления, бэкап, Node.js/Composer, кнопки списка Firewall IP-rules (заполнить, применить,
  массово вкл/выкл; токен в шаблон списка через `onShow`) и страница заморозки vhost. Удаление и сохранение
  правил фаервола и так защищены токеном средствами ISPConfig. Проверено curl-тестом на тестовом сервере:
  старые GET-ссылки ничего не делают, POST без токена и с повторным токеном блокируются.
- **Имя пакета в панели Node.js/Composer** проверяется по реестру: npm `name` или `@scope/name` (+`@версия`),
  composer `vendor/name` (+`:ограничение`). URL, `git+https`, `github:`, `user/repo`, пути и алиасы `npm:`
  не проходят (`nc_valid_pkg` в панели и в `ss-nodecomposer-sync.php`).
- **Токен Telegram в панели уведомлений** уходит в теле POST, в журнал не пишется, а `ss-notify-sync.php`
  затирает payload заданий сразу после выполнения. Если токен задан, а chat id пустой, панель предупреждает.
- **Права на то, что раскладывает установщик.** Копия установщика с Windows приезжает с правами 777, и раньше
  `cp -a` и `tar` под root переносили их на системные файлы (так `/etc/nginx/snippets` на проде стал 777).
  Теперь сниппеты ставятся через `install -m 644`, все архивы распаковываются с `--no-same-owner
  --no-same-permissions`, плагины Roundcube копируются без сохранения прав. При старте установщик сам снимает
  запись для группы и других со своего каталога. `_security_fix_stack_perms` (этап security, конец полной
  установки и `--update`) снимает запись для других с конфигов стека: `/etc/nginx`, `/etc/php`,
  `/usr/local/ispconfig`, почта, CrowdSec, fail2ban, ufw, Roundcube, phpMyAdmin, bind, MariaDB, ssh, systemd,
  cron.d (`STACK_CONF_DIRS` в `lib/core.sh`). Групповую запись там не трогает, она бывает штатной (ISPConfig
  `lib/lang` 770, `/etc/bind/slave` 2770). `/var/www` не трогает. Список исправленного пишется в `setup.log`.
- **ISPConfig недоступен для загрузки (Cloudflare-челлендж/403)**: если `ispconfig.org`/`git.ispconfig.org`
  отвечают 403 (`cf-mitigated: challenge`), `wget`/`curl` не пройдут JS-проверку. Установщик в интерактиве
  ставит этап `ispconfig` на ПАУЗУ и ждёт: скачайте архив в браузере (он проходит проверку) —
  `https://www.ispconfig.org/downloads/ISPConfig-3-stable.tar.gz` — и положите как `/tmp/ispconfig.tar.gz`
  (или задайте `ISPC_LOCAL_TARBALL=/path`), нажмите Enter — продолжит. Догнать этап: `--only ispconfig`.
- **UFW в WSL/контейнере** падает с `Couldn't find parent pid` (`under_ssh`) — артефакт окружения;
  на реальном VPS `ufw enable` работает. Установщик честно сообщает, что firewall не активирован.
- **CrowdSec LAPI** уводится с порта 8080, если на нём панель ISPConfig (иначе агент не стартует).
  При повторном прогоне порт, который слушает сам crowdsec, конфликтом не считается (LAPI не «уезжает»).
- **CrowdSec по веб-серверу**: коллекция парсера и acquisition выбираются по `WEBSERVER` —
  nginx (`crowdsecurity/nginx`, логи `/var/log/nginx/*`, `type: nginx`) или apache
  (`crowdsecurity/apache2`, `/var/log/apache2/*`, `type: apache2`); per-site логи ISPConfig в обоих.
- **CrowdSec детект почтового брута** (`_crowdsec_enable_mail`, если выбрана почта): коллекции
  `crowdsecurity/postfix` + `crowdsecurity/dovecot` + acquisition `mail-ispconfig.yaml`
  (`/var/log/mail.log`, `type: syslog` — парсеры postfix/dovecot роутятся по имени программы).
  Включается в `install_crowdsec` (install) и в `--update` (для уже стоящих серверов без mail-движка),
  идемпотентно. **Важно:** веб-логи ISPConfig анонимизируются (последний октет → `.0`), поэтому
  CrowdSec там банит сетевой адрес `.0`, а не реального клиента; `mail.log` содержит **реальные IP**,
  поэтому SMTP/IMAP-брутеры (сценарии `postfix-spam`/`dovecot-spam`) банятся по-настоящему. E2E на проде:
  `81.30.98.0/24` (IR, ~100k SASL-фейлов) забанен сразу после включения.
- **Реальные IP для веб-детекта CrowdSec** (фикс анонимизации): публичные nginx access-логи маскируются
  (GDPR, `$ip_anonymized`, последний октет → `.0`) — если их читать, CrowdSec банит сетевой `.0`, а не
  атакующего. Решение: рядом с публичным логом пишется отдельный **`crowdsec.log`** форматом
  `crowdsec_realip` (настоящий `$remote_addr`) — **ЕДИНЫЙ `/var/log/nginx/crowdsec.log` для ВСЕХ сайтов**:
  глобальный из `assets/nginx/nginx.conf` (default-server) + все vhost'ы пишут туда же (conf-custom
  vhost-шаблон, блоки logging `yes`/`anon`, `access_log /var/log/nginx/crowdsec.log crowdsec_realip;`).
  **Почему единый, а не per-site** (`Вариант A`): раньше каждый сайт писал в `httpd/<site>/crowdsec.log` и
  acquisition читал их по glob'у `httpd/*/crowdsec.log` — но CrowdSec раскрывает glob при СТАРТЕ и НЕ
  подхватывает каталоги сайтов, созданных позже → новые сайты оставались без веб-детекта (E2E-подтверждено:
  10 сайтов, `lsof` показал открытым только глобальный лог). Единый стабильный файл читается всегда →
  **новые сайты покрываются автоматически, без glob/рестартов/resync**. Миграция существующих
  (`_ispconfig_crowdsec_shared_migrate`, stage 8.13.1 + `--update` 3.2.7.1): sed переправляет строку
  `access_log` в готовых vhost'ах и рантайм-шаблонах на общий путь **без ISPConfig resync** (уникальные
  директивы/данные сайтов не трогаются) + `nginx -t`/reload + убирает per-site logrotate. Acquisition
  `web-ispconfig.yaml` для nginx = один файл (для Apache — обычные per-site access, он не анонимизируется). Публичный
  `access.log` остаётся маскированным (приватность сохранена), CrowdSec/fail2ban видят реальный IP.
  **Важно:** пакет CrowdSec при установке создаёт `acquis.d/setup.nginx.yaml`, читающий
  АНОНИМИЗИРОВАННЫЙ `/var/log/nginx/*.log` (→ баны `.0` + дубль `crowdsec.log`) — `_crowdsec_drop_anon_acquis`
  его убирает (install + `--update`), иначе фикс работает лишь наполовину. E2E: после удаления CrowdSec
  читает только `crowdsec.log` + `mail.log`, `.0`-решения больше не появляются.
  **Per-site:** `_ispconfig_crowdsec_vhost_log` (lib/ispconfig.sh, шаг 8.13 + `--update` 3.2.7) добавляет
  companion `access_log .../crowdsec.log crowdsec_realip;` в АКТИВНЫЙ runtime vhost-шаблон ISPConfig —
  `conf-custom/nginx_vhost.conf.master` если есть, иначе `conf/` (НЕ путать с `conf-custom/install/` —
  это шаблоны установщика, не для генерации vhost). Идемпотентно (гард по `crowdsec.log`). Существующие
  сайты подхватывают строку при **ISPConfig Resync** (Tools → Resync или `datalogUpdate(...,force=true)`);
  новые — сразу. **Замороженные сайты** (vhost-freeze) шаблон не используют → их `crowdsec.log` не пишется
  (vhost управляется вручную) — это ожидаемо. E2E на проде: 8 незамороженных сайтов получили `crowdsec.log`
  с реальными IP, `example.com` (заморожен) — пропущен, nginx -t OK, сайты 200, CrowdSec читает per-site.
  Ротация: единый лог покрыт штатным logrotate nginx; per-site `/etc/logrotate.d/crowdsec-realip`
  больше не создаётся (устарел с единым логом; повторный прогон его удаляет). E2E на проде: `crowdsec.log` пишет реальные IP, CrowdSec парсит 55/55, публичный лог `.0`.
- **Панель CrowdSec** (`ISPC_CROWDSEC_PANEL=y`, по умолч. y; `_ispconfig_deploy_crowdsec_panel`, гейт по
  наличию `cscli`): пункт меню **System → Дополнения → CrowdSec** с таблицей активных решений (IP, страна, AS, сценарий,
  источник, истечение) и кнопкой **«Снять»** бан — аналог лог-вьюшек ISPConfig, но структурированно.
  Интерфейс (под `ispconfig`) не может дёргать `cscli` (root) → root-cron `ss-crowdsec-sync.php`
  (`/etc/cron.d/ss-crowdsec-panel`, раз в минуту) кэширует `cscli decisions list -o json` в таблицу
  `crowdsec_decision` (её читает страница) и выполняет снятие из очереди `crowdsec_action`
  (`cscli decisions delete --ip`). IP валидируется в странице и в cron (отбой инъекций — E2E:
  `not-an-ip; rm` → `error`). en+ru, страница/меню переналиваются в `--update` (3.2.6). E2E на проде:
  кэш 25 решений (реальные IP из `crowdsec.log`), снятие бана через очередь = `1 decision(s) deleted`.
  **Community blocklist (CAPI):** детальная таблица — только ЛОКАЛЬНЫЕ решения (их можно снимать); огромный
  community-список (десятки тысяч IP) показывается СВОДКОЙ. Счётчики по источнику берутся дёшево прямо из
  sqlite CrowdSec (`/var/lib/crowdsec/data/crowdsec.db`: `SELECT origin,COUNT(*) … GROUP BY origin`, через
  PDO) в таблицу `crowdsec_origin` — без парсинга 29k строк `cscli decisions list --all` каждую минуту.
  Заголовок страницы: «Всего заблокировано IP: N (community blocklist (CAPI): X · локально: Y)». E2E на
  проде: CAPI 29268 + локально 40.
- **Анти-дубль-клик во ВСЕХ queue-панелях** (notify, backup, CrowdSec, ufw-блок-лист, Node/Composer):
  единый приём — кнопки-действия несут класс `ss-lock` и **гаснут сразу на клике** (JS, `pointer-events:none`),
  а страница **сама авто-обновляется** (`loadContent`, 5с) пока в очереди/применении есть незавершённое
  (детект по статусам таблиц-очередей: `*_job`/`*_action`/`*_restore`/`applied=n`) — до результата и разблокировки.
  Где операция тяжёлая/опасная (backup-run, restore, npm/composer install) — при незавершённой задаче кнопки
  дополнительно **блокируются на сервере** (новую задачу не ставим), чтобы не наплодить дублей; где действия
  безопасны/пакетны (снятие банов CrowdSec, вкл/выкл строк ufw) — только клиентский `ss-lock` + авто-рефреш.
- **CrowdSec CAPI** (`CROWDSEC_CAPI=y`, по умолч. y; `_crowdsec_capi_register`): регистрация в Central API
  для **community blocklist** — упреждающие баны IP, отмеченных всей сетью CrowdSec (на проде ~29k, отдельный
  nft-набор `crowdsec-blacklists-CAPI`, бунсер их применяет) + анонимный обмен сигналами. Пакет регистрирует
  сам в postinst; функция — идемпотентная страховка (регистрирует ТОЛЬКО если `cscli capi status` неуспешен,
  иначе создала бы дубль машины). Install (`install_crowdsec`) + `--update` (гейт по `! cscli capi status`).
- **CrowdSec hub — авто-обновление правил** (`CROWDSEC_HUB_AUTOUPDATE=y`, по умолч. y; `_crowdsec_hub_autoupdate`):
  community blocklist (список IP) агент тянет сам ~раз в 2ч, а вот **правила детекта** (hub: сценарии/парсеры/
  коллекции) сами НЕ апгрейдятся — со временем устаревают (новые CVE/паттерны не детектятся). Ставим wrapper
  `/usr/local/sbin/ss-crowdsec-hub-upgrade` (`cscli hub update && cscli hub upgrade && systemctl reload crowdsec`,
  со случайной задержкой ≤40 мин — не бить CDN разом) + еженедельный cron `/etc/cron.d/ss-crowdsec-hub` (пн 04:23).
  Аналог авто-обновления баз антивируса. Install + `--update`. E2E на проде: wrapper/cron на месте, реальный
  прогон `hub upgrade` обновил data-файлы, агент жив (91 элемент hub).
- **CrowdSec — эскалация bantime рецидивистам** (`CROWDSEC_BANTIME_ESCALATION=y`, по умолч. y; `_crowdsec_profile_escalation`):
  повторно залетающий IP должен сидеть дольше. В `/etc/crowdsec/profiles.yaml` включаем штатный
  `duration_expr: Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 4)` для профилей `default_ip_remediation`
  и `default_range_remediation` — базовый бан 4ч умножается на (число прошлых решений по IP + 1): первый раз 4ч,
  1 прошлый → 8ч, 3 → 16ч, 8 → 36ч. Идемпотентно: если активная строка `duration_expr` уже есть — не трогаем
  (уважаем ручные правки); line-based awk (mawk-safe, без multichar RS); бэкап `profiles.yaml.bak.<ts>` + reload
  с проверкой. Install + `--update`. **Наблюдение на проде** (2026-07-02): рецидив ~40% (105/262 IP с ≥2 алертами);
  явный актор — подсеть `81.30.98.0/24` (6 хостов по 9 алертов) → отдельно закрыт ручным range-баном на 30 дней
  (`cscli decisions add --range … --duration 720h`). Анонимизация веб-логов (баны `.0`) уже устранена — активные
  баны 100% на реальные IP.
- **Панель «Доверенные IP»** (`ISPC_TRUSTED_PANEL=y`, по умолч. y; `_ispconfig_deploy_trusted_panel`; гейт: есть
  `cscli` или `fail2ban-client`). Пункт System → **Trusted IPs**. Один список IP и подсетей, которые не банятся.
  Таблица `ss_trusted_ip` (что должно быть доверенным), root-cron `ss-trusted-sync.php` раз в минуту приводит к ней
  CrowdSec (allowlist `luckystack-trusted` через `cscli allowlists`, CrowdSec 1.6.8+, действует и на общий
  блок-лист) и fail2ban (`[DEFAULT] ignoreip` в `/etc/fail2ban/jail.d/zz-luckystack-trusted.local`, reload только
  при изменении). Уже стоящие баны по новому адресу снимаются (`cscli decisions delete --ip`, для подсети `--range
  ... --contained`; `fail2ban-client unban`), пять минут подряд, потому что fail2ban после reload восстанавливает
  баны из своей базы. У записи комментарий и срок (навсегда, 1 час, сутки, 7 и 30 дней), истёкшие удаляются.
  Подсети шире /16 (IPv4) и /32 (IPv6) не принимаются. Кнопка «Мой IP» и предупреждение, если текущего IP админа
  нет в списке; удаление своего адреса с отдельным подтверждением. Проверка «где забанен IP» через очередь
  `ss_trusted_job`: доверенный ли, решения CrowdSec (включая CAPI), срабатывания, джейлы fail2ban, блок-лист ufw.
  Другие allowlist CrowdSec показываются только для чтения. При установке в список попадают `ISPCONFIG_ADMIN_IPS`,
  `SSH_ALLOW_IPS` и внешний IP сервера. Срок считается в SQL (`NOW() + INTERVAL`): PHP панели работает в UTC, а
  MariaDB в поясе сервера. Install (8.17b) + `--update` (3.2.11b). Тест 14/14 на тестовом сервере.
- **Панель «Firewall: блок-лист»** (`ISPC_UFWBLOCK_PANEL=y`, по умолч. y; `_ispconfig_deploy_ufwblock_panel`;
  меню System → **Firewall block-list**; гейт — установлен ufw): ручной **ufw-deny для IP и подсетей** +
  **подсказки по подсетям-кластерам**. Зачем: `crowdsec-firewall-bouncer` (v0.0.34, nftables) **НЕ применяет
  range-решения** — кладёт CIDR в host-набор `ipv4_addr` (без `flags interval`) как одиночный сетевой адрес
  (`81.30.98.0/24` → `81.30.98.0`, не блокирует никого). Поэтому подсети режем через **ufw** (нативный CIDR,
  правило `insert 1` — до allow-правил портов). Паттерн панелей: интерфейс ведёт таблицу `ufw_block`
  (IP/CIDR, active y/n), а root-cron `ss-ufwblock-sync.php` (раз/мин) **реконсилит** реальные правила ufw с
  таблицей (добавляет active-строки как `deny from <t> comment panel-block:<t>`, снимает исчезнувшие;
  флаг `applied`) и наполняет `ufw_block_suggest` — подсети `/24`, из которых CrowdSec активно забанил **≥3 IP**
  (кандидаты на бан всей подсети; уже заблокированные исключаются). Навигация через `loadContent()` (не
  form-submit). **Валидация в странице И кроне**: только IPv4/IPv6/CIDR, маска не шире `/8` (IPv4)/`/16` (IPv6),
  `escapeshellarg`; **анти-локаут** — страница запрещает блокировать подсеть, содержащую IP текущего админа
  (`REMOTE_ADDR`). en+ru. Install (8.17) + `--update` (3.2.11). E2E на проде: add IP/подсеть → правило ufw,
  toggle/delete → снятие, подсказка `81.30.98.0/24` (6 IP) появляется/исчезает по состоянию блока.
- **UFW vs CrowdSec за nftables**: при выборе `FIREWALL=ufw` (в т.ч. фоллбэк с crowdsec) установщик
  сначала гасит остаточный `crowdsec-firewall-bouncer` и сносит его nft-таблицу — иначе бунсер
  держит nftables и `ufw enable` проходит, но правила не применяются (риск лок-аута).
- **Единый firewall ISPConfig — модуль «Firewall IP-rules»** (`ISPC_FW_EXT=y`, по умолч. y):
  встроенный firewall ISPConfig умеет только «открыть порт ВСЕМ». Установщик ставит **дружелюбный модуль**
  (System → «Firewall IP-rules»), который СТАНОВИТСЯ ЕДИНСТВЕННЫМ движком firewall. Поля на правило:
  **Сервер, Протокол (TCP/UDP), Порт (число или диапазон `A:B`, напр. `40110:40210`), «Открыть всем»,
  Разрешённые IP, Описание, Активно**. Два режима на порт:
    - **Открыть всем** (`allow_all=y`) — публичный порт (web/mail/dns/ftp…), ACCEPT без DROP;
    - снять галочку — порт открыт **только** перечисленным IP (ACCEPT + DROP остальным).
  Реализация: таблица `firewall_restrict` + datatable-модуль (list/edit/del, tform, шаблоны, lang, пункт
  меню) + **серверный модуль** `firewall_restrict_module` (mods-available + симлинк mods-enabled) +
  **server-plugin** `firewall_restrict_plugin` (plugins-available + симлинк plugins-enabled). Цепочка
  применения: сохранение в панели → `sys_datalog` → `server.sh` → **модуль** (он ловит таблицу через
  `registerTableHook` И **обязательно** объявляет события через `announceEvents` — без этого `registerEvent`
  ISPConfig молча игнорирует подписку и плагин не вызовется!) → `raiseEvent('firewall_restrict_*')` →
  **плагин** пересобирает блок `# luckystack: restrict-isp` в `/etc/ufw/before.rules` (цепочка
  `ufw-before-input`, ДО user-правил) + `ufw reload`. Кнопка **«Заполнить значения по умолчанию»**
  (`firewall_restrict_seed.php`, только админ) идемпотентно сеет публичные порты (из родного firewall +
  типовой веб/почта-набор) и базовые IP-ограничения на IP текущего админа. before.rules переживает и
  `ufw reload`, и обновления ISPConfig. Все три компонента (модуль/плагин/файлы интерфейса) переналиваются
  `_ispconfig_deploy_firewall_ext` при установке и в `--update` (как conf-custom). Развёрнуто и проверено
  на живом сервере (php -l, rebuild() E2E, внешняя доступность).
  **Контроль/UX модуля:** (1) **валидация** поля «Разрешённые IP» — CUSTOM-валидатор
  `validate_firewall_restrict` (interface/lib/classes) блокирует сохранение при некорректном IPv4/IPv6/CIDR;
  (2) **анти-локаут** — кнопка «Добавить мой IP» и live-предупреждение, если IP админа не в списке
  ограниченного правила (контроллер отдаёт `my_ip`); (3) **статус «Применено»** — колонка `applied`
  (datetime): контроллер сбрасывает в `NULL` при сохранении (→ ⏳ «ожидает ≤1 мин»), плагин при rebuild
  ставит `NOW` у **всех** правил сервера (не только `active='y'`) — после пересборки before.rules отражает
  текущее состояние ВСЕХ правил (активные в блоке, выключенные корректно отсутствуют), поэтому и
  выключенное правило считается применённым (иначе оно навсегда зависало бы в ⏳, т.к. по `active='n'`
  апдейт `active='y'` не проходил); в списке ✓ (применено)/⏳ (ожидает); кнопка **«Применить сейчас»**
  (`firewall_restrict_apply.php`) форсит пересборку через datalog-тоггл; (4) **тест порта** в строке (`firewall_restrict_test.php`) — `fsockopen
  127.0.0.1:порт` показывает, есть ли локальный слушатель (диагностика «порт открыт, но служба не запущена»);
  (4b) **массовый вкл/выкл** (C1): чекбоксы в списке + «select all» + кнопки «Включить/Выключить выбранные»
  → `firewall_restrict_bulk.php?ids=…&do=enable|disable` меняет `active` через `datalogUpdate` (только при
  реальном отличии) → модуль→плагин пересобирают before.rules. E2E: 2 правила → bulk disable → before.rules=0;
  (5) **rate-limit** (`rate_limit=y`) — ограничение частоты новых соединений с одного IP через
  `-m hashlimit --hashlimit-above 30/min --hashlimit-burst 60 --hashlimit-mode srcip -j DROP` (защита
  от перебора/флуда; established уже принят выше в цепочке ufw, поэтому не страдает); (6) **гео-фильтр**
  (`geo_mode` off/allow/block + `geo_countries` = коды ISO 3166 alpha-2): `block` — DROP трафика из
  указанных стран поверх обычной логики; `allow` — порт открыт ТОЛЬКО этим странам (белый список,
  IP/«Открыть всем» игнорируются). Диапазоны стран — ipset'ы `ss_geo_<cc>`/`ss_geo6_<cc>` (hash:net),
  наполняются из `/etc/ss-firewall/geoip/<cc>.zone` (агрегированные CIDR с **ipdeny.com**) скриптом
  `/usr/local/sbin/ss-firewall-geo-refresh` (cron `/etc/cron.d/ss-firewall-geo`, вс 04:17 + докачка из
  плагина при появлении новой страны). ipset'ы пересобирает хук `/etc/ufw/before.init` (его пишет плагин)
  на старте/`flush-on-reload` ufw — ДО загрузки before.rules, поэтому ссылки `--match-set` всегда валидны;
  пакет `ipset` ставится `_ispconfig_deploy_firewall_ext`. Зону, для которой не удалось скачать данные,
  плагин не подставляет (geo=allow → fail-closed, geo=block → просто без этой страны; в server.log warning).
  Поля `rate_limit`/`geo_mode`/`geo_countries` добавляются `ALTER … IF NOT EXISTS`; валидатор `valid_countries`
  блокирует не-ISO-коды. E2E на живом сервере: hashlimit + geo block/allow в before.rules и в ядре iptables,
  ipset скачан и наполнен.
- **Родной firewall ISPConfig гасится** (`_ispconfig_takeover_native_firewall`): чтобы движок был ОДИН,
  при первом заходе установщик переносит публичные порты родного firewall в таблицу как `allow_all=y`
  (`_ispconfig_seed_public_ports`), затем перехватывает движок: (1) пересобирает before.rules из таблицы
  (все порты уже открыты), (2) чистит `user.rules` родного firewall (`ufw delete allow …` — без разрыва,
  before.rules держит порты), (3) гасит родной firewall **прямым** `UPDATE firewall SET active='n'` в БД
  (НЕ через панель — иначе сработал бы его плагин, а он на `active=n` делает `ufw disable`, вырубив фаервол
  целиком). Пункт меню родного «Firewall» убирается из `module.conf.php` (наш «Firewall IP-rules» встаёт
  на его место). Перехват — ТОЛЬКО при первом заходе (родной `active=y`); после него апдейт НЕ пересевает
  публичные порты, чтобы не воскрешать удалённые админом в панели.
- **Панель Fail2ban** (`ISPC_FAIL2BAN_PANEL=y`, по умолч. y; `_ispconfig_deploy_fail2ban_panel`): пункт меню
  **System → Дополнения → Fail2ban** со статусом джейлов (забанено/неуд.попыток/всего) и списком забаненных IP с кнопкой
  **«Разбанить»**, плюс форма «забанить IP вручную». Интерфейс ISPConfig работает под непривилегированным
  пользователем и НЕ может дёргать `fail2ban-client` (root-сокет), поэтому: панель пишет запрос в очередь
  (таблица `fail2ban_action`, `status=pending`), а **root-cron** `ss-fail2ban-sync.php`
  (`/etc/cron.d/ss-fail2ban`, раз в минуту) выполняет его через `fail2ban-client set <jail> ban/unbanip`
  и обновляет кэш статуса (таблица `fail2ban_jail`), который читает страница (≤1 мин на применение).
  Имя джейла и IP валидируются и в очереди (`valid_ips`/regex), и в cron-скрипте (отбой команд-инъекций —
  E2E: `sshd; rm -rf` → `error`). Страница только админская, локализована (en+ru). Страница/меню затираются
  обновлением ISPConfig → переналиваются в `--update` (3.2.4); таблицы/cron — идемпотентно.
- **Наши установочные IP-ограничения сеются в панель** (`_ispconfig_seed_firewall_rules`): правила SSH
  (`22` и `SSH_PORT` → `SSH_ALLOW_IPS`), панели (`ISPCONFIG_PANEL_PORT` → `ISPCONFIG_ADMIN_IPS`, **+ её
  UDP при `PANEL_HTTP3=y`** — иначе QUIC обошёл бы IP-ограничение TCP) и MySQL (`3306` →
  `MARIADB_REMOTE_IPS`, если `MARIADB_REMOTE=y`) заносятся **в `firewall_restrict`** (`allow_all=n`), с
  человекочитаемыми описаниями. Публичный HTTP/3 (`443/udp` сайты + `apps/udp`) сеется как `allow_all=y`.
  Идемпотентно по `server_id+proto+port`: правки сохраняются, удалённое правило восстанавливается. Текущий
  SSH-IP добавляется автоматически (анти-локаут).
- **Базовый слой before.rules** (`_security_ufw_restrict_persist`): когда таблица `firewall_restrict`
  есть (ISPConfig+модуль), ВСЕ правила ведёт панель — базовый слой не пишет ничего (его блок
  `# luckystack: restrict` снимается), чтобы не было двух источников. **Без ISPConfig** (нет модуля)
  базовый слой по-прежнему пишет TCP IP-ограничения + UDP-открытия HTTP/3 из setup.conf в блок `restrict`
  (цепочка `ufw-before-input`). Идемпотентно (по маркерам), IPv4+IPv6, с откатом при сбое `ufw reload`.
  Применить на уже установленном сервере: `./server-setup.sh --update` (выбрать «security»).
- **Заморозка vhost — галочка «Не обновлять vhost» + редактор vhost в панели** (`ISPC_VHOST_FREEZE=y`,
  по умолч. y): при любом сохранении сайта core-плагин ISPConfig перегенерирует
  `/etc/nginx/sites-available/<домен>.vhost` из шаблона, затирая ручные правки. Галочка **«Не обновлять
  vhost»** (вкладка Options) включает per-site заморозку; рядом — **textarea «Содержимое vhost»**, где
  редактируется сам конфиг прямо из панели. Реализация: колонки `freeze_vhost` (галочка) +
  `freeze_vhost_content` (`mediumtext`, содержимое) в `web_domain`; поля в форме (tform/шаблон/lang,
  переналивается при `--update`) + **отдельный** server-plugin `zzz_freeze_vhost_plugin` (префикс `zzz_`
  → грузится ПОСЛЕ `nginx_plugin`, обработчик `web_domain_update` срабатывает ПОСЛЕ регенерации).
  **Источник правды — колонка `freeze_vhost_content`** (интерфейс ISPConfig работает под непривилегированным
  пользователем и НЕ может писать в `/etc/nginx/sites-frozen` (root:root) — поэтому контент в БД, а на диск
  его кладёт плагин-root). Логика: при включении галочки (контент пуст) плагин загружает текущий
  сгенерированный vhost в поле БД (снимок-старт, live не трогает); когда контент задан — пишет его в
  `sites-available` (+ зеркало в `sites-frozen`), `nginx -t`, при ошибке **откат** к сгенерированному
  (кривой конфиг не уронит веб-сервер); `active=n` не трогается; снятие галочки/удаление сайта чистят
  контент и зеркало. **Безопасность:** галочка и редактор видны и применяются ТОЛЬКО админу — поля обёрнуты
  `<tmpl_if name="is_admin">`, а в `onSubmit` для не-админа значения принудительно берутся из БД (иначе
  клиент подделкой POST вписал бы произвольный конфиг nginx под root, либо обычным сохранением сбросил бы
  заморозку). `/etc/nginx/sites-frozen` попадает в бэкап (архивируется весь `/etc`); контент — ещё и в
  бэкап/миграцию ISPConfig (он в БД). **Важно:** пока галочка стоит, изменения сайта в панели (PHP-версия
  → новый FPM-сокет, SSL, root) во vhost НЕ попадут — это суть заморозки; правь конфиг в textarea. Apache
  поддержан (`apache2ctl -t`). Развёртывается `_ispconfig_deploy_vhost_freeze` при установке (шаг 8.8) и в `--update`.
  **Статус/diff/дрейф:** плагин-root складывает в БД `freeze_vhost_generated` (последний сгенерированный
  core vhost) и `freeze_vhost_status` (итог `nginx -t`: ok/ошибка+текст). Страница **«Заморозка: статус и
  diff»** (`web_vhost_freeze_info.php`, только админ, кнопка во вкладке Options) показывает: статус
  последнего применения, **детектор дрейфа PHP-сокета** (`fastcgi_pass` в замороженном ≠ в сгенерированном
  → риск 502 при смене версии PHP), сгенерированный core vhost (read-only — что было бы без заморозки), и
  кнопки **«Пересеять из сгенерированного»** (контент←generated) и **«Применить сейчас»** (через
  datalogUpdate). Так «тихий откат» кривого конфига теперь виден в панели как статус-ошибка.
  **Заметность:** у замороженного сайта на **всех вкладках** формы редактирования сверху висит
  предупреждающий баннер «Сайт заморожен…». Реализация: контроллер формы (`web_vhost_domain_edit.php`,
  `onShowEnd`) на каждом рендере выставляет template-var `freeze_vhost_active` из БД; общий шаблон-обёртка
  `themes/default/templates/tabbed_form.tpl.htm` рендерит `alert-warning` по `<tmpl_if
  name="freeze_vhost_active" op="==" value="y">` (для прочих форм var не задан → баннер не выводится). Эти
  два файла (контроллер + тема) тоже затираются обновлением ISPConfig → переналиваются в `_ispconfig_patch_vhost_freeze_form`.
- **Тёмная тема панели — тумблер** (`ISPC_DARK_THEME=y`, по умолч. y, `_ispconfig_deploy_theme_dark`):
  кнопка-переключатель (иконка `fa-adjust`) рядом с «Выход» в шапке. Реализация «CSS + класс»: `ss-dark.js`
  ставит класс `ss-dark` на `<html>` (выбор в `localStorage`; стартовое значение — по
  `prefers-color-scheme`), `ss-dark.css` переопределяет цвета поверх штатной темы (Bootstrap 3 + ISPConfig:
  каркас/шапка/сайдбар/панели/таблицы/формы/вкладки/алерты/select2/пагинация). Оба файла кладутся в
  `themes/default/assets/stylesheets/`, в `main.tpl.htm` добавляются ссылки в `<head>` + кнопка у logout.
  На всех пользователей; кастомные страницы (firewall-модуль, заморозка) на Bootstrap-классах красятся
  автоматически. `main.tpl.htm` затирается обновлением ISPConfig → переналивается при `install`/`--update`
  (идемпотентно по маркеру `ss-theme-toggle`). Палитру правят в `ss-dark.css`.
- **Порт Apps-vhost** (`ISPCONFIG_APPS_PORT`, по умолч. 8081): порт apps-домена ISPConfig
  (webmail/phpMyAdmin через `apps.<домен>`), задаётся в мастере рядом с портом панели.
  ISPConfig хранит его в `server.config` (`apps_vhost_port`); `_ispconfig_set_apps_port` после
  установки меняет и конфиг сервера (durable — будущие регенерации), и живой `apps.vhost`
  (с `nginx -t`+откатом), а firewall открывает новый порт (tcp + udp для HTTP/3).
- **Удалённый доступ к MariaDB** (`MARIADB_REMOTE=y`, по умолч. n): чтобы галочка
  **«Remote Access»** у базы в ISPConfig реально работала (коннект к БД извне). Включает
  `bind-address = 0.0.0.0` (localhost продолжает работать) и открывает `3306/tcp` в firewall
  **только** для `MARIADB_REMOTE_IPS` (список через пробел; пусто = всем, с предупреждением).
  В ISPConfig: у DB-юзера отметить «Remote Access» + указать Remote IPs. `--healthcheck` при
  этом не падает на торчащем 3306, а напоминает ограничить его по IP. ⚠ Без списка IP 3306
  наружу — риск брутфорса. На уже установленном сервере включить:
  `bind-address` в `/etc/mysql/mariadb.conf.d/99-luckystack.cnf` → `0.0.0.0`, `systemctl restart mariadb`,
  `ufw allow from <IP> to any port 3306 proto tcp`.
- **conf-custom** (усиление шаблонов ISPConfig) применяется ТОЛЬКО к nginx
  (`nginx_vhost.conf.master`); на Apache этап no-op (другой шаблон/синтаксис).
- **DNS-шаблон зоны** (`DNS_ZONE_TEMPLATE=y`, опц. при компоненте `dns`): мастер спрашивает IP
  для ns1–ns4 (автодетект IP сервера), а после установки ISPConfig идемпотентно зашивает шаблон
  «Default» в `dbispconfig.dns_template` — каждый новый домен через «Add DNS Zone with Wizard»
  получает vanity-NS + SPF/DMARC(`p=none`)/CAA(letsencrypt)/autodiscover. DKIM не трогаем (его
  ISPConfig добавляет per-домен). Что подправить перед продом (делегирование у регистратора,
  вторичный NS, DKIM, DMARC→quarantine, SPF→`-all`, PTR, DNSSEC) — в `/root/dns-zone-template-notes.txt`.
- **--healthcheck** дополнительно валидирует конфиг активного веб-сервера (`nginx -t` /
  `apache2ctl configtest`): битый конфиг при «active»-сервисе молча не применяет новые vhost'ы.
- **Удаление** не доверяет `WEBSERVER` из setup.conf вслепую — детектит реально установленный
  сервер; CrowdSec чистится независимо от веб-сервера (это firewall).
- **Профиль установки (пресет)** в начале мастера предзаполняет чеклист компонентов:
  Минимальный (ядро+DNS+security+LE) / Веб+Почта / Полный / Свой. Пресет — умный дефолт,
  чеклист под ним правится вручную. Ядро (веб-сервер+PHP+MariaDB+ISPConfig+SSL) — всегда.
- **Файл доступов** `/root/server-access.txt` (chmod 600) пишется в конце установки: URL панели/
  вебмейла/dbadmin/Monit, логин admin + пароль, где лежат остальные пароли, команды обслуживания.
  Чтобы доступы не терялись при закрытии терминала (экранная сводка исчезает).
- **Авто-healthcheck в финале** полного прогона (не `--only`/`--from`): сразу показывает
  зелёный/красный итог под сводкой (`HC_NO_CLEAR=1` — не затирает её), новичку не надо помнить
  про `--healthcheck`.
- **Анти-лок-аут** (`SSH_NETSAFE`, см. таблицу выше): таймер отката firewall/SSH, подтверждение —
  из НОВОГО соединения (текущая established-сессия переживает лок-аут и доступ не доказывает).
- **Валидация ввода в мастере**: FQDN (формат host.domain.tld), часовой пояс (наличие в zoneinfo),
  SSH-порт (1–65535) — перезапрос при ошибке (`ui_input_validated`). Опечатка в FQDN иначе тихо
  каскадит в провал LE/почты.
- **LE-отказ — понятный UX**: при rate-limit Let's Encrypt этап показывает причину и время сброса
  (из `/var/log/ispconfig/acme.log`) + варианты (ждать / `LE_STAGING=y`). При любом провале LE громко
  предупреждает, что запрет панели по IP (`PANEL_FQDN_ONLY`) **НЕ применён** (ставится только при
  успешном серте). `LE_STAGING=y` — выпуск на staging-CA (серт НЕ доверенный, но без rate-limit, для тестов).
- **Откат SSH-харденинга в uninstall**: если харденинг применялся (есть `sshd_config.harden.bak`),
  удаление предлагает вернуть вход по паролю (дефолт — да; с `sshd -t`). Также снимаются наши
  SSH-артефакты: drop-in порта `00-luckystack-ssh.conf` + Match-блок `ssh-allow-ips`.
- **Смена SSH-порта — через drop-in, не основной конфиг**: на Debian 12+ `Include sshd_config.d/*`
  стоит вверху, и cloud-init/провайдерский drop-in с `Port 22` перебивал бы наш Port в конце
  основного файла (симптом: конфиг говорит NNN, демон слушает 22). Поэтому пишем в `00-*` (читается
  первым → побеждает) + глушим конфликтующие Port + сверяем `sshd -T`. `--only ssh` применяет
  порт/IP/харденинг отдельно (если полный прогон до финальных шагов не дошёл).
- **`SSH_ALLOW_IPS` через firewall** (UFW `allow from IP`) — при `FIREWALL=crowdsec` теперь тоже
  применяется, т.к. ufw поднимается поверх (`CROWDSEC_WITH_UFW=y`). Самозащита: если текущий адрес
  не в списке — открывается со всех. _(Прежний sshd-уровневый `Match Address *,!IP` убран — он на
  практике блокировал даже разрешённый IP и приводил к лок-ауту.)_
- **Выбор firewall в мастере** — «CrowdSec+UFW (оба, рекоменд.)» / «только CrowdSec» / «только UFW» /
  «нет». «Оба» = `FIREWALL=crowdsec` + `CROWDSEC_WITH_UFW=y` (ufw=порты, crowdsec=IP-баны).
- **Оффсайт-бэкап** (`BACKUP_REMOTE_TYPE`): после локального снимка `server-backup.sh` зеркалит
  каталог бэкапов вовне — `rsync` по SSH на другой сервер или `rclone` в облако (S3/B2/GDrive).
  Защита от потери диска/сервера; сбой выгрузки идёт в уведомления.
- **Уведомления** (`NOTIFY_EMAIL`/`NOTIFY_TG_*`): email и/или Telegram. Помимо событий (сбой бэкапа)
  ежедневный `server-monitor.sh` проверяет диск/TLS-серт/службы/**свежесть бэкапа** и шлёт ТОЛЬКО
  при проблемах (без спама). Удаляются при uninstall независимо от компонентов.
- **Exposure-check в healthcheck**: `--healthcheck`/`--diagnostics` флагают, если БД/кэш
  (3306 MariaDB, 5432 PostgreSQL, 6379 Redis, 11211 memcached, 27017 MongoDB) слушают НЕ на
  localhost (доступны из интернета — firewall по IP-банам порт не закрывает). MariaDB у нас
  биндится на `127.0.0.1` по умолчанию; проверка ловит дрейф/ручные изменения.
- **CrowdSec ≠ файрвол портов**: CrowdSec/fail2ban банят IP, но порты НЕ закрывают. При
  `FIREWALL=crowdsec` установщик по умолчанию (`CROWDSEC_WITH_UFW=y`) поднимает ufw default-deny
  ПОВЕРХ (ufw=порты, crowdsec=IP-баны). Раздельные nft-таблицы → сосуществуют; SSH-порт открыт
  до включения (анти-лок-аут страхует).
- **Diagnostics-bundle** (`--diagnostics`): один архив для поддержки. Пароли в `setup.conf`
  вырезаются, хвост лога проходит скраб секретов — но архив всё равно стоит проверить
  (`tar tzf …`) перед отправкой.
- **Онбординг-гайд** `GETTING-STARTED.md` (этот файл — про установщик; гайд — про «что делать
  дальше» обычному пользователю: вход в панель, первый сайт/ящик, DNS, безопасность). При установке
  копируется на сервер в `/root/GETTING-STARTED.md` и упоминается в финальной сводке + `server-access.txt`.
- **Защита панели — 2FA**: ISPConfig 3.2 имеет встроенную двухфакторную аутентификацию (TOTP),
  включается пользователем в панели (Tools → Two Factor Authentication). Установщик не может
  включить её принудительно (настройка per-user) — рекомендация выводится в `server-access.txt`.
  fail2ban-jail для входа в панель добавляется автоматически ТОЛЬКО при наличии фильтра ISPConfig
  (`/etc/fail2ban/filter.d/ispconfig.conf`); базовый `[sshd]`-jail активен всегда.
- **Лог** (`setup.log`) при запусках НЕ затирается (дозапись + ротация при >5 МБ). Права 600 (только
  root); значения паролей/токенов/ключей (`*PW*`, `*PASS*`, `*SECRET*`, `*TOKEN*`, `*KEY*`) в лог не
  пишутся — маскируются как `<скрыто>`. Вывод инсталлера ISPConfig из `/tmp` после установки удаляется.
- **Dovecot 2.4 (Debian 13)**: формат ssl-настроек несовместим с 2.3 (`ssl_cert = <…` не работает,
  демон не стартует). `hostcert` (deploy-скрипт) и `mailsni` (SNI-генератор) определяют версию по
  `dovecot --version` и для ≥2.4 пишут `ssl_server_cert_file`/`ssl_server_key_file`; новый конфиг
  гейтится `doveconf -n` с откатом на предыдущий, работающий Dovecot не ломается.
- **Пересборка nginx на работающем сервере** (`--update` → «ПЕРЕСБОРКА nginx», `--only nginx`): сборка
  в staging, новый бинарник тестируется, старый — `/usr/sbin/nginx.backup`, конфиг — `nginx.conf.orig`;
  после установки — `nginx -t` новым бинарником + рестарт с подтверждением (в `--unattended` —
  автоматически), при провале — откат бинарника и конфига. OpenSSL качается с фолбэком
  (openssl.org → GitHub Releases → `/source/old/`), с таймаутами.
- **acme.sh** хранит серты в `/root/.acme.sh` (не `/etc/letsencrypt`).
- **ISPConfig nightly** в `--status` сверяется по ДАТЕ сборки (Last-Modified nightly-тарбола vs
  `ISPCONFIG_INSTALL_DATE`), а не по stable-версии — иначе nightly всегда «отставала» бы от stable.
