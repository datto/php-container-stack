#!/bin/sh

php_version="${1}"

el_release_major="$(. /etc/os-release; echo "${VERSION_ID}" | cut -d '.' -f 1)"
if [ "${el_release_major}" = 8 ]
then
  dnf module enable -y "${php_version}"
elif [ "${el_release_major}" = 9 ] && [ "${php_version}" = "8.0" ]
then
  true
  # Nothing to do, php 8.0 is in the distro with no app stream at this version
elif [ "${el_release_major}" = 9 ]
then
  dnf module enable -y "php:${php_version}"
fi
