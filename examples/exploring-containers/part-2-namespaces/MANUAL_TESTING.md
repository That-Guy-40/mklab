# Manual testing — Part 2 (IPC, network & time namespaces)

Real captured output, verified **2026-07-03** on kernel `6.8.0` with **rootless
podman 4.9.3**, image built from `alpine:3.23` (util-linux 2.41.4) via
`phase4-podman/lab-podman.sh build`. Everything below ran in a rootless
`--privileged` box **except** the two steps explicitly marked *rootful/author-run*.

## Build

```console
$ phase4-podman/lab-podman.sh build --tag ec-part2 \
      --context examples/exploring-containers/part-2-namespaces
…
Successfully tagged localhost/ec-part2:latest
```

## §1 IPC namespace — isolation contrast ✅

```console
$ podman run --rm --privileged ec-part2 sh -c '
    cd /root && gcc processA.c -o processA && gcc processB.c -o processB
    echo "--- host IPC ns: write then read ---"
    ./processA "Hello from $$"; ./processB
    echo "--- NEW ipc ns: host message INVISIBLE (fresh, empty segment) ---"
    ./processA "Hello from $$"; unshare --ipc ./processB'
processA.c: In function 'main':
processA.c:20:56: warning: comparison between pointer and integer      ← author's own code, harmless
processB.c: In function 'main':
processB.c:19:65: warning: comparison between pointer and integer
--- host IPC ns: write then read ---
Created key 12D22FA
Created key 12D22FA
Reading shared memory:
Hello from 1
Shared memory removed
--- NEW ipc ns: host message INVISIBLE (fresh, empty segment) ---
Created key 12D22FA
Created key 12D22FA
Reading shared memory:
                          ← EMPTY: the new IPC namespace has its own SysV space
Shared memory removed
```

## §2 Network namespace — `unshare --net` basics ✅

```console
$ podman run --rm --privileged ec-part2 sh -c 'unshare --net sh -c "
    echo fresh net ns:; ip -br link
    ping -c1 -W1 127.0.0.1 2>&1 | tail -1
    ip link set lo up
    ping -c1 -W1 127.0.0.1 2>&1 | tail -2 | head -1"'
fresh net ns:
lo               DOWN           00:00:00:00:00:00 <LOOPBACK>       ← only lo, and DOWN
ping: sendto: Network unreachable                                 ← loopback not up yet
1 packets transmitted, 1 packets received, 0% packet loss         ← after `ip link set lo up`
```

## §3 Network namespace — veth + bridge across two namespaces ✅ (rootless form)

The author's `ip netns` form fails rootless — captured here so the wall is honest:

```console
$ podman run --rm --privileged ec-part2 sh -c 'ip netns add mynetns'
mount of /sys failed: Operation not permitted        ← rootless can't remount sysfs; use rootful, or the form below
```

The PID-named equivalent (`unshare` + `nsenter`) reaches the identical end state:

```console
$ podman run --rm --privileged ec-part2 sh -c '
    unshare --net sleep 60 & P1=$!; unshare --net sleep 60 & P2=$!; sleep 0.3
    ip link add br0 type bridge
    ip link add veth1 type veth peer name br-veth1
    ip link add veth2 type veth peer name br-veth2
    ip link set veth1 netns $P1; ip link set veth2 netns $P2
    ip link set br-veth1 master br0; ip link set br-veth2 master br0
    ip addr add 10.0.0.10/24 dev br0; ip link set br0 up
    ip link set br-veth1 up; ip link set br-veth2 up
    nsenter -t $P1 -n sh -c "ip addr add 10.0.0.11/24 dev veth1; ip link set veth1 up; ip link set lo up"
    nsenter -t $P2 -n sh -c "ip addr add 10.0.0.12/24 dev veth2; ip link set veth2 up; ip link set lo up"
    nsenter -t $P2 -n ping -c2 -W1 10.0.0.11 | tail -3
    kill $P1 $P2 2>/dev/null'
--- 10.0.0.11 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss          ← ns2 → ns1 across the bridge
round-trip min/avg/max = 0.045/0.057/0.069 ms
```

## §4 Outbound NAT — rootful/author-run ⚠️

`echo 1 > /proc/sys/net/ipv4/ip_forward` + `iptables -t nat -A POSTROUTING -s
10.0.0.0/24 -j MASQUERADE` + `ping 8.8.8.8` needs real root and a routable uplink;
under rootless podman the container's own egress is a `slirp4netns` shim, so this
is documented in the RUNBOOK, not claimed as verified here. Run the box rootful
(`sudo podman run --privileged …`) to reproduce.

## §5 Time namespace — in-box on latest Alpine ✅

```console
$ podman run --rm --privileged ec-part2 sh -c '
    echo "host   : $(uptime)"
    echo "timens : $(unshare --time --boottime 86400 uptime)"
    unshare --time --boottime 86400 cat /proc/self/timens_offsets'
host   :  16:38:13 up 18:10,  0 users,  load average: 0.36, 0.33, 0.38
timens :  16:38:13 up 1 day, 18:10,  0 users,  load average: 0.36, 0.33, 0.38   ← +24h boot offset
monotonic           0         0
boottime        86400         0
```

For contrast, Alpine **3.11** (the author's base) can't do this — its util-linux
2.34 `unshare` has no `--time`, and the 2020 edge workaround is now dead:

```console
$ podman run --rm alpine:3.11 sh -c 'unshare --help | grep -c time'
0                                                    ← no --time in util-linux 2.34
```

## Summary

| Section | Result |
|---|---|
| §1 IPC namespace isolation | ✅ verified in-box (rootless) |
| §2 `unshare --net` basics | ✅ verified in-box (rootless) |
| §3 veth + bridge cross-ns ping | ✅ verified in-box (rootless `unshare`+`nsenter` form) |
| §3 `ip netns` bridge form | ⚠️ rootful — `mount of /sys failed` rootless (wall captured) |
| §4 outbound NAT / MASQUERADE | ⚠️ rootful/author-run |
| §5 time namespace | ✅ verified in-box (latest Alpine); 3.11 can't (captured) |
