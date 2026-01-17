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

# Добавить A запись
samba-tool dns add 127.0.0.1 green.skills srv-web1 A 10.10.0.5 -U administrator --password='P@ssw0rd'

# Добавить PTR запись
samba-tool dns add 127.0.0.1 10.10.in-addr.arpa 5.0 PTR srv-web1.green.skills -U administrator --password='P@ssw0rd'

# На SRV1

# Добавить A запись
samba-tool dns add 127.0.0.1 green.skills vm-cloud A 192.168.1.5 -U administrator --password='P@ssw0rd'

# Если нет, создать:
samba-tool dns add 127.0.0.1 green.skills logs CNAME vm-cloud.green.skills -U administrator --password='P@ssw0rd'

# Добавить PTR запись
samba-tool dns add 127.0.0.1 1.168.192.in-addr.arpa 5.1 PTR vm-cloud.green.skills -U administrator --password='P@ssw0rd'

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
mkdir -p /root/certs
cd /root/certs

# Извлечь CA сертификат и ключ из Samba
cp /var/lib/samba/private/tls/ca.pem /root/certs/GreenCA.crt
cp /var/lib/samba/private/tls/key.pem /root/certs/GreenCA.key

# Создать конфигурацию для генерации сертификатов
cat > /root/certs/openssl.cnf << 'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C=RU
ST=Moscow
L=Moscow
O=GreenAtom
OU=IT
CN=

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 =
EOF

# Функция для генерации сертификата
generate_cert() {
    local DOMAIN=$1
    
    # Создать временный конфиг
    sed "s/^CN=.*/CN=$DOMAIN/" /root/certs/openssl.cnf > /tmp/openssl_${DOMAIN}.cnf
    sed -i "s/^DNS.1 =.*/DNS.1 = $DOMAIN/" /tmp/openssl_${DOMAIN}.cnf
    
    # Генерировать приватный ключ
    openssl genrsa -out ${DOMAIN}.key 2048
    
    # Генерировать CSR
    openssl req -new -key ${DOMAIN}.key -out ${DOMAIN}.csr -config /tmp/openssl_${DOMAIN}.cnf
    
    # Подписать сертификат CA
    openssl x509 -req -in ${DOMAIN}.csr \
        -CA /root/certs/GreenCA.crt \
        -CAkey /root/certs/GreenCA.key \
        -CAcreateserial \
        -out ${DOMAIN}.crt \
        -days 365 \
        -sha256 \
        -extensions v3_req \
        -extfile /tmp/openssl_${DOMAIN}.cnf
    
    # Создать цепочку сертификатов
    cat ${DOMAIN}.crt /root/certs/GreenCA.crt > ${DOMAIN}.chain.crt
    
    # Удалить временные файлы
    rm /tmp/openssl_${DOMAIN}.cnf ${DOMAIN}.csr
    
    echo "✓ Сертификат для $DOMAIN создан"
}

# Генерировать сертификаты для всех сервисов
generate_cert "webatom.green.skills"
generate_cert "git.green.skills"
generate_cert "mail.green.skills"
generate_cert "vpn.green.skills"
generate_cert "logs.green.skills"

# На SRV1

# Скопировать сертификаты на VM-CLOUD через VIRT1
scp /root/certs/vpn.green.skills.crt root@virt1.green.skills:/tmp/
scp /root/certs/vpn.green.skills.key root@virt1.green.skills:/tmp/
scp /root/certs/GreenCA.crt root@virt1.green.skills:/tmp/

# На SRV1

# Скопировать сертификаты на SRV3
scp /root/certs/mail.green.skills.crt root@srv3.green.skills:/tmp/
scp /root/certs/mail.green.skills.key root@srv3.green.skills:/tmp/
scp /root/certs/GreenCA.crt root@srv3.green.skills:/tmp/

# На SRV1

# Создать SPN для почтового сервера
samba-tool spn add smtp/mail.green.skills srv3 -U administrator --password='P@ssw0rd'
samba-tool spn add imap/mail.green.skills srv3 -U administrator --password='P@ssw0rd'

# Экспортировать keytab
samba-tool domain exportkeytab /tmp/srv3.keytab \
    --principal=smtp/mail.green.skills \
    -U administrator --password='P@ssw0rd'

samba-tool domain exportkeytab /tmp/srv3.keytab \
    --principal=imap/mail.green.skills \
    -U administrator --password='P@ssw0rd'

# Скопировать keytab на SRV3
scp /tmp/srv3.keytab root@srv3.green.skills:/etc/krb5.keytab

# На SRV1

# Скопировать сертификаты на SRV4
scp /root/certs/webatom.green.skills.crt root@srv4.green.skills:/tmp/
scp /root/certs/webatom.green.skills.key root@srv4.green.skills:/tmp/
scp /root/certs/git.green.skills.crt root@srv4.green.skills:/tmp/
scp /root/certs/git.green.skills.key root@srv4.green.skills:/tmp/
scp /root/certs/GreenCA.crt root@srv4.green.skills:/tmp/


# Проверить созданные сертификаты
ls -lh /root/certs/

# Проверить содержимое сертификата
openssl x509 -in webatom.green.skills.crt -text -noout

# Скопировать корневой сертификат в общедоступное место
cp /root/certs/GreenCA.crt /tmp/

# Сделать доступным для копирования
chmod 644 /tmp/GreenCA.crt

# ============================================
# ЭТАП 8: Создание задания автоматизации для CLI-1
# ============================================

echo ""
echo "[8/12] Создание задания автоматизации для CLI-1..."

# Создание скрипта автоматизации для CLI-1
cat > /var/lib/samba/sysvol/green.skills/scripts/cli1-setup.sh << 'EOF'
#!/bin/bash
# Автоматизация настройки CLI-1

LOG="/var/log/cli1-automation.log"

exec > >(tee -a "$LOG") 2>&1

echo "=========================================="
echo "Начало автоматизации CLI-1: $(date)"
echo "=========================================="

# Обновление системы
echo "[1/5] Обновление системы..."
apt update
apt upgrade -y

# Установка необходимых пакетов
echo "[2/5] Установка пакетов..."
apt install -y \
    htop \
    xrdp \
    mc \
    vim \
    net-tools \
    curl \
    wget

# Настройка XRDP
echo "[3/5] Настройка XRDP..."
systemctl enable xrdp
systemctl start xrdp

# Настройка firewall для XRDP
if command -v ufw &> /dev/null; then
    ufw allow 3389/tcp
fi

# Настройка sudo для группы developers
echo "[4/5] Настройка sudo для developers..."
cat > /etc/sudoers.d/developers << 'SUDO'
# Права для группы developers
%developers ALL=(ALL) NOPASSWD: /usr/bin/journalctl
%developers ALL=(ALL) NOPASSWD: /usr/bin/systemctl status *
%developers ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart *
%developers ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop *
%developers ALL=(ALL) NOPASSWD: /usr/bin/systemctl start *
SUDO

chmod 0440 /etc/sudoers.d/developers

# Проверка синтаксиса sudoers
visudo -c -f /etc/sudoers.d/developers

# Установка CA сертификата
echo "[5/5] Установка CA сертификата..."
if [ -f "/tmp/green-ca.crt" ]; then
    cp /tmp/green-ca.crt /usr/local/share/ca-certificates/
    update-ca-certificates
    echo "✅ CA сертификат установлен"
else
    echo "⚠️  CA сертификат не найден, загружаем с сервера..."
    wget -O /usr/local/share/ca-certificates/green-ca.crt \
        http://srv1.green.skills/ca/green-ca.crt 2>/dev/null && \
        update-ca-certificates
fi

echo ""
echo "=========================================="
echo "✅ Автоматизация CLI-1 завершена: $(date)"
echo "=========================================="
echo ""
echo "Установленные пакеты:"
dpkg -l | grep -E 'htop|xrdp|mc'
echo ""
echo "Статус служб:"
systemctl status xrdp --no-pager
echo ""
echo "Sudo права для developers:"
cat /etc/sudoers.d/developers
EOF

chmod +x /var/lib/samba/sysvol/green.skills/scripts/cli1-setup.sh

# Создание GPO для автоматического выполнения скрипта
# (в реальности требуется samba-tool gpo, здесь создаем заготовку)

cat > /root/deploy-cli1-automation.sh << 'DEPLOY'
#!/bin/bash
# Скрипт для развертывания автоматизации на CLI-1

CLI1_IP="10.30.0.100"
SCRIPT_PATH="/var/lib/samba/sysvol/green.skills/scripts/cli1-setup.sh"

echo "Развертывание автоматизации на CLI-1..."

# Копирование скрипта на CLI-1
scp $SCRIPT_PATH administrator@${CLI1_IP}:/tmp/cli1-setup.sh

# Копирование CA сертификата
scp /etc/pki/CA/certs/ca.crt administrator@${CLI1_IP}:/tmp/green-ca.crt

# Выполнение скрипта на CLI-1
ssh administrator@${CLI1_IP} "sudo bash /tmp/cli1-setup.sh"

echo "✅ Автоматизация развернута на CLI-1"
DEPLOY

chmod +x /root/deploy-cli1-automation.sh

echo "✅ Задание автоматизации создано"
echo "   Скрипт: /var/lib/samba/sysvol/green.skills/scripts/cli1-setup.sh"
echo "   Развертывание: /root/deploy-cli1-automation.sh"

# ============================================
# ЭТАП 9: Финальная проверка
# ============================================

echo ""
echo "[9/12] Проверка служб..."

echo ""
echo "=== Samba AD DC ==="
systemctl status samba-ad-dc --no-pager | head -15

echo ""
echo "=== BIND9 DNS ==="
systemctl status bind9 --no-pager | head -10

echo ""
echo "=== ISC DHCP Server ==="
systemctl status isc-dhcp-server --no-pager | head -10

echo ""
echo "[10/12] Проверка DNS..."
echo "=== A записи ==="
host srv1.green.skills 127.0.0.1
host srv2.green.skills 127.0.0.1
host srv4.green.skills 127.0.0.1

echo ""
echo "=== CNAME записи ==="
host webatom.green.skills 127.0.0.1
host mail.green.skills 127.0.0.1
host vpn.green.skills 127.0.0.1

echo ""
echo "[11/12] Проверка Kerberos..."
echo 'P@ssw0rd' | kinit administrator@GREEN.SKILLS
klist

echo ""
echo "[12/12] Проверка пользователей и групп..."
echo "=== Пользователи ==="
samba-tool user list | head -10

echo ""
echo "=== Группы ==="
samba-tool group list | head -10

echo ""
echo "=== Членство в группах ==="
samba-tool group listmembers "Domain Admins"
samba-tool group listmembers "developers"

echo ""
echo "======================================"
echo "✅ SRV1 настроен успешно!"
echo "======================================"