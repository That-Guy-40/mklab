#!/usr/bin/env python3
"""MAAS metadata + introspection sink — a tiny stdlib HTTP service.

Two jobs, both keyed by node name in the URL path (the probe/installer knows its
own name from the kernel cmdline `maas.node=<name>`):

  GET  /<node>/meta-data   NoCloud meta-data  (instance-id + local-hostname)
  GET  /<node>/user-data   NoCloud user-data  (cloud-config: hostname + SSH key)
  POST /quote/<mac>        attestation sink: the node's PCR quote, keyed by MAC
  POST /quote-sig/<mac>    its detached CMS signature (DER, binary-safe)
                           -> $STATE/<node>/quote.json{,.sig}, which
                           drivers/image-measured.sh verifies and compares to the
                           image's pcrs.expected. Keyed by MAC because a measured
                           golden image is GENERIC — every node boots the same
                           bytes, so identity must come from the machine, not from
                           something the payload could name itself.
  POST /facts/<node>       introspection sink: JSON body -> $STATE/<node>/facts.json
                           (+ a facts.received marker so `maas-lab.sh inspect` can
                           tell the probe reported back)
  GET  /                   health line

DRY fleet from one image: every node boots the same image and pulls its identity
here by name, instead of baking per-node config into per-node images (the NoCloud
pattern real MAAS/cloud-init use).

Security: binds 127.0.0.1 by default (F1 — loopback only; the real fleet binds the
PXE gateway). Writes are atomic (tmp + os.replace) and confined to $STATE/<node>/;
a node name with a path separator is rejected.
"""
import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _safe_node(name):
    # node names are simple identifiers; never let one escape the state dir
    if not name or "/" in name or "\\" in name or name in (".", ".."):
        return None
    return name


class Handler(BaseHTTPRequestHandler):
    # set by the server factory below
    state_dir = "."
    ssh_key = ""

    def log_message(self, *a):  # quiet by default; the lab owns the transcript
        if os.environ.get("MAAS_METADATA_VERBOSE"):
            super().log_message(*a)

    def _send(self, code, body, ctype="text/plain"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parts = [p for p in self.path.split("/") if p]
        if not parts:
            self._send(200, "maas-metadata: ok\n")
            return
        if len(parts) == 2 and parts[1] in ("meta-data", "user-data"):
            node = _safe_node(parts[0])
            if not node:
                self._send(400, "bad node name\n"); return
            if parts[1] == "meta-data":
                self._send(200, f"instance-id: {node}\nlocal-hostname: {node}\n")
            else:
                key_line = f"ssh_authorized_keys:\n  - {self.ssh_key}\n" if self.ssh_key else ""
                self._send(200,
                           "#cloud-config\n"
                           f"hostname: {node}\n"
                           f"{key_line}")
            return
        self._send(404, "not found\n")

    def do_POST(self):
        parts = [p for p in self.path.split("/") if p]
        if len(parts) == 2 and parts[0] == "facts":
            node = _safe_node(parts[1])
            if not node:
                self._send(400, "bad node name\n"); return
            length = int(self.headers.get("Content-Length", 0) or 0)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                facts = json.loads(raw.decode() or "{}")
            except (ValueError, UnicodeDecodeError):
                self._send(400, "facts body is not valid JSON\n"); return
            nd = os.path.join(self.state_dir, node)
            if not os.path.isdir(nd):
                self._send(404, f"no such enrolled node '{node}'\n"); return
            _atomic_write(os.path.join(nd, "facts.json"),
                          json.dumps(facts, sort_keys=True) + "\n")
            _atomic_write(os.path.join(nd, "facts.received"), "1\n")
            self._send(200, f"recorded facts for {node}\n")
            return

        # POST /quote/<mac>  and  /quote-sig/<mac>  — the attestation sink.
        #
        # KEYED BY MAC, NOT BY NODE NAME, and that is the whole design. A measured
        # golden image is GENERIC: every node boots the same bytes, so there is no
        # per-node cmdline to carry an identity, and a node that could name itself
        # could name itself as somebody else. The MAC is what the control plane
        # already recorded per node at enroll time, and it is the one identifier a
        # shared image cannot claim on another machine's behalf.
        #
        # This service does NOT judge the quote. It records what arrived, and
        # `drivers/image-measured.sh` verifies the signature against the lab CA and
        # compares the PCRs to the image's policy. A sink that decided what was
        # trustworthy would be a second, weaker copy of the gate.
        if len(parts) == 2 and parts[0] in ("quote", "quote-sig"):
            mac = _safe_mac(parts[1])
            if not mac:
                self._send(400, "bad mac\n"); return
            node = self._node_for_mac(mac)
            if not node:
                self._send(404, f"no enrolled node has mac {mac}\n"); return
            length = int(self.headers.get("Content-Length", 0) or 0)
            raw = self.rfile.read(length) if length else b""
            if not raw:
                self._send(400, "empty body\n"); return
            nd = os.path.join(self.state_dir, node)
            name = "quote.json" if parts[0] == "quote" else "quote.json.sig"
            # Binary-safe: the signature is DER, not text.
            tmp = os.path.join(nd, name + ".tmp")
            with open(tmp, "wb") as fh:
                fh.write(raw)
            os.replace(tmp, os.path.join(nd, name))
            self._send(200, f"recorded {name} for {node} ({mac})\n")
            return
        self._send(404, "not found\n")

    def _node_for_mac(self, mac):
        """Which enrolled node owns this MAC? The registry is the only authority."""
        try:
            entries = sorted(os.listdir(self.state_dir))
        except OSError:
            return None
        for n in entries:
            f = os.path.join(self.state_dir, n, "mac")
            try:
                with open(f) as fh:
                    if fh.read().strip().lower() == mac:
                        return n
            except OSError:
                continue
        return None


def _safe_mac(mac):
    """A MAC, or None. Rejects anything that could escape the state dir."""
    mac = (mac or "").strip().lower()
    if len(mac) != 17:
        return None
    parts = mac.split(":")
    if len(parts) != 6:
        return None
    for p in parts:
        if len(p) != 2 or any(c not in "0123456789abcdef" for c in p):
            return None
    return mac


def _atomic_write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="metadata.py")
    ap.add_argument("cmd", choices=["serve"])
    ap.add_argument("--state", required=True, help="the MAAS registry dir ($MAAS_STATE)")
    ap.add_argument("--port", type=int, default=8282)  # NOT 8181 (netboot nginx, :ro) / 8080 (SABnzbd)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--ssh-key", default=os.environ.get("MAAS_SSH_KEY", ""))
    args = ap.parse_args(argv)

    Handler.state_dir = os.path.abspath(args.state)
    Handler.ssh_key = args.ssh_key
    os.makedirs(Handler.state_dir, exist_ok=True)
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    host, port = httpd.socket.getsockname()[:2]
    # announce the bound port on stdout (port 0 -> ephemeral; tests read this)
    print(f"maas-metadata listening on http://{host}:{port} state={Handler.state_dir}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
