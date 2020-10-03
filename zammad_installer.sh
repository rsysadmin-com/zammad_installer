#!/usr/local/env bash

# Zammad installer
#
# 20200920 - Martin Mielke <martinm@rsysadmin.com>
#
# quick and dirty script to install Zammad based on the instructions described here:
# https://docs.zammad.org/en/latest/install/centos.html
#
# Target OS: CentOS 8 (for now)
#
# Feel free to change this to fit your needs.
#
# Disclaimer: this script is provided on an "AS IS" basis.
# The autor is not to be held responsible for the use, misuse and/or any damage
# that this little tool may cause.
#

# soem variables
zammad_fqdn=$(hostname -f)                # i.e.: helpdesk.domain.tld
ssl_crt=/etc/nginx/ssl/${zammad_fqdn}.crt
ssl_key=/etc/nginx/ssl/${zammad_fqdn}.key
ssl_csr=/etc/nginx/ssl/${zammad_fqdn}.csr
ssl_dhp=/etc/nginx/ssl/dhparam.pem

dns1=8.8.8.8    # or use your own DNS
dns2=8.8.4.4

# ---- YOU SHOULD NOT NEED TO EDIT BELOW THIS LINE ----

# check that we are running this as the root user
if [ $UID -ne 0 ]
then
  echo -e "\n ERROR - you must be root to run this installer.\n"
  exit 1
fi

# little banner
cat << EOF

=== Zammad Installer - v.0.001 ===
    by: martinm@rsysadmin.com
----------------------------------

EOF

# load system functions for prettier handling of return codes
if [ -r /etc/init.d/functions ]
then
  . /etc/init.d/functions
fi

# main()

# Install and configure prerequisites first...

action "== Importing ElasticSearch repository key"
rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch


action "== Adding ElasticSearch repository file to the system"
echo "[elasticsearch-7.x]
name=Elasticsearch repository for 7.x packages
baseurl=https://artifacts.elastic.co/packages/7.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md" > /etc/yum.repos.d/elasticsearch-7.x.repo


echo "== Installing Java OpenJDK and ElasticSearch..."
yum install java-1.8.0-openjdk elasticsearch -y 

action "== Installing ingest-attachment plugin."
/usr/share/elasticsearch/bin/elasticsearch-plugin install --batch ingest-attachment

action "== Adding recommended ElasticSearch configuration"
echo "

# Zammad Stuff
#
# Tickets above this size (articles + attachments + metadata)
# may fail to be properly indexed (Default: 100mb).
#
# When Zammad sends tickets to Elasticsearch for indexing,
# it bundles together all the data on each individual ticket
# and issues a single HTTP request for it.
# Payloads exceeding this threshold will be truncated.
#
# Performance may suffer if it is set too high.
http.max_content_length: 400mb

# Allows the engine to generate larger (more complex) search queries.
# Elasticsearch will raise an error or deprecation notice if this value is too low,
# but setting it too high can overload system resources (Default: 1024).
#
# Available in version 6.6+ only.
indices.query.bool.max_clause_count: 2000

" >> /etc/elasticsearch/elasticsearch.yml


action "== Setting vm.max_map_count for ElasticSearch"
sysctl -w vm.max_map_count=262144 > /dev/null


action "== Reloading some daemons"
systemctl daemon-reload


action "== Enabling and starting ElasticSearch"
systemctl -q enable --now elasticsearch 


action "== Adding Zammad repository to the system"
wget -O /etc/yum.repos.d/zammad.repo https://dl.packager.io/srv/zammad/zammad/stable/installer/el/8.repo


echo -e "== Installing Zammad..."
yum install zammad -y 

action "== Removing default nginx configuration (no SSL support)"
rm -f /etc/nginx/conf.d/zammad.conf

action "== Fixing file permissions on Zammad's public directory"  # this was needed at least until version 3.4.x
find /opt/zammad/public -type f -exec chmod 644 {} \;             # remove these 2 lines if newer versions already fix the issue

action "== Creating /etc/nginx/ssl directory"
mkdir /etc/nginx/ssl

action "== Generating self-signed SSL certs..."
# generate key and csr 
openssl req -new -newkey rsa:4096 -nodes \
    -keyout $ssl_key -out $ssl_csr \
    -subj "/C=CH/ST=Denial/L=Zug/O=Dis/CN=server"

# generate elf signed passwordless certificate 
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=server" \
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

action "== Creating nginx configuration with SSL support"

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

  ssl_protocols TLSv1.2;

  ssl_ciphers 'EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH';

  ssl_dhparam /etc/nginx/ssl/dhparam.pem;

  ssl_prefer_server_ciphers on;

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


action "== Updating SELinux settings"
setsebool httpd_can_network_connect on -P


echo "== Setting up your firewall..."
action "-- adding HTTP service"
firewall-cmd -q --zone=public --add-service=http --permanent

action "-- adding HTTPS service"
firewall-cmd -q --zone=public --add-service=https --permanent

action "-- reloading firewall with new settings"
firewall-cmd -q --reload


action "== Connecting Zammad and ElasticSearch"
zammad run rails r "Setting.set('es_url', 'http://localhost:9200')"


action "== Rebuilding indexes"
zammad run rake searchindex:rebuild  > /dev/null


action "== Doing some final configuration on Zammad"
zammad run rails r "Setting.set('es_index', Socket.gethostname.downcase + '_zammad')"

action "== Excluding stuff to be indexed"
zammad run rails r "Setting.set('es_attachment_ignore', [ '.png', '.jpg', '.jpeg', '.mpeg', '.mpg', '.mov', '.bin', '.exe', '.box', '.mbox' ] )"

action "== Setting maximum size for attachements to be indexed"
zammad run rails r "Setting.set('es_attachment_max_size_in_mb', 50)"



echo "== Generating dhparam.pem file... seat back and relax... :-)"
openssl dhparam -out $ssl_dhp 4096 

echo "== Restarting services..."
systemctl restart elasticsearch
systemctl restart zammad
systemctl restart nginx

echo -e "\n\nZammad is ready...\n"


