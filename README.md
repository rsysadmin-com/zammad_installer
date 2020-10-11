# zammad_installer
This little script aims to simplify and to automate as much as possible the whole Zammad installation process as described here:
* https://docs.zammad.org/en/latest/install/centos.html
* https://docs.zammad.org/en/latest/install/ubuntu.html
* https://docs.zammad.org/en/latest/install/suse.html

Of course, there are a few Ansible playbooks that you may use as well. They did not work for me. I started as an old-school UNIX-SysAdmin and, even though I use all those Infrastructure as Code Tools [shameless self-promotion: I'm also a GCP Architect :-)], I still feel that a shell script is a good way to go.

Please download the right version for your operating system:
* CentOS 8      : zammad_installer.sh
* Ubuntu        : zammad_installer_ubuntu.sh
* OpenSUSE 42   : zammad_installer_suse.sh

These scripts have been proven to flawlessly work under CentOS 8, Ubuntu 18.10 and OpenSUSE 42.

## before you run this...
There are at least 2 things that you may need to keep in mind for a Production Enviroment, namely:

1. the DNS entries, currently set to Google's public DNS
```
dns1=8.8.8.8    # or use your own DNS
dns2=8.8.4.4
``` 
2. the path to your SSL certificates if you have your own
```
ssl_crt=/etc/nginx/ssl/${zammad_fqdn}.crt
ssl_key=/etc/nginx/ssl/${zammad_fqdn}.key
ssl_csr=/etc/nginx/ssl/${zammad_fqdn}.csr
``` 

In that case, it could be a good idea to either comment or delete this part of the script (taken from the CentOS version; other distributions will have an //echo -e// instead of //action//):
``` 
action "== Generating self-signed SSL certs..."
# generate key and csr 
openssl req -new -newkey rsa:4096 -nodes \
    -keyout $ssl_key -out $ssl_csr \
    -subj "/C=CH/ST=Denial/L=Zug/O=Dis/CN=server"

# generate elf signed passwordless certificate 
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=server" \
    -keyout $ssl_key -out $ssl_crt

``` 

## btw
Please make sure that your hostname is a FQDN and is added to your DNS or /etc/hosts file.
nginx will be configured for you using that FQDN.
Run:
``` 
echo $HOSTNAME
``` 
to get the your system's FQDN.
If you do not know what I am talking about, just run the script and hope for the best :-)

## usage
First off, you must be root to run this installer.

Using this installer is pretty straight-forward:
1. clone this repo
2. cd zammad_installer
3. chmod +x ./zammad_installer.sh (or ./zammad_installer_ubuntu.sh or ./zammad_installer_suse.sh)
4. ./zammad_installer.sh (or ./zammad_installer_ubuntu.sh)

And, please, be very patient... it will take some time to install everything for you.

How much will depend on your server specifications and your network speed...

## what if I need to modify something once the installation is finished?
Good question. To which I have to say:

WARNING - do NOT run this installer again - this could wreck your existing Zammad installation!

You will need to edit the files where the changes are needed. 

A typical case would be /etc/nginx/conf.d/zammad_ssl.conf because, say, you want to access your Zammad server using other CNAME. In that case, just append the new CNAME in the server_name variable (line numbers may differ):

```
 15 server {
 16   listen 80;
 17 
 18   server_name zammad.domain.tld otheralias.domain.tld;

```

and here:
```
 35 server {
 36   listen 443 ssl http2;
 37 
 38   server_name zammad.domain.tld otheralias.domain.tld;
 39 

```
In this case, do not forget to restart nginx.

## disclaimer
this script is provided on an "AS IS" basis. 
The author is not to be held responsible for any damage that it use or misuse may cause.
