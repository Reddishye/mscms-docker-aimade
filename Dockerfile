FROM php:8.3-fpm-bookworm AS minestore-installer

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    COMPOSER_ALLOW_SUPERUSER=1

# Install system dependencies with verbose output
RUN echo "🔧 Starting system dependencies installation..." \
 && apt-get update \
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
      jq \
 && rm -rf /var/lib/apt/lists/* \
 && echo "✅ System dependencies installed successfully"

# Install required PHP extensions INCLUDING REDIS
RUN echo "🔧 Installing PHP extensions..." \
 && docker-php-ext-configure gd --with-freetype --with-jpeg \
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
      opcache \
 && pecl install redis \
 && docker-php-ext-enable redis \
 && echo "✅ PHP extensions installed successfully" \
 && php -m | grep -E "(pdo_mysql|mysqli|mbstring|zip|gd|xml|curl|soap|bcmath|opcache|redis)"

# Configure PHP settings
RUN echo "🔧 Configuring PHP settings..." \
 && { \
      echo "memory_limit = 256M"; \
      echo "upload_max_filesize = 64M"; \
      echo "post_max_size = 64M"; \
      echo "max_execution_time = 300"; \
    } >> /usr/local/etc/php/php.ini \
 && echo "✅ PHP configuration completed"

# Install Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Install Node.js
RUN echo "🔧 Installing Node.js..." \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y nodejs \
 && npm install -g pnpm pm2 \
 && rm -rf /var/lib/apt/lists/* \
 && echo "✅ Node.js ecosystem installed"

# Create comprehensive installer script
RUN cat > /usr/local/bin/install-minestore.sh << 'EOF'
#!/usr/bin/env bash
set -e

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INSTALLER] $1"
}

log "🚀 Starting MineStoreCMS Installation with Enhanced Debugging..."

# Validate required env
log "🔍 Validating environment variables..."
: "${LICENSE_KEY:?❌ ERROR: LICENSE_KEY is required}"
: "${DB_HOST:?❌ ERROR: DB_HOST is required}"
: "${DB_PORT:?❌ ERROR: DB_PORT is required}"
log "✅ All required environment variables are set"

# Enhanced database connection check
log "⏳ Waiting for database connection on ${DB_HOST}:${DB_PORT}..."
attempt=0
max_attempts=30
until nc -z "$DB_HOST" "$DB_PORT"; do
  attempt=$((attempt + 1))
  if [ $attempt -ge $max_attempts ]; then
    log "❌ ERROR: Database connection timeout after $max_attempts attempts"
    exit 1
  fi
  log "⏳ Database connection attempt $attempt/$max_attempts - waiting..."
  sleep 5
done
log "✅ Database connection established successfully!"

# Redis connection check
log "⏳ Checking Redis connection on ${REDIS_HOST:-redis}:${REDIS_PORT:-6379}..."
until nc -z "${REDIS_HOST:-redis}" "${REDIS_PORT:-6379}"; do
  log "⏳ Waiting for Redis..."
  sleep 2
done
log "✅ Redis connection established!"

if [ ! -f "/var/www/minestore/.installed" ]; then
  log "📦 Starting MineStoreCMS download process..."
  
  cd /tmp
  log "🌐 Downloading from: https://minestorecms.com/download/v3/${LICENSE_KEY:0:8}..."
  
  if ! wget --no-check-certificate --progress=dot:mega --timeout=30 --tries=3 \
       "https://minestorecms.com/download/v3/${LICENSE_KEY}" -O minestorecms.tar.gz; then
    log "❌ ERROR: Download failed"
    exit 1
  fi
  
  if [ ! -s minestorecms.tar.gz ]; then
    log "❌ ERROR: Downloaded file is empty"
    exit 1
  fi
  
  file_size=$(stat -c%s minestorecms.tar.gz)
  log "✅ Download completed successfully - File size: ${file_size} bytes"
  
  log "📦 Extracting MineStoreCMS archive..."
  mkdir -p /var/www/minestore
  
  if ! tar -xzf minestorecms.tar.gz -C /var/www/minestore; then
    log "❌ ERROR: Failed to extract archive"
    exit 1
  fi
  
  rm -f minestorecms.tar.gz
  log "✅ MineStoreCMS extracted successfully"
  
  if [ ! -f "/var/www/minestore/composer.json" ]; then
    log "❌ ERROR: composer.json not found"
    exit 1
  fi
  
  cd /var/www/minestore
  
  # Generate .env
  log "⚙️ Generating application configuration..."
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
  log "✅ Back-end .env configured"
  
  if [ -d frontend ]; then
    cat > frontend/.env << FRONTENDEOF
NEXT_PUBLIC_API_URL="${APP_URL}"
FRONTENDEOF
    log "✅ Front-end .env configured"
    
    # Copy frontend to shared volume for the frontend container
    if [ -d "/shared" ]; then
      log "📦 Copying frontend to shared volume..."
      cp -r frontend /shared/
      log "✅ Frontend copied to shared volume"
    fi
  fi
  
  # CRITICAL: Fix Laravel IDE Helper issue
  log "🔧 Checking for Laravel IDE Helper service provider conflicts..."
  
  if [ -f "config/app.php" ]; then
    if grep -q "Barryvdh\\\\LaravelIdeHelper\\\\IdeHelperServiceProvider" config/app.php; then
      log "⚠️ Found Laravel IDE Helper in service providers - applying production fix..."
      cp config/app.php config/app.php.backup
      sed -i 's/.*Barryvdh\\LaravelIdeHelper\\IdeHelperServiceProvider.*/        \/\/ Barryvdh\\LaravelIdeHelper\\IdeHelperServiceProvider::class, \/\/ Disabled for production/' config/app.php
      log "✅ Laravel IDE Helper service provider disabled for production"
    else
      log "✅ No Laravel IDE Helper conflicts detected"
    fi
  fi
  
  log "📦 Installing PHP dependencies with enhanced error handling..."
  
  if ! composer install --no-dev --no-scripts --no-autoloader --no-interaction --ignore-platform-reqs --verbose; then
    log "❌ ERROR: Composer dependency installation failed"
    exit 1
  fi
  
  if ! composer dump-autoload --optimize --no-dev --verbose; then
    log "❌ ERROR: Autoloader generation failed"
    exit 1
  fi
  
  log "✅ PHP dependencies installed successfully"
  
  if [ -z "$APP_KEY" ]; then
    log "🔑 Generating application key..."
    if ! php artisan key:generate --force --verbose; then
      log "❌ ERROR: Failed to generate application key"
      exit 1
    fi
    log "✅ Application key generated"
  fi
  
  touch .installed
  echo "$(date)" > .installed
  log "✅ Installation completed successfully"
else
  log "ℹ️ Installation already completed (found .installed marker)"
fi

log "🛡️ Setting file permissions..."
chown -R www-data:www-data /var/www/minestore
chmod -R 755 /var/www/minestore
chmod -R 775 storage bootstrap/cache

log "🎉 MineStoreCMS installer finished successfully!"
EOF

RUN chmod +x /usr/local/bin/install-minestore.sh

WORKDIR /var/www/minestore
ENTRYPOINT ["/usr/local/bin/install-minestore.sh"]

# ===============================================
# RUNTIME STAGE - PHP-FPM for Queue Workers
# ===============================================
FROM php:8.3-fpm-bookworm AS minestore-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# Install runtime dependencies
RUN apt-get update \
 && apt-get install -y \
      curl \
      libzip-dev \
      libpng-dev \
      libjpeg-dev \
      libfreetype6-dev \
      libxml2-dev \
      libcurl4-openssl-dev \
      libonig-dev \
      libssl-dev \
      netcat-openbsd \
 && rm -rf /var/lib/apt/lists/*

# Install PHP extensions INCLUDING REDIS
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
      opcache \
 && pecl install redis \
 && docker-php-ext-enable redis

# Configure PHP for production
RUN { \
      echo "memory_limit = 256M"; \
      echo "upload_max_filesize = 64M"; \
      echo "post_max_size = 64M"; \
      echo "max_execution_time = 300"; \
      echo "opcache.enable = 1"; \
      echo "opcache.memory_consumption = 128"; \
      echo "opcache.interned_strings_buffer = 8"; \
      echo "opcache.max_accelerated_files = 4000"; \
      echo "opcache.revalidate_freq = 2"; \
      echo "opcache.fast_shutdown = 1"; \
    } >> /usr/local/etc/php/php.ini

WORKDIR /var/www/minestore

EXPOSE 9000
CMD ["php-fpm"]

# ===============================================
# PRODUCTION STAGE - Apache + PHP for Laravel (NEW!)
# ===============================================
FROM php:8.3-apache-bookworm AS minestore-production

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# Install runtime dependencies
RUN apt-get update \
 && apt-get install -y \
      curl \
      libzip-dev \
      libpng-dev \
      libjpeg-dev \
      libfreetype6-dev \
      libxml2-dev \
      libcurl4-openssl-dev \
      libonig-dev \
      libssl-dev \
      netcat-openbsd \
 && rm -rf /var/lib/apt/lists/*

# Install PHP extensions INCLUDING REDIS
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
      opcache \
 && pecl install redis \
 && docker-php-ext-enable redis

# Configure PHP for production
RUN { \
      echo "memory_limit = 256M"; \
      echo "upload_max_filesize = 64M"; \
      echo "post_max_size = 64M"; \
      echo "max_execution_time = 300"; \
      echo "opcache.enable = 1"; \
      echo "opcache.memory_consumption = 128"; \
      echo "opcache.interned_strings_buffer = 8"; \
      echo "opcache.max_accelerated_files = 4000"; \
      echo "opcache.revalidate_freq = 2"; \
      echo "opcache.fast_shutdown = 1"; \
    } >> /usr/local/etc/php/php.ini

# Configure Apache for production Laravel
RUN a2enmod rewrite \
 && a2enmod headers \
 && a2enmod ssl

# Create Apache virtual host for Laravel
RUN cat > /etc/apache2/sites-available/laravel.conf << 'EOF'
<VirtualHost *:8000>
    DocumentRoot /var/www/minestore/public
    DirectoryIndex index.php index.html
    
    <Directory /var/www/minestore/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    # Security headers
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    
    # Logging
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
    
    # Health check endpoint
    Alias /health /var/www/minestore/public/index.php
</VirtualHost>
EOF

# Enable the Laravel site and disable default
RUN a2dissite 000-default \
 && a2ensite laravel

# Change Apache to listen on port 8000
RUN sed -i 's/Listen 80/Listen 8000/' /etc/apache2/ports.conf

WORKDIR /var/www/minestore

EXPOSE 8000

# ===============================================
# FRONTEND STAGE - Next.js Frontend (PRODUCTION)
# ===============================================
FROM node:20-alpine AS minestore-frontend

# Set environment variables for PRODUCTION
ENV NODE_ENV=production \
    PORT=3000 \
    NEXT_TELEMETRY_DISABLED=1

# Install dependencies for building
RUN apk add --no-cache curl bash

# Set working directory
WORKDIR /app

# Create a simple working frontend that doesn't require build
RUN echo "🔧 Setting up lightweight frontend container..." \
 && mkdir -p pages/api \
 && echo 'import React from "react"; export default function Home() { return React.createElement("div", {}, React.createElement("h1", {}, "MineStoreCMS Frontend"), React.createElement("p", {}, "Frontend service is running in production mode.")); }' > pages/index.js \
 && echo 'export default function handler(req, res) { res.status(200).json({ status: "OK", service: "frontend", timestamp: new Date().toISOString(), mode: process.env.NODE_ENV }); }' > pages/api/health.js \
 && echo '{"name":"minestore-frontend","version":"1.0.0","scripts":{"dev":"next dev","build":"next build","start":"next start"},"dependencies":{"next":"15.0.0","react":"18.2.0","react-dom":"18.2.0"}}' > package.json \
 && echo "✅ Simple frontend structure created"

# Install dependencies using npm install (not ci) and build
RUN echo "📦 Installing dependencies..." \
 && npm install \
 && echo "🔨 Building for production..." \
 && npm run build \
 && echo "🧹 Removing unnecessary files..." \
 && rm -rf node_modules/.cache \
 && npm prune --production \
 && echo "✅ Production build completed successfully"

# Create production startup script with better error handling
RUN echo '#!/bin/bash' > /app/start.sh \
 && echo 'set -e' >> /app/start.sh \
 && echo 'echo "🚀 Starting Next.js frontend in PRODUCTION mode on port $PORT..."' >> /app/start.sh \
 && echo 'echo "📊 Node version: $(node --version)"' >> /app/start.sh \
 && echo 'echo "🏭 Environment: $NODE_ENV"' >> /app/start.sh \
 && echo '' >> /app/start.sh \
 && echo '# Check if we have a shared frontend from the installer' >> /app/start.sh \
 && echo 'if [ -f "/shared/frontend/package.json" ] && [ -d "/shared/frontend" ]; then' >> /app/start.sh \
 && echo '  echo "📦 Found shared frontend, copying and building..."' >> /app/start.sh \
 && echo '  rm -rf /app/*' >> /app/start.sh \
 && echo '  cp -r /shared/frontend/* /app/ 2>/dev/null || true' >> /app/start.sh \
 && echo '  if [ -f "package.json" ]; then' >> /app/start.sh \
 && echo '    echo "🔧 Installing shared frontend dependencies..."' >> /app/start.sh \
 && echo '    npm install' >> /app/start.sh \
 && echo '    echo "🔨 Building shared frontend for production..."' >> /app/start.sh \
 && echo '    npm run build' >> /app/start.sh \
 && echo '    echo "🧹 Cleaning up dev dependencies..."' >> /app/start.sh \
 && echo '    npm prune --production' >> /app/start.sh \
 && echo '  fi' >> /app/start.sh \
 && echo 'fi' >> /app/start.sh \
 && echo '' >> /app/start.sh \
 && echo '# Start the application' >> /app/start.sh \
 && echo 'if [ -f ".next/BUILD_ID" ]; then' >> /app/start.sh \
 && echo '  echo "✅ Production build found, starting optimized server..."' >> /app/start.sh \
 && echo '  exec npm start' >> /app/start.sh \
 && echo 'else' >> /app/start.sh \
 && echo '  echo "❌ No production build found!"' >> /app/start.sh \
 && echo '  echo "🔧 Attempting emergency build..."' >> /app/start.sh \
 && echo '  npm install && npm run build && npm prune --production' >> /app/start.sh \
 && echo '  if [ -f ".next/BUILD_ID" ]; then' >> /app/start.sh \
 && echo '    echo "✅ Emergency build successful, starting server..."' >> /app/start.sh \
 && echo '    exec npm start' >> /app/start.sh \
 && echo '  else' >> /app/start.sh \
 && echo '    echo "❌ Emergency build failed, exiting..."' >> /app/start.sh \
 && echo '    exit 1' >> /app/start.sh \
 && echo '  fi' >> /app/start.sh \
 && echo 'fi' >> /app/start.sh \
 && chmod +x /app/start.sh

# Create a non-root user
RUN addgroup -g 1001 -S nodejs \
 && adduser -S nextjs -u 1001 -G nodejs \
 && chown -R nextjs:nodejs /app

USER nextjs

EXPOSE 3000

# Production-ready health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
  CMD curl -f http://localhost:3000/api/health || exit 1

CMD ["/app/start.sh"]
