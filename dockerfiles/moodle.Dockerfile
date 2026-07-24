# Moodle 5.x — Production Docker Build
# Update: change MOODLE_VERSION below, rebuild, redeploy
# Source: https://download.moodle.org/releases/latest/
#
# Requires: PostgreSQL 15+, PHP 8.2+
# Supports: SCORM, xAPI, Redis cache, Gmail SMTP
# Note: Moodle 5.x uses public/ webroot structure

ARG MOODLE_VERSION=5.1.3
ARG MOODLE_BRANCH=501

# Plugin versions — update here to upgrade
ARG MOOVE_VERSION=MOODLE_500_STABLE
ARG FORMAT_TILES_VERSION=main

FROM php:8.3.21-apache AS builder

ARG MOODLE_VERSION
ARG MOODLE_BRANCH
ARG MOOVE_VERSION
ARG FORMAT_TILES_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates unzip git \
  && curl -fSL "https://packaging.moodle.org/stable${MOODLE_BRANCH}/moodle-${MOODLE_VERSION}.tgz" \
     -o /tmp/moodle.tgz \
  && mkdir -p /opt/moodle \
  && tar -xzf /tmp/moodle.tgz -C /opt/moodle --strip-components=1 \
  && rm /tmp/moodle.tgz

# ── Moove theme (Moodle HQ — modern Bootstrap 5 responsive theme) ──
RUN curl -fSL "https://github.com/willianmano/moodle-theme_moove/archive/refs/heads/${MOOVE_VERSION}.tar.gz" \
    -o /tmp/moove.tgz \
  && mkdir -p /opt/moodle/public/theme/moove \
  && tar -xzf /tmp/moove.tgz -C /opt/moodle/public/theme/moove --strip-components=1 \
  && rm /tmp/moove.tgz

# ── format_tiles (card-based course layout — Netflix-style grid) ──
RUN curl -fSL "https://github.com/TechnologyEnhancedLearning/moodle-format_tiles/archive/refs/heads/${FORMAT_TILES_VERSION}.tar.gz" \
    -o /tmp/tiles.tgz \
  && mkdir -p /opt/moodle/public/course/format/tiles \
  && tar -xzf /tmp/tiles.tgz -C /opt/moodle/public/course/format/tiles --strip-components=1 \
  && rm /tmp/tiles.tgz

# ── Production image ──

FROM php:8.3.21-apache

# System deps + PHP extensions required by Moodle
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    libzip-dev \
    libicu-dev \
    libxml2-dev \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libldap2-dev \
    libsodium-dev \
    libcurl4-openssl-dev \
    libonig-dev \
    libxslt1-dev \
    unzip \
    ghostscript \
    cron \
  && docker-php-ext-configure gd --with-freetype --with-jpeg \
  && docker-php-ext-install -j$(nproc) \
    pgsql \
    pdo_pgsql \
    zip \
    intl \
    xml \
    soap \
    gd \
    mbstring \
    bcmath \
    opcache \
    sodium \
    exif \
    xsl \
  && pecl install https://pecl.php.net/get/redis-6.3.0.tgz \
  && docker-php-ext-enable redis \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Apache config — Moodle 5.x uses public/ as webroot
RUN a2enmod rewrite headers
COPY <<'APACHECONF' /etc/apache2/sites-available/000-default.conf
<VirtualHost *:80>
    DocumentRoot /var/www/html/public
    <Directory /var/www/html/public>
        AllowOverride All
        Require all granted
    </Directory>
    <Directory /var/www/html>
        Require all denied
    </Directory>
    <Directory /var/www/html/public>
        Require all granted
    </Directory>
</VirtualHost>
APACHECONF

# Copy Moodle source from builder
COPY --from=builder /opt/moodle /var/www/html

# Keep a seed copy of plugin dirs so entrypoint can populate volumes on first run.
# Volumes for theme/ and course/format/ start empty — seeded at container start, not build time.
RUN cp -a /var/www/html/public/theme /var/www/html-src-theme \
  && cp -a /var/www/html/public/course/format /var/www/html-src-format

# Create moodledata directory (mapped to volume)
RUN mkdir -p /var/www/moodledata \
  && chown -R www-data:www-data /var/www/html /var/www/html-src-theme /var/www/html-src-format /var/www/moodledata

# PHP production config
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY <<'PHPINI' /usr/local/etc/php/conf.d/moodle.ini
upload_max_filesize = 256M
post_max_size = 256M
memory_limit = 512M
max_execution_time = 300
max_input_vars = 5000
opcache.enable = 1
opcache.memory_consumption = 128
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 60
PHPINI

# Moodle config — placed in project root (not public/), uses environment variables
COPY <<'MOODLECFG' /var/www/html/config.php
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();

// Database
$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = getenv('DB_HOST') ?: 'cryptex-pgbouncer';
$CFG->dbname    = getenv('DB_NAME') ?: 'moodle';
$CFG->dbuser    = getenv('DB_USER');
$CFG->dbpass    = getenv('DB_PASSWORD');
$CFG->prefix    = 'mdl_';

// Paths
$CFG->wwwroot   = getenv('MOODLE_URL');
$CFG->dataroot  = '/var/www/moodledata';
$CFG->directorypermissions = 02777;

// Reverse proxy (Cloudflare Tunnel)
// sslproxy: tells Moodle it's behind HTTPS terminator
// reverseproxy not needed — sslproxy handles it
$CFG->sslproxy = true;

// Portfolio showcase — public course browsing without login
// Visitors see course catalog and auto-enter as guest (no login button required)
// Per course: Participants → Enrollment methods → Guest access → enable, no password
$CFG->forcelogin = 0;
$CFG->autologinguests = 1;

// Redis session handler
$redishost = getenv('REDIS_HOST');
if ($redishost) {
    $CFG->session_handler_class = '\core\session\redis';
    $CFG->session_redis_host = $redishost;
    $CFG->session_redis_port = getenv('REDIS_PORT') ?: 6379;
    $CFG->session_redis_database = 2;  // DB 0 = reserved, DB 2 = Moodle sessions
    $redisauth = getenv('REDIS_PASSWORD');
    if ($redisauth) { $CFG->session_redis_auth = $redisauth; }
    $CFG->session_redis_prefix = 'moodle_sess_';
    $CFG->session_redis_acquire_lock_timeout = 120;
    $CFG->session_redis_lock_expire = 7200;
}

// SMTP
$smtphost = getenv('SMTP_HOST');
if ($smtphost) {
    $CFG->smtphosts = $smtphost . ':' . (getenv('SMTP_PORT') ?: '587');
    $CFG->smtpsecure = getenv('SMTP_SECURITY') ?: 'tls';
    $CFG->smtpuser = getenv('SMTP_USER') ?: '';
    $CFG->smtppass = getenv('SMTP_PASSWORD') ?: '';
    $CFG->noreplyaddress = getenv('SMTP_USER') ?: 'noreply@example.com';
}

// Performance
$CFG->cachedir = '/var/www/moodledata/cache';
$CFG->localcachedir = '/tmp/moodlelocalcache';
$CFG->tempdir = '/var/www/moodledata/temp';

// Admin
$CFG->admin = 'admin';

require_once(__DIR__ . '/lib/setup.php');
MOODLECFG

RUN chown www-data:www-data /var/www/html/config.php

# Entrypoint — handles first-run install, cron, upgrades
COPY <<'ENTRYPOINT' /entrypoint.sh
#!/bin/bash
set -e

# Ensure moodledata subdirs exist
mkdir -p /var/www/moodledata/{cache,temp,sessions,filedir,lang,localcache}
chown -R www-data:www-data /var/www/moodledata
mkdir -p /tmp/moodlelocalcache
chown www-data:www-data /tmp/moodlelocalcache

# Seed plugin volumes from image on first run.
# Volumes for theme/ and course/format/ are mounted empty on fresh deploys.
# Copy baked-in plugins so the LMS works without requiring a rebuild to add plugins.
# On subsequent starts, the volume already has content — skip (idempotent).
if [ -z "$(ls -A /var/www/html/public/theme 2>/dev/null)" ]; then
    echo "Seeding theme volume from image..."
    cp -a /var/www/html-src-theme/. /var/www/html/public/theme/
    chown -R www-data:www-data /var/www/html/public/theme
fi
if [ -z "$(ls -A /var/www/html/public/course/format 2>/dev/null)" ]; then
    echo "Seeding format volume from image..."
    mkdir -p /var/www/html/public/course/format
    cp -a /var/www/html-src-format/. /var/www/html/public/course/format/
    chown -R www-data:www-data /var/www/html/public/course/format
fi

# Wait for PostgreSQL
echo "Waiting for PostgreSQL..."
until php -r "
try {
    new PDO(
        'pgsql:host=' . getenv('DB_HOST') . ';port=5432;dbname=' . getenv('DB_NAME'),
        getenv('DB_USER'),
        getenv('DB_PASSWORD')
    );
    exit(0);
} catch(Exception \$e) {
    exit(1);
}
" 2>/dev/null; do
  sleep 3
done
echo "PostgreSQL ready."

# First-run install or upgrade
if [ ! -f /var/www/moodledata/.installed ]; then
    echo "Running Moodle install..."
    php /var/www/html/admin/cli/install_database.php \
        --agree-license \
        --fullname="${MOODLE_SITE_NAME:-Moodle}" \
        --shortname="${MOODLE_SITE_NAME:-Moodle}" \
        --adminuser="${MOODLE_ADMIN_USER:-admin}" \
        --adminpass="${MOODLE_ADMIN_PASSWORD:-changeme}" \
        --adminemail="${MOODLE_ADMIN_EMAIL:-admin@example.com}" \
        --lang=en \
        2>&1 || echo "Install may have already run"
    touch /var/www/moodledata/.installed
    echo "Install complete."
else
    echo "Running Moodle upgrade check..."
    php /var/www/html/admin/cli/upgrade.php --non-interactive 2>&1 || true
fi

# Portfolio showcase settings (idempotent — run each start)
php /var/www/html/admin/cli/cfg.php --name=forcelogin --set=0 2>/dev/null || true
php /var/www/html/admin/cli/cfg.php --name=autologinguests --set=1 2>/dev/null || true

# ── Theme + layout (idempotent — safe to run each start) ──
# Set Moove as active theme
php /var/www/html/admin/cli/cfg.php --name=theme --set=moove 2>/dev/null || true
# Remove theme designer mode (forces compiled CSS — faster, production-ready)
php /var/www/html/admin/cli/cfg.php --name=themedesignermode --set=0 2>/dev/null || true
# Set default course format to tiles (new courses get card layout automatically)
php /var/www/html/admin/cli/cfg.php --name=format --set=tiles --component=moodlecourse 2>/dev/null || true
# Purge theme cache so changes take effect immediately
php /var/www/html/admin/cli/purge_caches.php 2>/dev/null || true

# Moodle cron is managed by host cron via deploy.sh (docker exec)
# NOT started here — running cron inside the container causes double-execution

echo "Starting Apache..."
exec apache2-foreground
ENTRYPOINT
RUN chmod +x /entrypoint.sh

EXPOSE 80

CMD ["/entrypoint.sh"]
