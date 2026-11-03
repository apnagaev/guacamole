# Apache Guacamole (Ansible + Docker Compose)

[Apache Guacamole](https://guacamole.apache.org/) — удалённые рабочие столы (RDP, VNC, SSH) прямо в браузере, без клиентов. Два узла, вход через Keycloak, разворачивается и обновляется одним плейбуком.

- Guacamole на двух узлах, оба активны: подключения, пользователи и история — во внешней MySQL/MariaDB
- Вход через Keycloak (OpenID Connect), права — по ролям из токена
- Запись сеансов с просмотром в интерфейсе, папка «диска» для обмена файлами в RDP
- Обновление без простоя: узлы перезапускаются по очереди, каждый проверяется по HTTP
- Секреты — в одном файле переменных (ansible-vault)
- Firewall на nftables: порт Guacamole доступен только reverse proxy, узлам и внутренней сети

```
            браузеры
               │ https
       ┌───────▼───────┐  vIP
       │ reverse proxy │  /guacamole (WebSocket)
       └───┬───────┬───┘
       :86 │       │ :86
   ┌───────▼─┐   ┌─▼───────┐
   │  node1  │   │  node2  │   guacamole (веб) + guacd (протоколы)
   └──┬───┬──┘   └──┬───┬──┘
      │   └────┬────┘   │
 ┌────▼────┐ ┌─▼──────────────┐
 │  MySQL  │ │ записи сеансов │  ──► RDP / VNC / SSH хосты
 └─────────┘ └────────────────┘
```

## Структура

```
install_guacamole.yaml          # плейбук: firewall, файлы, поочерёдный запуск, проверка, очистка
inventory.example.yml           # пример inventory (группа docker, node: 1/2)
vars/guacamole.example.yml      # все настройки: версия, адреса, каталоги, база, Keycloak, firewall
tasks/guacamole-healthcheck.yaml
files/guacamole/
  guacamole.yaml.j2             # docker-compose.yaml
  guacamole.env.j2              # переменные Guacamole: база и Keycloak (0600 на хосте)
  guacamole.nft.j2              # правила nftables
  rdp-keyboard.sql              # раскладка клавиатуры для всех RDP-подключений
```

## Настройка

```bash
cp inventory.example.yml inventory.yml
cp vars/guacamole.example.yml vars/guacamole.yml
ansible-vault encrypt vars/guacamole.yml
```

В `vars/guacamole.yml`: версия, публичный адрес (он же redirect URI клиента `guacamole` в Keycloak), база, каталоги записей и «диска», `trusted_nets` (сети reverse proxy и мониторинга).

База создаётся один раз по [инструкции](https://guacamole.apache.org/doc/gug/jdbc-auth.html) (`initdb.sh --mysql`). При переходе с 1.5.x на 1.6.0 выполните `upgrade-pre-1.6.0.sql` из архива `guacamole-auth-jdbc-1.6.0`.

## Развертывание

```bash
ansible-playbook -i inventory.yml install_guacamole.yaml --ask-vault-pass
```

На каждом узле по очереди:
1. Применяет nftables (`/etc/nftables.d/guacamole.nft`).
2. Создаёт каталоги записей и «диска», кладёт `docker-compose.yaml` и `guacamole.env` (0600).
3. Скачивает образы и выполняет `docker compose up -d`: пересоздаются только изменившиеся контейнеры.
4. Ждёт ответа `/guacamole/` и запуска guacd, только потом переходит к следующему узлу.
5. Удаляет неиспользуемые образы (тома и сети других сервисов не трогает).

## Reverse proxy

Сессия Guacamole привязана к узлу: используйте `ip_hash` (или sticky cookie) и WebSocket:

```nginx
upstream guacamole { ip_hash; server 10.0.0.1:86; server 10.0.0.2:86; }
location /guacamole/ {
    proxy_pass http://guacamole;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffering off;
    proxy_read_timeout 300s;
}
```

## Раскладка клавиатуры (RDP)

По умолчанию Guacamole переводит нажатия в скан-коды американской раскладки: кириллица с компьютера пользователя теряется, а язык ввода определяет удалённая машина. Параметр подключения **Keyboard layout**:

- **Unicode** (`failsafe`) — печатается то, что выбрано у пользователя, раскладка удалённой машины не важна. Ввод на экране входа Windows и в окнах UAC может не работать, в части программ бывают сбои.
- **Russian (Qwerty)** (`ru-ru-qwerty`) — как физическая клавиатура: русские буквы передаются, язык ввода переключается на удалённой машине.

Для одного подключения — в его параметрах, для всех RDP-подключений сразу — `files/guacamole/rdp-keyboard.sql` (по умолчанию `failsafe`).

## «Диск» и записи

- В RDP-подключении: «Включить диск» и путь `/home/guacd/shared` — это каталог `guacamole_shared_dir` на узле. У каждого узла свой каталог; чтобы файлы были видны с обоих, укажите общее хранилище.
- Запись сеансов: в подключении путь `/home/guacd/recordings` и имя `${HISTORY_UUID}` — тогда запись открывается из истории подключений. Каталог `guacamole_recordings_dir` создаётся, если его нет; права существующего не меняются (guacd пишет от uid 1000).

## Проверка

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep guac
curl -sI http://127.0.0.1:86/guacamole/ | head -1      # 200
nft list table inet guacamole
```

## Обновление

Прогоните плейбук: при `guacamole_version: latest` он скачает свежий релиз. Чтобы закрепить версию, укажите тег, например `"1.6.0"`. Перед выходом новой версии — бэкап базы и [заметки к релизу](https://guacamole.apache.org/releases/): новые версии иногда требуют SQL-обновления схемы.
