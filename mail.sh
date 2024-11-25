#!/bin/bash

# Sprawdzenie uprawnień root
if [ "$(id -u)" != "0" ]; then
    echo "Uruchom skrypt jako root!"
    exit 1
fi

# Zmienna dla domeny
DOMAIN="wojtek.ovh"
EMAIL="admin@$DOMAIN"
DOCKER_COMPOSE_VERSION="1.29.2"

# Instalacja Dockera i Docker Compose
echo "Instalacja Dockera i Docker Compose..."
apt update && apt install -y \
    apt-transport-https ca-certificates curl software-properties-common \
    lsb-release sudo
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg
echo "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io

# Instalacja Docker Compose
echo "Instalacja Docker Compose..."
curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Dodanie użytkownika do grupy Docker
usermod -aG docker $USER

# Instalacja wymaganych kontenerów
echo "Pobieranie i uruchamianie kontenerów..."
mkdir -p /home/$USER/mailserver
cd /home/$USER/mailserver

# Tworzymy plik docker-compose.yml
cat > docker-compose.yml <<EOL
version: '3'

services:
  postfix:
    image: instrumentisto/postfix
    container_name: postfix
    environment:
      - MAIL_DOMAIN=$DOMAIN
      - MAIL_RELAY_HOST=mail.$DOMAIN
      - SMTP_PORT=587
    ports:
      - "587:587"
    networks:
      - mailnet
    volumes:
      - ./postfix/config:/etc/postfix
      - ./postfix/mail:/var/mail
    restart: always

  dovecot:
    image: dovecot/dovecot
    container_name: dovecot
    environment:
      - MAIL_DOMAIN=$DOMAIN
    ports:
      - "993:993"
      - "143:143"
    volumes:
      - ./dovecot/config:/etc/dovecot
      - ./dovecot/mail:/var/mail
    networks:
      - mailnet
    restart: always

  opendkim:
    image: instrumentisto/opendkim
    container_name: opendkim
    environment:
      - MAIL_DOMAIN=$DOMAIN
    volumes:
      - ./opendkim/config:/etc/opendkim
    networks:
      - mailnet
    restart: always

  rspamd:
    image: rspamd/rspamd
    container_name: rspamd
    ports:
      - "11332:11332"
    networks:
      - mailnet
    volumes:
      - ./rspamd/config:/etc/rspamd
    restart: always

  grafana:
    image: grafana/grafana
    container_name: grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    ports:
      - "3000:3000"
    networks:
      - mailnet
    restart: always

  prometheus:
    image: prom/prometheus
    container_name: prometheus
    ports:
      - "9090:9090"
    networks:
      - mailnet
    volumes:
      - ./prometheus/config:/etc/prometheus
      - ./prometheus/data:/prometheus
    restart: always

  fail2ban:
    image: crazymax/fail2ban
    container_name: fail2ban
    environment:
      - TZ=Europe/Warsaw
    volumes:
      - ./fail2ban/config:/etc/fail2ban
    networks:
      - mailnet
    restart: always

  clamav:
    image: clamav/clamav
    container_name: clamav
    ports:
      - "3310:3310"
    networks:
      - mailnet
    restart: always

  redis:
    image: redis
    container_name: redis
    networks:
      - mailnet
    restart: always

  cockpit:
    image: cockpit-project/cockpit
    container_name: cockpit
    ports:
      - "9090:9090"
    networks:
      - mailnet
    restart: always

networks:
  mailnet:
    driver: bridge
EOL

# Wybór ścieżek do plików konfiguracji
echo "Tworzenie katalogów do konfiguracji..."
mkdir -p ./postfix/config ./postfix/mail ./dovecot/config ./dovecot/mail ./opendkim/config ./rspamd/config ./prometheus/config ./prometheus/data ./fail2ban/config ./clamav/config ./cockpit/config

# Konfiguracja SSL (Certbot)
echo "Tworzenie certyfikatów SSL..."
docker run --rm -v /home/$USER/mailserver/certbot/config:/etc/letsencrypt -v /home/$USER/mailserver/certbot/www:/var/www/certbot \
    certbot/certbot certonly --standalone -d $DOMAIN -d mail.$DOMAIN --non-interactive --agree-tos -m $EMAIL

# Uruchomienie kontenerów
echo "Uruchamianie kontenerów Docker..."
docker-compose up -d

# Konfiguracja automatycznych backupów
echo "Konfiguracja automatycznych backupów..."
echo "0 3 * * * root tar -czf /home/$USER/mailserver/backups/mailserver_$(date +\%F).tar.gz /home/$USER/mailserver" >> /etc/crontab

# Monitoring i logi
echo "Konfiguracja monitorowania i logowania..."
docker exec grafana /bin/bash -c "grafana-cli plugins install grafana-piechart-panel"
docker exec prometheus /bin/bash -c "prometheus --config.file=/etc/prometheus/prometheus.yml --web.listen-address=:9090"

# Restart usług
echo "Restart usług..."
docker-compose restart

echo "Instalacja zakończona! Serwer pocztowy skonfigurowany w Dockerze dla $DOMAIN. Usługi są dostępne w kontenerach Docker."
