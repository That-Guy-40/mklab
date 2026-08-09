# RUNBOOK — walking into dependency hell, and out again, by hand

The by-hand version of what [`setup-workshop.sh`](setup-workshop.sh) +
[`demo.sh`](demo.sh) automate. Keep the article open while you type — it is
vendored byte-exact in
[`upstream-tutorial/`](upstream-tutorial/README.md), and every section below
names the moment in it being replayed. Commands run as the `learner`; anything
that changes package state is `sudo`, because dnf transactions are root's job
and sudoing them is exactly what you would do on a production box.

```bash
phase5-lxd/lab-lxd.sh up --config examples/RPM-dependency-hell-in-the-yum-shell/yum-shell-rocky.toml
examples/RPM-dependency-hell-in-the-yum-shell/setup-workshop.sh yum-shell-rocky/shell
phase5-lxd/lab-lxd.sh exec yum-shell-rocky/shell -- su - learner
```

## 0. Know your ground: on Rocky, `yum` never went away — it IS dnf

```bash
cat /etc/rocky-release
readlink -f /usr/bin/yum        # -> /usr/bin/dnf-3
```

The article is EL7 + yum. EL8/9 replaced yum's implementation with dnf and kept
the *name* as a compat CLI — which is why every command in a 2018 war story
still runs verbatim in 2026. The output cosmetics differ (dnf's depsolver
speaks libsolv, not yum's python resolver); the plot does not.

Your box's "production" state, straight from the article's cast list (renamed —
the packages are tiny local fakes from `/opt/bat-hell/repo`, built by
[`bin/build-bat-hell-repo.sh`](bin/build-bat-hell-repo.sh); the name-for-name
mapping to his Percona/postfix cast is the table at the top of that script):

```bash
rpm -q bat-shared-56 meatloaf-mta python-bat perl-DBD-bat \
       hellban hellban-sendmail hell-lsb-core
rpm -q --provides bat-shared-56       # libbat.so.18 — remember this soname
rpm -q --requires meatloaf-mta        # ...because your MTA links it
```

One library soname, provided by an installed package, needed by production
services. That is the tripwire.

## 1. The hell: his opening error (article: `Error: foo conflicts with bar`)

```bash
sudo yum install bat-client-57
```

Refused. Read the `Problem:` block bottom-up, the way the article walks its
`Resolving Dependencies` transcript top-down: client-57 needs shared-57, which
needs shared-compat-57, which **conflicts with the installed bat-shared-56** —
because both provide `libbat.so.18` and are mutually exclusive. His diagnosis,
in his words: *"the problem shows up when you have several major versions of a
program available, all providing some of the same functionality to other
packages, all being mutually exclusive."*

Note the last line of the refusal: EL9's dnf suggests `--allowerasing`. His
EL7 yum suggested `--skip-broken` — which cannot help (nothing is broken;
something is *conflicting*). Hold that thought for §5.

## 2. The trap: "OK, so I will just remove it"

```bash
sudo yum remove bat-shared-56
```

**Read the transaction table before you touch the keyboard.** Removing one
library package would take six dependent packages with it — your MTA, the
`hell-lsb-core` whose real-world twin's description ("the fundamental system
interfaces, libraries, and runtime environment upon which all conforming
applications and libraries depend") is what made him write *"Very much not
OK"*. Answer **N**, like he did.

Why the cascade: RPM refuses to leave a package's `Requires:` unsatisfied, and
a plain `remove` can only *remove* to keep that invariant. `meatloaf-mta` needs
`libbat.so.18`; with bat-shared-56 gone nothing would provide it; so the MTA
goes too, and then everything needing an MTA follows.

## 3. The turn: the word "transaction" is the answer

The article's pivot: *"Did you notice the use of the word transaction in
Transaction Summary from yum? A transaction is actually what I want."* Remove
the old provider and install the new one **in the same depsolver run**, and the
`libbat.so.18` requirement never goes unsatisfied — no cascade.

His fix, verbatim, interactively (type it like he did):

```bash
sudo yum shell
> remove bat-shared-56
> install bat-shared-compat-57
> run
```

Confirm `y` at the summary — it should say Install 1, Remove 1, and *nothing
else* — then `exit`. (Scripted form, which is what `demo.sh` uses:
`printf 'remove bat-shared-56\ninstall bat-shared-compat-57\nrun\nexit\n' | sudo yum shell -y`.)

Verify no bystander was harmed, and that history recorded ONE transaction:

```bash
rpm -q meatloaf-mta python-bat perl-DBD-bat hellban hellban-sendmail hell-lsb-core
sudo dnf history info last     # Install compat-57 + Removed shared-56, same ID
```

## 4. The finale: "And then finally"

```bash
sudo yum install bat-client-57      # Install 1 Package (+1 Dependent package)
rpm -q bat-client-57 bat-shared-57
```

Done and done :-) — the article ends here. The lab has two more roads.

## 5. Roads he couldn't take in 2018

Reset to the opening state any time (offline, ~1 s):

```bash
bash ~/dependency-hell/bin/reset-hell.sh
```

**Road 2 — the trick became a verb.** `dnf swap` *is* the shell session of §3,
spelled as one command:

```bash
sudo dnf swap bat-shared-56 bat-shared-compat-57
sudo dnf history info last          # same shape: one txn, Install + Removed
```

**Road 3 — the error message learned the answer** (reset again first). Take
the hint §1 printed:

```bash
sudo dnf install --allowerasing bat-client-57
```

One command replays the entire article: the depsolver is allowed to *erase* its
way out of the conflict, chooses to erase **exactly** bat-shared-56 — the one
package he hand-picked — and the whole 5.7 stack arrives with all six
bystanders untouched. Check what it chose before trusting it on a real box:
`--allowerasing` hands the *choice* of casualties to the depsolver, so the
transaction table is the contract. Here the table is honest and minimal; a
messier repo can make it choose more creatively.

**Why `yum shell` still matters** when both one-liners exist: the shell is the
general form. Any set of marks — several removes, several installs, a
downgrade — can ride one transaction; `swap` and `--allowerasing` are the two
most common shapes of that, promoted to flags.

## 6. Prove it all in one go

```bash
bash ~/dependency-hell/demo.sh      # -> PASS: all 23 checks hold
```

## 7. Optional excursions

- **Read the hell's source.** `less ~/dependency-hell/bin/build-bat-hell-repo.sh`
  — ten spec files, three directives (`Provides:` / `Requires:` / `Conflicts:`),
  zero payload. Dependency hell is pure metadata; that is why it can be
  bottled.
- **Make it worse.** Rebuild the repo with the `Conflicts:` line deleted and
  watch §1 sail through — no conflict, no story ([`demo.sh`](demo.sh)'s
  negative control, run by hand). Or delete compat-57's `Provides:` and watch
  *every* escape road start eating bystanders — `dnf swap` refuses outright,
  and `--allowerasing` erases seven packages instead of one.
- **Interrogate history.** `sudo dnf history` and `sudo dnf history info <id>`
  turn the box's whole life into an audit log; `sudo dnf history undo last` is
  the transaction concept paying rent a second time. (Undo of the swap works
  here because both providers are still in the repo.)
- **Re-enable the world.** The box's network mirrors were disabled for
  determinism: `sudo sed -i 's/^enabled=0/enabled=1/' /etc/yum.repos.d/rocky*.repo`.
