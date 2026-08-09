# MANUAL_TESTING — captured transcripts

Real output from provisioning and exercising this lab end-to-end, plus both
negative controls (the fixture broken on purpose, the checks watched to bite).
Trimmed only for length (package-install noise), never edited.

**Environment honesty:** these transcripts were captured in a plain
`rockylinux:9` **OCI container** (Rocky Linux 9.3 "Blue Onyx", docker) — every
guest-side step is byte-for-byte what `setup-workshop.sh` drives, in the same
order (install `rpm-build`/`createrepo_c`/`sudo` → `bin/build-bat-hell-repo.sh`
→ baseline install → mirrors disabled → `learner` + sudoers → sandbox pushed →
`demo.sh` as `learner`), and `demo.sh` was run **as the non-root `learner`**
exactly as the workshop leaves it. The Phase-5 **launch path itself**
(`lab-lxd.sh up` against `images:rockylinux/9`, then `setup-workshop.sh`
driving `lab-lxd.sh exec`) is the standard sibling mechanism but was **not
exercised in this capture** — it needs an initialised LXD/Incus host. If you
run it, the success signature is unchanged: the same `PASS:` line at the end
of step 6.

| Check | Rocky Linux 9 (EL9) |
|---|---|
| `/usr/bin/yum` → `dnf-3` (article commands run verbatim) | ✅ |
| bat-hell repo builds: 10 RPMs, `createrepo_c`, `.repo` file | ✅ |
| baseline: `bat-shared-56` + 6 bystanders | ✅ |
| §1 THE HELL — install refused, conflict named, `--allowerasing` hinted | ✅ |
| §2 THE TRAP — cascade lists all 6 bystanders, `Remove 7 Packages`, declined intact | ✅ |
| §3 THE ESCAPE — `yum shell` verbatim; 1 txn; 6 survivors; history agrees | ✅ |
| §4 THE FINALE — client + shared-57 in, exactly 2 packages altered | ✅ |
| §5 ROAD 2 — `dnf swap`, same shape | ✅ |
| §6 ROAD 3 — `--allowerasing` erases exactly `bat-shared-56` | ✅ |
| §7 — road 1 end state == road 3 end state, package for package | ✅ |
| `demo.sh` idempotent (re-run from a dirty end state → same PASS) | ✅ |
| runs as root **and** as `learner` via sudo | ✅ |
| negative control 1 — `Conflicts:` deleted → 9 checks bite | ✅ |
| negative control 2 — compat's `Provides:` deleted → 5 checks bite | ✅ |

Versions actually exercised:

| | Rocky Linux 9.3 |
|---|---|
| rpm | 4.16.1.3 |
| dnf | 4.14.0 (`yum` = the `dnf-3` compat CLI) |
| createrepo_c | 0.20.1 |
| sudo | 1.9.17p2 |

## The full `demo.sh` transcript (as `learner`)

```
== 0. the box: Rocky Linux, where `yum` never went away — it IS dnf ==
Rocky Linux release 9.3 (Blue Onyx)
    /usr/bin/yum -> /usr/bin/dnf-3
   [ok]  yum on this box is the dnf compat CLI (article commands run verbatim)
    --- restoring the article's opening state (bin/reset-hell.sh) ---
    hell restored: bat-shared-56 + 6 bystanders installed; the 5.7 stack is not
   [ok]  production baseline: bat-shared-56 + all 6 bystanders installed

== 1. THE HELL  —  `yum install bat-client-57` (his opening error, our packages) ==
     Problem: problem with installed package bat-shared-56-5.6.38-rel83.0.el9.noarch
      - package bat-shared-compat-57-5.7.20-19.1.el9.noarch from bat-hell conflicts with bat-shared-56 provided by bat-shared-56-5.6.38-rel83.0.el9.noarch from @System
      - package bat-shared-compat-57-5.7.20-19.1.el9.noarch from bat-hell conflicts with bat-shared-56 provided by bat-shared-56-5.6.38-rel83.0.el9.noarch from bat-hell
      - package bat-shared-57-5.7.20-19.1.el9.noarch from bat-hell requires bat-shared-compat-57, but none of the providers can be installed
      - package bat-client-57-5.7.20-19.1.el9.noarch from bat-hell requires bat-shared-57, but none of the providers can be installed
      - conflicting requests
    (try to add '--allowerasing' to command line to replace conflicting packages or '--skip-broken' to skip uninstallable packages or '--nobest' to use not only best candidate packages)
   [ok]  the install is refused (exit status)
   [ok]  the refusal names the crux: compat-57 conflicts with bat-shared-56
   [ok]  2018 got '--skip-broken' advice; EL9 already hints at --allowerasing

== 2. THE TRAP  —  "OK, so I will just remove it":  yum remove bat-shared-56 ==
    Removing:
     bat-shared-56         noarch      5.6.38-rel83.0.el9      @bat-hell        0
    Removing dependent packages:
     hell-lsb-core         noarch      4.1-27.el9              @bat-hell        0
     hellban               noarch      0.9.7-1.el9             @bat-hell        0
     hellban-sendmail      noarch      0.9.7-1.el9             @bat-hell        0
     meatloaf-mta          noarch      2.10.1-6.el9            @bat-hell        0
     perl-DBD-bat          noarch      4.023-5.el9             @bat-hell        0
     python-bat            noarch      1.2.5-1.el9             @bat-hell        0
    Transaction Summary
    Remove  7 Packages
   [ok]  the cascade would take all 6 innocent bystanders ("Very much not OK")
   [ok]  transaction summary: Remove 7 Packages — for a 1-package problem
   [ok]  --assumeno said N for us: rc=1 and nothing was actually removed

== 3. THE ESCAPE  —  his fix, verbatim: remove + install as ONE transaction ==
    > remove bat-shared-56
    > install bat-shared-compat-57
    > run
    > exit
    Installing:
     bat-shared-compat-57     noarch     5.7.20-19.1.el9        bat-hell      6.1 k
    Removing:
     bat-shared-56            noarch     5.6.38-rel83.0.el9     @bat-hell       0
    Transaction Summary
   [ok]  yum shell ran the swap (exit status)
   [ok]  the swap took: bat-shared-56 out, bat-shared-compat-57 in
   [ok]  all 6 bystanders survived — the entire point of the article
    history:     Install bat-shared-compat-57-5.7.20-19.1.el9.noarch @bat-hell
    history:     Removed bat-shared-56-5.6.38-rel83.0.el9.noarch     @@System
   [ok]  dnf history agrees: ONE transaction holds both the Install and the Removed

== 4. THE FINALE  —  "And then finally": the original install now just works ==
    Install  2 Packages
    Complete!
   [ok]  yum install bat-client-57 succeeds (exit status)
   [ok]  his 'Install 1 Package (+1 Dependent package)': client + shared-57
   [ok]  and it altered exactly those two packages, nothing else

== 5. ROAD 2  —  what 2018 taught became a verb: dnf swap ==
    hell restored: bat-shared-56 + 6 bystanders installed; the 5.7 stack is not
   [ok]  hell restored for road 2 (bystanders back, 5.7 stack gone)
    history:     Install bat-shared-compat-57-5.7.20-19.1.el9.noarch @bat-hell
    history:     Removed bat-shared-56-5.6.38-rel83.0.el9.noarch     @@System
   [ok]  dnf swap does the same exchange in one line (exit status)
   [ok]  same shape: one transaction, Install + Removed, 6 survivors

== 6. ROAD 3  —  the hint from section 1: dnf install --allowerasing ==
    hell restored: bat-shared-56 + 6 bystanders installed; the 5.7 stack is not
   [ok]  hell restored for road 3
    Installing:
     bat-client-57            noarch     5.7.20-19.1.el9        bat-hell      6.0 k
    Installing dependencies:
     bat-shared-57            noarch     5.7.20-19.1.el9        bat-hell      6.0 k
     bat-shared-compat-57     noarch     5.7.20-19.1.el9        bat-hell      6.1 k
    Removing dependent packages:
     bat-shared-56            noarch     5.6.38-rel83.0.el9     @bat-hell       0
    Transaction Summary
   [ok]  the original install succeeds in ONE command (exit status)
   [ok]  the depsolver erased exactly one package, and it is bat-shared-56
   [ok]  full 5.7 stack in, all 6 bystanders still standing

== 7. THE ROADS AGREE  —  three escapes, byte-identical end state ==
    bat-client-57-5.7.20
    bat-shared-56: absent
    bat-shared-57-5.7.20
    bat-shared-compat-57-5.7.20
    hell-lsb-core-4.1
    hellban-0.9.7
    hellban-sendmail-0.9.7
    meatloaf-mta-2.10.1
    perl-DBD-bat-4.023
    python-bat-1.2.5
   [ok]  yum shell + install  ==  dnf install --allowerasing (package for package)

PASS: all 23 checks hold (yum shell == dnf swap == --allowerasing; 6 bystanders, 0 harmed)
```

Note the run above **started from a previous run's end state** — section 0's
`reset-hell.sh` is what makes `demo.sh` idempotent, and that property is
exercised on every consecutive run.

## Negative control 1: delete the `Conflicts:`, and there is no hell

The fixture must be load-bearing: rebuild the repo with
`bat-shared-compat-57`'s `Conflicts: bat-shared-56` line deleted
(`sed '/Conflicts: bat-shared-56/d' bin/build-bat-hell-repo.sh | bash`,
then `dnf clean all`) and the story collapses — the install just succeeds —
and the checks say so by name:

```
   [BAD] the install is refused (exit status)  (got "0", want "1")
   [BAD] the refusal names the crux: compat-57 conflicts with bat-shared-56  (pattern "bat-shared-compat-57.*conflicts with bat-shared-56" not found in output)
   [BAD] 2018 got '--skip-broken' advice; EL9 already hints at --allowerasing  (pattern "\-\-allowerasing" not found in output)
   [BAD] the cascade would take all 6 innocent bystanders ("Very much not OK")  (got "0", want "6")
   [BAD] transaction summary: Remove 7 Packages — for a 1-package problem  (pattern "^Remove +7 Packages" not found in output)
   [BAD] dnf history agrees: ONE transaction holds both the Install and the Removed  (got "1", want "2")
   [BAD] and it altered exactly those two packages, nothing else  (got "0-of-1", want "2-of-2")
   [BAD] the depsolver erased exactly one package, and it is bat-shared-56  (got "0/0", want "1/1")
   [BAD] REGRESSION: the three roads no longer converge on the same installed set
FAIL: 9 of 23 checks failed
```

(A first attempt at this control matched `^Conflicts` anchored to line start —
which never matches the indented line inside the build script — and the demo
kept passing against an unbroken repo. The control controlled the control.)

## Negative control 2: delete compat's `Provides:`, and every road eats bystanders

The scarier injection — `bat-shared-compat-57` no longer provides
`libbat.so.18`, so the swap leaves the bystanders' dependency unprovided.
This is the failure mode the whole lab guards, and each road degrades
differently: `yum shell` completes its swap but the cascade follows;
`dnf swap` refuses outright (rc=1); `--allowerasing` erases **seven** packages
instead of one:

```
   [BAD] all 6 bystanders survived — the entire point of the article  (got "no", want "yes")
   [BAD] dnf swap does the same exchange in one line (exit status)  (got "1", want "0")
   [BAD] same shape: one transaction, Install + Removed, 6 survivors  (got "0/yes", want "2/yes")
   [BAD] the depsolver erased exactly one package, and it is bat-shared-56  (got "7/1", want "1/1")
   [BAD] full 5.7 stack in, all 6 bystanders still standing  (got "no", want "yes")
FAIL: 5 of 23 checks failed
```

Rebuilding the repo with the pristine `bin/build-bat-hell-repo.sh` (+
`dnf clean all`) restores `PASS: all 23 checks hold` — captured immediately
after the controls above.
