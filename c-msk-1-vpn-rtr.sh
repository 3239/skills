#!/bin/bash
set -e

### === 1. Базовая настройка системы ===
echo "[+] Настройка базовой системы..."

# Hostname и часовой пояс
hostnamectl set-hostname c-msk-1-vpn-rtr
timedatectl set-timezone Europe/Moscow

# Обновление системы
apt update && apt upgrade -y

# Установка необходимых пакетов
apt install -y \
  ifupdown vlan \
  frr frr-pythontools \
  strongswan strongswan-swanctl libstrongswan-extra-plugins \
  nftables \
  chrony \
  openssh-server \
  snmpd snmp \
  libpam-radius-auth \
  syslog-ng \
  pimd \
  iproute2 iputils-ping net-tools tcpdump curl jq

### === 2. Сетевые интерфейсы через /etc/network/interfaces ===
echo "[+] Настройка сетевых интерфейсов (ens18=WAN/DHCP, ens19=LAN/VLAN)..."

# Загрузка модуля 8021q для работы с VLAN
modprobe 8021q
echo "8021q" >> /etc/modules

cat > /etc/network/interfaces <<'EOF'
# Loopback
auto lo
iface lo inet loopback

auto ens18
iface ens18 inet static
    address 77.34.141.142/22
    gateway 77.34.140.1

auto ens19
iface ens19 inet manual
    up ip link set $IFACE up
    down ip link set $IFACE down

# VLAN 10 — INS (Clients)
auto ens19.10
iface ens19.10 inet static
    address 10.100.10.21/24
    vlan-raw-device ens19

# VLAN 20 — SRV (Servers)
auto ens19.20
iface ens19.20 inet static
    address 10.100.20.21/24
    vlan-raw-device ens19

# VLAN 60 — MGMT
auto ens19.60
iface ens19.60 inet static
    address 10.100.60.21/24
    vlan-raw-device ens19
EOF

# Применение конфигурации
ifdown -a 2>/dev/null || true
sleep 2
ifup -a

### === 3. Включение маршрутизации ===
echo "[+] Включение маршрутизации..."

cat >> /etc/sysctl.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.ens18.accept_redirects = 0
net.ipv4.conf.ens19.accept_redirects = 0
EOF

sysctl -p

### === 4. NAT через nftables ===
echo "[+] Настройка NAT..."

cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

define WAN_IF = "ens18"
define VLAN10_IF = "ens19.10"
define VLAN20_IF = "ens19.20"
define VLAN60_IF = "ens19.60"
define DC1_NET = 10.200.0.0/16
define DC2_NET = 10.201.0.0/16
define INS_NET = 10.100.10.0/24
define SRV_NET = 10.100.20.0/24
define MGMT_NET = 10.100.60.0/24

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif "lo" accept
        tcp dport {22, 179, 500, 4500} accept
        udp dport {500, 4500, 161} accept
        icmp type {echo-request, echo-reply, destination-unreachable, time-exceeded} accept
        reject with icmpx admin-prohibited
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        iif $VLAN10_IF oif $WAN_IF ip daddr != $DC1_NET, $DC2_NET accept
        iif $VLAN20_IF oif $WAN_IF ip daddr != $DC1_NET, $DC2_NET accept
        iif $VLAN60_IF oif $WAN_IF ip daddr != $DC1_NET, $DC2_NET accept
        iifname "gre*" oif $WAN_IF accept
        iif $WAN_IF oif $VLAN10_IF ct state established,related accept
        iif $WAN_IF oif $VLAN20_IF ct state established,related accept
        iif $WAN_IF oif $VLAN60_IF ct state established,related accept
        reject with icmpx admin-prohibited
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
    }

    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip saddr $INS_NET ip daddr != $DC1_NET, $DC2_NET oif $WAN_IF masquerade
        ip saddr $SRV_NET ip daddr != $DC1_NET, $DC2_NET oif $WAN_IF masquerade
        ip saddr $MGMT_NET ip daddr != $DC1_NET, $DC2_NET oif $WAN_IF masquerade
    }
}
EOF

systemctl enable --now nftables

### === 5. IPsec + GRE туннели (strongSwan) ===
echo "[+] Настройка IPsec и GRE (адреса +1 согласно таблице провайдеров)..."

# Конфигурация strongSwan
cat > /etc/swanctl/swanctl.conf <<'EOF'
connections {
    dc1-tunnel {
        # Локальный адрес: получаем через DHCP от провайдера
        # Удалённый адрес: 172.217.35.81 (+1 от 172.217.35.80 из таблицы)
        local_addrs = 77.34.141.142
        remote_addrs = 172.217.35.81

        local {
            auth = psk
        }
        remote {
            auth = psk
        }
        children {
            dc1-child {
                local_ts = 10.100.0.0/16
                remote_ts = 10.200.0.0/16
                updown = /etc/swanctl/gre-updown.sh
                esp_proposals = aes256-sha256-modp2048
                start_action = start
                dpd_action = restart
            }
        }
        version = 2
        proposals = aes256-sha256-modp2048
        dpd_timeout = 30
    }

    dc2-tunnel {
        # Удалённый адрес: 178.207.179.5 (+1 от 178.207.179.4 из таблицы)
        local_addrs = 77.34.141.142
        remote_addrs = 178.207.179.5

        local {
            auth = psk
        }
        remote {
            auth = psk
        }
        children {
            dc2-child {
                local_ts = 10.100.0.0/16
                remote_ts = 10.201.0.0/16
                updown = /etc/swanctl/gre-updown.sh
                esp_proposals = aes256-sha256-modp2048
                start_action = start
                dpd_action = restart
            }
        }
        version = 2
        proposals = aes256-sha256-modp2048
        dpd_timeout = 30
    }
}

secrets {
    ike-172.217.35.81 {
        secret = P@ssw0rdVPN
    }
    ike-178.207.179.5 {
        secret = P@ssw0rdVPN
    }
}
EOF

# Скрипт для автоматического создания GRE туннелей
cat > /etc/swanctl/gre-updown.sh <<'EOF'
#!/bin/bash
set -e

# Определяем локальный адрес из интерфейса ens18 (WAN)
LOCAL_IP=$(ip -4 addr show ens18 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

case "${PLUTO_PEER}" in
    172.217.35.81) TUN_NUM=101; REMOTE_IP="172.217.35.81" ;;
    178.207.179.5) TUN_NUM=102; REMOTE_IP="178.207.179.5" ;;
    *) exit 0 ;;
esac

case "${PLUTO_VERB}" in
    up-client)
        ip tunnel add gre${TUN_NUM} mode gre local ${LOCAL_IP} remote ${REMOTE_IP} ttl 255 2>/dev/null || true
        ip addr add 10.10.${TUN_NUM}.1/30 dev gre${TUN_NUM} 2>/dev/null || true
        ip link set gre${TUN_NUM} mtu 1400
        ip link set gre${TUN_NUM} up
        iptables -t mangle -A FORWARD -o gre${TUN_NUM} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
        ;;
    down-client)
        iptables -t mangle -D FORWARD -o gre${TUN_NUM} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
        ip link delete gre${TUN_NUM} 2>/dev/null || true
        ;;
esac
EOF

chmod +x /etc/swanctl/gre-updown.sh
systemctl enable --now strongswan-starter
swanctl --load-all

### === 6. FRRouting (OSPF + iBGP + PIM) ===
echo "[+] Настройка FRR..."

# Включение демонов
cat > /etc/frr/daemons <<EOF
zebra=yes
ospfd=yes
bgpd=yes
pimd=yes
watchfrr=yes
EOF

# Конфигурация FRR
cat > /etc/frr/frr.conf <<'EOF'
!
hostname c-msk-1-vpn-rtr
log syslog informational
!
interface gre101
 ip address 10.10.101.1/30
 ip mtu 1400
 ip ospf network point-to-point
 ip pim sparse-mode
!
interface gre102
 ip address 10.10.102.1/30
 ip mtu 1400
 ip ospf network point-to-point
 ip pim sparse-mode
!
interface ens19.10
 ip address 10.100.10.21/24
 ip ospf network broadcast
!
interface ens19.20
 ip address 10.100.20.21/24
 ip ospf network broadcast
!
interface ens19.60
 ip address 10.100.60.21/24
 ip ospf network broadcast
!
interface lo
 ip address 10.10.10.1/32
!
router ospf
 ospf router-id 10.10.10.1
 network 10.100.10.0/24 area 0.0.0.0
 network 10.100.20.0/24 area 0.0.0.0
 network 10.100.60.0/24 area 0.0.0.0
 passive-interface default
 no passive-interface ens19.10
 no passive-interface ens19.20
 no passive-interface ens19.60
 redistribute bgp 65000 route-map BGP_TO_OSPF
!
router bgp 65000
 bgp router-id 10.10.10.1
 bgp log-neighbor-changes
 no bgp ebgp-requires-policy
 neighbor 10.10.101.2 remote-as 65000
 neighbor 10.10.101.2 description dc-1-vpn-rtr
 neighbor 10.10.101.2 weight 200
 neighbor 10.10.101.2 update-source gre101
 neighbor 10.10.102.2 remote-as 65000
 neighbor 10.10.102.2 description dc-2-vpn-rtr
 neighbor 10.10.102.2 weight 100
 neighbor 10.10.102.2 update-source gre102
 !
 address-family ipv4 unicast
  redistribute ospf
  neighbor 10.10.101.2 activate
  neighbor 10.10.102.2 activate
 exit-address-family
!
route-map BGP_TO_OSPF permit 10
!
ip pim rp 10.120.150.150
!
line vty
!
EOF

chown -R frr:frr /etc/frr/
chmod 640 /etc/frr/frr.conf
systemctl enable --now frr

### === 7. NTP (chrony) ===
echo "[+] Настройка NTP..."

cat > /etc/chrony/chrony.conf <<EOF
server ntp.msk-ix.ru iburst
server 0.ru.pool.ntp.org iburst
server 1.ru.pool.ntp.org iburst

allow 10.100.0.0/16

driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF

systemctl restart chrony

### === 8. SSH + RADIUS аутентификация ===
echo "[+] Настройка SSH и RADIUS..."

# SSH конфигурация
cat > /etc/ssh/sshd_config.d/10-custom.conf <<EOF
Port 22
PermitRootLogin no
PasswordAuthentication yes
ChallengeResponseAuthentication yes
UsePAM yes
X11Forwarding no
AllowUsers green
AllowGroups sudo
EOF

# PAM для RADIUS
sed -i '2 a auth required pam_radius_auth.so' /etc/pam.d/sshd

cat > /etc/pam_radius_auth.conf <<EOF
10.100.20.10      RadiusSecret123      3
EOF
chmod 600 /etc/pam_radius_auth.conf

# Пользователь green
useradd -m -s /bin/bash -G sudo green 2>/dev/null || true
echo "green:P@ssw0rd" | chpasswd

systemctl restart ssh

### === 9. SNMP v3 ===
echo "[+] Настройка SNMP..."

cat > /etc/snmp/snmpd.conf <<EOF
agentAddress udp:161
sysLocation "Moscow DC (Primary)"
sysContact admin@office.local

createUser snmpuser SHA snmppass AES snmppass

view   greenskills included .1
group  green2026    v3 priv    greenskills

access green2026 "" usm priv prefix exact greenskills none none

rwuser snmpuser priv
EOF

systemctl restart snmpd

### === 10. Syslog-ng ===
echo "[+] Настройка Syslog..."

cat >> /etc/syslog-ng/syslog-ng.conf <<EOF

destination d_remote {
    syslog("10.100.20.10" transport("udp") port(514));
};

log {
    source(s_src);
    destination(d_remote);
    filter(f_messages);
};
EOF

systemctl restart syslog-ng

### === 11. IP SLA мониторинг ===
echo "[+] Настройка IP SLA мониторинга..."

cat > /usr/local/bin/ip-sla-monitor.sh <<'EOF'
#!/bin/bash
set -e

TRACK_FILE="/var/run/ip-sla-track1"
TEST_IP="11.11.11.1"

# Получаем текущий шлюз по умолчанию
GATEWAY=$(ip route show default | awk '{print $3}')

if [ -z "$GATEWAY" ]; then
    logger -t ip-sla "No default gateway found"
    exit 1
fi

if ping -c 3 -W 2 "$TEST_IP" &>/dev/null; then
    if [ ! -f "$TRACK_FILE" ] || [ "$(cat $TRACK_FILE)" != "1" ]; then
        echo "1" > "$TRACK_FILE"
        logger -t ip-sla "Internet connectivity RESTORED via $GATEWAY"
    fi
else
    if [ -f "$TRACK_FILE" ] && [ "$(cat $TRACK_FILE)" != "0" ]; then
        echo "0" > "$TRACK_FILE"
        logger -t ip-sla "Internet connectivity LOST via $GATEWAY"
    fi
fi
EOF

chmod +x /usr/local/bin/ip-sla-monitor.sh

cat > /etc/systemd/system/ip-sla-monitor.service <<EOF
[Unit]
Description=IP SLA Monitor (Primary)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ip-sla-monitor.sh
EOF

cat > /etc/systemd/system/ip-sla-monitor.timer <<EOF
[Unit]
Description=Run IP SLA Monitor every 10 seconds (Primary)
After=network-online.target

[Timer]
OnBootSec=30
OnUnitActiveSec=10

[Install]
WantedBy=timers.target
EOF

systemctl enable --now ip-sla-monitor.timer

### === 12. Финальная проверка ===
echo ""
echo "=========================================="
echo "✅ Конфигурация основного роутера завершена!"
echo "=========================================="
echo ""
echo "Интерфейсы:"
ip -br addr show | grep -E "(ens18|ens19|gre|lo|vlan)"
echo ""
echo "WAN интерфейс (DHCP):"
ip -br addr show ens18
echo ""
echo "Маршрут по умолчанию (получен через DHCP):"
ip route show default
echo ""
echo "Маршруты к локальной сети 10.100.0.0/16:"
ip route show 10.100.0.0/16 2>/dev/null || echo "  Будет добавлен после поднятия ens19.60"
echo ""
echo "GRE туннели (адреса удалённых концов +1):"
echo "  tun101 → 172.217.35.81 (MOONET +1)"
echo "  tun102 → 178.207.179.5 (GIGAFON COD +1)"
ip tunnel show | grep gre || echo "  Туннели ещё не подняты (ждём IPsec)"
echo ""
echo "Службы:"
for svc in frr strongswan nftables chrony ssh snmpd syslog-ng ip-sla-monitor.timer; do
    systemctl is-active $svc 2>/dev/null && echo "  ✅ $svc: active" || echo "  ❌ $svc: inactive"
done
echo ""
echo "⚠️ ВАЖНО:"
echo "   - ens18 = WAN (к провайдеру GOSTELECOM) — DHCP"
echo "   - ens19 = LAN (к бэкбону c-msk-1-bs) — транк с VLAN 10/20/60"
echo "   - Все внешние адреса увеличены на +1 согласно таблице провайдеров"
echo "   - Статические маршруты к провайдерам УДАЛЕНЫ (приходят через BGP от ISP)"
echo ""
echo "💡 Особенности основного роутера:"
echo "   - BGP weight: 200 (tun101) и 100 (tun102) — выше чем у резервного"
echo "   - IP SLA: проверка доступности 11.11.11.1 (сеть провайдера ROAMING)"
echo "   - Адреса туннелей: 172.217.35.81 и 178.207.179.5 (+1 от таблицы)"
