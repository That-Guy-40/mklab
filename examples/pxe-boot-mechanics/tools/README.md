# pxe-boot-mechanics — transport probes

Tools for poking at the **transport** half of a PXE boot by hand — TFTP and
HTTP(S) — so you can *watch* the individual fetches a netboot does for you
invisibly, and record/replay them. They're companions to the labs one level up
([`../vm-pxe-tftp-boot.toml`](../vm-pxe-tftp-boot.toml),
[`../vm-pxe-secureboot.toml`](../vm-pxe-secureboot.toml)): those boot a VM the
real way; these let you reproduce each step in isolation.

```
tools/
├── pxe-fetch.sh          native, dependency-light probe (curl-based)
├── socwrap.sh            vendored interactive REPL w/ macros + asciicast record/replay
├── macros/
│   ├── pxe-fetch.json    lab-tailored: drive iPXE's kernel/initrd HTTP GETs by hand
│   ├── http-protocol.json  generic HTTP/1.1 cheat-sheet (reference)
│   └── tftp.json           generic TFTP client cheat-sheet (reference)
└── README.md
```

Two tools on purpose: **`pxe-fetch.sh`** is the quick truth-teller (one command,
no deps beyond `curl`); **`socwrap.sh`** is the guided, *recordable* walkthrough
for when you want a replayable session.

---

## Where to run these (read this first)

A PXE *client* and the *artifact server* sit at different network vantage
points, and in this lab they are **not** reachable the same way. Run the probes
from the **host**, acting as the client — not from the server:

| Transport | Served by | Reachable from the host as |
|---|---|---|
| **HTTP(S)** | nginx in the podman/docker netboot container | `http://localhost:8181` (TLS: `https://localhost:8443`) |
| **TFTP** (QEMU lab) | QEMU **slirp's built-in** TFTP, inside the VM's NAT | **not reachable** — only the VM's firmware sees `tftp://10.0.2.2` |
| **TFTP** (real-HW) | the **dnsmasq ProxyDHCP+TFTP** container (`../../../netboot/setup-dhcp-tftp.sh`) | `tftp://localhost:69` |

> **`10.0.2.2` is the QEMU slirp gateway** — that address only resolves *inside*
> a slirp VM. From the host, the same nginx is on `localhost`. `pxe-fetch.sh`
> rewrites `10.0.2.2` → your `--server` automatically in `from-ipxe` mode.

Start an artifact server before probing, e.g.
[`../../podman-netboot-server.toml`](../../podman-netboot-server.toml)
(HTTP on 8181). For the TFTP target, bring up the dnsmasq container per
[`../../../netboot/MANUAL_TESTING.md`](../../../netboot/MANUAL_TESTING.md) §11.4.

---

## `pxe-fetch.sh` — quick probe

```bash
# What is actually being served? (HEAD sweep of common artifact names)
tools/pxe-fetch.sh probe

# Replay the EXACT kernel/initrd GETs your iPXE will do (authoritative):
tools/pxe-fetch.sh from-ipxe ~/netboot/boot.ipxe

# GET specific paths, show request + real response headers:
tools/pxe-fetch.sh http /vmlinuz /initrd.img

# TFTP-fetch ipxe.efi the way firmware does (needs the dnsmasq TFTP server up):
tools/pxe-fetch.sh tftp ipxe.efi --host localhost

# HTTPS (self-signed/snakeoil server from MANUAL_TESTING §10):
tools/pxe-fetch.sh probe --tls          # → https://localhost:8443, curl -k

# Record a session for later playback (uses asciinema if present, else script(1)):
tools/pxe-fetch.sh --record /tmp/probe.cast from-ipxe ~/netboot/boot.ipxe
```

Modes: `probe` (default) · `http` · `from-ipxe FILE` · `tftp [FILE...]`.
Run `tools/pxe-fetch.sh --help` for all options (`--server`, `--tls`, `--save`,
`--host`/`--port`, `--record`). It's `curl`-only; the `tftp` mode needs a `curl`
built with TFTP support (`curl -V | grep tftp`).

## `socwrap.sh` — guided, recordable walkthrough

For a stepped, narrated session you can record as an
[asciicast](https://docs.asciinema.org/manual/asciicast/v2/) and replay:

```bash
cd examples/pxe-boot-mechanics/tools

# Hand-type iPXE's HTTP fetches over a raw TCP connection, with macros:
./socwrap.sh --macros --macro-file macros/pxe-fetch.json --crlf -t localhost 8181
#   //set HOST localhost   //set KERNEL /vmlinuz   //set INITRD /initrd.img
#   //demo-bootipxe        # fetch boot.ipxe and read it back
#   //demo-chain           # boot.ipxe → kernel → initrd, the whole HTTP sequence
#   //help                 # the full macro list

# Record the same session, then replay it (no asciinema needed — built in):
./socwrap.sh --record walk.cast --macros --macro-file macros/pxe-fetch.json --crlf -t localhost 8181
./socwrap.sh --replay walk.cast --replay-speed 2

# TFTP client flow (binary UDP — driven via the real tftp client, not raw socat):
./socwrap.sh --macros --macro-file macros/tftp.json -p 'tftp> ' -- tftp
```

### Provenance of the vendored bits

`socwrap.sh` and `macros/{tftp,http-protocol}.json` are vendored **verbatim**
(byte-identical) from the author's `socat`-wrapper project — `socwrap.sh` is
its Phase 7 build (`7.0.0-phase7`, the one with session record/replay),
`tftp.json` and `http-protocol.json` are its protocol-macro cheat-sheets. They
live here so this lab is self-contained and reproducible. `macros/pxe-fetch.json`
is new and specific to this lab. To refresh the vendored copies, re-copy from
the upstream project and re-run `tools/pxe-fetch.sh`/`socwrap.sh --list-macros`
to confirm they still load.

### Tooling on this kind of host

`curl` (with `tftp://`), `socat`, `jq`, and `script(1)` are typically present.
The standalone **`tftp` client** and **`asciinema`** often are **not** — so
prefer `pxe-fetch.sh tftp` (curl) over the `tftp.json` client flow unless you
install a tftp client, and note that `socwrap.sh --record/--replay` needs
*neither* (its asciicast support is built in).

---

## ⚠️ Security

These are **lab** tools for **authorized, isolated** networks. TFTP and plain
HTTP have no authentication; the HTTPS demo path uses a **snakeoil** test key
with no real trust (see [`../README.md`](../README.md)). Don't point them at
hosts you don't own, and don't bridge the netboot network to anything untrusted.
