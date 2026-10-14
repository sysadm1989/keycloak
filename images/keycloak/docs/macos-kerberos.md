# Kerberos на macOS (Chrome и Yandex Browser)

Инструкция для входа в Keycloak через SPNEGO с Mac.

Параметры окружения **nemero**:

| Параметр | Значение |
|----------|----------|
| Realm | `OFFICE.CORP` |
| KDC | `office.corp` |
| URL Keycloak | `https://sso.nemero.online` |
| SPN | `HTTP/sso.nemero.online@OFFICE.CORP` |

См. также: [настройка Keycloak](../README.md#настройка-keycloak).

---

## 1. krb5.conf

```bash
sudo tee /etc/krb5.conf <<'EOF'
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
EOF
```

Проверка сети до KDC:

```bash
ping office.corp
nc -zv office.corp 88
```

---

## 2. Kerberos-тикет

Браузер использует **ваш** TGT из системного кэша. Keytab на Mac **не нужен**.

### Обычная работа

При входе в **macOS** Kerberos-тикет **сам не появляется** — если Mac не в домене AD и не настроен авто-SSO. Перед заходом в Keycloak нужен TGT в кэше:

```bash
kinit ваш_логин@OFFICE.CORP
klist -e
```

`kdestroy` перед `kinit` **не нужен**, если в кэше нет старого или чужого тикета. Достаточно одного `kinit` на сессию (пока тикет не истёк).

Если Mac **привязан к AD** и тикет уже есть после входа в систему — проверьте `klist -e`; при наличии TGT отдельный `kinit` не требуется.

В `klist -e` должен быть TGT с `aes256` или `aes128` (не `rc4`).

### Только при диагностике

`kdestroy && kinit` — если тикет устарел, после смены keytab на сервере или при ошибках `AES256 ... Cannot find key`:

```bash
kdestroy && kinit ваш_логин@OFFICE.CORP
klist -e
```

---

## 3. Google Chrome

Chrome на macOS требует **две** вещи: политику allowlist **и** FILE-кэш Kerberos (см. раздел 2). Safari при этом может работать без доп. настроек.

> `Authorization: Negotiate` Chrome добавляет сам при `401` + `WWW-Authenticate: Negotiate`. Вручную в DevTools задать нельзя.

### Полная настройка (рабочий порядок)

```bash
# 1. FILE-кэш (критично для Chrome)
export KRB5CCNAME=FILE:/tmp/krb5cc_$(id -u)
kdestroy
kinit ваш_логин@OFFICE.CORP
klist   # FILE:/tmp/krb5cc_..., не API:

# 2. Политики Chrome
defaults write com.google.Chrome AuthServerAllowlist '*.nemero.online,sso.nemero.online'
defaults write com.google.Chrome AuthNegotiateDelegateAllowlist '*.nemero.online,sso.nemero.online'
defaults write com.google.Chrome DisableAuthNegotiateCnameLookup -bool true
defaults delete com.google.Chrome AuthServerWhitelist 2>/dev/null
defaults delete com.google.Chrome AuthNegotiateDelegateWhitelist 2>/dev/null

# 3. Перезапуск Chrome из этого же терминала
pkill -x "Google Chrome" 2>/dev/null; sleep 1
open -a "Google Chrome"
```

### Способ 1 — defaults (пользователь)

```bash
defaults write com.google.Chrome AuthServerAllowlist '*.nemero.online,sso.nemero.online'
defaults write com.google.Chrome AuthNegotiateDelegateAllowlist '*.nemero.online,sso.nemero.online'
defaults read com.google.Chrome AuthServerAllowlist
```

### Способ 2 — Managed Preferences (системные)

```bash
sudo defaults write "/Library/Managed Preferences/com.google.Chrome" \
  AuthServerAllowlist '*.nemero.online,sso.nemero.online'
sudo defaults write "/Library/Managed Preferences/com.google.Chrome" \
  AuthNegotiateDelegateAllowlist '*.nemero.online,sso.nemero.online'
```

Или plist в `~/Library/Managed Preferences/com.google.Chrome.plist` / `/Library/Managed Preferences/`.

### DisableAuthNegotiateCnameLookup

По умолчанию Chrome при Negotiate делает **CNAME lookup** и строит SPN по каноническому имени DNS. Если SPN в AD — `HTTP/sso.nemero.online@OFFICE.CORP`, а CNAME указывает на другое имя, Kerberos ломается.

**Пользователь:**

```bash
defaults write com.google.Chrome DisableAuthNegotiateCnameLookup -bool true
defaults read com.google.Chrome DisableAuthNegotiateCnameLookup
```

**Системно (Managed Preferences):**

```bash
sudo defaults write "/Library/Managed Preferences/com.google.Chrome" \
  DisableAuthNegotiateCnameLookup -bool true
```

**plist** (вместе с allowlist):

```xml
<key>DisableAuthNegotiateCnameLookup</key>
<true/>
```

Проверка: `chrome://policy` → **DisableAuthNegotiateCnameLookup** = `true`, статус **OK**. Нужен **полный перезапуск** Chrome (`pkill -x "Google Chrome"`).

### Скрипт запуска на каждый день

`~/bin/chrome-sso.sh`:

```bash
#!/bin/bash
export KRB5CCNAME=FILE:/tmp/krb5cc_$(id -u)
klist -s 2>/dev/null || kinit ваш_логин@OFFICE.CORP || exit 1
pkill -x "Google Chrome" 2>/dev/null; sleep 1
open -a "Google Chrome"
```

```bash
chmod +x ~/bin/chrome-sso.sh
```

### Применение

1. **`KRB5CCNAME=FILE:...`** + **`kinit`** — без FILE-кэша Chrome не шлёт Negotiate.
2. Политики в `chrome://policy` → **AuthServerAllowlist** статус **OK**.
3. Полностью убить Chrome: `pkill -x "Google Chrome"`.
4. Запускать Chrome **после** `kinit` (из терминала или скрипта).
5. Network: второй GET к `sso.nemero.online` → `Authorization: Negotiate`.
6. На nginx: `auth_present=yes` на втором GET (если включён debug-лог).

### Быстрый тест с флагами (один запуск)

```bash
export KRB5CCNAME=FILE:/tmp/krb5cc_$(id -u)
kinit ваш_логин@OFFICE.CORP
pkill -x "Google Chrome" 2>/dev/null

"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --auth-server-whitelist="*.nemero.online,sso.nemero.online" \
  --auth-negotiate-delegate-whitelist="*.nemero.online,sso.nemero.online"
```

### Chrome не шлёт Negotiate — чеклист

| Проверка | Ожидание |
|----------|----------|
| `klist` | `FILE:/tmp/krb5cc_...`, **не** `API:...` |
| `chrome://policy` | AuthServerAllowlist **OK** |
| nginx (debug) | 2-й GET: `auth_present=yes` |
| DevTools Network | `Authorization: Negotiate` на 2-м GET |
| Устаревшие ключи | нет `AuthServerWhitelist` |
| Safari работает, Chrome нет | почти всегда **API vs FILE** кэш |

---

## 4. Yandex Browser

Яндекс Браузер на базе Chromium — для SPNEGO нужна политика **`AuthServerAllowlist`**.

### Если `browser://policy` пустой (как на скриншоте)

Политики **не применены**. Пока в разделе «Политики Яндекс Браузера» пусто — `Authorization: Negotiate` не появится.

Проверьте версию: **Помощь → О браузере**.
- **Браузер для организаций** — политики через Managed Preferences / mobileconfig ([документация](https://browser.yandex.ru/support/browser-corporate/ru/deployment/mac-os)).
- **Обычный** Яндекс Браузер — Managed Preferences часто **не работают**; используйте запуск с флагами (см. ниже) или установите корпоративную версию.

### Способ 1 — defaults в Managed Preferences (рекомендуется для корп. версии)

Официальный способ Яндекса — через `defaults`, не через `tee`:

```bash
kinit ваш_логин@OFFICE.CORP

sudo mkdir -p "/Library/Managed Preferences"

sudo defaults write "/Library/Managed Preferences/ru.yandex.desktop.yandex-browser" \
  AuthServerAllowlist '*.nemero.online,sso.nemero.online'

sudo defaults write "/Library/Managed Preferences/ru.yandex.desktop.yandex-browser" \
  AuthNegotiateDelegateAllowlist '*.nemero.online,sso.nemero.online'
```

Для одного пользователя (без sudo):

```bash
mkdir -p ~/Library/Managed\ Preferences

defaults write ~/Library/Managed\ Preferences/ru.yandex.desktop.yandex-browser \
  AuthServerAllowlist '*.nemero.online,sso.nemero.online'

defaults write ~/Library/Managed\ Preferences/ru.yandex.desktop.yandex-browser \
  AuthNegotiateDelegateAllowlist '*.nemero.online,sso.nemero.online'
```

Проверка в терминале:

```bash
defaults read "/Library/Managed Preferences/ru.yandex.desktop.yandex-browser"
# или для пользователя:
defaults read ~/Library/Managed\ Preferences/ru.yandex.desktop.yandex-browser
```

### Способ 2 — mobileconfig (корпоративная версия)

Если defaults не помог — установите профиль. Создайте файл `yandex-kerberos.mobileconfig`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
   <key>PayloadContent</key>
   <array>
      <dict>
         <key>AuthServerAllowlist</key>
         <string>*.nemero.online,sso.nemero.online</string>
         <key>AuthNegotiateDelegateAllowlist</key>
         <string>*.nemero.online,sso.nemero.online</string>
         <key>PayloadDisplayName</key>
         <string>Yandex Browser Kerberos</string>
         <key>PayloadIdentifier</key>
         <string>ru.yandex.desktop.yandex-browser.kerberos</string>
         <key>PayloadType</key>
         <string>ru.yandex.desktop.yandex-browser</string>
         <key>PayloadUUID</key>
         <string>A1B2C3D4-E5F6-7890-ABCD-EF1234567890</string>
         <key>PayloadVersion</key>
         <integer>1</integer>
      </dict>
   </array>
   <key>PayloadDescription</key>
   <string>Kerberos SSO for sso.nemero.online</string>
   <key>PayloadDisplayName</key>
   <string>Yandex Browser SSO</string>
   <key>PayloadIdentifier</key>
   <string>corp.nemero.yandex-browser.sso</string>
   <key>PayloadScope</key>
   <string>System</string>
   <key>PayloadType</key>
   <string>Configuration</string>
   <key>PayloadUUID</key>
   <string>B2C3D4E5-F6A7-8901-BCDE-F12345678901</string>
   <key>PayloadVersion</key>
   <integer>1</integer>
</dict>
</plist>
```

Дважды кликнуть файл → **Системные настройки → Конфиденциальность и безопасность → Профили** → Установить.

### Способ 3 — флаги запуска (обычный Яндекс Браузер)

Если `browser://policy` остаётся пустым — политики ОС не поддерживаются, но Kerberos можно проверить так:

```bash
kinit ваш_логин@OFFICE.CORP
pkill -x "Yandex" 2>/dev/null

"/Applications/Yandex.app/Contents/MacOS/Yandex" \
  --auth-server-whitelist="*.nemero.online,sso.nemero.online" \
  --auth-negotiate-delegate-whitelist="*.nemero.online,sso.nemero.online"
```

> Путь к исполняемому файлу может отличаться: `Yandex Browser.app` вместо `Yandex.app`. Найти: `ls /Applications/*.app/Contents/MacOS/`

### Применение

1. `kinit` **до** запуска браузера.
2. Полностью закрыть браузер (`Cmd+Q` или `pkill`).
3. Открыть снова.
4. В `browser://policy` нажать **«Повторно загрузить политики»**.
5. Должна появиться строка **AuthServerAllowlist** = `*.nemero.online,sso.nemero.online`.

---

## 5. Safari (опционально)

Safari использует системный Kerberos — достаточно `kinit` и захода на `https://sso.nemero.online`. Отдельные политики браузера не нужны.

---

## 6. Вход в Keycloak

1. Убедиться, что `klist` показывает TGT.
2. Открыть **только FQDN**: `https://sso.nemero.online/realms/...`
3. Не использовать IP или другой hostname — SPN `HTTP/sso.nemero.online` не совпадёт.

---

## 7. Проверка в DevTools

Открыть инструменты разработчика → вкладка **Network**:

| Шаг | Ожидание |
|-----|----------|
| 1-й запрос | ответ **401**, заголовок `WWW-Authenticate: Negotiate` |
| 2-й запрос | заголовок `Authorization: Negotiate <base64>` |

Проверка типа токена (в терминале Mac):

```bash
echo 'BASE64_ИЗ_ЗАГОЛОВКА' | base64 -d | xxd | head -1
```

| Начало | Значение |
|--------|----------|
| `60 82 ...` | Kerberos — ок |
| `4e 54 4c 4d` (`NTLM`) | браузер шлёт не Kerberos |

---

## 8. Типичные ошибки

| Симптом в Keycloak | Что проверить на Mac |
|--------------------|----------------------|
| `GSSHeader did not find the right tag` | Нет TGT, нет `AuthServerAllowlist`, браузер шлёт NTLM |
| `AES256 ... Cannot find key` | Старый TGT — `kdestroy` + `kinit` |
| Только 401, нет 2-го запроса | Политика браузера не применилась — перезапустить браузер |
| Форма логина вместо SSO | URL не `sso.nemero.online` или Kerberos в realm Disabled |

### Чеклист

```bash
# krb5
cat /etc/krb5.conf

# тикет
klist -e

# политика Chrome
defaults read "/Library/Managed Preferences/com.google.Chrome" AuthServerAllowlist 2>/dev/null

# политика Yandex (корп. версия)
defaults read "/Library/Managed Preferences/ru.yandex.desktop.yandex-browser" 2>/dev/null
defaults read ~/Library/Managed\ Preferences/ru.yandex.desktop.yandex-browser 2>/dev/null
```

---

## 9. Сброс настроек (откат)

```bash
sudo rm -f "/Library/Managed Preferences/com.google.Chrome.plist"
sudo rm -f "/Library/Managed Preferences/ru.yandex.desktop.yandex-browser.plist"
rm -f ~/Library/Managed\ Preferences/com.google.Chrome.plist
rm -f ~/Library/Managed\ Preferences/ru.yandex.desktop.yandex-browser.plist
defaults delete com.yandex.YandexBrowser AuthServerAllowlist 2>/dev/null
kdestroy
```
