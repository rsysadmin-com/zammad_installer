# zammad_installer
This little script aims to simplify and to automate as much as possible the whole Zammad installation process described here:
https://docs.zammad.org/en/latest/install/centos.html

Of course, there are a few Ansible playbooks that you may use as well. I started as an old-school UNIX-SysAdmin and, even though I use all those Infrastructure as Code Tools, I still feel that a script is a good way to go.

Please download the right version for your operating system:
* CentOS 8: zammad_installer.sh
* Ubuntu  : zammad_installer_ubuntu.sh

## usage
First off, you must be root to run this tool.

Using this installer is pretty straight-forward:
1. clone this repo
2. cd zammad_installer
3. chmod +x ./zammad_installer.sh (or ./zammad_installer_ubuntu.sh)
4. ./zammad_installer.sh (or ./zammad_installer_ubuntu.sh)

And, please, be patient... it will take some time to install everything for you.
How much will depend on your server specifications and your network speed...

## to-do
* Add support for installations on OpenSUSE
* Unify all installers in a single script

## disclaimer
this script is provided on an "AS IS" basis. The author is not to be held responsible for any damage that it use or misuse may cause.

