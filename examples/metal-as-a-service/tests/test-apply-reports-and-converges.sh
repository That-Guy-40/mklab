#!/usr/bin/env bash
# Verdict: `apply` says what each transition it issues actually did, and the live driver
# tests the reconciliation invariant with a sequence that can fail.
#
# THREE DEFECTS, all from one live run that looked like a 30-minute hang.
#
# 1. APPLY SWALLOWED EVERY TRANSITION'S OUTPUT. Each branch was
#    `( cmd_x … ) >/dev/null 2>&1` followed by a paraphrase — "deploy 'node1' failed —
#    see its state". So a deploy that blocked for half an hour produced ZERO bytes (the
#    operator could not tell it from a hang), and when it did fail the reason was in the
#    output that had just been discarded. The per-node table is worth keeping, so success
#    stays quiet; what changes is that a transition ANNOUNCES itself before running, and
#    a failure reprints the tool's own words instead of a vaguer sentence about them.
#
# 2. THE RECONCILIATION INVARIANT TESTED NOTHING. run-e2e.sh ran `apply --dry-run` and
#    then `apply`, labelling the second "must issue ZERO transitions". A dry run converges
#    nothing, so the real run afterwards issues exactly what the dry run predicted. The
#    label described a property the sequence had not set up: the check passed for any
#    `apply` whatsoever, including one that never converges. Convergence is a fixed point
#    and needs REAL then REAL.
#
# 3. fleet.toml DECLARED AN END-STATE THE RUN CANNOT REACH. node1 was declared
#    `install/almalinux9-ks` while phase 8 deploys `ramdisk/micro-linux-x86_64`, so pass 1
#    always spent itself undoing the deploy that had just succeeded — onto a ~30-minute
#    Anaconda install the script's own header says it avoids. A spec that fights the run
#    can never converge, so the invariant above would never have been reachable either.
#
# SAFETY: mock driver + mock BMC in a sandbox; the run-e2e.sh assertions are pure text.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl
trap 'cleanup_sandboxes' EXIT
maas_env
maas_env_drivers
export MOCK_DEPLOY_LOG="$SANDBOX/deploys.log"; : > "$MOCK_DEPLOY_LOG"
make_image v1

SPEC="$SANDBOX/fleet.toml"
cat > "$SPEC" <<'EOS'
[defaults]
memory_mb = 1024
bmc_user  = "admin"
bmc_pass  = "password"

[[node]]
name     = "n1"
bmc_port = 6230
driver   = "mock"
image    = "v1"
EOS

# ── 1. a FAILING transition reprints what the tool said ────────────────────
# MOCK_HEALTH_V1=fail makes the deploy fail inside the driver, which explains itself.
# apply must carry that explanation out, not replace it.
out="$(MOCK_HEALTH_V1=fail "$MAAS" apply "$SPEC" 2>&1)"
grep -qi 'health' <<<"$out" \
    || fail "REGRESSION: apply reported a failed deploy without a word from the driver about WHY. It used to discard the output and paraphrase ('deploy failed — see its state'), which is how a live run lost the only explanation it had. Got: $(tr '\n' '|' <<<"$out" | head -c 400)"
note "a failed transition carries the tool's own explanation out of apply  ✓"

# ── 2. …and a transition announces itself BEFORE it runs ───────────────────
# The half-hour of silence is the thing being fixed. A long transition has to be visibly
# in progress, or it is indistinguishable from a hung script.
grep -qE '^ *-> deploy n1' <<<"$out" \
    || fail "REGRESSION: apply issued a transition with no line announcing it. A deploy that blocks for 30 minutes then produces zero bytes reads as a hang — which is exactly what happened, and why this test exists. Got: $(tr '\n' '|' <<<"$out" | head -c 400)"
note "each transition announces itself before it runs  ✓"

# ── 3. the positive control: a SUCCEEDING apply stays quiet ────────────────
# Without this, §1 would also pass on an apply that dumps every driver's output always —
# which would bury the per-node table that is the point of the command.
#
# On a FRESH node: §1 left n1 in `error`, where apply correctly holds it and issues
# nothing. Reusing it here would make §4 below read "pass 1 issued 0" and call that
# convergence, when what it actually measured was a node nobody touched.
# The mock driver exits SILENTLY when it succeeds, so it cannot demonstrate this either
# way — an assertion against it would pass no matter what apply does. Use a driver that
# does speak on success, so "stays quiet" is a claim about apply rather than about the
# driver's taciturnity.
CHATTY="$SANDBOX/drivers"; mkdir -p "$CHATTY"
cat > "$CHATTY/chatty.sh" <<'EOS'
#!/usr/bin/env bash
# fixture driver: succeeds at everything, and says so on every verb
echo "chatty-driver: $* — all good" >&2
exit 0
EOS
chmod +x "$CHATTY/chatty.sh"
SPEC2="$SANDBOX/fleet2.toml"
sed 's/"n1"/"n2"/; s/6230/6231/; s/"mock"/"chatty"/' "$SPEC" > "$SPEC2"
: > "$MOCK_DEPLOY_LOG"
ok="$(MAAS_DRIVER_DIR="$CHATTY" "$MAAS" apply "$SPEC2" 2>&1)" || fail "apply failed on a healthy image"
grep -q 'chatty-driver:' <<<"$ok" \
    && fail "apply printed the driver's chatter for transitions that SUCCEEDED. The table is the deliverable; noise on the happy path is how people stop reading it — and an apply that always dumps everything would pass the failure assertions above for the wrong reason"
note "control: a successful transition stays quiet — the table survives  ✓"

# ── 4. the invariant, for real: a second REAL pass issues zero transitions ─
# This is the property run-e2e.sh claimed and did not test. Assert it against the actual
# implementation, so "converged" means converged.
n2="$(sed -nE 's/^ *applied: ([0-9]+) transition.*/\1/p' <<<"$ok" | tail -1)"
[[ -n "$n2" ]] || fail "could not parse a transition count out of apply's summary — run-e2e.sh parses the same line, so an unparseable summary silently disables the invariant check"
again="$(MAAS_DRIVER_DIR="$CHATTY" "$MAAS" apply "$SPEC2" 2>&1)" || fail "the second apply failed"
n3="$(sed -nE 's/^ *applied: ([0-9]+) transition.*/\1/p' <<<"$again" | tail -1)"
[[ "${n2:-0}" -gt 0 ]] \
    || fail "pass 1 issued no transitions at all, so 'pass 2 issued zero' proves nothing — the fixed point has to be reached before it can be asserted. (This is the same shape as the defect: a check that passes because nothing happened.)"
[[ "$n3" == 0 ]] \
    || fail "REGRESSION: a second REAL apply over a converged fleet issued $n3 transition(s). Reconciliation is a fixed point; an apply that keeps acting on a converged fleet re-deploys live nodes forever"
note "pass 1 issued $n2, pass 2 issued 0 — apply is a fixed point  ✓"

# ── 5. the live driver runs REAL-then-REAL, not dry-then-real ─────────────
E2E="$LAB_DIR/run-e2e.sh"
p9="$(sed -n '/\[9\/10\]/,/\[10\/10\]/p' "$E2E")"
[[ -n "$p9" ]] || fail "could not find phase 9 in run-e2e.sh"
n_real="$(grep -E '"\$MAAS" apply "\$HERE/fleet\.toml"' <<<"$p9" | grep -vc -- '--dry-run')"
[[ "$n_real" -ge 2 ]] \
    || fail "REGRESSION: phase 9 no longer runs apply for REAL twice. With a dry run as the first of the pair the invariant is untestable — a dry run converges nothing, so the real run after it simply issues what was predicted, and the check passes for any apply at all"
grep -q 'transition' <<<"$p9" \
    || fail "REGRESSION: phase 9 no longer checks the transition COUNT of the second pass. Printing two tables and calling the second one a no-op is the same claim-without-a-check this test exists to remove"
note "phase 9 converges with a real pass, then asserts a second real pass issues zero  ✓"

# ── 6. fleet.toml declares what the run actually deploys ──────────────────
# A spec that fights the run can never converge, so §4's invariant would be unreachable
# on the live fleet however correct the code is.
FLEET="$LAB_DIR/fleet.toml"
IMAGE="$(sed -nE 's/^IMAGE="\$\{E2E_IMAGE:-([^}]+)\}".*/\1/p' "$E2E" | head -1)"
NODE="$(sed -nE 's/^NODE="\$\{E2E_NODE:-([^}]+)\}".*/\1/p' "$E2E" | head -1)"
[[ -n "$IMAGE" && -n "$NODE" ]] || fail "could not read IMAGE/NODE out of run-e2e.sh"
decl="$(python3 - "$FLEET" "$NODE" <<'PY'
import sys, tomllib
spec = tomllib.load(open(sys.argv[1], 'rb'))
for n in spec.get('node', []):
    if n.get('name') == sys.argv[2]:
        print(f"{n.get('driver','-')}/{n.get('image','-')}")
        break
PY
)"
[[ "$decl" == "ramdisk/$IMAGE" ]] \
    || fail "REGRESSION: fleet.toml declares '$NODE' as '$decl' but run-e2e.sh deploys 'ramdisk/$IMAGE'. apply will spend pass 1 undoing the deploy phase 8 just made, so the fleet never converges and the invariant above can never hold. (It was 'install/almalinux9-ks': a ~30-minute Anaconda install the script's own header says it deliberately avoids.)"
note "fleet.toml declares for '$NODE' exactly what run-e2e.sh deploys ($decl)  ✓"

# ── 7. EVERY declared image is one its driver can actually describe ────────
# The subject node is not a special case. node2/node3 declared `busybox-netboot` and
# `anycast-dns-ram` — artifacts built by OTHER labs and absent on a fresh host. apply
# refused them by name (correctly), both nodes went to `error`, and pass 2 could never
# reach zero. A spec the fleet cannot satisfy makes the invariant unreachable however
# right the code is: the same trap node1's `install/almalinux9-ks` set, quieter, because
# these converge onto nothing at all rather than onto something slow.
#
# This asks the DRIVER, not the filesystem. "The catalog does not own this image" is a
# spec nobody can ever satisfy; "the artifact is not built yet" is a host that has not
# run a build command, and failing a test for that would be failing it for the wrong
# thing.
while read -r nname nimg; do
    [[ -n "$nname" ]] || continue
    "$LAB_DIR/drivers/ramdisk.sh" describe "$nimg" >/dev/null 2>&1 \
        || fail "REGRESSION: fleet.toml declares '$nname' as ramdisk/'$nimg', an image the ramdisk driver cannot describe. A node cannot converge onto an image its driver does not own — it lands in 'error' and the reconciliation invariant becomes unreachable"
    [[ "$nimg" == "$IMAGE" ]] \
        || note "NOTE: '$nname' declares '$nimg' rather than the run's '$IMAGE' — fine PROVIDED its artifacts are built on this host; 'drivers/ramdisk.sh describe $nimg' prints the command that builds them"
done < <(python3 -c '
import sys, tomllib
spec = tomllib.load(open(sys.argv[1], "rb"))
for n in spec.get("node", []):
    if n.get("driver") == "ramdisk":
        print(n.get("name", "?"), n.get("image", ""))
' "$FLEET")
note "every ramdisk node in fleet.toml declares an image its driver owns  ✓"

pass "apply announces each transition and reprints the tool's own words when one fails while staying quiet on success; the reconciliation invariant is tested real-then-real against a parsed transition count; and fleet.toml declares the end-state the run actually reaches"
