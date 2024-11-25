#!/bin/bash
# Kompleksowy skrypt instalacji i konfiguracji serwera pocztowego
# Wersja 2.0 - Rozszerzona i zabezpieczona

# Ustawienia bezpieczeństwa i obsługi błędów
set -euo pipefail

# Funkcja logowania
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/mail-server-setup.log
}

# Sprawdzenie uprawnień root
if [[ $EUID -ne 0 ]]; then
   log "ERROR: Ten skrypt musi być uruchomiony jako root"
   exit 1
fi

# Konfiguracja zmiennych środowiskowych
DOMAIN="wojtek.ovh"
EMAIL="admin@$DOMAIN"
TIMEZONE="Europe/Warsaw"
PROJECT_DIR="/opt/mailserver"
BACKUP_DIR="$PROJECT_DIR/backups"
DOCKER_COMPOSE_VERSION="2.24.0"

# Funkcja bezpiecznego pobierania plików
download_with_checksum() {
    local url="$1"
    local output="$2"
    local expected_checksum="${3:-}"
    
    log "Pobieranie pliku: $url"
    curl -fsSL "$url" -o "$output"
    
    if [[ -n "$expected_checksum" ]]; then
        echo "$expected_checksum  $output" | sha256sum -c
    fi
}

# Przygotowanie systemu
prepare_system() {
    log "Przygotowanie systemu..."
    
    # Aktualizacja systemu
    apt-get update
    apt-get upgrade -y
    
    # Instalacja niezbędnych narzędzi
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common \
        ufw \
        fail2ban \
        unattended-upgrades \
        apt-listchanges \
        needrestart \
        htop \
        iotop \
        sysstat \
        net-tools \
        tcpdump \
        mtr-tiny
    
    # Konfiguracja automatycznych aktualizacji
    dpkg-reconfigure -plow unattended-upgrades
}

# Konfiguracja bezpieczeństwa systemu
secure_system() {
    log "Konfiguracja bezpieczeństwa systemu..."
    
    # Wyłączenie nieużywanych usług
    systemctl disable \
        cups \
        bluetooth \
        avahi-daemon || true
    
    # Konfiguracja UFW
    ufw --force enable
    ufw default deny incoming
    ufw default allow outgoing
    
    # Otwórz niezbędne porty
    ufw allow 22/tcp    # SSH
    ufw allow 587/tcp   # SMTP
    ufw allow 993/tcp   # IMAPS
    ufw allow 143/tcp   # IMAP
    ufw allow 3000/tcp  # Grafana
    ufw allow 9090/tcp  # Prometheus
    
    # Konfiguracja Fail2Ban
    cat > /etc/fail2ban/jail.local <<EOL
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3

[postfix]
enabled = true
port = smtp
filter = postfix
logpath = /var/log/mail.log
maxretry = 3
EOL

    # Restart Fail2Ban
    systemctl restart fail2ban
}

# Optymalizacja systemu
optimize_system() {
    log "Optymalizacja systemu..."
    
    # Dostrajanie ustawień systemu
    cat > /etc/sysctl.d/99-custom.conf <<EOL
# Optymalizacja sieci
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65536
net.core.netdev_max_backlog = 65536

# Optymalizacja pamięci
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# Bezpieczeństwo sieci
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOL

    # Wczytanie nowych ustawień
    sysctl -p /etc/sysctl.d/99-custom.conf
}

# Instalacja Docker
install_docker() {
    log "Instalacja Docker..."
    
    # Dodanie oficjalnego klucza Docker GPG
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Konfiguracja repozytorium
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Instalacja Docker
    apt-get update
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    
    # Konfiguracja użytkownika
    USER_NAME=$(logname)
    usermod -aG docker "$USER_NAME"
}

# Przygotowanie katalogów projektu
prepare_project_directories() {
    log "Przygotowanie katalogów projektu..."
    
    mkdir -p "$PROJECT_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # Katalogi dla poszczególnych usług
    mkdir -p \
        "$PROJECT_DIR/postfix/config" \
        "$PROJECT_DIR/postfix/mail" \
        "$PROJECT_DIR/dovecot/config" \
        "$PROJECT_DIR/dovecot/mail" \
        "$PROJECT_DIR/opendkim/config" \
        "$PROJECT_DIR/rspamd/config" \
        "$PROJECT_DIR/prometheus/config" \
        "$PROJECT_DIR/prometheus/data" \
        "$PROJECT_DIR/fail2ban/config" \
        "$PROJECT_DIR/clamav/config" \
        "$PROJECT_DIR/grafana/config" \
        "$PROJECT_DIR/certbot/config" \
        "$PROJECT_DIR/certbot/www" \
        "$PROJECT_DIR/elk/logstash"
}

# Generowanie konfiguracji Docker Compose
generate_docker_compose() {
    log "Generowanie konfiguracji Docker Compose..."
    
    # Generowanie silnego hasła
    GRAFANA_PASSWORD=$(openssl rand -base64 24)
    
    cat > "$PROJECT_DIR/docker-compose.yml" <<EOL
version: '3.9'

services:
  postfix:
    image: instrumentisto/postfix:latest
    container_name: postfix
    environment:
      - MAIL_DOMAIN=${DOMAIN}
      - MAIL_RELAY_HOST=mail.${DOMAIN}
      - SMTP_PORT=587
    ports:
      - "587:587"
    networks:
      - mailnet
    volumes:
      - ./postfix/config:/etc/postfix:ro
      - ./postfix/mail:/var/mail
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE

  dovecot:
    image: dovecot/dovecot:latest
    container_name: dovecot
    volumes:
      - ./dovecot/config:/etc/dovecot
      - ./dovecot/mail:/var/mail
    networks:
      - mailnet
    restart: unless-stopped

  opendkim:
    image: instrumentisto/opendkim
    container_name: opendkim
    volumes:
      - ./opendkim/config:/etc/opendkim
    networks:
      - mailnet
    restart: unless-stopped

  rspamd:
    image: rspamd/rspamd
    container_name: rspamd
    networks:
      - mailnet
    volumes:
      - ./rspamd/config:/etc/rspamd
    restart: unless-stopped

  grafana:
    image: grafana/grafana
    container_name: grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
    networks:
      - mailnet
    volumes:
      - ./grafana/config:/var/lib/grafana
    restart: unless-stopped

  prometheus:
    image: prom/prometheus
    container_name: prometheus
    volumes:
      - ./prometheus/config:/etc/prometheus
      - ./prometheus/data:/prometheus
    networks:
      - mailnet
    restart: unless-stopped

  elk:
    image: sebp/elk
    container_name: log-management
    ports:
      - "5601:5601"
      - "9200:9200"
      - "5044:5044"
    volumes:
      - ./elk/logstash:/etc/logstash
    networks:
      - mailnet
    restart: unless-stopped

  certbot:
    image: certbot/certbot
    container_name: certbot
    volumes:
      - ./certbot/config:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    networks:
      - mailnet

networks:
  mailnet:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.default_bridge: false

EOL
}

# Konfiguracja SSL/Certbot
configure_ssl() {
    log "Konfiguracja SSL..."
    
    docker run --rm \
        -v "$PROJECT_DIR/certbot/config:/etc/letsencrypt" \
        -v "$PROJECT_DIR/certbot/www:/var/www/certbot" \
        certbot/certbot \
        certonly \
        --standalone \
        --preferred-challenges http \
        -d "$DOMAIN" \
        -d "mail.$DOMAIN" \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        --staging  # Usuń przed produkcją
}

# Skrypt kopii zapasowych
create_backup_script() {
    log "Tworzenie skryptu kopii zapasowych..."
    
    cat > /usr/local/bin/mailserver-backup.sh <<EOL
#!/bin/bash
set -euo pipefail

BACKUP_DIR="$BACKUP_DIR"
MAX_BACKUPS=7
PROJECT_DIR="$PROJECT_DIR"

# Docker Compose down przed kopią
docker-compose -f "$PROJECT_DIR/docker-compose.yml" down

# Kopia zapasowa
tar -czf "$BACKUP_DIR/mailserver_\$(date +%F).tar.gz" "$PROJECT_DIR"

# Rotacja kopii
cd "$BACKUP_DIR"
ls -t mailserver_*.tar.gz | tail -n +$((MAX_BACKUPS+1)) | xargs -d '\n' rm -f

# Restart usług
docker-compose -f "$PROJECT_DIR/docker-compose.yml" up -d
EOL

    chmod +x /usr/local/bin/mailserver-backup.sh
    
    # Dodanie do crontab
    echo "0 3 * * * root /usr/local/bin/mailserver-backup.sh" >> /etc/crontab
}

# Główna funkcja instalacji
main() {
    log "Rozpoczęcie instalacji serwera pocztowego..."
    
    prepare_system
    secure_system
    optimize_system
    install_docker
    prepare_project_directories
    generate_docker_compose
    configure_ssl
    create_backup_script
    
    # Uruchomienie kontenerów
    cd "$PROJECT_DIR"
    docker-compose up -d
    
    log "Instalacja serwera pocztowego zakończona sukcesem!"
    
    # Wyświetl podsumowanie
    echo "-------------------"
    echo "Domena: $DOMAIN"
    echo "Email administratora: $EMAIL"
    echo "Hasło Grafany: $GRAFANA_PASSWORD"
    echo "-------------------"
}

# Uruchomienie głównej funkcji
main
