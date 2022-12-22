# Design

## Supply Chain

Many popular base containers combine software from a large number of different vendors, often including a distribution and the upstream projects of each of their components. This presents a number of challenges:

* When a vulnerability is discovered in a component, how is it handled and on what schedule will it be fixed? The answer is likely different for each upstream and also requires additional actions on the part of the base container maintainer.
* How long will a particular tag of the container be maintained? This is often not an explicit guarantee on the part of the container maintainer.
* When making a container that layers on top of the base container, how do I install software that is missing? If the container was constructed from a combination of package managers and source-based installations, downstream consumers may not be able to use any single installation method to install system-level dependencies.

This container stack attempts to solve all of the above by getting all components from as few vendors as possible.

### Updates and Maintenance - Enterprise Linux

| Vendor | Security Update Schedule | Maintenance Schedule |
| - | - | - |
| RHEL UBI 9 Base | [Within days for Critical and Important vulnerabilities, every 6 weeks otherwise](https://access.redhat.com/articles/2208321) | [Until May 2032. If PHP 8.1 is chosen instead of 8.0, until May 2025](https://access.redhat.com/support/policy/updates/rhel-app-streams-life-cycle) |
| AlmaLinux Base EL9 | [One business day after RHEL](https://wiki.almalinux.org/Comparison.html) | [Same as RHEL](https://wiki.almalinux.org/Comparison.html) |
| EPEL 9 | ["In a timely manner"](https://fedoraproject.org/wiki/Category:Security_Team#Security_Response_2) | As long as they have a maintainer. This is often the entire supported lifecycle of an EL major release. (Note also that Datto engineers maintain some software in EPEL and could take over needed packages.) |
| [Our own backports](https://build.opensuse.org/project/subprojects/isv:Datto:Backports) | An internal team maintains these according to our internal security policies. Note that the public Datto Backports repositories should be considered reference and are not guaranteed to be updated. | An internal team maintains these for the same lifetime as the other software in the container. Again, the public Datto Backports repositories should be considered reference and are not guaranteed to be updated. |

To summarize, when people in our organization use these containers, they are guaranteed a security patch cadence and a maintenance duration that they can then use to keep their security commitments to their stakeholders.

### PHP Upgrade Path

An additional benefit of Enterprise Linux is that starting with EL8, there are multiple simultaneous maintained PHP versions on top of the same versions of the rest of the software in the OS, via [Application Streams](https://www.redhat.com/en/blog/introduction-appstreams-and-modules-red-hat-enterprise-linux).

This allows gradual upgrades of PHP versions on a per-application basis. Across a large enough number of applications, it is always necessary to have at least two supported versions: an older one, and the one everyone plans to upgrade to.

### Package Management - DNF

In all cases, software is installed via DNF, ensuring that projects that layer on top of these base containers can install additional software via DNF with proper dependency resolution and metadata.

Note that PHP extensions in particular benefit from a dependency-resolving package manager. Some PHP extensions that depend upon others require not only installing dependent extensions at the correct versions, but also loading their `.so`s in the correct order in PHP's `.ini`s. PHP extensions are packaged in Enterprise Linux in such a way that the package manager automatically handles all of this.

(A specific historical example of this is that `apcu_bc` provided `apcu.so`, and depended upon `apcu`, which provided `apc.so` but `php.ini` must specify that `apc.so` is loaded before `apcu.so` or symbols will not resolve correctly.)

### Updating These Images

We have deliberately chosen not to have reproducible builds for a particular tag. Instead, we prioritize being able to periodically rebuild a container at a particular tag in order to take advantage of security updates, in a way that maintains compatibility with downstream software.

This allows these base containers to be periodically rebuilt in order to ensure that they remain up to date, and allows downstream projects to either use periodic or event-based rebuilds to keep this software up to date as well.

## Interfaces

Base container images are intended to be built upon and extended. This makes them akin to software libraries in that they should present documented, public interfaces and should be clear about compatibility guarantees at a given version.

## Choice of libc - glibc

It was a deliberate choice to build these containers on a base that uses [glibc](https://www.gnu.org/software/libc/) rather than [musl libc](https://musl.libc.org/). PHP has various runtime compatibility issues with musl, and many PHP extensions tend not to support musl either.

## Multiple Processes

There should be a single concern per container. Ideally, this means that at runtime, each container runs a single process. The design of these containers differ: each container runs nginx and php-fpm.

There are several reasons for this:

* For most languages, the common design is to have a single web application process in a container that speaks HTTP using a library integrated into that language. At the time these containers were designed, no such HTTP server existed for PHP that was suitable to use outside of a development context, even if it were reverse-proxied by another HTTP server. Having PHP containers speak HTTP like all other language containers makes it easier to re-use higher level abstractions around them, like common helm charts when deployed to Kubernetes. In addition, PHP applications tend to be tightly coupled to the configuration of their HTTP servers.
* We wanted it to be possible to develop a simple application using only a container runtime like Podman or Docker without getting an orchestrator like Kubernetes or Docker-Compose involved. This can substantially simplify new developers' environment setup.
* PHP FPM already introduces a multiprocess model, so we were already forced to have more than one process per container.

When running multiple processes in a container, the one run by `ENTRYPOINT` or `CMD` gets PID 1, and it is therefore responsible for handling signals and reaping zombie processes. See any of [these](https://github.com/krallin/tini/issues/8#issuecomment-146135930) [excellent](https://blog.phusion.nl/2015/01/20/docker-and-the-pid-1-zombie-reaping-problem/) [writeups](https://github.com/docker-library/official-images#init) for more information.

We therefore run an `init` process as PID 1.

### Choice of Init - supervisord

We have chosen [supervisord](http://supervisord.org/) as a simple but extensible init system for these containers. It is [not](https://developers.redhat.com/blog/2016/09/13/running-systemd-in-a-non-privileged-container) [easy](https://developers.redhat.com/blog/2019/04/24/how-to-run-systemd-in-a-container) to run systemd in a container, especially a non-privileged one, because it is built around managing its own cgroups, among other problems. We considered [tini](https://github.com/krallin/tini) but found the additional configuration that supervisord gave us around redirecting file descriptors and other runtime configuration useful. We also rejected solutions like `docker run --init` (which injects tini) because we did not want the container to require additional outside software or configuration to run correctly.

### Limitations on Scaling

There are scenarios, especially in Kubernetes, where it is useful to be able to scale nginx processes separately from php-fpm processes. Therefore, in practice, some of our applications use base containers derived from these but with php-fpm and nginx in separate containers in the same pod.

## Symfony Cache

The scripts in `/usr/libexec/php-container/startup.d/` clear and warm the Symfony cache at container startup.

We have made the odd choice to do this at startup rather than container build time because Symfony may cache configuration files, including those that contain secrets. Even if files containing configuration secrets are available at build time, this prevents the possibility of them leaking into the built container image. This preserves the property that container images should never contain secrets; secrets should only be added in at runtime.

The cache clear script would normally be a no-op. It exists for development scenarios when source code directories (including the Symfony cache directory) are mounted into the container.

Cache clearing and warming are separated into different scripts so that additional application specific scripts can be inserted between them.

If you are building your application container image in an environment like CI where you know configuration will never be accidentally present, and therefore there is no danger of including secrets in the container image, you can do the following to move the cache warm behavior to container build time:

```dockerfile
RUN rm /usr/libexec/php-container/startup.d/10-clear-cache \
    && rm /usr/libexec/php-container/startup.d/90-warm-cache \
    && XDEBUG_MODE=off APP_DEBUG=0 php bin/console cache:clear --no-interaction
```
