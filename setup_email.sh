#!/usr/bin/env bash
# setup-mail-server.sh - Instalación y configuración básica de servidor DHCP, DNS, MTA/MDA y webmail en Ubuntu Server 24.
# Mayor robustez: validaciones, creación automática de DB Roundcube, manejo de errores y ajuste de servicio DNS (named)

set -euo pipefail
IFS=$'\n\t'

# Variables (ajusta si fuera necesario)
readonly IFACE="enp0s8"
readonly NETWORK="192.168.56.0"
readonly NETMASK="255.255.255.0"
readonly RANGE_START="192.168.56.100"
readonly RANGE_END="192.168.56.200"
readonly GATEWAY="192.168.56.1"
# Dominio (elige midominio.com o midominio.christian)
readonly DOMAIN="midominio.com"
readonly HOST="mail"
readonly FQDN="${HOST}.${DOMAIN}"
readonly DB_PATH="/var/lib/bind"
# Credenciales de base de datos Roundcube
readonly RC_DB_NAME="roundcube"
readonly RC_DB_USER="rc_user"
readonly RC_DB_PASS="$(openssl rand -base64 12)"

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

# Verificar interfaz
if ! ip link show "${IFACE}" &>/dev/null; then
  err "La interfaz ${IFACE} no existe. Ajusta IFACE al valor correcto."
fi

log "Actualizando repositorios e instalando paquetes..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  isc-dhcp-server bind9 bind9utils bind9-doc \
  postfix postfix-mysql dovecot-imapd dovecot-pop3d \
  mariadb-server apache2 php php-mysql php-intl php-zip php-mbstring php-pear php-net-smtp php-net-socket php-mail-mime wget unzip

# Servicio DNS real es 'named'
DNS_SERVICE="named"

log "Configurando ISC-DHCP-Server en interfaz ${IFACE}..."
cat > /etc/default/isc-dhcp-server <<EOF
INTERFACESv4="${IFACE}"
INTERFACESv6=""
EOF

cat > /etc/dhcp/dhcpd.conf <<EOF
option domain-name "${DOMAIN}";
option domain-name-servers ${GATEWAY};

default-lease-time 600;
max-lease-time 7200;

authoritative;

subnet ${NETWORK} netmask ${NETMASK} {
  range ${RANGE_START} ${RANGE_END};
  option routers ${GATEWAY};
}
EOF

log "Configurando BIND9 (DNS) para ${DOMAIN}..."
cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";
    recursion yes;
    allow-recursion { ${NETWORK}/24; };
    listen-on { ${GATEWAY}; };
    forwarders { 8.8.8.8; 8.8.4.4; };
    dnssec-validation auto;
    auth-nxdomain no;
    listen-on-v6 { none; };
};
EOF

cat >> /etc/bind/named.conf.local <<EOF
zone "${DOMAIN}" {
    type master;
    file "${DB_PATH}/db.${DOMAIN}";
};
EOF

cat > ${DB_PATH}/db.${DOMAIN} <<EOF
\$TTL    604800
@       IN      SOA     ns.${DOMAIN}. admin.${DOMAIN}. (
                              4         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL

@       IN      NS      ns.${DOMAIN}.
ns      IN      A       ${GATEWAY}
${HOST} IN      A       ${GATEWAY}
@       IN      MX 10   ${HOST}.${DOMAIN}.
EOF
chown root:bind ${DB_PATH}/db.${DOMAIN}
chmod 640 ${DB_PATH}/db.${DOMAIN}

log "Configurando MariaDB y creando BD Roundcube..."
systemctl start mariadb
mysql --user=root <<SQL
CREATE DATABASE IF NOT EXISTS \`${RC_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${RC_DB_USER}'@'localhost' IDENTIFIED BY '${RC_DB_PASS}';
GRANT ALL ON \`${RC_DB_NAME}\`.* TO '${RC_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

log "Instalando Roundcube manualmente..."
cd /tmp
wget -q https://github.com/roundcube/roundcubemail/releases/download/1.6.2/roundcubemail-1.6.2-complete.tar.gz
rm -rf /var/www/html/roundcube
tar xzf roundcubemail-1.6.2-complete.tar.gz
mv roundcubemail-1.6.2 /var/www/html/roundcube
chown -R www-data:www-data /var/www/html/roundcube

log "Configurando Roundcube..."
cat > /var/www/html/roundcube/config/config.inc.php <<EOF
<?php
global \$config;
\$config['db_dsnw'] = 'mysql://${RC_DB_USER}:${RC_DB_PASS}@localhost/${RC_DB_NAME}';
\$config['default_host'] = 'localhost';
\$config['smtp_server'] = 'localhost';
\$config['smtp_port'] = 25;
\$config['mail_domain'] = '${DOMAIN}';
\$config['support_url'] = '';
\$config['product_name'] = 'Demo Mail';
\$config['plugins'] = ['archive', 'managesieve'];
?>
EOF

log "Configurando Apache para Roundcube..."
a2enmod rewrite headers ssl
cat > /etc/apache2/sites-available/roundcube.conf <<EOF
<VirtualHost *:80>
    ServerName ${FQDN}
    DocumentRoot /var/www/html/roundcube
    <Directory /var/www/html/roundcube/>
      Options +FollowSymLinks
      AllowOverride All
      Require all granted
    </Directory>
    ErrorLog "/var/log/apache2/roundcube_error.log"
    CustomLog "/var/log/apache2/roundcube_access.log" combined
</VirtualHost>
EOF

a2dissite 000-default
a2ensite roundcube

log "Reiniciando y habilitando servicios..."
services=(isc-dhcp-server "${DNS_SERVICE}" mariadb postfix dovecot apache2)
for svc in "${services[@]}"; do
  log "-> Restarting \$svc..."
  systemctl restart "\$svc"
  log "-> Enabling \$svc..."
  systemctl enable "\$svc"
done

log "¡Configuración completada!"
echo "- Webmail: http://${FQDN}/"
echo "- BD Roundcube: usuario=${RC_DB_USER} contraseña=${RC_DB_PASS}"
