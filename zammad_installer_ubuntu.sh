#!/usr/bin/env bash

# Zammad installer
#
# 20201005 - Martin Mielke <martinm@rsysadmin.com>
# 20251110 - Updated for Ubuntu 24.04.3 LTS
#
# quick and dirty script to install Zammad based on the instructions described here:
# https://docs.zammad.org/en/latest/install/ubuntu.html
#
# Target OS: Ubuntu 24.04.3 LTS (compatible with 20.04+)
#
# Changes in latest version:
# - Updated to Elasticsearch 8.x (includes bundled JDK)
# - Enabled Elasticsearch 8.x security with HTTPS and authentication
# - Automatic SSL certificate configuration for Zammad
# - Secure password generation for Elasticsearch
# - Removed ingest-attachment plugin installation (bundled in ES 8.x)
# - Modernized TLS configuration (TLSv1.2 + TLSv1.3)
# - Updated SSL cipher suite for better security
# - Fixed apt-key deprecation (using gpg --dearmor with keyrings)
# - Removed deprecated file permission fix
#
# Feel free to change this to fit your needs.
#
# Disclaimer: this script is provided on an "AS IS" basis.
# The autor is not to be held responsible for the use, misuse and/or any damage
# that this little tool may cause.
#

# some variables
zammad_fqdn=$HOSTNAME                       # use the system's variables
ssl_crt=/etc/nginx/ssl/${zammad_fqdn}.crt
ssl_key=/etc/nginx/ssl/${zammad_fqdn}.key
ssl_csr=/etc/nginx/ssl/${zammad_fqdn}.csr
ssl_dhp=/etc/nginx/ssl/dhparam.pem

dns1=8.8.8.8    # or use your own DNS
dns2=8.8.4.4

# ---- YOU SHOULD NOT NEED TO EDIT BELOW THIS LINE ----

# output everything to a log file - you will need it if something goes wrong
zammadLog=./zammad_install-$(date +"%Y%m%d-%T").log
exec > >(tee -i $zammadLog)
exec 2>&1

# check that we are running this as the root user
if [ $UID -ne 0 ]
then
  echo -e "\n ERROR - you must be root to run this installer.\n"
  exit 1
fi

function checkStatus() {
    if [ $? -eq 0 ]
    then
        echo -e "[  OK!  ]\n"
    else 
        echo -e "[ ERROR ]\n"
        exit 1
    fi

}

# little banner
cat << EOF

=== Zammad Installer - v.0.002 (Ubuntu 24.04.3) ===
    by: martinm@rsysadmin.com
    Updated: 2025-11-10 for Ubuntu 24.04.3 LTS
-------------------------------------------------

EOF

# main()

# Install and configure prerequisites first...

echo -e "== Installing prerequisites..."
apt-get update -y
apt-get install apt-transport-https wget gpg firewalld nginx -y

echo -e "== Importing ElasticSearch repository key\t\c"
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
checkStatus
echo -e "-- adding repository\t\c"
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" | tee /etc/apt/sources.list.d/elastic-8.x.list > /dev/null
checkStatus

apt-get update -y
# Note: Elasticsearch 8.x includes a bundled JDK (no separate Java installation needed)
apt-get install elasticsearch -y
echo -e "== Note: Elasticsearch 8.x includes bundled JDK and ingest-attachment plugin"

echo -e "== Configuring ElasticSearch for Zammad\t\c"
# Remove any existing Zammad configuration to prevent duplicates
sed -i '/# Zammad:/d' /etc/elasticsearch/elasticsearch.yml
sed -i '/^http\.max_content_length:/d' /etc/elasticsearch/elasticsearch.yml
sed -i '/^indices\.query\.bool\.max_clause_count:/d' /etc/elasticsearch/elasticsearch.yml

# Add Zammad-specific configuration
cat >> /etc/elasticsearch/elasticsearch.yml << 'ESCONFIG'

# Zammad: Increase max content length for large tickets (Default: 100mb)
http.max_content_length: 400mb

# Zammad: Allow more complex search queries (Default: 1024)
indices.query.bool.max_clause_count: 2000
ESCONFIG

checkStatus


echo -e "== Setting vm.max_map_count for ElasticSearch\t\c"
sysctl -w vm.max_map_count=262144 > /dev/null
checkStatus

echo -e "== Reloading some daemons\t\c"
systemctl daemon-reload
checkStatus

echo -e "== Enabling and starting ElasticSearch\t\c"
systemctl -q enable --now elasticsearch
checkStatus

echo -e "== Waiting for ElasticSearch to start up..."
# Wait for Elasticsearch to be fully ready
for i in {1..30}; do
  if curl -s -k https://localhost:9200 > /dev/null 2>&1; then
    echo "ElasticSearch is ready!"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "WARNING: ElasticSearch may not be fully started"
  fi
  sleep 2
done

echo -e "== Generating and setting ElasticSearch password\t\c"
# Auto-generate a strong password for the elastic user in batch mode
ES_PASSWORD_OUTPUT=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -a -b 2>&1)
if [ $? -eq 0 ]; then
  # Extract the password from output (format: "New value: <password>")
  ES_PASSWORD=$(echo "$ES_PASSWORD_OUTPUT" | grep "New value:" | awk '{print $3}')
  if [ -z "$ES_PASSWORD" ]; then
    echo -e "[ ERROR ]"
    echo "Failed to extract password from output:"
    echo "$ES_PASSWORD_OUTPUT"
    exit 1
  fi
  echo -e "[  OK!  ]"
else
  echo -e "[ ERROR ]"
  echo "Failed to reset Elasticsearch password:"
  echo "$ES_PASSWORD_OUTPUT"
  exit 1
fi

echo ""
echo "*** IMPORTANT: ElasticSearch password generated: $ES_PASSWORD ***"
echo "*** Please save this password securely! ***"
echo ""

echo -e "== Adding Zammad repository to the system\t\c"
ubuntu_version=$(grep DISTRIB_RELEASE /etc/lsb-release | awk -F= '{ print $2 }')
wget -qO - https://dl.packager.io/srv/zammad/zammad/key | gpg --dearmor -o /usr/share/keyrings/zammad-keyring.gpg
wget -O /tmp/zammad.list https://dl.packager.io/srv/zammad/zammad/stable/installer/ubuntu/${ubuntu_version}.repo
sed 's|^deb |deb [signed-by=/usr/share/keyrings/zammad-keyring.gpg] |' /tmp/zammad.list > /etc/apt/sources.list.d/zammad.list
rm /tmp/zammad.list
checkStatus

echo -e "== Installing Zammad..."
apt-get update -y
apt-get install zammad -y

echo -e "== Removing default nginx configuration (no SSL support)\t\c"
rm -f /etc/nginx/sites-enabled/zammad.conf
checkStatus

echo -e "== Creating /etc/nginx/ssl directory\t\c"
mkdir -p /etc/nginx/ssl
checkStatus

echo -e "== Generating self-signed SSL certs..."
# generate key and csr 
openssl req -new -newkey rsa:4096 -nodes \
    -keyout $ssl_key -out $ssl_csr \
    -subj "/C=CH/ST=Denial/L=Zug/O=Dis/CN=server"

# generate self-signed passwordless certificate 
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=CH/ST=Denial/L=Springfield/O=Dis/CN=server" \
    -keyout $ssl_key -out $ssl_crt

# determine nginx's root directory
if [ -r /var/www/html ]
then
  nginx_root=/var/www/html
elif [ -r /usr/share/nginx/html ]
then
  nginx_root=/usr/share/nginx/html
else 
  echo -e "\nERROR - cannot find nginx\'s root directory."
  echo -e "ERROR - is nginx installed?\n"
  exit 1
fi

echo -e "== Creating nginx configuration with SSL support\t\c"
echo "
#
# Zammad nginx configuration with SSL 
#
#

upstream zammad-railsserver {
  server 127.0.0.1:3000;
}

upstream zammad-websocket {
  server 127.0.0.1:6042;
}

server {
  listen 80;

  server_name $zammad_fqdn;

  # security - prevent information disclosure about server version
  server_tokens off;

  access_log /var/log/nginx/zammad.access.log;
  error_log /var/log/nginx/zammad.error.log;

  location /.well-known/ {
    root $nginx_root;
  }

  return 301 https://\$server_name\$request_uri;

}


server {
  listen 443 ssl http2;

  server_name $zammad_fqdn;

  # security - prevent information disclosure about server version
  server_tokens off;

  ssl_certificate $ssl_crt;
  ssl_certificate_key $ssl_key;

  ssl_protocols TLSv1.2 TLSv1.3;

  ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';

  ssl_dhparam /etc/nginx/ssl/dhparam.pem;

  ssl_prefer_server_ciphers off;

  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 180m;

  resolver $dns1 $dns2;

  add_header Strict-Transport-Security "max-age=31536000" always;

  location = /robots.txt  {
    access_log off; log_not_found off;
  }

  location = /favicon.ico {
    access_log off; log_not_found off;
  }

  root /opt/zammad/public;

  access_log /var/log/nginx/zammad.access.log;
  error_log  /var/log/nginx/zammad.error.log;

  client_max_body_size 50M;

  location ~ ^/(assets/|robots.txt|humans.txt|favicon.ico) {
    expires max;
  }

  location /ws {
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header CLIENT_IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 86400;
    proxy_pass http://zammad-websocket;
  }

  location / {
    proxy_set_header Host \$http_host;
    proxy_set_header CLIENT_IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 180;
    proxy_pass http://zammad-railsserver;

    gzip on;
    gzip_types text/plain text/xml text/css image/svg+xml application/javascript application/x-javascript application/json application/xml;
    gzip_proxied any;
  }
}

" > /etc/nginx/conf.d/zammad_ssl.conf
checkStatus

echo "== Setting up your firewall..."
echo -e "-- adding HTTP service"
firewall-cmd -q --zone=public --add-service=http --permanent

echo -e "-- adding HTTPS service"
firewall-cmd -q --zone=public --add-service=https --permanent

echo -e "-- reloading firewall with new settings"
firewall-cmd -q --reload

echo -e "== Starting Zammad services for initial configuration\t\c"
systemctl start zammad
checkStatus

echo -e "== Waiting for Zammad to initialize..."
# Wait for Zammad to be fully ready
for i in {1..30}; do
  if zammad run rails r "puts 'ready'" > /dev/null 2>&1; then
    echo "Zammad is ready!"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "WARNING: Zammad may not be fully initialized"
  fi
  sleep 3
done

echo -e "== Extracting and adding ElasticSearch SSL certificate to Zammad\t\c"
ES_CERT_PATH="/etc/elasticsearch/certs/http_ca.crt"
cat > /tmp/zammad_add_cert.rb << 'RUBYSCRIPT'
cert_content = File.read('/etc/elasticsearch/certs/http_ca.crt')
cert = OpenSSL::X509::Certificate.new(cert_content)
SSLCertificate.create!(
  name: 'Elasticsearch CA',
  certificate: cert_content,
  not_before: cert.not_before,
  not_after: cert.not_after
)
RUBYSCRIPT

zammad run rails runner /tmp/zammad_add_cert.rb
rm -f /tmp/zammad_add_cert.rb
checkStatus

echo -e "== Connecting Zammad and ElasticSearch with secure credentials\t\c"
zammad run rails r "Setting.set('es_url', 'https://localhost:9200')" || { echo "[ ERROR ] Failed to set es_url"; exit 1; }
zammad run rails r "Setting.set('es_user', 'elastic')" || { echo "[ ERROR ] Failed to set es_user"; exit 1; }
zammad run rails r "Setting.set('es_password', '$ES_PASSWORD')" || { echo "[ ERROR ] Failed to set es_password"; exit 1; }
checkStatus

echo -e "== Restarting Zammad to load SSL certificate\t\c"
systemctl restart zammad
checkStatus

echo -e "== Waiting for Zammad to restart..."
# Wait for Zammad to be fully ready after restart
for i in {1..30}; do
  if zammad run rails r "puts 'ready'" > /dev/null 2>&1; then
    echo "Zammad is ready!"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "WARNING: Zammad may not be fully restarted"
  fi
  sleep 3
done

echo -e "== Rebuilding indexes"
zammad run rake zammad:searchindex:rebuild  > /dev/null

echo -e "== Doing some final configuration on Zammad"
zammad run rails r "Setting.set('es_index', Socket.gethostname.downcase + '_zammad')"

echo -e "== Excluding stuff to be indexed"
zammad run rails r "Setting.set('es_attachment_ignore', [ '.png', '.jpg', '.jpeg', '.mpeg', '.mpg', '.mov', '.bin', '.exe', '.box', '.mbox' ] )"

echo -e "== Setting maximum size for attachements to be indexed"
zammad run rails r "Setting.set('es_attachment_max_size_in_mb', 50)"

echo "== Generating dhparam.pem file (this may take a few minutes)..."
openssl dhparam -out $ssl_dhp 2048 

echo "== Restarting services..."
systemctl restart elasticsearch
systemctl restart zammad
systemctl restart nginx

echo -e "== Saving Elasticsearch credentials to /root/.zammad_es_credentials\t\c"
cat > /root/.zammad_es_credentials << EOFCRED
Elasticsearch Credentials
==========================
URL: https://localhost:9200
Username: elastic
Password: $ES_PASSWORD

Generated: $(date)

IMPORTANT: Keep this file secure!
These credentials are configured in Zammad and required for search functionality.
EOFCRED
chmod 600 /root/.zammad_es_credentials
checkStatus

echo -e "\n\n=========================================="
echo "== Zammad installation complete! =="
echo "=========================================="
echo ""
echo "Zammad URL: https://$zammad_fqdn"
echo ""
echo "Elasticsearch Configuration:"
echo "  URL: https://localhost:9200"
echo "  Username: elastic"
echo "  Password: $ES_PASSWORD"
echo ""
echo "Credentials saved to: /root/.zammad_es_credentials"
echo ""
echo "Installation log: $zammadLog"
echo "=========================================="
echo ""




# The End.
