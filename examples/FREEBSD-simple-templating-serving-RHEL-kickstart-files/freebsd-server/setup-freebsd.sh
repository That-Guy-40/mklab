#!/bin/sh
# setup-freebsd.sh — provision the FreeBSD "www" box as the AlmaLinux install
# server. RUN THIS AS root ON THE FreeBSD VM (nuageinit does NOT install packages
# for us — see WALKTHROUGH.md). Typical use, from the host after the VM is up:
#
#   scp -P 2222 -i <key> freebsd-server/setup-freebsd.sh freebsd@127.0.0.1:/tmp/
#   ssh -p 2222 -i <key> freebsd@127.0.0.1 'su -'          # password: freebsd
#   # then, as root:
#   sh /tmp/setup-freebsd.sh
#
# Idempotent. Tunables (env or edit):
LAN_IF="${LAN_IF:-vtnet1}"             # the socket-LAN NIC (2nd virtio NIC)
REPO_SERVER_IP="${REPO_SERVER_IP:-10.0.10.210}"
NETMASK="${NETMASK:-255.255.255.0}"
DOCROOT="${DOCROOT:-/usr/local/www/nginx}"
set -eu

echo "==> [1/5] installing nginx + cdrtools(mkisofs) + sudo"
ASSUME_ALWAYS_YES=yes pkg install -y nginx cdrtools sudo

echo "==> [2/5] passwordless sudo for the freebsd user (convenience)"
echo 'freebsd ALL=(ALL) NOPASSWD: ALL' > /usr/local/etc/sudoers.d/freebsd
chmod 440 /usr/local/etc/sudoers.d/freebsd

echo "==> [3/5] static IP $REPO_SERVER_IP on the lab LAN ($LAN_IF)"
sysrc ifconfig_${LAN_IF}="inet ${REPO_SERVER_IP} netmask ${NETMASK}"
service netif restart "${LAN_IF}" 2>/dev/null || ifconfig "${LAN_IF}" inet "${REPO_SERVER_IP}" netmask "${NETMASK}" || true

echo "==> [4/5] nginx.conf (autoindex) + docroot"
# Ship the repo docroot; the AlmaLinux tree goes under $DOCROOT/almalinux/<major>/...
mkdir -p "${DOCROOT}/almalinux"
# Install our nginx.conf if it was copied alongside; else write a minimal one.
if [ -f "$(dirname "$0")/nginx.conf" ]; then
    cp "$(dirname "$0")/nginx.conf" /usr/local/etc/nginx/nginx.conf
else
    cat > /usr/local/etc/nginx/nginx.conf <<EOF
worker_processes  1;
events { worker_connections 1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    server {
        listen       80;
        server_name  localhost;
        location / { root ${DOCROOT}; autoindex on; }
    }
}
EOF
fi
nginx -t

echo "==> [5/5] enable + (re)start nginx"
sysrc nginx_enable=YES
service nginx restart || service nginx start

echo
echo "==> done. FreeBSD www box is the install server."
echo "    docroot : ${DOCROOT}/almalinux/<major>/{BaseOS,AppStream}/<arch>/os/"
echo "    next    : populate the AlmaLinux tree with fetch-almalinux.sh, then"
echo "              run the templating engine and boot the client."
echo "    verify  : fetch -qo - http://localhost/almalinux/ | head"
