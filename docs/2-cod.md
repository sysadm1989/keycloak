# Второй Keycloak (второй ЦОД)

Сначала достаточно одного узла в `dc1` с белым IP. Второй узел (`dc2`, роль `passive`) добавляется в тот же кластер без смены hostname и issuer OIDC.

## Что уже должно работать

- Один узел `kc-dc1` с `keycloak_role: active` и публичным `ansible_host`.
- DNS `keycloak_hostname` (A-запись) указывает на белый IP этого узла.
- В группе `keycloak` в `inventories/prod/hosts.yml` подключён только `keycloak_dc1` (`keycloak_dc2` закомментирован).
- PostgreSQL доступна с будущего узла dc2 (те же `keycloak_db_hosts` / та же БД).
- Между ЦОД открыты порты JGroups: `7800` и `57800` (источник — `keycloak_address` пира).

## Шаги

1. **Inventory.** В `hosts.yml` у `kc-dc2` задайте:
   - `ansible_host` — SSH (и при необходимости публичный адрес узла);
   - `keycloak_address` — внутренний IP для JGroups, nftables и копирования LE-сертификата;
   - `keycloak_role: passive`;
   - `keycloak_site: dc2` (уже на группе `dc2`).

2. **Включить в группу кластера.** В `keycloak.children` раскомментируйте `keycloak_dc2`. Порядок важен: сначала `keycloak_dc1` (active), затем `keycloak_dc2` (passive) — так идут `update.yml` и выпуск Let's Encrypt.

3. **База.** Убедитесь, что в `keycloak_db_hosts` есть хост(ы), доступные из dc2. Hostname Keycloak (`keycloak_hostname`) не меняйте.

4. **Сеть.** Между `keycloak_address` узлов:
   - TCP `7800`, `57800` (JGroups);
   - SSH с active на passive (копия сертификата при `keycloak_external: true`);
   - доступ к PostgreSQL с обоих узлов.

5. **Установка второго узла:**

   ```bash
   ansible-playbook playbooks/platform.yml --limit keycloak_dc2 --ask-vault-pass
   ```

   Либо полный прогон на оба (реалмы не трогать, если уже импортированы):

   ```bash
   ansible-playbook playbooks/configure.yml --ask-vault-pass
   ```

6. **Сертификат.** При Let's Encrypt active выпускает сертификат и копирует его на passive. После появления второго узла один раз обновите/проверьте LE на active (или дождитесь cron), чтобы на dc2 легли `fullchain`/`privkey`.

7. **DNS / трафик.** Пока один белый IP — A-запись на `kc-dc1`. Когда появится второй публичный вход (второй белый IP или свой балансировщик), направьте DNS/балансировку так, чтобы оба узла получали HTTPS; health удобно смотреть локально: `GET /lb-check` → `200`.

8. **Проверка:**

   ```bash
   ansible-playbook playbooks/status.yml --ask-vault-pass
   ```

   На обоих: `docker compose ps`, `/health/ready`, `/lb-check` → `200`. Сессия, начатая на одном узле, должна жить на другом (сессии в PostgreSQL).

## Обновления после двух ЦОД

`playbooks/update.yml` идёт по порядку inventory: сначала active, потом passive. Не меняйте роли местами без нужды: LE всегда выпускает `active`.

## Откат второго узла

Закомментируйте `keycloak_dc2` в группе `keycloak`, при необходимости остановите compose на хосте и уберите его из DNS/балансировки. Первый узел продолжает работать один.

## CrowdSec

На каждом узле Keycloak роль `crowdsec` ставит свой Local API (`127.0.0.1:8088`) и nftables-bouncer. Второй ЦОД не требует общего LAPI: решения локальные, whitelist `10.0.0.0/8` уже в роли.
