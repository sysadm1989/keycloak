# nginx перед Keycloak (Kerberos / SPNEGO)

Прокси для `https://sso.nemero.online` → Keycloak на `127.0.0.1:8080`.

SPNEGO ломается, если nginx **не пробрасывает** `Authorization`, меняет hostname или обрезает большие Kerberos-токены.

См. также: [настройка Keycloak](../README.md#настройка-keycloak), [клиент macOS](macos-kerberos.md).

---

## 1. Фрагмент `nginx.conf` (блок `http {}`)

`log_format` и `map` **нельзя** класть в `conf.d/*.conf` — только в `/etc/nginx/nginx.conf` внутри `http { }`, обычно перед `include /etc/nginx/conf.d/*.conf;`:

```nginx
map $http_authorization $auth_present {
    default "yes";
    ""      "no";
}

log_format keycloak_spnego '$remote_addr [$time_local] "$request" $status '
                           'auth_present=$auth_present';
```

Проверка:

```bash
nginx -t && systemctl reload nginx
```

---

## 2. `/etc/nginx/conf.d/sso.conf`

Рабочий пример для **nemero**:

```nginx
upstream keycloak {
    server 127.0.0.1:8080;
    keepalive 32;
}

# Редирект с HTTP на HTTPS
server {
    listen 80;
    server_name sso.nemero.online;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name sso.nemero.online;

    large_client_header_buffers 4 16k;
    client_header_buffer_size 8k;

    ssl_certificate     /etc/nginx/ssl/sso.nemero.online.crt;
    ssl_certificate_key /etc/nginx/ssl/sso.nemero.online.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    access_log /var/log/nginx/keycloak_access.log keycloak_spnego;
    error_log  /var/log/nginx/keycloak_error.log;

    location / {
        proxy_pass http://keycloak;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  $server_port;

        # критично для Kerberos/SPNEGO
        proxy_set_header Authorization $http_authorization;
        proxy_pass_header Authorization;

        proxy_http_version 1.1;
        proxy_set_header Connection "";

        proxy_buffer_size         128k;
        proxy_buffers             4 256k;
        proxy_busy_buffers_size   256k;

        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }
}
```

### Что важно

| Директива | Зачем |
|-----------|--------|
| `server_name sso.nemero.online` | совпадает с SPN `HTTP/sso.nemero.online@OFFICE.CORP` |
| `proxy_set_header Authorization $http_authorization` | передаёт `Negotiate` токен в Keycloak |
| `proxy_pass_header Authorization` | не скрывает заголовок в ответе (если нужен) |
| `X-Forwarded-Host` / `X-Forwarded-Proto` | Keycloak видит правильный hostname за прокси |
| `large_client_header_buffers` | Kerberos-токен в `Authorization` может быть большим |
| `return 301 https://$host$request_uri` | редирект HTTP→HTTPS с сохранением host и path |

---

## 3. Переменные Keycloak за nginx

```bash
KC_HOSTNAME=sso.nemero.online
KC_HOSTNAME_STRICT=true
KC_PROXY=edge
KC_HTTP_ENABLED=true
```

`KC_HOSTNAME` должен совпадать с `server_name` в nginx и с именем в SPN.

---

## 4. Проверка SPNEGO через лог nginx

После входа с клиента (Chrome/Safari):

```bash
tail -f /var/log/nginx/keycloak_access.log
```

Ожидаемый успешный сценарий Kerberos:

```
GET .../openid-connect/auth ... 401 auth_present=no     ← challenge
GET .../openid-connect/auth ... 302 auth_present=yes      ← Negotiate принят
```

Если на **всех** запросах `auth_present=no` — браузер не шлёт токен (см. [macos-kerberos.md](macos-kerberos.md): Chrome + FILE-кэш, allowlist).

Тест, что nginx видит заголовок:

```bash
curl -sk -o /dev/null \
  -H "Authorization: Negotiate test" \
  "https://sso.nemero.online/realms/grafana/.well-known/openid-configuration"

tail -1 /var/log/nginx/keycloak_access.log
# auth_present=yes
```

---

## 5. Проверка на клиенте

В DevTools → Network:

1. Первый запрос → **401** + `WWW-Authenticate: Negotiate`
2. Повторный → `Authorization: Negotiate ...`
3. Ответ **302** (редирект), не форма логина

---

## 6. Типичные ошибки

| Симптом в логе / браузере | Причина | Решение |
|---------------------------|---------|---------|
| `auth_present=no` на 2-м GET | Chrome не шлёт Negotiate | FILE-кэш + `AuthServerAllowlist` |
| `auth_present=no` везде, Safari OK | только Chrome | [macos-kerberos.md](macos-kerberos.md) |
| `auth_present=yes`, но форма логина | Keycloak/realm/keytab | LDAP Kerberos в нужном realm |
| Нет `WWW-Authenticate: Negotiate` | Kerberos выключен в realm | Browser flow → Kerberos |
| 400 Bad Request | токен обрезан | увеличить `large_client_header_buffers` |
| SPN mismatch | другой hostname | только FQDN `sso.nemero.online`, не IP |
| `return 301 https://;` | битый редирект | `https://$host$request_uri` |

---

## 7. Откат debug-лога

Вернуть обычный формат:

```nginx
access_log /var/log/nginx/keycloak_access.log;
```

Удалить `map` и `log_format keycloak_spnego` из `nginx.conf`, если больше не нужны.
