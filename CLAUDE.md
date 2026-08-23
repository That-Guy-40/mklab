# CLAUDE.md — mklab

A multi-phase lab-building toolkit: one `phaseN-*/` directory per compute
type, each a self-contained driver plus its own `tests/`. Ready-to-run
`.toml` lab specs live in `examples/`, catalogued in
[`examples/00-INDEX.md`](examples/00-INDEX.md). Cohesive multi-file labs get
their own subdir under `examples/` (e.g. `tiny-linux-experiments/`,
`almalinux-pxe-lab/`, `pxe-boot-mechanics/`).

## Working practices

### Every test emits exactly one human-readable verdict line

A test's **minimal output is a single terminal verdict**: `PASS: <what was
proven>` (exit 0), `FAIL: <what broke>` (exit 1), or `SKIP: <why>` (exit 77) —
use the `pass`/`fail`/`skip`/`note` helpers in each phase's `tests/lib.sh`. **No
test may ever exit silently.** A bare non-zero exit with no message is a test
bug, not a result — the reader can't tell a real failure from a broken harness.

- **A failure must name the specific defect, not just say "failed."** Give each
  assertion its own `fail`/`REGRESSION:` message that states *what* broke and,
  ideally, the expected-vs-actual — e.g.
  `fail "REGRESSION: rm -rf recursed through the live bind and deleted the source"`,
  not `fail "assertion 3"`. One assertion → one specific message, so the printed
  line alone tells you which invariant was violated. **Prefix the message with
  `REGRESSION:`** when the assertion guards a previously-fixed bug from coming
  back (a regression test) — it flags the failure as "a fix was undone," which is
  more urgent than a first-time failure.

- Prefer intermediate progress via `note` (a `  - …` line), but the run must
  still **end on a `PASS`/`FAIL`/`SKIP`**.
- **The silent-exit trap:** functions under test report failure/refusal with
  `die` (which is `exit`, not `return`). Calling one in a plain `if f; then …`
  lets that `exit` blow past the `if` and kill the whole test *before its
  assertions run* — and if you redirected its stderr, the terminal is left blank
  with a bare `rc=1`. **Wrap a `die`-ing call in a subshell** — `if ( f ); then
  …` — so the exit is contained and the test continues to its verdict.
- **Belt-and-suspenders:** give the test an `EXIT`-trap safety net that prints
  `FAIL: test exited early (rc=N)` when `rc ∉ {0,77}`, so an unexpected `die`
  can never again produce silent output. (Real incident: two root-gated tests
  did exactly this — see [`REVIEW-phases-1-5.md`](REVIEW-phases-1-5.md).)

- **The net belongs in `lib.sh`, and a test must NEVER install its own `trap …
  EXIT`.** Bash keeps **one** EXIT trap per shell, so a test writing
  `trap 'cleanup' EXIT` silently **replaces** the net — which is invisible,
  because a safety net is only observable when something goes wrong. Measured
  2026-08-06: of metal-as-a-service's 36 tests, **23 had disarmed it this way**
  (a `die` ended them with a bare rc and no verdict at all) and 11 more had
  re-inlined it and printed `FAIL` **twice** for one failure. Two other labs had
  the same shape. So: `lib.sh` owns the trap, tests register teardown with
  `on_exit '<cmd>'` (evaluated at exit, so it may name a variable set later),
  `_on_exit` captures `$?` **before** running any of it — a teardown returns 0
  and would otherwise erase the status that triggered it — and a `_VERDICT` flag
  set by `pass`/`fail`/`skip` keeps the net quiet when a verdict was already
  given. Exemplars:
  [`examples/metal-as-a-service/tests/lib.sh`](examples/metal-as-a-service/tests/lib.sh),
  [`phase7-firecracker/tests/lib.sh`](phase7-firecracker/tests/lib.sh).

- **Cleanup that needs the exit status reads `$_EXIT_RC`.** `_on_exit` publishes
  it before running registrations. Without it, a teardown that must know whether
  the run failed — keep the evidence, skip the tidy-up — has to write its own
  `trap … EXIT`, which is exactly the defect the shape removes. (Real case:
  micro-cloud's DHCP-exhaustion test preserves its log directory on failure.)

- **Test the net, and enforce the rule.** A net nobody has watched fire is not
  known to work. [`tools/check-harness-net.sh`](tools/check-harness-net.sh) is
  the single implementation — it proves the net fires with the right rc when a
  test dies silently, stays quiet on pass/skip, prints **exactly one** `FAIL`
  when the test already spoke, runs registered cleanup in reverse, exposes
  `$_EXIT_RC` — and **fails if any test in the directory installs an EXIT trap
  of its own**, which turns the rule above from advice into a check.
  **That last check was itself a liar twice, the same way both times** — a regex
  over a *physical line* standing in for a question about a *command*:
  - **2026-08-08:** it matched `^[[:space:]]*trap`, so it never saw
    `tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT` — the trap after a semicolon,
    which is the most common way to open a test in this repo. It printed *"no test
    overrides lib.sh's EXIT trap"* across six suites while **twenty tests did**.
  - **2026-08-15** (found by [`REVIEW-phase1.md`](REVIEW-phase1.md) P1-3): the
    replacement matched `trap` and `EXIT` **on one line**, and its own comment
    advertised *"mid-line included"* — but a trap whose **body spans lines** puts
    them on different lines, so it passed over **three** tests that had taken the
    net down (`phase1-chroot/tests/test-cli-vs-config-parity.sh`, `phase4-podman/`
    and `phase5-lxd/tests/test-inspect-json.sh`).

  Each rewrite widened the pattern by one shape and was read as having answered the
  real question. **The real question is not textual**: *is `trap` run as a command
  here, with `EXIT` among its arguments?* So §1 is now a bounded **lexer** over
  quoting, comments, heredocs and backslash-continuations — a `trap` inside quotes
  is a string, one in a heredoc is data being written to a fixture, and neither is
  an installation.
  **The durable fix is §1a, not the lexer.** Sections 2–6 each prove themselves
  against a fixture; §1 never did, which is exactly why §1 is the section that was
  wrong twice — *a scan that matches nothing and a scan that is broken print the
  same green ✓*. §1 now runs the scanner over **8 shapes it must catch and 8 it
  must not** before it is aimed at any real test, in every suite, on every run.
  Both historical regressions were re-injected and watched to bite (blind to 5 and
  to 4 respectively), as was an over-firing scanner (6 false positives) — and the
  controls found a **third** blind spot neither audit named:
  `if true; then trap 'x' EXIT; fi`, since `then` is not one of the separators.

  **§7 covers being KILLED, which is not the same as failing.** Bash runs no EXIT
  trap for an untrapped fatal signal, so a run stopped from outside — a CI
  deadline, an agent harness timeout, Ctrl-C — used to end in a log that simply
  **stops**: no verdict, no reason. Measured 2026-08-19, and the cost is not
  hypothetical: a SIGTERM to a suite's process group printed bash's bare
  `Terminated`, and the truncated log was written up as an *intermittent defect in
  the test it happened to interrupt*. A day went into a bug that was never there.
  `lib.sh` now traps `TERM`/`INT`/`HUP`, names the signal, and re-exits `128+N`.
  Its control strips the traps from a copy of the lib and requires the naming to
  disappear — **and that control earned itself immediately**, disproving a claim
  the first draft had written into all thirteen `lib.sh` files (that the traps also
  rescued the teardown; they do not — a killed shell already ran its cleanup, which
  is why the claim had to be measured rather than reasoned).

  It provides
  its own verdict helpers on purpose: it must not source the lib under test, or
  the subject would be supplying its own harness. Every `tests/` directory ships
  a five-line `tests/test-harness-net.sh` that `exec`s it, so the check runs
  inside that suite's `run-all.sh` (and therefore CI) rather than only in
  `tools/`. All five defects were re-injected and watched to bite.

- **Don't write the test count in prose.** `run-all.sh` used to end on
  `N passed, 0 failed`; that integer got copied by hand into five documents and
  drifted in one. It also says nothing about coverage — a runner that quietly
  stopped after three tests prints a clean `3 passed, 0 failed`. Print a
  **ratio** instead (`ran/listed`, plus the count of test files on disk), fail
  when a listed test never ran, and fail when a test file is in no list — then
  docs can say *"every listed test ran, 0 skipped, 0 failed"*, which stays true
  as tests are added. (A test with no runner is a test nobody runs: one sat on
  disk here for weeks, guarded only by a comment.)

  **And NAME what skipped.** A count cannot say *which* guard did not run. Measured
  2026-08-15: two mount-guard tests skipped in phase 1 on a transient `unshare -rm`
  failure — never reproduced in 440 later attempts — and the suite printed a
  healthy-looking `13 passed, 13 skipped, 0 failed`. Nothing distinguished that run
  from one where both safety guards executed. An unmet precondition is an **UNKNOWN**,
  and it has to be legible as one, so the summary lists the skipped and failed files
  by name; the reason for each is already on its own `SKIP:` line above.

  **This is a check, not advice.** [`tools/tests/test-run-all-reports-a-ratio.sh`](tools/tests/test-run-all-reports-a-ratio.sh)
  drives **every** `*/tests/run-all.sh` against synthetic pass/fail/skip tests and
  asserts what it *prints* — deliberately behavioural, because a regex over a runner's
  source is the mistake the EXIT-trap checker made twice. Runners with a hand-maintained
  list are driven with fixtures named **from their own list**, so none is excluded. It
  carries its own control (the bare-count shape must fail the same assertions), and an
  early version of it passed all 13 runners *for the wrong reason* — the per-test
  `=== name ===` headers meant the skipped file appeared in the output whether or not the
  **summary** named it. Scoping the assertion to the summary section found four runners
  that only counted.

### The control is where the bugs are

Every checker in `tools/` ships with a control that plants the defect and watches the
scanner catch it — the rule the rest of this file keeps restating. What was not written
down until **2026-08-23** is where the defects actually turn up: **in the control, and in
the checker, far more often than in the corpus being checked.**

Measured over one day's work on four checkers. Each defect was caught by that checker's own
control, on the run that introduced it, and **none** would have been visible in a green run:

| the defect | how it presented |
|---|---|
| in `${v/pat/repl}`, an unescaped **`&` in the REPLACEMENT expands to the matched text** — so a replacement containing `2>&1` spliced the match back into itself | the "legacy" variant the control builds never ran; it reported *"the old shape survived a 77 too"* |
| in an ERE, **`\t` is a literal `t`** — `grep -vE '\t[[:space:]]*$'` drops every line **ending in the letter t** | the extractor silently lost its own fixtures `… lab-lxd.sh list` |
| arguments passed in the **wrong order**, so `class` held a file path | every hard finding quietly degraded to a warning — *a checker grading its own findings down to advisory* |
| a `# shellcheck disable` / an extraction aimed **one line off** the command it meant | a suppression that suppressed nothing; an extraction that swallowed the next YAML key and blamed bash |

Four rules follow, and the last two are the ones that were learned the expensive way:

- **Write the control first, then break the subject and watch it bite.** Not reason about it
  — run it. A control that has never failed is not known to be attached to anything.
- **When the control reports something surprising, suspect the control.** Every instance
  above first looked like a finding about the subject.
- **A scan that matches nothing and a scan that is broken print the same green ✓** — so make
  the checker prove itself on must-catch/must-not-catch fixtures *before* it is aimed at a
  real file (`check-harness-net.sh` §1a, `check-usage-is-data.sh` §0,
  `check-doc-verbs.sh` §0), and **prove it end to end**, not just its extractor: the
  question is *"does a bad input FAIL the run"*, and the extractor is only the first of the
  classifier, the probe and the reporting that sit between input and verdict.
- **Extract the shipped thing; never re-implement it.** `test-ci-tolerates-a-skipped-suite.sh`
  and `test-shellcheck-gate.sh` `sed` the step out of `ci.yml`; `check-doc-verbs.sh` and
  `check-guided-path-is-a-view.sh` share
  [`tools/lib/verb-probe.sh`](tools/lib/verb-probe.sh). A copy drifts from its subject and
  then proves something about the copy.

**And a checker that cannot decide must say so.** `check-doc-verbs.sh` grades a bare
`` `preserve.sh two tiers` `` as a warning, not a failure, because prose and a command are
structurally identical there; it leaves 78 commands **UNPROBED by name** rather than
invoking a `smoke-*.sh` to find out. Naming what it declined is what separates that from a
coverage list, which under-covers in silence.

### A usage heredoc is a program: help text must not be able to run

A `usage()` built as `cat <<EOF` has an **unquoted** delimiter — it has to, the text
interpolates `$LAB_PROG` — so a backtick or `$(...)` anywhere in that text is **command
substitution**. Phase 2 shipped ``Start the `listen` VM first.`` for months: bash ran
`listen`, wrote `listen: command not found` to stderr, and substituted the empty result
**into the help**, so every reader was told *"Start the  VM first."* Nothing failed;
`--help` still exited 0. It is this file's opening rule pointed the other way round —
there the live command was test data, here it was **prose**.

**"`--help` writes nothing to stderr" is the cheap check, and it is a liar.** It catches
only a command that does not *exist*. `` `date` `` or `$(pwd)` runs fine, emits no stderr,
and rewrites the help text silently — the dangerous case is the quiet one. Ask the real
question: *is there command substitution in a usage heredoc whose delimiter is unquoted?*

[`tools/check-usage-is-data.sh`](tools/check-usage-is-data.sh) asks both, and — per the
`check-harness-net.sh` lesson — proves itself against **5 must-catch and 5 must-not-catch**
shapes plus a `$(pwd)` fixture demonstrating the stderr check alone would pass it, **before**
it looks at a real file. Its §0 immediately caught the scanner's own blind spot (`usage() {
cat <<EOF` is one line, and an early `continue` skipped it). Every driver suite ships a
`tests/test-usage-is-data.sh` that execs it.

### "Fix a value everywhere" tasks: map the full blast radius BEFORE the first edit

When changing a value, path, or name that recurs across the repo (a **port**, a
**filename**, a config key, a VM name), `git grep` the **whole repo** for every
occurrence and **classify each hit** — in-scope vs. coincidental vs.
intentionally-different — *before* editing anything. Editing first and learning
the true scope afterward causes thrash and risks corrupting unrelated hits.

The loop:
1. `git grep -n '<value>'` repo-wide (or `tools/link_check.py --impact <file>` for file references).
2. Classify every hit: the thing you're changing / merely shares the string / deliberately different.
3. Edit only the in-scope set, then re-grep to confirm nothing stray remains **and** nothing unrelated was touched.

Real example (netboot HTTP port → 8181): `8080` appeared ~100× — some were the
netboot pipeline (change), many were unrelated (Open WebUI, the web UI, generic
docker/podman demos, test fixtures → leave), and one was a note explaining *why*
this host uses `8181` (`8080` is occupied by SABnzbd → must stay). A blanket
replace would have broken the unrelated hits; a too-narrow grep produced two
wrong guesses about direction. The full-repo grep + per-hit classification is
what got it right. **Host-specific values (ports especially) are often
intentional — verify what the host/configs actually use before changing them.**

### Fault-inject every discrete layer, and grade how gracefully it falls

For a lab with **layers that can fail independently** (a control plane, a driver
interface, an out-of-band channel, a state store), a passing test suite only proves
the happy path. The complementary question is **"when this breaks, how gracefully does
it fall?"** — and it is asked with a **chaos harness that injects a fault at each
layer** and grades the outcome on a ladder:

| rung | meaning | |
|---|---|---|
| **ABSORBED** | the fault never reached the service — refused before it could do harm | ← **the goal** |
| **DEGRADED** | still serving, on a fallback | acceptable *intermediate* |
| **HALTED** | not serving, but it stopped **honestly**: a named error state, a recorded reason, and a verb that recovers it | acceptable *intermediate* |
| **STRANDED** | stuck somewhere no verb accepts — nothing wrong with it, nothing to be done with it | **critical** |
| **LIED / STALE** | the record and reality disagree, or agreed once and nobody re-checked | **critical** |

**Fallback and graceful failure are the intermediate rungs, not the goal.** A run passes
at **zero criticals**; the intermediate rungs are counted and reported, never punished.

The rules that make it worth having:

- **Every discrete layer gets an injection point.** A layer with no scenario is a layer
  nobody has watched fall over. Enumerate them explicitly (each corresponds to a seam);
  name the ones **not yet covered** rather than leaving the gap implicit.
- **Grade AFTER attempting the recovery the system offers.** "Critical" must mean
  *nothing can be done about it*, not *the first thing I looked at was still wrong*.
- **The injector is a real implementation of the real interface**, so the fault runs
  through the real gates and rollback — not a special-cased branch inside the system.
- **Scope the fault to the subject under test.** A fault that breaks *everything* sends
  every scenario to the same rung and the fallback path never runs — the harness then
  reports a uniform, uninformative failure and looks like it is working.
- **Include a no-fault control row.** Otherwise "the harness reported failures" is
  indistinguishable from a system that never worked. (It earns its place: ours
  immediately caught a *grading* bug — a successful deploy being read as a fallback.)
- **Assert the rungs are OCCUPIED, not just that criticals are zero.** A matrix that
  never broke anything is all-ABSORBED; one that breaks everything unrecoverably is
  all-HALTED; one whose fallback path is dead never reaches DEGRADED. Zero criticals
  alone proves none of that.
- **Hold the harness to the standard it enforces.** Ours shipped a verifier that passed
  when the artifact was *missing* — the exact bug class it exists to hunt.

Exemplar: [`examples/metal-as-a-service/`](examples/metal-as-a-service/) —
[`chaos-run.sh`](examples/metal-as-a-service/chaos-run.sh) +
[`drivers/chaos.sh`](examples/metal-as-a-service/drivers/chaos.sh) over five layers
(driver · out-of-band · artifact store · registry · the control-plane process), with
[`tests/test-chaos-matrix.sh`](examples/metal-as-a-service/tests/test-chaos-matrix.sh)
**failing when a layer or a driver ships without coverage**. It has found three real
bugs so far, each invisible to the green suite: a node **stranded** in a transient state
no verb accepted (and `unmaintenance` handing it straight back into it), a node that
**passed its health gate and then died** while still reporting `active`, and a
**silent registry write failure** — the tool printed success, exited 0, and left the
record saying one image while the machine ran another.

### The two bug classes a green suite cannot see

Fourteen defects came out of [`examples/metal-as-a-service/`](examples/metal-as-a-service/)
on real hardware while its suite was green at every step. Nearly all were one of two
shapes, and both are **authoring** mistakes rather than coding ones — which is why more
tests of the same kind would not have found them.

#### 1. A record that outlives the thing it describes

A cached fact keeps being served after its subject changes. Nothing errors: the record is
*readable*, merely false. So the failure surfaces far downstream wearing someone else's
clothes. Every instance below is from one lab:

| the record | what it outlived | how it presented |
|---|---|---|
| `disk.raw.sha256` | a re-staged image | a node told to expect bytes nobody had |
| `pcrs.expected` | the build it was captured from | the node was wiped, re-imaged, booted — and *then* refused |
| `error_reason` | the incident that wrote it | the operator sent to an abort half an hour stale |
| the console log (append-only across boots) | the previous deploy | a second deploy reported `active` in one second |
| a `~/.cache` golden image | the code that built it | a boot that "proved" a bug still present after the fix |
| the served deployer `vmlinuz` | the kernel rebuilt over it | **`file -b` printed the identical version string; only the sha differed** |

- **Derive the fact; don't cache it.** Compute the digest from the bytes as you publish
  them. Read the firmware mode from the domain XML, not from an enroll-time default
  nobody revisits.
- **If it must be cached, bind it to its subject's identity and refuse a mismatch by
  name.** `capture-policy` stamps `# image-sha256:` into `pcrs.expected`; `verify` refuses
  a policy captured from a different build and prints both digests.
- **Refuse BEFORE the irreversible step.** A gate that fires after the `dd` is not a gate,
  it is a post-mortem.
- **Write the reason on every path.** A field three verbs maintain and a fourth does not
  is worse than absent: it is confidently wrong.
- **A version string is not an identity.** Two builds of one kernel print the same
  `file -b`. Compare hashes.
- **Scope the append-only thing.** Record a byte offset before acting and read only past
  it (`console_mark` in [`drivers/image.sh`](examples/metal-as-a-service/drivers/image.sh)),
  falling back to the whole file if it shrank — rotation is real.

#### 2. A test that asserts the mechanism instead of the outcome

An assertion naming *how* the code works passes when that mechanism is present and broken,
and fails when it is replaced by a better one. The second direction costs a day: nothing
is broken and the suite insists otherwise.

| the assertion | why it was wrong |
|---|---|
| `grep 'loaded NIC drivers'` | failed once the kernel had the drivers built in — a strictly better fix; would have *passed* had the modules loaded and the NIC still not come up |
| console fixtures **pre-written** before the deploy | proved only that the driver can grep a file the test handed it; kept passing after the driver correctly began ignoring pre-deploy output |
| delivery tested with `curl --data-binary` | binary-safe, so it proved the **sink** and nothing about the node — which has no curl, and whose `busybox wget` sends `Content-Length=strlen()`, truncating DER at the first NUL |

- **Assert the state the system must end in**, not the steps taken: "this machine has an
  interface, a MAC, and an *applied* lease", not "three modules were insmod'ed".
- **Drive the client the machine actually has.** If the payload posts with `busybox wget`,
  the test posts with `busybox wget`. A more capable tool is not a stand-in, it is a
  different seam.
- **Make effects follow causes in fixtures too.** A console exists *because* something
  booted — hence `MOCK_BMC_BOOT_SAYS`, which speaks on power-on instead of letting the
  test pre-write success.
- **A fixture the code must reject cannot also be its happy path.** Ours was a 12-byte DER
  declaring 16969 bytes of content; once the sink learned to refuse truncated DER, those
  bytes had to become the negative control and the positive case a self-consistent blob.
- **Run the negative control.** Break the thing under test and watch the assertion bite.
  Three sections here passed for weeks while proving nothing.

**Fix the liar first.** A second deploy never power-cycled the node, so it kept running
the previous image — and that was *hidden* by the stale-console bug: the dishonest gate
reported `active` in one second and survived every run, while the honest gate's nineteen
minutes of silence diagnosed itself. This is why **LIED** outranks **HALTED** on the
ladder above. An honest failure is debuggable; a false success is not.

### Doc/link integrity

`tools/link_check.py` validates Markdown cross-links repo-wide and maps file
references (`--impact <name>` shows every place a file is referenced — the edit
list before a rename/move/delete). Run it before/after any such change; it must
report **0 broken links** (it also exits non-zero on broken links, for CI/commit
gating).

**It checks the `#anchor`, not just the file** (since 2026-08-05 — before that it
split the fragment off and threw it away, so `0 broken links` meant only *the file
exists*). A missing anchor fails **silently** in a browser — you land at the top of
the page and nothing says the link was wrong — so a machine has to be the one
looking. Switching it on found three live breaks, all the same shape: **a heading
was edited and its inbound anchors were not** (`§5 Spike 0` gained "(SPARC)"; a
heading was never bare `Part 6`; "errata: **seven** commands" became "eight").

- **Don't hand-write a slug — print it.** `tools/link_check.py --anchors-of <doc>`
  lists every anchor a doc actually generates, in document order.
- **The em-dash trap** is the one that catches everyone: GitHub *deletes*
  punctuation rather than replacing it, so a heading's ` — ` (space, dash, space)
  becomes **two** hyphens. `## 5. Spike 0 (SPARC) — RESULT: **GREEN**` is
  `#5-spike-0-sparc--result-green`. Likewise `test's` → `tests`, `F.7` → `f7`, and
  a repeated heading gets `-1`, `-2` in document order.
- Regression + negative control: `tools/tests/test-link-check-anchors.sh` builds a
  fixture with **four deliberate breaks and eight legitimate anchors**, and re-runs
  the same fixture with `--no-anchors` — which must report **zero**, proving the
  failures come from the anchor logic and not from a path check.

### Route every new example into the learning-paths catalog

The labs are indexed **two** ways, and a new example must land in **both** or CI
fails. `examples/00-INDEX.md` is the *by-phase reference* (every spec gets a 00-INDEX
row). The orthogonal *by-journey* view is generated:
**`examples/learning-paths.toml`** is the single
hand-edited source of truth, rendered by **`tools/paths.py`** into
`examples/learning-paths/` (a hub + one file per path — **never hand-edit the
generated files; they carry a DO-NOT-EDIT banner**).

So when you add a cohesive lab (or a standalone root `.toml`), also **route it**:
add it as an ordered **step in a `[[path]]`** (when it fits a dependency-aware
journey — chroot *before* namespaces, a plain VM *before* kdump) and/or a
**member of a `[[collection]]`** (a themed, unordered bundle). Then
`tools/paths.py render && tools/paths.py --check`. The `--check` gate is a sibling
of `link_check.py` and must be **green**: it fails if any lab unit under
`examples/` is **unrouted** (the coverage/anti-drift guard — a lab nobody put in a
journey trips CI; intentional exclusions go in `[meta].coverage_exempt` **with a
reason**), if any ref doesn't resolve, or if the generated docs are stale.

- **Refs are `examples/`-relative** (`chroot-breakout/`, `chroot-examples/x.toml`,
  an out-of-tree hand-walk as `../micro-linux/hand-walk/`) — the same forms
  00-INDEX uses; the renderer prepends `../` so links resolve for `link_check.py`
  too. Keep **both** checkers green.
- **Every path step needs an *observable* checkpoint** — a command output, a
  file, a boot banner (mirror the lab's `MANUAL_TESTING.md` success signature),
  not "you should understand X".
- **Optionally machine-hintable:** a step may carry `verify_cmd` + `verify_marker`
  (and `verify_host = true` when the command is **host-safe, idempotent, and
  throwaway**). `tools/paths.py smoke --run` then *executes* the host-safe ones
  and greps for the marker; lab-context checkpoints are listed (via `--json`) for
  a per-lab harness. Exemplar: the `container-internals` path's part-3 OOM step
  (`verify_host=true`, marker `EXIT=137`).

### Provenance: vendor the upstream source for tutorial-based labs

Any lab that **operationalizes a specific external write-up** keeps a byte-exact,
attributed archive of that source *alongside* the operationalization, so the lab
is reproducible offline and its provenance is explicit (sources move, rot, or
get paywalled). Two tiers, by how tightly the lab tracks one source:

- **Built from one specific tutorial / blog post → vendor it.** Add an
  `upstream-tutorial/` subdir with the page saved **byte-exact** (HTML + its
  primary CSS so it renders offline) plus a `README.md` carrying: a provenance
  table (Title / Author / Canonical URL / Published / **Retrieved** date), a
  per-file **`sha256`** table, a note of what's left un-vendored (images, JS,
  fonts — absolute links to the live site), and a copyright/attribution
  paragraph ("all rights remain with the author; archived for offline reference;
  `git rm` to remove"). The parent lab's README/PLAN **must link the archive**
  (else `link_check.py` flags it as an orphan). Exemplars:
  [`examples/tiny-linux-experiments/floppinux/upstream-tutorial/`](examples/tiny-linux-experiments/floppinux/upstream-tutorial/),
  [`examples/debian-http-boot/upstream-tutorial/`](examples/debian-http-boot/upstream-tutorial/).
- **Follows official docs / an upstream catalog / upstream code (not one page)
  → cite, don't mirror.** Capture the exact URL(s) + a **retrieved/as-of date**
  + a one-line note in the lab's README; don't archive whole doc sites. (Labs
  that *fetch* their upstream live — gallery/ansible/vm-builder wrappers — pin or
  date the fetch instead.)

Fetching is allowed for archival (`curl`/`wget` of HTML/CSS is fine — the agent
Bash runner only gates fetch+**exec** of prebuilt toolchains). **Verify each URL
resolves 200 + has the expected title before hashing** — never enshrine an error
page's `sha256` as "the tutorial." Two labs sharing one source each keep their
own copy (self-containment rule), byte-identical. Keep `link_check.py` green
after every add.

### Hand-walk sandboxes: reproduce the author's environment to follow a tutorial by hand

For a tutorial-based lab, a `hand-walk/` subdir (sibling of `upstream-tutorial/`)
gives a **disposable container that reproduces the author's working environment**,
so a human can type the recipe step-by-step — distinct from the automated
`build-*.sh`. The deliverable per lab is a fixed shape:

- **`Containerfile`** — the environment *as code*: base = **the author's distro**
  where the tutorial is distro-specific (Arch for floppinux, Rocky for the
  Lorax-based rocky-pxe, Kali for kali-llm), a **neutral Debian** base where it's
  "any POSIX" (micro-linux, muxup, debian-http-boot, almalinux-server). Bake the
  tutorial's exact `apt`/`dnf`/`pacman` prereqs as readable `RUN` lines, one
  comment per line tying it to a tutorial step. Include the tool the post *runs in*
  (e.g. `qemu-system-*`) so build **and** boot happen in one box.
- **`RUNBOOK.md`** — walks the upstream steps with the **why** at each, links the
  vendored sibling `../upstream-tutorial/` as the source of truth, and contrasts
  with the repo's automated counterpart.
- **A 00-INDEX entry + an inbound link** from the parent lab's README (else
  `link_check.py` orphans it). Cataloged under *🚶 Hand-walk the tutorials*.

**Drive it through the existing phases** (`lab-podman.sh build`/`up` with a
`build =` Containerfile) — no one-off images — *unless* a step needs a privilege
the phase tool won't inject (muxup's `binfmt` → `--cap-add SYS_ADMIN
--security-opt systempaths=unconfined`); then build the image via the phase tool
and document the `podman run` launch. **Reproduce the author's env, then build +
boot it yourself to verify** — examining prereqs this way *surfaces* the real
gotchas (a hosted-C cross needs `libc6-dev-<arch>-cross`; `gcc` alone lacks
`<stdint.h>` for iPXE's host helper; debootstrap's `mknod` needs `fakeroot`;
`unshare --mount-proc` needs `/proc` un-masked). **Partition by what the sandbox
can run:** a step that hits the **toolchain-fetch gate** (musl.cc) or needs
**loop-mount/`mknod`** (blocked here even `--privileged`) is **authored with an
explicit "you run this" marker**, not silently claimed as verified — the agent
authors the Containerfile (a clean reproducible layer); the user runs the build.
Exemplars: [`micro-linux/hand-walk/`](micro-linux/hand-walk/) (clean, fully
verified), [`phase1-chroot/hand-walk/`](phase1-chroot/hand-walk/) (cap/binfmt),
[`examples/tiny-linux-experiments/floppinux/hand-walk/`](examples/tiny-linux-experiments/floppinux/hand-walk/) (author-only steps).

### Driving a boot loader / firmware serial console from a script: no flow control

Scripting a **serial console** (GRUB, SeaBIOS, an initramfs shell, a getty login)
over QEMU's unix `serial.sock` — e.g. driving a `lab-vm.sh` VM to interrupt GRUB
and edit the kernel command line — hits a trap nothing warns you about: **GRUB's
serial input has no flow control and silently DROPS characters** fed faster than
it consumes them. A long `linux …` line or a rapid key burst arrives garbled, the
edit "didn't take", and there is **no error**. (Found the hard way building
[`examples/root-password-reset/`](examples/root-password-reset/) — ~18 failed boot
cycles, all this one bug.)

- **Prefer `--echo-gate` over guessing a delay.** A fixed per-byte delay is a
  *guess about someone else's timing*, and this repo has now re-guessed it twice
  (Rocky's GRUB needed `0.08`; OpenBIOS-x86 dropped chars even at `0.04`) — the
  safe gap depends on what the consumer is doing at that instant, so no constant
  is right. Both `tools/drive-serial-repl.py` and `tools/drive-pty-repl.py` take
  **`--echo-gate`**, which **self-clocks**: send one byte, wait for the console
  to *echo that byte back*, then send the next. It cannot outrun the consumer at
  any speed, needs no tuning, and a byte that never echoes is **resent** and then
  reported (**exit 125**) instead of silently mangling the line. Only printable
  ASCII is gated (control bytes echo unpredictably: `\r`→`\r\n`, Ctrl-X→`^X`,
  DEL→`"\b \b"`); it is **opt-in** because a non-echoing prompt (password entry,
  a raw-mode reader) would never confirm. Regression test, no QEMU needed:
  `tools/tests/test-echo-gate.sh` (fixture `tools/tests/lossy-console.py` = a
  FIFO with no flow control; plain 40 ms send delivers `load-base` as `ldbe`,
  the gate delivers it whole). Verified against real OpenBIOS-ppc.
- **Testing the READER side (a SOL bridge, a boot-progress/milestone parser, the
  expect side of a driver)?** `tools/serial-source.py` is the **emitter** fixture — a
  fake serial device that streams a `--marker` or **`--replay`s a canned boot log** over
  `--tcp` / `--pty` / stdout (the complement to `lossy-console.py`). It is a *program*,
  not a shell loop, to dodge a real footgun: a shell `printf` loop over a socket/pipe
  **block-buffers and silently delivers nothing** (found wiring ipmi_sim SOL in
  [`examples/bmc-toolkit/`](examples/bmc-toolkit/README.md)) — the tool flushes every
  line. Regression: `tools/tests/test-serial-source.sh`.
- **Slow-send everything you "type":** when you can't gate on echo, one byte at a
  time with a **~40 ms** delay (`for ch in s: sock.sendall(bytes([ch]));
  sleep(0.04)`) — the floor, not a guarantee. Faster drops chars. Space out
  keystrokes (~0.3–0.4 s) and **single-step** them — bursts drop keys.
- **Short input can't be dropped:** when diagnosing *firmware* over a lossy
  console, don't type long Forth colon-definitions at the prompt — compile the
  probe in (a `forth_printf` in the C loader, or a word baked into the
  dictionary) and type one short word to invoke it.
- **Arrow-key escapes (`\x1b[B`) are unreliable** in GRUB's editor — the leading
  `Esc` reads as "discard edits / exit". Use single-byte emacs keys
  (`Ctrl-n`/`Ctrl-p`/`Ctrl-a`/`Ctrl-e`). Even then, blind multi-line navigation of
  a **wrapping** menu entry is fragile; for *deterministic automation* the GRUB
  **command line** (`c` → one slow-typed `search` / `linux … init=/bin/bash` /
  `initrd` / `boot`) beats editing the entry. Document the faithful `e`-menu-edit
  for **humans** (who navigate it visually with no trouble) — the fragility is
  purely an automation concern.
- **Catch the menu** with `EXPECT "automatically in"` (countdown, reprinted each
  second) or `"Welcome to GRUB"` (not "GNU GRUB"); **any keypress cancels** the
  countdown (the menu then waits forever — looks hung). **One client at a time** on
  the serial socket — a stray second connection silently steals the bytes. QEMU
  monitor **`sendkey` does not reach a serial GRUB** (it targets the emulated
  PS/2/VGA keyboard). For deterministic reruns, power-cycle with
  `lab-vm.sh stop --force && start` (ssh `reboot` races the attach/boot timing).
- **Ground-truth the result** with the booted kernel's **`/proc/cmdline`**, not by
  screen-scraping GRUB's noisy per-keystroke ANSI redraws.

Cloud images also bake `timeout=0` into their `grub.cfg` (menu hidden); a one-time
prestage that sets `GRUB_TIMEOUT=5` + `GRUB_TIMEOUT_STYLE=menu` and regenerates
(Debian `update-grub`, Rocky `grub2-mkconfig`) restores an interruptible **serial**
menu — lab setup, not part of the reset. Exemplar:
[`examples/root-password-reset/`](examples/root-password-reset/)
([`RUNBOOK-init-shell.md`](examples/root-password-reset/RUNBOOK-init-shell.md) +
[`MANUAL_TESTING.md`](examples/root-password-reset/MANUAL_TESTING.md)) — verified
end-to-end on Debian/BIOS.

### Killing a process: by PID, never by pattern

When a process must be killed, resolve it to a **PID first** (`pgrep`, `ps`, a
recorded `$!`, a pidfile) and `kill <pid>`. **Never** use `pkill -f` / `pkill` /
`killall` on a name or command-line substring to do the actual kill.

A pattern matches *every* process whose argv contains the string — including ones
you didn't mean and, crucially, **the very thing the pattern names**. Real
incident: `pkill -f <vm>/serial.sock` to reap a capture `socat` also matched
**QEMU itself** (its `-chardev …serial.sock` carries that exact path), so it
killed the VM — and the agent's own shell — with **exit 144**. The path you grep
for is usually shared by the workload you are trying to protect.

- **Find with a pattern, kill by PID:** `pgrep -f <pat>` to *list*, eyeball the
  hits, then `kill` the specific PID(s). Inspecting the match before killing is
  the whole point.
- This applies to any shared-substring footgun — `serial.sock` paths, a port
  number, a config filename, a lab/VM name that recurs across cmdlines.
- Prefer the tool's own lifecycle verb when there is one (`lab-vm.sh stop`,
  `lab-lxd.sh down`, `incus delete -f <name>`) over a raw signal.
