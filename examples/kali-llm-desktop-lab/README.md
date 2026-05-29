# Kali local-LLM lab — Tier 2-FULL: the faithful blog stack in a Kali desktop VM

The heavyweight, **blog-faithful** companion to [`../kali-llm-lab/`](../kali-llm-lab/)
(Tier 1, headless containers). Here the *entire* experience from the Kali post
[*Local LLM with Ollama & 5ire*](https://www.kali.org/blog/kali-llm-ollama-5ire/)
runs **inside one Kali XFCE VM**:

| Blog piece | What it is | Here |
|---|---|---|
| **Ollama** | local LLM runtime (HTTP API :11434) | ✅ in-VM, systemd service |
| **5ire** | the *real* desktop GUI / MCP client (Electron AppImage) | ✅ in-VM, reached over VNC-through-SSH |
| **mcp-kali-server** | exposes nmap/sqlmap/metasploit/… to the model as MCP tools | ✅ in-VM (Tier 3 — the agentic payoff) |

This is the lab Tier 1's README flagged as *"Future state / TODO — Option 2."*
It's now a real runbook. The trade-off vs Tier 1 is honesty about cost: a
multi-GB Kali image, ~8 GB RAM, and an interactive desktop you drive by hand —
so the steps below are a **documented procedure**, not a one-command `up`. See
**"What's verified vs documented"** at the bottom.

> **Why a whole VM and not more containers?** 5ire is an Electron *desktop* app —
> there's nothing to serve headlessly (that's exactly why Tier 1 substitutes the
> browser-based Open WebUI). To get the *real* 5ire GUI **and** let it spawn
> `mcp-kali-server` against Kali's actual tools, you need a Kali desktop. We run
> that desktop headless in QEMU (serial + SSH, like every Phase 2 VM) and reach
> the GUI by tunnelling an in-guest **VNC** server over the VM's SSH — no change
> to Phase 2, the same SSH-forward posture the rest of the repo uses.

---

## What's in this directory

| File | Role |
|---|---|
| `kali-llm-desktop.toml` | Phase 2 VM definition: Kali XFCE, 8 GB / 4 vCPU, disk-image backend. |
| `provision-kali-llm.sh` | **Runs *inside* the VM as root.** Installs Ollama + a model, `mcp-kali-server` + the tool set, the 5ire AppImage, and TigerVNC + XFCE. |
| `README.md` | This runbook. |

Reuses `phase2-qemu-vm/lab-vm.sh` unchanged — no new phase code.

---

## Prerequisites (on the lab host)

```bash
# Phase 2 disk-image backend deps + 7z to extract Kali's prebuilt image:
sudo apt-get install -y qemu-system-x86 ovmf p7zip-full jq
# A VNC viewer on whatever machine you'll watch the desktop from, e.g.:
#   sudo apt-get install -y tigervnc-viewer      # or remmina, or macOS Screen Sharing
```

KVM strongly recommended (`ls /dev/kvm`) — an XFCE desktop under pure TCG is
painfully slow. Budget **~8 GB RAM** for the VM and **~20 GB disk** (Kali image +
the desktop/tool packages + Ollama model blobs).

---

## The workflow

### 1. Create + boot the Kali VM

```bash
cd /path/to/LAB_CREATE_V2
phase2-qemu-vm/lab-vm.sh create --config examples/kali-llm-desktop-lab/kali-llm-desktop.toml
phase2-qemu-vm/lab-vm.sh start  kali-llm-desktop
```

First `create` downloads + extracts Kali's prebuilt QEMU image (several GB,
cached afterward). The VM runs **headless** (serial console + SSH).

### 2. First-boot setup (Kali images have no cloud-init)

Kali's prebuilt images don't ship cloud-init, so SSH is enabled by hand once —
exactly as [`../vm-kali-amd64.toml`](../vm-kali-amd64.toml) documents:

```bash
phase2-qemu-vm/lab-vm.sh console kali-llm-desktop      # login: kali / kali
#   (in the guest:)
sudo systemctl enable --now ssh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# paste your PUBLIC key into ~/.ssh/authorized_keys, then chmod 600 it:
nano ~/.ssh/authorized_keys        # (Ctrl-A then Ctrl-] frees the serial console)
```

Read back the auto-allocated SSH port and confirm SSH works:

```bash
PORT=$(phase2-qemu-vm/lab-vm.sh inspect kali-llm-desktop --json | jq -r .ssh_port)
phase2-qemu-vm/lab-vm.sh ssh kali-llm-desktop -- uname -a    # → Linux … kali
```

### 3. Provision the whole stack inside the VM

```bash
scp -P "$PORT" examples/kali-llm-desktop-lab/provision-kali-llm.sh kali@127.0.0.1:/tmp/
phase2-qemu-vm/lab-vm.sh ssh kali-llm-desktop -- 'sudo bash /tmp/provision-kali-llm.sh'
```

This installs Ollama (+ pulls `llama3.2:1b` by default), `mcp-kali-server` and
the tool set, the 5ire AppImage to `/opt/5ire`, and TigerVNC + XFCE; then it
starts a VNC desktop on `:1` (loopback only) and prints the exact tunnel command.
Knobs (prefix the remote command):

```bash
# heavier model, skip metasploit/wordlists, set a real VNC password:
phase2-qemu-vm/lab-vm.sh ssh kali-llm-desktop -- \
  'sudo MODEL=llama3.2:3b LITE=1 VNC_PASS=changeme bash /tmp/provision-kali-llm.sh'
```

| Env | Default | Meaning |
|---|---|---|
| `MODEL` | `llama3.2:1b` | Ollama model to pull (the blog used 3b/4b/8b on a GPU). |
| `FIVEIRE_VER` | `0.15.3` | 5ire AppImage release (the blog's version). |
| `LITE` | *(off)* | `LITE=1` skips `metasploit-framework` + `wordlists` (big). |
| `VNC_PASS` | `kali` | VNC password — **change it** for anything but a throwaway. |

### 4. Open the desktop (VNC over SSH) and use 5ire

Keep this tunnel open in its own terminal — it maps your machine's `localhost:5901`
to the VM's loopback-only VNC server:

```bash
ssh -p "$PORT" -L 5901:localhost:5901 kali@127.0.0.1
```

Point your VNC viewer at **`localhost:5901`** (password = `VNC_PASS`). In the XFCE
desktop, launch **5ire** (Applications menu, or `/opt/5ire/5ire-x86_64.AppImage`)
and follow the blog:

1. **Workspace → Providers → Ollama** → enable. 5ire's default endpoint
   `http://localhost:11434` is correct (Ollama runs in this same VM). Enable your
   model (toggle **Enabled**, and **Tools** so it can call MCP).
2. **Tools → Local** → add: Name `mcp-kali-server`, Command `/usr/bin/mcp-server`
   → enable. 5ire spawns it over stdio; it exposes nmap/sqlmap/… as MCP tools.
3. **New Chat → Ollama →** try the blog's headline demo:
   > `do a port scan of scanme.nmap.org`

   The model emits an MCP tool call, `nmap` actually runs in the VM, and the
   results come back into the chat. That's the full Tier 3 agentic loop.

### 5. Tear down

```bash
phase2-qemu-vm/lab-vm.sh destroy kali-llm-desktop --force
```

Everything (model blobs, installed tools, 5ire config) lived in the VM's disk, so
destroy reclaims it all. To keep the VM but stop it: `lab-vm.sh stop kali-llm-desktop`.

---

## ⚠️ Security — read before the MCP demo

This lab is **Tier 3**: a local LLM with an MCP tool that runs **real offensive
tools** (`nmap`, `hydra`, `sqlmap`, `metasploit`, …). That turns "chat" into "an
agent that can attack things." Treat it accordingly:

- **Only ever target hosts you are authorized to test.** The blog uses
  `scanme.nmap.org` — Nmap's sanctioned test host. Do not point it at anything else
  you don't own or have written permission to assess.
- **Keep the VM on an isolated network** with no route to machines you don't own.
  QEMU user-net already firewalls the guest (outbound NAT, no inbound except the
  SSH hostfwd), but the *guest itself* can reach the internet — so the LLM can
  scan outward. Cut that off (`--no-network`-style host firewall, or an isolated
  bridge) if you're not actively running the authorized demo.
- **Prompt injection is a live risk here.** A malicious page, file, or even a
  scanned service's banner that the model ingests can rewrite its instructions and
  steer the agent into scanning/exploiting hosts you never intended. Don't feed it
  untrusted content while the MCP tools are enabled.
- **It runs as root in the VM** (the blog's setup; `mcp-server` and the tools need
  it). The VM is the blast radius — keep it **disposable** and trust nothing it
  produces.
- **Ollama's API is unauthenticated** and the **VNC server has a weak default
  password** — both are bound to **loopback only** and reached via SSH-forward.
  Never `-localhost no` the VNC server or publish 11434 on a real interface.

---

## GPU acceleration (advanced — vfio passthrough)

Tier 1 gets a GPU cheaply via rootless-podman **CDI** (`devices = ["nvidia.com/gpu=all"]`).
That path does **not** apply here: this is a full VM, so the GPU has to be handed
to the *guest* via **vfio PCI passthrough** — host-specific and much heavier:

- Host needs IOMMU on (`intel_iommu=on` / `amd_iommu=on`), the GPU bound to
  `vfio-pci` (and isolated in its own IOMMU group), and `lab-vm.sh` would need a
  `-device vfio-pci,host=<BDF>` passthrough hook (not currently a TOML field).
- It's all-or-nothing: a passed-through GPU leaves the host (no display on it
  while the VM holds it), so you typically need a second GPU for the host.

For most users the CPU default (small model) is the right call here; reach for
**Tier 1 + CDI** when you want GPU-accelerated Ollama without VM passthrough pain.
Treat in-VM GPU as a documented future hook, not a turnkey step.

---

## What's verified vs documented

Being honest about what was actually exercised on this host vs. what is a written
procedure you run yourself:

| Step | Status |
|---|---|
| `kali-llm-desktop.toml` parses; fields valid | ✅ verified (`tomllib`) |
| `provision-kali-llm.sh` syntax | ✅ verified (`bash -n`) |
| `lab-vm.sh inspect … --json \| jq .ssh_port` port read-back | ✅ verified against `lab-vm.sh` (`cmd_inspect`) |
| Kali image download + full ~multi-GB VM boot | 📄 documented — too heavy to boot here |
| In-VM provisioning (Ollama/5ire/MCP/VNC install) | 📄 documented — runs inside the VM |
| The 5ire GUI + MCP `scanme.nmap.org` demo | 📄 documented — interactive desktop |
| GPU vfio passthrough | 📄 documented hook only — host-specific |

For a path that **is** fully verified end-to-end on a lab host (Open WebUI HTTP
200, `/api/generate` round-trip), use **Tier 1** in [`../kali-llm-lab/`](../kali-llm-lab/).
See [`../../KALI_LLM_LAB_PLAN.md`](../../KALI_LLM_LAB_PLAN.md) for the full design.
