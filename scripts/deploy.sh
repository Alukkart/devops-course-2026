#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                     # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"

err() { echo "deploy: $*" >&2; }

# 1. Разбор аргумента --dry-run
DRY_RUN=""
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN="--dry-run" ;;
    *)         err "неизвестный аргумент: $1 (использование: $0 [--dry-run])"; exit 1 ;;
esac

cd "$REPO_ROOT"

# 2. Проверки по требованиям 4 и 5
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    err "файл site/index.html отсутствует — доставка отменена (--delete удалил бы главную страницу)"
    exit 1
fi

# изменения отслеживаемых файлов (рабочая копия и индекс) и любые неучтённые файлы в site/
if [[ -n "$(git status --porcelain --untracked-files=no)" || -n "$(git status --porcelain -- site/)" ]]; then
    err "в репозитории есть незафиксированные изменения — доставка отменена:"
    { git status --short --untracked-files=no; git status --short -- site/; } | sort -u >&2
    exit 1
fi

COMMIT="$(git rev-parse --short HEAD)"

# 3. Синхронизация каталога ${LOCAL_DIR} на ${REMOTE}:${REMOTE_DIR} — одно SSH-соединение,
#    BatchMode исключает интерактивный запрос пароля
echo "Доставка коммита ${COMMIT} на ${REMOTE}:${REMOTE_DIR} ${DRY_RUN:+(пробный запуск)}"
rsync -avz --delete --chmod=D755,F644 ${DRY_RUN} \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
    "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run — завершение с кодом 0 без проверки доступности
if [[ -n "$DRY_RUN" ]]; then
    echo "Пробный запуск завершён, состояние сервера не изменено"
    exit 0
fi

# 5. Проверка доступности ${SITE_URL} с проверкой сертификата
if ! curl -fsS --max-time 10 --cacert "$CA_CERT" -o /dev/null "$SITE_URL/"; then
    err "ресурс ${SITE_URL} недоступен после доставки"
    exit 1
fi

echo "Деплой выполнен: ${SITE_URL} отвечает, доставлен коммит ${COMMIT}"
