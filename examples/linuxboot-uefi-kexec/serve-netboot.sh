#!/usr/bin/env bash
# serve-netboot.sh — bring up (or tear down) the netboot server u-root fetches the
# installer kernel/initrd (+ kickstart/preseed) from.
#
#   ./serve-netboot.sh [up|down|status]          # HTTP  on :8181  (P1)
#   ./serve-netboot.sh [up|down|status] --tls     # HTTPS on :8443  (P2, lab-CA cert)
#
# HTTP mode reuses the repo's rootless podman netboot server verbatim
# (examples/podman-netboot-server.toml — nginx:alpine, ~/netboot → :8181).
#
# TLS mode (P2) serves the SAME ~/netboot over HTTPS on :8443 with a server cert
# issued by the shared lab CA (examples/lab-ca). u-root's `pxeboot` has no https
# scheme, but its `wget` does (Go SystemCertPool) — so the P2 boot fetches with
# `wget https://…` (trusting the lab CA baked into the ROM's initramfs) and boots via
# the `kexec` command. See POC-PXEBOOT-P2.md. It's a direct rootless `podman run`
# (not a TOML) because it mounts host-specific cert + conf paths.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TOML="$REPO/examples/podman-netboot-server.toml"
LP="$REPO/phase4-podman/lab-podman.sh"
LABCA="$REPO/examples/lab-ca"
NETBOOT_DIR="${NETBOOT_DIR:-$HOME/netboot}"
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
TLS_CN="${TLS_CN:-10.0.2.2}"; TLS_PORT="${TLS_PORT:-8443}"
TLS_NAME="lab-netboot-tls"

# --- arg parse: a verb (up/down/status) + optional --tls ---
TLS=0; VERB=""
for a in "$@"; do case "$a" in
  --tls) TLS=1 ;; up|down|status) VERB="$a" ;;
  *) echo "usage: $0 [up|down|status] [--tls]" >&2; exit 1 ;;
esac; done
VERB="${VERB:-up}"

# ============================ HTTP (:8181) — P1 ============================
if [[ "$TLS" -eq 0 ]]; then
  case "$VERB" in
    up)   echo "==> :8181 netboot server (HTTP, reuses podman-netboot-server.toml)"
          "$LP" up --config "$TOML"; sleep 1
          curl -fsI http://127.0.0.1:8181/vmlinuz >/dev/null 2>&1 \
            && echo "==> :8181 serving $NETBOOT_DIR" || echo "warn: :8181 not answering yet" ;;
    down) "$LP" down --config "$TOML" ;;
    status) curl -fsI http://127.0.0.1:8181/vmlinuz >/dev/null 2>&1 \
              && echo ":8181 up" || { echo ":8181 not serving"; exit 1; } ;;
  esac
  exit 0
fi

# ============================ HTTPS (:8443) — P2 ============================
CERT="$LABCA/private/certs/$TLS_CN-fullchain.crt"
KEY="$LABCA/private/certs/$TLS_CN.key"
CONF="$WORKDIR/netboot-tls.conf"

case "$VERB" in
  up)
    # 1. ensure the shared lab CA + a server cert for $TLS_CN exist (idempotent)
    [[ -f "$LABCA/lab-ca.crt" ]] || "$LABCA/make-ca.sh" >/dev/null
    [[ -f "$CERT" && -f "$KEY" ]] || "$LABCA/issue-server-cert.sh" "$TLS_CN" netboot.lab >/dev/null
    # 2. generate the nginx TLS server block (autoindex so wget can browse the tree)
    mkdir -p "$WORKDIR"
    cat > "$CONF" <<EOF
server {
    listen $TLS_PORT ssl;
    server_name $TLS_CN netboot.lab;
    ssl_certificate     /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;
    root /usr/share/nginx/html;
    autoindex on;
}
EOF
    # 3. rootless nginx:alpine serving ~/netboot over HTTPS with the lab-CA cert
    podman rm -f "$TLS_NAME" >/dev/null 2>&1 || true
    echo "==> :$TLS_PORT netboot server (HTTPS, lab-CA cert for $TLS_CN)"
    podman run -d --rm --name "$TLS_NAME" -p "$TLS_PORT:$TLS_PORT" \
      -v "$NETBOOT_DIR:/usr/share/nginx/html:ro" \
      -v "$CERT:/etc/nginx/certs/server.crt:ro" \
      -v "$KEY:/etc/nginx/certs/server.key:ro" \
      -v "$CONF:/etc/nginx/conf.d/default.conf:ro" \
      docker.io/library/nginx:alpine >/dev/null
    sleep 1
    if curl -fsI --cacert "$LABCA/lab-ca.crt" --resolve "$TLS_CN:$TLS_PORT:127.0.0.1" \
         "https://$TLS_CN:$TLS_PORT/vmlinuz" >/dev/null 2>&1; then
      echo "==> :$TLS_PORT serving $NETBOOT_DIR over HTTPS (verified vs lab-ca.crt, no -k)"
    else echo "warn: :$TLS_PORT not answering yet (podman logs $TLS_NAME)"; fi ;;
  down)   podman rm -f "$TLS_NAME" >/dev/null 2>&1 && echo "==> stopped $TLS_NAME" || echo "not running" ;;
  status) curl -fsI --cacert "$LABCA/lab-ca.crt" --resolve "$TLS_CN:$TLS_PORT:127.0.0.1" \
            "https://$TLS_CN:$TLS_PORT/vmlinuz" >/dev/null 2>&1 \
            && echo ":$TLS_PORT up (HTTPS, lab-CA verified)" || { echo ":$TLS_PORT not serving"; exit 1; } ;;
esac
