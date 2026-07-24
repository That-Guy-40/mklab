# package-mirror-ram — Manual Testing

## Part 1 — the guarded network-state mount  ✅ verified (host-only, 2026-07-23)

```bash
examples/package-mirror-ram/tests/test-state-mount-guard.sh
```

```
  - NFS mount failure → exit 0 + WARN (guard holds)
  - NFS mount success → exit 0 + real nfs4 mount attempted
  - iSCSI attach failure → exit 0 + WARN (guard holds)
  - already-mounted → exit 0, no re-mount
PASS: state-mount.sh: network-storage mount is ||-guarded (failures never panic /init), success mounts, idempotent
```

No docker, no root, no real NFS/iSCSI — `mount`/`iscsiadm`/`mountpoint` are stubbed
on `PATH`. This guards the one property that would otherwise brick a node: an
unguarded mount failure in `/init` (which runs `set -e`) panics PID 1.

---

## Part 2 — live mirror storage  ⏳ author-run

Standing up a **live** NFS or iSCSI mount is author-run here for two reasons:
(1) it touches **host-global kernel state** — the kernel NFS server and the iSCSI
initiator's global session table — and this dev host is *itself* serving NFS on
`:2049`; (2) it needs a storage server the node can reach. Both recipes below are
ready to run on a host you control (or two VMs). The node side is just
`state-mount.sh` with the right `STATE_*` env (baked in the image or on the
kernel cmdline).

> **Note from building this:** an isolated NFS demo via `nfs-ganesha` in docker
> was attempted; it works in principle (userspace server, NFSv4-only, binds 2049
> in its own netns), but exercising it churned the session's docker daemon into a
> state where it could no longer reap containers. That fragility is exactly why
> the live mount is author-run rather than an agent-run smoke.

### 2a. NFS (userspace server — nfs-ganesha, NFSv4-only, no rpcbind)

On the **storage server** (a box/VM you control), export the mirror tree:

```conf
# /etc/ganesha/ganesha.conf
NFS_CORE_PARAM { Protocols = 4; NFS_Port = 2049; }
NFSV4 { Graceless = true; }
EXPORT {
    Export_Id = 1; Path = /srv/mirror; Pseudo = /srv/mirror;
    Access_Type = RO; Squash = No_Root_Squash;
    Protocols = 4; Transports = TCP; SecType = sys;
    FSAL { Name = VFS; }
}
LOG { Default_Log_Level = EVENT; }
```

```bash
sudo mkdir -p /var/run/ganesha
sudo ganesha.nfsd -F -f /etc/ganesha/ganesha.conf     # foreground
```

On the **node** (what `state-mount.sh` does with `STATE_KIND=nfs`):

```bash
mount -t nfs4 -o vers=4.1,proto=tcp,ro,soft,timeo=50,retrans=2 \
    <storage>:/srv/mirror /srv/mirror
curl -s http://127.0.0.1/dists/stable/Packages   # nginx serves the mounted tree
```

### 2b. iSCSI (block — tgt target + open-iscsi initiator)

On the **storage server**, export a LUN backed by the mirror filesystem image:

```bash
sudo tgtadm --lld iscsi --op new --mode target --tid 1 \
    -T iqn.2026-07.lab:mirror
sudo tgtadm --lld iscsi --op new --mode logicalunit --tid 1 --lun 1 \
    -b /srv/mirror.img            # a filesystem image holding the mirror tree
sudo tgtadm --lld iscsi --op bind --mode target --tid 1 -I ALL
```

On the **node** (what `state-mount.sh` does with `STATE_KIND=iscsi`):

```bash
iscsiadm -m discovery -t sendtargets -p <storage>:3260
iscsiadm -m node -T iqn.2026-07.lab:mirror -p <storage>:3260 --login
mount -o ro /dev/disk/by-path/ip-<storage>:3260-iscsi-iqn.2026-07.lab:mirror-lun-0 \
    /srv/mirror
```

> **Host-global cleanup (author, with sudo):** `iscsiadm … --logout` and
> `tgtadm --op delete` remove the initiator session + target; `pkill`-free —
> use the tools' own delete verbs.

### 2c. The RAM node image

Build [`package-mirror-chroot.toml`](package-mirror-chroot.toml) per its header,
pass the state config on the kernel cmdline
(`--append "STATE_KIND=nfs STATE_SRC=<storage>:/srv/mirror"`), sign + serve via
mechanic ①, and boot. Success signature: `/init` runs `state-mount.sh` (guarded),
the mirror mounts, systemd starts nginx, and `curl http://<node>/dists/stable/Packages`
returns content that lives on the storage server — reboot into a new verified
image and the mirror is untouched.

---

## Cleanup

The guard test cleans its own tempdir. There is no persistent state from Part 1.
For Part 2, tear down the storage with the tools' delete verbs (see 2b).
