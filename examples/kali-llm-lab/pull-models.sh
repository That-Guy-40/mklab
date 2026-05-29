#!/usr/bin/env bash
# pull-models.sh — Pull one or more Ollama models into the kali-llm lab's
#                  persistent model volume, via the running ollama container.
#
# The lab must already be up:
#   phase4-podman/lab-podman.sh up --config examples/kali-llm-lab/kali-llm-lab.toml
#
# This wraps `lab-podman.sh exec kali-llm/ollama -- ollama pull <model>`, so the
# blobs land in the `kali-llm-ollama` named volume and survive down/up.
#
# Usage:
#   examples/kali-llm-lab/pull-models.sh [MODEL ...]
#
# With no args, pulls the CPU-friendly default (llama3.2:1b — ~1.3 GB, answers
# on CPU in a couple of GB of RAM).  Pass model tags to pull others, e.g.:
#   examples/kali-llm-lab/pull-models.sh qwen2.5:0.5b           # ultralight (~400 MB)
#   examples/kali-llm-lab/pull-models.sh llama3.2:3b qwen3:4b   # the blog's models (GPU recommended)
#   examples/kali-llm-lab/pull-models.sh llama3.1:8b           # the blog's largest (needs a GPU / lots of RAM)
#
# Why a tiny default?  The blog used 3–8B models on a 6 GB GPU.  This lab must
# run anywhere, so the default is small enough for CPU-only.  Upgrade per the
# examples above once you've confirmed your hardware (see README "Hardware").

set -euo pipefail

readonly LAB_PROG="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
# repo root is two levels up: examples/kali-llm-lab/ -> examples/ -> repo
readonly REPO_ROOT="${SCRIPT_DIR%/examples/*}"
readonly LAB_PODMAN="${REPO_ROOT}/phase4-podman/lab-podman.sh"
readonly LAB_CONFIG="${SCRIPT_DIR}/kali-llm-lab.toml"

# ─── Logging ────────────────────────────────────────────────────────────────
_log() {
    local level="$1"; shift
    local color reset
    if [[ -t 2 ]]; then
        case "$level" in
            info)  color=$'\033[36m' ;;
            warn)  color=$'\033[33m' ;;
            error) color=$'\033[31m' ;;
            *)     color='' ;;
        esac
        reset=$'\033[0m'
    else
        color=""; reset=""
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}
log_info()  { _log info  "$@"; }
log_warn()  { _log warn  "$@"; }
die()       { _log error "$@"; exit 1; }

case "${1:-}" in -h|--help)
    sed -n '2,28p' "$0"; exit 0 ;;
esac

[[ -x "$LAB_PODMAN" ]] || die "can't find lab-podman.sh at $LAB_PODMAN"

# Default model when none requested.
declare -a models=("$@")
[[ ${#models[@]} -gt 0 ]] || models=("llama3.2:1b")

# Pre-flight: is the ollama container actually running?  `exec` would fail with
# a less obvious message otherwise, so check and point at `up`.
if ! "$LAB_PODMAN" exec kali-llm/ollama -- ollama --version >/dev/null 2>&1; then
    die "the 'ollama' service isn't running.  Bring the lab up first:
  phase4-podman/lab-podman.sh up --config $LAB_CONFIG"
fi

log_info "pulling ${#models[@]} model(s) into the kali-llm-ollama volume:"
for m in "${models[@]}"; do
    log_info "  ollama pull ${m} ..."
    # Stream pull progress straight through (no capture) so the user sees it.
    "$LAB_PODMAN" exec kali-llm/ollama -- ollama pull "$m" \
        || die "pull failed for '${m}' (typo in the tag, or no network from the container?)"
    log_info "  ${m}: done"
done

log_info "models now available in the lab:"
"$LAB_PODMAN" exec kali-llm/ollama -- ollama list >&2 || true

log_info ""
log_info "next: forward the UI from your laptop and open it —"
log_info "  ssh -L 8088:localhost:8088 -L 11434:localhost:11435 <lab-host>"
log_info "  then browse to http://localhost:8088  (Open WebUI; first account = admin)"
