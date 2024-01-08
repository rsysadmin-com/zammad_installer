#!/usr/bin/env bash

# Zammad installer
#
# 20201008 - Martin Mielke <martinm@rsysadmin.com>
#
# quick and dirty script to install Zammad based on the instructions described here:
# https://docs.zammad.org/en/latest/install/suse.html
#
# Target OS: (Open)SUSE 42.x
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
        echo -e "\t[  OK!  ]\n"
    else 
        echo -e "\t[ ERROR ]\n"
        exit 1
    fi

}

# little banner
cat << EOF

=== Zammad Installer - v.0.002 ((Open)SUSE) ===
    by: martinm@rsysadmin.com
-----------------------------------------------

EOF

# main()

# Install and configure prerequisites first...
echo -e "== Installing prerequisites..."
zypper install -y wget insserv-compat firewalld nginx

# are we running on Tumbleweed?
if [ $(grep ^ID= /etc/*release | awk -F= '{ print $2 }') = "\"opensuse-tumbleweed\"" ]
then
  echo "== Adding some extra repositories for Tumbleweed"
  zypper ar https://download.opensuse.org/repositories/home:jgrassler:monasca/openSUSE_Tumbleweed/home:jgrassler:monasca.repo
  zypper --gpg-auto-import-keys ref
  echo "== Installing libmysqlclient18"
  zypper install -y libmysqlclient18
  checkStatus
fi

echo -e "== Importing ElasticSearch repository key\c"
rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch
checkStatus

echo -e "== Adding ElasticSearch repository file to the system\c"
echo "[elasticsearch-7.x]
name=Elasticsearch repository for 7.x packages
baseurl=https://artifacts.elastic.co/packages/7.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md" > /etc/zypp/repos.d/elasticsearch-7.x.repo
checkStatus

echo "== Installing Java OpenJDK and ElasticSearch..."
zypper install -y java-1_8_0-openjdk elasticsearch  

echo -e "== Installing ingest-attachment plugin"
/usr/share/elasticsearch/bin/elasticsearch-plugin install --batch ingest-attachment

echo -e "== Adding recommended ElasticSearch configuration\c"
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

echo -e "== Setting vm.max_map_count for ElasticSearch\c"
sysctl -w vm.max_map_count=262144 > /dev/null
checkStatus

echo -e "== Reloading some daemons\c"
systemctl daemon-reload
checkStatus

echo -e "== Enabling and starting ElasticSearch\c"
chkconfig elasticsearch on
checkStatus

echo -e "== Adding Zammad repository to the system\c"
wget -O /etc/zypp/repos.d/zammad.repo https://dl.packager.io/srv/zammad/zammad/stable/installer/sles/12.repo
checkStatus
echo -e "== Auto-accepting GPG keys\c"
zypper --gpg-auto-import-keys ref
checkStatus

echo -e "== Installing Zammad..."
zypper install -y zammad

echo -e "== Removing default nginx configuration (no SSL support)\c"
rm -f /etc/nginx/vhosts.d/zammad.conf
checkStatus

echo -e "== Fixing file permissions on Zammad's public directory\c"  # this was needed at least until version 3.4.x
find /opt/zammad/public -type f -exec chmod 644 {} \;             # remove these 2 lines if newer versions already fix the issue
checkStatus

echo -e "== Creating /etc/nginx/ssl directory\c"
mkdir /etc/nginx/ssl
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

# determine nginx's root directory - best effort
nginx_root=$(grep root /etc/nginx/nginx.conf | uniq  | grep -v \#  | awk '{ print $2; }' | awk -F\; '{ print $1 }')
if [ -z $nginx_root ]
then
  echo -e "\nERROR - cannot find nginx\'s root directory."
  echo -e "ERROR - is nginx installed?\n"
  exit 1
else
  echo -e "== nginx root directory seems to be: $nginx_root"
fi

echo -e "== Creating nginx configuration with SSL support\c"
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

" > /etc/nginx/vhosts.d/zammad_ssl.conf
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
zammad run rake zammad:searchindex:rebuild  > /dev/null

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