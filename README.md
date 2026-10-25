# Keycloak

Ansible-проект ставит и обновляет Keycloak 26.8 в Docker: nginx на хосте завершает TLS, Keycloak в контейнере. Образ собирается из `images/keycloak` вместе с темами и провайдерами. Узел с белым IP: A-запись `keycloak_hostname` указывает на `ansible_host`. Можно начать с одного ЦОД и позже добавить второй (`docs/2-cod.md`). Роли `active` / `passive` — для Let's Encrypt и порядка `update`.

PostgreSQL поднимает другая система. Плейбук только подключается к ней. Внешний Infinispan не используется. Сессии Keycloak 26 — в этой базе.

## Что должно быть у сети

- Белый IP на узле Keycloak (`ansible_host`); DNS A → этот адрес.
- Открыты с интернета: `443/tcp`, при `keycloak_external: true` ещё `80/tcp` (ACME + редирект).
- NTP на узлах Keycloak.
- При двух узлах: небольшая задержка, приватная сеть для JGroups (`keycloak_address`), доступ обоих к PostgreSQL; в группе `keycloak` сначала `active`, затем `passive`.
- Один hostname / issuer OIDC на весь кластер.

## Схема

Один узел (типичный старт). nginx принимает HTTPS на белом IP и проксирует на локальный Keycloak.

```mermaid
flowchart LR
  client([Клиент])
  dns["DNS A<br/>keycloak_hostname"]

  client -->|DNS| dns
  dns -->|белый IP| nginx
  nginx -->|127.0.0.1:8080| kc["Keycloak"]
  kc -->|JDBC| db[("PostgreSQL")]
```

Вход пользователя:

```mermaid
sequenceDiagram
  autonumber
  actor Клиент
  participant nginx
  participant Keycloak
  participant DB as PostgreSQL

  Клиент->>nginx: HTTPS 443 (A → белый IP)
  nginx->>Keycloak: HTTP 127.0.0.1:8080
  Keycloak->>DB: JDBC, сессия и реалм
  DB-->>Keycloak: commit
  Keycloak-->>Клиент: ответ
```

- JDBC URL — из `keycloak_db_hosts` или `keycloak_db_url`.
- Локальный health: `GET /lb-check` → management `/health/ready` (для `status.yml` и своего мониторинга).

## Подготовка

ОС узлов: Ubuntu 24.04/26.04 LTS. Управляющая машина: ansible-core 2.16+. Keycloak — в Docker (JDK внутри образа).

Секреты (admin, БД, LDAP bind, client secret реалмов) — в ansible-vault: `inventories/prod/vault.yml.example` → `group_vars/all/vault.yml`. В `realms/*.yml` пишите `secret: "{{ vault_keycloak_client_<realm>_<clientId> }}"` (плейбук рендерит Jinja).

```bash
cp inventories/prod/vault.yml.example inventories/prod/group_vars/all/vault.yml
# заполните vault_keycloak_admin_password, vault_keycloak_db_password,
# vault_keycloak_ldap_*_bind_password, vault_keycloak_client_platforms_gitlab, …
ansible-vault encrypt inventories/prod/group_vars/all/vault.yml
```

Дальше поправьте `inventories/prod/hosts.yml` и `group_vars/all/main.yml` (`keycloak_hostname` и т.д.).

Без `keycloak_external` nginx получает self-signed на `keycloak_hostname`. Свои файлы — `keycloak_tls_cert_src` и `keycloak_tls_key_src`.

```yaml
keycloak_tls_cert_src: /path/on/controller/fullchain.pem
keycloak_tls_key_src: /path/on/controller/privkey.pem
```

Внешний Keycloak (`keycloak_external: true`) выпускает Let's Encrypt на активном узле: HTTP-01 на порт 80 белого IP. При двух узлах nginx на обоих отдаёт один challenge-файл; сертификат active копирует на passive по SSH (`ansible_user`). Продление каждый день в 03:15.

```yaml
keycloak_external: true
keycloak_acme_email: admin@example.com
```

## Плейбуки

Все команды из корня репозитория, обычно с `--ask-vault-pass`. Inventory по умолчанию — `inventories/prod` (см. `ansible.cfg`).

| Плейбук | Что делает |
| --- | --- |
| `playbooks/site.yml` | Полная установка с нуля: вызывает `platform.yml`, затем `realms.yml`. |
| `playbooks/platform.yml` | База хоста и платформа Keycloak **без** импорта реалмов. |
| `playbooks/configure.yml` | Повторная настройка уже установленных узлов (конфиг, TLS, firewall, CrowdSec) **без** роли `common` и **без** реалмов. |
| `playbooks/realms.yml` | Импорт/обновление реалмов из `realms/*.yml` (один раз на кластер, `run_once`). |
| `playbooks/update.yml` | Обновление образа/конфига Keycloak по одному узлу (порядок inventory: сначала `active`). |
| `playbooks/status.yml` | Только диагностика: `docker compose ps`, `/health/ready`, `/lb-check`. Ничего не меняет. |

### `site.yml`

Импортирует по очереди:

1. `platform.yml`
2. `realms.yml`

Типичный первый запуск:

```bash
ansible-playbook playbooks/site.yml --ask-vault-pass
```

### `platform.yml`

1. **`common`** на всех хостах — пакеты, chrony.
2. **`keycloak`** на группе `keycloak`, `serial: 1` — Docker, Compose в `/opt/keycloak`, контейнер, nginx, TLS (LE / self-signed / свои файлы), systemd-unit `keycloak.service`.
3. **`firewall`** на всех — nftables (`inet keycloak_fw`), UFW гасится.
4. **`crowdsec`** на `keycloak` — разбор логов nginx и бан через nftables.

Реалмы не трогает.

### `configure.yml`

То же, что платформенная часть без `common`:

1. **`keycloak`** (`serial: 1`) — перевыкладка conf/env/compose, pull образа при необходимости, restart при изменениях, ожидание ready, nginx, сертификат.
2. **`firewall`**
3. **`crowdsec`**

Для повседневных правок inventory/vault/TLS/firewall без полного site и без импорта реалмов:

```bash
ansible-playbook playbooks/configure.yml --ask-vault-pass
```

### `realms.yml`

Роль `keycloak_realm` один раз с active-узла (через API на `127.0.0.1:8080`):

- читает `realms/*.yml` (не `*.example`);
- создаёт отсутствующий реалм или обновляет настройки;
- `partialImport` клиентов/ролей/групп/IdP при наличии в файле;
- опционально LDAP из `keycloak_ldap_federations` (AD / FreeIPA на нужные реалмы);
- удаление: `-e '{"keycloak_realms_absent":["apps"]}'`.

```bash
ansible-playbook playbooks/realms.yml --ask-vault-pass
```

### `update.yml`

Только роль `keycloak`, `serial: 1`, порядок inventory. Нужен при смене тега образа (темы/провайдеры в образе) или когда достаточно прогнать роль Keycloak без firewall/CrowdSec:

```bash
ansible-playbook playbooks/update.yml \
  -e keycloak_version=26.8.0 \
  -e keycloak_image=sysadm1989/keycloak:26.8.0 \
  --ask-vault-pass
```

### `status.yml`

На каждом узле Keycloak печатает роль, статус compose, HTTP-коды health и lb-check:

```bash
ansible-playbook playbooks/status.yml
```

### Образ Docker

На узлах крутится `sysadm1989/keycloak:{{ keycloak_version }}` (темы и провайдеры внутри). Серверы — `linux/amd64`:

```bash
cd images/keycloak
docker buildx build --platform linux/amd64 \
  -t sysadm1989/keycloak:26.8.0 \
  --build-arg KEYCLOAK_VERSION=26.8.0 \
  --push .
```

Unit `keycloak.service` вызывает `docker compose up/down` из `/opt/keycloak`.

### Truststores (LDAPS) и Kerberos (только office.corp)

На узле: `/opt/keycloak/truststores/` → в контейнере `/opt/keycloak/conf/truststores` (`truststore-paths`) — CA для LDAPS AD и FreeIPA.  
Kerberos/SPNEGO — только AD `OFFICE.CORP` (`office.corp`): keytab `/opt/keycloak/keytabs/`, `krb5.conf` → `/etc/krb5.conf`. FreeIPA без Kerberos.

```yaml
keycloak_truststores_src: "{{ playbook_dir }}/../files/keycloak/truststores"

keycloak_kerberos_enabled: true
keycloak_kerberos_keytab_src: "{{ playbook_dir }}/../files/keycloak/keytabs/keycloak.keytab"
keycloak_kerberos_krb5_src: "{{ playbook_dir }}/../files/keycloak/krb5.conf"
# или шаблон: keycloak_kerberos_default_realm + keycloak_kerberos_realms (OFFICE.CORP)
```

Пример `krb5.conf`: `files/keycloak/krb5.conf.example`. В Admin Console: Key tab = `/opt/keycloak/keytabs/keycloak.keytab`, realm `OFFICE.CORP`, principal `HTTP/sso.nemero.online@OFFICE.CORP`. Keytab в git не кладите.

Базу и пользователя создаёт другая система. Пользователь `keycloak_db_user` должен владеть базой `keycloak_db_name`, пароль — ключ `db_password` в HashiCorp Vault (`prod/keycloak`).

```yaml
keycloak_db_hosts:
  - keycloak.cluster.example
keycloak_db_tls_mode: verify-server
keycloak_db_ca_file: /path/on/controller/db-ca.pem
```

Несколько адресов означают выбор текущего primary (`targetServerType=primary`). Один адрес подключается напрямую. В Keycloak 26 для TLS к БД: `disabled` или `verify-server` (нужен `keycloak_db_ca_file`). Полный JDBC вместо списка — `keycloak_db_url`; вместе со списком его задавать нельзя.

## Реалмы

Файлы `realms/*.yml` — тот же документ, что у Admin API, только в YAML. Полный экспорт записывается списком `realms:`. Примеры: `realms/apps.yml.example`, `realms/platforms.yml`, `realms/kubernetes.yml.example`. Плейбук сам переводит YAML в JSON запроса.

```bash
# platforms.yml уже в репозитории; kubernetes клиентов — из example:
cp realms/kubernetes.yml.example realms/kubernetes.yml
ansible-playbook playbooks/realms.yml --ask-vault-pass
```

Реалм **platforms** (тема `nemero-ad`) — общие SSO для внутренних платформ; клиент GitLab внутри него — `gitlab` (issuer `…/realms/platforms`). Реалм **atlassian** — тот же AD, группы из `OU=Atlassian`. Kubernetes — отдельный реалм из example. Учётные записи между реалмами не общие. LDAP — `keycloak_ldap_federations`. Частично заполненный элемент останавливает импорт. После правок — `playbooks/realms.yml`. Регистрация и смена пароля выключены. Группы в токене — claim `groups`.

- Нет реалма — создаётся целиком.
- Реалм уже есть — обновляются его настройки, клиенты, роли, группы и identity providers (`ifResourceExists=OVERWRITE`).
- Пользователи из файла применяются только с `-e keycloak_realm_import_users=true`.
- Удаление: `-e '{"keycloak_realms_absent":["apps"]}'`.
- Секреты клиентов — только в vault; при OVERWRITE значение из vault перезаписывает секрет в Keycloak.

Провайдеры — `images/keycloak/providers/*.jar`. Темы — `images/keycloak/themes/<name>/`. Они попадают в образ при `docker build` и в список Login theme реалма.

NEMERO — словознак с визитки (синий `#2E4298`, россыпь точек у O). Темы login:

- `nemero-ad` — светлая сторона визитки, Active Directory
- `nemero-freeipa` — синее поле, FreeIPA
- `nemero-master` — синее поле и бейдж MASTER REALM; задаётся в `realms/master.yml`

Превью: `open images/keycloak/themes/preview.html` (в браузере; встроенный preview IDE часто пустой) или `images/keycloak/themes/preview.jpg`. В реалме поле `loginTheme`. Смена темы — новый тег образа и `playbooks/update.yml`.

Реалм **ya360** — пример SAML IdP для Yandex 360 (`realms/ya360.yml.example`). Чтобы включить: `cp realms/ya360.yml.example realms/ya360.yml`. Админ и поля кабинета 360 — в `realms/ya360.md`.

## Порты

| Кто | Куда | Порт |
| --- | --- | --- |
| клиенты (белый IP) | nginx | 443 |
| Let's Encrypt + редирект HTTP, при `keycloak_external: true` | nginx | 80 |
| локальный health `GET /lb-check` | nginx | 80 или 443 |
| nginx | Keycloak | 127.0.0.1:8080 и :9000 |
| импорт реалмов на самом узле | Keycloak | 127.0.0.1:8080 |
| Keycloak active | Keycloak passive | 7800, 57800 |
| Keycloak | PostgreSQL | 5433 |

Порты 7800 и 57800 нужны только между двумя узлами Keycloak. Keycloak слушает 8080 и 9000 только на `127.0.0.1`. Снаружи их нет: на 9000 ещё и `/metrics`. Порт 80 с интернета открыт при `keycloak_external: true`.

## Внешний SSO

Снаружи открыт 443 на белом IP. Порт 80 — когда `keycloak_external: true` (ACME и редирект на HTTPS). Остальное режет **nftables** (таблица `inet keycloak_fw`, без `flush ruleset` — с Docker не конфликтует). UFW отключается. Правила: `nft list table inet keycloak_fw`.

- `keycloak_external: true` + `keycloak_hostname` + `keycloak_acme_email` → Let's Encrypt на активном узле, копия на пассивном.
- Иначе без файлов сертификата → self-signed на `keycloak_hostname`.
- TLS завершает nginx. Клиентские `X-Forwarded-*` до Keycloak не доходят: nginx подставляет свои.
- Консоль администратора доступна на том же имени, что и вход пользователей. Плейбук её отдельно не закрывает.
- SSH по умолчанию открыт (`firewall_ssh_cidrs: [0.0.0.0/0]`). Сузьте список до сети администраторов. После смены CIDR снова `configure.yml`.

## Чего проект не делает

Не создаёт DNS A-запись и PostgreSQL. Не ставит мониторинг. Для TLS к базе задайте `keycloak_db_tls_mode` и `keycloak_db_ca_file`.

**CrowdSec** (роль `roles/crowdsec`) читает логи nginx Keycloak и SSH, банит через **nftables**: для обычных пользователей вход не меняется. Whitelist: `10.0.0.0/8` и localhost. LAPI — `127.0.0.1:8088` (не `:8080`). Проверка: `cscli metrics`, `cscli decisions list`, `systemctl status crowdsec crowdsec-firewall-bouncer`.
