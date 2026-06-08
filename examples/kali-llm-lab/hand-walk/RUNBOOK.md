# Hand-walk: *Kali & LLM — local with Ollama & 5ire*, by hand

Follow the Kali blog **inside a Kali container that carries the prerequisites** —
install Ollama the post's way, run a model **on CPU**, and expose Kali's tools to
the model via `mcp-kali-server`. This is the **server side**; the 5ire GUI is the
*client* (see the sibling desktop lab).

- **The post (byte-exact archive):** [`../upstream-tutorial/`](../upstream-tutorial/) ·
  canonical: <https://www.kali.org/blog/kali-llm-ollama-5ire/>
- **The environment as code:** [`Containerfile`](Containerfile) — Kali +
  the fetch/unpack tools (Ollama install + model pull are RUNBOOK steps).
- **Automated + GUI counterparts:** the verified Phase-4 pod
  [`../kali-llm-lab.toml`](../kali-llm-lab.toml) (Ollama + Open WebUI) is the
  turnkey version; the real-5ire GUI lives in the
  [`../../kali-llm-desktop-lab/`](../../kali-llm-desktop-lab/) VM.

> ### Honest framing
> This hand-walk is **authored, not built in this sandbox** — by design:
> 1. **Multi-GB.** The Kali base + any useful model are gigabytes; this is a
>    deliberate, explicit pull, not something to bake silently.
> 2. **Ollama is a fetched prebuilt binary.** The post installs it by downloading
>    + executing `ollama-linux-amd64.tar.zst` from ollama.com — your machine's
>    call to trust (the same posture as this repo's toolchain-fetch gate). The
>    post sha512-verifies it; §1 below does too.
>
> So §1 (Ollama) and §3 (model) are steps **you** run. Want it working with zero
> fuss instead? Use the verified pod `../kali-llm-lab.toml`.

---

## 0. Bring up the box

```bash
# on your machine, from the repo root:
phase4-podman/lab-podman.sh build --tag kali-llm-handwalk \
    --context examples/kali-llm-lab/hand-walk
podman run --rm -it -p 11434:11434 kali-llm-handwalk bash    # 11434 = Ollama's API port
```

---

## 1. Install Ollama — the post's exact method (fetch + **verify** + unpack)

The post deliberately *checks the download* before trusting it — do the same:

```bash
curl --fail --location https://ollama.com/download/ollama-linux-amd64.tar.zst \
    > /tmp/ollama-linux-amd64.tar.zst
file /tmp/ollama-linux-amd64.tar.zst                 # → Zstandard compressed data
sha512sum /tmp/ollama-linux-amd64.tar.zst            # compare to the value in the post
tar x -v --zstd -C /usr -f /tmp/ollama-linux-amd64.tar.zst
```

**CPU-only note.** The post also installs `nvidia-driver`/`nvidia-smi` for GPU
acceleration — **skip that here**: Ollama runs fine on CPU (just slower). That's
the one deliberate divergence from the post for this server box.

The post then creates an `ollama` user + a **systemd** service
(`systemctl enable --now ollama`). A plain container has no systemd as PID 1, so
run the server directly:

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve &     # bind all interfaces so :11434 is reachable
```

> **Why podman + `serve &` here, not the systemd unit (a deliberate choice).**
> This box reproduces what matters for the walk — the **Ollama API + Kali tools**
> — and matches the repo's existing Phase-4 pod [`../kali-llm-lab.toml`](../kali-llm-lab.toml),
> which likewise runs Ollama as a process, not a unit. The post's
> `useradd -r … ollama` + `ollama.service` is the *host* install idiom. If you
> specifically want the **systemd unit running as written**, that's the one case
> in this fleet that calls for a **system container**: run this on a real Kali
> host, or build it as a **Phase-5 LXD/Incus** instance (systemd as PID 1, import
> a Kali rootfs via `lab-lxd.sh --from-chroot`) and `systemctl enable --now
> ollama` there. For learning the API + MCP flow, the process form above is
> simpler and equivalent.

---

## 2. Talk to it

```bash
curl -s http://localhost:11434/api/version       # server up?
```

---

## 3. Pull a model (gigabytes — your choice)

```bash
ollama pull qwen2.5:0.5b      # tiny, CPU-friendly; the post uses larger GPU models
ollama run  qwen2.5:0.5b "Say hello from Kali."
```

The repo's [`../pull-models.sh`](../pull-models.sh) scripts this for the pod.

---

## 4. The agentic payoff: `mcp-kali-server`

This exposes Kali's tools (`nmap`, `sqlmap`, `metasploit`, …) to the model as
**MCP** tools, so an MCP-aware client can drive them. It pulls in real tooling, so
it's a chunky install:

```bash
apt-get update && apt-get install -y mcp-kali-server   # + the tools you want it to wrap
mcp-kali-server --help
```

⚠️ **Offensive tooling — authorized targets only.** This is the same posture as
the rest of the repo's Kali labs.

---

## 5. Chat with a GUI

Your `:11434` Ollama API is now reachable from a chat client:
- **Open WebUI** (browser, headless) — exactly what the repo's pod
  [`../kali-llm-lab.toml`](../kali-llm-lab.toml) wires up.
- **5ire** (the post's desktop GUI, with MCP) — the real thing runs in the
  [`../../kali-llm-desktop-lab/`](../../kali-llm-desktop-lab/) VM, pointed at an
  Ollama like this one.

---

## 6. Tear down & provenance

`exit` the `--rm` box; it's gone (models included — re-pull next time, or use a
volume). `podman rmi kali-llm-handwalk`.

- **Provenance.** The archived post under [`../upstream-tutorial/`](../upstream-tutorial/)
  is the work of **Kali / OffSec**; all rights remain with them. Vendored for
  offline reference; this runbook only operationalises it. Prefer the
  [canonical page](https://www.kali.org/blog/kali-llm-ollama-5ire/).
- **Status:** *authored, you build* — multi-GB Kali base + model, and the Ollama
  install is a fetch-and-exec you authorize on your own machine (§1 verifies it).
  For a verified, turnkey Ollama, use the Phase-4 pod `../kali-llm-lab.toml`.
