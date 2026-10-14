# Переменные окружения Keycloak (`.env`)

Пример для развёртывания на хосте: `/ops/keycloak/.env`.

Связанные документы: [README](../README.md#настройка-keycloak), [nginx](nginx-keycloak-spnego.md), [macOS Kerberos](macos-kerberos.md).

> Пароли и секреты в git **не коммитить**. В примере ниже — плейсхолдеры; на сервере подставьте реальные значения.

---

## Пример `/ops/keycloak/.env`

```bash
# --- Прокси и публичный URL (критично для SPNEGO / SPN) ---
KC_HTTP_ENABLED=true
KC_PROXY=edge
KC_PROXY_HEADERS=xforwarded
KC_HOSTNAME=sso.nemero.online
KC_HOSTNAME_STRICT=true

# --- Отладка Kerberos / SPNEGO (убрать или снизить уровень в prod) ---
KC_LOG_LEVEL=org.keycloak:TRACE
JAVA_OPTS_APPEND="-Dsun.security.krb5.debug=true -Dsun.security.spnego.debug=true"

# --- Health / metrics ---
KC_HEALTH_ENABLED=true
KC_METRICS_ENABLED=true

# --- Truststore для LDAPS (раскомментировать при необходимости) ---
#KC_TRUSTSTORE_PATHS=/opt/keycloak/conf/truststores

# --- PostgreSQL (обязательно для сохранения настроек realm / Kerberos) ---
KC_DB=postgres
KC_DB_URL_HOST=keycloackdb.nemero.online
KC_DB_URL_PORT=5432
KC_DB_URL_DATABASE=keycloak
KC_DB_USERNAME=keycloak
KC_DB_PASSWORD=<секрет>

# --- Bootstrap admin (только первый старт; сменить после установки) ---
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=<секрет>
```

---

## Описание переменных

### Прокси и hostname

| Переменная | Значение | Зачем |
|------------|----------|--------|
| `KC_HOSTNAME` | `sso.nemero.online` | Публичный FQDN = имя в SPN `HTTP/sso.nemero.online@OFFICE.CORP` |
| `KC_HOSTNAME_STRICT` | `true` | Запрет других Host-заголовков |
| `KC_PROXY` | `edge` | Keycloak за reverse proxy (nginx) |
| `KC_PROXY_HEADERS` | `xforwarded` | Читать `X-Forwarded-*` от nginx |
| `KC_HTTP_ENABLED` | `true` | HTTP внутри контейнера (nginx терминирует TLS) |

Должно совпадать с `server_name` в [nginx](nginx-keycloak-spnego.md).

### Отладка

| Переменная | Значение | Зачем |
|------------|----------|--------|
| `KC_LOG_LEVEL` | `org.keycloak:TRACE` | Подробные логи Keycloak (`auth-spnego`, LDAP) |
| `JAVA_OPTS_APPEND` | `-Dsun.security.krb5.debug=true ...` | JVM-логи Kerberos/GSS в stdout контейнера |

В production после отладки:

```bash
KC_LOG_LEVEL=info
# убрать JAVA_OPTS_APPEND или оставить только нужные флаги
```

### База данных

| Переменная | Значение |
|------------|----------|
| `KC_DB` | `postgres` |
| `KC_DB_URL_HOST` | хост PostgreSQL |
| `KC_DB_URL_PORT` | `5432` |
| `KC_DB_URL_DATABASE` | имя БД |
| `KC_DB_USERNAME` / `KC_DB_PASSWORD` | учётка БД |

Без персистентной БД настройки Kerberos в Admin Console **теряются** после пересоздания контейнера.

### Bootstrap admin

`KC_BOOTSTRAP_ADMIN_*` — создаёт admin только при **первом** запуске пустой БД. Дальше пароль меняется в Admin Console или через `kcadm.sh`.

---

## Docker Compose

Путь на хосте: `/apps/keycloak/docker-compose.yml`.

```yaml
services:
  keycloak:
    image: ci.repo.nemero.online/images/ci/keycloak:26.8.0
    restart: unless-stopped
    ports:
      - "8080:8080"
      - "9000:9000"
    env_file:
      - .env
    volumes:
      - /apps/keycloak/keytabs:/opt/keycloak/keytabs:ro
      - /apps/keycloak/truststores:/opt/keycloak/conf/truststores:ro
      - /apps/keycloak/krb5.conf:/etc/krb5.conf:ro
```

Переменные из `.env` подхватываются через `env_file`. Дублировать `KC_LOG_LEVEL` и `JAVA_OPTS_APPEND` в `environment:` не обязательно, если они уже в `.env`.

### Volumes (Kerberos)

| Хост | Контейнер | Назначение |
|------|-----------|------------|
| `/apps/keycloak/keytabs/keycloak.keytab` | `/opt/keycloak/keytabs/keycloak.keytab` | HTTP SPN |
| `/apps/keycloak/krb5.conf` | `/etc/krb5.conf` | realm `OFFICE.CORP`, KDC `office.corp` |
| `/apps/keycloak/truststores/` | `/opt/keycloak/conf/truststores/` | CA для LDAPS (опционально) |

Файл `krb5.conf` должен **существовать на хосте до** `docker compose up`. Иначе Docker создаст каталог вместо файла.

```bash
docker compose up -d --force-recreate   # после смены volumes или .env
```

Права на keytab:

```bash
chown 1000:1000 /apps/keycloak/keytabs/keycloak.keytab
chmod 440 /apps/keycloak/keytabs/keycloak.keytab
```

---

## Проверка после изменения `.env`

```bash
cd /apps/keycloak
docker compose config   # убедиться, что env подхватился
docker compose up -d --force-recreate
docker logs -f keycloak-keycloak-1 2>&1 | grep -iE 'kerberos|spnego|gss'
```

```bash
docker exec keycloak-keycloak-1 klist -ket /opt/keycloak/keytabs/keycloak.keytab
docker exec keycloak-keycloak-1 cat /etc/krb5.conf
```

---

## OpenTelemetry (опционально)

Если в логах:

```
Failed to export TraceRequestMarshaler ... Connection refused: localhost/127.0.0.1:4317
```

— включён экспорт трейсов, но коллектор не запущен. На Kerberos **не влияет**. Отключить или указать endpoint OTLP, если трейсинг не нужен.

---

## Чеклист согласованности

| Компонент | Значение |
|-----------|----------|
| `KC_HOSTNAME` | `sso.nemero.online` |
| nginx `server_name` | `sso.nemero.online` |
| SPN / Server principal | `HTTP/sso.nemero.online@OFFICE.CORP` |
| Key tab в Admin Console | `/opt/keycloak/keytabs/keycloak.keytab` |
| krb5.conf KDC | `office.corp` |
