#!/usr/bin/env bash
# Demo the control-pane runner (tools/control-pane) end-to-end: register a small fleet,
# enumerate it with live progress, watch a node reach its terminal milestone, and show how
# Phase 6 surfaces the same fleet. Self-contained + non-polluting (a temp state dir).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CP="$HERE/../../tools/control-pane"
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

SD="$(mktemp -d)"; trap 'rm -rf "$SD"' EXIT
mkdir -p "$SD/control-pane/edge1" "$SD/control-pane/edge2"
# edge1 = a completed install; edge2 = still mid-flight (a partial console)
printf 'Starting partitioner\nInstalling the base system\nRunning post-install\nlogin:\n' > "$SD/edge1.console"
printf 'Starting partitioner\nInstalling the base system\n'                                 > "$SD/edge2.console"
printf 'profile = "install"\nconsole = "%s"\n' "$SD/edge1.console" > "$SD/control-pane/edge1/node.toml"
printf 'profile = "install"\nconsole = "%s"\n' "$SD/edge2.console" > "$SD/control-pane/edge2/node.toml"

echo "### the fleet, with live progress ###"
LAB_STATE_DIR="$SD" "$CP" list

echo; echo "### watch edge1 reach its terminal milestone (bars on stderr, verdict on stdout) ###"
"$CP" watch --profile install "$SD/edge1.console"

echo; echo "### inspect edge2 (still mid-install) ###"
LAB_STATE_DIR="$SD" "$CP" inspect edge2

cat <<'EOF'

### Surface it in Phase 6 ###
Register nodes under your REAL state dir, then open the TUI — a `control-pane` group
appears with a live progress bar per node (also in phase6b-web):

  mkdir -p "$LAB_STATE_DIR/control-pane/edge1"
  printf 'profile = "install"\nconsole = "/path/to/edge1.console"\n' \
      > "$LAB_STATE_DIR/control-pane/edge1/node.toml"
  ( cd phase6-tui && uv run lab-tui )
EOF
