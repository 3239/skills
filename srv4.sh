# Установить зависимости
apt install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release
sleep 10
# Добавить GPG ключ Docker
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Добавить репозиторий Docker
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Обновить список пакетов
apt update
sleep 3
# Установить Docker
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sleep 10
# Проверить статус
systemctl status docker
sleep 3
# Проверить версию
docker --version
docker compose version
sleep 3
# На SRV4

# Создать директорию для GitFlic
mkdir -p /opt/gitflic
cd /opt/gitflic

# Создать docker-compose.yml
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  gitflic:
    image: gitea/gitea:latest
    container_name: gitflic
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__database__DB_TYPE=postgres
      - GITEA__database__HOST=host.docker.internal:5432
      - GITEA__database__NAME=gitflic
      - GITEA__database__USER=gitflic_user
      - GITEA__database__PASSWD=P@ssw0rd
      - GITEA__server__DOMAIN=git.green.skills
      - GITEA__server__ROOT_URL=https://git.green.skills
      - GITEA__server__HTTP_PORT=3000
    restart: always
    volumes:
      - ./data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "3000:3000"
      - "2222:22"
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF

# Запустить GitFlic
docker compose up -d
sleep 3
# Проверить статус
docker compose ps
sleep 3
# Проверить логи
docker compose logs -f
sleep 5
# Дождаться полного запуска (может занять несколько минут)
# Нажать Ctrl+C для выхода из логов

# Проверить доступность
curl http://localhost:3000
sleep 5
# На SRV4

# Создать конфигурацию для git.green.skills
cat > /etc/nginx/sites-available/gitflic << 'EOF'
# Перенаправление HTTP → HTTPS
server {
    listen 80;
    server_name git.green.skills;
    return 301 https://$server_name$request_uri;
}

# HTTPS сервер
server {
    listen 443 ssl http2;
    server_name git.green.skills;
    
    # SSL сертификаты
    ssl_certificate /etc/nginx/ssl/git.green.skills.crt;
    ssl_certificate_key /etc/nginx/ssl/git.green.skills.key;
    
    # SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # Логи
    access_log /var/log/nginx/gitflic_access.log;
    error_log /var/log/nginx/gitflic_error.log;
    
    # Проксирование на GitFlic
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Таймауты
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

# Активировать сайт
ln -s /etc/nginx/sites-available/gitflic /etc/nginx/sites-enabled/
sleep 3
# Проверить конфигурацию
nginx -t
sleep 5
# Перезапустить Nginx
systemctl reload nginx
sleep 3
# Проверить
curl -k https://git.green.skills
sleep 3
# На SRV4

# Установить Ansible
apt update
apt install -y ansible
sleep 10
# Проверить версию
ansible --version
sleep 3
# На SRV4

# Создать директорию для Ansible
mkdir -p /srv/ansible
cd /srv/ansible
sleep 5
# Создать структуру директорий
mkdir -p {inventory,playbooks,roles,group_vars,host_vars}
sleep 5
# Создать inventory файл
cat > inventory/hosts << 'EOF'
[clients]
cli-2.green.skills

[clients:vars]
ansible_user=root
ansible_password=P@ssw0rd
ansible_connection=ssh
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

# Создать ansible.cfg
cat > ansible.cfg << 'EOF'
[defaults]
inventory = inventory/hosts
host_key_checking = False
retry_files_enabled = False
deprecation_warnings = False

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False
EOF

# На SRV4

# Создать плейбук
cat > playbooks/configure_cli2.yml << 'EOF'
---
- name: Configure CLI-2
  hosts: clients
  become: yes
  
  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600
    
    - name: Install NFS client
      apt:
        name: nfs-common
        state: present
    
    - name: Get list of domain users
      shell: "getent passwd | grep '/home/' | cut -d: -f1"
      register: domain_users
      changed_when: false
    
    - name: Create Desktop directory for each user
      file:
        path: "/home/{{ item }}/Desktop"
        state: directory
        owner: "{{ item }}"
        group: "{{ item }}"
        mode: '0755'
      loop: "{{ domain_users.stdout_lines }}"
      when: domain_users.stdout_lines | length > 0
      ignore_errors: yes
    
    - name: Create Shares directory for each user
      file:
        path: "/home/{{ item }}/Desktop/Shares"
        state: directory
        owner: "{{ item }}"
        group: "{{ item }}"
        mode: '0755'
      loop: "{{ domain_users.stdout_lines }}"
      when: domain_users.stdout_lines | length > 0
      ignore_errors: yes
    
    - name: Mount Shares to Desktop for each user
      mount:
        path: "/home/{{ item }}/Desktop/Shares"
        src: "10.10.0.12:/mnt/tank/Shares"
        fstype: nfs
        opts: defaults,_netdev
        state: mounted
      loop: "{{ domain_users.stdout_lines }}"
      when: domain_users.stdout_lines | length > 0
      ignore_errors: yes
    
    - name: Add fstab entry for automatic mounting
      lineinfile:
        path: /etc/fstab
        line: "10.10.0.12:/mnt/tank/Shares /home/%U/Desktop/Shares nfs defaults,_netdev,user,noauto 0 0"
        state: present
    
    - name: Create pam_mount configuration
      copy:
        dest: /etc/security/pam_mount.conf.xml
        content: |
          <?xml version="1.0" encoding="utf-8" ?>
          <pam_mount>
            <volume user="*" fstype="nfs" server="10.10.0.12" 
                    path="/mnt/tank/Shares" 
                    mountpoint="~/Desktop/Shares" 
                    options="defaults,_netdev" />
          </pam_mount>
    
    - name: Install libpam-mount
      apt:
        name: libpam-mount
        state: present
EOF

# Проверить синтаксис плейбука
ansible-playbook playbooks/configure_cli2.yml --syntax-check
sleep 5
# Проверить подключение к CLI-2
ansible clients -m ping
sleep 5
# Запустить плейбук
ansible-playbook playbooks/configure_cli2.yml
sleep 5
# Проверить результат
ansible clients -m shell -a "df -h | grep Shares"
