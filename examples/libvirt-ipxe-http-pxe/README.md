# libvirt-ipxe-http-pxe — PXE-boot an installer over **HTTP only**, no TFTP

Scaffolding for Dusty Mabe's two-part how-to on **easy PXE boot testing with
iPXE + libvirt** — reproduced so you can *walk through it as an experiment* on a
modern host:

- [*Easy PXE boot testing with only HTTP using iPXE and libvirt*](upstream-tutorial/2019-01-04-easy-pxe-boot-testing-http-ipxe-libvirt.html) (2019-01-04)
- [*Update … minus PXELINUX*](upstream-tutorial/2019-09-13-minus-pxelinux.html) (2019-09-13)

Both are vendored byte-exact under [`upstream-tutorial/`](upstream-tutorial/README.md).

## The gem

Setting up PXE is normally a chore because you need a **TFTP** server (plus DHCP,
plus HTTP) — three services to stand up and keep in sync. Dusty's insight:

> **libvirt's network-boot firmware _is_ iPXE, and iPXE can fetch the DHCP
> bootfile over HTTP.** So put an `http://` URL in the libvirt network's
> `<bootp file=…>` and the entire PXE flow — bootfile, kernel, initrd, kickstart,
> even the whole DVD repo — comes off a single `python3 -m http.server`. **No
> TFTP at all.**

There are two variants, and the second is the punchline:

| Variant | DHCP `<bootp file>` points at | Needs pxelinux? | Chain |
|---|---|---|---|
| **`pxelinux`** (post 1) | `http://…/pxelinux.0` | yes (`syslinux`) | DHCP → iPXE → HTTP `pxelinux.0` → `pxelinux.cfg/default` → kernel/initrd |
| **`ipxe`** (post 2) | `http://…/boot.ipxe` | **no** | DHCP → iPXE → HTTP `boot.ipxe` (`#!ipxe`) → kernel/initrd |

The `ipxe` variant drops pxelinux entirely: the bootfile *is* an iPXE script, and
libvirt's iPXE ROM runs `#!ipxe` scripts natively.

## Walk through it

You need `libvirt` + `virt-install` + `xorriso` + a **Fedora Server DVD ISO**
(any current release; the posts used Fedora 29). The bridge IP `192.168.122.1` is
libvirt's `default` network out of the box.

> **Prefer to type every command yourself?** [`RUNBOOK.md`](RUNBOOK.md) unrolls
> both scripts into the exact by-hand commands — including, front and center, how
> HTTPS is enabled in iPXE by **an edit to `config/general.h` and a recompile**.

```bash
cd examples/libvirt-ipxe-http-pxe

# 1. Stage the HTTP tree — extracts the ISO rootless (no sudo loop-mount) and
#    generates the configs for YOUR ISO name. Pick a variant:
./setup-pxe-http.sh stage --iso ~/Downloads/Fedora-Server-dvd-x86_64-41-1.4.iso --variant ipxe

# 2. Serve it (leave running in its own terminal):
./setup-pxe-http.sh serve                 # python3 -m http.server 8000

# 3. Point libvirt's default network at the HTTP bootfile. This EDITS your
#    network, so the script only PREPARES the XML + prints the commands — you run
#    them (it also backs up your current network XML first):
./setup-pxe-http.sh netxml --variant ipxe
#    → then run the printed  virsh net-destroy/net-define/net-start  commands

# 4. Launch the installer VM and watch it HTTP-boot on the serial console:
./setup-pxe-http.sh virtinstall           # prints the exact virt-install command
```

When it works, the serial console shows iPXE taking a DHCP lease, fetching the
bootfile over **HTTP**, then the kernel/initrd — e.g. (from post 2):

```text
net0: 192.168.122.216/255.255.255.0 gw 192.168.122.1
Filename: http://192.168.122.1:8000/boot.ipxe
http://192.168.122.1:8000/boot.ipxe... ok
boot.ipxe : 209 bytes [script]
Fedora-Server-dvd-x86_64-…/images/pxeboot/vmlinuz... ok
Fedora-Server-dvd-x86_64-…/images/pxeboot/initrd.img... ok
```

…and Anaconda runs the kickstart (`inst.ks=http://192.168.122.1:8000/kickstart.cfg`)
to a hands-off `@core` install. Full step-by-step with expected output and
teardown: [MANUAL_TESTING.md](MANUAL_TESTING.md).

## `setup-pxe-http.sh` verbs

| Command | Does | Touches your system? |
|---|---|---|
| `stage --iso … [--variant ipxe\|pxelinux]` | rootless-extract the ISO, generate `kickstart.cfg` + `boot.ipxe`/`pxelinux.cfg` | no (writes only under `PXE_HTTP_DIR`) |
| `serve [--port N]` | `python3 -m http.server` in the tree | no (binds a local port) |
| `netxml [--variant …]` | dump your net **read-only**, inject `<bootp>`, xmllint it, **print** the apply/restore commands | no — you run the printed `virsh` commands |
| `virtinstall` | **print** the `virt-install` command | no — you run it |
| `tree` / `clean` | show / remove the HTTP tree | `clean` removes `PXE_HTTP_DIR` |

`PXE_HTTP_DIR` (default `~/.cache/lab-create/libvirt-ipxe-http-pxe/pxeserver`)
and `--ip`/`--port` are the knobs.

## Deliberate modernizations (each surfaced by actually running it)

- **Rootless ISO staging.** The posts `sudo mount -o loop` the DVD; we **extract**
  it with `xorriso -osirrox` instead — same served tree, no root, no stale mounts.
- **`virt-install` now requires `--osinfo`.** The 2019 command errors on current
  virt-install (*"Missing --os-variant/--osinfo"*); the printed command adds
  `--osinfo detect=on,require=off`. Confirmed via `virt-install --dry-run`.
- **Any current Fedora Server DVD**, not the EOL Fedora 29. The
  `images/pxeboot/{vmlinuz,initrd.img}` layout and the kickstart directives are
  unchanged across releases; `setup-pxe-http.sh` substitutes your ISO's name.
- **Kickstart gains `network`/`timezone`.** Modern Anaconda halts a headless
  install without them; the 2019 minimal kickstart is otherwise verbatim.

## What's verified vs. yours to run

The **rootless half** is verified here (2026-07-02): ISO extraction, config
generation for both variants, that every path iPXE/Anaconda fetch returns **HTTP
200**, that the generated libvirt network XML is valid (`xmllint`) with the
`<bootp>` line injected, and that the `virt-install` invocation passes
`--dry-run`. The **libvirt half** — applying the network XML and running the VM —
mutates your `default` network and spins a guest, so it's **yours to run** (the
script prepares and prints those steps, and backs up your network first).

## Extension: HTTPS via the lab CA

Once the HTTP flow works, [`https/`](https/README.md) takes it further: fetch the
**kernel and initrd over HTTPS**, the server certificate **verified against the
shared [lab CA](../lab-ca/README.md)**. It builds a custom iPXE (modern iPXE
`#undef`s HTTPS on BIOS builds, and trusting a *private* CA needs `TRUST=`
baked in) that the stock ROM chainloads over HTTP, then does TLS the rest of the
way. The core — iPXE validating the lab-CA leaf, and **rejecting** a rogue cert —
is verified rootless in plain qemu (positive **and** negative). See
[`https/README.md`](https/README.md) and
[`https/MANUAL_TESTING-https.md`](https/MANUAL_TESTING-https.md).

## ⚠️ Security / footguns

- A **throwaway lab**: the kickstart sets `rootpw --plaintext foobar` and wipes
  the VM's disk (`zerombr` / `clearpart --all`). Fine for a scratch VM; never
  point this at real hardware or reuse the password.
- `netxml` edits libvirt's **`default`** network. The script backs up your
  current XML (`net-default.orig.xml`) and prints the one-liner to restore it —
  run that when you're done so unrelated VMs get their normal DHCP back.
- The HTTP server binds `0.0.0.0:8000` with no auth; it's only reachable from the
  libvirt NAT here, but don't run it on a hostile network.
