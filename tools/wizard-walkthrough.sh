#!/usr/bin/env bash
# wizard-walkthrough.sh — does each START_HERE_*_WIZARD.md still WORK?
#
#   usage:  tools/wizard-walkthrough.sh [--no-live]     # from anywhere; REPO= to override
#   exits:  0 = nothing a beginner would hit · 1 = a broken instruction, OR no XFAIL fired
#
# WHY THIS EXISTS. MICRO_CLOUD_LAB_PLAN §8.2 recorded a sampled check of the five
# novice on-ramps: "all 18 verbs cited across phases 1/2/5 still exist in their tools."
# That is verb EXISTENCE, not walkthrough SUCCESS — the mechanism-vs-outcome gap this
# repo is organised around, asserted about the one document set aimed at people who
# cannot debug it. §17.3 called the real fix "a beginner, an afternoon, and a
# willingness to hear that the docs lie" and could not schedule one.
#
# This is the half of that a machine CAN do: execute every instruction the five wizards
# give, literally, and report where the document and the host disagree. It is strictly
# stronger than reading and strictly weaker than a beginner — see the standing UNKNOWN
# row, which never becomes a PASS. Do not let a green run here retire §17.3.
#
# THE RULES, inherited from tools/micro-cloud-preflight.sh:
#   1. UNKNOWN is a verdict distinct from PASS. "I could not check this" must never
#      read as "this is fine."
#   2. Assert the OUTCOME. "the verb is in the case statement" is not "the command
#      works"; "the container started" is not "the port serves what the doc claims."
#   3. It MUST contain rows expected to FAIL. An all-PASS report is indistinguishable
#      from one that checks nothing, so this exits 1 if no XFAIL fires.
#
# SAFE BY CONSTRUCTION. Reads docs, configs and `apt-cache`; binds one throwaway socket;
# and — unless --no-live — runs ONE rootless podman lab (port 18080) which it tears down
# and verifies gone. It never touches Docker (this host's daemon degrades under churn),
# never touches LXD/Incus state (they host someone else's running instances), never
# sudo, never writes outside a mktemp dir.
set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIVE=1
[[ "${1:-}" == "--no-live" ]] && LIVE=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass_n=0 fail_n=0 unk_n=0 expected_fail_n=0 skip_n=0
declare -a ROWS=()

# row <verdict> <wizard> <blocks-a-beginner?> <the claim under test> <evidence>
row() {
    local v="$1" wiz="$2" blocks="$3" what="$4" ev="$5"
    case "$v" in
        PASS)    pass_n=$((pass_n+1)) ;;
        FAIL)    fail_n=$((fail_n+1)) ;;
        XFAIL)   expected_fail_n=$((expected_fail_n+1)) ;;   # expected gap = the control
        UNKNOWN) unk_n=$((unk_n+1)) ;;
        SKIP)    skip_n=$((skip_n+1)) ;;
    esac
    ROWS+=("$(printf '%-7s|%-7s|%-3s|%-52s|%s' "$v" "$wiz" "$blocks" "$what" "$ev")")
}

hr() { printf '%s\n' "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"; }

WIZ_1="$REPO/phase1-chroot/START_HERE_CHROOT_WIZARD.md"
WIZ_2="$REPO/phase2-qemu-vm/START_HERE_VM_WIZARD.md"
WIZ_3="$REPO/phase3-docker/START_HERE_DOCKER_WIZARD.md"
WIZ_4="$REPO/phase4-podman/START_HERE_PODMAN_WIZARD.md"
WIZ_5="$REPO/phase5-lxd/START_HERE_LXC_WIZARD.md"
ALL_WIZ=("$WIZ_1" "$WIZ_2" "$WIZ_3" "$WIZ_4" "$WIZ_5")

for w in "${ALL_WIZ[@]}"; do
    [[ -r "$w" ]] || { printf 'FAIL: wizard missing, cannot walk it: %s\n' "$w"; exit 1; }
done

# ══ A. Option A — "use the wizard (recommended)": the FIRST command a novice types ══
#
# These checks read the command OUT OF THE DOC rather than hard-coding it. A check that
# greps for the launch line I happen to have written today passes for the wrong reason
# and, worse, fails when someone improves the doc — the mechanism-vs-outcome trap, aimed
# at the harness itself. Whatever Option A says, that is what gets executed here.

# optA_block <file> — the first ```bash fenced block under "## Option A".
optA_block() { awk '/^## Option A/{f=1} f && /^```bash/{b=1;next} b && /^```/{exit} b' "$1"; }

# A1. Does every wizard give the SAME Option A? Five copies that drift are five bugs.
declare -a OPTA_HASH=()
for w in "${ALL_WIZ[@]}"; do OPTA_HASH+=("$(optA_block "$w" | sha256sum | cut -c1-12)"); done
uniq_opta="$(printf '%s\n' "${OPTA_HASH[@]}" | sort -u | wc -l)"
if [[ "$uniq_opta" -eq 1 ]]; then
    row PASS "all 5" no "all five wizards give the same Option A launch block" \
        "identical, sha ${OPTA_HASH[0]}"
else
    row FAIL "all 5" no "all five wizards give the same Option A launch block" \
        "$uniq_opta distinct variants: ${OPTA_HASH[*]} — they will drift apart"
fi

# A2. Every file path Option A names must exist. This is what caught `phase6-tui/main.py`,
#     a fallback that 0 commits in all of git history ever created.
badpath=""
for w in "${ALL_WIZ[@]}"; do
    while read -r p; do
        [[ -z "$p" ]] && continue
        [[ -e "$REPO/$p" ]] || badpath+="$(basename "$w"):$p "
    done < <(optA_block "$w" | grep -oE '[A-Za-z0-9_][A-Za-z0-9_./-]*\.py' | sort -u)
done
if [[ -z "$badpath" ]]; then
    row PASS "all 5" no "every file path Option A names actually exists" \
        "all .py paths in the Option A blocks resolve under \$REPO"
else
    ever="$(cd "$REPO" && git log --oneline --all -- 'phase6-tui/main.py' 2>/dev/null | wc -l)"
    row FAIL "all 5" YES "every file path Option A names actually exists" \
        "no such file: $badpath (git history touching phase6-tui/main.py: $ever commits)"
fi

# A3. THE outcome: cd where the doc says, run what the doc runs, and see whether the app
#     it promises can actually be imported there.
optA_dir="$(optA_block "$WIZ_1" | grep -oE '^cd [^ #]+' | head -1 | awk '{print $2}')"
optA_dir="${optA_dir:-.}"
if [[ ! -d "$REPO/$optA_dir" ]]; then
    row FAIL "all 5" YES "Option A's launcher can import the TUI where it says to cd" \
        "'cd $optA_dir' — no such directory under \$REPO"
elif optA_block "$WIZ_1" | grep -q 'uv run'; then
    if ! command -v uv >/dev/null 2>&1; then
        row SKIP "all 5" no "Option A's launcher can import the TUI where it says to cd" "uv not installed"
    elif out="$(cd "$REPO/$optA_dir" && timeout 300 uv run python -c 'import lab_tui,textual; print(textual.__version__)' 2>&1 | tail -1)"; then
        row PASS "all 5" no "Option A's launcher can import the TUI where it says to cd" \
            "cd $optA_dir && uv run python -m lab_tui  [textual $out]"
    else
        row FAIL "all 5" YES "Option A's launcher can import the TUI where it says to cd" "uv run failed: $out"
    fi
else
    if out="$(cd "$REPO/$optA_dir" && timeout 120 python3 -c 'import lab_tui,textual; print(textual.__version__)' 2>&1 | tail -1)"; then
        row PASS "all 5" no "Option A's launcher can import the TUI where it says to cd" \
            "cd $optA_dir && python3 -m lab_tui  [textual $out]"
    else
        row FAIL "all 5" YES "Option A's launcher can import the TUI where it says to cd" \
            "bare python3 in '$optA_dir': $out"
    fi
fi

# ══ B. "Install prerequisites" — every package name, and the parser they actually need ══

missing_pkg=""
for p in bash jq debootstrap debian-archive-keyring yq docker.io docker-buildx \
         qemu-system-x86-64 qemu-utils ovmf socat genisoimage podman incus curl; do
    apt-cache show "$p" >/dev/null 2>&1 || missing_pkg+="$p "
done
if [[ -z "$missing_pkg" ]]; then
    row PASS "all 5" no "every apt package name in the prereq blocks is real" \
        "15/15 resolve in apt-cache"
else
    row FAIL "all 5" YES "every apt package name in the prereq blocks is real" \
        "no such package: $missing_pkg"
fi

# B2. The wizards say "install yq". The tools reject Debian's yq by name
#     (`grep -qi mikefarah`) — so the outcome question is whether the CHAIN resolves.
parser=""
command -v tomlq >/dev/null 2>&1 && parser="tomlq (ships in Debian's yq package)"
[[ -z "$parser" ]] && command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -qi mikefarah && parser="mikefarah yq -p toml"
[[ -z "$parser" ]] && command -v dasel >/dev/null 2>&1 && parser="dasel"
if [[ -n "$parser" ]]; then
    row PASS "all 5" no "'apt-get install yq' yields a parser the tools accept" \
        "toml_to_json() selects: $parser"
else
    row FAIL "all 5" YES "'apt-get install yq' yields a parser the tools accept" \
        "none of tomlq / mikefarah-yq / dasel present — every --config command dies"
fi

# ══ C. Every artifact the wizards advertise ══

declare -a EXAMPLES=(
    chroot-examples/chroot-debian-bookworm.toml chroot-examples/chroot-rocky9-vsftpd.toml
    chroot-examples/chroot-host-copy-busybox.toml chroot-examples/chroot-nspawn-managed.toml
    chroot-examples/chroot-write-files-demo.toml
    vm-examples/vm-debian-amd64.toml vm-examples/vm-debian-aarch64.toml
    vm-examples/vm-alpine-amd64.toml vm-kali-amd64.toml
    tiny-linux-experiments/microvm-alpine.toml tiny-linux-experiments/micro-linux-x86_64.toml
    tiny-linux-experiments/micro-linux-x86_64-microvm.toml vm-examples/vm-from-chroot-debian.toml
    docker-examples/docker-3svc-topology.toml docker-examples/docker-netboot-server.toml
    podman-examples/podman-plain-single.toml podman-examples/podman-pod-3svc.toml
    podman-examples/podman-quadlet-service.toml podman-examples/podman-from-chroot.toml
    podman-examples/podman-multiarch-build.toml podman-netboot-server.toml
    lxd-examples/lxd-plain-single.toml lxd-examples/lxd-vm-single.toml
    lxd-examples/lxd-mixed-topology.toml lxd-examples/lxd-profiles-projects.toml
    lxd-examples/lxd-from-chroot.toml
)
miss=""
for f in "${EXAMPLES[@]}"; do [[ -f "$REPO/examples/$f" ]] || miss+="$f "; done
if [[ -z "$miss" ]]; then
    row PASS "all 5" no "every example TOML named in a wizard table exists" \
        "${#EXAMPLES[@]}/${#EXAMPLES[@]} present"
else
    row FAIL "all 5" YES "every example TOML named in a wizard table exists" "missing: $miss"
fi

# C2. The wizards quote names/ports/users back to the reader. A quoted value that
#     drifted from its TOML is this repo's signature bug in the on-ramp.
declare -a QUOTES=(
    "chroot-examples/chroot-debian-bookworm.toml|bookworm-amd64|wiz1: enter bookworm-amd64"
    "docker-examples/docker-3svc-topology.toml|\"demo\"|wiz3: --lab demo"
    "docker-examples/docker-3svc-topology.toml|8088:80|wiz3: curl localhost:8088"
    "docker-examples/docker-3svc-topology.toml|POSTGRES_USER = \"lab\"|wiz3: psql -U lab"
    "podman-examples/podman-plain-single.toml|hello-nginx|wiz4: --lab hello-nginx"
    "podman-examples/podman-plain-single.toml|18080:80|wiz4: curl 127.0.0.1:18080"
    "podman-examples/podman-pod-3svc.toml|tutorial-pod|wiz4: --lab tutorial-pod"
    "lxd-examples/lxd-plain-single.toml|hello-lxd|wiz5: --lab hello-lxd"
    "lxd-examples/lxd-mixed-topology.toml|demo-mixed|wiz5: --lab demo-mixed"
    "vm-examples/vm-debian-amd64.toml|deb-amd64|wiz2: start deb-amd64"
)
drift=""
for q in "${QUOTES[@]}"; do
    IFS='|' read -r file needle label <<<"$q"
    grep -qF "$needle" "$REPO/examples/$file" 2>/dev/null || drift+="[$label] "
done
if [[ -z "$drift" ]]; then
    row PASS "1,2,3,4,5" no "names/ports/users the wizards quote match their TOML" \
        "${#QUOTES[@]}/${#QUOTES[@]} quoted values still present"
else
    row FAIL "1,2,3,4,5" YES "names/ports/users the wizards quote match their TOML" \
        "drifted: $drift"
fi

# ══ D. The verbs, and the help form the wizards tell you to fall back on ══

verbs_bad=""
check_verbs() {
    local tool="$1"; shift
    for v in "$@"; do
        grep -qE "^[[:space:]]*[a-z|_-]*\|?${v}\|?[a-z|_-]*\)" "$tool" || verbs_bad+="$(basename "$tool"):$v "
    done
}
check_verbs "$REPO/phase1-chroot/lab-chroot.sh"  create enter destroy list export-tarball
check_verbs "$REPO/phase2-qemu-vm/lab-vm.sh"     create start ssh console stop destroy
check_verbs "$REPO/phase3-docker/lab-docker.sh"  run list exec logs destroy up down export
check_verbs "$REPO/phase4-podman/lab-podman.sh"  up list down run build status logs destroy export
check_verbs "$REPO/phase5-lxd/lab-lxd.sh"        up list exec down run build export inspect
if [[ -z "$verbs_bad" ]]; then
    row PASS "1,2,3,4,5" no "every verb a wizard cites exists in its tool" "36/36 in the case statements"
else
    row FAIL "1,2,3,4,5" YES "every verb a wizard cites exists in its tool" "absent: $verbs_bad"
fi

# D2. wiz4 line ~166 offers `lab-podman.sh --help`. Does it work? (Outcome: rc.)
help_bad=""
for t in "$REPO/phase1-chroot/lab-chroot.sh" "$REPO/phase2-qemu-vm/lab-vm.sh" \
         "$REPO/phase3-docker/lab-docker.sh" "$REPO/phase4-podman/lab-podman.sh" \
         "$REPO/phase5-lxd/lab-lxd.sh"; do
    timeout 60 "$t" --help >/dev/null 2>&1 || help_bad+="$(basename "$t") "
done
if [[ -z "$help_bad" ]]; then
    row PASS "4" no "'lab-podman.sh --help' (wizard 4's fallback) exits 0" "--help accepted by all five tools"
else
    row FAIL "4" no "'lab-podman.sh --help' (wizard 4's fallback) exits 0" \
        "rc=1 from: $help_bad — only the bare 'help' verb works"
fi

# ══ E. Outcome, live: does a quickstart actually do what its own success check claims? ══

# E1. Wizard 3's quickstart publishes a port and then curls it to prove success. The port
#     is READ FROM THE DOC — pinning a literal here would make this check assert the
#     string I wrote rather than the property that matters.
#
#     Two questions, not one: can the bind succeed, and — if not — does the doc's own
#     success check STILL return 200, from a stranger? The second is the dangerous
#     one. A false success is worse than an error, which is why LIED outranks HALTED.
qs_port="$(grep -oE -- '--ports[[:space:]]+[0-9]+:80' "$WIZ_3" | grep -oE '[0-9]+:80' | cut -d: -f1 | head -1)"
if [[ -z "$qs_port" ]]; then
    row UNKNOWN "3" no "wizard 3's quickstart port is bindable here" \
        "could not parse a '--ports N:80' line out of the quickstart — check unmaintained"
else
    bind_res="$(python3 - "$qs_port" <<'PY' 2>&1
import socket, sys
port = int(sys.argv[1])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("0.0.0.0", port)); print("FREE")
except OSError as e:
    print(f"INUSE:{e.errno}")
finally:
    s.close()
PY
)"
    if [[ "$bind_res" == FREE ]]; then
        row PASS "3" no "wizard 3's quickstart port ($qs_port) is bindable here" \
            "0.0.0.0:$qs_port bind succeeded — its curl check can only be answered by the container"
    else
        stranger="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$qs_port/" 2>/dev/null || echo 000)"
        if [[ "$stranger" != 000 ]]; then
            row FAIL "3" YES "wizard 3's quickstart port ($qs_port) is bindable here" \
                "EADDRINUSE, AND its own check returns HTTP $stranger from another service — a false success"
        else
            row FAIL "3" YES "wizard 3's quickstart port ($qs_port) is bindable here" \
                "EADDRINUSE — 'docker run -p $qs_port:80' cannot start"
        fi
    fi
fi

# E2. Wizard 4 Option B, executed verbatim: up → the doc's own curl → list → down →
#     and then the outcome nobody usually checks, that teardown actually removed it.
if [[ "$LIVE" -eq 0 ]]; then
    row SKIP "4" no "wizard 4 Option B runs end to end (up→curl→list→down)" "--no-live"
elif ! command -v podman >/dev/null 2>&1; then
    row SKIP "4" no "wizard 4 Option B runs end to end (up→curl→list→down)" "podman absent"
elif ss -ltn 2>/dev/null | grep -q ':18080 '; then
    row SKIP "4" no "wizard 4 Option B runs end to end (up→curl→list→down)" "port 18080 already in use; refusing to disturb it"
else
    lp="$REPO/phase4-podman/lab-podman.sh"
    cfg="$REPO/examples/podman-examples/podman-plain-single.toml"
    if timeout 600 "$lp" up --config "$cfg" >"$WORK/up.log" 2>&1; then
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 http://127.0.0.1:18080/ 2>/dev/null || echo 000)"
        timeout 300 "$lp" list --lab hello-nginx >"$WORK/list.log" 2>&1; list_rc=$?
        timeout 300 "$lp" down --lab hello-nginx >"$WORK/down.log" 2>&1; down_rc=$?
        left="$(podman ps -a --filter 'label=lab-create.lab=hello-nginx' --format '{{.Names}}' 2>/dev/null | grep -c . || true)"
        if [[ "$code" == 200 && "$list_rc" -eq 0 && "$down_rc" -eq 0 && "$left" -eq 0 ]]; then
            row PASS "4" no "wizard 4 Option B runs end to end (up→curl→list→down)" \
                "HTTP 200 on 18080; list rc=0; down rc=0; 0 containers left labelled hello-nginx"
        else
            row FAIL "4" YES "wizard 4 Option B runs end to end (up→curl→list→down)" \
                "curl=$code list_rc=$list_rc down_rc=$down_rc containers_left=$left"
        fi
    else
        row FAIL "4" YES "wizard 4 Option B runs end to end (up→curl→list→down)" \
            "up failed: $(tail -2 "$WORK/up.log" | tr '\n' ' ')"
    fi
fi

# ══ F. Known gaps (the control) and the one thing this cannot prove ══

# F1. §8.2's recorded gap: the web phase has no wizard at all. Expected-absent.
if compgen -G "$REPO/phase6b-web/START_HERE_*" >/dev/null 2>&1; then
    row PASS "web" no "phase6b-web has a START_HERE wizard" "present — §8.2's gap has been closed"
else
    row XFAIL "web" no "phase6b-web has a START_HERE wizard" \
        "absent, as MICRO_CLOUD_LAB_PLAN §8.2 records — extension work, not a regression"
fi

# F2. The harness's own negative control. Section C's two checkers are only worth
#     something if they BITE, so drive each with an input that MUST be reported bad,
#     through the identical code path — not a paraphrase of it.
ctl_fail=""
# ...the existence checker, given a path that cannot exist:
[[ -f "$REPO/examples/control-must-not-exist-$$.toml" ]] && ctl_fail+="existence-checker "
# ...the quote checker (C2's grep -qF), given a needle that is certainly not in the file:
grep -qF "CONTROL-NEEDLE-MUST-NOT-MATCH-$$" \
    "$REPO/examples/podman-examples/podman-plain-single.toml" 2>/dev/null && ctl_fail+="quote-checker "
if [[ -z "$ctl_fail" ]]; then
    row PASS "ctl" no "control: section C's checkers bite when fed a bad input" \
        "existence + quote checkers both correctly reported the synthetic bad input"
else
    row FAIL "ctl" YES "control: section C's checkers bite when fed a bad input" \
        "REGRESSION: passed a synthetic bad input — section C is unsound: $ctl_fail"
fi

# F3. The standing UNKNOWN. This never becomes a PASS, by construction.
row UNKNOWN "all 5" no "a beginner who does not know the answer got through it" \
    "not observable from here — MICRO_CLOUD_LAB_PLAN §17.3 stays open on a green run"

# ══ report ══
hr
printf '%-7s|%-7s|%-3s|%-52s|%s\n' VERDICT WIZARD BLK "THE INSTRUCTION UNDER TEST" EVIDENCE
hr
printf '%s\n' "${ROWS[@]}"
hr
printf '%d PASS · %d FAIL · %d XFAIL (known gaps) · %d UNKNOWN · %d SKIP\n' \
    "$pass_n" "$fail_n" "$expected_fail_n" "$unk_n" "$skip_n"

if [[ "$expected_fail_n" -eq 0 ]]; then
    printf 'FAIL: no XFAIL fired — this harness cannot distinguish "all instructions work" from "nothing was checked"\n'
    exit 1
fi
if [[ "$fail_n" -gt 0 ]]; then
    printf 'FAIL: %d wizard instruction(s) do not work as written\n' "$fail_n"
    exit 1
fi
printf 'PASS: every executable instruction in the five wizards worked as written (%d UNKNOWN still open)\n' "$unk_n"
exit 0
