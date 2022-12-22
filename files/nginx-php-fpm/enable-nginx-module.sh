#!/bin/sh

nginx_version="${1}"

el_release_major="$(. /etc/os-release; echo "${VERSION_ID}" | cut -d '.' -f 1)"
if [ "${el_release_major}" = 8 ]
then
  dnf module enable -y "${nginx_version}"
elif [ "${el_release_major}" = 9 ] && [ "${nginx_version}" = "1.20" ]
then
  true
  # Nothing to do, nginx 1.20 is in the distro with no app stream at this version
elif [ "${el_release_major}" = 9 ]
then
  dnf module enable -y "nginx:${nginx_version}"
fi
