#!/bin/bash
# admin-pc - Administrator workstation

hostnamectl set-hostname admin-pc
timedatectl set-timezone Europe/Moscow

# === Пользователь green ===
useradd -m -s /bin/bash green 2>/dev/null || true
echo "green:P@ssw0rd" | chpasswd
echo "green ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/green
chmod 440 /etc/sudoers.d/green

cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

# -=c-msk-1-bs;ens23=-
auto ens18
iface ens18 inet static
    address 10.100.60.50
    netmask 255.255.255.0
    gateway 10.100.60.254
    dns-nameservers 10.100.20.10
EOF

systemctl restart networking

apt update && apt install -y \
    openssh-client \
    net-tools \
    traceroute \
    tcpdump \
    nmap \
    snmp \
    curl \
    wget \
    vim \
    firefox-esr \
    chrony

# === NTP ===
cat > /etc/chrony/chrony.conf << 'EOF'
server 10.100.60.1 iburst
makestep 1 3
rtcsync
EOF

systemctl enable --now chrony

# === Импорт сертификата UserGate ===
mkdir -p /usr/local/share/ca-certificates/
# wget -O /usr/local/share/ca-certificates/usergate-ca.crt http://10.100.60.254/ca.crt
# update-ca-certificates

echo "=== admin-pc configuration complete ==="
