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