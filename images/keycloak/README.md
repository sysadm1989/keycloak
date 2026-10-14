# Keycloak

Универсальный Docker-образ Keycloak на базе [quay.io/keycloak/keycloak](https://quay.io/repository/keycloak/keycloak). В образ входят темы из `themes/` и JAR из `providers/`. Версия базового образа задаётся build-arg `KEYCLOAK_VERSION` (по умолчанию 26.8.0).

Сборка для PostgreSQL + Infinispan (`ispn`). Hostname, JDBC и пароли не зашиваются: их задаёт Ansible через `/etc/keycloak/keycloak.conf` и `keycloak.env`.

Документация по Kerberos/SPNEGO для окружения **nemero** (`OFFICE.CORP`, `sso.nemero.online`) — ниже и в `docs/`.

## Содержание

- [Сборка образа](#сборка-образа)
- [Настройка Keycloak](#настройка-keycloak)
- [Переменные окружения `.env`](docs/keycloak-env.md)
- [Клиент macOS](docs/macos-kerberos.md) — Chrome, Yandex Browser, Safari
- [Настройка nginx](docs/nginx-keycloak-spnego.md)

---

## Сборка образа

```bash
docker buildx build --platform linux/amd64 \
  -t sysadm1989/keycloak:26.8.0 \
  --build-arg KEYCLOAK_VERSION=26.8.0 \
  --push .
docker run --rm -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  keycloak:26.8.0 start-dev
```

Темы: `themes/<name>/…`. Провайдеры: `providers/*.jar`. После добавления файлов пересоберите образ.

Параметры БД и hostname в бою — через переменные окружения или `keycloak.conf` (`KC_DB_URL`, `KC_HOSTNAME` и др.), см. [документацию Keycloak](https://www.keycloak.org/server/all-config).

## Настройка Keycloak

### Предварительные требования

1. Kerberos realm и KDC (Samba AD / Active Directory).
2. SPN: `HTTP/sso.nemero.online@OFFICE.CORP`.
3. Keytab с ключами **HTTP SPN** (не учётки `svc_keycloak_sso`).
4. Вход пользователей по **FQDN** `sso.nemero.online`, не по IP.

### Параметры (nemero)

| Параметр | Значение |
|----------|----------|
| SPN / Server principal | `HTTP/sso.nemero.online@OFFICE.CORP` |
| Kerberos realm | `OFFICE.CORP` |
| Hostname | `sso.nemero.online` |
| Учётка с SPN | `svc_keycloak_sso` |
| Keytab (хост) | `/apps/keycloak/keytabs/keycloak.keytab` |
| Keytab (контейнер) | `/opt/keycloak/keytabs/keycloak.keytab` |
| krb5.conf (контейнер) | `/etc/krb5.conf` |
| KDC | `office.corp` |

### Keytab (Samba AD)

SPN на учётке:

```bash
samba-tool user show svc_keycloak_sso | grep servicePrincipalName
# servicePrincipalName: HTTP/sso.nemero.online
```

Экспорт keytab — **только для HTTP principal**:

```bash
samba-tool domain exportkeytab /tmp/keycloak.keytab \
  --principal=HTTP/sso.nemero.online@OFFICE.CORP

klist -ket /tmp/keycloak.keytab
kinit -kt /tmp/keycloak.keytab HTTP/sso.nemero.online@OFFICE.CORP
klist
```

> Не путать с `svc_keycloak_sso@OFFICE.CORP` — это user principal, Keycloak его не использует.

После смены пароля учётки keytab нужно перевыпустить:

```bash
samba-tool user setpassword svc_keycloak_sso --newpassword='<пароль>'
samba-tool domain exportkeytab /tmp/keycloak.keytab \
  --principal=HTTP/sso.nemero.online@OFFICE.CORP
```

### krb5.conf (сервер)

Файл на хосте: `/apps/keycloak/krb5.conf`. JVM читает только **`/etc/krb5.conf`** в контейнере.

```ini
[libdefaults]
    default_realm = OFFICE.CORP
    dns_lookup_realm = false
    dns_lookup_kdc = false
    rdns = false
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
    OFFICE.CORP = {
        kdc = office.corp
        admin_server = office.corp
    }

[domain_realm]
    .nemero.online = OFFICE.CORP
    .office.corp = OFFICE.CORP
    nemero.online = OFFICE.CORP
    office.corp = OFFICE.CORP
```

### Docker Compose

Полный пример **`.env`** и `docker-compose.yml`: **[docs/keycloak-env.md](docs/keycloak-env.md)**.

Кратко — `env_file: .env`, volumes: keytab, `krb5.conf`, truststores (см. документ).

### Admin Console (LDAP + Kerberos)

| Поле | Значение |
|------|----------|
| Allow Kerberos authentication | **On** |
| Kerberos realm | `OFFICE.CORP` |
| Server principal | `HTTP/sso.nemero.online@OFFICE.CORP` |
| Key tab | `/opt/keycloak/keytabs/keycloak.keytab` |
| Kerberos principal attribute | `userPrincipalName` |
| Debug | **On** (на время отладки) |

Порядок:

1. **Authentication → Browser flow** — **Kerberos**: `Alternative` или `Required` (в `master` оставить `Disabled`).
2. **User Federation → LDAP** → Kerberos integration.
3. Заполнить поля, нажать **Save** внизу страницы.
4. F5 — поля не должны быть пустыми.

### Почему настройки «сбиваются»

Keycloak не сохранит Kerberos без **Server principal** и **Key tab** (ошибка «You must enter a key tab»).

| Причина | Решение |
|---------|---------|
| Не нажали Save | Save внизу LDAP-провайдера, затем F5 |
| Другой realm | Проверить имя realm вверху слева |
| БД не персистентна | `KC_DB=postgres` и рабочий `KC_DB_URL` |
| Импорт realm | GitOps/`kc.sh import` перезаписывает ручные правки |

Отключить Kerberos в `master` через CLI:

```bash
/opt/keycloak/bin/kcadm.sh get authentication/flows/browser/executions -r master
/opt/keycloak/bin/kcadm.sh update authentication/flows/browser/executions -r master \
  -b '{"id":"<EXECUTION_ID>","requirement":"DISABLED"}'
```

### Логирование

См. [docs/keycloak-env.md](docs/keycloak-env.md) — `KC_LOG_LEVEL`, `JAVA_OPTS_APPEND`.

Плюс **Debug** в User Federation.

### Проверка (сервер)

```bash
docker inspect keycloak-keycloak-1 --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
docker exec keycloak-keycloak-1 klist -ket /opt/keycloak/keytabs/keycloak.keytab
docker exec keycloak-keycloak-1 cat /etc/krb5.conf

kinit -kt /apps/keycloak/keytabs/keycloak.keytab HTTP/sso.nemero.online@OFFICE.CORP
kvno HTTP/sso.nemero.online@OFFICE.CORP
```

### Ошибки шифрования (RC4 vs AES)

```text
Cannot find key ... RC4 / AES256
```

| Причина | Решение |
|---------|---------|
| KVNO mismatch | Перевыпустить keytab после смены пароля |
| Keytab для user, не HTTP | `exportkeytab --principal=HTTP/sso.nemero.online@OFFICE.CORP` |
| RC4 vs AES | AES keytab + AES в `krb5.conf` на сервере и Mac |

Подробнее: [Keycloak Server Admin — Kerberos](https://www.keycloak.org/docs/latest/server_admin/index.html#_kerberos).

---

## Клиент macOS

Подробная инструкция: **[docs/macos-kerberos.md](docs/macos-kerberos.md)** — `krb5.conf`, `kinit`, Google Chrome, Yandex Browser, Safari, диагностика.

Кратко:

```bash
kinit ваш_логин@OFFICE.CORP
# Chrome: AuthServerAllowlist = *.nemero.online в chrome://policy
# Yandex: AuthServerAllowlist = *.nemero.online в browser://policy
# Вход: https://sso.nemero.online
```

---

## Настройка nginx

Подробная инструкция и рабочий пример **`/etc/nginx/conf.d/sso.conf`**: **[docs/nginx-keycloak-spnego.md](docs/nginx-keycloak-spnego.md)**.

Кратко — критично для SPNEGO:

```nginx
proxy_set_header Authorization $http_authorization;
proxy_pass_header Authorization;
server_name sso.nemero.online;   # = SPN и KC_HOSTNAME
```

Переменные Keycloak: `KC_HOSTNAME=sso.nemero.online`, `KC_PROXY=edge`, `KC_HOSTNAME_STRICT=true`.

---
