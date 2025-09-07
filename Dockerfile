# Dockerfile for MineStore Application Installation
FROM php:8.3-fpm-bookworm AS minestore-installer

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    COMPOSER_ALLOW_SUPERUSER=1

# Install system dependencies
RUN apt-get update \
 && apt-get install -y \
      curl \
      wget \
      unzip \
      zip \
      git \
      netcat-openbsd \
      tzdata \
      libzip-dev \
      libpng-dev \
      libjpeg-dev \
      libfreetype6-dev \
      libxml2-dev \
      libcurl4-openssl-dev \
      libonig-dev \
      libssl-dev \
 && rm -rf /var/lib/apt/lists/*

# Install required PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-install -j"$(nproc)" \
      pdo_mysql \
      mysqli \
      mbstring \
      zip \
      gd \
      xml \
      curl \
      soap \
      bcmath \
      opcache

# Configure PHP settings
RUN { \
      echo "memory_limit = 256M"; \
      echo "upload_max_filesize = 64M"; \
      echo "post_max_size = 64M"; \
      echo "max_execution_time = 300"; \
    } >> /usr/local/etc/php/php.ini

# Install Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Install Node.js 20.x + pnpm and pm2
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y nodejs \
 && npm install -g pnpm pm2 \
 && rm -rf /var/lib/apt/lists/*

# Create installer script
RUN cat > /usr/local/bin/install-minestore.sh << 'EOF'
#!/usr/bin/env bash
set -e

echo "🚀 Starting MineStoreCMS Installation..."

# Validate required env
: "${LICENSE_KEY:?LICENSE_KEY is required}"
: "${DB_HOST:?DB_HOST is required}"
: "${DB_PORT:?DB_PORT is required}"

echo "⏳ Waiting for database connection..."
until nc -z "$DB_HOST" "$DB_PORT"; do
  echo "⏳ Waiting for database..."
  sleep 5
done
echo "✅ Database connection established!"

if [ ! -f "/var/www/minestore/.installed" ]; then
  echo "📦 Downloading MineStoreCMS..."
  cd /tmp
  wget --no-check-certificate "https://minestorecms.com/download/v3/${LICENSE_KEY}" -O minestorecms.tar.gz

  if [ ! -s minestorecms.tar.gz ]; then
    echo "❌ ERROR: Could not download MineStoreCMS. Check LICENSE_KEY"
    exit 1
  fi

  mkdir -p /var/www/minestore
  tar -xzf minestorecms.tar.gz -C /var/www/minestore
  rm -f minestorecms.tar.gz
  echo "✅ MineStoreCMS downloaded"

  # Install timezone extension if provided
  if [ -f timezone.so ]; then
    EXT_DIR=$(php -i | awk '/^extension_dir/ {print $3}')
    mv timezone.so "$EXT_DIR/"
    echo "extension=timezone" > /usr/local/etc/php/conf.d/timezone.ini
    echo "✅ Timezone extension installed"
  fi

  cd /var/www/minestore

  # Generate .env
  cat > .env << ENVEOF
APP_NAME="${APP_NAME:-MineStoreCMS}"
APP_ENV="${APP_ENV:-production}"
APP_KEY="${APP_KEY:-}"
APP_DEBUG="${APP_DEBUG:-false}"
APP_URL="${APP_URL}"
DB_CONNECTION=mysql
DB_HOST="${DB_HOST}"
DB_PORT="${DB_PORT}"
DB_DATABASE="${DB_DATABASE}"
DB_USERNAME="${DB_USERNAME}"
DB_PASSWORD="${DB_PASSWORD}"
TIMEZONE="${TIMEZONE:-UTC}"
LOCALE="${LOCALE:-en}"
LICENSE_KEY="${LICENSE_KEY}"
INSTALLED=0
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
CACHE_DRIVER="${CACHE_DRIVER:-redis}"
SESSION_DRIVER="${SESSION_DRIVER:-redis}"
QUEUE_CONNECTION="${QUEUE_CONNECTION:-redis}"
PAYNOW_ENABLED="${PAYNOW_ENABLED:-}"
PAYNOW_TAX_MODE="${PAYNOW_TAX_MODE:-}"
PAYNOW_STORE_ID="${PAYNOW_STORE_ID:-}"
PAYNOW_API_KEY="${PAYNOW_API_KEY:-}"
STEAM_API_KEY="${STEAM_API_KEY:-}"
ENVEOF

  echo "✅ Back-end .env configured"

  # Front-end .env
  if [ -d frontend ]; then
    mkdir -p frontend
    cat > frontend/.env << FRONTENDEOF
NEXT_PUBLIC_API_URL="${APP_URL}"
FRONTENDEOF
    echo "✅ Front-end .env configured"
  fi

  echo "📦 Installing PHP deps..."
  composer install --no-dev --optimize-autoloader --no-interaction --ignore-platform-reqs

  if [ -z "$APP_KEY" ]; then
    echo "🔑 Generating application key..."
    php artisan key:generate --force
  fi

  if [ -d frontend ]; then
    echo "📦 Installing front-end deps..."
    cd frontend
    pnpm install --prod
    pnpm exec next telemetry disable
    echo "🔨 Building front-end..."
    pnpm run build
    cd ..
  fi

  touch .installed
  echo "✅ Installation complete"
fi

echo "🛡️ Setting permissions..."
chown -R www-data:www-data /var/www/minestore
chmod -R 755 /var/www/minestore
chmod -R 775 storage bootstrap/cache
echo "✅ Installer finished"
EOF

RUN chmod +x /usr/local/bin/install-minestore.sh

WORKDIR /var/www/minestore
ENTRYPOINT ["/usr/local/bin/install-minestore.sh"]
