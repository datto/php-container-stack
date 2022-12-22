# PHP Container Stack

Dockerfile for a base container stack for PHP web applications, especially for those that use the [Symfony](https://symfony.com/) framework.

## Unmaintained; for reference only

This repository is **not maintained**. It is intended to be useful as a reference for base container implementers, but will not be kept up to date.

## What This Offers

Use these images in the FROM line of your PHP application's Dockerfile.

Key features:

* Predictable timelines for security patches and maintenance lifetimes
* Explicit interfaces to build upon
* A single container that runs your application and speaks HTTP

See [the design documentation](design.md) for more details on how these containers were designed and why particular decisions were made.

## Images

This repository's Dockerfile provides 3 images, each layered on the last:

* nginx-php-fpm: For PHP web applications
* cookiecutter: For Symfony applications
* cookiecutter-build: For running the build steps of a Symfony application

See each image's instructions for how to build it.

All images derive FROM [Almalinux 9 Base](https://wiki.almalinux.org/containers/docker-images.html#almalinux-docker-images-variants), but this could be easily substituted for [Red Hat Universal Base Image 9](https://catalog.redhat.com/software/containers/ubi9/ubi/615bcf606feffc5384e8452e).

## Available Tags

These images are intended to be tagged based upon the PHP version (major dot minor) they were built with, specified in the `PHP_VERSION` build argument.

This can be any PHP version [available in EL9](https://access.redhat.com/support/policy/updates/rhel-app-streams-life-cycle#rhel9_application_streams), whether that be in the default repositories or in an Application Stream (the appropriate packages will be automatically chosen at build time).

At time of writing, the following tags are available:

* 8.1
* 8.0

Note that if you prefer PHP 7.4, you could change the FROM line in nginx-php-fpm to a UBI 8 container, but you would need to package `composer` for EL8 yourself.

## How to use these images

Once you've built each image according to that image's instructions, your Symfony application's Dockerfile should look something like this:

```dockerfile
FROM cookiecutter-build:8.0 as build

COPY --chown "${APP_USER}:${APP_GROUP}" .

ENV SYMFONY_ENV=dev

RUN --mount=type=ssh \
    COMPOSER_OPTS="--ignore-platform-reqs --no-interaction --no-plugins --no-scripts --prefer-dist -vvv" && \
    if [ "$SYMFONY_ENV" = "prod" ]; then \
        COMPOSER_OPTS="${COMPOSER_OPTS} --no-dev"; \
    fi && \
    composer install ${COMPOSER_OPTS} && \
    # prevent git directory from being copied in future stages
    find . -mindepth 2 -type d -name .git | xargs rm -rf

FROM cookiecutter:8.0

COPY --from build --chown "${APP_USER}:${APP_GROUP} /var/www/html/app/vendor /var/www/html/app/vendor
COPY --chown "${APP_USER}:${APP_GROUP} composer.json composer.lock ./bin ./config ./src ./public ./templates ./translations ./.env* /var/www/html/app/
```

## nginx-php-fpm

Nginx and PHP-FPM for PHP web applications.

### Provides

* A PHP runtime, whose version can be specified in the container's tag
* PHP-FPM, listening on 127.0.0.1:9000
    * Before it starts, scripts in `/usr/libexec/php-container/php-fpm/startup.d` will be run in lexical order
* An nginx web server
    * Configured with sane security defaults
    * Configured with good log formats
    * Includes additional config within the `http` scope from `/etc/nginx/conf.d/*.conf`
    * Provides a default overridable server at `/etc/nginx/conf.d/default.conf`. Overwrite this file to override.
        * Listens on port 80
        * Document root at `/var/www/html/app/public`
        * Serves static files, except for dotfiles
        * Treats the following as directory indexes `index`, `index.php`, `index.html`.
        * When a URL does not match a static file, rewrites it as `index.php$is_args$args`
        * Forwards requests for PHP to the FPM process.
        * Redirects server error pages to the nginx defaults in `/var/lib/nginx/html`
    * Includes `vts` module that outputs prometheus metrics on `/metrics`
* All logs go to stdout or stderr
* A supervisor process that correctly manages subprocesses
* All processes currently run under the `APP_USER` user and `APP_GROUP` group. These are set as ENV variables for you to override or use in downstream containers.
* `DOCUMENT_ROOT` - READONLY - Env variable pointing to the WORKDIR, or where you should place your application code

### Installing Dependencies

OS dependencies can be installed as follows:

```
RUN dnf install -y \
       hello \
       nginx \
    && dnf clean all
```

#### Package Repositories

DNF is pre-configured to install from the following repositories:

* `baseos`: AlmaLinux 9 - BaseOS
* `appstream`: AlmaLinux 9 - AppStream
* `crb`: AlmaLinux 9 - CRB
* Optionally `php:8.1` : AlmaLinux PHP Application Stream based upon the PHP version specified in the container tag
* `epel-release-9`: Extras Packages for Enterprise Linux 9
* [`php-modules-el9`](https://build.opensuse.org/project/show/isv:Datto:Backports:PHP_Extensions): Datto-maintained repositories containing packaged PHP extensions not available from UBI or EPEL

### Building

```bash
DOCKER_BUILDKIT=1 docker build --target nginx-php-fpm -t nginx-php-fpm:8.0 --build-arg PHP_VERSION=8.0
# or
podman build --target nginx-php-fpm -t nginx-php-fpm:8.0 --build-arg PHP_VERSION=8.0
```

The Dockerfile uses a build ARG `PHP_VERSION` to specify the PHP version, which defaults to 8.0.
It also uses a build ARG `NGINX_VERSION` to specify the NGINX version, which defaults to 1.20.

## cookiecutter

Container for running PHP apps written in the [Symfony](https://symfony.com/) framework.

### Provides

* A PHP runtime, whose version can be specified in the container's tag
* PHP-FPM
* Installed PHP extensions necessary to run cookiecutter apps
* An nginx web server configured as follows:
    * Listens on port 80
    * If a URL does not match a filename within the document root, it will be routed to `index.php$is_args$args` and routed through to FPM.
    * If a URL does match a filename that is not a dotfile or php file, that file will be served directly as a static resource.
    * .htaccess files are not supported.
* A `/usr/libexec/php-container/startup.d/` directory for scripts that will be run at container startup before FPM starts:
    * `10-clear-cache`: runs `bin/console cache:clear --no-warmup`. If you want to clear additional application-specific caches, please add your own scripts.
    * `90-warm-cache`: runs `bin/console cache:warmup`
* Application directories:
    * `/var/www/html/app`: where the codebase should be deployed
    * `/var/www/html/app/public`: the web server's document root
* The following environment variables, which can be customized as necessary
    * `APP_USER` and `APP_GROUP`: name of the user and group that all processes run under
    * `SYMFONY_ENV`: defaults to `prod`. Configures which Symfony environment to use.

### Building

```bash
DOCKER_BUILDKIT=1 docker build --target cookiecutter -t cookiecutter:8.0 --build-arg PHP_VERSION=8.0
# or
podman build --target cookiecutter -t cookiecutter:8.0 --build-arg PHP_VERSION=8.0
```

The Dockerfile uses a build ARG `PHP_VERSION` to specify the PHP version, which defaults to 8.0.

## cookiecutter-build

The cookiecutter container plus the OS and PHP dependencies needed to build Symfony applications.

At runtime, please use the `cookiecutter` images rather than these.

### Provides

* Everything provided by the cookiecutter container
* A pre-created directory at `$SRC_DIR` as the working directory for you to copy app sources into
* Pre-created directories for the destination of the source code. An `$APP_NAME` build arg is provided for running COPY in a downstream Dockerfile. It defaults to `app`, and it is not recommended to change this, because of the difficulty of passing build args between stages of multistage docker builds.
* composer
* make
* git
    * Host keys for github.com, gitlab.com, and pagure.io are already provided and trusted by git over SSH. Credentials for accessing specific repos are not baked into the container.

### Building

```bash
DOCKER_BUILDKIT=1 docker build --target cookiecutter-build -t cookiecutter-build:8.0 --build-arg PHP_VERSION=8.0
# or
podman build --target cookiecutter-build -t cookiecutter-build:8.0 --build-arg PHP_VERSION=8.0
```

The Dockerfile uses a build ARG `PHP_VERSION` to specify the PHP version, which defaults to 8.0.

## Thanks

The design of these containers is primarily the work of Daniel Axelrod, Neal Gompa, and Jonathan Roemer.

Thanks to Jason Lodice, Ben Lucas, Ryan Atkinson, Liam Morris, and Arun Philip for their contributions, suggestions, and ideas.

Thank you to the folks at Red Hat, AlmaLinux, and Fedora for maintaining the software upon which this is based.

## License

The source code in this repository is copyright 2023 Datto, Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0.

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

As with all containers, images built from this source code likely also contain other software which may be under other licenses. It is the image user's responsibility to ensure that any use of built images complies with any relevant licenses for all software contained within.
