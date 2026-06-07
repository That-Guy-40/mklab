# Kali local-LLM lab — Ollama + Open WebUI (headless), with real 5ire on the client

Run a **local LLM on Kali**, the reproducible/headless way: the heavy
**Ollama** backend runs rootless on a lab host; you reach a chat UI from your
laptop over an **SSH tunnel**. This is Tier 1 of the Kali blog
[*Local LLM with Ollama & 5ire*](https://www.kali.org/blog/kali-llm-ollama-5ire/),
adapted to LAB_CREATE_V2's Phase 4 (rootless podman). The source post is
vendored byte-exact under [`upstream-tutorial/`](upstream-tutorial/) (HTML + CSS
+ provenance + `sha256`s) so this lab stays reproducible and attributed offline.

The blog's actual stack is three pieces that containerize very differently:

| Piece | What it is | How this lab handles it |
|---|---|---|
| **Ollama** | local LLM runtime, HTTP API on :11434 | ✅ containerized (this lab) |
| **5ire** | a desktop GUI / MCP client | ❌ can't run headless → **Tier 1** uses Open WebUI in your browser; **Tier 2** wires the *real* 5ire on your client to this lab's Ollama |
| **mcp-kali-server** | exposes nmap/sqlmap/metasploit/… to the model as MCP tools | ✅ the agentic payoff — in the sibling **[`kali-llm-desktop-lab/`](../kali-llm-desktop-lab/)** (Tier 2-full) |

> **Design note.** 5ire is an Electron desktop app — there is nothing to serve
> headlessly, so a fully self-contained headless lab can't *be* 5ire. Tier 1
> uses **Open WebUI** (a browser chat client) as the headless stand-in, exactly
> the SSH-forward posture Phase 6b uses. Tier 2 restores blog fidelity by
> pointing the real 5ire desktop app at this same Ollama endpoint.

---

## What's in this directory

| File | Role |
|---|---|
| `kali-llm-lab.toml` | Phase 4 pod: `ollama` + `open-webui`, loopback-published. |
| `pull-models.sh` | Pull model(s) into the persistent volume via the running container. |
| `README.md` | This file. |

Reuses `phase4-podman/lab-podman.sh` unchanged — no new phase code.

---

## Prerequisites

```bash
sudo apt-get install -y podman jq yq curl     # rootless podman; no root needed to run the lab
podman info >/dev/null && echo "podman OK (rootless)"
```

~5 GB of disk for the two images (Ollama ~1.5 GB, Open WebUI ~3–4 GB) plus the
model (see **Hardware**). No GPU required for the default model.

---

## Tier 1 — the headless stack (this lab)

### 1. Bring it up

```bash
cd /path/to/LAB_CREATE_V2
phase4-podman/lab-podman.sh up --config examples/kali-llm-lab/kali-llm-lab.toml
```
First run pulls both images and starts a pod (`llmstack`) with the two
containers sharing `localhost`. Ports are published on the **host loopback
only**, on collision-safe numbers (`127.0.0.1:8088` for the UI,
`127.0.0.1:11435` for the Ollama API — the canonical 8080/11434 are commonly
taken, e.g. by a native `ollama serve` on 11434; change them in the TOML if
8088/11435 are busy too).

Confirm:
```bash
phase4-podman/lab-podman.sh list --lab kali-llm        # → ollama + open-webui, same POD
curl -s http://127.0.0.1:11435/api/version             # → {"version":"…"}  (the lab's Ollama)
```

### 2. Pull a model

```bash
examples/kali-llm-lab/pull-models.sh                   # default: llama3.2:1b (CPU-friendly)
# or, the blog's models (GPU recommended — see Hardware):
#   examples/kali-llm-lab/pull-models.sh llama3.2:3b qwen3:4b llama3.1:8b
curl -s http://127.0.0.1:11435/api/tags | jq '.models[].name'   # lists what's pulled
```

Smoke-test the backend directly (no UI needed):
```bash
curl -s http://127.0.0.1:11435/api/generate \
     -d '{"model":"llama3.2:1b","prompt":"say hi in 3 words","stream":false}' | jq -r .response
```

### 3. Reach the UI from your laptop (SSH-forward)

```bash
# On your laptop (not the lab host):
#   left of the colon = your laptop's port; right = the lab host's published port
ssh -L 8088:localhost:8088 -L 11434:localhost:11435 <lab-host>
# then open:
http://localhost:8088
```
Open WebUI prompts you to **create the first account** — it becomes the admin
(this is `WEBUI_AUTH=true`). Pick your model in the chat dropdown and go.

The `-L 11434:localhost:11435` forward (laptop 11434 → lab 11435) is only needed
for Tier 2 (real 5ire, which defaults to `localhost:11434`) or direct API calls
from your laptop; the browser UI only needs `8088`.

### 4. Tear down

```bash
phase4-podman/lab-podman.sh down --lab kali-llm
# Models + chat history persist in named volumes (kali-llm-ollama, kali-llm-webui).
# To reclaim that space too:
#   podman volume rm kali-llm-ollama kali-llm-webui
```

---

## Tier 2 — the *real* 5ire on your client (blog-faithful)

The lab provides the backend; run the actual 5ire desktop app on your machine
and point it here. With the `-L 11434:localhost:11435` SSH-forward from step 3
active (so your laptop's `localhost:11434` reaches the lab's Ollama):

1. Install 5ire per the blog (AppImage from its GitHub releases), on your
   desktop OS, e.g.:
   ```bash
   curl -fL https://github.com/nanbingxyz/5ire/releases/download/v0.15.3/5ire-0.15.3-x86_64.AppImage \
        -o ~/5ire.AppImage && chmod +x ~/5ire.AppImage && ~/5ire.AppImage
   ```
2. In 5ire → **Workspace → Providers → Ollama**: enable it. Because the SSH
   tunnel maps your laptop's `11434` → the lab's `11435`, 5ire's default
   `http://localhost:11434` reaches *this lab's* Ollama with no reconfig.
   Enable the model(s) you pulled (toggle **Enabled**, and **Tools** for MCP).
3. New Chat → Ollama → talk to your lab-hosted model.

This is the blog's exact client, against a reproducible, disposable backend.

---

## GPU acceleration (opt-in)

The default `llama3.2:1b` runs fine on CPU. For the blog's 3–8B models you'll
want an NVIDIA GPU. Rootless podman uses **CDI** (Container Device Interface):

```bash
# One-time host setup (needs the NVIDIA driver + nvidia-container-toolkit):
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list | grep nvidia.com/gpu      # confirm a device exists
```

Then just **uncomment the `devices` line** on the `ollama` service in
`kali-llm-lab.toml` and re-`up`:

```toml
[[service]]
name    = "ollama"
# ...
devices = ["nvidia.com/gpu=all"]      # whole GPU; or "nvidia.com/gpu=0" for one card
```

`lab-podman.sh` now wires a per-service `devices` key straight to
`podman run --device …` (works in both plain and pod services). Confirm the GPU
is visible inside the container:

```bash
podman exec lab-kali-llm-ollama nvidia-smi     # lists your GPU
```

CPU-only (no `devices` line) remains the default and needs no setup.

---

## Hardware (the honest constraints)

| Model | Size | Runs on | Notes |
|---|---|---|---|
| `qwen2.5:0.5b` | ~400 MB | CPU, ~2 GB RAM | ultralight; quick smoke tests |
| `llama3.2:1b` *(default)* | ~1.3 GB | CPU, ~3 GB RAM | good balance; the lab default |
| `llama3.2:3b` | ~2 GB | CPU slow / GPU | the blog's mid model |
| `qwen3:4b` | ~2.5 GB | GPU recommended | the blog's model |
| `llama3.1:8b` | ~4.7 GB | GPU (≥6 GB VRAM) | the blog's largest |

The blog ran on a 6 GB GTX 1060; that VRAM is why it stuck to 3–8B. CPU-only
works for the small models — just slower.

---

## Security

This stack has two sharp edges. Treat both seriously:

- **Ollama's API is unauthenticated.** Anyone who can reach it can run models,
  exhaust your RAM/GPU, and hit any Ollama CVE (the model/blob handlers have had
  path-traversal/RCE-class issues). This lab publishes it on
  **`127.0.0.1:11435` only** — reach it via SSH-forward, never publish it on
  `0.0.0.0` on an untrusted network. (Same posture as Phase 6b.)
- **Open WebUI:** `WEBUI_AUTH=true` is set so the first account is the admin.
  Still loopback + SSH-forward by default.
- **The agentic MCP tier (future state) is "an LLM that can run offensive
  tools."** See the TODO below for why that's a different risk class entirely.

---

## Tier 2-full — the faithful full Kali desktop (now its own lab)

> **Status: built** — see [`../kali-llm-desktop-lab/`](../kali-llm-desktop-lab/).
> What was "planned, not implemented" here now ships as a runbook lab.

Tier 1 (this lab) gives you the backend + a browser client. The blog's *full*
experience — the real 5ire desktop app **and** the `mcp-kali-server` letting the
model drive Kali's tools — really wants a **complete Kali desktop**, so it lives
in a sibling lab rather than here:

1. **A Phase 2 Kali XFCE VM** (`kali-llm-desktop.toml`), provisioned by
   `provision-kali-llm.sh` with Ollama + the 5ire AppImage + `mcp-kali-server`
   and the tool set (nmap, gobuster, nikto, hydra, john, sqlmap, wpscan,
   enum4linux-ng, metasploit) + TigerVNC, reached via **VNC-through-SSH**.
2. **MCP wired into 5ire** (Tools → Local → `/usr/bin/mcp-server`) so a prompt
   like *"port-scan scanme.nmap.org"* makes the model emit a tool call that runs
   the real `nmap` — the blog's headline demo (this is **Tier 3**).
3. **GPU passthrough to the VM** (vfio) for the larger models — documented as a
   host-specific hook there; harder than this lab's rootless-podman CDI path.

### ⚠️ Why Tier 3 is gated behind a serious warning

Giving an LLM an MCP tool that executes `nmap`/`hydra`/`sqlmap`/`metasploit`
turns "chat" into "an agent that can attack things." Combined with **prompt
injection** (a malicious page, file, or even a target's service banner that the
model ingests can rewrite its instructions), the agent can be steered into
scanning or exploiting hosts you never intended. The desktop lab therefore:

- keeps the offensive tools to the **isolated, disposable VM**, with no route to
  anything you don't own;
- allows **only explicitly-authorized targets** (the blog uses `scanme.nmap.org`,
  Nmap's sanctioned test host);
- trusts nothing the agent produces, and binds Ollama + VNC to **loopback only**.

**Never point an LLM-driven offensive-tool agent at hosts or networks you are
not authorized to test.** That warning is front-and-center in the desktop lab's
README, alongside an honest "verified vs documented" table.

See [`../kali-llm-desktop-lab/README.md`](../kali-llm-desktop-lab/) for the full
runbook and `KALI_LLM_LAB_PLAN.md` for the design (component mapping, exit
criteria, open questions).
