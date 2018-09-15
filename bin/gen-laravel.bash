#!/usr/bin/env bash

[[ -z "$1" ]] && exit

# -- Initial commit -----------------------------------------------------------
mkdir "$1"
cd "$1" || exit
composer create-project --prefer-dist laravel/laravel laravel 5.6
rm laravel/public/css/app.css laravel/public/js/app.js
git --git-dir="$PWD/.git" --work-tree="$PWD" init .
git --git-dir="$PWD/.git" --work-tree="$PWD" commit -m 'Empty root' --allow-empty
git --git-dir="$PWD/.git" --work-tree="$PWD" add .
git --git-dir="$PWD/.git" --work-tree="$PWD" commit -m 'Initial commit'

# -- Add README.md and webroot symlink ----------------------------------------
cat <<EOT >README.md
## Project Creation
\`\`\`
mkdir "$1"
cd "$1" || exit
composer create-project --prefer-dist laravel/laravel laravel 5.6
rm laravel/public/css/app.css laravel/public/js/app.js
ln -nfs laravel/public webroot
\`\`\`
EOT

ln -nfs laravel/public webroot

git add README.md webroot
git commit -m 'Add README.md and webroot symlink'

# -- Add engines node to package.json -----------------------------------------
node <<EOT
var data = require('./laravel/package.json');
var fs = require('fs');

data.engines = {};
data.engines.node = ">= 8.11.3";
data.engines.npm  = ">= 6.4.1";

fs.writeFileSync('./laravel/package.json', JSON.stringify(data, null, 4));
EOT
git add ./laravel/package.json
git commit -m 'Add engines node to package.json'

# -- Add package-lock.json after running: npm install -------------------------
pushd laravel > /dev/null || exit

npm install
git add package*.json
git commit -m 'Add package-lock.json after running: npm install'

# -- Run: npm install n --save-dev --------------------------------------------
npm install n --save-dev
git add package*.json
git commit -m 'Run: npm install n --save-dev'

popd > /dev/null || exit

# -- Add .gitignore -----------------------------------------------------------
cat <<EOT > .gitignore
# Compiled assets
laravel/public/css/app.css
laravel/public/js/app.js
laravel/public/mix-manifest.json
EOT

git add .gitignore
git commit -m 'Add .gitignore'

# -- Add Makefile -------------------------------------------------------------
cat <<EOT > Makefile
export N_PREFIX := \$(HOME)/n
export PATH := \$(N_PREFIX)/bin:\$(PATH)
# These version values for node/npm are used in this Makefile and
# laravel/package.json
NODE_VERSION="8.11.3"
NPM_VERSION="6.4.1"

SHELL := /bin/bash
# ------------------------------------------------------------------------------
all: dev composer-ida cc
# ------------------------------------------------------------------------------
cc:
  @cd laravel && php artisan cache:clear
  @cd laravel && php artisan config:cache
  @cd laravel && php artisan view:clear
  @cd laravel && php artisan route:clear
  @cd laravel && php artisan migrate --no-interaction

composer-ida:
  @rm -rvf laravel/bootstrap/cache/*
  @cd laravel && composer install && composer dump-autoload -o
# ------------------------------------------------------------------------------
dev: npm-install
  @cd laravel \\
    && npm run dev

prod: npm-install
  @cd laravel \\
    && npm run production

watch: npm-install
  @cd laravel \\
    && npm run watch

npm-install:
  @cd laravel \\
    && { npm install || { npm rebuild node-sass; npm install; } } \\
    && ./node_modules/.bin/n "\$(NODE_VERSION)" \\
    && npm install -g npm@"\$(NPM_VERSION)"
EOT

git add Makefile
git commit -m 'Add Makefile'

# -- Add setup notes to README.md ---------------------------------------------
cat <<EOT >> README.md

## Setup
* Create database
* Create/update \`laravel/.env\` with database credentials (including \`APP_URL\`
  and \`DB_HOST\` to match your setup)
- Run: \`php laravel/artisan key:generate\` if \`APP_KEY\` is empty
* Run: \`make all\`
EOT

git add README.md
git commit -m 'Add setup notes to README.md'

# -- Run: composer require tcg/voyager ----------------------------------------
pushd laravel > /dev/null || exit
composer require tcg/voyager

git add composer.*
git commit -m 'Run: composer require tcg/voyager'

# -- Run: php artisan voyager:install -----------------------------------------
php artisan voyager:install

git add .
git commit -m 'Run: php artisan voyager:install'

popd > /dev/null || exit

# -- Update README.md, adding notes about voyager -----------------------------
cat <<EOT >> README.md
### Voyager Admin Dashboard
* Initial setup only, run: \`php laravel/artisan voyager:install\`
* If you don't already have an account, run: \`php laravel/artisan voyager:admin your@email.com --create\`
EOT

git add README.md
git commit -m 'Update README.md, adding notes about voyager'
