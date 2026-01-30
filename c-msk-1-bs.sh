#!/bin/bash
# c-msk-1-bs - OVS Bridge Switch (исправленная версия)
# Все порты ens18-22 — транковые с VLAN 10/20/60 (native VLAN 60)
# ens23 — access порт для management (VLAN 60)

set -e

# === Базовая настройка ===
hostnamectl set-hostname c-msk-1-bs
timedatectl set-timezone Europe/Moscow

# === Пользователь green с sudo без пароля ===
useradd -m -s /bin/bash green 2>/dev/null || true
echo "green:P@ssw0rd" | chpasswd
echo "green ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/green
chmod 440 /etc/sudoers.d/green

# === Установка OVS ===
apt update && apt install -y openvswitch-switch net-tools iproute2

# Автозапуск OVS при загрузке
systemctl enable openvswitch-switch
systemctl start openvswitch-switch

sleep 3

# === Создание основного bridge ===
ovs-vsctl --may-exist add-br br0

# === Добавление ТРАНКОВЫХ портов (ens18-22) с описаниями ===
# Все транковые порты пропускают VLAN 10,20,60 с нативным VLAN 60 (untagged)

# ens18 -> c-msk-1-vpn-rtr:ens19 (LAN side)
ovs-vsctl --may-exist add-port br0 ens18
ovs-vsctl set interface ens18 external_ids:description="-=c-msk-1-vpn-rtr;ens19=-"
ovs-vsctl set port ens18 trunks=10,20,60 vlan_mode=native-untagged tag=60

# ens19 -> c-msk-1-fw:port0
ovs-vsctl --may-exist add-port br0 ens19
ovs-vsctl set interface ens19 external_ids:description="-=c-msk-1-fw;port0=-"
ovs-vsctl set port ens19 trunks=10,20,60 vlan_mode=native-untagged tag=60

# ens20 -> c-msk-2-fw:port0
ovs-vsctl --may-exist add-port br0 ens20
ovs-vsctl set interface ens20 external_ids:description="-=c-msk-2-fw;port0=-"
ovs-vsctl set port ens20 trunks=10,20,60 vlan_mode=native-untagged tag=60

# ens21 -> c-msk-2-vpn-rtr:ens19 (LAN side)
ovs-vsctl --may-exist add-port br0 ens21
ovs-vsctl set interface ens21 external_ids:description="-=c-msk-2-vpn-rtr;ens19=-"
ovs-vsctl set port ens21 trunks=10,20,60 vlan_mode=native-untagged tag=60

# ens22 -> c-msk-core:Gi1/0
ovs-vsctl --may-exist add-port br0 ens22
ovs-vsctl set interface ens22 external_ids:description="-=c-msk-core;Gi1/0=-"
ovs-vsctl set port ens22 trunks=10,20,60 vlan_mode=native-untagged tag=60

# === ACCESS порт для управления (ens23) ===
# ens23 -> admin-pc:ens18 (только VLAN 60, untagged)
ovs-vsctl --may-exist add-port br0 ens23
ovs-vsctl set interface ens23 external_ids:description="-=admin-pc;ens18=-"
ovs-vsctl set port ens23 tag=60 vlan_mode=access

# === Internal интерфейс для управления коммутатором (VLAN 60) ===
ovs-vsctl --may-exist add-port br0 mgmt tag=60 -- set interface mgmt type=internal

# === Сетевая конфигурация ===
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

# -=c-msk-1-vpn-rtr;ens19=- (транк)
auto ens18
iface ens18 inet manual
    up ip link set $IFACE up
    down ip link set $IFACE down

# -=c-msk-1-fw;port0=- (транк)
auto ens19
iface ens19 inet manual
    up ip link set $IFACE up
    down ip link set $IFACE down

# -=c-msk-2-fw;port0=- (транк)
auto ens20
iface ens20 inet manual
    up ip link set $IFACE up
    down ip link set $IFACE down

# -=c-msk-2-vpn-rtr;ens19=- (транк)
auto ens21
iface ens21 inet manual
    up ip link set $IFACE up
    down ip link set $IFACE down

# -=c-msk-core;Gi1/0=- (транк)
auto ens22
iface ens22 inet manual
    up ip link set $IFACE up
    down ip link set $IFACE down

# -=admin-pc;ens18=- (access VLAN 60)
auto ens23
iface ens23 inet manual
    up ip link set $IFACE up
    down ip link set $IFACE down

# Management interface коммутатора (VLAN 60)
auto mgmt
iface mgmt inet static
    address 10.100.60.18
    netmask 255.255.255.0
    gateway 10.100.60.254
    dns-nameservers 10.100.20.10
EOF

# Применяем настройки интерфейсов
for iface in ens18 ens19 ens20 ens21 ens22 ens23 mgmt; do
    ip link set $iface up 2>/dev/null || true
done

# Настройка IP для управления
ip addr flush dev mgmt 2>/dev/null || true
ip addr add 10.100.60.18/24 dev mgmt
ip route add default via 10.100.60.254 2>/dev/null || true

# === NTP клиент ===
apt install -y chrony -y

cat > /etc/chrony/chrony.conf << 'EOF'
server 10.100.60.21 iburst
server 10.100.60.22 iburst
makestep 1 3
rtcsync
driftfile /var/lib/chrony/chrony.drift
EOF

systemctl enable --now chrony

# === SSH ===
apt install -y openssh-server -y

cat > /etc/ssh/sshd_config.d/security.conf << 'EOF'
PermitRootLogin no
PasswordAuthentication yes
AllowUsers green
EOF

systemctl restart ssh

# === SNMP Agent ===
apt install -y snmpd -y

cat > /etc/snmp/snmpd.conf << 'EOF'
agentAddress udp:161
view greenskills included .1
rocommunity public 10.100.0.0/16
sysLocation "Moscow Backbone Switch"
sysContact admin@office.local
EOF

systemctl enable --now snmpd

# === Syslog клиент (syslog-ng) ===
apt install -y syslog-ng -y

cat >> /etc/syslog-ng/syslog-ng.conf << 'EOF'

# Отправка логов на сервер (уровень notice и выше)
destination d_remote { syslog("10.100.20.10" transport("udp") port(514)); };
filter f_notice { level(notice..emerg); };
log { source(s_src); filter(f_notice); destination(d_remote); };
EOF

systemctl restart syslog-ng

# === STP для предотвращения петель ===
ovs-vsctl set bridge br0 stp_enable=true
ovs-vsctl set bridge br0 other-config:stp-priority=32768

# === Финальная проверка ===
echo ""
echo "=========================================="
echo "✅ Конфигурация c-msk-1-bs завершена!"
echo "=========================================="
echo ""
echo "Топология портов:"
ovs-vsctl list-ports br0 | while read port; do
    desc=$(ovs-vsctl get interface $port external_ids:description 2>/dev/null | tr -d '"')
    mode=$(ovs-vsctl get port $port vlan_mode 2>/dev/null | tr -d '"')
    tag=$(ovs-vsctl get port $port tag 2>/dev/null)
    trunks=$(ovs-vsctl get port $port trunks 2>/dev/null | tr -d '[]')
    if [ "$mode" = "access" ]; then
        echo "  $port: ACCESS VLAN $tag → $desc"
    else
        echo "  $port: TRUNK ($trunks) native=$tag → $desc"
    fi
done
echo ""
echo "Management IP: 10.100.60.18/24"
echo "Default gateway: 10.100.60.254"
echo ""
echo "STP status:"
ovs-vsctl get bridge br0 stp_enable
echo ""
ovs-vsctl show
