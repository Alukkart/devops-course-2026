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
| `devops` | `devops`, `sudo`, `users` (с ПР № 7 также `docker`) | только по ключу Ed25519 (`~/.ssh/devops_vm` на хосте), пароль для sudo |
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
