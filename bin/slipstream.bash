#!/usr/bin/env bash

# -- HELPER FUNCTIONS, PT. 1 --------------------------------------------------
DEBUG=NotEmpty
DEBUG=

# Echo to strerr
function errcho() {
  >&2 echo "$@"
}

# Die with message to stderr and exit code
function die() {
  errcho "$1"
  exit "$2"
}

# Quiet it all
function qt() {
  "$@" > /dev/null 2>&1
}

# Quiet only errors
function qte() {
  "$@" 2> /dev/null
}
# -- CHECKS RUNNING IN BASH ---------------------------------------------------
INVOKED_AS="$(basename "$BASH")"
if [[ -z "$INVOKED_AS" ]] || [[ "$INVOKED_AS" != 'bash' ]]; then
  die "Please invoke this script thusly: bash $0" 127
fi
# -- DON'T RUN AS SUDO --------------------------------------------------------
if [[ $UID -eq 0 ]]; then
  if [[ ! -z "$SUDO_USER" ]]; then
    cat <<EOT
It looks like you're running this script via sudo.
That's OK. I'll re-run it as: $SUDO_USER
EOT
    exec sudo -u "$SUDO_USER" bash -c "$0"
  else
    die "Yikes! Please don't run this as root!" 127
  fi
fi
# -- CHECK MAC AND YOSEMITE ---------------------------------------------------
if [[ $OSTYPE == darwin* ]]; then
  OSX_VERSION="$(sw_vers -productVersion)"
  [[ "$OSX_VERSION" == 10.10* ]] || [[ "$OSX_VERSION" == 10.11* ]]

  if [[ $? -ne 0 ]]; then
    cat <<EOT
Sorry! This script is currently only compatible with:
  Yosemite   (10.10*) or
  El Capitan (10.11*)
You're running:

$(sw_vers)

EOT
    exit 127
  fi
else
  die "Oops! This script was only meant for Mac OS X" 127
fi
# -- HELPER FUNCTIONS, PT. 2 --------------------------------------------------
# Parse out .data sections of this file
function get_pkgs() {
 sed -n "/Start: $1/,/End: $1/p" "$0"
}

MYPID="$$"

# Clean-up!
function clean_up() {
  errcho "Cleaning up! Bye!"
  # Kill all caffeinate processes that are children of this script
  pkill -P $MYPID caffeinate
}

trap clean_up EXIT INT QUIT KILL TERM
# -----------------------------------------------------------------------------
# Strip out comments, beginning and trailing whitespace, [ :].*$, an blank lines
function clean() {
  sed 's/#.*$//;s/^[[:blank:]][[:blank:]]*//g;s/[[:blank:]][[:blank:]]*$//;s/[ :].*$//;/^$/d' "$1" | sort -u
}

# Process install
function process() {
  local brew_php_linked debug extra line

  debug="$([[ ! -z "$DEBUG" ]] && echo echo)"

  # Compare what is already installed with what we want installed
  while read -r -u3 line && [[ ! -z "$line" ]]; do
    show_status "($1) $line"
    case "$1" in
      'brew tap')
        $debug brew tap $line;;
      'brew cask')
        $debug brew cask install $line;;
      'brew leaves')
        # Quick hack to allow for extra --args
        line="$(egrep "^$line[ ]*.*$" <(clean <(get_pkgs "$1")))"
        $debug brew install $line;;
      'brew php')
        line="$(egrep "^$line[ ]*.*$" <(clean <(get_pkgs "$1")))"
        brew_php_linked="$(cd /usr/local/Library/LinkedKegs && qte ls -d php[57][0-9])"
        if [[ ! -z "$brew_php_linked" ]]; then
          if [[ "$line" != "$brew_php_linked"* ]]; then
            brew unlink "$brew_php_linked"
            qte brew list "${line:0:5}" && brew link "${line:0:5}"
          fi
        fi
        $debug brew install $line;;
      npm)
        SUDO=
        $debug $SUDO npm install -g $line;;
      gem)
        SUDO=sudo
        if [[ "$(ls -ld "$(command -v gem)" | awk '{print $3}')" != 'root' ]]; then
          SUDO=
        fi

        # http://stackoverflow.com/questions/31972968/cant-install-gems-on-macos-x-el-capitan
        [[ "$OSX_VERSION" == 10.11* ]] && extra='-n /usr/local/bin'

        line="$(egrep "^$line[ ]*.*$" <(get_pkgs "$1"))"
        $debug $SUDO "$1" install -f $extra $line;;
      *)
        ;;
    esac
  done 3< <(get_diff "$@")

  qt hash
}

# Get list of installed packages
function get_installed() {
  case "$1" in
    'brew tap')
      brew tap | sort -u;;
    'brew cask')
      brew cask list | sort -u;;
    'brew leaves'|'brew php')
      brew list | sort -u;;
    npm)
      qte npm -g list | iconv -c -f utf-8 -t ascii | grep -v -e '^/' -e '^  ' | sed 's/@.*$//;/^$/d;s/ //g' | sort -u;;
    gem)
      $1 list | sed 's/ .*$//' | sort -u;;
    *)
      echo;;
  esac
}

# Get difference of these sets
function get_diff() {
  comm -13 <(get_installed "$1") <(clean <(get_pkgs "$1"))
}

# Colorized output status
function show_status() {
  echo "$(tput setaf 3)Working on: $(tput setaf 5)${@}$(tput sgr0)"
}

# Generate self-signed SSL
function genssl() {
  # http://www.jamescoyle.net/how-to/1073-bash-script-to-create-an-ssl-certificate-key-and-request-csr
  # http://www.freesoftwaremagazine.com/articles/generating_self_signed_test_certificates_using_one_single_shell_script
  # http://www.akadia.com/services/ssh_test_certificate.html
  local domain C ST L O OU CN emailAddress password

  domain=server
  # Change to your company details
  C=US;  ST=Oregon;  L=Portland; O=$domain; # Country, State, Locality, Organization
  OU=IT; CN=$domain; emailAddress="$USER@localhost"

  # Change to your company details (NOTE: CN should match Apache ServerName value
  C=US;  ST=Oregon;  L=Portland; O=$domain; # Country, State, Locality, Organization
  OU=IT; CN=127.0.0.1; emailAddress="$USER@localhost"
  # Common Name, Email Address, Organizational Unit

  #Optional
  password=dummypassword
  # Step 1: Generate a Private Key
  openssl genrsa -des3 -passout pass:$password -out "${domain}.key" 2048 -noout
  # Step 2: Generate a CSR (Certificate Signing Request)
  openssl req -new -key "${domain}.key" -out "${domain}.csr" -passin pass:"$password" \
    -subj "/C=$C/ST=$ST/L=$L/O=$O/OU=$OU/CN=$CN/emailAddress=$emailAddress"
  # Step 3: Remove Passphrase from Key. Comment the line out to keep the passphrase
  openssl rsa -in "${domain}.key" -passin pass:"$password" -out "${domain}.key"
  # Step 4: Generating a Self-Signed Certificate
  openssl x509 -req -days 3650 -in "${domain}.csr" -signkey "${domain}.key" -out "${domain}.crt"
}
# -- CHECK AND INSTALL XCODE CLI TOOLS ----------------------------------------
# .text
if ! qt xcode-select -p; then
  echo "You don't seem to have Xcode Command Line Tools installed"
  read -r -p "Hit [enter] to start its installation. Re-run this script when done: " dummy
  xcode-select --install
  exit
fi
# -- OVERVIEW OF CHANGES THAT WILL BE MADE ------------------------------------
cat <<EOT

OK. It looks like we're ready to go.
*****************************************************************
***** NOTE: This script assumes a "virgin" Yosemite state.  *****
***** If you've already made changes to files in /etc, then *****
***** all bets are off. You have been WARNED!               *****
*****************************************************************
If you wish to continue, then this is what I'll be doing:
  - Git-ifying your /etc folder
  - Allow for password-less sudo by altering /etc/sudoers
  - Install home brew, and some brew packages:
$(
  echo $(clean <(get_pkgs "brew cask")) \
       $(clean <(get_pkgs "brew php")) \
       $(clean <(get_pkgs "brew leaves")) \
    | fold -w $(($(tput cols) - 6)) -s \
    | sed 's/^/      /'
)
  - Update the System Ruby Gem, and install some gems:
$(
  echo $(clean <(get_pkgs "gem")) \
    | fold -w $(($(tput cols) - 6)) -s \
    | sed 's/^/      /'
)
  - Install some npm packages:
$(
  echo $(clean <(get_pkgs "npm")) \
    | fold -w $(($(tput cols) - 6)) -s \
    | sed 's/^/      /'
)
  -- Configure:
    - Postfix (Disable outgoing mail)
    - MariaDB (InnoDB tweaks, etc.)
    - Php.ini (Misc. configurations)
    - Apache2 (Enable modules, and add wildcard vhost conf)
    - Dnsmasq (Resolve *.dev domains w/OUT /etc/hosts editing)
EOT

read -r -p "Hit [enter] to start or control-c to quit: " dummy
# -- KEEP DISPLAY/SYSTEM FROM IDLING/SLEEPING ---------------------------------
# Generously setting for an hour, but clean_up() will kill it upon exit or
# interrupt
caffeinate -d -i -t 3600 &
# -- VERSION CONTROL /etc -----------------------------------------------------
# We should have git available now, after installing Xcode cli tools

# Slipstream Git commit message prefix
SGP='[Slipstream]'

sudo -H bash -c "
[[ -z '$(git config --get user.name)'  ]] && git config --global user.name 'System Administrator'
[[ -z '$(git config --get user.email)' ]] && git config --global user.email '$USER@localhost'"

if [[ ! -f /etc/.git/config ]]; then
  show_status "Git init-ing /etc [you may be prompted for sudo password]: "
  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git init ; git add . ; git commit -m '${SGP} Initial commit' "
fi

# -- PASSWORDLESS SUDO --------------------------------------------------------
if ! qt sudo grep '^%admin[[:space:]]*ALL=(ALL) NOPASSWD: ALL' /etc/sudoers; then
  show_status "Making sudo password-less for 'admin' group"
  sudo sed -i .bak 's/\(%admin[[:space:]]*ALL=(ALL)\) ALL/\1 NOPASSWD: ALL/' /etc/sudoers

  if qt /etc/sudoers /etc/sudoers.bak; then
    echo "No change made to: /etc/sudoers"
  else
    show_status 'Committing to git'
    sudo -H bash -c " cd /etc/ ; git add sudoers ; git commit -m '${SGP} Password-less sudo for \"admin\" group' "
  fi

  sudo rm -f /etc/sudoers.bak
fi
# -- HOMEBREW -----------------------------------------------------------------
echo "== Processing Homebrew =="

if ! qt command -v brew; then
  ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
  qt hash

  # TODO: test for errors
  brew doctor
fi

show_status "brew tap"
process "brew tap"

show_status "brew cask"
qt brew cask --version || brew install caskroom/cask/brew-cask
process "brew cask"

show_status "brew php"
process "brew php"

show_status "brew leaves"
process "brew leaves"
# -- UPDATE AND INSTALL GEMS --------------------------------------------------
echo "== Processing Gem =="
# sudo gem update --system
show_status "gem"
process "gem"
# -- INSTALL NPM PACKAGES -----------------------------------------------------
echo "== Processing Npm =="
show_status "npm"
process "npm"
# -- DISABLE OUTGOING MAIL ----------------------------------------------------
echo "== Processing Postfix =="

if ! qt grep '^virtual_alias_maps' /etc/postfix/main.cf; then
  show_status "Disabling outgoing mail"
  cat <<EOT | qt sudo tee -a /etc/postfix/main.cf

virtual_alias_maps = regexp:/etc/postfix/virtual
EOT
fi

if ! qt grep "$USER" /etc/postfix/virtual; then
  cat <<EOT | qt sudo tee -a /etc/postfix/virtual

/.*/ $USER@localhost
EOT
fi

qt pushd /etc/
if git status | qt egrep 'postfix/main.cf|postfix/virtual'; then
  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git add postfix/main.cf postfix/virtual ; git commit -m '${SGP} Disable outgoing mail (postfix tweaks)' "
fi
qt popd
# -- INSTALL MARIADB (MYSQL) --------------------------------------------------
echo "== Processing MariaDB =="

# brew info mariadb
[[ ! -d ~/Library/LaunchAgents ]] && mkdir -p  ~/Library/LaunchAgents
if qt ls /usr/local/opt/mariadb/*.plist && ! qt ls ~/Library/LaunchAgents/homebrew.mxcl.mariadb.plist; then
  show_status 'Linking MariaDB LaunchAgent plist'
  ln -sfv /usr/local/opt/mariadb/*.plist ~/Library/LaunchAgents/homebrew.mxcl.mariadb.plist
fi

[[ ! -d /etc/homebrew/etc/my.cnf.d ]] && sudo mkdir -p /etc/homebrew/etc/my.cnf.d
if [[ ! -f /etc/homebrew/etc/my.cnf.d/mysqld_innodb.cnf ]]; then
  show_status 'Creating: /etc/homebrew/etc/my.cnf.d/mysqld_innodb.cnf'
  cat <<EOT | qt sudo tee /etc/homebrew/etc/my.cnf.d/mysqld_innodb.cnf
[mysqld]
innodb_file_per_table = 1
socket = /tmp/mysql.sock

query_cache_type = 1
query_cache_size = 128M
query_cache_limit = 2M
max_allowed_packet = 64M

default_storage_engine = InnoDB
innodb_flush_method=O_DIRECT
innodb_buffer_pool_size = 512M
innodb_log_buffer_size = 16M
innodb_flush_log_at_trx_commit = 0
# Deprecated: innodb_locks_unsafe_for_binlog = 1
innodb_log_file_size = 256M

tmp_table_size = 32M
max_heap_table_size = 32M
thread_cache_size = 4
query_cache_limit = 2M
join_buffer_size = 8M
bind-address = 127.0.0.1
key_buffer_size = 256M
EOT

  show_status 'Linking to: /usr/local/etc/my.cnf.d/mysqld_innodb.cnf'
  ln -svf /etc/homebrew/etc/my.cnf.d/mysqld_innodb.cnf /usr/local/etc/my.cnf.d/mysqld_innodb.cnf
  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git add homebrew ; git commit -m '${SGP} Add homebrew/etc/my.cnf.d/mysqld_innodb.cnf' "
fi

# TOOO: ps aux | grep mariadb and prehaps use nc to test if port is open
# brew info mariadb
if ! qt launchctl list homebrew.mxcl.mariadb; then
  show_status 'Loading: ~/Library/LaunchAgents/homebrew.mxcl.mariadb.plist'
  launchctl load ~/Library/LaunchAgents/homebrew.mxcl.mariadb.plist

  show_status 'Setting mysql root password... waiting for mysqld to start'
  # Just sleep, waiting for mariadb to start
  sleep 7
  mysql -u root mysql <<< "UPDATE user SET password=PASSWORD('root') WHERE User='root'; FLUSH PRIVILEGES;"
fi
# -- SETUP SYSTEM PHP.INI -----------------------------------------------------
echo "== Processing system php.ini =="

# php (cp php.ini.default?)
if [[ ! -f /etc/php.ini ]]; then
  show_status 'Copying Default System Php.ini'
  sudo cp /etc/php.ini.default /etc/php.ini

  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git add php.ini ; git commit -m '${SGP} Add system /etc/php.ini as copy of the default' "

  show_status 'Updating some system PHP settings'
  sudo sed -i .bak '
    s|max_execution_time = 30|max_execution_time = 0|
    s|memory_limit = 128M|memory_limit = 256M|
    s|display_errors = Off|display_errors = On|
    s|display_startup_errors = Off|display_startup_errors = On|
    s|;error_log = php_errors.log|error_log = /var/log/apache2/php_errors.log|
    s|;date.timezone =|date.timezone = America/Los_Angeles|
    s|pdo_mysql.default_socket=|pdo_mysql.default_socket="/tmp/mysql.sock"|
    s|mysql.default_socket =|mysql.default_socket = "/tmp/mysql.sock"|
    s|mysqli.default_socket =|mysqli.default_socket = "/tmp/mysql.sock"|
  ' /etc/php.ini
  sudo rm /etc/php.ini.bak

  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git add php.ini ; git commit -m '${SGP} Update system php.ini' "
fi
# -- SETUP APACHE -------------------------------------------------------------
echo "== Processing Apache =="

# apache httpd.conf?
# diff -r apache2/httpd.conf /Users/jeebak/SlipStream/host/apache2/httpd.conf
show_status 'Updating httpd.conf settings'
for i in \
  'LoadModule socache_shmcb_module libexec/apache2/mod_socache_shmcb.so' \
  'LoadModule ssl_module libexec/apache2/mod_ssl.so' \
  'LoadModule cgi_module libexec/apache2/mod_cgi.so' \
  'LoadModule vhost_alias_module libexec/apache2/mod_vhost_alias.so' \
  'LoadModule actions_module libexec/apache2/mod_actions.so' \
  'LoadModule rewrite_module libexec/apache2/mod_rewrite.so' \
  'LoadModule php5_module libexec/apache2/libphp5.so' \
; do
  sudo sed -i .bak "s;#$i;$i;" /etc/apache2/httpd.conf
done

DEV_DIR="/Users/$USER/Sites"

[[ ! -d "$DEV_DIR" ]] && mkdir -p "$DEV_DIR"

if [[ ! -d "/etc/apache2/ssl" ]]; then
  mkdir -p "$$/ssl"
  qt pushd "$$/ssl"
  genssl
  qt popd
  sudo mv "$$/ssl" /etc/apache2
  sudo chown -R root:wheel /etc/apache2/ssl
  rmdir "$$"

  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git add apache2/ssl; git commit -m '${SGP} Add apache2/ssl files' "
fi

if [[ ! -f /etc/apache2/extra/dev.conf ]]; then
  cat <<EOT | qt sudo tee -a /etc/apache2/extra/dev.conf
<VirtualHost *:80>
  ServerAdmin $USER@localhost
  ServerAlias *.dev *.vmdev
  VirtualDocumentRoot $DEV_DIR/%-2/webroot

  UseCanonicalName Off

  LogFormat "%V %h %l %u %t \"%r\" %s %b" vcommon
  CustomLog "/var/log/apache2/access_log" vcommon
  ErrorLog "/var/log/apache2/error_log"

  <Directory "$DEV_DIR">
    AllowOverride All
    Options +Indexes +FollowSymLinks +ExecCGI
    Require all granted
    RewriteBase /
  </Directory>
</VirtualHost>

Listen 443
<VirtualHost *:443>
  ServerAdmin $USER@localhost
  ServerAlias *.dev *.vmdev
  VirtualDocumentRoot $DEV_DIR/%-2/webroot

  SSLEngine On
  SSLCertificateFile    /private/etc/apache2/ssl/server.crt
  SSLCertificateKeyFile /private/etc/apache2/ssl/server.key

  UseCanonicalName Off

  LogFormat "%V %h %l %u %t \"%r\" %s %b" vcommon
  CustomLog "/var/log/apache2/access_log" vcommon
  ErrorLog "/var/log/apache2/error_log"

  <Directory "$DEV_DIR">
    AllowOverride All
    Options +Indexes +FollowSymLinks +ExecCGI
    Require all granted
    RewriteBase /

  </Directory>
</VirtualHost>
EOT
  cat <<EOT | qt sudo tee -a /etc/apache2/httpd.conf

# Local vhost and ssl, for *.dev
Include /private/etc/apache2/extra/dev.conf
EOT

  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git add apache2/extra/dev.conf ; git commit -m '${SGP} Add apache2/extra/dev.conf' "
fi

# Have ServerName match CN in SSL Cert
sudo sed -i .bak 's/#ServerName www.example.com:80/ServerName 127.0.0.1/' /etc/apache2/httpd.conf
if qt diff /etc/apache2/httpd.conf /etc/apache2/httpd.conf.bak; then
  echo "No change made to: apache2/httpd.conf"
else
  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git add apache2/httpd.conf ; git commit -m '${SGP} Update apache2/httpd.conf' "
fi
sudo rm /etc/apache2/httpd.conf.bak

# https://clickontyler.com/support/a/38/how-start-apache-automatically/

if ! qt sudo launchctl list org.apache.httpd; then
  show_status 'Loading: /System/Library/LaunchDaemons/org.apache.httpd.plist'
  sudo launchctl load -w /System/Library/LaunchDaemons/org.apache.httpd.plist
fi
# -- WILDCARD DNS -------------------------------------------------------------
echo "== Processing Dnsmasq =="

# dnsmasq (add note to /etc/hosts)
#  add symlinks as non-root to /usr/local/etc files

if qt ls /usr/local/opt/dnsmasq/*.plist && ! qt ls /Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist; then
  show_status 'Linking Dnsmasq LaunchAgent plist'
  # brew info dnsmasq
  sudo cp -fv /usr/local/opt/dnsmasq/*.plist /Library/LaunchDaemons
  sudo chown root /Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist
fi

if [[ ! -f /etc/homebrew/etc/dnsmasq.conf ]]; then
  show_status 'Creating: /etc/homebrew/etc/dnsmasq.conf'
  cat <<EOT | qt sudo tee /etc/homebrew/etc/dnsmasq.conf
address=/.dev/127.0.0.1
EOT
  show_status 'Linking to: /usr/local/etc/dnsmasq.conf'
  ln -svf /etc/homebrew/etc/dnsmasq.conf /usr/local/etc/dnsmasq.conf
fi

[[ ! -d /etc/resolver ]] && sudo mkdir /etc/resolver
if [[ ! -f /etc/resolver/dev ]]; then
  cat <<EOT | qt sudo tee /etc/resolver/dev
nameserver 127.0.0.1
EOT
fi

# brew info dnsmasq
if ! qt sudo launchctl list homebrew.mxcl.dnsmasq; then
  show_status 'Loading: /Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist'
  sudo launchctl load /Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist
fi

qt pushd /etc/
if git status | qt egrep 'resolver/dev|homebrew/etc/dnsmasq.conf'; then
  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git add resolver/dev homebrew/etc/dnsmasq.conf ; git commit -m '${SGP} Add dnsmasq files' "
fi
qt popd

if ! qt grep -i dnsmasq /etc/hosts; then
  cat <<EOT | qt sudo tee -a /etc/hosts

# NOTE: dnsmasq is managing *.dev domains (foo.dev) so there's no need to add such here
# Use this hosts file for non-.dev domains like: foo.bar.com
EOT

  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git add hosts ; git commit -m '${SGP} Add dnsmasq note to hosts file' "
fi
# -- SETUP BREW PHP.INI -------------------------------------------------------
echo "== Processing Brew php.ini =="

for i in /usr/local/etc/php/*/php.ini; do
  version="$(basename "$(dirname "$i")")"

  if [[ ! -f "/etc/homebrew/etc/php/$version/php.ini" ]]; then
    show_status "Copying Default Brew PHP $version Php.ini"
    [[ ! -d "/etc/homebrew/etc/php/$version" ]] && sudo mkdir -p "/etc/homebrew/etc/php/$version"
    sudo cp "/usr/local/etc/php/$version/php.ini" "/etc/homebrew/etc/php/$version/php.ini"

    show_status 'Committing to git'
    sudo -H bash -c " cd /etc/ ; git add homebrew/etc/php/$version/php.ini ; git commit -m '${SGP} Add homebrew/etc/php/$version/php.ini as a copy of homebrew default' "

    show_status 'Updating some brew PHP settings'
    sudo sed -i .bak '
      s|max_execution_time = 30|max_execution_time = 0|
      s|memory_limit = 128M|memory_limit = 256M|
      s|display_errors = Off|display_errors = On|
      s|display_startup_errors = Off|display_startup_errors = On|
      s|;error_log = php_errors.log|error_log = /var/log/apache2/php_errors.log|
      s|;date.timezone =|date.timezone = America/Los_Angeles|
      s|pdo_mysql.default_socket=|pdo_mysql.default_socket="/tmp/mysql.sock"|
      s|mysql.default_socket =|mysql.default_socket = "/tmp/mysql.sock"|
      s|mysqli.default_socket =|mysqli.default_socket = "/tmp/mysql.sock"|
    ' "/etc/homebrew/etc/php/$version/php.ini"
    sudo rm "/etc/homebrew/etc/php/$version/php.ini.bak"

    show_status "Linking to: /etc/homebrew/etc/php/$version/php.ini"
    if [[ -f "/usr/local/etc/php/$version/php.ini" ]]; then
      mv /usr/local/etc/php/"$version"/php.ini{,.orig}
    fi
    ln -svf "/etc/homebrew/etc/php/$version/php.ini" "/usr/local/etc/php/$version/php.ini"

    show_status 'Committing to git'
    sudo -H bash -c " cd /etc/ ; git add homebrew/etc/php/$version/php.ini ; git commit -m '${SGP} Update homebrew/etc/php/$version/php.ini' "
  fi
done
# -- SETUP BREW PHP / XDEBUG---------------------------------------------------
echo "== Processing Brew PHP / Xdebug =="

[[ ! -d /etc/homebrew/etc/apache2 ]] && sudo mkdir -p /etc/homebrew/etc/apache2

if [[ ! -f /etc/homebrew/etc/apache2/php5.conf ]]; then
  show_status 'Updating httpd.conf settings, to use brew php'
  cat <<EOT | qt sudo tee /etc/homebrew/etc/apache2/php5.conf
LoadModule php5_module /usr/local/lib/libphp5.so
EOT
fi

if [[ ! -f /etc/homebrew/etc/apache2/php7.conf ]]; then
  cat <<EOT | qt sudo tee /etc/homebrew/etc/apache2/php7.conf
LoadModule php7_module /usr/local/lib/libphp7.so

<IfModule php7_module>
  AddType application/x-httpd-php .php
  AddType application/x-httpd-php-source .phps

  <IfModule dir_module>
    DirectoryIndex index.html index.php
  </IfModule>
</IfModule>

<FilesMatch \.php\$>
  SetHandler application/x-httpd-php
</FilesMatch>
EOT
fi

[[ ! -d /usr/local/var/run/apache2 ]] && mkdir -p /usr/local/var/run/apache2
if [[ -z "$(readlink /usr/local/var/run/apache2/php.conf)" ]]; then
  ln -svf /etc/homebrew/etc/apache2/php5.conf /usr/local/var/run/apache2/php.conf
fi

# Account for both newly and previously provisioned scenarios
sudo sed -i .bak "s;LoadModule php5_module libexec/apache2/libphp5.so;Include /usr/local/var/run/apache2/php.conf;" /etc/apache2/httpd.conf
sudo sed -i .bak "s;LoadModule php5_module /usr/local/opt/php56/libexec/apache2/libphp5.so;Include /usr/local/var/run/apache2/php.conf ;" /etc/apache2/httpd.conf
sudo rm /etc/apache2/httpd.conf.bak

qt pushd /etc/
if git status | qt egrep 'apache2/httpd.conf'; then
  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git add apache2/httpd.conf ; git commit -m '${SGP} Update apache2/httpd.conf to use brew php' "
fi
qt popd

for i in /usr/local/etc/php/*/conf.d/ext-xdebug.ini; do
  version="$(basename "$(dirname "$(dirname "$i")")")"
  ver="${version/./}"
  v="${ver:0:1}"

  LIBPHP="/usr/local/opt/php${ver}/libexec/apache2/libphp${v}.so"

  if [[ -f "$LIBPHP" ]]; then

    if [[ ! -f "/etc/homebrew/etc/php/$version/conf.d/ext-xdebug.ini" ]]; then
      show_status "Copying Default Brew PHP $version ext-xdebug.ini"
      [[ ! -d "/etc/homebrew/etc/php/$version/conf.d" ]] && sudo mkdir -p "/etc/homebrew/etc/php/$version/conf.d"
      sudo cp "/usr/local/etc/php/$version/conf.d/ext-xdebug.ini" "/etc/homebrew/etc/php/$version/conf.d/ext-xdebug.ini"

      show_status 'Committing to git'
      sudo -H bash -c " cd /etc/ ; git add homebrew/etc/php/$version/conf.d/ext-xdebug.ini ; git commit -m '${SGP} Add homebrew/etc/php/$version/conf.d/ext-xdebug.ini as a copy of homebrew default' "

      show_status "Updating: /etc/homebrew/etc/php/$version/conf.d/ext-xdebug.ini"
      cat <<EOT | qt sudo tee "/etc/homebrew/etc/php/$version/conf.d/ext-xdebug.ini"
[xdebug]
; The "real" path to the .so file would be:
;   zend_extension="/usr/local/Cellar/php${ver}-xdebug/*/xdebug.so"
; but Homebrew provides this convenient symlink:
 zend_extension="/usr/local/opt/php${ver}-xdebug/xdebug.so"

 xdebug.remote_enable=On
 xdebug.remote_host=127.0.0.1
 xdebug.remote_port=9000
 xdebug.remote_handler="dbgp"
 xdebug.remote_mode=req;

 xdebug.profiler_enable_trigger=1;
 xdebug.trace_enable_trigger=1;
 xdebug.trace_output_name = "trace.out.%t-%s.%u"
 xdebug.profiler_output_name = "cachegrind.out.%t-%s.%u"
EOT

      show_status "Linking to: /etc/homebrew/etc/php/$version/conf.d/ext-xdebug.ini"
      if [[ -f "/usr/local/etc/php/$version/conf.d/ext-xdebug.ini" ]]; then
        mv /usr/local/etc/php/"$version"/conf.d/ext-xdebug.ini{,.orig}
      fi
      ln -svf "/etc/homebrew/etc/php/$version/conf.d/ext-xdebug.ini" "/usr/local/etc/php/$version/conf.d/ext-xdebug.ini"

      show_status 'Committing to git'
      sudo -H bash -c " cd /etc/ ; git add homebrew ; git commit -m '${SGP} Update homebrew/etc/php/$version/conf.d/ext-xdebug.ini' "
    fi
  fi
done

# Make php56 the default
brew_php_linked="$(cd /usr/local/Library/LinkedKegs && qte ls -d php[57][0-9])"
# Only link if brew php is not linked. If it is, we assume it was intentionally done
if [[ -z "$brew_php_linked" ]]; then
  brew link --overwrite php56
fi

[[ ! -e /usr/local/lib/libphp5.so ]] \
  && ln -svf /usr/local/opt/php56/libexec/apache2/libphp5.so /usr/local/lib/libphp5.so

# Some "upgrades" from (Mountain Lion / Mavericks) Apache 2.2 to 2.4, seems to
# keep the 2.2 config files. The "LockFile" directive is an artifact of 2.2
#   http://apple.stackexchange.com/questions/211015/el-capitan-apache-error-message-ah00526
# This simple commenting out of the line seems to work just fine.
sudo sed -i .bak 's;^\(LockFile\);# \1;' /etc/apache2/extra/httpd-mpm.conf
sudo rm -f /etc/apache2/extra/httpd-mpm.conf.bak

qt pushd /etc/
if git status | qt grep 'apache2/extra/httpd-mpm.conf'; then
  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; git add apache2/extra/httpd-mpm.conf ; git commit -m '${SGP} Comment out LockFile in apache2/extra/httpd-mpm.conf' "
fi
qt popd

sudo apachectl -k restart
sleep 3
# -- SETUP ADMINER ------------------------------------------------------------
show_status 'Setting up adminer'
if [[ -d "$DEV_DIR/adminer/webroot" ]]; then
  cat <<EOT

It looks like you already have "$DEV_DIR/adminer/webroot" on your system. If
you'd like to use the brew maintained version of Adminer, you can overwrite
your current install of adminer with:

  ln -svf "/usr/local/share/adminer/index.php" "$DEV_DIR/adminer/webroot/index.php"

EOT
else
  mkdir -p "$DEV_DIR/adminer/webroot"
  ln -svf "/usr/local/share/adminer/index.php" "$DEV_DIR/adminer/webroot/index.php"
fi
# -- SHOW THE USER CONFIRMATION PAGE ------------------------------------------
if [[ ! -d "$DEV_DIR/slipstream/webroot" ]]; then
  mkdir -p "$DEV_DIR/slipstream/webroot"
fi

cat <<EOT > "$DEV_DIR/slipstream/webroot/index.php"
<div style="width: 600px; margin: auto;">
  <h4>If you're seeing this, then it's a good sign that everything's working</h4>
<?php
  if( ! empty(\$_SERVER['HTTPS']) && strtolower(\$_SERVER['HTTPS']) !== 'off') {
    \$prefix = 'non-';
    \$url = "http://{\$_SERVER['HTTP_HOST']}/";
  } else {
    \$prefix = '';
    \$url = "https://{\$_SERVER['HTTP_HOST']}/";
  }
  print '<p>[test ' . \$prefix . 'SSL: <a href="' . \$url . '">' . \$url . '</a>]</p>';
?>

<p>
  Your ~/Sites folder will now automatically serve websites from folders that
  contain a "webroot" folder/symlink, using the .dev TLD. This means that there
  is no need to edit the /etc/hosts file for *.dev domains. For example, if you:
</p>
<pre>
  cd ~/Sites
  git clone git@github.com:username/your-website.git
</pre>
</blockquote>
<p>
  the website will be served at: http://your-website.dev/ automatically.
</p>
<p>
  Because of the way the apache vhost file VirtualDocumentRoot is configured,
  git clones that contain a "." will fail.
</p>
<p>
  Note that the mysql (MariaDB) root password is: root. You can confirm it by running:
</p>
<pre>
  mysql -p -u root mysql
</pre>

<p>
  You can now access Adminer at: <a href="http://adminer.dev/">http://adminer.dev/</a>
  using the same mysql credentials.
  Optionally, you can download a
  <a href="https://www.adminer.org/#extras" target="_blank">custom theme</a> adminer.css
  to "$DEV_DIR/adminer/webroot/adminer.css"
</p>

<h4>These are the packages were installed</h4>
<p>
  <strong>Brew:</strong>
  $(clean <(get_pkgs "brew cask")) $(clean <(get_pkgs "brew php")) $(clean <(get_pkgs "brew leaves"))
</p>

<p>
  <strong>Gems:</strong>
  $(clean <(get_pkgs "gem"))
</p>

<p>
  <strong>NPM:</strong>
  $(clean <(get_pkgs "npm"))
</p>

<p> </p>
</div>

<?php
  phpinfo();
?>
EOT

open http://slipstream.dev/
# -----------------------------------------------------------------------------
# We're done! Now,...
# clean_up (called automatically, since we're trap-ing EXIT signal)

# This is necessary to allow for the .data section(s)
exit

# -- LIST OF PACKAGES TO INSTALL ----------------------------------------------
# .data
# -----------------------------------------------------------------------------
# Start: brew tap
homebrew/php
homebrew/services
# End: brew tap
# -----------------------------------------------------------------------------
# Start: brew cask
# Editors
sublime-text
# Misc
clipmenu
# gimp
google-chrome
google-hangouts
iterm2
# Apple Java
# http://apple.stackexchange.com/questions/153584/install-java-jre-6-next-to-jre-7-on-os-x-10-10-yosemite
# java
# http://msol.io/blog/tech/2014/03/10/work-more-efficiently-on-your-mac-for-developers/#tap-caps-lock-for-escape
p4merge
sequel-pro
slack
sourcetree
vagrant
vagrant-manager
virtualbox
vlc
# End: brew cask
# -----------------------------------------------------------------------------
# Start: brew php
# This is dumb. Drush has a dependency on brew php, and composer but won't
# install them automatically. This entire script depends on 'sort -u' to
# determine what needs to be installed... so, creating php.
php55
php55-mcrypt
php55-opcache
php55-xdebug
php56
php56-mcrypt
php56-opcache
php56-xdebug
php70
php70-mcrypt
php70-opcache
php70-xdebug
# End: brew php
# -----------------------------------------------------------------------------
# Start: brew leaves
# Development Envs
node
# Database
adminer
mariadb
# Network
dnsmasq
# Shell
bash-completion
bash-git-prompt
# Utilities
apachetop
boris
composer
coreutils
drupalconsole
drush
php-cs-fixer
pngcrush
psysh
symfony-installer
terminus
the_silver_searcher
wp-cli
# End: brew leaves
# -----------------------------------------------------------------------------
# Start: gem
bundler
compass
capistrano -v 2.15.5
# End: gem
# -----------------------------------------------------------------------------
# Start: npm
bower
csslint
fixmyjs
grunt-cli
js-beautify
jshint
yo
# End: npm
# -----------------------------------------------------------------------------
