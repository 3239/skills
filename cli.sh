#!/bin/bash
# cli - Client workstation

hostnamectl set-hostname cli
timedatectl set-timezone Europe/Moscow

# === Пользователь green ===
useradd -m -s /bin/bash green 2>/dev/null || true
echo "green:P@ssw0rd" | chpasswd
echo "green ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/green
chmod 440 /etc/sudoers.d/green

cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

# -=c-msk-1-as;Gi1/1=-
auto ens18
iface ens18 inet dhcp
EOF

systemctl restart networking

apt update && apt install -y firefox-esr chrony curl wget

# === NTP ===
cat > /etc/chrony/chrony.conf << 'EOF'
server 10.100.60.1 iburst
makestep 1 3
rtcsync
EOF

systemctl enable --now chrony

# === Импорт сертификата UserGate для HTTPS инспекции ===
# Сертификат нужно скачать с FW и импортировать:
mkdir -p /usr/local/share/ca-certificates/
# wget -O /usr/local/share/ca-certificates/usergate-ca.crt http://10.100.60.254/ca.crt
# update-ca-certificates

# Для Firefox нужно импортировать через настройки браузера
# или через certutil

echo "=== cli configuration complete ==="
