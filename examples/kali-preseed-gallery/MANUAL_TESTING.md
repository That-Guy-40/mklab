# Kali preseed gallery — manual testing runbook

Copy-pasteable checks for the gallery, in the order you'd run them. The **new**
surface here (vs. `../kali-pxe-lab/`) is the **catalog fetch + vda-patch** and
the **variant selector** — those are checked exhaustively below. The iPXE ROM
build, the two-disk boot-loop, and the "did d-i clobber the ROM disk?" question
are shared verbatim with the PXE lab, so for those see
[`../kali-pxe-lab/MANUAL_TESTING.md`](../kali-pxe-lab/MANUAL_TESTING.md).

All commands run from the repo root. Replace `/home/sqs` in the TOML with your
`$HOME` first.

---

## ⚠️ Read this first — the one install-breaking risk (inherited)

This lab boots the installer from an **iPXE ROM on a second virtio disk**, so the
guest has `/dev/vda` (blank target) **and** `/dev/vdb` (the ROM). The upstream
preseeds pin `/dev/sda` and don't set `partman-auto/disk`, which would (a) fail
`grub-install` (no `sda` on a virtio bus) or (b) let d-i partition over `/dev/vdb`
and destroy the ROM mid-install. `fetch-preseeds.sh` rewrites both to `/dev/vda`.
**Section 1 below proves the patch took** before you ever boot. The deep dive on
the boot-loop + how vda-pinning protects the ROM is in the PXE lab's runbook.

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

## 3. Fetch the installer + build the ROM for real (≈1–3 min, Docker)

```bash
examples/kali-pxe-lab/fetch-kali-installer.sh --arch amd64        # → ~/netboot/kali/{linux,initrd.gz}
examples/kali-preseed-gallery/select-preseed.sh headless-default  # → ~/netboot/ipxe.qcow2
file ~/netboot/ipxe.qcow2     # → QEMU QCOW2 Image
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

## 5. Boot it (unattended) — and confirm the ROM survived

```bash
phase2-qemu-vm/lab-vm.sh create  --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
phase2-qemu-vm/lab-vm.sh start   kali-preseed-install
phase2-qemu-vm/lab-vm.sh console kali-preseed-install     # watch; Ctrl-] detaches
```

`headless-default` finishes fastest (no desktop). After it reboots into Kali,
log in on the console (`kali`/`kali`) and confirm d-i partitioned the **target**,
not the ROM:

```bash
lsblk
# Expect:  vda 20G  with vda1 (/) [+ swap]      ← installed here ✓
#          vdb ~4M  with NO child partitions    ← iPXE ROM untouched ✓
```

> Desktop / `*-large` / `crypto*` variants work the same way but take far longer
> (GBs of packages; secure-wipe on non-`skip-wipe` crypto). Verify those the same
> way — just budget the time.

---

## 6. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab kali-preseed-gallery
phase2-qemu-vm/lab-vm.sh    destroy kali-preseed-install --force
# Optional: reclaim artifacts:  rm -rf ~/netboot/kali ~/netboot/kali-preseed ~/netboot/ipxe.qcow2
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| VM keeps re-running the installer | `grub-install` failed (ROM disk, not target) | confirm §1a pinned `/dev/vda`; check §5 `lsblk` shows `vda1` |
| `vdb` got partitioned | served an **unpatched** preseed | re-run `fetch-preseeds.sh` (no `--verbatim`); rebuild the ROM |
| d-i stops at a prompt | `partman-auto/disk` missing → guided partitioner asks | §1a should have caught it; ensure you didn't `--verbatim` |
| `curl …/kali-preseed/<v>` → 404 | variant name typo, or TOML volume still `/home/sqs` | check the staged filename; fix the volume path |
| iPXE can't fetch over HTTP | nginx not up, or guest can't reach `10.0.2.2` | `lab-podman.sh up` first; `10.0.2.2` is the slirp host alias |
| Install very slow / stalls on apt | a desktop/`*-large` variant pulling GBs | expected; try `headless-default` to validate the pipeline first |

---

## Notes

- **One variant at a time per ROM.** The selected preseed is baked into
  `ipxe.qcow2`. To switch: `select-preseed.sh <other>`, then `destroy` + `create`
  the VM (blank the target disk) before `start`.
- **The gallery and PXE lab share `~/netboot/` + port 8181.** Run one at a time;
  the nginx service is identical.
