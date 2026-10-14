# Конфигурация виртуальной машины devops-vm

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Гипервизор | Oracle VirtualBox (macOS) |
| Имя машины | `devops-vm` |
| Гостевая ОС | Ubuntu Server 24.04.5 LTS |
| Оперативная память | 2048 МБ |
| Процессор | 2 ядра |
| Диск | 25 ГБ (VDI, динамический), корневой раздел `/dev/sda2` |
| Имя узла | `devops-vm`, FQDN `devops-vm.devops.local` |

Имя узла задаётся командами:

```bash
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f    # devops-vm.devops.local
```

## 2. Сетевые интерфейсы

| Адаптер VirtualBox | Интерфейс | Тип | Адрес | Назначение |
|---|---|---|---|---|
| Адаптер 1 | `enp0s8` | NAT | 10.0.2.15/24 (DHCP) | Выход в Интернет, проброс порта SSH |
| Адаптер 2 | `enp0s9` | Host-only (`HostNetwork`, 192.168.56.0/24) | 192.168.56.2/24 (DHCP) | Прямой доступ с хоста по имени `devops.local` |

Файл `/etc/netplan/50-cloud-init.yaml`:

```yaml
network:
  version: 2
  ethernets:
    enp0s8:
      dhcp4: true
    enp0s9:
      dhcp4: true
```

Применение: `sudo netplan apply`. На хостовой системе в `/etc/hosts` добавлена запись `192.168.56.2 devops.local`.

## 3. Правило проброса портов

| Имя | Протокол | Адрес хоста | Порт хоста | Порт гостя |
|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | 2222 |

```bash
VBoxManage modifyvm devops-vm --natpf1 "ssh,tcp,127.0.0.1,2222,,2222"
```

## 4. Учётные записи

| Имя | Группы | Аутентификация |
|---|---|---|
| `devops` | `devops`, `sudo`, `users`, `docker` | только по ключу Ed25519 (`~/.ssh/devops_vm` на хосте), пароль для sudo |
| `student` | `student`, `sudo` | учётная запись установки, вход по SSH запрещён директивой `AllowUsers` |

Права: `~/.ssh` — 700, `~/.ssh/authorized_keys` — 600, владелец `devops`.

Псевдоним на хосте (`~/.ssh/config`):

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH

Файл `/etc/ssh/sshd_config.d/99-hardening.conf`:

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Служба переведена с сокетной активации на постоянный режим (иначе порт из конфигурации игнорируется):

```bash
sudo sshd -t
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
```

## 6. Правила межсетевого экрана

Политики: `deny (incoming)`, `allow (outgoing)`, `disabled (routed)`; журналирование `medium`.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw logging medium
sudo ufw enable
```

| Порт | Действие | Комментарий |
|---|---|---|
| 80/tcp | ALLOW IN | HTTP |
| 443/tcp | ALLOW IN | HTTPS |
| 2222/tcp | LIMIT IN | SSH rate-limited (≥6 соединений за 30 с — блокировка) |

## 7. Снимки состояния

| Снимок | Момент создания |
|---|---|
| `01-clean-install` | после установки Ubuntu Server, до настройки (ПР № 5, раздел 3) |
| `03-ssh-hardened` | после настройки SSH, UFW и DNS (ПР № 5) |
| `04-nginx-https` | 14.10.2026, после установки Nginx и перевода ресурса на HTTPS (ПР № 6) |
| `05-docker-compose` | 14.10.2026, после установки Docker и запуска проекта «приложение + СУБД» (ПР № 7) |

## 8. Веб-сервер

**Пакет:** `nginx` из репозитория Ubuntu (версия 1.24.0), служба `nginx.service` включена в автозапуск.

```bash
sudo apt update && sudo apt install -y nginx
```

Главный процесс работает от `root`, рабочие — от `www-data`. Порты 80 и 443 разрешены правилами UFW из раздела 6 (профиль `Nginx Full` не используется).

**Конфигурация ресурса:** `/etc/nginx/sites-available/devops-site`, активируется символической ссылкой в `/etc/nginx/sites-enabled/`; стандартный ресурс отключён (ссылка `sites-enabled/default` удалена, файл в `sites-available` сохранён).

```nginx
# Блок 1: перенаправление HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;

    return 301 https://$host$request_uri;
}

# Блок 2: ресурс по HTTPS
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;

    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/devops-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    error_page 404 /404.html;

    access_log /var/log/nginx/devops-site.access.log;
    error_log /var/log/nginx/devops-site.error.log;
}
```

```bash
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

HSTS не включается (самоподписанный сертификат).

**Каталог ресурса:** `/var/www/devops-site`, владелец `devops:devops`, права каталогов 755, файлов 644 (модель «владелец пишет, веб-сервер читает»). Содержимое доставляется из каталога `site/` репозитория сценарием `scripts/deploy.sh` (`rsync -avz --delete --chmod=D755,F644`).

```bash
sudo mkdir -p /var/www/devops-site
sudo chown -R devops:devops /var/www/devops-site
```

**Сертификат и ключ:**

| Файл | Владелец | Права |
|---|---|---|
| `/etc/ssl/certs/devops.crt` (сертификат) | root:root | 644 |
| `/etc/ssl/private/devops.key` (закрытый ключ RSA 2048) | root:root | 600 |

Формирование самоподписанного сертификата, срок действия 365 дней (выпущен 14.10.2026, истекает 14.10.2027):

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
```

Сертификат копируется на хост по SSH и указывается клиентам как доверенный: `scp devops:/etc/ssl/certs/devops.crt ~/devops.crt`, `curl --cacert ~/devops.crt https://devops.local`.

**Журналы:** `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log` (запросы к блоку перенаправления — в общий `/var/log/nginx/access.log`).

## 9. Контейнеризация

**Docker Engine** установлен из официального репозитория Docker (пакет `docker.io` из репозитория Ubuntu не используется, конфликтующие пакеты удалены): Docker Engine 29.9.1, плагин Compose v5.6.0, архитектура arm64.

```bash
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove -y $pkg; done
sudo apt-get update && sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**Участники группы `docker`:** только `devops` (имеет право sudo). Членство в группе равносильно правам root, поэтому учётные записи без sudo в группу не включаются.

```bash
sudo usermod -aG docker devops   # затем новая SSH-сессия
```

**Проект на сервере:** `/home/devops/app` (имя проекта Compose — `app`). Исходный код хранится в каталоге `app/` репозитория и доставляется командой `rsync -avz --delete --exclude=.env app/ devops:app/`. Состав: `app.py`, `requirements.txt`, `Dockerfile`, `.dockerignore`, `docker-compose.yml`, `.env.example`.

| Сервис | Образ | Контейнер | Назначение |
|---|---|---|---|
| `app` | `devops-app:1.0` (собирается из `Dockerfile`, процесс от пользователя `app`, uid 999) | `app-app-1` | Flask + gunicorn, порт 5000 |
| `db` | `postgres:16-alpine` | `app-db-1` | PostgreSQL 16, healthcheck `pg_isready` |

Запуск: `cd ~/app && docker compose up -d --build`; политика перезапуска `unless-stopped`.

**Файл `.env`:** `/home/devops/app/.env`, владелец `devops`, права 600; создаётся только на сервере из шаблона, пароль СУБД генерируется случайно; в репозиторий и образ не попадает (`.gitignore`, `.dockerignore`, `rsync --exclude=.env`).

```bash
cd ~/app && cp .env.example .env && chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
```

**Публикуемые порты и адреса:**

| Порт | Адрес | Доступ |
|---|---|---|
| 5000/tcp (app) | `127.0.0.1:5000` | только для Nginx на этой же машине |
| 5432/tcp (db) | не публикуется | только из сети проекта `app_backend` по имени `db` |

Порты на `0.0.0.0` не публикуются: правила Docker в iptables обрабатываются до правил UFW.

**Сети и тома:** пользовательская bridge-сеть `app_backend`; именованный том `app_db_data` → `/var/lib/postgresql/data` (сохраняется при `docker compose down`, удаляется только `down -v`).

**Обратный прокси-сервер:** в блок HTTPS `/etc/nginx/sites-available/devops-site` (раздел 8) добавлено расположение, статический ресурс `/` сохранён:

```nginx
    location /app/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```

Применение: `sudo nginx -t && sudo systemctl reload nginx`. Приложение доступно по `https://devops.local/app/`.
