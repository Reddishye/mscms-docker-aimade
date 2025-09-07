# Dockerfile for MineStore Application Installation with Verbose Debugging
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
 && echo "✅ PHP extensions installed successfully" \
 && php -m | grep -E "(pdo_mysql|mysqli|mbstring|zip|gd|xml|curl|soap|bcmath|opcache)"

# Configure PHP settings
RUN echo "🔧 Configuring PHP settings..." \
 && { \
      echo "memory_limit = 256M"; \
      echo "upload_max_filesize = 64M"; \
      echo "post_max_size = 64M"; \
      echo "max_execution_time = 300"; \
    } >> /usr/local/etc/php/php.ini \
 && echo "✅ PHP configuration completed" \
 && cat /usr/local/etc/php/php.ini | tail -4

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
 && echo "✅ Node.js ecosystem installed" \
 && node --version && npm --version && pnpm --version && pm2 --version

# Create comprehensive installer script with verbose logging and IDE Helper fix
RUN cat > /usr/local/bin/install-minestore.sh << 'EOF'
#!/usr/bin/env bash
set -e

# Enhanced logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INSTALLER] $1"
}

log "🚀 Starting MineStoreCMS Installation with Enhanced Debugging..."

# Validate required env with detailed feedback
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
  
  # Download with detailed progress and error handling
  if ! wget --no-check-certificate --progress=dot:mega --timeout=30 --tries=3 \
       "https://minestorecms.com/download/v3/${LICENSE_KEY}" -O minestorecms.tar.gz; then
    log "❌ ERROR: Download failed. Checking connection and license key..."
    log "🔍 Attempting to ping download server..."
    if ping -c 3 minestorecms.com; then
      log "✅ Server is reachable - likely invalid LICENSE_KEY"
    else
      log "❌ Server unreachable - network issue"
    fi
    exit 1
  fi
  
  # Verify download integrity
  if [ ! -s minestorecms.tar.gz ]; then
    log "❌ ERROR: Downloaded file is empty. Invalid LICENSE_KEY or server error"
    ls -la minestorecms.tar.gz
    exit 1
  fi
  
  file_size=$(stat -c%s minestorecms.tar.gz)
  log "✅ Download completed successfully - File size: ${file_size} bytes"
  
  # Verify it's actually a gzipped tar file
  if ! file minestorecms.tar.gz | grep -q "gzip compressed"; then
    log "❌ ERROR: Downloaded file is not a valid gzipped archive"
    file minestorecms.tar.gz
    head -c 200 minestorecms.tar.gz
    exit 1
  fi
  
  log "📦 Extracting MineStoreCMS archive..."
  mkdir -p /var/www/minestore
  
  if ! tar -xzf minestorecms.tar.gz -C /var/www/minestore; then
    log "❌ ERROR: Failed to extract archive"
    tar -tzf minestorecms.tar.gz | head -10
    exit 1
  fi
  
  rm -f minestorecms.tar.gz
  log "✅ MineStoreCMS extracted successfully"
  
  # Verify extraction contents
  log "🔍 Verifying extracted contents..."
  ls -la /var/www/minestore/
  
  if [ ! -f "/var/www/minestore/composer.json" ]; then
    log "❌ ERROR: composer.json not found - invalid archive structure"
    find /var/www/minestore -name "composer.json" | head -5
    exit 1
  fi
  
  # Install timezone extension if provided
  if [ -f timezone.so ]; then
    log "🔧 Installing timezone extension..."
    EXT_DIR=$(php -i | awk '/^extension_dir/ {print $3}')
    mv timezone.so "$EXT_DIR/"
    echo "extension=timezone" > /usr/local/etc/php/conf.d/timezone.ini
    log "✅ Timezone extension installed"
  fi
  
  cd /var/www/minestore
  
  # Generate comprehensive .env file
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
  
  # Front-end .env
  if [ -d frontend ]; then
    log "⚙️ Configuring front-end environment..."
    cat > frontend/.env << FRONTENDEOF
NEXT_PUBLIC_API_URL="${APP_URL}"
FRONTENDEOF
    log "✅ Front-end .env configured"
  fi
  
  # CRITICAL: Fix Laravel IDE Helper issue before composer install
  log "🔧 Checking for Laravel IDE Helper service provider conflicts..."
  
  if [ -f "config/app.php" ]; then
    # Check if IDE Helper is registered
    if grep -q "Barryvdh\\\\LaravelIdeHelper\\\\IdeHelperServiceProvider" config/app.php; then
      log "⚠️  Found Laravel IDE Helper in service providers - applying production fix..."
      
      # Create a backup
      cp config/app.php config/app.php.backup
      
      # Comment out the IDE Helper service provider for production
      sed -i 's/.*Barryvdh\\LaravelIdeHelper\\IdeHelperServiceProvider.*/        \/\/ Barryvdh\\LaravelIdeHelper\\IdeHelperServiceProvider::class, \/\/ Disabled for production/' config/app.php
      
      log "✅ Laravel IDE Helper service provider disabled for production"
      
      # Show the change
      grep -A2 -B2 "LaravelIdeHelper" config/app.php || log "Service provider successfully commented out"
    else
      log "✅ No Laravel IDE Helper conflicts detected"
    fi
  else
    log "⚠️  config/app.php not found - skipping IDE Helper check"
  fi
  
  # Analyze composer.json for potential issues
  log "🔍 Analyzing composer dependencies..."
  if [ -f "composer.json" ]; then
    log "📄 composer.json contents:"
    cat composer.json | jq '.' 2>/dev/null || cat composer.json
    
    # Check for IDE Helper in require-dev
    if grep -q "barryvdh/laravel-ide-helper" composer.json; then
      log "⚠️  Laravel IDE Helper found in composer.json - this is expected in require-dev"
    fi
  fi
  
  log "📦 Installing PHP dependencies with enhanced error handling..."
  
  # Method 1: Install without problematic scripts, then dump autoload
  log "🔧 Step 1: Installing dependencies without scripts..."
  if ! composer install --no-dev --no-scripts --no-autoloader --no-interaction --ignore-platform-reqs --verbose; then
    log "❌ ERROR: Composer dependency installation failed"
    log "🔍 Composer diagnose output:"
    composer diagnose
    exit 1
  fi
  
  log "🔧 Step 2: Generating optimized autoloader..."
  if ! composer dump-autoload --optimize --no-dev --verbose; then
    log "❌ ERROR: Autoloader generation failed"
    exit 1
  fi
  
  log "✅ PHP dependencies installed successfully"
  
  # Verify critical files exist
  log "🔍 Verifying installation integrity..."
  critical_files=("vendor/autoload.php" "artisan" "bootstrap/app.php")
  for file in "${critical_files[@]}"; do
    if [ ! -f "$file" ]; then
      log "❌ ERROR: Critical file missing: $file"
      exit 1
    else
      log "✅ Found: $file"
    fi
  done
  
  # Generate application key if needed
  if [ -z "$APP_KEY" ]; then
    log "🔑 Generating application key..."
    if ! php artisan key:generate --force --verbose; then
      log "❌ ERROR: Failed to generate application key"
      php artisan --version
      exit 1
    fi
    log "✅ Application key generated"
  fi
  
  # Handle frontend if it exists
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
  else
    log "ℹ️  No frontend directory found - skipping frontend build"
  fi
  
  # Create installation marker
  touch .installed
  echo "$(date)" > .installed
  log "✅ Installation completed successfully"
  
else
  log "ℹ️  Installation already completed (found .installed marker)"
fi

log "🛡️ Setting file permissions..."
chown -R www-data:www-data /var/www/minestore
chmod -R 755 /var/www/minestore
chmod -R 775 storage bootstrap/cache

log "📊 Final installation summary:"
log "   - Installation directory: $(pwd)"
log "   - Disk usage: $(du -sh . | cut -f1)"
log "   - PHP version: $(php --version | head -n1)"
log "   - Composer version: $(composer --version)"
log "   - Node version: $(node --version 2>/dev/null || echo 'N/A')"

if [ -f ".installed" ]; then
  log "   - Installation date: $(cat .installed)"
fi

log "🎉 MineStoreCMS installer finished successfully!"
EOF

# Make installer executable and verify
RUN chmod +x /usr/local/bin/install-minestore.sh \
 && echo "🔧 Installer script created and made executable" \
 && ls -la /usr/local/bin/install-minestore.sh

WORKDIR /var/www/minestore

ENTRYPOINT ["/usr/local/bin/install-minestore.sh"]
