# Note: Using "latest" tag so we don't have to edit for minor version updates.
# The image itself is already scoped to major version 9.
# hadolint ignore=DL3006,DL3007
FROM quay.io/almalinuxorg/9-base AS nginx-php-fpm
ARG PHP_VERSION=8.0
ARG NGINX_VERSION=1.20
USER root

RUN mkdir -p /usr/libexec/php-container/

# Configure backport repos for PHP extensions and nginx modules not available elsewhere
COPY files/nginx-php-fpm/config/*.repo /etc/yum.repos.d/

COPY files/nginx-php-fpm/enable-*-module.sh /usr/libexec/php-container/

# Install packages
# If using Red Hat UBI, this step should also disable subscription-manager to avoid
# hitting repos that require a RHEL subscription, but this step is not necessary on Alma.
# Set PHP version DNF variable
# Enable EPEL to get supervisor
# Note that because packages within an Enterprise Linux major version maintain compatability,
# we choose not to version-lock them so that rebuilds will pull in bug- and security-fixes.
# hadolint global ignore=DL3033, DL3041
RUN echo "$PHP_VERSION" > /etc/dnf/vars/phpversion \
    && echo "$NGINX_VERSION" > /etc/dnf/vars/nginxversion \
    && dnf install -y \
        https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm \
    && /usr/libexec/php-container/enable-php-module.sh "${PHP_VERSION}"\
    && /usr/libexec/php-container/enable-nginx-module.sh "${NGINX_VERSION}"\
    && dnf install -y \
        nginx \
        nginx-mod-vts \
        php-cli \
        php-fpm \
        supervisor \
    && dnf clean all

# Configure nginx
RUN mkdir -p /etc/nginx/conf.d /etc/nginx/conf.d/default-server.d
COPY files/nginx-php-fpm/config/nginx.conf /etc/nginx/nginx.conf
COPY files/nginx-php-fpm/config/nginx-conf.d/default.conf /etc/nginx/conf.d/default.conf

# Configure PHP-FPM
RUN mkdir -p /usr/libexec/php-container/php-fpm/startup.d
COPY files/nginx-php-fpm/bin/php-container-fpm-start /usr/local/bin
COPY files/nginx-php-fpm/config/fpm-pool.conf /etc/php-fpm.d/www.conf
# We have certain settings that we want to override the defaults in php-fpm.conf
# These can't be handled in php-fpm.d because those files are included too early
COPY files/nginx-php-fpm/config/php-fpm.global.override.conf /etc/php-fpm.global.override.conf
RUN echo 'include=/etc/php-fpm.global.override.conf' >>/etc/php-fpm.conf

# Configure PHP
COPY files/nginx-php-fpm/config/php.ini /etc/php.d/custom.ini

# Configure supervisord
# WARNING: This conf.d directory is considered a private interface.
# Additional processes should almost always go in new containers rather
# than being started in this one.
COPY files/nginx-php-fpm/config/supervisord.conf /etc/supervisor/supervisord.conf
COPY files/nginx-php-fpm/config/supervisord.conf.d/* /etc/supervisor/conf.d/

# Setup document root
RUN mkdir -p /var/www/html/app/public

# Set the user and group to run under
ENV APP_USER fpm-app
ENV APP_GROUP ${APP_USER}

# Explicitly create the user and group.
# This has the benefit of failing if they already exist to ensure they aren't reused from something else.
# We create a home directory for the user because Composer will write its cache there.
RUN groupadd "${APP_GROUP}" && \
    useradd --create-home --shell=/sbin/nologin --no-user-group --gid="${APP_GROUP}" "${APP_USER}"

# Make sure files/folders needed by the processes are accessable when they run under APP_USER
# /run is not recursive because it is only needed for apps to write their pidfiles to /run/<appname>.pid
RUN chown -R "${APP_USER}:${APP_GROUP}" /var/www/html/app/public && \
  chown "${APP_USER}:${APP_GROUP}" /run && \
  chown -R "${APP_USER}:${APP_GROUP}" /var/log/nginx && \
  chown -R "${APP_USER}:${APP_GROUP}" /usr/libexec/php-container/php-fpm/startup.d

# Allow nginx to bind to port 80 even when running as APP_USER
RUN setcap 'cap_net_bind_service=+ep' /usr/sbin/nginx

# Switch to use the non-root user from here on
USER ${APP_USER}

# Add application
ENV DOCUMENT_ROOT /var/www/html/app/public
WORKDIR ${DOCUMENT_ROOT}

# Expose the port nginx is reachable on
EXPOSE 80

# Let supervisord start nginx & php-fpm
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]

FROM nginx-php-fpm as cookiecutter
USER root

# Install php extensions to support symfony apps
RUN dnf install -y \
        # symfony deps cytpe, iconv, pcre, session, tokenizer
        php-common \
        # symfony dep simplexml
        php-xml \
        php-mbstring \
        php-opcache \
        php-pecl-apcu \
        php-pecl-igbinary \
        php-pecl-yaml \
    && dnf clean all

# Set up docroot parent directory with proper permissions
# This is necessary because the codebase exists one level up from the docroot
RUN mkdir -p "/var/www/html/app" && \
    chown -R "${APP_USER}:${APP_GROUP}" "/var/www/html/app"

# Add our customizations to the default vhost
COPY files/cookiecutter/nginx-default-server/default-server-extensions.conf /etc/nginx/conf.d/default-server.d/cookiecutter-extensions.conf

# Copy over Symfony startup scripts
COPY files/cookiecutter/startup.d/* /usr/libexec/php-container/php-fpm/startup.d/

ENV SYMFONY_ENV prod

USER ${APP_USER}:${APP_GROUP}

# Re-configure the healthcheck to hit the standard Cookiecutter healthcheck URL
HEALTHCHECK --interval=5s --timeout=5s --retries=1 CMD curl --silent --fail http://127.0.0.1:80/healthcheck

FROM cookiecutter AS cookiecutter-build
USER root

# composer: PHP library dependency management. From EPEL
# git-core & unzip: used by composer during app build
# rsync: app build dependency
RUN dnf install -y \
        composer \
        git-core \
        git-lfs \
        make \
        rsync \
        unzip \
    && dnf clean all

# Trust the published host keys of github.com, gitlab.com, and pagure.io for easy cloning
COPY files/cookiecutter-build/git-known_hosts /usr/libexec/php-container/
RUN cat /usr/libexec/php-container/git-known_hosts >> /etc/ssh/ssh_known_hosts

# Position the source code so that its public subdirectory is the app root.
# For a multi-stage build, this location doesn't actually matter.
# However, for local development, it is convenient to be able to volume mount
# the source code into the correct location for it to be served directly.
# This environment variable is intended to be READ ONLY, since the server
# docroot cannot be changed.
ENV SRC_DIR /var/www/html/app

# It is recommended not to change this
ARG APP_NAME=app

# Create directories for the code destination
RUN mkdir -p "${SRC_DIR}" && \
    mkdir -p "/var/www/vhosts/${APP_NAME}" && \
    chown -R "${APP_USER}:${APP_GROUP}" "${SRC_DIR}" "/var/www/vhosts"

WORKDIR ${SRC_DIR}

USER ${APP_USER}
