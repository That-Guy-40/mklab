# Hand-walk: *IPC, network & time namespaces*, by hand, in a box

Follow Thomas Van Laere's **[*Exploring Containers - Part 2*](upstream-tutorial/)**
inside a disposable Alpine container. Part 1 showed that a chroot is *not* a
boundary and pointed at namespaces; this part walks three of them directly:
**IPC** (isolate System V shared memory), **network** (build a veth+bridge
topology between namespaces), and **time** (give a process its own clock offset).

- **The post (byte-exact archive):** [`upstream-tutorial/`](upstream-tutorial/) ·
  canonical: <https://thomasvanlaere.com/posts/2020/08/exploring-containers-part-2/>
- **The environment as code:** [`Containerfile`](Containerfile) — **latest Alpine**
  + `build-base` + `iproute2` + `iptables` + `util-linux`. (Why not 3.11 like
  Part 1? See §5 — the time namespace needs a newer `unshare` than 3.11 ships,
  the very reason the *author* reached to Alpine edge back in 2020.)
- **The IPC programs:** [`processA.c`](processA.c) / [`processB.c`](processB.c) —
  the author's verbatim.

> **Verification split (read this first).** Everything here runs in a rootless
> `--privileged` podman box **except** three steps that need real
> (init-user-namespace) root, which rootless podman does not grant: the `ip netns`
> form of the bridge demo (needs a sysfs remount), the outbound **NAT** rule, and
> nothing else. Where a step hits that wall, this runbook says so and gives a
> **rootless-friendly equivalent** that *is* verified in this box (see
> [`MANUAL_TESTING.md`](MANUAL_TESTING.md) for captured output). The `# →` lines
> below are this box's real output.

---

## 0. Bring up the box

The post runs `docker run -it --name docker-sandbox --rm --privileged alpine:3.11`.
We build the same *kind* of environment with the repo's Phase-4 tool and launch it
`--privileged` (the post's flag; the network and time demos need `CAP_NET_ADMIN` /
`CAP_SYS_ADMIN`).

```bash
# from the repo root:
phase4-podman/lab-podman.sh build --tag ec-part2 \
    --context examples/exploring-containers/part-2-namespaces
podman run --rm -it --privileged ec-part2 /bin/sh
```

---

## 1. IPC namespace — isolate System V shared memory

The post writes two tiny C programs: **`processA`** writes a message into a System
V shared-memory segment (keyed by `ftok(".", 0x01)`), and **`processB`** reads it
back and then removes the segment. Both are already in the box at `/root`; compile
them:

```sh
gcc processA.c -o processA
gcc processB.c -o processB
# → warning: comparison between pointer and integer   (the author's own code —
#   shmat() returns a pointer; the (== -1) check is harmless here, it still runs)
```

In the **host** IPC namespace, A writes and B reads it:

```sh
./processA "Hello from $$"
./processB
# → Reading shared memory:
# → Hello from 1
# → Shared memory removed
```

Now write again, but read from a **new IPC namespace** — the segment A created is
invisible; B in the new namespace gets a *fresh, empty* one:

```sh
./processA "Hello from $$"
unshare --ipc ./processB
# → Reading shared memory:
# →                          ← EMPTY. Different IPC namespace = different SysV space.
# → Shared memory removed
```

**Why this is the lesson.** IPC objects (SysV shm/semaphores/message queues) are
scoped to an IPC namespace. Two processes share them only if they share the
namespace; `unshare --ipc` gives you a private one, so the same `ftok` key resolves
to a different segment. That's how a container's IPC can't collide with the host's.

---

## 2. Network namespace — a private, empty network stack

```sh
unshare --net sh
ip -br link
# → lo    DOWN    00:00:00:00:00:00 <LOOPBACK>     ← a brand-new stack: only lo, and it's DOWN
ping -c1 127.0.0.1
# → ping: sendto: Network unreachable              ← even loopback needs bringing up
ip link set lo up
ping -c1 127.0.0.1
# → 1 packets transmitted, 1 packets received, 0% packet loss
exit
```

**Why.** A network namespace is a *complete, independent* copy of the kernel's
network stack — its own interfaces, routes, iptables, sockets. A fresh one has
nothing but a down `lo`. Everything a container "has" on the network, something
had to put there.

---

## 3. Network namespace — wire two of them together with veth + a bridge

This is the heart of container networking: **veth pairs** (a virtual cable — two
ends; a packet in one comes out the other) plus a **bridge** (a virtual switch)
to join namespaces. The post uses persistent, *named* namespaces via `ip netns`:

```sh
# ---- THE AUTHOR'S FORM (ip netns) — needs ROOTFUL podman; see the note below ----
ip netns add mynetns
ip netns add myothernetns
ip link add veth1 type veth peer name br-veth1
ip link set veth1 netns mynetns
ip netns exec mynetns ip addr add 10.0.0.11/24 dev veth1
# … veth2 into myothernetns at 10.0.0.12/24 …
ip link add br0 type bridge
ip link set br-veth1 master br0
ip link set br-veth2 master br0
ip addr add dev br0 10.0.0.10/24
ip link set br0 up      # + bring every veth end up, + lo in each netns
ip netns exec myothernetns ping -c3 10.0.0.11
```

> **⚠️ Rootless wall.** `ip netns add` bind-mounts the new namespace under
> `/run/netns` **and remounts `/sys`** to reflect it — and remounting sysfs needs
> `CAP_SYS_ADMIN` in the **initial** user namespace, which rootless podman does not
> have even with `--privileged`. So in this box the very first `ip netns add`
> fails:
> ```
> mount of /sys failed: Operation not permitted
> ```
> Run the box **rootful** (`sudo podman run --privileged …`) and the author's
> `ip netns` commands work verbatim. Below is the **rootless-friendly equivalent**
> that reaches the identical end state *in this box* — same veth pairs, same
> bridge, same cross-namespace ping.

```sh
# ---- ROOTLESS-FRIENDLY FORM (unshare + nsenter) — verified in this box ----
# Two anonymous net namespaces, held open by a backgrounded sleeper each:
unshare --net sleep 600 & P1=$!
unshare --net sleep 600 & P2=$!

ip link add br0 type bridge                       # the switch, in our main ns
ip link add veth1 type veth peer name br-veth1    # cable 1
ip link add veth2 type veth peer name br-veth2    # cable 2
ip link set veth1 netns $P1                        # far end of cable 1 -> ns1
ip link set veth2 netns $P2                        # far end of cable 2 -> ns2
ip link set br-veth1 master br0                     # near ends -> the bridge
ip link set br-veth2 master br0
ip addr add 10.0.0.10/24 dev br0; ip link set br0 up
ip link set br-veth1 up; ip link set br-veth2 up

# configure each namespace's end via nsenter (setns into the holder's net ns):
nsenter -t $P1 -n sh -c 'ip addr add 10.0.0.11/24 dev veth1; ip link set veth1 up; ip link set lo up'
nsenter -t $P2 -n sh -c 'ip addr add 10.0.0.12/24 dev veth2; ip link set veth2 up; ip link set lo up'

nsenter -t $P2 -n ping -c2 10.0.0.11
# → 2 packets transmitted, 2 packets received, 0% packet loss   ← ns2 reaches ns1 across the bridge
kill $P1 $P2
```

**Why the swap is legitimate.** `ip netns` is just sugar for "create a net
namespace and *persist* it as a file you can name." `unshare --net` creates the
same kind of namespace; `ip link set … netns <pid>` and `nsenter -t <pid> -n` name
it by the **PID** of a process living in it instead of by a `/run/netns/<name>`
file — so we never remount sysfs, and never touch the wall. The kernel objects
(veth, bridge, the isolation) are identical.

---

## 4. Network namespace — reach the outside (NAT) · author-run, rootful

The post's last network step lets a namespace reach the real internet by enabling
IP forwarding and masquerading its source address on the way out:

```sh
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -j MASQUERADE
ip -all netns exec ip route add default via 10.0.0.10
ip -all netns exec ping -c3 8.8.8.8
```

> **⚠️ Author-run, rootful.** Applying an `iptables` NAT rule and having outbound
> packets actually egress needs real root + a routable uplink. Under **rootless**
> podman the container's own outbound path is itself a userspace shim
> (`slirp4netns`), so nested MASQUERADE to `8.8.8.8` is not meaningful here. Run
> the box **rootful** to reproduce this step; it is documented, not claimed as
> verified in this rootless lab.

---

## 5. Time namespace — give a process its own uptime

The newest namespace here (mainlined in **Linux 5.6**, 2020). It virtualizes
`CLOCK_MONOTONIC` and `CLOCK_BOOTTIME` offsets — so a process can believe the
machine booted at a different time.

```sh
uptime
# → 16:38:13 up 18:10, …
unshare --time --boottime 86400 uptime
# → 16:38:13 up 1 day, 18:10, …          ← +86400s (24h) added to boot time, only in here
unshare --time --boottime 86400 cat /proc/self/timens_offsets
# → monotonic           0         0
# → boottime        86400         0
```

> **⚠️ Era-divergence — why this box is *not* Alpine 3.11.** The time namespace
> needs `unshare` from **util-linux ≥ 2.36**. Alpine 3.11 ships **2.34** (no
> `--time`), so in 2020 the author did:
> ```sh
> apk add --repository http://dl-cdn.alpinelinux.org/alpine/edge/main util-linux=2.36
> ```
> **That command is dead in 2026:** Alpine edge rotated its package-signing key, so
> a 3.11 box now rejects the edge repo with `WARNING: … UNTRUSTED signature` and
> silently keeps 2.34; and `=2.36` is long gone from edge anyway. Rather than pin a
> vanished version through an untrusted repo, this lab simply uses a **current
> Alpine** (3.23), whose util-linux (2.41) has `--time` built in — the author's
> *intent*, reproducibly. The kernel side is unconditional: this host is 6.8 and
> `/proc/self/ns/time` exists.
>
> Bonus (ties to Part 3): the time namespace also works **rootless, no
> `--privileged`**, if you create it inside a user namespace where you hold
> `CAP_SYS_ADMIN`:
> `unshare --user --map-root-user --time --boottime 86400 uptime`.

---

## 6. Tear down & provenance

`exit` the `--rm` box and everything — the namespaces, the compiled programs —
vanishes.

```bash
podman rmi ec-part2          # drop the image when done
```

- **Provenance.** The archived post under [`upstream-tutorial/`](upstream-tutorial/)
  is the work of **Thomas Van Laere**; all rights remain with the author.
  [`processA.c`](processA.c) / [`processB.c`](processB.c) are his programs
  verbatim. Prefer the [canonical
  page](https://thomasvanlaere.com/posts/2020/08/exploring-containers-part-2/).
- **Verified in this box (rootless `--privileged`):** the IPC isolation contrast,
  the `unshare --net` basics, the veth+bridge cross-namespace ping (rootless
  form), and the time namespace. The `ip netns` bridge form and the outbound NAT
  are the two **rootful/author-run** steps. Captured output:
  [`MANUAL_TESTING.md`](MANUAL_TESTING.md).
