# POC-A — Real IPMI Serial-over-LAN via OpenIPMI `ipmi_sim` (the money shot)

**Spike goal:** prove a *faithful* `ipmitool -I lanplus … sol activate` streams a VM's
serial console over a genuine RMCP+/lanplus IPMI session — the thing VirtualBMC can't do
(no `activate_payload`) and MAAS v1 substitutes with a libvirt console. Per
`BMC_TOOLKIT_LAB_PLAN.md` §5, this is the lab's highest-risk / highest-payoff item.

**Result: ✅ PASS — proven headless, rootless, with NO libvirt.** The whole SOL/RMCP+
surface (the actual risk) needs neither root nor libvirt; only the chassis→power wiring
touches libvirt, so it was isolated out and the money shot proven on a high UDP port.

## Environment (host, this box)
- `ipmi_sim` **1.0.13** (Debian `openipmi` pkg), `ipmitool`, `socat` — all already present.
- No root: LAN bound to `127.0.0.1:9001` (high port; 623 would need privilege).
- No libvirt: the "VM serial" is a `socat` PTY fed by a banner generator (`gen.sh`).

## The winning setup
- **`ipmisim1.emu`** — minimal BMC: `mc_setbmc 0x20` / `mc_add 0x20 0 no-device-sdrs
  0x23 9 8 0x9f 0x1291 0xf02 persist_sdr` / `mc_enable 0x20`.
- **`lan.conf`** — `startlan 1` on `127.0.0.1:9001`, `allowed_auths_* … md5 straight`,
  users `ipmiusr`/`test` (admin) + anonymous, and the key line:
  `sol "<pty>" 115200`.
- **serial source** — `socat -u EXEC:gen.sh PTY,link=<pty>,raw,echo=0,b115200`.
- **launch** — `ipmi_sim -c lan.conf -f ipmisim1.emu -n -s <writable-statedir>`.
- **the money shot** — `{ sleep 6; } | timeout 9 ipmitool -I lanplus -H 127.0.0.1
  -p 9001 -U ipmiusr -P test -C 3 sol activate`.

## Verified transcript (real)
```
== [3/5] RMCP+ session sanity: chassis status over lanplus ==
   System Power         : off
   … (full chassis status returned — RAKP/RMCP+ session established) …
   RMCP+ session OK
== [4/5] SOL config check (ipmi_sim enables SOL by default) ==
   Enabled                         : true
   Force Encryption                : false
   Force Authentication            : false
== [5/5] REAL SOL: sol activate, capture streamed serial for ~6s ==
   [SOL Session operational.  Use ~? for help]
   [BMC-TOOLKIT-SOL-PROOF] alpine-node login: tick=3
   [BMC-TOOLKIT-SOL-PROOF] alpine-node login: tick=4
   … tick=5,6,7,8 …
PASS: real IPMI SOL over RMCP+ streamed the VM serial (6 marker lines via sol activate)
```

## Gotchas found (each cost a cycle — these are the RUNBOOK's teaching moments)
1. **`sol activate < /dev/null` tears the session down instantly.** ipmitool exits on
   stdin **EOF** (rc=0, session established then gone) *before* any serial arrives. Fix:
   keep stdin **open** for the capture window — `{ sleep N; } | ipmitool … sol activate`.
   This is *the* SOL-automation gotcha; the toolkit's `bmc.sh sol --capture` must do it.
2. **`ipmi_sim -d` (debug) core-dumps** in 1.0.13 (Aborted). Use `-n` (disables stdin
   console); debug is not usable here.
3. **`-s <state-dir>` is mandatory for non-root.** Default persistence path
   `/var/ipmi_sim/<name>` isn't writable; point `-s` at a writable dir or it fails.
4. **`ipmitool … -C 3`** suppresses the benign "Unable to Get Channel Cipher Suites"
   retry (ipmi_sim doesn't implement Get Channel Cipher Suites; fixing the cipher skips
   the slow probe).
5. **`sol payload enable` → "Invalid command"** and **`sol set enabled true` →
   "Parameter not supported"**: ipmi_sim **enables SOL by default** (`sol info` shows
   `Enabled: true`), so neither is needed — don't call them.
6. **serial source must be `socat -u EXEC:gen.sh PTY,…`** (unidirectional). The
   double-pty form `EXEC:gen.sh,pty` silently delivered nothing.
7. **`sol "tcp:host:port"`** is a documented device form ("SOL access to qemu ports") —
   this is the **production wiring** for a real QEMU/libvirt node (`<serial type='tcp'>`
   / `-serial tcp:…`). POC used a PTY; the lab's live node uses `tcp:`.
8. The benign `Invalid completion code … Get VSO Capabilities` + `tcgetattr:
   Inappropriate ioctl` lines during activate are just ipmitool probing/raw-mode on a
   non-tty — the session still goes operational.

## Power path — decision: COEXIST (ipmi_sim = SOL, vbmcd = power)
`ipmi_sim` chassis **power control returns 0xCC** ("Invalid data field in request") in
1.0.13 — **even vanilla**: `ipmitool … chassis power on` and even the raw
`raw 0x00 0x02 0x01` (Chassis Control / power-up) are rejected. The `startcmd` power-hook
mechanism exists (it *is* the intended virsh-shim), but the Chassis Control command
itself won't accept the request in this build without setup I couldn't find documented.

Rather than rat-hole (and since chassis→virsh is author-run libvirt anyway), Spike A
adopts the plan's **§5 fallback-ladder option 2 — coexist**: the `ipmi_sim` backend
provides **real SOL**, and **`vbmcd` (already ✅-proven) provides power/bootdev**. Two
BMCs per node (SOL on one port, power on another), each doing what it's proven to do.
`bmc.sh` hides the split behind one verb surface (the whole point of the capability
model). The "whole-BMC on one session" shape (ipmi_sim power too) stays an **open
follow-up** with a precise starting point: *why does Chassis Control return 0xCC in
ipmi_sim 1.0.13, and what emu/lan.conf power setup clears it?*

## Reusable artifacts (promote to `examples/bmc-toolkit/` at assembly)
- `ipmisim1.emu`, `lan.conf.template` — the minimal working BMC + SOL config.
- `run-spikeA.sh` — the headless SOL proof (one PASS/FAIL verdict, kill-by-PID).
- The `sol activate` stdin-open + `-C 3` idiom → the `bmc.sh sol` implementation.
