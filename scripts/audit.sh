#!/usr/bin/env bash
# Аудит конфигурации devops-vm. Код возврата 0 — все проверки пройдены, 1 — есть нарушения.
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK]   $desc"; ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён"        "no"  "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no"  "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
check "Порт SSH отличен от 22"             "yes" "$(sudo sshd -T | awk '/^port /{print ($2 != 22) ? "yes" : "no"}')"
check "MaxAuthTries равно 3"               "3"   "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен"                 "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
check "Политика для входящего трафика — deny"    "deny"   "$(sudo ufw status verbose | awk '/^Default:/{print $2}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "    %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
CERT="/etc/ssl/certs/devops.crt"
KEY="/etc/ssl/private/devops.key"
SITE_DIR="/var/www/devops-site"
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"   # порог срока действия сертификата, дней
check "Служба nginx активна"                 "active" "$(systemctl is-active nginx)"
check "Конфигурация nginx корректна"         "ok"     "$(sudo nginx -t >/dev/null 2>&1 && echo ok || echo fail)"
check "Сертификат действителен ещё ${CERT_MIN_DAYS} дн." "ok" \
      "$(openssl x509 -in "$CERT" -noout -checkend $((CERT_MIN_DAYS * 86400)) >/dev/null 2>&1 && echo ok || echo expiring)"
check "Нет файлов ресурса с записью для всех" "0"     "$(find "$SITE_DIR" -perm -o+w | wc -l)"
check "Права закрытого ключа равны 600"      "600"    "$(sudo stat -c '%a' "$KEY")"

echo "[5] Контейнеризация"
APP_ENV="${APP_ENV:-$HOME/app/.env}"
check "Служба docker активна"                  "active"  "$(systemctl is-active docker)"
check "Контейнер СУБД в состоянии healthy"     "healthy" "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || echo absent)"
check "Порты 5000/5432 только на 127.0.0.1"    "0" \
      "$(ss -tln | awk '$4 ~ /:(5000|5432)$/ && $4 !~ /^127\.0\.0\.1:/' | wc -l)"
check "Права файла .env равны 600"             "600"     "$(stat -c '%a' "$APP_ENV" 2>/dev/null || echo absent)"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
