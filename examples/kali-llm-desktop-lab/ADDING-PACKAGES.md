# Adding a package — `kali-llm-desktop-lab`

This lab is **not** a chroot build. The `[[vm]]` uses `backend = "disk-image"`:
it boots a **prebuilt Kali image** and is provisioned **in-guest, over SSH**, by
`provision-kali-llm.sh`. There is no chroot and no `from-chroot` re-image — the
VM disk is persistent, so packages you install stick across reboots.

So "add a package" = add it to the **provisioner's tool list** (so a fresh
provision installs it) and apply it to the **running VM**.

## Where packages are declared

`provision-kali-llm.sh`, the `TOOLS` array:

```bash
declare -a TOOLS=(mcp-kali-server dirb gobuster nikto nmap enum4linux-ng hydra john sqlmap wpscan)
if [[ -z "$LITE" ]]; then
    TOOLS+=(metasploit-framework wordlists)   # large; LITE=1 skips these
...
apt-get install -y --no-install-recommends "${TOOLS[@]}"
```

(That's the script's faithful copy of the blog's apt line. The XFCE/VNC packages
are installed further down, in step 4 of the script.)

## Add one

1. **Edit the `TOOLS` array** in `provision-kali-llm.sh` — add the package
   name(s). To add `feroxbuster` and `seclists`:
   ```bash
   declare -a TOOLS=(mcp-kali-server dirb gobuster nikto nmap enum4linux-ng hydra john sqlmap wpscan feroxbuster seclists)
   ```
   This keeps a from-scratch (re-provisioned) build correct.

2. **Apply it to the running VM.** The VM is named `kali-llm-desktop`; read its
   auto-allocated SSH port from the manifest, then install over SSH — a targeted
   `apt` is faster than re-running the whole provisioner (which would also
   re-pull the model and reconfigure VNC):
   ```bash
   phase2-qemu-vm/lab-vm.sh ssh kali-llm-desktop -- 'sudo apt-get update && sudo apt-get install -y --no-install-recommends feroxbuster seclists'
   ```
   (Or re-run the whole stack — it's idempotent:
   `phase2-qemu-vm/lab-vm.sh ssh kali-llm-desktop -- 'sudo bash /tmp/provision-kali-llm.sh'`.)

3. **Verify** — over SSH (or on the serial `console`):
   ```bash
   phase2-qemu-vm/lab-vm.sh ssh kali-llm-desktop -- 'dpkg -l feroxbuster seclists | grep ^ii'
   ```

## Notes

- **No `--vm-only` here.** That flag belongs to the `from-chroot` backend
  (offsec-awae). This VM is a live disk image — `apt install` *is* the change;
  nothing needs re-imaging.
- **Want the LLM to be able to drive the new tool?** `mcp-kali-server` exposes
  CLI tools as MCP tools; most CLI security packages are usable from 5ire once
  installed. No extra wiring needed for ordinary `apt` CLI tools.
- **GUI apps** install fine but you'll only see them through the SSH-tunnelled
  VNC desktop (README §4).

## TL;DR

```bash
# 1. add the pkg to the TOOLS=(...) array in provision-kali-llm.sh
# 2. install it in the running VM:
phase2-qemu-vm/lab-vm.sh ssh kali-llm-desktop -- 'sudo apt-get install -y <pkg>'
# 3. verify:
phase2-qemu-vm/lab-vm.sh ssh kali-llm-desktop -- 'dpkg -l <pkg> | grep ^ii'
```
