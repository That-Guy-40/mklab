# Kali Local-LLM (Ollama + 5ire + MCP) Lab — Design Plan v1

> **Status**: v1 — derived from the Kali blog *"Local LLM with Ollama & 5ire"*
> (https://www.kali.org/blog/kali-llm-ollama-5ire/) and adapted to
> LAB_CREATE_V2's existing phase machinery.
> **Tier 1 — IMPLEMENTED (2026-05-29)** in `examples/kali-llm-lab/` and
> boot-verified end-to-end (pod up; `ollama` + `open-webui` running; a model
> pulled into the volume; a real `/api/generate` returned a completion; Open
> WebUI served HTTP 200). **Tier 2 (real 5ire) — documented** in the lab README.
> **Tier 2-full (faithful Kali desktop VM) + Tier 3 (agentic MCP) —
> IMPLEMENTED-AS-RUNBOOK (2026-05-29)** in `examples/kali-llm-desktop-lab/`: a
> Phase-2 Kali XFCE VM + an in-VM provisioner installing Ollama + the real 5ire
> AppImage + `mcp-kali-server` + the tool set + TigerVNC, reached via
> VNC-through-SSH. Cheap parts verified (TOML parse, `bash -n`, the
> `inspect --json | jq .ssh_port` port read-back); the multi-GB VM boot / GUI /
> MCP demo / GPU vfio are documented procedures (see that lab's "What's verified
> vs documented").
> Lives at repo root next to `ALMALINUX_PXE_LAB_PLAN.md` /
> `NETBOOT_LAB_PLAN.md` / `MICRO_LINUX_LAB_PLAN.md`.
> **Directories:** `examples/kali-llm-lab/` (Tier 1) + `examples/kali-llm-desktop-lab/` (Tier 2-full).

---

## 1. What the blog actually builds

A fully-local, offline AI assistant on Kali that can **drive Kali's own
offensive tools** by voice/chat. Three moving parts:

| Piece | What it is | In the blog |
|---|---|---|
| **Ollama** | local LLM runtime (a `llama.cpp` wrapper); HTTP API on **:11434** | tarball + systemd unit; `ollama pull llama3.1:8b / llama3.2:3b / qwen3:4b`; NVIDIA GTX 1060 6 GB / CUDA 12.4 |
| **5ire** | a desktop **GUI** AI assistant + **MCP client** (Electron AppImage) | downloaded to `/opt/5ire/`; GUI-configured to use the local Ollama provider |
| **mcp-kali-server** | an **MCP server** exposing Kali tools (nmap, gobuster, nikto, hydra, john, sqlmap, wpscan, enum4linux-ng, metasploit) to the model | `apt install mcp-kali-server …`; a Flask API on **:5000** + the `mcp-server` MCP wrapper at `/usr/bin/mcp-server`; 5ire → Tools → Local → command `/usr/bin/mcp-server` |

The payoff demo: ask the assistant to "port-scan scanme.nmap.org," the LLM
emits an MCP tool call, `mcp-kali-server` runs the real `nmap`, and the result
flows back into the chat. Everything local, no SaaS.

> **Port note.** Standard Ollama serves **:11434** (the blog's `:5000` is the
> *mcp-kali-server* Flask API, not Ollama). This plan uses 11434 for Ollama and
> 5000 for the Kali-MCP Flask service, and says so explicitly to avoid the
> blog's ambiguity.

---

## 2. The crux: three pieces, three *very* different homes

This is **not** a netboot/install lab like the AlmaLinux/Rocky/Kali-PXE labs.
It's an **application stack**, and the three pieces containerize very
differently — which is the central design problem:

| Piece | Containerizable headless? | Natural home |
|---|---|---|
| **Ollama** | ✅ trivially — official image, HTTP API, stateless but for the model cache | **Phase 4 rootless podman** (or Phase 3 docker) |
| **mcp-kali-server** | ⚠️ yes, but heavy — needs the Kali toolset (`kalilinux/kali-rolling` + a big apt install) | Phase 4 podman **Kali container**, or inside a Phase 2 Kali VM |
| **5ire** | ❌ **no** — it's a desktop Electron GUI; there's nothing to "serve" headlessly | a real desktop: the **host**, or a **Phase 2 Kali desktop VM** |

So a faithful, fully-self-contained, *headless* lab is impossible with 5ire as
written — a GUI app needs a display. The plan resolves this with **fidelity
tiers** (the same pattern the netboot lab uses: minimal → busybox → full), so
the default is turnkey/headless and the faithful path is documented on top.

---

## 3. Proposed design — three fidelity tiers

```
                          examples/kali-llm-lab/
   ┌─────────────────────────────────────────────────────────────────────┐
   │ TIER 1  (default, headless, self-contained)   — Phase 4 rootless     │
   │   ┌──────────────┐        ┌────────────────┐                         │
   │   │  ollama       │  :11434│  open-webui     │  :8080  ── browser via │
   │   │ (LLM backend) │◀───────│ (chat UI = the  │         SSH-forward    │
   │   │  model volume │        │  headless 5ire  │                        │
   │   └──────────────┘         │  stand-in)      │                        │
   │        ▲                   └────────────────┘                         │
   │        │ Ollama API over the shared POD localhost (one pod, 2 svcs)   │
   ├────────┼──────────────────────────────────────────────────────────── │
   │ TIER 2  (faithful client)                                             │
   │        └── real 5ire AppImage on the HOST desktop  (or a Kali VM)     │
   │            → its Ollama provider points at the Tier-1 endpoint        │
   ├─────────────────────────────────────────────────────────────────────│
   │ TIER 3  (agentic / the blog's payoff)        ⚠️ offensive-tool access │
   │   ┌────────────────────────┐                                          │
   │   │ kali-mcp (kali-rolling  │  exposes nmap/sqlmap/metasploit/… as     │
   │   │  + mcp-kali-server)     │  MCP tools the model can invoke          │
   │   └────────────────────────┘  ON AN ISOLATED NETWORK, default OFF     │
   └─────────────────────────────────────────────────────────────────────┘
```

### Tier 1 — Ollama + Open WebUI (the turnkey core) — ✅ IMPLEMENTED

The reproducible, headless, repo-idiomatic heart of the lab. A Phase 4 rootless
podman topology:

- **`ollama`** — `docker.io/ollama/ollama` (pin a digest). Named volume
  `ollama-models → /root/.ollama` so pulled models survive `down`/`up`. Bound
  **loopback only**.
- **`open-webui`** — `ghcr.io/open-webui/open-webui` with
  `OLLAMA_BASE_URL=http://localhost:11434` (shared pod localhost). A browser chat UI — the **headless
  stand-in for 5ire** (5ire is a desktop app; Open WebUI is the functional
  equivalent you can reach over an SSH-forward, exactly like Phase 6b).
- Reached via `ssh -L 8088:localhost:8088 labhost` → `http://localhost:8088`
  (host ports 8088/11435 dodge the commonly-occupied 8080/11434).

**Why Open WebUI and not 5ire here?** 5ire cannot run headless. Open WebUI gives
the same "chat with your local model" experience in a browser, keeps the lab
fully self-contained and SSH-forwardable, and matches the repo's existing
web-UI posture (Phase 6b). The plan is explicit that this is an *adaptation*,
not the blog's literal client — and Tier 2 restores fidelity.

### Tier 2 — real 5ire against the lab's Ollama (faithful client) — ✅ documented in the lab README

No new containers. The README documents:
- Install the **5ire AppImage** per the blog (host Kali desktop, or a Phase 2
  Kali desktop VM via `examples/vm-kali-amd64.toml` / the `kali-pxe-lab`).
- Point 5ire → Workspace → Providers → **Ollama** at the Tier-1 endpoint
  (`http://localhost:11434` if 5ire runs on the same host as the container with
  the port published; or `http://<lab-host>:11434` over the network — see
  Security).
- This is the blog's literal client, talking to our reproducible backend.

### Tier 3 — mcp-kali-server (the agentic pentest payoff) ⚠️ — ✅ realized in the Tier 2-full VM

The blog's headline capability: the LLM driving real Kali tools via MCP. This is
**powerful and dangerous** (see §6) and is **opt-in, isolated, authorized-targets-only**.

As built, Tier 3 lives **inside the Tier 2-full Kali desktop VM**
(`examples/kali-llm-desktop-lab/`) rather than as a separate container — that's
the faithful blog topology (5ire spawns `mcp-server` locally over stdio, against
in-VM tools):

- `provision-kali-llm.sh` installs `mcp-kali-server` + the blog's tool set (nmap,
  gobuster, nikto, hydra, john, sqlmap, wpscan, enum4linux-ng, and —unless
  `LITE=1`— metasploit-framework + wordlists).
- Wired to 5ire as a Local MCP tool (**Tools → Local → Command `/usr/bin/mcp-server`**).
- The VM is the isolation boundary; the README ships a single explicitly-authorized
  target (`scanme.nmap.org`, as the blog uses) and a loud warning, and tells you to
  keep the VM off any network with hosts you don't own.

> An alternative **container-only** Tier 3 (an isolated-network `kali-mcp` service
> built from `kalilinux/kali-rolling`, `mcp-server` / Flask on :5000) remains a
> valid lighter-weight variant for the Tier-1 stack — sketched below — but the
> in-VM realization above is what's faithful to the blog and what's now shipped.

---

## 4. How it maps onto LAB_CREATE_V2

| Blog step | mklab component | Status |
|---|---|---|
| Run Ollama as a service | Phase 4 `lab-podman.sh` `[[service]]` | **Reuse** (new TOML) |
| Persist pulled models | a named volume in the service `volumes` | **Reuse** |
| Pull models | new `pull-models.sh` (wraps `podman exec … ollama pull`) | **New** (small) |
| Browser chat client | Open WebUI `[[service]]` (Tier 1) | **Reuse** |
| Desktop chat client (5ire) | host, or Phase 2 Kali VM (`vm-kali-amd64.toml`) | **Reuse + document** |
| Kali-tools MCP server | Phase 4 `build`-backend service from `kalilinux/kali-rolling` | **New** Containerfile |
| GPU acceleration | rootless podman CDI via the Phase-4 `devices` key | **Implemented** (`devices = ["nvidia.com/gpu=all"]`) |
| Surface the running containers | Phase 6 TUI / Phase 6b web | **Reuse** (free) |

**No new phase code is needed.** Everything rides existing `lab-podman.sh`
features (services, volumes, networks, `build`, `exec`). The only new *code* is
`pull-models.sh` and the optional `kali-mcp` Containerfile; the rest is a TOML +
README + INDEX rows — same shape as the PXE labs.

---

## 5. Proposed directory layout (`examples/kali-llm-lab/`)

| File | Role | Tier |
|---|---|---|
| `kali-llm-lab.toml` | Phase 4 topology: `ollama` + `open-webui` on a private net, loopback-published | 1 |
| `pull-models.sh` | `podman exec kali-llm-ollama ollama pull <model>` — default a CPU-friendly small model, blog models as opt-in flags | 1 |
| `kali-mcp.Containerfile` | `FROM kalilinux/kali-rolling` + apt `mcp-kali-server` + tools; entrypoint runs `mcp-server` | 3 |
| `kali-llm-lab.toml` `[[service]]` `kali-mcp` (commented/opt-in) | the agentic tier, default-off | 3 |
| `README.md` | runbook for all three tiers, 5ire wiring, GPU opt-in, **security**, why-notes | all |
| `MANUAL_TESTING.md` *(optional, later)* | end-to-end verify like the PXE labs | all |

### As-built `kali-llm-lab.toml` (Tier 1 — implemented)

The shipped TOML uses a **pod** rather than a bridge network — cleaner than the
original sketch, because pod members share `localhost`, so `open-webui` reaches
`ollama` at `http://localhost:11434` with no brittle container-name DNS. Host
ports dodge the canonical 8080/11434 (commonly occupied — a native
`ollama serve` already owns 11434; this repo's netboot labs likewise dodge 8080):

```toml
[lab]
name = "kali-llm"
tags = ["kali", "llm", "ollama", "open-webui", "ai", "mcp"]

[[pod]]
name    = "llmstack"
publish = ["127.0.0.1:8088:8080", "127.0.0.1:11435:11434"]  # host:container

[[service]]
name = "ollama"
engine = "podman"
image = "docker.io/ollama/ollama:latest"     # pin @sha256:… in practice
manager = "pod"
pod = "llmstack"
volumes = ["kali-llm-ollama:/root/.ollama"]    # named volume; podman auto-creates

[[service]]
name = "open-webui"
engine = "podman"
image = "ghcr.io/open-webui/open-webui:main"
manager = "pod"
pod = "llmstack"
environment = { OLLAMA_BASE_URL = "http://localhost:11434", WEBUI_AUTH = "true" }
volumes = ["kali-llm-webui:/app/backend/data"]
```

**Pre-build checks — resolved against `lab-podman.sh` (read + live-verified):**
`127.0.0.1:`-prefixed publishes pass through verbatim ✅; named volumes
auto-create and correctly skip the SELinux `:Z` suffix (audit finding F10) ✅;
pod members honor `volumes` + `environment` ✅. **GPU `devices` key: now
implemented** — a per-service `devices = [...]` field emits `podman run
--device …` in both the plain and pod paths (validated against flag-injection;
unit + live `/dev/fuse` passthrough tested). GPU is opt-in by uncommenting
`devices = ["nvidia.com/gpu=all"]` on the `ollama` service.

### INDEX.md rows (proposed)

- A new **"🤖 AI / LLM"** subsection (or under Phase 4) with a
  `[`kali-llm-lab/`](kali-llm-lab/)` row describing the tiered stack.
- A unified-demos style row since it can span Phase 4 (+ Phase 2 for the Kali
  desktop VM in Tier 2).

---

## 6. Security posture (first-class — this lab is sharper than most)

This lab combines two high-risk surfaces. The README must lead with this.

1. **Ollama's API is unauthenticated.** Anyone who can reach `:11434` can run
   models, exhaust GPU/RAM, enumerate/pull/delete models, and hit any Ollama
   CVEs (there have been path-traversal / RCE-class issues in the model/blob
   handlers). **Default: bind loopback (`127.0.0.1:11434`)**; reach it via
   SSH-forward. Never publish `0.0.0.0:11434` on an untrusted network. (Mirrors
   the Phase 6b stance: loopback default, auth/proxy before exposure.)

2. **Open WebUI auth.** Enable `WEBUI_AUTH=true` (first registered user becomes
   admin). Still loopback + SSH-forward by default.

3. **Tier 3 is "an LLM that can run offensive tools" — treat it as such.**
   `mcp-kali-server` gives the model the ability to execute `nmap`, `hydra`,
   `sqlmap`, `metasploit`, etc. with whatever arguments the model decides.
   Combined with **prompt injection** (a malicious web page, file, or target
   banner the model ingests can rewrite its instructions), this is a path from
   "chat" to "the agent attacks a target." Mitigations the plan mandates:
   - **Default OFF** (commented in the TOML; explicit opt-in to enable).
   - **Isolated network** — the `kali-mcp` container gets a podman network with
     no route to anything you don't own; document `--internal`-style isolation.
   - **Authorized targets only** — the only example target is `scanme.nmap.org`
     (Nmap's sanctioned test host), with a banner: *never point this at hosts or
     networks you are not explicitly authorized to test.*
   - **Throwaway containers** — the Kali-MCP container is disposable; nothing it
     does should be trusted or persisted.
   - Note the blog runs the MCP server **as root** — in our container that's
     contained to the (rootless, user-namespaced) container, but we still
     document dropping privileges / read-only mounts where possible.

4. **Model provenance.** Models come from the Ollama registry; Ollama verifies
   blob digests on pull. Note GGUF-parsing has had CVEs, so treat untrusted
   third-party models like untrusted input. Pin the model and registry in
   `pull-models.sh`.

---

## 7. Resource sizing & GPU (the honest constraints)

- **CPU-only default.** The blog's models (3–8B) want a GPU (it used a 6 GB
  GTX 1060). For a lab that runs anywhere, **default to a tiny model** —
  `qwen2.5:0.5b` (~400 MB) or `llama3.2:1b` (~1.3 GB) — which answers on CPU in
  a few GB RAM. `pull-models.sh` defaults to the small model and documents the
  blog's `llama3.2:3b` / `qwen3:4b` / `llama3.1:8b` as upgrades.
- **GPU opt-in (rootless podman, NVIDIA).** Document the CDI path:
  `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`, then add
  `--device nvidia.com/gpu=all` via the service's `devices` key (now wired in
  lab-podman.sh). Faithful to the blog's `nvidia-driver`+`nvidia-smi` step,
  adapted to containers.
- **Disk.** Model cache lives in the `ollama-models` volume; a few GB for small
  models, tens of GB if the user pulls the big ones. Persists across restarts.

---

## 8. Exit criteria (what "done" means)

1. `lab-podman.sh up --config examples/kali-llm-lab/kali-llm-lab.toml` brings up
   `ollama` + `open-webui` rootless; both reachable on loopback.
2. `pull-models.sh` pulls the default small model into the persistent volume;
   it survives `down` + `up`.
3. `curl http://127.0.0.1:11434/api/tags` lists the model;
   `curl -s http://127.0.0.1:11434/api/generate -d '{"model":"…","prompt":"hi"}'`
   returns a completion (the headless backend proof).
4. Browser (over SSH-forward) → Open WebUI → chat with the model works.
5. **Tier 2:** README steps wire a real 5ire to the endpoint (verified by hand
   on a desktop / Kali VM — documented, not automated, since it's a GUI).
6. **Tier 3:** with the opt-in `kali-mcp` service up and the MCP tool registered,
   a prompt like "scan scanme.nmap.org" produces a real `nmap` run via MCP — on
   the isolated network, against the sanctioned target only.
7. Security section present; loopback-default verified; Tier 3 ships default-off.

---

## 9. What's faithful vs. adapted (be upfront)

| Blog | This lab | Why |
|---|---|---|
| Ollama via tarball + systemd | Ollama via rootless podman + volume | Reproducible, disposable, matches the repo idiom; same API |
| 5ire desktop GUI as the client | **Tier 1:** Open WebUI (browser); **Tier 2:** real 5ire documented | 5ire can't run headless; Open WebUI keeps Tier 1 self-contained, Tier 2 restores fidelity |
| `mcp-kali-server` on the host | Tier 3 Kali container, isolated, opt-in | Keeps the dangerous tool-exec surface disposable + contained |
| GPU on the host | rootless-podman CDI passthrough (opt-in) | Faithful capability, container-native |
| 3–8B models | small model default, blog models documented | Runs without a GPU; upgradeable |

---

## 10. Open questions / pre-build checks

1. **`lab-podman.sh` feature check** — confirm it supports: (a) a
   `127.0.0.1:`-prefixed host bind in `ports`, (b) named-volume references that
   podman auto-creates, (c) a per-service `devices` key for CDI GPU passthrough — NOW IMPLEMENTED,
   (d) `build` services from a `Containerfile` in the lab dir. Any gaps are
   small, contained Phase-4 additions — to be scoped before implementation, not
   assumed.
2. **Open WebUI vs. LibreChat vs. a minimal `curl`-only Tier 1.** Open WebUI is
   the richest browser client but a large image; a `curl`/`/api/generate`
   smoke-test path could be the truly-minimal Tier 0. Decide during build.
3. **MCP wiring for Open WebUI.** 5ire speaks MCP natively; Open WebUI's
   tool/pipeline model differs. Tier 3 may be cleanest demonstrated with 5ire
   (Tier 2 client) rather than Open WebUI. Document accordingly.
4. **Kali-MCP image size/build time.** `metasploit-framework` + wordlists is
   large; consider a "lite" tool subset (nmap/sqlmap/gobuster/nikto) as the
   default Containerfile, full set as a build-arg.
5. **Pin digests** for `ollama/ollama` and `open-webui` (supply chain), as the
   other labs pin installer checksums.

---

## 11. Suggested build order (when greenlit)

1. Tier 1 TOML (`ollama` + `open-webui`) + `pull-models.sh` + README core. Verify
   exit criteria 1–4.
2. README Tier 2 (5ire wiring) + cross-links to `vm-kali-amd64.toml` /
   `kali-pxe-lab/`.
3. Tier 3 `kali-mcp.Containerfile` + opt-in service + the security section.
4. GPU opt-in docs. INDEX rows. Optional `MANUAL_TESTING.md`.
5. Any small `lab-podman.sh` additions surfaced by the §10 feature check, each
   with tests (the Phase 4 suite is fixture-based).

---

## 12. Decision (resolved 2026-05-29)

The maintainer chose **Tier 1 as the implemented default** — the headless
Ollama + Open WebUI pod reached over SSH-forward, with the real 5ire wired
from the client (Tier 2) — and initially asked to **plan, but defer, Option 2**
(the faithful full Kali desktop VM running 5ire + `mcp-kali-server` in-VM) plus
the agentic MCP Tier 3. Open WebUI (not a `curl`-only Tier 0) is the shipped
Tier-1 client, since the maintainer wanted a backing GUI on the client side.

### Update (2026-05-29, same day): Option 2 promoted from deferred to built

The maintainer then asked to *"do a real tier 2-full,"* so Option 2 is no longer
deferred: it ships as `examples/kali-llm-desktop-lab/` — a Phase-2 Kali XFCE VM
with an in-VM `provision-kali-llm.sh` that installs the *whole* blog stack
(Ollama + the real 5ire AppImage + `mcp-kali-server` + tools + TigerVNC), the
GUI reached over VNC-through-SSH. Tier 3 is realized in-VM there (§3). Verified
cheaply (TOML parse, `bash -n`, port read-back); the multi-GB VM boot, the GUI,
the MCP `scanme.nmap.org` demo, and GPU vfio are documented procedures, clearly
labelled in that lab's "What's verified vs documented" table — not claimed as
machine-verified here.
