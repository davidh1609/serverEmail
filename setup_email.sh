#!/usr/bin/env bash
set -e

# Variables (ajusta si fuera necesario)
IFACE="emp0s8"
NETWORK="192.168.56.0"
NETMASK="255.255.255.0"
RANGE_START="192.168.56.100"
RANGE_END="192.168.56.200"
GATEWAY="192.168.56.1"
# Dominio ajustado a midominio.com (puedes cambiar a midominio.christian si lo prefieres)
DOMAIN="midominio.com"
HOST="mail"
FQDN="${HOST}.${DOMAIN}"
DB_PATH="/var/lib/bind"

echo "==> Actualizando repositorios e instalando paquetes..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  isc-dhcp-server bind9 bind9utils bind9-doc \
  apache2 postfix postfix-mysql dovecot-imapd dovecot-pop3d \
  roundcube roundcube-core roundcube-mysql

echo "==> Configurando ISC-DHCP-Server..."
cat > /etc/default/isc-dhcp-server <<EOF
# INTERFACESv4: interfaz en la que escucha DHCPv4
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

echo "==> Configurando BIND9 (DNS)..."
# Habilitar consultas recursivas sólo desde la red interna
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

# Zona directa
cat >> /etc/bind/named.conf.local <<EOF
zone "${DOMAIN}" {
    type master;
    file "${DB_PATH}/db.${DOMAIN}";
};
EOF

# Crear archivo de zona
cat > ${DB_PATH}/db.${DOMAIN} <<EOF
$TTL    604800
@       IN      SOA     ns.${DOMAIN}. admin.${DOMAIN}. (
                              2         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL

; Name servers
        IN      NS      ns.${DOMAIN}.

; Registros A
ns      IN      A       ${GATEWAY}
${HOST} IN      A       ${GATEWAY}

; MX
@       IN      MX 10   ${HOST}.${DOMAIN}.

EOF

chown root:bind ${DB_PATH}/db.${DOMAIN}
chmod 640 ${DB_PATH}/db.${DOMAIN}

echo "==> Configurando Postfix y Dovecot..."
# Postfix: usar dominio local
postconf -e "myhostname = ${FQDN}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
postconf -e "home_mailbox = Maildir/"

# Dovecot: asegurar soporte Maildir
sed -i 's|#mail_location = .*|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf

# Permitir login plain (sólo dentro de la demo)
sed -i 's|#disable_plaintext_auth = yes|disable_plaintext_auth = no|' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|auth_mechanisms = .*|auth_mechanisms = plain login|' /etc/dovecot/conf.d/10-auth.conf

echo "==> Configurando Roundcube (webmail... )"
# Apuntar Apache a Roundcube
a2enconf roundcube
a2enmod rewrite headers

echo "==> Reiniciando servicios..."
systemctl restart isc-dhcp-server
systemctl restart bind9
systemctl restart postfix
systemctl restart dovecot
systemctl restart apache2

echo "==> Habilitando servicios al arranque..."
systemctl enable isc-dhcp-server bind9 postfix dovecot apache2

echo "==> ¡Listo!"
echo "  • DHCP corriendo en ${IFACE}, rango ${RANGE_START}-${RANGE_END}"
echo "  • DNS autoritativo para ${DOMAIN}, host ${FQDN}"
echo "  • Webmail disponible en: http://${FQDN}/roundcube/"
