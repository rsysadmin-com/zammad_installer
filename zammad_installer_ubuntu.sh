#!/usr/bin/env bash

# Zammad installer
#
# 20201005 - Martin Mielke <martinm@rsysadmin.com>
#
# quick and dirty script to install Zammad based on the instructions described here:
# https://docs.zammad.org/en/latest/install/ubuntu.html
#
# Target OS: Ubuntu
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

=== Zammad Installer - v.0.001 (Ubuntu) ===
    by: martinm@rsysadmin.com
-------------------------------------------

EOF

# main()

# Install and configure prerequisites first...

echo -e "== Installing prerequisites..."
apt-get install apt-transport-https wget firewalld nginx -y


echo -e "== Importing ElasticSearch repository key\t\c"
echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | tee -a /etc/apt/sources.list.d/elastic-7.x.list
checkStatus
echo -e "-- adding apt key\t\c"
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | apt-key add -
checkStatus

apt-get update -y
apt-get install openjdk-8-jdk elasticsearch -y 

echo -e "== Installing ingest-attachment plugin"
/usr/share/elasticsearch/bin/elasticsearch-plugin install --batch ingest-attachment

echo -e "== Adding recommended ElasticSearch configuration\t\c"
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

echo -e "== Adding Zammad repository to the system\t\c"
ubuntu_version=$(grep DISTRIB_RELEASE /etc/lsb-release | awk -F= '{ print $2 }')
wget -qO - https://dl.packager.io/srv/zammad/zammad/key | sudo apt-key add -
wget -O /etc/apt/sources.list.d/zammad.list https://dl.packager.io/srv/zammad/zammad/stable/installer/ubuntu/${ubuntu_version}.repo
checkStatus

echo -e "== Installing Zammad..."
apt-get update -y
apt-get install zammad -y

echo -e "== Removing default nginx configuration (no SSL support)\t\c"
rm -f /etc/nginx/sites-enabled/zammad.conf
checkStatus

echo -e "== Fixing file permissions on Zammad's public directory\t\c"  # this was needed at least until version 3.4.x
find /opt/zammad/public -type f -exec chmod 644 {} \;             # remove these 2 lines if newer versions already fix the issue
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
checkStatus

echo "== Setting up your firewall..."
echo -e "-- adding HTTP service"
firewall-cmd -q --zone=public --add-service=http --permanent

echo -e "-- adding HTTPS service"
firewall-cmd -q --zone=public --add-service=https --permanent

echo -e "-- reloading firewall with new settings"
firewall-cmd -q --reload

echo -e "== Connecting Zammad and ElasticSearch"
zammad run rails r "Setting.set('es_url', 'http://localhost:9200')"

echo -e "== Rebuilding indexes"
zammad run rake searchindex:rebuild  > /dev/null

echo -e "== Doing some final configuration on Zammad"
zammad run rails r "Setting.set('es_index', Socket.gethostname.downcase + '_zammad')"

echo -e "== Excluding stuff to be indexed"
zammad run rails r "Setting.set('es_attachment_ignore', [ '.png', '.jpg', '.jpeg', '.mpeg', '.mpg', '.mov', '.bin', '.exe', '.box', '.mbox' ] )"

echo -e "== Setting maximum size for attachements to be indexed"
zammad run rails r "Setting.set('es_attachment_max_size_in_mb', 50)"

echo "== Generating dhparam.pem file... seat back and relax... :-)"
openssl dhparam -out $ssl_dhp 4096 

echo "== Restarting services..."
systemctl restart elasticsearch
systemctl restart zammad
systemctl restart nginx

echo -e "\n\n== Zammad is ready: http://$zammad_fqdn \n"




# The End.
