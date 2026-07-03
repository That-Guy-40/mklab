#!/usr/bin/env python3
# serve-https.py — the HTTPS half of the lab: a rootless TLS file server, the
# secure sibling of `python3 -m http.server`.  Serves the staged PXE tree over
# https:// using a leaf certificate issued by the shared lab CA
# (examples/lab-ca/), so iPXE — built to TRUST that CA — fetches kernel+initrd
# over TLS.  No nginx, no root.
#
#   ./serve-https.py --cert <fullchain.crt> --key <leaf.key> \
#                    --dir <PXE_HTTP_DIR> --port 8443
import argparse, http.server, os, ssl

ap = argparse.ArgumentParser(description="rootless HTTPS file server for the PXE tree")
ap.add_argument("--cert", required=True, help="server cert (leaf or leaf+CA fullchain)")
ap.add_argument("--key", required=True, help="server private key")
ap.add_argument("--dir", default=".", help="directory to serve")
ap.add_argument("--port", type=int, default=8443)
ap.add_argument("--bind", default="0.0.0.0")
a = ap.parse_args()

os.chdir(a.dir)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(a.cert, a.key)
httpd = http.server.HTTPServer((a.bind, a.port), http.server.SimpleHTTPRequestHandler)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
print(f"HTTPS serving {os.getcwd()} on https://{a.bind}:{a.port}/  (Ctrl-C to stop)")
httpd.serve_forever()
