# anycast-dns-ram — Manual Testing

## Part 1 — health-gated anycast announce  ✅ verified (podman, 2026-07-23)

### The one-shot proof

```bash
examples/anycast-dns-ram/demo-anycast.sh
# → PASS: health-gated anycast: 10.89.7.100/32 announced while healthy,
#         withdrawn on DNS failure, re-announced on recovery
```

Real run (KVM host, rootless podman, Knot 3.4.6 / ExaBGP 4.2.25 / bird 2.17.5):

```
  - node DNS serving example.lab
  - healthy: collector sees 10.89.7.100/32 (announced)
  - unhealthy: collector no longer sees 10.89.7.100/32 (withdrawn)
  - recovered: collector sees 10.89.7.100/32 again (re-announced)
PASS: health-gated anycast: 10.89.7.100/32 announced while healthy, withdrawn on DNS failure, re-announced on recovery
```

The collector's route table while **healthy** — the anycast VIP, learned over
BGP from the node (AS65010):

```
Table master4:
10.89.7.100/32       unicast [gated ...] * (100) [AS65010i]
	via 10.89.7.10 on eth0
```

ExaBGP's health log across the toggle (the control plane *is* the health script):

```
HEALTH: up   -> announced 10.89.7.100/32
HEALTH: down -> withdrew  10.89.7.100/32      ← knotc stop
HEALTH: up   -> announced 10.89.7.100/32      ← knotd restarted
```

### Watch it live (by hand)

```bash
# Terminal A — stand up the two nodes, then leave them running:
#   (demo-anycast.sh does this; or run the podman commands from it manually)
podman exec anycast-collector birdc show route          # VIP present

# Terminal B — take DNS down, watch the route vanish at the collector:
podman exec anycast-node knotc -c /etc/anycast/knot.conf stop
sleep 5
podman exec anycast-collector birdc show route          # VIP gone

# Bring it back:
podman exec anycast-node sh -c 'chmod 0777 /var/lib/knot && knotd -c /etc/anycast/knot.conf -d'
sleep 8
podman exec anycast-collector birdc show route          # VIP back
```

### Gotchas (learned building this)

- **knotd EACCES on its pidfile in rootless podman.** knotd binds `:53` as root
  then drops `CAP_DAC_OVERRIDE`, so its rundir must be writable by the euid it
  lands on. The demo mounts `--tmpfs /var/lib/knot` and `chmod 0777`s it — a
  container-ism (a real deploy gets `/run/knot` from systemd-tmpfiles). `strace`
  shows `EACCES`, which knotd mislabels as "operation not permitted".
- **ExaBGP refuses to run as root** unless told: `env exabgp.daemon.user=root`.
- **Kill by PID / lifecycle verb, not pattern.** The demo stops DNS with
  `knotc stop` and reaps containers with `podman rm -f <name>` — never `pkill -f`.

---

## Part 2 — verified RAM-resident node image  ⏳ author-run

Building the node's RAM image needs `sudo debootstrap` (the agent Bash tool
can't sudo), so this half is **author-run**. The **verify/rollback mechanism it
relies on is fully verified** in
[`../../netboot/MANUAL_TESTING.md` §13](../../netboot/MANUAL_TESTING.md) (three
scenarios: a signed image boots, a tampered image rolls back to the prior slot,
both-tampered refuses to boot). The exact pipeline is in the header of
[`anycast-dns-chroot.toml`](anycast-dns-chroot.toml):

```
create (sudo)  →  export-initrd  →  sign-payload.sh  →  build-ipxe.sh --imgverify  →  serve  →  boot
```

Success signature once booted: the node's serial shows systemd reaching
multi-user, `knotd` answering `example.lab SOA`, and `exabgp` announcing the
anycast VIP — at which point `demo-anycast.sh`'s collector proof applies to the
real node.

---

## Cleanup

`demo-anycast.sh` tears down its own containers and network on exit (by name,
via `podman rm -f` / `podman network rm`). To remove the image:

```bash
podman image rm anycast-dns-ram
```
