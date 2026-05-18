# TRAX LRS 3 — ARM64 custom build
# Laravel-based xAPI Learning Record Store

FROM php:8.2.29-apache

# Install system deps + PHP extensions
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    unzip \
    curl \
    libpq-dev \
    libzip-dev \
    libicu-dev \
    libxml2-dev \
  && docker-php-ext-install \
    pdo_pgsql \
    pgsql \
    zip \
    intl \
    xml \
    bcmath \
    opcache \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Apache: enable mod_rewrite
RUN a2enmod rewrite

# Set document root to Laravel public/
RUN sed -ri -e 's|/var/www/html|/var/www/html/public|g' /etc/apache2/sites-available/000-default.conf
RUN echo '<Directory /var/www/html/public>\n\
    AllowOverride All\n\
    Require all granted\n\
</Directory>' > /etc/apache2/conf-available/laravel.conf \
  && a2enconf laravel

WORKDIR /var/www/html

# Clone TRAX LRS 3 starter — pinned to v3.1 (Dec 2025)
# To upgrade: change --branch below to a newer tag from:
#   https://github.com/trax-project/trax3-starter-lrs/tags
RUN git clone --depth 1 --branch v3.1 https://github.com/trax-project/trax3-starter-lrs.git . \
  && composer install --no-dev --optimize-autoloader --no-interaction

# Set permissions
RUN chown -R www-data:www-data /var/www/html \
  && chmod -R 775 storage bootstrap/cache

# PHP production tuning
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
RUN echo 'upload_max_filesize = 64M\n\
post_max_size = 64M\n\
memory_limit = 256M\n\
max_execution_time = 120\n\
opcache.enable = 1\n\
opcache.memory_consumption = 128\n\
opcache.max_accelerated_files = 10000' > /usr/local/etc/php/conf.d/traxlrs.ini

# Entrypoint script — handles DB wait, migrations, admin user creation
RUN cat > /entrypoint.sh << 'ENTRY'
#!/bin/bash
set -e

# Ensure Laravel storage directories exist (volume mount replaces storage/)
mkdir -p storage/framework/{sessions,views,cache} storage/logs
chown -R www-data:www-data storage bootstrap/cache

# Generate .env from Docker environment variables (Laravel requires this file)
cat > /var/www/html/.env << EOF
APP_NAME="TRAX LRS"
APP_ENV=${APP_ENV:-production}
APP_KEY=${APP_KEY}
APP_DEBUG=${APP_DEBUG:-false}
APP_URL=${APP_URL}

DB_CONNECTION=${DB_CONNECTION:-pgsql}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT:-5432}
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}

ADMIN_EMAIL=${ADMIN_EMAIL:-admin@traxlrs.com}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-aaaaaaaa}
DEFAULT_ENDPOINT_USERNAME=${DEFAULT_ENDPOINT_USERNAME:-traxlrs}
DEFAULT_ENDPOINT_PASSWORD=${DEFAULT_ENDPOINT_PASSWORD:-aaaaaaaa}

LOG_CHANNEL=stack
LOG_LEVEL=error

SESSION_DRIVER=file
CACHE_DRIVER=file
QUEUE_CONNECTION=sync
EOF
chown www-data:www-data /var/www/html/.env

# Wait for PostgreSQL
echo "Waiting for PostgreSQL..."
until php -r "
try {
    new PDO(
        'pgsql:host=' . getenv('DB_HOST') . ';port=' . getenv('DB_PORT') . ';dbname=' . getenv('DB_DATABASE'),
        getenv('DB_USERNAME'),
        getenv('DB_PASSWORD')
    );
    echo 'DB OK';
    exit(0);
} catch(Exception \$e) {
    exit(1);
}
" 2>/dev/null; do
  sleep 3
done

# Generate key if not set via env
if [ -z "$APP_KEY" ] || [ "$APP_KEY" = "base64:" ]; then
  php artisan key:generate --force
fi

# Run migrations
php artisan migrate --force --no-interaction

# Create admin user on first run (idempotent — checks if user exists)
if [ -n "$ADMIN_EMAIL" ] && [ -n "$ADMIN_PASSWORD" ]; then
    php artisan tinker --execute="
        use App\Models\User;
        if (!User::where('email', env('ADMIN_EMAIL'))->exists()) {
            User::create([
                'name' => 'Admin',
                'email' => env('ADMIN_EMAIL'),
                'password' => bcrypt(env('ADMIN_PASSWORD')),
                'admin' => true,
            ]);
            echo 'Admin user created.';
        } else {
            echo 'Admin user exists.';
        }
    " 2>/dev/null || echo "Admin user creation skipped (may need manual setup)"
fi

# Cache config
php artisan config:cache
php artisan route:cache

# Start Apache
exec apache2-foreground
ENTRY
RUN chmod +x /entrypoint.sh

EXPOSE 80

CMD ["/entrypoint.sh"]
