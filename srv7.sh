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