# Kali preseed gallery — manual testing runbook

Copy-pasteable checks for the gallery, in the order you'd run them. The **new**
surface here (vs. `../kali-pxe-lab/`) is the **catalog fetch + vda-patch** and
the **variant selector** — those are checked exhaustively below.  The boot path
is QEMU `pxe-install` (BIOS): SeaBIOS → the NIC's PXE ROM → TFTP `ipxe.pxe` →
iPXE → d-i → install to `/dev/vda` → reboot into the installed disk.

All commands run from the repo root. Replace `/home/sqs` in the TOML with your
`$HOME` first.

---

## ⚠️ Read this first — the one install-breaking risk

The VM's only disk is a **virtio** disk, `/dev/vda` (there is no `/dev/sda`).
Every upstream preseed pins `/dev/sda` and sets no `partman-auto/disk`, which on
this bus would (a) fail `grub-install` (no `sda`) or (b) leave d-i's partitioner
**prompting** for the target, breaking the unattended install. `fetch-preseeds.sh`
rewrites both to `/dev/vda`. **Section 1 below proves the patch took** before you
ever boot.

---

## 0. Preflight

```bash
for c in qemu-system-x86_64 qemu-img podman docker jq curl; do
    command -v "$c" >/dev/null && echo "ok: $c" || echo "MISSING: $c"
done
ls /dev/kvm >/dev/null 2>&1 && echo "ok: KVM" || echo "no KVM (TCG = slow)"
```

---

## 1. Fetch the catalog + prove the vda-patch took (≈30 s)

```bash
examples/kali-preseed-gallery/fetch-preseeds.sh
PSD=~/netboot/kali-preseed
```

**1a. Every staged variant is pinned to `/dev/vda`, and none still says `/dev/sda`:**

```bash
bad=0
for f in "$PSD"/*.cfg "$PSD"/headless-default; do
    grep -q 'grub-installer/bootdev[[:space:]]\+string /dev/vda$' "$f" || { echo "❌ $(basename "$f"): grub not pinned"; bad=1; }
    grep -q 'partman-auto/disk[[:space:]]\+string /dev/vda$'      "$f" || { echo "❌ $(basename "$f"): partman not pinned"; bad=1; }
    grep -q '/dev/sda' "$f" && { echo "⚠️  $(basename "$f"): still has /dev/sda"; bad=1; }
done
[ "$bad" = 0 ] && echo "✅ all staged variants pinned to /dev/vda, zero /dev/sda"
```

**1b. The verbatim upstream copy is preserved (and still says `/dev/sda`) — so the
patch is the *only* change:**

```bash
diff <(grep -E 'partman-auto/(disk|method)|grub-installer/bootdev' "$PSD/raw/xfce-default.cfg") \
     <(grep -E 'partman-auto/(disk|method)|grub-installer/bootdev' "$PSD/xfce-default.cfg")
# Expect: raw has '/dev/sda' grub line and no disk line; staged has both pinned /dev/vda.
```

**1c. No duplicate disk lines (the `packer-preseed` commented-disk edge case):**

```bash
grep -c '^d-i[[:space:]]\+partman-auto/disk' "$PSD/packer-preseed.cfg"   # → 1
```

**1d. `--verbatim` really leaves `/dev/sda` (for the real-hardware path):**

```bash
tmp=$(mktemp -d); examples/kali-preseed-gallery/fetch-preseeds.sh --out "$tmp" --verbatim --only xfce-default >/dev/null 2>&1
grep -q '/dev/sda' "$tmp/xfce-default.cfg" && echo "✅ --verbatim kept /dev/sda"; rm -rf "$tmp"
```

---

## 2. Select a variant + inspect the iPXE boot params (no build)

```bash
examples/kali-preseed-gallery/select-preseed.sh headless-default --print-only
# Confirm the printed build-ipxe command has:
#   --append 'auto=true priority=critical preseed/url=…/kali-preseed/headless-default …console=ttyS0,115200n8 ---'
```

Error path (lists the catalog, exits nonzero):

```bash
examples/kali-preseed-gallery/select-preseed.sh nope 2>&1 | head -3; echo "exit=$?"
```

---

## 3. Fetch the installer + build the iPXE boot program (≈1–3 min, Docker)

```bash
examples/kali-pxe-lab/fetch-kali-installer.sh --arch amd64        # → ~/netboot/kali/{linux,initrd.gz}
examples/kali-preseed-gallery/select-preseed.sh headless-default  # → ~/netboot/ipxe.pxe (+ .efi/.qcow2)
file ~/netboot/ipxe.pxe       # → … (iPXE BIOS NBP, served via slirp TFTP)
```

---

## 4. Serve + confirm all three artifacts (instant — the #1 failure point)

```bash
phase4-podman/lab-podman.sh up --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
for u in kali/linux kali/initrd.gz kali-preseed/headless-default; do
    printf '%-28s ' "$u"; curl -sI "http://localhost:8181/$u" | head -1
done
# All three → HTTP/1.1 200 OK.  404 = wrong path / TOML still says /home/sqs.
```

---

## 5. Boot it (unattended) — and confirm the loop terminates

```bash
phase2-qemu-vm/lab-vm.sh create  --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
phase2-qemu-vm/lab-vm.sh start   kali-preseed-install
phase2-qemu-vm/lab-vm.sh console kali-preseed-install     # watch; Ctrl-] detaches
```

What you'll see: SeaBIOS tries the blank `vda` (bootindex 0) → falls to the NIC
PXE ROM → TFTP `ipxe.pxe` → iPXE fetches the d-i kernel/initrd → unattended
install to `/dev/vda` → reboot. `headless-default` finishes fastest (no desktop).

Confirm the loop **terminated** (i.e. the second boot came from the disk, not the
network) — two host-side checks that don't need a guest login (the installed
kernel has no serial console):

```bash
# (a) nginx logged the netboot fetches exactly ONCE (at install time) — no second
#     round after the reboot = SeaBIOS booted the installed disk:
podman logs lab-kali-preseed-gallery-http 2>&1 | grep -a 'GET /kali/linux'   # one timestamp

# (b) the installed disk has a GRUB boot sector (stop the VM first):
phase2-qemu-vm/lab-vm.sh stop kali-preseed-install
tgt=~/.local/state/lab-create/vms/kali-preseed-install/kali-preseed-install-target.qcow2
qemu-img convert -f qcow2 -O raw "$tgt" /tmp/vda.raw
od -An -tx1 -j510 -N2 /tmp/vda.raw      # 55 aa  (boot signature)
strings <(head -c2048 /tmp/vda.raw) | grep -i grub   # → GRUB ; rm /tmp/vda.raw
```

> Desktop / `*-large` / `crypto*` variants work the same way but take far longer
> (GBs of packages; secure-wipe on non-`skip-wipe` crypto). Verify those the same
> way — just budget the time.

---

## 6. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab kali-preseed-gallery
phase2-qemu-vm/lab-vm.sh    destroy kali-preseed-install --force
# Optional: reclaim artifacts:  rm -rf ~/netboot/kali ~/netboot/kali-preseed ~/netboot/ipxe.*
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| VM keeps re-running the installer (never boots the disk) | `grub-install` failed, or the target lacks `bootindex=0` | confirm §1a pinned `/dev/vda`; check §5(b) for `55 aa` + `GRUB` on the target |
| d-i stops at a prompt | `partman-auto/disk` missing → guided partitioner asks | §1a should have caught it; ensure you didn't `--verbatim` |
| `curl …/kali-preseed/<v>` → 404 | variant name typo, or TOML volume still `/home/sqs` | check the staged filename; fix the volume path |
| iPXE never starts (`No bootable device`) | guest didn't reach the NIC PXE ROM, or `ipxe.pxe` not served | confirm `firmware="bios"` + `pxe_bootfile="ipxe.pxe"`; `ipxe.pxe` present in `pxe_dir` |
| iPXE can't fetch over HTTP | nginx not up, or guest can't reach `10.0.2.2` | `lab-podman.sh up` first; `10.0.2.2` is the slirp host alias |
| Install very slow / stalls on apt | a desktop/`*-large` variant pulling GBs | expected; try `headless-default` to validate the pipeline first |

---

## Notes

- **One variant at a time per NBP.** The selected preseed is baked into
  `ipxe.pxe`. To switch: `select-preseed.sh <other>`, then `destroy` + `create`
  the VM (blank the target disk) before `start`.
- **The gallery and PXE lab share `~/netboot/` + port 8181.** Run one at a time;
  the nginx service is identical.
