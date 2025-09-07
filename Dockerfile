# Dockerfile for MineStore Application Installation
FROM php:8.3-fpm-bookworm as minestore-installer

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV COMPOSER_ALLOW_SUPERUSER=1

# Install system dependencies
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

# Install required PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
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
RUN echo "memory_limit = 256M" >> /usr/local/etc/php/php.ini \
    && echo "upload_max_filesize = 64M" >> /usr/local/etc/php/php.ini \
    && echo "post_max_size = 64M" >> /usr/local/etc/php/php.ini \
    && echo "max_execution_time = 300" >> /usr/local/etc/php/php.ini

# Install Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Install Node.js 20.11.1
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm pm2

# Configure working directory
WORKDIR /var/www/minestore

# Entrypoint script for MineStore installation
COPY <<'EOF' /usr/local/bin/install-minestore.sh
#!/bin/bash
set -e
echo "🚀 Starting MineStoreCMS Installation..."

# Check required variables
if [ -z "$LICENSE_KEY" ]; then
    echo "❌ ERROR: LICENSE_KEY is required"
    exit 1
fi

# Wait for database to be available
echo "⏳ Waiting for database connection..."
until nc -z -v -w30 $DB_HOST $DB_PORT; do
    echo "⏳ Waiting for database..."
    sleep 5
done
echo "✅ Database connection established!"

# Download MineStoreCMS if not exists
if [ ! -f "/var/www/minestore/.installed" ]; then
    echo "📦 Downloading MineStoreCMS..."
    
    cd /tmp
    wget --no-check-certificate https://minestorecms.com/download/v3/$LICENSE_KEY -O minestorecms.tar.gz
    
    if [ ! -f "minestorecms.tar.gz" ]; then
        echo "❌ ERROR: Could not download MineStoreCMS. Check LICENSE_KEY"
        exit 1
    fi
    
    cd /var/www/minestore
    tar -xzf /tmp/minestorecms.tar.gz
    rm -f /tmp/minestorecms.tar.gz
    
    echo "✅ MineStoreCMS downloaded and extracted"
    
    # Install timezone extension if exists
    if [ -e timezone.so ]; then
        EXTENSION_DIR=$(php -i | grep ^extension_dir | head -n 1 | cut -d " " -f 3)
        mv timezone.so $EXTENSION_DIR/
        echo "extension=timezone" > /usr/local/etc/php/conf.d/timezone.ini
        echo "✅ Timezone extension installed"
    fi
    
    # Create .env file from environment variables (don't modify existing files)
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

# Redis configuration
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"

# Cache, Session, Queue configuration
CACHE_DRIVER="${CACHE_DRIVER:-redis}"
SESSION_DRIVER="${SESSION_DRIVER:-redis}"
QUEUE_CONNECTION="${QUEUE_CONNECTION:-redis}"

# MineStoreCMS specific configuration
PAYNOW_ENABLED="${PAYNOW_ENABLED:-}"
PAYNOW_TAX_MODE="${PAYNOW_TAX_MODE:-}"
PAYNOW_STORE_ID="${PAYNOW_STORE_ID:-}"
PAYNOW_API_KEY="${PAYNOW_API_KEY:-}"
STEAM_API_KEY="${STEAM_API_KEY:-}"
ENVEOF
    
    echo "✅ Backend .env file configured from environment variables"
    
    # Configure frontend .env
    if [ -d frontend ]; then
        cat > frontend/.env << FRONTENDEOF
NEXT_PUBLIC_API_URL="${APP_URL}"
FRONTENDEOF
        echo "✅ Frontend .env configured"
    fi
    
    # Install PHP dependencies (exclude dev dependencies that cause issues)
    echo "📦 Installing PHP dependencies..."
    composer install --no-dev --optimize-autoloader --no-interaction --ignore-platform-reqs
    
    # Generate application key if not provided
    if [ -z "$APP_KEY" ] || [ "$APP_KEY" = "" ]; then
        echo "🔑 Generating application key..."
        php artisan key:generate --force
    fi
    
    # Install frontend dependencies
    if [ -d frontend ]; then
        echo "📦 Installing frontend dependencies..."
        cd frontend
        pnpm install --production
        pnpm exec next telemetry disable
        
        # Build frontend
        echo "🔨 Building frontend..."
        pnpm run build
        cd ..
    fi
    
    # Mark as installed
    touch /var/www/minestore/.installed
    echo "✅ Installation completed"
fi

# Configure permissions
echo "🛡️ Setting up permissions..."
chown -R www-data:www-data /var/www/minestore
chmod -R 755 /var/www/minestore
chmod -R 775 storage bootstrap/cache

echo "✅ MineStore installation completed successfully!"
EOF

RUN chmod +x /usr/local/bin/install-minestore.sh

# Entry point
ENTRYPOINT ["/usr/local/bin/install-minestore.sh"]
