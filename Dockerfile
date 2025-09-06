# Multi-stage build for MineStoreCMS
FROM php:8.3-fpm-bookworm

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV COMPOSER_ALLOW_SUPERUSER=1

# Install system dependencies
RUN apt-get update && apt-get install -y \
    nginx \
    supervisor \
    curl \
    wget \
    unzip \
    zip \
    git \
    cron \
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

# Configure Nginx
RUN rm -f /etc/nginx/sites-enabled/default
COPY <<EOF /etc/nginx/sites-enabled/minestore.conf
server {
    listen 80;
    server_name _;
    client_max_body_size 64M;
    
    # Rate limiting
    limit_req_zone \$binary_remote_addr zone=one:40m rate=180r/m;
    limit_req zone=one burst=86 nodelay;
    
    # Frontend Next.js routes
    location /_next/static {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    location /static {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
    }
    
    # Backend Laravel routes
    location ~ ^/(admin|api|install|initiateInstallation) {
        proxy_pass http://127.0.0.1:8090;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Backend static assets
    location ~ ^/(assets|css|flags|fonts|img|js|libs|res|scss|style)/ {
        proxy_pass http://127.0.0.1:8090;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# Backend Laravel server
server {
    listen 8090;
    server_name _;
    root /var/www/minestore/public;
    index index.php;
    client_max_body_size 64M;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    
    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    
    location ~ /\. {
        deny all;
    }
}
EOF

# Configure supervisord
COPY <<EOF /etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:nginx]
command=nginx -g 'daemon off;'
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
startretries=3

[program:php-fpm]
command=php-fpm -F
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
startretries=3

[program:laravel-queue]
command=php /var/www/minestore/artisan queue:work --queue=high,standard,low,default --daemon --sleep=3 --tries=3
directory=/var/www/minestore
user=www-data
stdout_logfile=/var/log/supervisor/laravel-queue.log
stderr_logfile=/var/log/supervisor/laravel-queue.log
autorestart=true
startretries=3

[program:laravel-paynow-queue]
command=php /var/www/minestore/artisan queue:work --queue=paynow --daemon --sleep=3 --tries=3
directory=/var/www/minestore
user=www-data
stdout_logfile=/var/log/supervisor/laravel-paynow-queue.log
stderr_logfile=/var/log/supervisor/laravel-paynow-queue.log
autorestart=true
startretries=3

[program:laravel-schedule]
command=/bin/bash -c 'while true; do php /var/www/minestore/artisan schedule:run; sleep 60; done'
directory=/var/www/minestore
user=www-data
stdout_logfile=/var/log/supervisor/laravel-schedule.log
stderr_logfile=/var/log/supervisor/laravel-schedule.log
autorestart=true
startretries=3

[program:laravel-cron-worker]
command=php /var/www/minestore/artisan cron:worker
directory=/var/www/minestore
user=www-data
stdout_logfile=/var/log/supervisor/laravel-cron-worker.log
stderr_logfile=/var/log/supervisor/laravel-cron-worker.log
autorestart=true
startretries=3

[program:discord-bot]
command=php /var/www/minestore/artisan discord:run
directory=/var/www/minestore
user=www-data
stdout_logfile=/var/log/supervisor/discord-bot.log
stderr_logfile=/var/log/supervisor/discord-bot.log
autorestart=true
startretries=3

[program:frontend]
command=/bin/bash -c 'cd /var/www/minestore/frontend && pnpm start'
directory=/var/www/minestore/frontend
user=www-data
environment=NODE_ENV=production,PORT=3000
stdout_logfile=/var/log/supervisor/frontend.log
stderr_logfile=/var/log/supervisor/frontend.log
autorestart=true
startretries=3

[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock
EOF

# Configure PHP-FPM
RUN echo "listen = /run/php/php8.3-fpm.sock" >> /usr/local/etc/php-fpm.d/www.conf \
    && echo "listen.owner = www-data" >> /usr/local/etc/php-fpm.d/www.conf \
    && echo "listen.group = www-data" >> /usr/local/etc/php-fpm.d/www.conf \
    && echo "listen.mode = 0660" >> /usr/local/etc/php-fpm.d/www.conf

# Entrypoint script
COPY <<'EOF' /usr/local/bin/entrypoint.sh
#!/bin/bash
set -e

echo "🚀 Starting MineStoreCMS..."

# Check required variables
if [ -z "$LICENSE_KEY" ]; then
    echo "❌ ERROR: LICENSE_KEY is required"
    exit 1
fi

if [ -z "$APP_URL" ]; then
    echo "❌ ERROR: APP_URL is required"
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
    
    # Configure backend .env
    if [ -f .env ]; then
        sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" .env
        sed -i "s|^DB_HOST=.*|DB_HOST=${DB_HOST}|" .env
        sed -i "s|^DB_PORT=.*|DB_PORT=${DB_PORT}|" .env
        sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${DB_DATABASE}|" .env
        sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${DB_USERNAME}|" .env
        sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" .env
        sed -i "s|^TIMEZONE=.*|TIMEZONE=${TIMEZONE:-UTC}|" .env
        sed -i "s|^LICENSE_KEY=.*|LICENSE_KEY=${LICENSE_KEY}|" .env
        sed -i "s|^INSTALLED=.*|INSTALLED=1|" .env
        
        # Configure Redis if available
        if [ ! -z "$REDIS_HOST" ]; then
            sed -i "s|^REDIS_HOST=.*|REDIS_HOST=${REDIS_HOST}|" .env
            sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
            sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
            sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env
        fi
        
        echo "✅ Backend .env file configured"
    fi
    
    # Configure frontend .env
    if [ -f frontend/.env ]; then
        sed -i "s|^NEXT_PUBLIC_API_URL=.*|NEXT_PUBLIC_API_URL=${APP_URL}|" frontend/.env
        echo "✅ Frontend .env configured"
    elif [ -d frontend ]; then
        echo "NEXT_PUBLIC_API_URL=${APP_URL}" > frontend/.env
        echo "✅ Frontend .env created"
    fi
    
    # Install PHP dependencies
    echo "📦 Installing PHP dependencies..."
    composer install --no-dev --optimize-autoloader --no-interaction
    
    # Generate application key
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

cd /var/www/minestore

# Run migrations
echo "🗄️ Running database migrations..."
php artisan migrate --force

# Optimize application
echo "⚡ Optimizing application..."
php artisan config:clear
php artisan cache:clear
php artisan route:clear
php artisan view:clear
php artisan config:cache
php artisan route:cache
php artisan view:cache

# Configure permissions
echo "🛡️ Setting up permissions..."
chown -R www-data:www-data /var/www/minestore
chmod -R 755 /var/www/minestore
chmod -R 775 storage bootstrap/cache
mkdir -p /run/php
chown www-data:www-data /run/php

# Configure timezone
if [ ! -z "$TIMEZONE" ]; then
    ln -snf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    echo $TIMEZONE > /etc/timezone
fi

echo "✅ Configuration completed. Starting services..."

exec "$@"
EOF

RUN chmod +x /usr/local/bin/entrypoint.sh

# Create required directories
RUN mkdir -p /var/log/supervisor /run/php

# Expose port
EXPOSE 80

# Entry point
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
