FROM php:8.3-cli-bookworm

ARG SEMGREP_VERSION=1.136.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        jq \
        libonig-dev \
        libsqlite3-dev \
        libxml2-dev \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        unzip \
    && docker-php-ext-install -j"$(nproc)" dom mbstring pdo_sqlite simplexml soap \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2.8 /usr/bin/composer /usr/local/bin/composer

RUN python3 -m venv /opt/semgrep \
    && /opt/semgrep/bin/pip install --no-cache-dir "semgrep==${SEMGREP_VERSION}"

ENV PATH="/opt/semgrep/bin:${PATH}" \
    PHP_MEMORY_LIMIT=1024M \
    COMPOSER_ALLOW_SUPERUSER=1

WORKDIR /opt/wp-audit
COPY tools /opt/wp-audit/tools
COPY contracts /opt/wp-audit/contracts

RUN composer install \
      --working-dir=/opt/wp-audit/tools \
      --no-interaction \
      --prefer-dist \
      --optimize-autoloader \
    && composer check-platform-reqs --working-dir=/opt/wp-audit/tools \
    && mkdir -p /opt/wp-audit/reports/phase1 /opt/wp-audit/reports/logs /opt/wp-audit/data \
    && chmod -R a+rwX /opt/wp-audit/reports /opt/wp-audit/data

COPY tools/docker/wp-audit-tools /usr/local/bin/wp-audit-tools
RUN chmod 0755 /usr/local/bin/wp-audit-tools

ENTRYPOINT ["wp-audit-tools"]
CMD ["help"]
