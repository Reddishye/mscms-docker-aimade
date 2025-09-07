# Dockerfile for MineStore Application - Complete Multi-Stage Build
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

# Install required PHP extensions with verbose output
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
 && echo "✅ PHP extensions installed successfully"

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
RUN echo "🔧 Verifying Composer installation..." \
 && composer --version \
 && echo "✅ Composer ready"

# Install Node.js 20.x + pnpm and pm2
RUN echo "🔧 Installing Node.js and package managers..." \
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

if [ ! -f "/var/www/minestore/.installed" ]; then
  log "📦 Starting MineStoreCMS download process..."
  
  cd /tmp
  log "🌐 Downloading from: https://minestorecms.com/download/v3/${LICENSE_KEY:0:8}..."
  
  if ! wget --no-check-certificate --progress=dot:mega --timeout=30 --tries=3 \
       "https://minestorecms.com/download/v3/${LICENSE_KEY}" -O minestorecms.tar.gz; then
    log "❌ ERROR: Download failed. Checking connection and license key..."
    exit 1
  fi
  
  if [ ! -s minestorecms.tar.gz ]; then
    log "❌ ERROR: Downloaded file is empty. Invalid LICENSE_KEY or server error"
    exit 1
  fi
  
  file_size=$(stat -c%s minestorecms.tar.gz)
  log "✅ Download completed successfully - File size: ${file_size} bytes"
  
  if ! file minestorecms.tar.gz | grep -q "gzip compressed"; then
    log "❌ ERROR: Downloaded file is not a valid gzipped archive"
    exit 1
  fi
  
  log "📦 Extracting MineStoreCMS archive..."
  mkdir -p /var/www/minestore
  
  if ! tar -xzf minestorecms.tar.gz -C /var/www/minestore; then
    log "❌ ERROR: Failed to extract archive"
    exit 1
  fi
  
  rm -f minestorecms.tar.gz
  log "✅ MineStoreCMS extracted successfully"
  
  if [ ! -f "/var/www/minestore/composer.json" ]; then
    log "❌ ERROR: composer.json not found - invalid archive structure"
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
  
  log "🔧 Step 1: Installing dependencies without scripts..."
  if ! composer install --no-dev --no-scripts --no-autoloader --no-interaction --ignore-platform-reqs --verbose; then
    log "❌ ERROR: Composer dependency installation failed"
    composer diagnose
    exit 1
  fi
  
  log "🔧 Step 2: Generating optimized autoloader..."
  if ! composer dump-autoload --optimize --no-dev --verbose; then
    log "❌ ERROR: Autoloader generation failed"
    exit 1
  fi
  
  log "✅ PHP dependencies installed successfully"
  
  critical_files=("vendor/autoload.php" "artisan" "bootstrap/app.php")
  for file in "${critical_files[@]}"; do
    if [ ! -f "$file" ]; then
      log "❌ ERROR: Critical file missing: $file"
      exit 1
    fi
  done
  
  if [ -z "$APP_KEY" ]; then
    log "🔑 Generating application key..."
    if ! php artisan key:generate --force --verbose; then
      log "❌ ERROR: Failed to generate application key"
      exit 1
    fi
    log "✅ Application key generated"
  fi
  
  if [ -d frontend ]; then
    log "📦 Installing front-end dependencies..."
    cd frontend
    if ! pnpm install --prod --verbose; then
      log "❌ ERROR: Frontend dependency installation failed"
      exit 1
    fi
    pnpm exec next telemetry disable
    log "🔨 Building front-end application..."
    if ! pnpm run build; then
      log "❌ ERROR: Frontend build failed"
      exit 1
    fi
    cd ..
    log "✅ Frontend built successfully"
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
# RUNTIME STAGE - PHP-FPM for Laravel Backend
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

# Install PHP extensions
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

# Copy application from installer stage
COPY --from=minestore-installer --chown=www-data:www-data /var/www/minestore /var/www/minestore

WORKDIR /var/www/minestore

# Ensure proper permissions
RUN chown -R www-data:www-data /var/www/minestore \
 && chmod -R 755 /var/www/minestore \
 && chmod -R 775 storage bootstrap/cache

EXPOSE 9000

CMD ["php-fpm"]

# ===============================================
# FRONTEND STAGE - Node.js for Next.js Frontend
# ===============================================
FROM node:20-alpine AS minestore-frontend

# Set environment variables
ENV NODE_ENV=production \
    PORT=3000 \
    NEXT_TELEMETRY_DISABLED=1

# Install dependencies for building
RUN apk add --no-cache \
    curl \
    bash

# Set working directory
WORKDIR /app

# Wait for installation to complete and copy frontend
COPY --from=minestore-installer /var/www/minestore/frontend /app

# Verify frontend exists and install dependencies
RUN echo "🔧 Setting up Next.js frontend..." \
 && if [ -f "package.json" ]; then \
      echo "✅ Found package.json, installing dependencies..."; \
      npm ci --only=production --silent; \
      echo "✅ Frontend dependencies installed"; \
    else \
      echo "⚠️ No package.json found, creating minimal Next.js app..."; \
      npm init -y; \
      npm install next@latest react@latest react-dom@latest --save; \
      mkdir -p pages; \
      echo 'export default function Home() { return <div><h1>MineStoreCMS Frontend</h1><p>Frontend service is running</p></div> }' > pages/index.js; \
      echo 'export default function Health() { return <div>OK</div> }' > pages/health.js; \
      echo '{"scripts":{"dev":"next dev","build":"next build","start":"next start"}}' > package.json; \
      npm run build; \
      echo "✅ Minimal frontend created"; \
    fi

# Create health check endpoint if it doesn't exist
RUN mkdir -p pages/api \
 && if [ ! -f "pages/api/health.js" ]; then \
      echo 'export default function handler(req, res) { res.status(200).json({ status: "OK", service: "frontend" }) }' > pages/api/health.js; \
    fi

# Create startup script
RUN echo '#!/bin/bash' > /app/start.sh \
 && echo 'echo "🚀 Starting Next.js frontend on port $PORT..."' >> /app/start.sh \
 && echo 'echo "📊 Node version: $(node --version)"' >> /app/start.sh \
 && echo 'echo "📦 NPM version: $(npm --version)"' >> /app/start.sh \
 && echo 'if [ -f ".next/BUILD_ID" ]; then' >> /app/start.sh \
 && echo '  echo "✅ Build found, starting production server..."' >> /app/start.sh \
 && echo '  exec npm start' >> /app/start.sh \
 && echo 'else' >> /app/start.sh \
 && echo '  echo "⚠️ No build found, running in development mode..."' >> /app/start.sh \
 && echo '  exec npm run dev' >> /app/start.sh \
 && echo 'fi' >> /app/start.sh \
 && chmod +x /app/start.sh

# Create a non-root user for security
RUN addgroup -g 1001 -S nodejs \
 && adduser -S nextjs -u 1001 -G nodejs \
 && chown -R nextjs:nodejs /app

USER nextjs

EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD curl -f http://localhost:3000/api/health || exit 1

CMD ["/app/start.sh"]
