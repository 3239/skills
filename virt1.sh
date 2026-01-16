# Обновить систему
apt update
apt upgrade -y

# Установить пакеты виртуализации
apt install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    bridge-utils \
    virtinst \
    virt-manager \
    virt-viewer \
    cpu-checker \
    nfs-common

# Проверить поддержку виртуализации
egrep -c '(vmx|svm)' /proc/cpuinfo
# Должно вывести число больше 0

kvm-ok
# Должно вывести: KVM acceleration can be used

# Добавить пользователя в группу libvirt
usermod -aG libvirt root

# Запустить libvirtd
systemctl enable libvirtd
systemctl start libvirtd

# Проверить статус
systemctl status libvirtd

# Проверить сети libvirt
virsh net-list --all

# На VIRT1

# Создать точку монтирования
mkdir -p /mnt/vm_infra

# Смонтировать NFS (уже сделано в Шаге 6.4, но повторим)
mount -t nfs 10.10.0.12:/mnt/tank/vm_infra /mnt/vm_infra

# Проверить
df -h | grep vm_infra

# Убедиться, что запись в /etc/fstab есть
grep vm_infra /etc/fstab

# Если нет, добавить:
cat >> /etc/fstab << 'EOF'
10.10.0.12:/mnt/tank/vm_infra /mnt/vm_infra nfs defaults,_netdev 0 0
EOF

# На VIRT1

# Создать пул хранения на NFS
virsh pool-define-as vm_infra dir --target /mnt/vm_infra

# Запустить пул
virsh pool-start vm_infra

# Включить автозапуск
virsh pool-autostart vm_infra

# Проверить пулы
virsh pool-list --all

# Проверить информацию о пуле
virsh pool-info vm_infra

# На VIRT1

# Создать конфигурацию сети
cat > /tmp/internal-net.xml << 'EOF'
<network>
  <name>internal</name>
  <bridge name='virbr1'/>
  <forward mode='nat'/>
  <ip address='192.168.1.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.1.2' end='192.168.1.254'/>
      <host mac='52:54:00:00:00:05' name='vm-cloud' ip='192.168.1.5'/>
    </dhcp>
  </ip>
</network>
EOF

# Определить сеть
virsh net-define /tmp/internal-net.xml

# Запустить сеть
virsh net-start internal

# Включить автозапуск
virsh net-autostart internal

# Проверить сети
virsh net-list --all

# Проверить информацию о сети
virsh net-info internal

# Проверить DHCP конфигурацию
virsh net-dumpxml internal

# На VIRT1

# Перейти в директорию NFS хранилища
cd /mnt/vm_infra

# Скачать диск VM-CLOUD
wget http://files.greenlab.local/vm-cloud.qcow2

# Проверить скачанный файл
ls -lh vm-cloud.qcow2

# Проверить информацию о диске
qemu-img info vm-cloud.qcow2

# На VIRT1

# Создать ВМ
virt-install \
  --name=vm-cloud \
  --ram=2048 \
  --vcpus=2 \
  --disk path=/mnt/vm_infra/vm-cloud.qcow2,format=qcow2,bus=virtio \
  --network network=internal,mac=52:54:00:00:00:05,model=virtio \
  --os-variant=debian11 \
  --graphics vnc,listen=0.0.0.0,port=5900 \
  --noautoconsole \
  --import

# Проверить статус ВМ
virsh list --all

# Должна быть ВМ vm-cloud в состоянии running

# Получить информацию о ВМ
virsh dominfo vm-cloud

# Проверить сетевой интерфейс
virsh domifaddr vm-cloud

# Если IP не показывается, подождать несколько секунд и повторить

# На VIRT1

# Подключиться к консоли
virsh console vm-cloud

# Нажать Enter несколько раз

# Войти в систему (если требуется логин)
# Login: root
# Password: (пароль из образа)

# Проверить сеть
ip addr show

# Должен быть интерфейс с IP 192.168.1.5

# Если IP не настроен, настроить вручную:
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet static
    address 192.168.1.5
    netmask 255.255.255.0
    gateway 192.168.1.1
    dns-nameservers 10.10.0.10
    dns-search green.skills
EOF

systemctl restart networking

# Проверить связь
ping -c 3 192.168.1.1
ping -c 3 10.10.0.10

# Настроить hostname
hostnamectl set-hostname vm-cloud.green.skills

# На VM-CLOUD:

# Обновить систему
apt update
apt upgrade -y

# Установить ocserv
apt install -y ocserv

# Проверить установку
ocserv --version

# На VIRT1

# Скопировать файлы в VM-CLOUD
# Поскольку VM-CLOUD в изолированной сети, используем virsh
# Альтернатива: настроить SSH доступ через NAT

# Создать временную директорию на NFS
mkdir -p /mnt/vm_infra/temp_certs
cp /tmp/vpn.green.skills.* /mnt/vm_infra/temp_certs/
cp /tmp/GreenCA.crt /mnt/vm_infra/temp_certs/
# На VM-CLOUD

# Смонтировать NFS временно
apt install -y nfs-common
mkdir -p /mnt/temp
mount -t nfs 10.10.0.12:/mnt/tank/vm_infra /mnt/temp

# Скопировать сертификаты
mkdir -p /etc/ocserv/ssl
cp /mnt/temp/temp_certs/vpn.green.skills.crt /etc/ocserv/ssl/
cp /mnt/temp/temp_certs/vpn.green.skills.key /etc/ocserv/ssl/
cp /mnt/temp/temp_certs/GreenCA.crt /etc/ocserv/ssl/

# Размонтировать
umount /mnt/temp

# Проверить файлы
ls -l /etc/ocserv/ssl/

# На VM-CLOUD

# Создать конфигурационный файл
cat > /etc/ocserv/ocserv.conf << 'EOF'
# Authentication
auth = "plain[passwd=/etc/ocserv/ocpasswd]"

# TCP and UDP port number
tcp-port = 443
udp-port = 443

# Server certificate and key
server-cert = /etc/ocserv/ssl/vpn.green.skills.crt
server-key = /etc/ocserv/ssl/vpn.green.skills.key
ca-cert = /etc/ocserv/ssl/GreenCA.crt

# Run as user/group
run-as-user = nobody
run-as-group = nogroup

# Socket file
socket-file = /run/ocserv.socket

# Chroot directory
#chroot-dir = /var/lib/ocserv

# Isolate workers
isolate-workers = true

# Max clients
max-clients = 16
max-same-clients = 2

# Keepalive
keepalive = 32400
dpd = 90
mobile-dpd = 1800

# MTU
try-mtu-discovery = true

# Compression
compression = true
no-compress-limit = 256

# TLS priorities
tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-RSA:-VERS-SSL3.0:-ARCFOUR-128"

# Authentication timeout
auth-timeout = 240
idle-timeout = 1200
mobile-idle-timeout = 1800

# Reauth time
min-reauth-time = 300

# Ban score
max-ban-score = 80
ban-reset-time = 1200

# Cookie timeout
cookie-timeout = 300

# Deny roaming
deny-roaming = false

# Rekey
rekey-time = 172800
rekey-method = ssl

# Use occtl
use-occtl = true

# PID file
pid-file = /run/ocserv.pid

# Device
device = vpns

# Predictable IPs
predictable-ips = true

# Default domain
default-domain = green.skills

# IPv4 network
ipv4-network = 192.168.100.0/24

# DNS
dns = 10.10.0.10

# Routes
route = 10.0.0.0/8
route = 192.168.1.0/24

# Cisco client compatibility
cisco-client-compat = true
dtls-legacy = true
EOF

# Создать файл паролей
touch /etc/ocserv/ocpasswd

# Создать пользователя VPN
ocpasswd -c /etc/ocserv/ocpasswd vpnuser
# Ввести пароль: P@ssw0rd
# Подтвердить: P@ssw0rd

# Проверить файл паролей
cat /etc/ocserv/ocpasswd

# Включить IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Настроить iptables для NAT
iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
iptables -A FORWARD -i vpns+ -o ens3 -j ACCEPT
iptables -A FORWARD -i ens3 -o vpns+ -m state --state RELATED,ESTABLISHED -j ACCEPT

# Сохранить правила iptables
apt install -y iptables-persistent
netfilter-persistent save

# Запустить ocserv
systemctl enable ocserv
systemctl start ocserv

# Проверить статус
systemctl status ocserv

# Проверить порты
ss -tulnp | grep 443

# Проверить логи
tail -f /var/log/syslog | grep ocserv