# Multi-stage Dockerfile for MineStore Application
FROM php:8.3-fpm-bookworm as base

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    COMPOSER_ALLOW_SUPERUSER=1

# Install system dependencies in one layer
RUN apt-get update && apt-get install -y \
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

# Install PHP extensions in one layer
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

# Configure PHP
RUN { \
        echo "memory_limit = 512M"; \
        echo "upload_max_filesize = 64M"; \
        echo "post_max_size = 64M"; \
        echo "max_execution_time = 300"; \
        echo "max_input_vars = 3000"; \
        echo "opcache.enable=1"; \
        echo "opcache.memory_consumption=256"; \
        echo "opcache.interned_strings_buffer=8"; \
        echo "opcache.max_accelerated_files=20000"; \
        echo "opcache.revalidate_freq=2"; \
        echo "opcache.fast_shutdown=1"; \
    } > /usr/local/etc/php/conf.d/minestore.ini

# Install Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Create www-data home directory
RUN mkdir -p /var/www && chown www-data:www-data /var/www

###########################################
# INSTALLER STAGE
###########################################
FROM base as minestore-installer

# Install Node.js and tools for installation
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm pm2 \
    && rm -rf /var/lib/apt/lists/*

# Create enhanced installer script
COPY <<'EOF' /usr/local/bin/install-minestore.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Starting MineStoreCMS Installation..."

# Validate required environment variables
: "${LICENSE_KEY:?LICENSE_KEY is required}"
: "${DB_HOST:?DB_HOST is required}"
: "${DB_PORT:?DB_PORT is required}"
: "${DB_DATABASE:?DB_DATABASE is required}"
: "${DB_USERNAME:?DB_USERNAME is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"
: "${APP_URL:?APP_URL is required}"

# Wait for services
echo "⏳ Waiting for database connection..."
timeout=60
while ! nc -z "$DB_HOST" "$DB_PORT"; do
    timeout=$((timeout-1))
    if [ $timeout -eq 0 ]; then
        echo "❌ Database connection timeout"
        exit 1
    fi
    echo "⏳ Waiting for database... ($timeout seconds remaining)"
    sleep 2
done
echo "✅ Database connection established!"

if [[ -n "${REDIS_HOST:-}" ]]; then
    echo "⏳ Waiting for Redis connection..."
    timeout=30
    while ! nc -z "$REDIS_HOST" "${REDIS_PORT:-6379}"; do
        timeout=$((timeout-1))
        if [ $timeout -eq 0 ]; then
            echo "❌ Redis connection timeout"
            exit 1
        fi
        echo "⏳ Waiting for Redis... ($timeout seconds remaining)"
        sleep 2
    done
    echo "✅ Redis connection established!"
fi

# Skip installation if already done
if [ -f "/var/www/minestore/.installed" ]; then
    echo "✅ MineStoreCMS already installed, skipping..."
    exit 0
fi

echo "📦 Downloading MineStoreCMS..."
cd /tmp

# Download with better error handling
if ! wget --timeout=60 --tries=3 --no-check-certificate \
    "https://minestorecms.com/download/v3/${LICENSE_KEY}" \
    -O minestorecms.tar.gz; then
    echo "❌ ERROR: Could not download MineStoreCMS. Check your LICENSE_KEY and internet connection"
    exit 1
fi

# Verify download
if [ ! -s minestorecms.tar.gz ]; then
    echo "❌ ERROR: Downloaded file is empty. Check your LICENSE_KEY"
    exit 1
fi

# Extract application
echo "📦 Extracting MineStoreCMS..."
mkdir -p /var/www/minestore
if ! tar -xzf minestorecms.tar.gz -C /var/www/minestore; then
    echo "❌ ERROR: Could not extract MineStoreCMS archive"
    exit 1
fi
rm -f minestorecms.tar.gz
echo "✅ MineStoreCMS extracted successfully"

cd /var/www/minestore

# Generate .env file
echo "⚙️ Configuring environment..."
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

LOG_CHANNEL=stack
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=info
ENVEOF

echo "✅ Backend .env configured"

# Configure frontend if it exists
if [ -d "frontend" ]; then
    echo "⚙️ Configuring frontend environment..."
    cat > frontend/.env << FRONTENDEOF
NEXT_PUBLIC_API_URL="${APP_URL}"
NODE_ENV=production
FRONTENDEOF
    echo "✅ Frontend .env configured"
fi

# Install PHP dependencies
echo "📦 Installing PHP dependencies..."
if ! composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist; then
    echo "❌ ERROR: Failed to install PHP dependencies"
    exit 1
fi

# Generate application key if not provided
if [ -z "${APP_KEY:-}" ]; then
    echo "🔑 Generating application key..."
    php artisan key:generate --force --no-interaction
fi

# Install and build frontend if it exists
if [ -d "frontend" ] && [ -f "frontend/package.json" ]; then
    echo "📦 Installing frontend dependencies..."
    cd frontend
    
    if ! pnpm install --prod --frozen-lockfile; then
        echo "❌ ERROR: Failed to install frontend dependencies"
        exit 1
    fi
    
    pnpm exec next telemetry disable
    
    echo "🔨 Building frontend..."
    if ! pnpm run build; then
        echo "❌ ERROR: Failed to build frontend"
        exit 1
    fi
    
    cd ..
    echo "✅ Frontend built successfully"
fi

# Run database migrations
echo "🗄️ Running database migrations..."
if ! php artisan migrate --force --no-interaction; then
    echo "❌ ERROR: Database migration failed"
    exit 1
fi

# Clear and cache Laravel configuration
echo "🔧 Optimizing Laravel..."
php artisan config:clear --no-interaction || true
php artisan cache:clear --no-interaction || true
php artisan route:clear --no-interaction || true
php artisan view:clear --no-interaction || true
php artisan config:cache --no-interaction || true
php artisan route:cache --no-interaction || true
php artisan view:cache --no-interaction || true

# Set proper permissions
echo "🛡️ Setting permissions..."
chown -R www-data:www-data /var/www/minestore
chmod -R 755 /var/www/minestore
find /var/www/minestore/storage -type d -exec chmod 775 {} \;
find /var/www/minestore/bootstrap/cache -type d -exec chmod 775 {} \;
find /var/www/minestore/storage -type f -exec chmod 664 {} \;
find /var/www/minestore/bootstrap/cache -type f -exec chmod 664 {} \;

# Mark installation as complete
touch .installed
echo "✅ MineStoreCMS installation completed successfully!"
EOF

RUN chmod +x /usr/local/bin/install-minestore.sh

WORKDIR /var/www/minestore
ENTRYPOINT ["/usr/local/bin/install-minestore.sh"]

###########################################
# RUNTIME STAGE
###########################################
FROM base as minestore-runtime

# Create startup script for runtime services
COPY <<'EOF' /usr/local/bin/start-runtime.sh
#!/usr/bin/env bash
set -euo pipefail

echo "⏳ Waiting for MineStore installation to complete..."
while [ ! -f /var/www/minestore/.installed ]; do
    sleep 5
done

cd /var/www/minestore

# Run Laravel optimizations
echo "🔧 Running Laravel optimizations..."
php artisan config:clear --no-interaction || true
php artisan cache:clear --no-interaction || true
php artisan config:cache --no-interaction || true

# Ensure proper permissions
chown -R www-data:www-data /var/www/minestore
chmod -R 755 /var/www/minestore
find storage -type d -exec chmod 775 {} \; 2>/dev/null || true
find bootstrap/cache -type d -exec chmod 775 {} \; 2>/dev/null || true

echo "✅ Runtime initialization complete"

# Start PHP-FPM
exec php-fpm
EOF

RUN chmod +x /usr/local/bin/start-runtime.sh

WORKDIR /var/www/minestore
EXPOSE 9000
CMD ["/usr/local/bin/start-runtime.sh"]

###########################################
# FRONTEND STAGE
###########################################
FROM node:20-alpine as minestore-frontend

WORKDIR /var/www/minestore

# Create frontend startup script
COPY <<'EOF' /usr/local/bin/start-frontend.sh
#!/bin/sh
set -e

echo "⏳ Waiting for MineStore installation to complete..."
while [ ! -f /var/www/minestore/.installed ]; do
    sleep 5
done

cd /var/www/minestore

# Check if frontend exists and is built
if [ -d "frontend" ] && [ -f "frontend/package.json" ]; then
    cd frontend
    
    # Install pnpm if not available
    if ! command -v pnpm >/dev/null 2>&1; then
        npm install -g pnpm
    fi
    
    # Check if already built
    if [ ! -d ".next" ]; then
        echo "📦 Installing frontend dependencies..."
        pnpm install --prod --frozen-lockfile
        pnpm exec next telemetry disable
        echo "🔨 Building frontend..."
        pnpm run build
    fi
    
    echo "🚀 Starting frontend server..."
    exec pnpm start
else
    echo "⚠️  Frontend not found, creating placeholder..."
    mkdir -p /tmp/frontend
    cd /tmp/frontend
    
    cat > package.json << 'PKGEOF'
{
  "name": "minestore-frontend-placeholder",
  "version": "1.0.0",
  "scripts": {
    "start": "node server.js"
  }
}
PKGEOF
    
    cat > server.js << 'SERVEREOF'
const http = require('http');
const server = http.createServer((req, res) => {
    res.writeHead(200, {'Content-Type': 'text/html'});
    res.end(`
        <!DOCTYPE html>
        <html>
        <head>
            <title>MineStore Loading</title>
            <style>
                body { font-family: Arial, sans-serif; text-align: center; margin-top: 50px; }
                .loading { color: #666; }
            </style>
        </head>
        <body>
            <h1>MineStore Frontend</h1>
            <p class="loading">Frontend is loading...</p>
            <p>If this persists, check if the frontend was properly built during installation.</p>
        </body>
        </html>
    `);
});
server.listen(3000, () => {
    console.log('Frontend placeholder running on port 3000');
});
SERVEREOF
    
    exec node server.js
fi
EOF

RUN chmod +x /usr/local/bin/start-frontend.sh

EXPOSE 3000
CMD ["/usr/local/bin/start-frontend.sh"]
