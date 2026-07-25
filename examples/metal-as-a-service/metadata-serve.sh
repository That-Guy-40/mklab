#!/usr/bin/env bash
# metadata-serve.sh — run the MAAS metadata + introspection sink (lib/metadata.py)
# against the live registry. Serves NoCloud user-data per node and receives the
# inspection probe's facts POST. Foreground; Ctrl-C to stop (kill by this PID, F8).
#
#   metadata-serve.sh [--port P] [--host H] [--ssh-key FILE-OR-STRING]
#
# Port defaults to 8282 — a SEPARATE listener from the netboot HTTP server. On this
# host :8181 is the netboot nginx (read-only static kernel/initrd delivery) and :8080
# is SABnzbd (see CLAUDE.md), so the POST-capable metadata sink must NOT reuse either.
# Kernel/initrd still come off :8181; facts POST to :8282.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAAS="$HERE/maas-lab.sh"

port=8282 host=127.0.0.1 ssh_key=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) port="$2"; shift 2 ;;
        --host) host="$2"; shift 2 ;;
        --ssh-key)
            if [[ -f "$2" ]]; then ssh_key="$(cat "$2")"; else ssh_key="$2"; fi
            shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'metadata-serve: unknown option %s\n' "$1" >&2; exit 1 ;;
    esac
done

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

# Resolve the registry dir the way maas-lab.sh does (honor MAAS_STATE/LAB_STATE_DIR).
STATE="$("$MAAS" _state-root)" || { echo "could not resolve MAAS state dir" >&2; exit 1; }
echo "serving metadata for registry: $STATE" >&2
exec python3 "$HERE/lib/metadata.py" serve --state "$STATE" --port "$port" --host "$host" \
    ${ssh_key:+--ssh-key "$ssh_key"}
