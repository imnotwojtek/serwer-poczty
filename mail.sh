#!/bin/bash

# Check for root privileges
if [ "$(id -u)" != "0" ]; then
    echo "Run this script as root!"
    exit 1
fi

# Update system and install packages
apt update && apt upgrade -y
apt install -y postfix dovecot-core dovecot-imapd dovecot-pop3d \
opendkim opendkim-tools opendmarc rspamd clamav-daemon fail2ban \
certbot ufw redis-server unattended-upgrades logwatch mysql-server \
auditd && apt autoremove -y

# Automatic updates configuration
dpkg-reconfigure -plow unattended-upgrades

# Firewall (UFW) - Stricter rules
ufw default deny incoming
ufw default allow outgoing
ufw allow 25,587,465/tcp  # SMTP
ufw allow 143,993,110,995/tcp  # IMAP/POP3
ufw allow 3306/tcp  # MySQL (only if needed)
ufw enable

# Postfix: Enhanced Security
postconf -e "myhostname = mail.yourdomain.com" # Replace yourdomain.com
postconf -e "mydomain = yourdomain.com" # Replace yourdomain.com
postconf -e "myorigin = $mydomain"
postconf -e "mydestination = $myhostname, $mydomain, localhost.localdomain, localhost"
postconf -e "relayhost ="
postconf -e "smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
postconf -e "smtpd_tls_mandatory_protocols = TLSv1.2, TLSv1.3"
postconf -e "smtpd_tls_mandatory_ciphers = HIGH"
postconf -e "smtpd_tls_security_level = encrypt"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination, check_policy_service unix:private/policy-spf"
postconf -e "smtpd_data_restrictions = reject_unauth_destination" # added stricter check
postconf -e "smtpd_banner = $myhostname ESMTP $mail_name (Ubuntu)" # Minimal banner
postconf -e "disable_vrfy_command = yes" # Security best practice
postconf -e "smtp_helo_timeout = 300s"
postconf -e "smtpd_helo_required = yes"


# Dovecot: High Security
sed -i 's/#ssl = yes/ssl = yes/' /etc/dovecot/conf.d/10-ssl.conf
sed -i 's/#auth_mechanisms = plain login/auth_mechanisms = plain login/' /etc/dovecot/conf.d/10-auth.conf
sed -i 's/#disable_plaintext_auth = yes/disable_plaintext_auth = yes/' /etc/dovecot/conf.d/10-auth.conf
# Consider using a more secure authentication method like LDAP or PAM

# DKIM and DMARC configuration (Generate your own keys)
# ... (Your DKIM and DMARC key generation and configuration) ...  # DO NOT USE GENERATED KEYS DIRECTLY FROM SCRIPT!

# Let's Encrypt - Automatic renewal
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload postfix dovecot'") | crontab -

# Fail2Ban: Enhanced Security
cat > /etc/fail2ban/jail.local <<EOL
[postfix]
enabled  = true
port    = smtp,ssmtp
logpath = /var/log/mail.log
maxretry = 3
bantime  = 86400

[dovecot]
enabled  = true
port    = pop3,pop3s,imap,imaps
logpath = /var/log/mail.log
maxretry = 3
bantime  = 86400

[mysqld-auth]
enabled  = true
port    = 3306
logpath = /var/log/mysql/error.log
maxretry = 3
bantime  = 86400
EOL
systemctl restart fail2ban

# Rspamd (Spam filtering) - Minimal Configuration
systemctl enable rspamd
systemctl start rspamd

# ClamAV (Antivirus) - Minimal Configuration
freshclam
systemctl enable clamav-daemon
systemctl start clamav-daemon

# MySQL: Security hardening (Replace with stronger password!)
mysql_secure_installation
# Consider using TLS for MySQL connections


# Logwatch: Minimal configuration.  No email addresses!
echo "Detail = High" > /etc/logwatch/conf/logwatch.conf
systemctl restart logwatch

# Auditd: System Auditing (Customize rules as needed)
systemctl enable auditd
systemctl start auditd
# Add audit rules to /etc/audit/audit.rules to monitor specific files and actions.

# Restart services
systemctl restart postfix dovecot rspamd clamav-daemon

echo "Installation complete!  Security and Privacy Enhanced."
