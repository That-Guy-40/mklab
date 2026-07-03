# Vendored upstream — Ciro S. Costa's `/proc` article series (ops.tips)

Byte-exact archives of the **six** consecutive ops.tips articles this lab
provides a hands-on sandbox for, plus the site's stylesheet and the fifteen
explanatory SVG diagrams, so the writing and its figures are preserved offline
and the provenance is explicit (web pages move, rot, or change).

All six are by **Ciro S. Costa** (Ciro da Silva da Costa), published on
**ops.tips** (the author's blog) over a week in October 2018, © Ciro da Silva da
Costa, 2018 — no explicit open license (see below). All retrieved **2026-07-03**.

## Provenance

| # | Title | Canonical URL | Published |
|---|---|---|---|
| 1 | What is /proc? | <https://ops.tips/blog/what-is-slash-proc/> | 2018-10-10 |
| 2 | How is /proc able to list process IDs? | <https://ops.tips/blog/how-is-proc-able-to-list-pids/> | 2018-10-11 |
| 3 | Why top and free inside containers don't show the correct container memory | <https://ops.tips/blog/why-top-inside-container-wrong-memory/> | 2018-10-12 |
| 4 | Process resource limits under the hood | <https://ops.tips/blog/proc-pid-limits-under-the-hood/> | 2018-10-13 |
| 5 | Using /proc to get a process' current stack trace | <https://ops.tips/blog/using-procfs-to-get-process-stack-trace/> | 2018-10-14 |
| 6 | How Linux creates sockets and counts them | <https://ops.tips/blog/how-linux-creates-sockets/> | 2018-10-16 |

## Files & `sha256`

The two article pages are kept **byte-exact**. Their asset links (CSS, diagrams,
fonts) are **absolute** (`https://ops.tips/…`, `/blog/-/images/…`) — ops.tips is
a Hugo static site with content-addressed bundles — so, unlike a page with
*relative* links, the byte-exact HTML cannot be made to load those assets from
`file://` without editing it (which would break the hashes). The CSS and the five
content SVGs are therefore vendored **alongside** purely for preservation; view
the byte-exact pages best while online, or read the articles' prose directly.

```
b05fc4176bde8173cf16317ee26bcfae9f14a981cbd225a9bfb1475d437d8aeb  what-is-slash-proc.html
5e6c9f3c23757873117c332f74119b88241a3b86d72a21d452741615aa1b78b6  how-is-proc-able-to-list-pids.html
94df3b438b07648542a6097b1d384d2269276ba318b4fc959790c9ff2eef2a35  why-top-inside-container-wrong-memory.html
573a7f754ff714f2c01d98ef99d235c96961e4cd158718a8b90ffcac771964ed  proc-pid-limits-under-the-hood.html
75922cc496f110bdc184ab4d765a2174146459fd2494dc8a354af9ea71997227  bundle.min.css
8f836b75f4c80571ce3301e3df9ddf32fc6070594575026999e11274b27cb452  images/vfs-abstraction.svg
c38016e8b5dfd7fdc0f2fe2a74a5809b5baa7d9c9c43dcfdb1f818aae269d05e  images/kernel-open-and-read.svg
3e4ade7efbfaa13afab9d1d61d8a526ec7a45d25d72cd27f13c6fa5a98c98f5b  images/procfs-file-operations.svg
ec8b617413578882be07c3e8a5d35cc7aa3b2b1d436aaa4d5da0365cd16151e9  images/getdents-under-the-hood.svg
565767f4d603bd42688c6c717d0a1150ba22f0a25df9c4fe765d368a209048c8  images/ls-proc.svg
e46b9e96f191119c9ce71de6d7eee8d67f7510ccc8ece15c8e2ce84008fe0afa  images/meminfo-uncontained.svg
8a952646129fa2d157545747c029ef0f3208fd89f2b305414041b0067e9005c4  images/ulimits-example.svg
0ff6774251c5fe399ce387a2cd863a269edc12367d3b7e273a320656135271ee  using-procfs-to-get-process-stack-trace.html
102439093e4ce82986920abbe79a8f61c08211275dc3d9c09fe40acf50f76e96  how-linux-creates-sockets.html
b9aa541b42c05ca69f6972f45f729dd5432e969a05974b968179dc2fb6e521a1  images/epoll-notifying.svg
4c4531833f3a80b976cc2e4e724735d076eb536d69e7803d7af2bb449bef809e  images/procfs-capturing-stack.svg
0ea0de82ca33d517efc209514f162ac79350406b8158dd34ed11873879342868  images/tcp-server-blocking-main-thread.svg
eb6c1c786e7436967e71f48f406b3c099ca12c941046535c6d5acd63faabc595  images/client-server-boundary.svg
b66563592d252b54708acdf7b864de52ec58af45ea10f3a86958131729669a8e  images/house-sockets-overview.svg
08c2f9be48f1b10f283f675c7ed8590499e21b8720cdcd15f3377d0a1d72d472  images/net-internal-socket.svg
1c44f1fe1806475dec73c13c351294e66729680ff8d55bdc8190285b313b5eba  images/server-accepting.svg
68bf62f2fa9cd718fb05d5606131f291d7f03014da16174911f2cfd36aa78162  images/socket-how-does-it-work.svg
```

Verify any time (from this directory):

```bash
sha256sum -c <<'EOF'
b05fc4176bde8173cf16317ee26bcfae9f14a981cbd225a9bfb1475d437d8aeb  what-is-slash-proc.html
5e6c9f3c23757873117c332f74119b88241a3b86d72a21d452741615aa1b78b6  how-is-proc-able-to-list-pids.html
94df3b438b07648542a6097b1d384d2269276ba318b4fc959790c9ff2eef2a35  why-top-inside-container-wrong-memory.html
573a7f754ff714f2c01d98ef99d235c96961e4cd158718a8b90ffcac771964ed  proc-pid-limits-under-the-hood.html
75922cc496f110bdc184ab4d765a2174146459fd2494dc8a354af9ea71997227  bundle.min.css
8f836b75f4c80571ce3301e3df9ddf32fc6070594575026999e11274b27cb452  images/vfs-abstraction.svg
c38016e8b5dfd7fdc0f2fe2a74a5809b5baa7d9c9c43dcfdb1f818aae269d05e  images/kernel-open-and-read.svg
3e4ade7efbfaa13afab9d1d61d8a526ec7a45d25d72cd27f13c6fa5a98c98f5b  images/procfs-file-operations.svg
ec8b617413578882be07c3e8a5d35cc7aa3b2b1d436aaa4d5da0365cd16151e9  images/getdents-under-the-hood.svg
565767f4d603bd42688c6c717d0a1150ba22f0a25df9c4fe765d368a209048c8  images/ls-proc.svg
e46b9e96f191119c9ce71de6d7eee8d67f7510ccc8ece15c8e2ce84008fe0afa  images/meminfo-uncontained.svg
8a952646129fa2d157545747c029ef0f3208fd89f2b305414041b0067e9005c4  images/ulimits-example.svg
0ff6774251c5fe399ce387a2cd863a269edc12367d3b7e273a320656135271ee  using-procfs-to-get-process-stack-trace.html
102439093e4ce82986920abbe79a8f61c08211275dc3d9c09fe40acf50f76e96  how-linux-creates-sockets.html
b9aa541b42c05ca69f6972f45f729dd5432e969a05974b968179dc2fb6e521a1  images/epoll-notifying.svg
4c4531833f3a80b976cc2e4e724735d076eb536d69e7803d7af2bb449bef809e  images/procfs-capturing-stack.svg
0ea0de82ca33d517efc209514f162ac79350406b8158dd34ed11873879342868  images/tcp-server-blocking-main-thread.svg
eb6c1c786e7436967e71f48f406b3c099ca12c941046535c6d5acd63faabc595  images/client-server-boundary.svg
b66563592d252b54708acdf7b864de52ec58af45ea10f3a86958131729669a8e  images/house-sockets-overview.svg
08c2f9be48f1b10f283f675c7ed8590499e21b8720cdcd15f3377d0a1d72d472  images/net-internal-socket.svg
1c44f1fe1806475dec73c13c351294e66729680ff8d55bdc8190285b313b5eba  images/server-accepting.svg
68bf62f2fa9cd718fb05d5606131f291d7f03014da16174911f2cfd36aa78162  images/socket-how-does-it-work.svg
EOF
```

> The stylesheet's filename **is** its own `sha256` (`bundle.min.<hash>.css`) —
> Hugo content-addresses its asset bundle, so the hash above matching the name is
> a second, independent integrity check.

## Which SVG belongs to which article

| SVG | Article |
|---|---|
| `images/vfs-abstraction.svg` | 1 — the VFS layer over ext4 vs procfs |
| `images/kernel-open-and-read.svg` | 1 — the `open()`→`read()` path into `f_op->read` |
| `images/procfs-file-operations.svg` | 1 — different procfs paths, different `file_operations` |
| `images/getdents-under-the-hood.svg` | 2 — `getdents64` from userspace down to the fs |
| `images/ls-proc.svg` | 2 — `ls /proc` calling into `proc_pid_readdir` |
| `images/meminfo-uncontained.svg` | 3 — `/proc/meminfo` reading global counters, blind to the cgroup |
| `images/ulimits-example.svg` | 4 — `ulimit`/`getrlimit`/`setrlimit` all funnel into `prlimit` |
| `images/tcp-server-blocking-main-thread.svg`, `epoll-notifying.svg`, `procfs-capturing-stack.svg` | 5 — a blocked server; epoll; capturing the stack via procfs |
| `images/house-sockets-overview.svg`, `socket-how-does-it-work.svg`, `client-server-boundary.svg`, `server-accepting.svg`, `net-internal-socket.svg` | 6 — the socket metaphor, the syscall boundary, `sock_create` internals |

## Not vendored (live links remain absolute to the original hosts)

- **Fonts** — the Lato `.woff`/`.woff2` files the CSS references by `url(/fonts/…)`.
  Text falls back to a system sans-serif; no meaning is lost.
- **JavaScript, analytics, comments** — site chrome and the Disqus/analytics
  includes. The articles read fully without them.
- **Header / social images** — `me.jpg`, `opstips.png`, the `slash-proc.png`
  OpenGraph card. These are branding, not article content; the fifteen **content**
  SVGs above are the only in-body figures and are all vendored.

## License / attribution

The articles are © **Ciro da Silva da Costa, 2018** (the footer notice). The site
carries **no explicit open license**, so they are treated as all-rights-reserved
and reproduced here **verbatim, with attribution, for offline educational
reference** only — not redistribution. All rights remain with the author; no
endorsement is implied. To remove this archive, `git rm` this directory.

Source of truth:
<https://ops.tips/blog/what-is-slash-proc/> ·
<https://ops.tips/blog/how-is-proc-able-to-list-pids/> ·
<https://ops.tips/blog/why-top-inside-container-wrong-memory/> ·
<https://ops.tips/blog/proc-pid-limits-under-the-hood/> ·
<https://ops.tips/blog/using-procfs-to-get-process-stack-trace/> ·
<https://ops.tips/blog/how-linux-creates-sockets/>
