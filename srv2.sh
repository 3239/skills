hostnamectl set-hostname srv1.green.skills

cat > /etc/hosts << 'EOF'
127.0.0.1       localhost
10.20.0.10      srv2.green.skills srv2

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

samba-tool domain join green.skills DC \
    -U "Administrator" \
    --realm=GREEN.SKILLS \
    --dns-backend=SAMBA_INTERNAL

  # Скопировать конфигурацию Kerberos с SRV1
scp root@srv1.green.skills:/etc/krb5.conf /etc/krb5.conf

# Настроить DNS
cat > /etc/resolv.conf << 'EOF'
nameserver 10.10.0.10
nameserver 127.0.0.1
search green.skills
EOF

# Запустить службы Samba
systemctl unmask samba-ad-dc
systemctl enable samba-ad-dc
systemctl start samba-ad-dc

# Проверить статус
systemctl status samba-ad-dc

# Проверить репликацию
samba-tool drs showrepl

# Должен показать репликацию с srv1.green.skills

# Проверить DNS
host -t SRV _ldap._tcp.green.skills

# Проверить Kerberos
kinit administrator@GREEN.SKILLS
klist

# Проверить список пользователей
samba-tool user list