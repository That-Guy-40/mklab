# Adding a "package" — `kali-llm-lab`

Heads-up: this lab has **no apt packages to add**. It's a **Phase-4 Podman**
stack (`[[pod]]` + `[[service]]`) — no chroot, no VM, no `apt`. The unit of
"stuff you add" here is one of two things:

1. an **Ollama model** (the usual thing you want more of), or
2. another **container/service**.

Installing an apt package *inside* a running container is possible but
**ephemeral** — it's lost the next time the container is recreated (`down`/`up`).
The durable ways are below.

## 1. Add an Ollama model  ← most common

Models live in the persistent `kali-llm-ollama` volume, so they survive
`down`/`up`. Use the helper (a thin wrapper around
`lab-podman.sh exec kali-llm/ollama -- ollama pull`):

```bash
# lab must be up first:
phase4-podman/lab-podman.sh up --config examples/kali-llm-lab/kali-llm-lab.toml

# pull one or more models:
examples/kali-llm-lab/pull-models.sh qwen2.5:0.5b          # ultralight (~400 MB)
examples/kali-llm-lab/pull-models.sh llama3.2:3b qwen3:4b  # the blog's models (GPU recommended)
```

**Verify:**
```bash
phase4-podman/lab-podman.sh exec kali-llm/ollama -- ollama list
```

## 2. Add a service (another container)

Add a `[[service]]` block to `kali-llm-lab.toml` (attach it to the `llmstack`
pod so it shares `localhost` with ollama/open-webui), then re-up:

```toml
[[service]]
name    = "my-tool"
engine  = "podman"
image   = "docker.io/library/<image>:<tag>"
manager = "pod"
pod     = "llmstack"
```
```bash
phase4-podman/lab-podman.sh up --config examples/kali-llm-lab/kali-llm-lab.toml
```

**Verify:**
```bash
phase4-podman/lab-podman.sh status --lab kali-llm
```

## 3. (Rarely) bake an apt package into an image

If you genuinely need an OS package inside the `ollama` (or webui) container and
it must persist, don't `exec apt` — build a small derived image instead:

```dockerfile
# Containerfile
FROM docker.io/ollama/ollama:latest
RUN apt-get update && apt-get install -y --no-install-recommends <pkg> && rm -rf /var/lib/apt/lists/*
```
Build it, then point the service's `image = "localhost/<your-image>:tag"` in the
TOML and `up`. (For a throwaway lab this is usually overkill — prefer a model or
a service.)

## Why this differs from the offsec-awae chroot→VM flow

There's nothing to `apt install` and nothing to re-image: a container's contents
come from its **image**, and the only mutable state is the **named volumes**.
The "add to the TOML install line, then re-image" pattern doesn't apply —
the equivalents are `pull-models.sh` (data) and a new `[[service]]` (capability).
