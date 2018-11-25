#!/usr/bin/env bash

set -eo pipefail

# -- HELPER FUNCTIONS, PT. 1 --------------------------------------------------
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

# Misc
function is_mac() {
  [[ $OSTYPE == darwin* ]]
}

function is_linux() {
  # Usually linux-gnu, but OpenSuse is linux
  [[ $OSTYPE == linux* ]]
}

function is_mageia() {
  [[ -f /etc/lsb-release ]] && qt grep -i mageia /etc/lsb-release
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
# -- HELPER FUNCTIONS, PT. 2 --------------------------------------------------
# Parse out .data sections of this file
function get_pkgs() {
 sed -n "/Start: $1/,/End: $1/p" "$0"
}

# ... or eval it if there's code
function get_conf() {
  eval "$(get_pkgs "$1")"
}

MYPID="$$"

# Clean-up!
function clean_up() {
  errcho "Cleaning up! Bye!"

  if is_mac; then
    # Kill all caffeinate processes that are children of this script
    pkill -P $MYPID caffeinate
  fi

  exit
}

trap clean_up EXIT INT QUIT TERM
# -- CHECK OS VERSION ---------------------------------------------------------
pkg_manager=""
if is_mac; then
  OSX_VERSION="$(sw_vers -productVersion)"

  if [[ ! "$OSX_VERSION" =~ 10.1[1234] ]]; then
    get_conf "system-requirement-mac"
    exit 127
  fi
elif is_linux; then
  # openSUSE has both zypper and apt-get
  [[ -z "$pkg_manager" ]] && pkg_manager="$(basename "$(command -v zypper)")"
  [[ -z "$pkg_manager" ]] && pkg_manager="$(basename "$(command -v apt-get)")"
  [[ -z "$pkg_manager" ]] && pkg_manager="$(basename "$(command -v dnf)")"
  [[ -z "$pkg_manager" ]] && pkg_manager="$(basename "$(command -v pacman)")"

  if [[ -z "$pkg_manager" ]]; then
    get_conf "system-requirement-linux"
    exit 127
  fi
else
  die "Oops! This script is not compatibile with or tested for your OS" 127
fi
# -----------------------------------------------------------------------------
# Strip out comments, beginning and trailing whitespace, [ :].*$, and blank lines
function clean() {
  sed 's/#.*$//;s/^[[:blank:]][[:blank:]]*//g;s/[[:blank:]][[:blank:]]*$//;s/[ :].*$//;/^$/d' "$1" | sort -u
}

# PATH need to been updated to include "$(brew --prefix)" before process() is 1st called
# The paths are hard-coded, since this is happening before brew is installed
is_mac   && export PATH="/usr/local/bin:$PATH"
is_linux && export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"

# Process install
function process() {
  local brew_php_linked line pecl_pkg num_ver

  show_status "$1"
  # Compare what is already installed with what we want installed
  while read -r -u3 -a line; do
    [[ -z "$line" ]] && continue
    show_status "($1) $line"

    read -r -a line <<< "$(grep -E "^${line}[ ]*.*$" <(clean <(get_pkgs "$1")))"
    case "$1" in
      'apt-get'|'dnf'|'zypper')
        sudo "$1" install -y "${line[@]}"
        ;;
      'brew tap')
        brew tap "${line[@]}"
        ;;
      'brew cask')
        # TODO: figure out how to determine if a non-brew cask already installed in /Applications
        brew cask install "${line[@]}" || true
        ;;
      'brew build-essential'|'brew leaves'*)
        brew install "${line[@]}"
        ;;
      'brew php')
        [[ -z "$BREW_PREFIX" ]] && die "Brew is either not yet installed, or \$BREW_PREFIX not yet set" 127

        brew_php_linked="$(if qte cd "$BREW_PREFIX/var/homebrew/linked"; then qte ls -d php php@[57].[0-9]* || true; fi)"
        num_ver="$(grep -E -o '[0-9]+\.[0-9]+' <<< "$line" || brew info php | head -1 | grep -E -o '[0-9]+\.[0-9]+' || true)"

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

        # Quick hack to get around this issue with building the memcached PECL
        #   checking for sasl/sasl.h... no
        #   configure: error: no, sasl.h is not available. Run configure with --disable-memcached-sasl to disable this check
        #   ERROR: `/tmp/pear/temp/memcached/configure --with-php-config=/home/linuxbrew/.linuxbrew/opt/php/bin/php-config --with-libmemcached-dir=no' failed
        if is_linux && [[ "$line" = "libmemcached" ]]; then
          brew reinstall --build-from-source "${line[@]}"
        else
          brew install "${line[@]}"
        fi

        brew link --overwrite --force "$line"

        show_status "Installing PECLs for: $line"

        if [[ -x "$BREW_PREFIX/opt/$line/bin/pecl" ]]; then
          "$BREW_PREFIX/opt/$line/bin/pecl" channel-update pecl.php.net

          # This inner loop to install pecl packages for specific php versions'
          # only run when the brew install for the specific version's run, i.e.,
          # pecl installation's not separate/standalone, currently.
          while read -r -u4 pecl_pkg; do
            if pecl_pkg="$(sed 's/#.*$//' <<< "$pecl_pkg" || true)"; then
              [[ -z "$pecl_pkg" ]] && continue
              # We're not checking to see if it's already installed

              show_status "PECL: Installing: $pecl_pkg"
              # This entire block is to accommodate php@5.6 :/
              if [[ "$line" =~ @ ]] && [[ "$pecl_pkg" =~ $line ]]; then
                # TODO: refine this for multiple versions
                pecl_pkg="$(sed "s/:$line//" <<< "$pecl_pkg")"
                # TODO: better error handling
                qt "$BREW_PREFIX/opt/$line/bin/pecl" install "$pecl_pkg" <<< ''
              else
                pecl_pkg="$(sed 's/:.*$//' <<< "$pecl_pkg")"
                if is_mac; then
                  # TODO: better error handling
                  qt env MACOSX_DEPLOYMENT_TARGET="$(sw_vers -productVersion | grep -E -o '^[0-9]+\.[0-9]+')" \
                      CFLAGS='-fgnu89-inline' \
                      LDFLAGS='-fgnu89-inline' \
                      CXXFLAGS='-fgnu89-inline' \
                    "$BREW_PREFIX/opt/$line/bin/pecl" install "$pecl_pkg" <<< ''
                elif is_linux; then
                  # TODO: better error handling
                  qt "$BREW_PREFIX/opt/$line/bin/pecl" install "$pecl_pkg" <<< ''
                fi
              fi
            fi
          done 4< <(get_pkgs "pecl")
        fi
        ;;
      'gem')
        # TODO: Add to http://slipstream.localhost/
        #   brew info ruby: ruby is keg-only, which means it was not symlinked into /usr/local, ...
        # TODO: either check to see if the ".../opt/ruby/bin" is already in $PATH, or move outside function
        is_mac && export PATH="/usr/local/opt/ruby/bin:$PATH"
        gem install -f "${line[@]}"
        ;;
      'npm')
        npm install -g "${line[@]}"
        ;;
      'pacman')
        sudo pacman -S --noconfirm "${line[@]}"
        ;;
      *)
        ;;
    esac
  done 3< <(get_diff "$@")

  qt hash
}

# Get list of installed packages
function get_installed() {
  case "$1" in
    'apt-get')
      qte apt list --installed | sed 's;/.*$;;' | sort -u
      ;;
    'brew cask')
      brew cask list | sort -u
      ;;
    'brew tap')
      brew tap | sort -u
      ;;
    'brew build-essential'|'brew leaves'*|'brew php')
      brew list | sort -u
      ;;
    'dnf')
      qte dnf list installed | sed 's/\..*$//' | sort -u
      ;;
    'gem')
      $1 list | sed 's/ .*$//' | sort -u
      ;;
    'npm')
      qte npm -g list | iconv -c -f utf-8 -t ascii | grep -v -e '^/' -e '^  ' | sed 's/@.*$//;/^$/d;s/ //g' | sort -u
      ;;
    'pacman')
      qte pacman -Qn | sed 's/ .*$//' | sort -u
      ;;
    'zypper')
      qte zypper search --installed-only | sed 's;^i *| *\([^ ][^ ]*\).*$;\1;' | sort -u
      ;;
    *)
      echo
      ;;
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
  local msg vcs

  vcs="$(basename "$(command -v etckeeper || echo git)")"

  msg="$2"
  show_status "Committing to $vcs"
  sudo -H bash -c " cd /etc/ ; $1 ; $vcs commit -m '[Slipstream] $msg' "
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

# Given: "max_execution_time = 0"
# echo's: "s|;*[[:space:]]*max_execution_time[[:space:]]*=[[:space:]]*.*|max_execution_time = 0|"
function get_ini_sed_script() {
  local i pre peri post sed_script

  pre=';*[[:space:]]*'
  post='[[:space:]]*=[[:space:]]*.*'
  sed_script=""

  for i in "$@"; do
    peri="${i%% *}"
    sed_script="${sed_script}s|${pre}${peri}${post}|$i|"$'\n'
  done

  echo "$sed_script"
}
# -- CHECK AND INSTALL XCODE CLI TOOLS ----------------------------------------
# .text
if is_mac; then
  if ! qt xcode-select -p; then
    echo "You don't seem to have Xcode Command Line Tools installed"
    # shellcheck disable=SC2034
    read -r -p "Hit [enter] to start its installation. Re-run this script when done: " dummy
    xcode-select --install
    exit
  fi
fi
# -- OVERVIEW OF CHANGES THAT WILL BE MADE ------------------------------------
get_conf "all-systems-go-$(is_mac && echo mac; is_linux && echo linux)"

# shellcheck disable=SC2034
read -r -p "Hit [enter] to start or control-c to quit: " dummy
# -- KEEP DISPLAY/SYSTEM FROM IDLING/SLEEPING ---------------------------------
if is_mac; then
  # Generously setting for an hour, but clean_up() will kill it upon exit or
  # interrupt
  caffeinate -d -i -t 3600 &
fi
# -- VERSION CONTROL /etc -----------------------------------------------------
# We should have git available now, after installing Xcode cli tools
if [[ ! -f /etc/.git/config ]]; then
  show_status "Git init-ing /etc [you may be prompted for sudo password]: "

  if is_linux; then
    case "$pkg_manager" in
      'apt-get')
        sudo apt-get update
        # apt-cache depends etckeeper
        sudo apt-get install -y etckeeper
        ;;
      'dnf')
        # Mageia has neither sudo nor git in base installation
        # TODO: what to do if wrong password's entered for "su"?
        qt command -v sudo || su -c 'dnf -y install sudo'; qt hash
        qt command -v git  || sudo   dnf -y install git;   qt hash
        # Quick+dirty hack :/
        if ! is_mageia; then
          sudo dnf -y install etckeeper
          sudo etckeeper init
        fi
        ;;
      'pacman')
        sudo pacman -Syy --noconfirm # The -Syu seems to do entire system upgrade
        sudo pacman -S --noconfirm etckeeper
        sudo etckeeper init
        ;;
      'zypper')
        # Took forever: sudo zypper update -y
        sudo zypper install -y etckeeper
        ;;
    esac

    qt hash
  fi

  sudo -H bash -c "
[[ -z '$(git config --get user.name)'  ]] && git config --global user.name 'System Administrator'
[[ -z '$(git config --get user.email)' ]] && git config --global user.email '$USER@localhost'" || true

  if ! qt command -v etckeeper; then
    etc_git_commit "git init" || true
    etc_git_commit "git add ." "Initial commit"
  fi
fi

# -- PRIME THE PUMP -----------------------------------------------------------
if is_linux; then
  show_status "== Processing $pkg_manager =="
  process "$pkg_manager"
  qt hash

  if [[ ! -L /Users ]]; then
    show_status "Symlinking /home to /Users"
    sudo ln -nfs /home /Users
  fi
fi
# -- PASSWORDLESS SUDO --------------------------------------------------------
show_status "== Processing Sudo Password =="

if is_mac; then
  if ! qt sudo grep '^%admin[[:space:]]*ALL=(ALL) NOPASSWD: ALL' /etc/sudoers; then
    show_status "Making sudo password-less for 'admin' group"
    sudo sed -i.bak 's/\(%admin[[:space:]]*ALL[[:space:]]*=[[:space:]]*(ALL)\)[[:space:]]*ALL/\1 NOPASSWD: ALL/' /etc/sudoers

    if qt sudo diff /etc/sudoers /etc/sudoers.bak; then
      errcho "No change made to: /etc/sudoers"
    else
      etc_git_commit "git add sudoers" 'Password-less sudo for "admin" group'
    fi

    sudo rm -f /etc/sudoers.bak
  fi
elif is_linux; then
  if ! qt sudo test -e /etc/sudoers.d/10-local-users; then
    [[ ! -d /etc/sudoers.d ]] && sudo mkdir -p /etc/sudoers.d
    cat <<EOT | qt sudo tee /etc/sudoers.d/10-local-users
# User rules for $USER
$USER ALL=(ALL) NOPASSWD:ALL
EOT
    sudo chmod 640 /etc/sudoers.d/10-local-users
    etc_git_commit "git add /etc/sudoers.d/10-local-users" "Password-less sudo for '$USER'"
  fi
fi
# -- HOMEBREW -----------------------------------------------------------------
show_status "== Processing Homebrew =="

if ! qt command -v brew; then
  is_mac   && /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
  is_linux && sh            -c "$(curl -fsSL https://raw.githubusercontent.com/Linuxbrew/install/master/install.sh)"
  qt hash
fi

BREW_PREFIX="$(brew --prefix)"
export BREW_PREFIX

if is_linux; then
  # brew doctor complains:
  #   You should create these directories and change their ownership to your account.
  sudo mkdir -p         "$BREW_PREFIX/var/homebrew/linked"
  sudo chown -R "$USER" "$BREW_PREFIX/var/homebrew/linked"

  process "brew build-essential"
fi

# TODO: test for errors
brew doctor || true

if is_mac; then
  process "brew tap"
  process "brew cask"
fi

process "brew php"
process "brew leaves"
is_mac   && process "brew leaves-mac"
is_linux && process "brew leaves-linux"
# -- INSTALL PYTHON / PIPS ----------------------------------------------------
show_status "== Processing Pip =="

if is_linux; then
  export PATH="$HOME/.pyenv/shims:$PATH"
  if [[ ! -x "$HOME/.pyenv/shims/python" ]]; then
    qt hash
    eval "$(pyenv init -)"
    # Latest stable version
    # Versions 2.7.* does not support OpenSSL1.1.0
    pyenv install 3.7.1
    pyenv global 3.7.1
    qt hash
  fi
fi

process "pip"
# -- INSTALL RUBY / GEMS ------------------------------------------------------
show_status "== Processing Gem =="

if is_linux; then
  export PATH="$HOME/.rbenv/shims:$PATH"
  if [[ ! -x "$HOME/.rbenv/shims/ruby" ]]; then
    qt hash
    eval "$(rbenv init -)"
    # Latest stable version
    rbenv install 2.5.3
    rbenv global 2.5.3
    qt hash
  fi
fi

process "gem"
# -- INSTALL NPM PACKAGES -----------------------------------------------------
show_status "== Processing Npm =="

if is_linux; then
  # Set N_PREFIX since it's /usr/local under linux, and would require sudo
  export N_PREFIX="$HOME/n"
  export PATH="$HOME/n/bin:$PATH"
  # n-install aborts if it finds Node.js-related binaries already in $PATH
  # brew uses node, reports icu4c, which in turn is a dep for php
  if qt brew list node; then
    brew unlink node
    rm -f "$BREW_PREFIX/bin/npm"
  fi
  if [[ ! -x "$HOME/n/bin/node" ]]; then
    # https://github.com/mklement0/n-install
    curl -L https://git.io/n-install | bash -s -- -y
    n lts
  fi
fi

process "npm"
# -- DISABLE OUTGOING MAIL ----------------------------------------------------
show_status "== Processing Postfix =="

if is_linux; then
  # TODO: cleanup logic
  case "$pkg_manager" in
    'apt-get')
      if ! qte apt list --installed | sed 's;/.*$;;' | qt grep postfix; then
        sudo debconf-set-selections <<< "postfix postfix/mailname string $(hostname)"
        sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
        sudo apt-get install -y bsd-mailx postfix
      fi
      ;;
    'dnf')
      # TODO: figure out configuration
      if ! qte dnf list installed | sed 's/\..*$//' | qt grep postfix; then
        sudo dnf -y install mailx postfix
      fi
      ;;
    'pacman')
      # TODO: figure out configuration
      # manjaro: "sendmail: error while loading shared libraries: libicui18n.so.63: cannot open shared object file: No such file or directory"
      if ! qte pacman -Qn | sed 's/ .*$//' | qt grep postfix; then
        sudo pacman -S --noconfirm postfix
      fi
      ;;
    'zypper')
      # TODO: figure out configuration
      if ! qte zypper search --installed-only | sed 's;^i *| *\([^ ][^ ]*\).*$;\1;' | qt grep postfix; then
        sudo zypper install -y mailx postfix
      fi
      ;;
  esac
fi

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
if sudo git status | qt grep -E 'postfix/main.cf|postfix/virtual'; then
  etc_git_commit "git add postfix/main.cf postfix/virtual" "Disable outgoing mail (postfix tweaks)"
fi
qt popd
# -- INSTALL MARIADB (MYSQL) --------------------------------------------------
show_status "== Processing MariaDB =="

[[ ! -d "$BREW_PREFIX/etc/my.cnf.d" ]] && mkdir -p "$BREW_PREFIX/etc/my.cnf.d"
# TODO: decouple from /etc/homebrew/etc/my.cnf.d/mysqld_innodb.cnf
if [[ ! -f "$BREW_PREFIX/etc/my.cnf.d/mysqld_innodb.cnf" ]]; then
  show_status           "Creating: $BREW_PREFIX/etc/my.cnf.d/mysqld_innodb.cnf"
  get_conf "mysqld_innodb.cnf" >  "$BREW_PREFIX/etc/my.cnf.d/mysqld_innodb.cnf"
fi

# Start MariaDB
# The new version of 'mysql.server status' uses su which prompts for password
# if you're not root, so we do this
mysqld_pid=
mysqld_status=
if [[ -f "$BREW_PREFIX/var/mysql/$(hostname).pid" ]]; then
  read -r mysqld_pid < "$BREW_PREFIX/var/mysql/$(hostname).pid"
  kill -0 "$mysqld_pid"
  mysqld_status="$?"
fi

if [[ "$mysqld_status" != "0" ]]; then
  if is_mac; then
    brew services restart mariadb
  elif is_linux; then
    # TODO: figure out how to start automatically
    (qt mysql.server stop; qt mysql.server start &)
  fi
  show_status "Setting mysql root password... waiting for mysqld to start"
  # Just sleep, waiting for mariadb to start
  sleep 7
  if qt mysql -u root <<< 'SELECT 1;'; then
    mysql -u root mysql <<< "SET SQL_SAFE_UPDATES = 0; UPDATE user SET password=PASSWORD('root') WHERE User='root'; FLUSH PRIVILEGES; SET SQL_SAFE_UPDATES = 1;"
  fi
fi
# -- SETUP APACHE -------------------------------------------------------------
show_status "== Processing Apache =="

# TODO: switch from using system apache to homebrew apache
# # Neuter System Apache, and don't worry about and /etc/ droppings
# if qt  pgrep    -f "/usr/sbin/httpd"; then
#   sudo pkill -9 -f "/usr/sbin/httpd"
#
#   show_status "Unloading: /System/Library/LaunchDaemons/org.apache.httpd.plist"
#   sudo launchctl unload -w /System/Library/LaunchDaemons/org.apache.httpd.plist
# fi

APACHE_BASE="/etc/apache2"
is_linux && APACHE_BASE="$BREW_PREFIX/etc/httpd"
HTTPD_CONF="$APACHE_BASE/httpd.conf"

SUDO_ON_MAC="$(if is_mac; then echo sudo; fi)"
show_status "Updating httpd.conf settings"
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
  $SUDO_ON_MAC sed -i.bak "s;#.*${i}\\(.*\\);${i}\\1;"  "$HTTPD_CONF"
done

$SUDO_ON_MAC sed -i.bak "s;^Listen 80.*$;Listen 80;"    "$HTTPD_CONF"
$SUDO_ON_MAC sed -i.bak "s;^User .*$;User $USER;"       "$HTTPD_CONF"
$SUDO_ON_MAC sed -i.bak "s;^Group .*$;Group $(id -gn);" "$HTTPD_CONF"

DEST_DIR="/Users/$USER/Sites"

[[ ! -d "$DEST_DIR" ]] && mkdir -p "$DEST_DIR"

if [[ ! -d "$APACHE_BASE/ssl" ]]; then
  show_status "Add httpd/ssl files"

  mkdir -p "$$/ssl"
  qt pushd "$$/ssl"
  genssl
  qt popd
  $SUDO_ON_MAC mv "$$/ssl" "$APACHE_BASE"
  rmdir "$$"

  if is_mac; then
    sudo chown -R root:wheel "$APACHE_BASE/ssl"
    etc_git_commit "git add apache2/ssl" "Add apache2/ssl files"
  fi
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

if [[ ! -f "$APACHE_BASE/extra/localhost.conf" ]] || ! qt grep "$PHP_FPM_HANDLER" "$APACHE_BASE/extra/localhost.conf" || ! qt grep \\.localhost\\.metaltoad-sites\\.com "$APACHE_BASE/extra/localhost.conf" || ! qt grep \\.xip\\.io "$APACHE_BASE/extra/localhost.conf"; then
  # shellcheck disable=SC2086
  get_conf "localhost.conf" | qt $SUDO_ON_MAC tee "$APACHE_BASE/extra/localhost.conf"

  if ! qt grep '^# Local vhost and ssl, for \*.localhost$' "$HTTPD_CONF"; then
    cat <<EOT | qt sudo tee -a "$HTTPD_CONF"

# Local vhost and ssl, for *.localhost
Include $APACHE_BASE/extra/localhost.conf
EOT
  fi

  is_mac && etc_git_commit "git add apache2/extra/localhost.conf" "Add apache2/extra/localhost.conf"
else
  if qt grep ' ProxySet connectiontimeout=5 timeout=240$' "$APACHE_BASE/extra/localhost.conf"; then
    show_status "Update httpd/extra/localhost.conf ProxySet timeout value to 1800"
    $SUDO_ON_MAC sed -i.bak 's/ ProxySet connectiontimeout=5 timeout=240/ ProxySet connectiontimeout=5 timeout=1800/' "$APACHE_BASE/extra/localhost.conf"
    $SUDO_ON_MAC rm "$APACHE_BASE/extra/localhost.conf.bak"

    is_mac && etc_git_commit "git add apache2/extra/localhost.conf" "Update apache2/extra/localhost.conf ProxySet timeout value to 1800"
  fi
fi

if ! qt grep '^# To avoid: Gateway Timeout, during xdebug session (analogous changes made to the php.ini files)$' "$HTTPD_CONF"; then
  # shellcheck disable=SC2086
  cat <<EOT | qt $SUDO_ON_MAC tee -a "$HTTPD_CONF"

# To avoid: Gateway Timeout, during xdebug session (analogous changes made to the php.ini files)
Timeout 1800
EOT
fi

# Have ServerName match CN in SSL Cert
$SUDO_ON_MAC sed -i.bak 's/#ServerName www.example.com:80.*/ServerName 127.0.0.1/' "$HTTPD_CONF"
if is_mac; then
  if qt diff "$HTTPD_CONF" "${HTTPD_CONF}.bak"; then
    errcho "No change made to: apache2/httpd.conf"
  else
    etc_git_commit "git add apache2/httpd.conf" "Update apache2/httpd.conf"
  fi
fi
$SUDO_ON_MAC rm "${HTTPD_CONF}.bak"

# https://clickontyler.com/support/a/38/how-start-apache-automatically/
if is_mac && ! qt sudo launchctl list org.apache.httpd; then
  show_status "Loading: /System/Library/LaunchDaemons/org.apache.httpd.plist"
  sudo launchctl load -w /System/Library/LaunchDaemons/org.apache.httpd.plist
fi
# TODO: automatically start apache, for linux
# -- WILDCARD DNS -------------------------------------------------------------
show_status "== Processing Dnsmasq =="

# TODO: decouple from /etc/homebrew/etc/dnsmasq.conf
conffile="$BREW_PREFIX/etc/dnsmasq.conf"
is_linux && conffile="/etc/NetworkManager/dnsmasq.d/10-slipstream.conf"
if [[ ! -f "$conffile" ]] || ! qt grep -E '^address=/.localhost/127.0.0.1$' "$conffile"; then
  show_status "Updating: $conffile"
  [[ ! -d "${conffile%/*}" ]] && sudo mkdir -p "${conffile%/*}"
  cat <<EOT | qt sudo tee -a "$conffile"
address=/.localhost/127.0.0.1
EOT

  if is_linux; then
    etc_git_commit "git add $conffile" "Updating $conffile"
    # TODO: Mint: "Failed to restart dnsmasq.service: Unit dnsmasq.service not found."
    qt sudo systemctl restart dnsmasq || true
  fi
fi

if is_mac; then
  [[ ! -d /etc/resolver ]] && sudo mkdir /etc/resolver
  if [[ ! -f /etc/resolver/localhost ]]; then
    cat <<EOT | qt sudo tee /etc/resolver/localhost
nameserver 127.0.0.1
EOT
    etc_git_commit "git add resolver/localhost" "Add resolver/localhost file for dnsmasq updates"
  fi

  show_status "Starting: sudo brew services start dnsmasq"
  sudo brew services start dnsmasq
fi

if is_linux; then
  conffile="/etc/NetworkManager/NetworkManager.conf"
  # TODO: should really test for "[main]" and "dns=dnsmasq"
  if [[ ! -f "$conffile" ]] || ! qt grep -E -e '^dns=dnsmasq$' "$conffile"; then
    show_status "Updating: $conffile"
    [[ ! -d "${conffile%/*}" ]] && sudo mkdir -p "${conffile%/*}"
    cat <<EOT | qt sudo tee -a "$conffile"
[main]
dns=dnsmasq
EOT

    etc_git_commit "git add $conffile" "Updating $conffile"
    # TODO: Mint: "Failed to restart dnsmasq.service: Unit dnsmasq.service not found."
    qt sudo systemctl restart dnsmasq || true
    # TODO: Mageia: Failed to restart NetworkManager.service: Unit NetworkManager.service not found.
    qt sudo systemctl restart NetworkManager || true
  fi
fi

if ! qt grep -i dnsmasq /etc/hosts; then
  cat <<EOT | qt sudo tee -a /etc/hosts

# NOTE: dnsmasq is managing *.localhost domains (foo.localhost) so there's no need to add such here
# Use this hosts file for non-.localhost domains like: foo.bar.com
EOT

  etc_git_commit "git add hosts" "Add dnsmasq note to hosts file"
fi
# -- SETUP BREW PHP / PHP.INI / XDEBUG ----------------------------------------
show_status "== Processing Brew PHP / php.ini / Xdebug =="

if is_mac; then
  [[ ! -d ~/Library/LaunchAgents ]] && mkdir -p  ~/Library/LaunchAgents
fi

ini_settings=(
  "date.timezone = America/Los_Angeles"
  "display_errors = On"
  "display_startup_errors = On"
  "error_log = /var/log/apache2/php_errors.log"
  "max_execution_time = 0"
  "max_input_time = 1800"
  "max_input_vars = 10000"
  "memory_limit = 256M"
  "mysql.default_socket = /tmp/mysql.sock"
  "mysqli.default_socket = /tmp/mysql.sock"
  "pdo_mysql.default_socket = /tmp/mysql.sock"
  "post_max_size = 100M"
  "realpath_cache_size = 128K"
  "realpath_cache_ttl = 3600"
  "upload_max_filesize = 100M"
)

conf_settings=(
  "listen = $PHP_FPM_LISTEN"
  "listen.mode = 0666"
  "pm.max_children = 10"
)

for i in "$BREW_PREFIX/etc/php/"*/php.ini; do
  dir_path="${i%/*}"
  version="$(grep -E -o '[0-9]+\.[0-9]+' <<< "$i")"

  # Process php.ini for $version
  show_status "Updating some $i settings"
  sed -i.bak "$(get_ini_sed_script "${ini_settings[@]}")" "$i"
  mv "${i}.bak" "${i}.${NOW}-post-process"
  show_status "Original saved to: ${i}.${NOW}-post-process"

  # Process ext-xdebug.ini
  if [[ -f "$dir_path/conf.d/ext-xdebug.ini" ]]; then
    show_status "Found old ext-xdebug.ini, backed up to: $dir_path/conf.d/ext-xdebug.ini"
    mv "$dir_path/conf.d/ext-xdebug.ini"{,-"$NOW"}
  fi
  show_status       "Updating: $dir_path/conf.d/ext-xdebug.ini"
  get_conf "ext-xdebug.ini" > "$dir_path/conf.d/ext-xdebug.ini"

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
    sed -i.bak "
      $(get_ini_sed_script "${conf_settings[@]}")
      /^user[[:space:]]*=[[:space:]]*.*/ s|^|;|
      /^group[[:space:]]*=[[:space:]]*.*/ s|^|;|
    " "$php_fpm_conf"
    mv "${php_fpm_conf}.bak" "${php_fpm_conf}-${NOW}"
    show_status "Original saved to: ${php_fpm_conf}-${NOW}"
  fi
done

if is_mac; then
  if [[ -d "/etc/homebrew/$APACHE_BASE" ]]; then
    show_status "Deleting homebrew/$APACHE_BASE for switch to php-fpm"
    sudo rm -rf "/etc/homebrew/$APACHE_BASE"
    etc_git_commit "git rm -r homebrew/$APACHE_BASE" "Deleting homebrew/$APACHE_BASE for switch to php-fpm"
  fi

  if [[ -d "$BREW_PREFIX/var/run/apache2" ]]; then
    rm -rf "$BREW_PREFIX/var/run/apache2"
  fi

  # Account for both newly and previously provisioned scenarios
  sudo sed -i.bak "s;^\\(LoadModule[[:space:]]*php5_module[[:space:]]*libexec/apache2/libphp5.so\\);# \\1;"                         "$HTTPD_CONF"
  sudo sed -i.bak "s;^\\(LoadModule[[:space:]]*php5_module[[:space:]]*$BREW_PREFIX/opt/php56/libexec/apache2/libphp5.so\\);# \\1;"  "$HTTPD_CONF"
  sudo sed -i.bak "s;^\\(Include[[:space:]]\"*$BREW_PREFIX/var/run/apache2/php.conf\\);# \\1;"                                      "$HTTPD_CONF"
  sudo rm "${HTTPD_CONF}.bak"

  qt pushd /etc/
  if git status | qt grep -E 'apache2/httpd.conf'; then
    etc_git_commit "git add apache2/httpd.conf" "Update apache2/httpd.conf to use brew php-fpm"
  fi
  qt popd

  while read -r -u3 service && [[ ! -z "$service" ]]; do
    qte brew services stop "$service"
  done 3< <(brew services list | grep -E -e '^php ' -e '^php@[57]' | grep ' started ' | cut -f1 -d' ')
fi

[[ ! -d "$BREW_PREFIX/var/log/" ]] && mkdir -p "$BREW_PREFIX/var/log/"
# Make php@7.1 the default
if is_mac; then
  brew services start php@7.1
elif is_linux; then
  qte killall php-fpm || true
fi

brew_php_linked="$(if qte cd "$BREW_PREFIX/var/homebrew/linked"; then qte ls -d php php@[57].[0-9]* || true; fi)"
# Only link if brew php is not linked. If it is, we assume it was intentionally done
if [[ -z "$brew_php_linked" ]]; then
  brew link --overwrite --force php@7.1
fi

if is_mac; then
  # Some "upgrades" from (Mountain Lion / Mavericks) Apache 2.2 to 2.4, seems to
  # keep the 2.2 config files. The "LockFile" directive is an artifact of 2.2
  #   http://apple.stackexchange.com/questions/211015/el-capitan-apache-error-message-ah00526
  # This simple commenting out of the line seems to work just fine.
  sudo sed -i.bak 's;^\(LockFile\);# \1;' "$APACHE_BASE/extra/httpd-mpm.conf"
  sudo rm -f "$APACHE_BASE/extra/httpd-mpm.conf.bak"

  qt pushd /etc/
  if git status | qt grep 'apache2/extra/httpd-mpm.conf'; then
    etc_git_commit "git add apache2/extra/httpd-mpm.conf" "Comment out LockFile in apache2/extra/httpd-mpm.conf"
  fi
  qt popd

  sudo apachectl -k restart
elif is_linux; then
  ("$BREW_PREFIX/sbin/php-fpm" &)
  [[ ! -d "/var/log/apache2/" ]] && { sudo mkdir "/var/log/apache2/"; sudo chown "$USER:$(id -ng)" "/var/log/apache2/"; }
  sudo "$(brew --prefix)"/bin/apachectl -k restart
fi

sleep 3
# -- SETUP ADMINER ------------------------------------------------------------
show_status "Setting up adminer"
[[ ! -d "$DEST_DIR/adminer/webroot" ]] && mkdir  -p "$DEST_DIR/adminer/webroot"
[[ ! -w "$DEST_DIR/adminer/webroot" ]] && chmod u+w "$DEST_DIR/adminer/webroot"
latest="$(curl -IkLs https://github.com/vrana/adminer/releases/latest | col -b | grep Location | grep -E -o '[^/]+$')"

if [[ -e "$DEST_DIR/adminer/webroot/index.php" ]]; then
  if [[ "$(grep '\* @version' "$DEST_DIR/adminer/webroot/index.php" | grep -E -o '[0-9]+.*')" != "${latest/v/}" ]]; then
    rm -f  "$DEST_DIR/adminer/webroot/index.php"
    show_status "Updating adminer to latest version"
    curl -L -o "$DEST_DIR/adminer/webroot/index.php" "https://github.com/vrana/adminer/releases/download/$latest/adminer-${latest/v/}-en.php"
  fi
else
  rm -f  "$DEST_DIR/adminer/webroot/index.php" # could be dead symlink
  curl -L -o "$DEST_DIR/adminer/webroot/index.php" "https://github.com/vrana/adminer/releases/download/$latest/adminer-${latest/v/}-en.php"
fi
# -- SHOW THE USER CONFIRMATION PAGE ------------------------------------------
[[ ! -d "$DEST_DIR/slipstream/webroot" ]] && mkdir -p "$DEST_DIR/slipstream/webroot"
get_conf "slipstream" > "$DEST_DIR/slipstream/webroot/index.php"
"$(command -v xdg-open || command -v open)" http://slipstream.localhost/
# -----------------------------------------------------------------------------
# We're done! Now,...
# clean_up (called automatically, since we're trap-ing EXIT signal)

# This is necessary to allow for the .data section(s)
exit

# -- LIST OF PACKAGES TO INSTALL ----------------------------------------------
# .data
# -----------------------------------------------------------------------------
# TODO: revisit: apt-get, dnf, pacman, and zypper dependencies. they were added
# before the "brew build-essential" group was added
# Start: apt-get
build-essential
curl
default-jdk
git
# For pyenv and/or rbenv
libbz2-dev
libffi-dev
libsqlite3-dev
libssl-dev
zlib1g-dev
# End: apt-get
# -----------------------------------------------------------------------------
# Start: dnf
dnsmasq
java-1.8.0-openjdk
make
# For pyenv and/or rbenv
libffi-devel
zlib-devel
# End: dnf
# -----------------------------------------------------------------------------
# Start: pacman
dnsmasq
dnsutils
git
jdk10-openjdk
# For linuxbrew php
libmemcached
# End: pacman
# -----------------------------------------------------------------------------
# Start: zypper
# End: zypper
# -----------------------------------------------------------------------------
# Start: brew build-essential
binutils
gcc
linux-headers
pkg-config
# End: brew build-essential
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
p4v
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
httpd
# This needs to be available for the imagemagick, memcached PECLs
imagemagick
libmemcached
memcached
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
xdebug:php@5.6-2.5.5
# End: pecl
# -----------------------------------------------------------------------------
# Start: brew leaves
# Development Envs
# Database
mariadb
# Network
sshuttle
# Shell
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
# Start: brew leaves-mac
# Development Envs
node
ruby
# Network
dnsmasq
# Shell
bash-completion
# End: brew leaves-mac
# -----------------------------------------------------------------------------
# Start: brew leaves-linux
# Development Envs
pyenv
rbenv
# End: brew leaves-linux
# -----------------------------------------------------------------------------
# Start: pip
# End: pip
# -----------------------------------------------------------------------------
# Start: gem
bundler
compass
capistrano -v 2.15.5
# End: gem
# -----------------------------------------------------------------------------
# Start: npm
csslint
fixmyjs
grunt-cli
js-beautify
jshint
# End: npm
# -----------------------------------------------------------------------------
# Start: system-requirement-mac
cat <<EOT
Sorry! This script is currently only compatible with:
  El Capitan  (10.11*)
  Sierra      (10.12*)
  High Sierra (10.13*)
  Mojave      (10.14*)
You're running:

$(sw_vers)

EOT
# End: system-requirement-mac
# -----------------------------------------------------------------------------
# Start: system-requirement-linux
cat <<EOT
Sorry! This script is currently only compatible with:

  apt-get based distributions, tested on:

    Mint >= 19.1
    Xubuntu >= 18.04

  dnf based distributions, tested on:

    Fedora >= 29
    Mageia >= 6

  pacman based distributions, tested on:

    Antergos >= 18.11
    Manjaro >= 18.0

You're running:

$(
  if [[ -e /proc/version ]]; then
    cat /proc/version
  elif [[ -e /etc/issue ]]; then
    cat /etc/issue
  fi
)

EOT
# WIP: openSUSE >= 42.3
# Running into:
#   cannot be installed as binary package and must be built from source.
#   Install Clang or brew install gcc
# chicken/egg issue w/ gcc / glibc
# End: system-requirement-linux
# -----------------------------------------------------------------------------
# Start: all-systems-go-mac
cat <<EOT

OK. It looks like we're ready to go.
*******************************************************************************
***** NOTE: This script assumes a "pristine" installation of El Capitan,  *****
***** [High] Sierra, or Mojave If you've already made changes to files in *****
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
    - Apache2 (Enable modules, and add wildcard vhost conf) [including
      - ServerAlias for *.nip.io, *.xip.io for <anything>.<IP Address>.nip.io
        *.localhost.metaltoad-sites.com, *.lvh.me, and *.vcap.me for localhost]
    - Dnsmasq (Resolve *.localhost domains w/OUT /etc/hosts editing)
EOT
# End: all-systems-go-mac
# -----------------------------------------------------------------------------
# Start: all-systems-go-linux
cat <<EOT

OK. It looks like we're ready to go.
*******************************************************************************
***** NOTE: This script assumes a "pristine" installation of Ubuntu,      *****
***** If you've already made changes to files in /etc, then all bets      *****
***** are off. You have been WARNED!                                      *****
*******************************************************************************
If you wish to continue, then this is what I'll be doing:
  - Git-ifying your /etc folder with etckeeper
  - Allow for password-less sudo by adding /etc/sudoers.d/10-local-users
  - Install linux brew, and some brew packages
  - Install Python  (via 'pyenv')             and install some pips
  - Install Ruby    (via 'rbenv/ruby-build')  and install some gems
  - Install NodeJs  (via 'n/n-install')       and install some npm packages
  -- Configure:
    - Postfix (Disable outgoing mail)
    - MariaDB (InnoDB tweaks, etc.)
    - Php.ini (Misc. configurations)
    - Apache2 (Enable modules, and add wildcard vhost conf) [including
      - ServerAlias for *.nip.io, *.xip.io for <anything>.<IP Address>.nip.io
        *.localhost.metaltoad-sites.com, *.lvh.me, and *.vcap.me for localhost]
    - Dnsmasq (Resolve *.localhost domains w/OUT /etc/hosts editing)
EOT
# End: all-systems-go-linux
# -----------------------------------------------------------------------------
# Start: mysqld_innodb.cnf
cat <<EOT
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
# End: mysqld_innodb.cnf
# -----------------------------------------------------------------------------
# Start: localhost.conf
cat <<EOT
<VirtualHost *:80>
  ServerAdmin $USER@localhost
  ServerAlias *.localhost *.vmlocalhost *.localhost.metaltoad-sites.com *.xip.io *.nip.io *.lvh.me *.vcap.me
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

  # Depends on:
  #   "LoadModule proxy_fcgi_module libexec/apache2/mod_proxy_fcgi.so" in httpd.conf on mac, and
  #   "LoadModule proxy_fcgi_module lib/httpd/modules/mod_proxy_fcgi.so" on linux
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
  ServerAlias *.localhost *.vmlocalhost *.localhost.metaltoad-sites.com *.xip.io *.nip.io *.lvh.me *.vcap.me
  VirtualDocumentRoot $DEST_DIR/%1/webroot

  SSLEngine On
  SSLCertificateFile    $APACHE_BASE/ssl/server.crt
  SSLCertificateKeyFile $APACHE_BASE/ssl/server.key

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

  # Depends on:
  #   "LoadModule proxy_fcgi_module libexec/apache2/mod_proxy_fcgi.so" in httpd.conf on mac, and
  #   "LoadModule proxy_fcgi_module lib/httpd/modules/mod_proxy_fcgi.so" on linux
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
# End: localhost.conf
# -----------------------------------------------------------------------------
# Start: ext-xdebug.ini
cat <<EOT
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
# End: ext-xdebug.ini
# -----------------------------------------------------------------------------
# Start: slipstream
cat <<EOT
<div style="width: 934px; margin-bottom: 16px; margin-left: auto; margin-right: auto;">
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

  \$my_ip = getHostByName(getHostName());

  \$link = @mysqli_connect('127.0.0.1', 'root', 'root', 'mysql');
  \$mysqli_status = \$link ? mysqli_stat(\$link) : mysqli_connect_error();
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
  the website will be served at any of the following:
  <ul>
    <li>http://your-website.localhost/</li>
    <li>http://your-website.localhost.metaltoad-sites.com/</li>
    <li>http://your-website.lvh.me/</li>
    <li>http://your-website.vcap.me/</li>
    <li>http://your-website.<?php echo \$my_ip; ?>.nip.io/</li>
    <li>http://your-website.<?php echo \$my_ip; ?>.xip.io/</li>
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
  <strong>Current status:</strong>
  <dd><i><?php echo preg_replace('/  /', '<br/>', \$mysqli_status); ?></i></dd>
</p>

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
  $(is_mac && clean <(get_pkgs "brew cask"))
  $(clean <(get_pkgs "brew php"))
  $(clean <(get_pkgs "brew leaves"))
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
# End: slipstream
# -----------------------------------------------------------------------------
