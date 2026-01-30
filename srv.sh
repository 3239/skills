#!/bin/bash
# srv - Infrastructure Server

set -e

hostnamectl set-hostname srv
timedatectl set-timezone Europe/Moscow

# === Пользователь green ===
useradd -m -s /bin/bash green 2>/dev/null || true
echo "green:P@ssw0rd" | chpasswd
echo "green ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/green
chmod 440 /etc/sudoers.d/green

# === Сетевая конфигурация ===
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

# -=c-msk-2-as;Gi1/1=-
auto ens18
iface ens18 inet static
    address 10.100.20.10
    netmask 255.255.255.0
    gateway 10.100.20.1
    dns-nameservers 127.0.0.1
EOF

systemctl restart networking

apt update && apt install -y \
    isc-dhcp-server \
    bind9 bind9utils \
    freeradius freeradius-utils \
    syslog-ng \
    tftpd-hpa \
    chrony \
    openssh-server

# === ISC DHCP Server ===
cat > /etc/dhcp/dhcpd.conf << 'EOF'
authoritative;
default-lease-time 86400;
max-lease-time 172800;

option domain-name "office.local";
option domain-name-servers 10.100.20.10;
option ntp-servers 10.100.60.1;

# Subnet INS (VLAN 10) - клиенты
subnet 10.100.10.0 netmask 255.255.255.0 {
    range 10.100.10.100 10.100.10.200;
    option routers 10.100.10.1;
    option broadcast-address 10.100.10.255;
}

# Subnet SRV (VLAN 20) - без dynamic
subnet 10.100.20.0 netmask 255.255.255.0 {
    option routers 10.100.20.1;
}

# Subnet MGMT (VLAN 60) - без dynamic
subnet 10.100.60.0 netmask 255.255.255.0 {
    option routers 10.100.60.254;
}
EOF

# DHCP слушает через relay (не напрямую)
cat > /etc/default/isc-dhcp-server << 'EOF'
INTERFACESv4=""
INTERFACESv6=""
EOF

systemctl enable --now isc-dhcp-server

# === BIND9 DNS ===
cat > /etc/bind/named.conf.options << 'EOF'
options {
    directory "/var/cache/bind";
    recursion yes;
    allow-recursion { 10.0.0.0/8; 172.16.0.0/12; };
    forwarders { 8.8.8.8; 8.8.4.4; };
    dnssec-validation auto;
    listen-on { any; };
    allow-query { any; };
};
EOF

cat > /etc/bind/named.conf.local << 'EOF'
zone "office.local" {
    type master;
    file "/etc/bind/db.office.local";
};

zone "dc.local" {
    type master;
    file "/etc/bind/db.dc.local";
};

zone "20.100.10.in-addr.arpa" {
    type master;
    file "/etc/bind/db.10.100.20";
};
EOF

cat > /etc/bind/db.office.local << 'EOF'
$TTL 604800
@   IN  SOA srv.office.local. admin.office.local. (
            2024010101 604800 86400 2419200 604800 )
@           IN  NS      srv.office.local.
srv         IN  A       10.100.20.10
core        IN  A       10.100.60.1
fw          IN  A       10.100.60.254
fw1         IN  A       10.100.60.252
fw2         IN  A       10.100.60.253
vpn1        IN  A       10.100.60.21
vpn2        IN  A       10.100.60.22
bs          IN  A       10.100.60.18
as1         IN  A       10.100.60.11
as2         IN  A       10.100.60.12
admin-pc    IN  A       10.100.60.50
EOF

cat > /etc/bind/db.dc.local << 'EOF'
$TTL 604800
@   IN  SOA zabbix.dc.local. admin.dc.local. (
            2024010101 604800 86400 2419200 604800 )
@           IN  NS      zabbix.dc.local.
zabbix      IN  A       10.200.20.10
vpn         IN  A       10.200.20.20
multimedia  IN  A       10.200.20.30
core        IN  A       10.200.60.1
dc-vpn1     IN  A       10.200.60.2
dc-vpn2     IN  A       10.200.60.3
EOF

systemctl enable --now bind9

# === FreeRADIUS ===
cat > /etc/freeradius/3.0/clients.conf << 'EOF'
client localhost {
    ipaddr = 127.0.0.1
    secret = testing123
}

client cisco_devices {
    ipaddr = 10.100.60.0/24
    secret = RadiusSecret123
}
EOF

cat > /etc/freeradius/3.0/users << 'EOF'
# Пользователь radadmin с привилегиями 15
radadmin    Cleartext-Password := "P@ssw0rd"
            Service-Type = NAS-Prompt-User,
            Cisco-AVPair = "shell:priv-lvl=15"

# Пользователь 1line с привилегиями 5 и parser view
1line       Cleartext-Password := "P@ssw0rd"
            Service-Type = NAS-Prompt-User,
            Cisco-AVPair = "shell:priv-lvl=5",
            Cisco-AVPair = "shell:parser-view-name=1LINE"

# Пользователь green с привилегиями 15
green       Cleartext-Password := "P@ssw0rd"
            Service-Type = NAS-Prompt-User,
            Cisco-AVPair = "shell:priv-lvl=15"

# MAB аутентификация - разрешенные MAC-адреса
# Формат: MAC адрес без разделителей, lowercase
# Пример для cli:
001122334455    Cleartext-Password := "001122334455"
                Service-Type = Call-Check,
                Tunnel-Type = VLAN,
                Tunnel-Medium-Type = IEEE-802,
                Tunnel-Private-Group-Id = 10

# Пример для srv:
aabbccddeeff    Cleartext-Password := "aabbccddeeff"
                Service-Type = Call-Check,
                Tunnel-Type = VLAN,
                Tunnel-Medium-Type = IEEE-802,
                Tunnel-Private-Group-Id = 20
EOF

systemctl enable --now freeradius

# === Syslog-ng Server ===
mkdir -p /opt/logs

cat > /etc/syslog-ng/conf.d/remote.conf << 'EOF'
# Прием логов по UDP
source s_network {
    network(
        transport("udp")
        port(514)
    );
};

# Шаблон имени файла с hostname
destination d_remote_hosts {
    file("/opt/logs/${HOST}.log"
        create_dirs(yes)
        perm(0644)
        dir_perm(0755)
    );
};

# Фильтр: notice (5) и важнее
filter f_notice_and_above {
    level(notice..emerg);
};

# Лог
log {
    source(s_network);
    filter(f_notice_and_above);
    destination(d_remote_hosts);
};
EOF

systemctl restart syslog-ng

# === TFTP Server для конфигураций ===
mkdir -p /opt/tftp
chmod 777 /opt/tftp

cat > /etc/default/tftpd-hpa << 'EOF'
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/opt/tftp"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure --create"
EOF

systemctl enable --now tftpd-hpa

# === NTP клиент ===
cat > /etc/chrony/chrony.conf << 'EOF'
server 10.100.60.1 iburst
makestep 1 3
rtcsync
EOF

systemctl enable --now chrony

# === SSH ===
cat > /etc/ssh/sshd_config.d/security.conf << 'EOF'
PermitRootLogin no
PasswordAuthentication yes
AllowUsers green
EOF

systemctl restart sshd

echo "=== srv configuration complete ==="
echo "Services: DHCP, DNS, RADIUS, Syslog-ng, TFTP"
