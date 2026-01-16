# На SRV3

# Обновить систему
apt update
apt upgrade -y

# Установить Postfix
apt install -y postfix

# Во время установки выбрать:
# - General type: Internet Site
# - System mail name: green.skills

# Установить Dovecot
apt install -y dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd

# Установить дополнительные пакеты
apt install -y \
    sasl2-bin \
    libsasl2-modules \
    libsasl2-modules-sql \
    libsasl2-modules-ldap \
    krb5-user \
    libpam-krb5

# На SRV3

# Создать директории для сертификатов
mkdir -p /etc/ssl/certs
mkdir -p /etc/ssl/private

# Переместить сертификаты
mv /tmp/mail.green.skills.crt /etc/ssl/certs/
mv /tmp/mail.green.skills.key /etc/ssl/private/
mv /tmp/GreenCA.crt /etc/ssl/certs/

# Установить права
chmod 644 /etc/ssl/certs/mail.green.skills.crt
chmod 600 /etc/ssl/private/mail.green.skills.key
chmod 644 /etc/ssl/certs/GreenCA.crt

# Проверить
ls -l /etc/ssl/certs/mail.green.skills.crt
ls -l /etc/ssl/private/mail.green.skills.key

# На SRV3

# Настроить Kerberos
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

# На SRV3

# Установить права на keytab
chmod 600 /etc/krb5.keytab

# Проверить keytab
klist -k /etc/krb5.keytab

# Проверить Kerberos аутентификацию
kinit -k smtp/mail.green.skills
klist

# На SRV3

# Создать резервную копию конфигурации
cp /etc/postfix/main.cf /etc/postfix/main.cf.bak

# Настроить main.cf
cat > /etc/postfix/main.cf << 'EOF'
# Basic settings
smtpd_banner = $myhostname ESMTP
biff = no
append_dot_mydomain = no
readme_directory = no
compatibility_level = 2

# TLS parameters
smtpd_tls_cert_file=/etc/ssl/certs/mail.green.skills.crt
smtpd_tls_key_file=/etc/ssl/private/mail.green.skills.key
smtpd_tls_CAfile=/etc/ssl/certs/GreenCA.crt
smtpd_tls_security_level=may
smtpd_tls_auth_only = yes
smtpd_tls_loglevel = 1
smtpd_tls_received_header = yes
smtpd_tls_session_cache_database = btree:${data_directory}/smtpd_scache

smtp_tls_CAfile=/etc/ssl/certs/GreenCA.crt
smtp_tls_security_level=may
smtp_tls_loglevel = 1
smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache

# SASL authentication
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain = $myhostname
broken_sasl_auth_clients = yes

# Network settings
myhostname = mail.green.skills
mydomain = green.skills
myorigin = $mydomain
mydestination = $myhostname, localhost.$mydomain, localhost, $mydomain
relayhost =
mynetworks = 10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = all
inet_protocols = ipv4
home_mailbox = Maildir/

# SMTP restrictions
smtpd_recipient_restrictions = 
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination

smtpd_relay_restrictions = 
    permit_mynetworks,
    permit_sasl_authenticated,
    defer_unauth_destination

# Mailbox settings
mailbox_command = 
virtual_alias_maps = hash:/etc/postfix/virtual
EOF

# Настроить master.cf для submission
cat >> /etc/postfix/master.cf << 'EOF'

# Submission port
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_recipient_restrictions=
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF

# Создать файл virtual aliases
touch /etc/postfix/virtual
postmap /etc/postfix/virtual

# Перезапустить Postfix
systemctl restart postfix

# Проверить статус
systemctl status postfix

# Проверить порты
ss -tulnp | grep master

# На SRV3

# Создать резервную копию конфигурации
cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bak

# Настроить dovecot.conf
cat > /etc/dovecot/dovecot.conf << 'EOF'
# Protocols
protocols = imap pop3 lmtp

# Listen on all interfaces
listen = *

# Disable plaintext auth (except on localhost)
disable_plaintext_auth = no

# Mail location
mail_location = maildir:~/Maildir
mail_privileged_group = mail

# SSL/TLS
ssl = required
ssl_cert = </etc/ssl/certs/mail.green.skills.crt
ssl_key = </etc/ssl/private/mail.green.skills.key
ssl_ca = </etc/ssl/certs/GreenCA.crt
ssl_min_protocol = TLSv1.2

# Authentication mechanisms
auth_mechanisms = plain login gssapi

# Include other config files
!include conf.d/*.conf
EOF

# Настроить 10-auth.conf
cat > /etc/dovecot/conf.d/10-auth.conf << 'EOF'
disable_plaintext_auth = no
auth_mechanisms = plain login gssapi

# Kerberos/GSSAPI
auth_gssapi_hostname = mail.green.skills
auth_krb5_keytab = /etc/krb5.keytab

# System users
!include auth-system.conf.ext
EOF

# Настроить 10-mail.conf
cat > /etc/dovecot/conf.d/10-mail.conf << 'EOF'
mail_location = maildir:~/Maildir
mail_privileged_group = mail
first_valid_uid = 1000
EOF

# Настроить 10-master.conf для LMTP и Auth
cat > /etc/dovecot/conf.d/10-master.conf << 'EOF'
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service pop3-login {
  inet_listener pop3 {
    port = 110
  }
  inet_listener pop3s {
    port = 995
    ssl = yes
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
    group = vmail
  }
  user = dovecot
}

service auth-worker {
  user = $default_internal_user
}
EOF

# Настроить 10-ssl.conf
cat > /etc/dovecot/conf.d/10-ssl.conf << 'EOF'
ssl = required
ssl_cert = </etc/ssl/certs/mail.green.skills.crt
ssl_key = </etc/ssl/private/mail.green.skills.key
ssl_ca = </etc/ssl/certs/GreenCA.crt
ssl_min_protocol = TLSv1.2
ssl_cipher_list = HIGH:!aNULL:!MD5
ssl_prefer_server_ciphers = yes
EOF

# Создать пользователя vmail (если нужен для virtual mailboxes)
groupadd -g 5000 vmail
useradd -g vmail -u 5000 vmail -d /var/mail -s /usr/sbin/nologin

# Перезапустить Dovecot
systemctl restart dovecot

# Проверить статус
systemctl status dovecot

# Проверить порты
ss -tulnp | grep dovecot

# На SRV3

# Проверить отправку письма локально
echo "Test email" | mail -s "Test" root@green.skills

# Проверить логи
tail -f /var/log/mail.log

# Проверить очередь
mailq

# Проверить подключение к IMAP
telnet localhost 143
# Ввести:
# a1 LOGIN administrator P@ssw0rd
# a2 LIST "" "*"
# a3 LOGOUT

# Проверить подключение к SMTP
telnet localhost 25
# Ввести:
# EHLO green.skills
# QUIT
