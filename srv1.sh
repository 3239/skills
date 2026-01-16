#!/bin/bash
#
# Скрипт настройки SRV1 - Основной контроллер домена ALD PRO
# IP: 10.10.0.10
# Hostname: srv1.green.skills
# OS: Astra Linux 1.7.7.9 GUI
#

set -e

echo "======================================"
echo "  Настройка SRV1 - Primary DC"
echo "======================================"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Запустите скрипт с правами root"
    exit 1
fi

# ============================================
# ЭТАП 1: Базовая настройка сети
# ============================================

echo ""
echo "[1/12] Настройка сети и hostname..."

# Hostname
hostnamectl set-hostname srv1.green.skills

# Настройка сети
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 10.10.0.10
    netmask 255.255.255.0
    gateway 10.10.0.1
    dns-nameservers 127.0.0.1
    dns-search green.skills
EOF

sudo ip route add default via 10.10.0.1

# Hosts файл
cat > /etc/hosts << 'EOF'
127.0.0.1       localhost
10.10.0.10      srv1.green.skills srv1

# ЦОД А
10.10.0.11      virt1.green.skills virt1
10.10.0.12      storage.green.skills storage
10.10.0.5       srv-web1.green.skills srv-web1
192.168.1.5     vm-cloud.green.skills vm-cloud

# ЦОД B
10.20.0.10      srv2.green.skills srv2
10.20.0.11      srv3.green.skills srv3
10.20.0.12      srv4.green.skills srv4

# OFFICE
10.30.0.100     cli-1.green.skills cli-1
10.30.0.101     cli-2.green.skills cli-2

# Aliases
10.20.0.12      webatom.green.skills
192.168.1.5     logs.green.skills
10.20.0.12      git.green.skills
10.10.0.11      vpn.green.skills
10.20.0.11      mail.green.skills
EOF

# Применение сети
systemctl restart networking

echo "✅ Сеть настроена"

# ============================================
# ЭТАП 2: Установка ALD PRO 3.0.0
# ============================================

echo ""
echo "[2/12] Установка пакетов ALD PRO..."

# Добавление репозитория ALD PRO (если требуется)
# echo "deb https://repo.ald.pro/3.0.0/ stable main" > /etc/apt/sources.list.d/ald-pro.list

apt update
apt install -y \
    ald-server \
    ald-admin \
    ald-client \
    bind9 \
    bind9utils \
    isc-dhcp-server \
    krb5-user \
    krb5-admin-server \
    krb5-config \
    krb5-kdc \
    ldap-utils \
    sssd \
    sssd-tools \
    python3-pip \
    xca
apt install -y samba winbind smbclient dnsutils
echo "✅ Пакеты установлены"

# ============================================
# ЭТАП 3: Развертывание домена ALD PRO
# ============================================

echo ""
echo "[3/12] Развертывание домена green.skills..."

# Инициализация домена
ald-admin domain init \
    --domain green.skills \
    --realm GREEN.SKILLS \
    --netbios-name GREEN \
    --admin-password 'P@ssw0rd' \
    --ip-address 10.10.0.10 \
    --dns-forwarder 192.168.55.254

# Запуск служб
systemctl enable ald-server
systemctl start ald-server
systemctl enable bind9
systemctl start bind9
systemctl enable krb5-kdc
systemctl start krb5-kdc
systemctl enable krb5-admin-server
systemctl start krb5-admin-server

echo "✅ Домен развернут"

# ============================================
# ЭТАП 4: Настройка DNS
# ============================================

echo ""
echo "[4/12] Настройка DNS записей..."

# A записи
ald-admin dns add-record --zone green.skills --name srv1 --type A --value 10.10.0.10
ald-admin dns add-record --zone green.skills --name srv2 --type A --value 10.20.0.10
ald-admin dns add-record --zone green.skills --name srv3 --type A --value 10.20.0.11
ald-admin dns add-record --zone green.skills --name srv4 --type A --value 10.20.0.12
ald-admin dns add-record --zone green.skills --name virt1 --type A --value 10.10.0.11
ald-admin dns add-record --zone green.skills --name vm-cloud --type A --value 192.168.1.5
ald-admin dns add-record --zone green.skills --name storage --type A --value 10.10.0.12
ald-admin dns add-record --zone green.skills --name srv-web1 --type A --value 10.10.0.5
ald-admin dns add-record --zone green.skills --name cli-1 --type A --value 10.30.0.100
ald-admin dns add-record --zone green.skills --name cli-2 --type A --value 10.30.0.101

# CNAME записи
ald-admin dns add-record --zone green.skills --name webatom --type CNAME --value srv4.green.skills.
ald-admin dns add-record --zone green.skills --name logs --type CNAME --value vm-cloud.green.skills.
ald-admin dns add-record --zone green.skills --name git --type CNAME --value srv4.green.skills.
ald-admin dns add-record --zone green.skills --name vpn --type CNAME --value virt1.green.skills.
ald-admin dns add-record --zone green.skills --name mail --type CNAME --value srv3.green.skills.

# PTR записи (обратные зоны)
ald-admin dns add-reverse-zone --network 10.10.0.0/24
ald-admin dns add-reverse-zone --network 10.20.0.0/24
ald-admin dns add-reverse-zone --network 10.30.0.0/24

ald-admin dns add-record --zone 0.10.10.in-addr.arpa --name 10 --type PTR --value srv1.green.skills.
ald-admin dns add-record --zone 0.20.10.in-addr.arpa --name 10 --type PTR --value srv2.green.skills.
ald-admin dns add-record --zone 0.20.10.in-addr.arpa --name 11 --type PTR --value srv3.green.skills.
ald-admin dns add-record --zone 0.20.10.in-addr.arpa --name 12 --type PTR --value srv4.green.skills.
ald-admin dns add-record --zone 0.10.10.in-addr.arpa --name 11 --type PTR --value virt1.green.skills.
ald-admin dns add-record --zone 0.10.10.in-addr.arpa --name 12 --type PTR --value storage.green.skills.
ald-admin dns add-record --zone 0.10.10.in-addr.arpa --name 5 --type PTR --value srv-web1.green.skills.

echo "✅ DNS записи добавлены"

# ============================================
# ЭТАП 5: Настройка DHCP с DDNS
# ============================================

echo ""
echo "[5/12] Настройка DHCP сервера..."

cat > /etc/dhcp/dhcpd.conf << 'EOF'
authoritative;
ddns-update-style interim;
ddns-updates on;
ignore client-updates;

subnet 10.10.0.0 netmask 255.255.255.0 {
    # Пусто — DHCP не раздаётся
}

# Настройка DDNS
include "/etc/dhcp/ddns-keys.conf";

zone green.skills. {
    primary 127.0.0.1;
    key DHCP_UPDATER;
}

zone 0.30.10.in-addr.arpa. {
    primary 127.0.0.1;
    key DHCP_UPDATER;
}

shared-network OFFICE {
    subnet 10.30.0.0 netmask 255.255.255.0 {
        range 10.30.0.100 10.30.0.200;
        option routers 10.30.0.1;
        option domain-name "green.skills";
        option domain-name-servers 10.10.0.10;  # IP srv1
        default-lease-time 600;
        max-lease-time 7200;
        ddns-domainname "green.skills.";
        ddns-rev-domainname "in-addr.arpa.";
    }
}
EOF

# Генерация DDNS ключа
dnssec-keygen -a HMAC-SHA256 -b 256 -n HOST DHCP_UPDATER
KEY=$(grep Key: Kdhcp*.private | cut -d ' ' -f 2)

cat > /etc/dhcp/ddns-keys.conf << EOF
key DHCP_UPDATER {
    algorithm hmac-sha256;
    secret "$KEY";
};
EOF

# Добавление ключа в named.conf
cat >> /etc/bind/named.conf.local << EOF
key DHCP_UPDATER {
    algorithm hmac-sha256;
    secret "$KEY";
};

zone "green.skills" {
    type master;
    file "/var/lib/bind/db.green.skills";
    allow-update { key DHCP_UPDATER; };
};

zone "0.30.10.in-addr.arpa" {
    type master;
    file "/var/lib/bind/db.10.30.0";
    allow-update { key DHCP_UPDATER; };
};
EOF

# Настройка интерфейса для DHCP
cat > /etc/default/isc-dhcp-server << 'EOF'
INTERFACESv4="eth0"
INTERFACESv6=""
EOF

systemctl enable isc-dhcp-server
systemctl restart isc-dhcp-server
systemctl restart bind9

echo "✅ DHCP настроен"

# ============================================
# ЭТАП 6: Импорт пользователей
# ============================================

echo ""
echo "[6/12] Импорт пользователей из CSV..."

# Создание OU
ald-admin ou create --name GreenAtom --base-dn "dc=green,dc=skills"

# Создание групп
ald-admin group create --name secusers --base-dn "ou=GreenAtom,dc=green,dc=skills"
ald-admin group create --name developers --base-dn "ou=GreenAtom,dc=green,dc=skills"

# Делегирование прав группам
ald-admin delegation add --group secusers --permissions "user-management,gpo-management,hbac-management"
ald-admin delegation add --group developers --permissions "automation-management"

# Импорт пользователей
tail -n +2 "$CSV_FILE" | while IFS=';' read -r firstname lastname password username; do
    # Очистка от пробелов И символов \r\n
    firstname="$firstname"
    lastname="$lastname"
    password="$password"
    username="$username"

    echo "Создаём: $username"
    samba-tool user create "$username" "$password" \
        --given-name="$firstname" \
        --surname="$lastname" \
        --mail-address="${username}@green.skills" \
        --must-change-at-next-login \
        -U administrator
done

tail -n +2 | while IFS=';' read -r firstname lastname password username; do
    if [ "$username" != "username" ]; then
        ald-admin user create \
            --firstname="$firstname" \
            --lastname="$lastname" \
            --password="$password" \
            --username="$username"
    fi
done < Загрузки/users.csv

echo "✅ Пользователи импортированы"

# ============================================
# ЭТАП 7: Настройка центра сертификации XCA
# ============================================

echo ""
echo "[7/12] Настройка центра сертификации..."

# Создание директории для XCA
mkdir -p /home/administrator/.xca

# Экспорт приватного ключа и сертификата ALD PRO
ald-admin cert export --type ca --output /tmp/ald-ca.crt
ald-admin cert export --type ca-key --output /tmp/ald-ca.key

# Создание базы данных XCA (требуется GUI, делаем заготовку)
cat > /root/xca-setup.sh << 'EOF'
#!/bin/bash
# Запустите этот скрипт в GUI сессии под пользователем administrator

# 1. Откройте XCA
# 2. File -> New Database
# 3. Путь: /home/administrator/GreenCA.xdb
# 4. Пароль: P@ssw0rd
# 5. Import -> Private Key: /tmp/ald-ca.key
# 6. Import -> Certificate: /tmp/ald-ca.crt

echo "XCA настроен. Используйте его для выпуска сертификатов."
EOF

chmod +x /root/xca-setup.sh

# Экспорт CA сертификата для клиентов
cp /tmp/ald-ca.crt /usr/local/share/ca-certificates/green-ca.crt
update-ca-certificates

echo "✅ CA подготовлен (требуется GUI для завершения)"

# ============================================
# ЭТАП 8: Создание задания автоматизации для CLI-1
# ============================================

echo ""
echo "[8/12] Создание задания автоматизации для CLI-1..."

cat > /tmp/cli1-automation.sh << 'EOF'
#!/bin/bash
# Автоматизация для CLI-1

# Установка пакетов
apt update
apt install -y htop xrdp

# Настройка sudo для группы developers
echo "%developers ALL=(ALL) NOPASSWD: /usr/bin/journalctl, /usr/bin/systemctl" >> /etc/sudoers.d/developers
chmod 0440 /etc/sudoers.d/developers

echo "Автоматизация CLI-1 выполнена"
EOF

# Создание задания в ALD PRO
ald-admin automation create \
    --name "CLI-1 Setup" \
    --target "cli-1.green.skills" \
    --script /tmp/cli1-automation.sh \
    --schedule "once"

echo "✅ Задание автоматизации создано"

# ============================================
# ЭТАП 9: Финальная проверка
# ============================================

echo ""
echo "[9/12] Проверка служб..."

systemctl status ald-server --no-pager
systemctl status bind9 --no-pager
systemctl status isc-dhcp-server --no-pager
systemctl status krb5-kdc --no-pager

echo ""
echo "[10/12] Проверка DNS..."
host srv1.green.skills
host srv2.green.skills
nslookup webatom.green.skills

echo ""
echo "[11/12] Проверка Kerberos..."
echo 'P@ssw0rd' | kinit administrator@GREEN.SKILLS
klist

echo ""
echo "[12/12] Проверка пользователей..."
ald-admin user list

echo ""
echo "======================================"
echo "✅ SRV1 настроен успешно!"
echo "======================================"