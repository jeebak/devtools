#!/usr/bin/env bash

# -- HELPER FUNCTIONS, PT. 1 --------------------------------------------------
DEBUG=NotEmpty
DEBUG=
NOW="$(date '+%Y-%m-%d_%H-%M-%S')"

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
# -- CHECK MAC AND VERSION ----------------------------------------------------
if [[ $OSTYPE == darwin* ]]; then
  OSX_VERSION="$(sw_vers -productVersion)"

  if [[ ! "$OSX_VERSION" =~ 10.1[0123] ]]; then
    cat <<EOT
Sorry! This script is currently only compatible with:
  Yosemite    (10.10*)
  El Capitan  (10.11*)
  Sierra      (10.12*)
  High Sierra (10.13*)
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

  exit
}

trap clean_up EXIT INT QUIT TERM
# -----------------------------------------------------------------------------
# Strip out comments, beginning and trailing whitespace, [ :].*$, and blank lines
function clean() {
  sed 's/#.*$//;s/^[[:blank:]][[:blank:]]*//g;s/[[:blank:]][[:blank:]]*$//;s/[ :].*$//;/^$/d' "$1" | sort -u
}

# Process install
function process() {
  local brew_php_linked debug extra line pecl_pkg num_ver

  debug="$([[ ! -z "$DEBUG" ]] && echo echo)"

  # Compare what is already installed with what we want installed
  while read -r -u3 -a line && [[ ! -z "$line" ]]; do
    show_status "($1) $line"
    case "$1" in
      'brew tap')
        $debug brew tap "${line[@]}";;
      'brew cask')
        $debug brew cask install "${line[@]}";;
      'brew leaves')
        # Quick hack to allow for extra --args
        line="$(grep -E "^$line[ ]*.*$" <(clean <(get_pkgs "$1")))"
        $debug brew install "${line[@]}";;
      'brew php')
        [[ -z "$BREW_PREFIX" ]] && die "Brew is either not yet installed, or \$BREW_PREFIX not yet set" 127

        brew_php_linked="$(qte cd "$BREW_PREFIX/var/homebrew/linked" && qte ls -d php php@[57].[0-9]*)"
        num_ver="$(grep -E -o '[0-9]+\.[0-9]+' <<< "$line" || brew info php | head -1 | grep -E -o '[0-9]+\.[0-9]+')"

        if [[ ! -z "$brew_php_linked" ]]; then
          if [[ "$line" != "$brew_php_linked" ]]; then
            brew unlink "$brew_php_linked"
          fi
        fi

        # Wipe the slate clean
        if [[ -f "$BREW_PREFIX/etc/php/$num_ver/php.ini" ]]; then
          show_status "Found old php.ini, backed up to: $BREW_PREFIX/etc/php/$num_ver/php.ini-$NOW"
          mv "$BREW_PREFIX/etc/php/$num_ver/php.ini"{,-"$NOW"}
        fi
        rm -rf "$BREW_PREFIX/share/${line/php/pear}"

        $debug brew install "${line[@]}"
        $debug brew link --overwrite --force "$line"

        show_status "Installing PECLs for: $line"

        $debug "$BREW_PREFIX/opt/$line/bin/pecl" channel-update pecl.php.net

        # This inner loop to install pecl packages for specific php versions'
        # only run when the brew install for the specific version's run, i.e.,
        # pecl installation's not separate/standalone, currently.
        while read -r -u4 pecl_pkg; do
          if pecl_pkg="$(sed 's/#.*$//' <<< "$pecl_pkg")" && [[ ! -z "$pecl_pkg" ]]; then
            # We're not checking to see if it's already installed

            # This entire block is to accommodate php@5.6 :/
            if [[ "$line" =~ @ ]] && [[ "$pecl_pkg" =~ $line ]]; then
              # TODO: refine this for multiple versions
              pecl_pkg="$(sed "s/:$line//" <<< "$pecl_pkg")"
              show_status "PECL: Installing: $pecl_pkg"
              "$BREW_PREFIX/opt/$line/bin/pecl" install "$pecl_pkg" <<< '' > /dev/null
            else
              pecl_pkg="$(sed 's/:.*$//' <<< "$pecl_pkg")"
              show_status "PECL: Installing: $pecl_pkg"
              env MACOSX_DEPLOYMENT_TARGET="$(sw_vers -productVersion | grep -E -o '^[0-9]+\.[0-9]+')" \
                  CFLAGS='-fgnu89-inline' \
                  LDFLAGS='-fgnu89-inline' \
                  CXXFLAGS='-fgnu89-inline' \
                "$BREW_PREFIX/opt/$line/bin/pecl" install "$pecl_pkg" <<< '' > /dev/null
            fi
          fi
        done 4< <(get_pkgs "pecl")
        ;;
      npm)
        SUDO=
        $debug $SUDO npm install -g "${line[@]}";;
      gem)
        SUDO=sudo
        # shellcheck disable=SC2012
        if [[ "$(ls -ld "$(command -v gem)" | awk '{print $3}')" != 'root' ]]; then
          SUDO=
        fi

        # http://stackoverflow.com/questions/31972968/cant-install-gems-on-macos-x-el-capitan
        if qt command -v csrutil && csrutil status | qt grep enabled; then
          extra=(-n $BREW_PREFIX/bin)
        fi

        line="$(grep -E "^$line[ ]*.*$" <(get_pkgs "$1"))"
        $debug $SUDO "$1" install -f "${extra[@]}" "${line[@]}";;
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
  echo "$(tput setaf 3)Working on: $(tput setaf 5)${*}$(tput sgr0)"
}

# Git commit /etc changes via sudo
function etc_git_commit() {
  local msg

  msg="$2"
  show_status 'Committing to git'
  sudo -H bash -c " cd /etc/ ; $1 ; git commit -m '[Slipstream] $msg' "
}

# Generate self-signed SSL
function genssl() {
  # http://www.jamescoyle.net/how-to/1073-bash-script-to-create-an-ssl-certificate-key-and-request-csr
  # http://www.freesoftwaremagazine.com/articles/generating_self_signed_test_certificates_using_one_single_shell_script
  # http://www.akadia.com/services/ssh_test_certificate.html
  local domain C ST L O OU CN emailAddress password

  domain=server

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
  # shellcheck disable=SC2034
  read -r -p "Hit [enter] to start its installation. Re-run this script when done: " dummy
  xcode-select --install
  exit
fi
# -- OVERVIEW OF CHANGES THAT WILL BE MADE ------------------------------------
cat <<EOT

OK. It looks like we're ready to go.
*******************************************************************************
***** NOTE: This script assumes a "pristine" installation of Yosemite,    *****
***** El Capitan, or Sierra. If you've already made changes to files in   *****
***** /etc, then all bets are off. You have been WARNED!                  *****
*******************************************************************************
If you wish to continue, then this is what I'll be doing:
  - Git-ifying your /etc folder
  - Allow for password-less sudo by altering /etc/sudoers
  - Install home brew, and some brew packages
  - Update the System Ruby Gem, and install some gems
  - Install some npm packages
  -- Configure:
    - Postfix (Disable outgoing mail)
    - MariaDB (InnoDB tweaks, etc.)
    - Php.ini (Misc. configurations)
    - Apache2 (Enable modules, and add wildcard vhost conf)
      [including ServerAlias for *.localhost.metaltoad-sites.com, and *.xip.io]
    - Dnsmasq (Resolve *.localhost domains w/OUT /etc/hosts editing)
EOT

# shellcheck disable=SC2034
read -r -p "Hit [enter] to start or control-c to quit: " dummy
# -- KEEP DISPLAY/SYSTEM FROM IDLING/SLEEPING ---------------------------------
# Generously setting for an hour, but clean_up() will kill it upon exit or
# interrupt
caffeinate -d -i -t 3600 &
# -- VERSION CONTROL /etc -----------------------------------------------------
# We should have git available now, after installing Xcode cli tools

if [[ ! -f /etc/.git/config ]]; then
  show_status "Git init-ing /etc [you may be prompted for sudo password]: "
  sudo -H bash -c "
[[ -z '$(git config --get user.name)'  ]] && git config --global user.name 'System Administrator'
[[ -z '$(git config --get user.email)' ]] && git config --global user.email '$USER@localhost'"

  etc_git_commit "git init"
  etc_git_commit "git add ." "Initial commit"
fi
# -- PASSWORDLESS SUDO --------------------------------------------------------
if ! qt sudo grep '^%admin[[:space:]]*ALL=(ALL) NOPASSWD: ALL' /etc/sudoers; then
  show_status "Making sudo password-less for 'admin' group"
  sudo sed -i .bak 's/\(%admin[[:space:]]*ALL[[:space:]]*=[[:space:]]*(ALL)\)[[:space:]]*ALL/\1 NOPASSWD: ALL/' /etc/sudoers

  if qt diff /etc/sudoers /etc/sudoers.bak; then
    echo "No change made to: /etc/sudoers"
  else
    etc_git_commit "git add sudoers" 'Password-less sudo for "admin" group'
  fi

  sudo rm -f /etc/sudoers.bak
fi
# -- HOMEBREW -----------------------------------------------------------------
echo "== Processing Homebrew =="

if ! qt command -v brew; then
  /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
  qt hash

  # TODO: test for errors
  brew doctor
else
  # There was a major(?) architecture change to homebrew around 2015-12(?)
  if ! brew --version | qt grep "Homebrew [>]*[^0]"; then
    die "Hmm... Old version of brew detected. You may want to run: brew update; brew upgrade; and re-run this script when done" 127
  fi

  BREW_PREFIX="$(brew --prefix)"
  export BREW_PREFIX

  # https://brew.sh/2018/01/19/homebrew-1.5.0/
  currentBrewVersion="$(brew --version | grep -E -o '[0-9]+\.[0-9]+')"

  if [[ "$(echo -e "$currentBrewVersion\\n1.4" | sort -t '.' -k 1,1 -k 2,2 -g | tail -1)" = '1.4' ]]; then
    errcho "In brew version 1.5 (http://bit.ly/2q9wcoI / http://bit.ly/2qcXiem) the php tap has been archived."
    die "This script will no longer support the older version" 127
  else
    if brew list | grep -E -e '^php[57]' > /dev/null; then
      show_status "Found old packages from the homebrew/php tap. Deleting"
      brew list | grep -E -e '^php[57]' | xargs brew rm --force --ignore-dependencies
      # TODO: during a test run, 'brew rm php56' failed, due to
      # $BREW_PREFIX/Cellar/php@5.6/5.6.35/var being owned by root. It seems
      # isolated to one laptop, since the ownership was correct on another
      # laptop.
    fi

    if brew tap  | grep -E homebrew/php  > /dev/null; then
      show_status "Found old homebrew/php tap. Deleting"
      brew untap homebrew/php
    fi
    [[ -d "$BREW_PREFIX/etc/php" ]] && find "$BREW_PREFIX/etc/php" -name ext-mcrypt.ini -delete
  fi
fi

BREW_PREFIX="$(brew --prefix)"
export BREW_PREFIX

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
if git status | qt grep -E 'postfix/main.cf|postfix/virtual'; then
  etc_git_commit "git add postfix/main.cf postfix/virtual" "Disable outgoing mail (postfix tweaks)"
fi
qt popd
# -- INSTALL MARIADB (MYSQL) --------------------------------------------------
echo "== Processing MariaDB =="

# brew info mariadb
[[ ! -d ~/Library/LaunchAgents ]] && mkdir -p  ~/Library/LaunchAgents
if qt ls "$BREW_PREFIX/opt/mariadb/"*.plist && ! qt ls ~/Library/LaunchAgents/homebrew.mxcl.mariadb.plist; then
  show_status 'Linking MariaDB LaunchAgent plist'
  ln -sfv "$BREW_PREFIX/opt/mariadb/"*.plist ~/Library/LaunchAgents/homebrew.mxcl.mariadb.plist
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

  show_status "Linking to: $BREW_PREFIX/etc/my.cnf.d/mysqld_innodb.cnf"
  ln -svf /etc/homebrew/etc/my.cnf.d/mysqld_innodb.cnf "$BREW_PREFIX/etc/my.cnf.d/mysqld_innodb.cnf"
  etc_git_commit "git add homebrew" "Add homebrew/etc/my.cnf.d/mysqld_innodb.cnf"
fi

# TOOO: ps aux | grep mariadb and prehaps use nc to test if port is open
# brew info mariadb
if ! qt launchctl list homebrew.mxcl.mariadb; then
  show_status 'Loading: ~/Library/LaunchAgents/homebrew.mxcl.mariadb.plist'
  launchctl load ~/Library/LaunchAgents/homebrew.mxcl.mariadb.plist

  show_status 'Setting mysql root password... waiting for mysqld to start'
  # Just sleep, waiting for mariadb to start
  sleep 7
  mysql -u root mysql <<< "SET SQL_SAFE_UPDATES = 0; UPDATE user SET password=PASSWORD('root') WHERE User='root'; FLUSH PRIVILEGES; SET SQL_SAFE_UPDATES = 1;"
fi
# -- SETUP APACHE -------------------------------------------------------------
echo "== Processing Apache =="

HTTPD_CONF="/etc/apache2/httpd.conf"

show_status 'Updating httpd.conf settings'
for i in \
  'LoadModule socache_shmcb_module ' \
  'LoadModule ssl_module ' \
  'LoadModule cgi_module ' \
  'LoadModule vhost_alias_module ' \
  'LoadModule actions_module ' \
  'LoadModule rewrite_module ' \
  'LoadModule proxy_fcgi_module ' \
  'LoadModule proxy_module ' \
; do
  sudo sed -i .bak "s;#.*${i}\\(.*\\);${i}\\1;" "$HTTPD_CONF"
done

sudo sed -i .bak "s;^Listen 80.*$;Listen 80;"     "$HTTPD_CONF"
sudo sed -i .bak "s;^User .*$;User $USER;"        "$HTTPD_CONF"
sudo sed -i .bak "s;^Group .*$;Group $(id -gn);"  "$HTTPD_CONF"

DEST_DIR="/Users/$USER/Sites"

[[ ! -d "$DEST_DIR" ]] && mkdir -p "$DEST_DIR"

if [[ ! -d "/etc/apache2/ssl" ]]; then
  mkdir -p "$$/ssl"
  qt pushd "$$/ssl"
  genssl
  qt popd
  sudo mv "$$/ssl" /etc/apache2
  sudo chown -R root:wheel /etc/apache2/ssl
  rmdir "$$"

  etc_git_commit "git add apache2/ssl" "Add apache2/ssl files"
fi

# Set a default value, if not set as an env
PHP_FPM_PORT="${PHP_FPM_PORT:-9009}"

# We'd use these if we want to use localhost:some_port, but the default port is 9000
PHP_FPM_LISTEN="localhost:${PHP_FPM_PORT}"
PHP_FPM_HANDLER="fcgi://${PHP_FPM_LISTEN}"
PHP_FPM_PROXY="fcgi://${PHP_FPM_LISTEN}"

# Since port 9000 is also the default port for xdebug, so lets use...
PHP_FPM_LISTEN="$BREW_PREFIX/var/run/php-fpm.sock"
PHP_FPM_HANDLER="proxy:unix:$PHP_FPM_LISTEN|fcgi://localhost/"
PHP_FPM_PROXY="fcgi://localhost/"

[[ ! -d "$BREW_PREFIX/var/run" ]] && mkdir -p "$BREW_PREFIX/var/run"

if [[ -f /etc/apache2/extra/dev.conf ]]; then
  etc_git_commit "git rm apache2/extra/dev.conf" "Remove apache2/extra/dev.conf"
fi

if qt grep '^# Local vhost and ssl, for \*.dev$'                          "$HTTPD_CONF"; then
  sudo sed -i .bak '/^# Local vhost and ssl, for \*.dev$/d'               "$HTTPD_CONF"
  sudo sed -i .bak '/Include \/private\/etc\/apache2\/extra\/dev.conf/d'  "$HTTPD_CONF"
  sudo rm "${HTTPD_CONF}.bak"

  etc_git_commit "git add $HTTPD_CONF" "Remove references to .dev from $HTTPD_CONF"
fi

if [[ ! -f /etc/apache2/extra/localhost.conf ]] || ! qt grep "$PHP_FPM_HANDLER" /etc/apache2/extra/localhost.conf || ! qt grep \\.localhost\\.metaltoad-sites\\.com /etc/apache2/extra/localhost.conf || ! qt grep \\.xip\\.io /etc/apache2/extra/localhost.conf; then
  cat <<EOT | qt sudo tee /etc/apache2/extra/localhost.conf
<VirtualHost *:80>
  ServerAdmin $USER@localhost
  ServerAlias *.localhost *.vmlocalhost *.localhost.metaltoad-sites.com *.xip.io
  VirtualDocumentRoot $DEST_DIR/%1/webroot

  UseCanonicalName Off

  LogFormat "%V %h %l %u %t \"%r\" %s %b" vcommon
  CustomLog "/var/log/apache2/access_log" vcommon
  ErrorLog "/var/log/apache2/error_log"

  # With the switch to php-fpm, the apache2/other/php5.conf is not "Include"-ed, so need to...
  AddType application/x-httpd-php .php
  AddType application/x-httpd-php-source .phps

  <IfModule dir_module>
    DirectoryIndex index.html index.php
  </IfModule>

  # Depends on: LoadModule proxy_fcgi_module libexec/apache2/mod_proxy_fcgi.so in $HTTPD_CONF
  #   http://serverfault.com/a/672969
  #   https://httpd.apache.org/docs/2.4/mod/mod_proxy_fcgi.html
  # This is to forward all PHP to php-fpm.
  <FilesMatch \\.php$>
    SetHandler "${PHP_FPM_HANDLER}"
  </FilesMatch>

  <Proxy ${PHP_FPM_PROXY}>
    ProxySet connectiontimeout=5 timeout=1800
  </Proxy>

  <Directory "$DEST_DIR">
    AllowOverride All
    Options +Indexes +FollowSymLinks +ExecCGI
    Require all granted
    RewriteBase /
  </Directory>
</VirtualHost>

Listen 443
<VirtualHost *:443>
  ServerAdmin $USER@localhost
  ServerAlias *.localhost *.vmlocalhost *.localhost.metaltoad-sites.com
  VirtualDocumentRoot $DEST_DIR/%1/webroot

  SSLEngine On
  SSLCertificateFile    /private/etc/apache2/ssl/server.crt
  SSLCertificateKeyFile /private/etc/apache2/ssl/server.key

  UseCanonicalName Off

  LogFormat "%V %h %l %u %t \"%r\" %s %b" vcommon
  CustomLog "/var/log/apache2/access_log" vcommon
  ErrorLog "/var/log/apache2/error_log"

  # With the switch to php-fpm, the apache2/other/php5.conf is not "Include"-ed, so need to...
  AddType application/x-httpd-php .php
  AddType application/x-httpd-php-source .phps

  <IfModule dir_module>
    DirectoryIndex index.html index.php
  </IfModule>

  # Depends on: LoadModule proxy_fcgi_module libexec/apache2/mod_proxy_fcgi.so in $HTTPD_CONF
  #   http://serverfault.com/a/672969
  #   https://httpd.apache.org/docs/2.4/mod/mod_proxy_fcgi.html
  # This is to forward all PHP to php-fpm.
  <FilesMatch \\.php$>
    SetHandler "${PHP_FPM_HANDLER}"
  </FilesMatch>

  <Proxy ${PHP_FPM_PROXY}>
    ProxySet connectiontimeout=5 timeout=240
  </Proxy>

  <Directory "$DEST_DIR">
    AllowOverride All
    Options +Indexes +FollowSymLinks +ExecCGI
    Require all granted
    RewriteBase /
  </Directory>
</VirtualHost>
EOT

  if ! qt grep '^# Local vhost and ssl, for \*.localhost$' "$HTTPD_CONF"; then
    cat <<EOT | qt sudo tee -a "$HTTPD_CONF"

# Local vhost and ssl, for *.localhost
Include /private/etc/apache2/extra/localhost.conf
EOT
  fi

  etc_git_commit "git add apache2/extra/localhost.conf" "Add apache2/extra/localhost.conf"
else
  if qt grep ' ProxySet connectiontimeout=5 timeout=240$' /etc/apache2/extra/localhost.conf; then
    sudo sed -i .bak 's/ ProxySet connectiontimeout=5 timeout=240/ ProxySet connectiontimeout=5 timeout=1800/' /etc/apache2/extra/localhost.conf
    sudo rm /etc/apache2/extra/localhost.conf.bak

    etc_git_commit "git add apache2/extra/localhost.conf" "Update apache2/extra/localhost.conf ProxySet timeout value to 1800"
  fi
fi

if ! qt grep '^# To avoid: Gateway Timeout, during xdebug session (analogous changes made to the php.ini files)$' "$HTTPD_CONF"; then
  cat <<EOT | qt sudo tee -a "$HTTPD_CONF"

# To avoid: Gateway Timeout, during xdebug session (analogous changes made to the php.ini files)
Timeout 1800
EOT
fi

# Have ServerName match CN in SSL Cert
sudo sed -i .bak 's/#ServerName www.example.com:80/ServerName 127.0.0.1/' "$HTTPD_CONF"
if qt diff "$HTTPD_CONF" "${HTTPD_CONF}.bak"; then
  echo "No change made to: apache2/httpd.conf"
else
  etc_git_commit "git add apache2/httpd.conf" "Update apache2/httpd.conf"
fi
sudo rm "${HTTPD_CONF}.bak"

# https://clickontyler.com/support/a/38/how-start-apache-automatically/

if ! qt sudo launchctl list org.apache.httpd; then
  show_status 'Loading: /System/Library/LaunchDaemons/org.apache.httpd.plist'
  sudo launchctl load -w /System/Library/LaunchDaemons/org.apache.httpd.plist
fi
# -- WILDCARD DNS -------------------------------------------------------------
echo "== Processing Dnsmasq =="

# dnsmasq (add note to /etc/hosts)
#  add symlinks as non-root to $BREW_PREFIX/etc files

if qt ls "$BREW_PREFIX/opt/dnsmasq/"*.plist && ! qt ls /Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist; then
  show_status 'Linking Dnsmasq LaunchAgent plist'
  # brew info dnsmasq
  sudo cp -fv "$BREW_PREFIX/opt/dnsmasq/"*.plist /Library/LaunchDaemons
  sudo chown root /Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist
fi

if [[ ! -f /etc/homebrew/etc/dnsmasq.conf ]] || qt grep '^address=/.dev/127.0.0.1$' /etc/homebrew/etc/dnsmasq.conf; then
  show_status 'Creating: /etc/homebrew/etc/dnsmasq.conf'
  cat <<EOT | qt sudo tee /etc/homebrew/etc/dnsmasq.conf
address=/.localhost/127.0.0.1
EOT
  show_status "Linking to: $BREW_PREFIX/etc/dnsmasq.conf"
  ln -svf /etc/homebrew/etc/dnsmasq.conf "$BREW_PREFIX/etc/dnsmasq.conf"
fi

[[ ! -d /etc/resolver ]] && sudo mkdir /etc/resolver
if [[ ! -f /etc/resolver/localhost ]]; then
  cat <<EOT | qt sudo tee /etc/resolver/localhost
nameserver 127.0.0.1
EOT
fi

# brew info dnsmasq
if ! qt sudo launchctl list homebrew.mxcl.dnsmasq; then
  show_status 'Loading: /Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist'
  sudo launchctl load /Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist
fi

qt pushd /etc/
if git status | qt grep -E 'resolver/localhost|homebrew/etc/dnsmasq.conf'; then
  etc_git_commit "git add resolver/localhost homebrew/etc/dnsmasq.conf" "Add dnsmasq files"
fi
qt popd

if [[ -f /etc/resolver/dev ]]; then
  etc_git_commit "git rm resolver/dev" "Remove /etc/resolver/dev"
fi

if ! qt grep -i dnsmasq /etc/hosts; then
  cat <<EOT | qt sudo tee -a /etc/hosts

# NOTE: dnsmasq is managing *.localhost domains (foo.localhost) so there's no need to add such here
# Use this hosts file for non-.localhost domains like: foo.bar.com
EOT

  etc_git_commit "git add hosts" "Add dnsmasq note to hosts file"
fi
# -- SETUP BREW PHP / PHP.INI / XDEBUG ----------------------------------------
echo "== Processing Brew PHP / php.ini / Xdebug =="

[[ ! -d ~/Library/LaunchAgents ]] && mkdir -p  ~/Library/LaunchAgents

for i in "$BREW_PREFIX/etc/php/"*/php.ini; do
  dir_path="${i%/*}"
  version="$(grep -E -o '[0-9]+\.[0-9]+' <<< "$i")"

  # Process php.ini for $version
  show_status "Updating some $i settings"
  sed -i .bak '
    s|max_execution_time = 30|max_execution_time = 0|
    s|max_input_time = 60|max_input_time = 1800|
    s|; *max_input_vars = 1000|max_input_vars = 10000|
    s|memory_limit = 128M|memory_limit = 256M|
    s|display_errors = Off|display_errors = On|
    s|display_startup_errors = Off|display_startup_errors = On|
    s|;error_log = php_errors.log|error_log = /var/log/apache2/php_errors.log|
    s|;date.timezone =|date.timezone = America/Los_Angeles|
    s|pdo_mysql.default_socket=.*|pdo_mysql.default_socket="/tmp/mysql.sock"|
    s|mysql.default_socket =.*|mysql.default_socket = "/tmp/mysql.sock"|
    s|mysqli.default_socket =.*|mysqli.default_socket = "/tmp/mysql.sock"|
    s|upload_max_filesize = 2M|upload_max_filesize = 100M|
  ' "$i"
  mv "${i}.bak" "${i}.${NOW}-post-process"
  show_status "Original saved to: ${i}.${NOW}-post-process"

  # Process ext-xdebug.ini
  if [[ -f "$dir_path/conf.d/ext-xdebug.ini" ]]; then
    show_status "Found old ext-xdebug.ini, backed up to: $dir_path/conf.d/ext-xdebug.ini"
    mv "$dir_path/conf.d/ext-xdebug.ini"{,-"$NOW"}
  fi
  show_status "Updating: $dir_path/conf.d/ext-xdebug.ini"
  cat <<EOT > "$dir_path/conf.d/ext-xdebug.ini"
[xdebug]
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

  # Process php-fpm.conf for $version
  #   This is the path for 7.x, and we need to check for it 1st, because it's easier this way
  if [[ -f "$BREW_PREFIX/etc/php/$version/php-fpm.d/www.conf" ]]; then
    php_fpm_conf="$BREW_PREFIX/etc/php/$version/php-fpm.d/www.conf"
  elif [[ -f "$BREW_PREFIX/etc/php/$version/php-fpm.conf" ]]; then
    php_fpm_conf="$BREW_PREFIX/etc/php/$version/php-fpm.conf"
  else
    php_fpm_conf=""
  fi

  if [[ ! -z "$php_fpm_conf" ]] && ! qt grep -E "^listen[[:space:]]*=[[:space:]]*$PHP_FPM_LISTEN" "$php_fpm_conf"; then
    show_status "Updating $php_fpm_conf"
    sed -i .bak "
      s|^listen[[:space:]]*=[[:space:]]*.*|listen = $PHP_FPM_LISTEN|
      s|[;]*listen.mode[[:space:]]*=[[:space:]]*.*|listen.mode = 0666|
    " "$php_fpm_conf"
    mv "${php_fpm_conf}.bak" "${php_fpm_conf}-${NOW}"
    show_status "Original saved to: ${php_fpm_conf}-${NOW}"
  fi
done

if [[ -d /etc/homebrew/etc/apache2 ]]; then
  show_status 'Deleting homebrew/etc/apache2 for switch to php-fpm'
  sudo rm -rf /etc/homebrew/etc/apache2
  etc_git_commit "git rm -r homebrew/etc/apache2" "Deleting homebrew/etc/apache2 for switch to php-fpm"
fi

if [[ -d "$BREW_PREFIX/var/run/apache2" ]]; then
  rm -rf "$BREW_PREFIX/var/run/apache2"
fi

# Account for both newly and previously provisioned scenarios
sudo sed -i .bak "s;^\\(LoadModule[[:space:]]*php5_module[[:space:]]*libexec/apache2/libphp5.so\\);# \\1;"                        "$HTTPD_CONF"
sudo sed -i .bak "s;^\\(LoadModule[[:space:]]*php5_module[[:space:]]*$BREW_PREFIX/opt/php56/libexec/apache2/libphp5.so\\);# \\1;" "$HTTPD_CONF"
sudo sed -i .bak "s;^\\(Include[[:space:]]\"*$BREW_PREFIX/var/run/apache2/php.conf\\);# \\1;"                                     "$HTTPD_CONF"
sudo rm "${HTTPD_CONF}.bak"

qt pushd /etc/
if git status | qt grep -E 'apache2/httpd.conf'; then
  etc_git_commit "git add apache2/httpd.conf" "Update apache2/httpd.conf to use brew php-fpm"
fi
qt popd

while read -r -u3 service && [[ ! -z "$service" ]]; do
  qte brew services stop "$service"
done 3< <(brew services list | grep -E -e '^php ' -e '^php@[57]' | grep ' started ' | cut -f1 -d' ')

# Make php@5.6 the default
[[ ! -d "$BREW_PREFIX/var/log/" ]] && mkdir -p "$BREW_PREFIX/var/log/"
brew services start php@5.6

brew_php_linked="$(qte cd "$BREW_PREFIX/var/homebrew/linked" && qte ls -d php php@[57].[0-9]*)"
# Only link if brew php is not linked. If it is, we assume it was intentionally done
if [[ -z "$brew_php_linked" ]]; then
  brew link --overwrite --force php@5.6
fi

# Some "upgrades" from (Mountain Lion / Mavericks) Apache 2.2 to 2.4, seems to
# keep the 2.2 config files. The "LockFile" directive is an artifact of 2.2
#   http://apple.stackexchange.com/questions/211015/el-capitan-apache-error-message-ah00526
# This simple commenting out of the line seems to work just fine.
sudo sed -i .bak 's;^\(LockFile\);# \1;' /etc/apache2/extra/httpd-mpm.conf
sudo rm -f /etc/apache2/extra/httpd-mpm.conf.bak

qt pushd /etc/
if git status | qt grep 'apache2/extra/httpd-mpm.conf'; then
  etc_git_commit "git add apache2/extra/httpd-mpm.conf" "Comment out LockFile in apache2/extra/httpd-mpm.conf"
fi
qt popd

sudo apachectl -k restart
sleep 3
# -- SETUP ADMINER ------------------------------------------------------------
show_status 'Setting up adminer'
[[ -d   "$DEST_DIR/adminer/webroot" ]] && mkdir -p  "$DEST_DIR/adminer/webroot"
[[ ! -w "$DEST_DIR/adminer/webroot" ]] && chmod u+w "$DEST_DIR/adminer/webroot"
latest="$(curl -IkLs https://github.com/vrana/adminer/releases/latest | col -b | grep Location | grep -E -o '[^/]+$')"

if [[ -e "$DEST_DIR/adminer/webroot/index.php" ]]; then
  if [[ "$(grep '\* @version' "$DEST_DIR/adminer/webroot/index.php" | grep -E -o '[0-9]+.*')" != "${latest/v/}" ]]; then
    rm -f  "$DEST_DIR/adminer/webroot/index.php"
    show_status 'Updating adminer to latest version'
    curl -L -o "$DEST_DIR/adminer/webroot/index.php" "https://github.com/vrana/adminer/releases/download/$latest/adminer-${latest/v/}-en.php"
  fi
else
  rm -f  "$DEST_DIR/adminer/webroot/index.php" # could be dead symlink
  curl -L -o "$DEST_DIR/adminer/webroot/index.php" "https://github.com/vrana/adminer/releases/download/$latest/adminer-${latest/v/}-en.php"
fi
# -- SHOW THE USER CONFIRMATION PAGE ------------------------------------------
if [[ ! -d "$DEST_DIR/slipstream/webroot" ]]; then
  mkdir -p "$DEST_DIR/slipstream/webroot"
fi

cat <<EOT > "$DEST_DIR/slipstream/webroot/index.php"
<div style="width: 600px; margin-bottom: 16px; margin-left: auto; margin-right: auto;">
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
  contain a "webroot" folder/symlink, using the .localhost TLD. This means that there
  is no need to edit the /etc/hosts file for *.localhost domains. For example, if you:
</p>
<pre>
  cd ~/Sites
  git clone git@github.com:username/your-website.git
</pre>
<p>
  the website will be served at:
  <ul>
    <li>http://your-website.localhost/ and</li>
    <li>http://your-site.localhost.metaltoad-sites.com/</li>
  </ul>
  automatically.
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
  You can now access Adminer at: <a href="http://adminer.localhost/">http://adminer.localhost/</a>
  using the same mysql credentials.
  Optionally, you can download a
  <a href="https://www.adminer.org/#extras" target="_blank">custom theme</a> adminer.css
  to "$DEST_DIR/adminer/webroot/adminer.css"
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
</div>

<?php
  phpinfo();
?>
EOT

open http://slipstream.localhost/
# -----------------------------------------------------------------------------
# We're done! Now,...
# clean_up (called automatically, since we're trap-ing EXIT signal)

# This is necessary to allow for the .data section(s)
exit

# -- LIST OF PACKAGES TO INSTALL ----------------------------------------------
# .data
# -----------------------------------------------------------------------------
# Start: brew tap
homebrew/services
# End: brew tap
# -----------------------------------------------------------------------------
# Start: brew cask
# Editors
sublime-text
# Misc
clipy
# gimp
google-chrome
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
# Php 7.2 dropped mcrypt support. Previous versions now have it built in: php -m | grep mcrypt
php
php@5.6
php@7.0
php@7.1
# End: brew php
# -----------------------------------------------------------------------------
# Start: pecl
# some_module:php@5.6-1.2.3:php@7.1-2.3.4
#   if      php@5.6 then use some_module-1.2.3
#   else if php@7.1 then use some_module-2.3.4
#   else use current version of some_module
#   end if
igbinary
imagick
memcached:php@5.6-2.2.0
opcache
xdebug:php@5.6-2.5.5
# End: pecl
# -----------------------------------------------------------------------------
# Start: brew leaves
# Development Envs
node
# Database
mariadb
# Network
dnsmasq
sshuttle
# Shell
bash-completion
bash-git-prompt
# Utilities
apachetop
composer
coreutils
php-cs-fixer
pngcrush
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
