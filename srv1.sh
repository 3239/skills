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

echo "na
echo "[1/12] Настройка сети и hostname..."

# Hostname
hostnamectl set-hostname srv1.green.skills

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
sudo apt install -y samba krb5-config winbind smbclient dnsutils
apt install -y \
    wget \
    curl \
    vim \
    net-tools \
    dnsutils \
    chrony
apt install -y krb5-kdc krb5-admin-server
echo "✅ Пакеты установлены"

# ============================================
# ЭТАП 3: Развертывание домена ALD PRO
# ============================================

echo ""
echo "[3/12] Развертывание домена green.skills..."

# Инициализация домена
samba-tool domain provision \
  --realm=GREEN.SKILLS \
  --domain=GREEN \
  --server-role=dc \
  --dns-backend=SAMBA_INTERNAL \
  --adminpass='P@ssw0rd' \
  --use-rfc2307

# Запуск служб
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
cat > /etc/krb5.conf << 'EOF'
[libdefaults]
    default_realm = GREEN.SKILLS
    dns_lookup_realm = true
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    rdns = false

[realms]
    GREEN.SKILLS = {
        kdc = srv1.green.skills
        admin_server = srv1.green.skills
        default_domain = green.skills
    }

[domain_realm]
    .green.skills = GREEN.SKILLS
    green.skills = GREEN.SKILLS
EOF

cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
search green.skills
EOF

# Запустить службы Samba
systemctl unmask samba-ad-dc
systemctl enable samba-ad-dc
systemctl start samba-ad-dc

# Проверить статус
systemctl status samba-ad-dc

host -t A srv1.green.skills
# Должен вернуть: srv1.green.skills has address 10.10.0.10

# Проверить Kerberos
kinit administrator@GREEN.SKILLS
# Password: P@ssw0rd

klist
# Должен показать ticket для administrator@GREEN.SKILLS

# Проверить список пользователей
samba-tool user list
echo "✅ Домен развернут"

# ============================================
# ЭТАП 4: Настройка DNS
# ============================================

echo ""
echo "[4/12] Настройка DNS записей..."

# Добавить A записи для всех серверов
samba-tool dns add 127.0.0.1 green.skills srv1 A 10.10.0.10 -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 green.skills srv2 A 10.20.0.10 -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 green.skills srv3 A 10.20.0.11 -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 green.skills srv4 A 10.20.0.12 -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 green.skills virt1 A 10.10.0.11 -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 green.skills storage A 10.10.0.12 -U administrator --password='P@ssw0rd'

# Добавить CNAME записи
samba-tool dns add 127.0.0.1 green.skills webatom CNAME srv4.green.skills -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 green.skills git CNAME srv4.green.skills -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 green.skills mail CNAME srv3.green.skills -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 green.skills vpn CNAME virt1.green.skills -U administrator --password='P@ssw0rd'

# Создать обратные зоны
samba-tool dns zonecreate 127.0.0.1 10.10.in-addr.arpa -U administrator --password='P@ssw0rd'
samba-tool dns zonecreate 127.0.0.1 20.10.in-addr.arpa -U administrator --password='P@ssw0rd'
samba-tool dns zonecreate 127.0.0.1 30.10.in-addr.arpa -U administrator --password='P@ssw0rd'
samba-tool dns zonecreate 127.0.0.1 1.168.192.in-addr.arpa -U administrator --password='P@ssw0rd'

# Добавить PTR записи
samba-tool dns add 127.0.0.1 10.10.in-addr.arpa 10.0 PTR srv1.green.skills -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 20.10.in-addr.arpa 10.0 PTR srv2.green.skills -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 20.10.in-addr.arpa 11.0 PTR srv3.green.skills -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 20.10.in-addr.arpa 12.0 PTR srv4.green.skills -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 10.10.in-addr.arpa 11.0 PTR virt1.green.skills -U administrator --password='P@ssw0rd'
samba-tool dns add 127.0.0.1 10.10.in-addr.arpa 12.0 PTR storage.green.skills -U administrator --password='P@ssw0rd'

# Настроить DNS forwarder
cat >> /etc/samba/smb.conf << 'EOF'

[global]
    dns forwarder = 192.168.55.254
EOF

# Перезапустить Samba
systemctl restart samba-ad-dc

# Проверить DNS записи
host srv1.green.skills
host srv2.green.skills
host webatom.green.skills
host 10.10.0.10

echo "✅ DNS записи добавлены"

# ============================================
# ЭТАП 5: Настройка DHCP с DDNS
# ============================================
apt install -y isc-dhcp-server
apt update
apt install -y bind9

cat > /etc/default/isc-dhcp-server << 'EOF'
INTERFACESv4="eth0"   
INTERFACESv6=""
EOF

tsig-keygen -a hmac-md5 DHCP_UPDATER > /etc/dhcp/dhcp-ddns.key
cat /etc/dhcp/dhcp-ddns.key

cat > /etc/dhcp/dhcpd.conf << 'EOF'
authoritative;
ddns-update-style interim;
ddns-updates on;
ignore client-updates;

include "/etc/dhcp/dhcp-ddns.key";
subnet 10.10.0.0 netmask 255.255.255.0 {
}

shared-network OFFICE {
    subnet 10.30.0.0 netmask 255.255.255.0 {
        range 10.30.0.100 10.30.0.200;
        option routers 10.30.0.1;
        option domain-name "green.skills";
        option domain-name-servers 10.10.0.10;
        default-lease-time 600;
        max-lease-time 7200;
        ddns-domainname "green.skills.";
        ddns-rev-domainname "in-addr.arpa.";
    }
}

zone green.skills. {
    primary 127.0.0.1;
    key DHCP_UPDATER;
}

zone 0.30.10.in-addr.arpa. {
    primary 127.0.0.1;
    key DHCP_UPDATER;
}
EOF

TSIG_SECRET=$(grep secret /etc/dhcp/dhcp-ddns.key | awk '{print $2}' | tr -d '";')
cat > /var/lib/samba/private/dns.keytab << EOF
key "DHCP_UPDATER" {
    algorithm hmac-md5;
    secret "$TSIG_SECRET";
};
EOF

cat >> /etc/samba/smb.conf << 'EOF'
[global]
    allow dns updates = secure only
EOF

systemctl restart samba-ad-dc
systemctl enable isc-dhcp-server
systemctl start isc-dhcp-server

# Проверить статус
systemctl status isc-dhcp-server

echo "✅ DHCP настроен"

# ============================================
# ЭТАП 6: Импорт пользователей
# ============================================

echo ""
echo "[6/12] Импорт пользователей из CSV..."

# Создать группу secusers
samba-tool group add secusers -U administrator --password='P@ssw0rd'

# Создать группу developers
samba-tool group add developers -U administrator --password='P@ssw0rd'

# Добавить secusers в Domain Admins
samba-tool group addmembers "Domain Admins" secusers -U administrator --password='P@ssw0rd'

# Добавить пользователей в группы (пример)
# Замените user1, user2, user3, user4 на реальные имена из users.csv

# Добавить пользователей в secusers
samba-tool group addmembers secusers user1,user2 -U administrator --password='P@ssw0rd'

# Добавить пользователей в developers
samba-tool group addmembers developers user3,user4 -U administrator --password='P@ssw0rd'

# Проверить членство в группах
samba-tool group listmembers secusers -U administrator --password='P@ssw0rd'
samba-tool group listmembers developers -U administrator --password='P@ssw0rd'
samba-tool group listmembers "Domain Admins" -U administrator --password='P@ssw0rd'

# Импорт пользователей
cat > import_users.sh << 'SCRIPT'
#!/bin/bash

CSV_FILE="Загрузки/users.csv"

sudo apt install dos2unix
dos2unix users.csv

# Пропустить заголовок и читать построчно
tail -n +2 "$CSV_FILE" | while IFS=';' read -r firstname lastname password username; do
    firstname=$firstname
    lastname=$lastname
    password=$password
    username=$username
    
    echo "Создание пользователя: $username ($firstname $lastname)"
    
    samba-tool user create "$username" "$password" \
        --given-name="$firstname" \
        --surname="$lastname" \
        --must-change-at-next-login \
        -U administrator --password='P@ssw0rd'
    
    if [ $? -eq 0 ]; then
        echo "✓ Пользователь $username создан успешно"
    else
        echo "✗ Ошибка создания пользователя $username"
    fi
done

echo "Импорт завершен"
SCRIPT

chmod +x import_users.sh

# Запустить импорт
./import_users.sh

# Проверить список пользователей
samba-tool user list


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