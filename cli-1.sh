apt update
apt upgrade -y
apt install -y \
    sssd \
    sssd-tools \
    realmd \
    adcli \
    krb5-user \
    samba-common-bin

sudo apt install -y packagekit

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

# Проверить доступность домена
realm discover green.skills

samba-tool domain join green.skills DC \
    -U "Administrator" \
    --realm=GREEN.SKILLS \
    --dns-backend=SAMBA_INTERNAL

cat > /etc/sssd/sssd.conf << 'EOF'
[sssd]
domains = green.skills
config_file_version = 2
services = nss, pam

[domain/green.skills]
default_shell = /bin/bash
krb5_store_password_if_offline = True
cache_credentials = True
krb5_realm = GREEN.SKILLS
realmd_tags = manages-system joined-with-adcli
id_provider = ad
fallback_homedir = /home/%u@%d
ad_domain = green.skills
use_fully_qualified_names = False
ldap_id_mapping = True
access_provider = ad
EOF

# Установить права на файл
chmod 600 /etc/sssd/sssd.conf

# Перезапустить SSSD
systemctl restart sssd

# Настроить автоматическое создание домашних директорий
pam-auth-update --enable mkhomedir

# Проверить присоединение к домену
realm list

# Проверить пользователя домена
id administrator
id administrator@green.skills

scp root@srv1.green.skills:/tmp/GreenCA.crt /tmp/

# Установить сертификат в систему
cp /tmp/GreenCA.crt /usr/local/share/ca-certificates/GreenCA.crt

# Обновить список доверенных сертификатов
update-ca-certificates

# Проверить
ls -l /etc/ssl/certs/ | grep GreenCA

# На CLI-1

# Установить OpenConnect клиент
apt update
apt install -y openconnect network-manager-openconnect network-manager-openconnect-gnome

# Получить fingerprint сертификата сервера
echo | openconnect --authenticate vpn.green.skills 2>&1 | grep -i fingerprint

# Сохранить fingerprint (например: pin-sha256:ABCD1234...)

# Создать скрипт автоподключения
cat > /usr/local/bin/vpn-autoconnect.sh << 'EOF'
#!/bin/bash

VPN_SERVER="vpn.green.skills"
VPN_USER="vpnuser"
VPN_PASSWORD="P@ssw0rd"
VPN_FINGERPRINT="pin-sha256:ЗАМЕНИТЕ_НА_РЕАЛЬНЫЙ_FINGERPRINT"

# Проверить, не подключен ли уже VPN
if ip link show tun0 &> /dev/null; then
    echo "VPN уже подключен"
    exit 0
fi

# Подключиться к VPN
echo "$VPN_PASSWORD" | openconnect \
    --background \
    --user="$VPN_USER" \
    --passwd-on-stdin \
    --servercert="$VPN_FINGERPRINT" \
    "$VPN_SERVER"

if [ $? -eq 0 ]; then
    echo "VPN подключен успешно"
else
    echo "Ошибка подключения VPN"
fi
EOF

# Заменить FINGERPRINT на реальный
# Отредактировать файл:
# nano /usr/local/bin/vpn-autoconnect.sh

# Сделать скрипт исполняемым
chmod +x /usr/local/bin/vpn-autoconnect.sh

# Создать systemd service для автозапуска
cat > /etc/systemd/system/vpn-autoconnect.service << 'EOF'
[Unit]
Description=VPN Auto Connect
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-autoconnect.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Включить автозапуск
systemctl daemon-reload
systemctl enable vpn-autoconnect.service

# Запустить сервис
systemctl start vpn-autoconnect.service

# Проверить статус
systemctl status vpn-autoconnect.service

# Проверить подключение VPN
ip addr show tun0
ping -c 3 192.168.1.5