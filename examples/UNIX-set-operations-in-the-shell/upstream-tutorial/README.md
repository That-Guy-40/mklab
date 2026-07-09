# Vendored upstream — four write-ups on set operations in the Unix shell

Byte-exact archives of the **four** pages this lab operationalizes, plus the
stylesheets they reference and Krumins' `setops.txt` cheat sheet, so they read
offline and their provenance is explicit (web pages move, rot, or get paywalled).

They are archived together because they form one story, and because **they
disagree with each other in a way that is worth catching**:

1. **The problem.** Krumins solves Google Treasure Hunt Puzzle 4 entirely from the
   shell. The crux is intersecting four files of numbers. *This is what led him to
   write about sets at all* — he says so in the first line of the next article.
2. **The article.** He writes up 14 set operations with `sort`, `uniq`, `comm`,
   `grep`, `diff`, `head`, `tail`, `wc`, `join`, `awk`.
3. **The cheat sheet.** A simplified list of the same 14, plus an `awk`
   implementation of each, and a downloadable `setops.txt`.
4. **The counterpoint.** Thomas Guest, in ACCU's *Overload*, reaches the same
   operations from a completely different direction — **counting** with
   `sort -m | uniq -c` rather than merging with `comm` — on real Apache logs, and
   then argues about what the shell tools *teach* us.

Reading (1) explains why anyone would care; (2) and (3) give the recipes; (4)
gives an independent implementation to check them against. And checking them is
the point: see [Errata](#errata-found-by-running-the-code) below.

## Provenance

| Field | Krumins ×3 | Guest ×1 |
|---|---|---|
| Author | **Peteris (Peter) Krumins** — `catonmat.net` | **Thomas Guest** — ACCU *Overload* |
| Titles | *Solving Google Treasure Hunt Puzzle 4: Prime Numbers* · *Set Operations in the Unix Shell* · *Set Operations in the Unix Shell Simplified* | *He Sells Shell Scripts to Intersect Sets* |
| Canonical URLs | <https://catonmat.net/solving-google-treasure-hunt-prime-number-problem-four> · <https://catonmat.net/set-operations-in-unix-shell> · <https://catonmat.net/set-operations-in-unix-shell-simplified> | <https://accu.org/journals/overload/15/80/guest_1410/> |
| Published | Puzzle solved **2008-06-06** (answer timestamp in the post); the two set-ops posts followed | ***Overload* 15(80), August 2007** |
| **Retrieved** | **2026-07-09** | **2026-07-09** |
| License | **No license statement anywhere on the page or site** | **"Copyright (c) 2018-2025 ACCU; all rights reserved."** |

> Note the chronology: Guest's *Overload* piece (Aug 2007) **predates** Krumins'
> puzzle (Jun 2008) by nearly a year. Neither cites the other. They converge on
> the same operations and diverge on the implementation — merge versus count —
> which is precisely why the pair is more instructive than either alone.

## Files & `sha256`

Each page is kept **byte-exact**, so its stylesheet links are untouched. Each
archive **mirrors its site's path layout** so those links resolve when served.

```
265cbdda0d40c3364260b1032ef8f0c8726ea620fb8868168765b9bb1f6f8865  catonmat/set-operations-in-unix-shell/index.html
89cd98efd67050db6ffc945c69092a2c7a1aff6d25d8de470f947fdbdc2931cb  catonmat/set-operations-in-unix-shell-simplified/index.html
f39a9177014f1ed8b43e522e5a25440d3b55b3bd780fb591aa0fdcfaf95e5ec2  catonmat/solving-google-treasure-hunt-prime-number-problem-four/index.html
0ac172be3dc663250f39ab909e1b5ef5c548c8eb7ad9eee08a5e3e74efc30fe3  catonmat/ftp/setops.txt
887b83d083107f68f5b3060b916274dc143615f34d6c589ca925d8de4f528096  catonmat/css/normalize.css
26971dc8acda2a0e03972c46c16e9ae8ddd30954145693f003ad68ea3eeef054  catonmat/css/stylesheet.css
97d97afd06b55aa3317580d047cc4557c4285b4beaf6d07e26c1f2445ded8222  accu/journals/overload/15/80/guest_1410/index.html
88683b0a41b07f465377c8846933bdfb1e57fc9a54accef3e5fd0125bd052cc7  accu/css/animate.css
131274e2a9c6ccab840dfc9c0b875dea0e2a6c47a4fdc5e24fc97d9d91ef8238  accu/css/bootstrap.3.3.7.css
a943cc65ac7d873653dccceeb64a9e37141c240b827bb3ff7315da43341487e5  accu/css/custom.css
05f1e861cb81f260375839e143061c44a5e394d30d515c9266c8bdbb43612b14  accu/css/owl.carousel.css
d76235bb401e2c9a5ff2e3822985ecf7ab447b821df3f19f9244dba09b27cb8a  accu/css/owl.theme.css
f1230bf84ccd1d54f74c9a6405fb9b6cf5150c8d4d1ee86542ec2f458ce8f7f3  accu/css/style.default.css
```

Verify any time (from this directory):

```bash
sha256sum -c <<'EOF'
265cbdda0d40c3364260b1032ef8f0c8726ea620fb8868168765b9bb1f6f8865  catonmat/set-operations-in-unix-shell/index.html
89cd98efd67050db6ffc945c69092a2c7a1aff6d25d8de470f947fdbdc2931cb  catonmat/set-operations-in-unix-shell-simplified/index.html
f39a9177014f1ed8b43e522e5a25440d3b55b3bd780fb591aa0fdcfaf95e5ec2  catonmat/solving-google-treasure-hunt-prime-number-problem-four/index.html
0ac172be3dc663250f39ab909e1b5ef5c548c8eb7ad9eee08a5e3e74efc30fe3  catonmat/ftp/setops.txt
887b83d083107f68f5b3060b916274dc143615f34d6c589ca925d8de4f528096  catonmat/css/normalize.css
26971dc8acda2a0e03972c46c16e9ae8ddd30954145693f003ad68ea3eeef054  catonmat/css/stylesheet.css
97d97afd06b55aa3317580d047cc4557c4285b4beaf6d07e26c1f2445ded8222  accu/journals/overload/15/80/guest_1410/index.html
88683b0a41b07f465377c8846933bdfb1e57fc9a54accef3e5fd0125bd052cc7  accu/css/animate.css
131274e2a9c6ccab840dfc9c0b875dea0e2a6c47a4fdc5e24fc97d9d91ef8238  accu/css/bootstrap.3.3.7.css
a943cc65ac7d873653dccceeb64a9e37141c240b827bb3ff7315da43341487e5  accu/css/custom.css
05f1e861cb81f260375839e143061c44a5e394d30d515c9266c8bdbb43612b14  accu/css/owl.carousel.css
d76235bb401e2c9a5ff2e3822985ecf7ab447b821df3f19f9244dba09b27cb8a  accu/css/owl.theme.css
f1230bf84ccd1d54f74c9a6405fb9b6cf5150c8d4d1ee86542ec2f458ce8f7f3  accu/css/style.default.css
EOF
```

## Opening them offline

**Both sites link their CSS with absolute paths** (`/css/stylesheet.css`,
`/css/style.default.css`), which a browser resolves against the *filesystem root*
over `file://`. Opening an `index.html` directly therefore renders it **unstyled**
— the prose and every code block are all there and perfectly readable. To see a
page as published, serve its mirror root over HTTP so `/css/...` resolves:

```bash
( cd catonmat && python3 -m http.server 8899 )   # then open
# http://localhost:8899/set-operations-in-unix-shell/
# http://localhost:8899/set-operations-in-unix-shell-simplified/
# http://localhost:8899/solving-google-treasure-hunt-prime-number-problem-four/
# http://localhost:8899/ftp/setops.txt

( cd accu && python3 -m http.server 8899 )       # then open
# http://localhost:8899/journals/overload/15/80/guest_1410/
```

(Port 8899 is arbitrary and host-local. Catonmat's `<link>` tags carry a
`?v=e5f5bf` cache-busting query, which an HTTP server ignores and `file://` does
not — another reason to serve rather than open.)

The cheat sheet [`catonmat/ftp/setops.txt`](catonmat/ftp/setops.txt) is plain
text; just read it.

## Not vendored (live links remain absolute to the original hosts)

**Krumins / catonmat** — the site's only script is a StatCounter beacon. The
articles' images are the site logo, a decorative footer graphic, and **one content
figure**: a Venn diagram of union/intersection/complement
(`wp-content/uploads/2008/10/set-union-intersect-complement.jpg`, ~6 KB, still
live). Its `<img src>` is **absolute**, so it loads when you are online and shows
a broken-image icon when you are not. The article is fully comprehensible without
it — the same treatment the
[perceptron lab](../../AI-build-a-perceptron/README.md) gives its two diagrams.

**Guest / ACCU** — the six local stylesheets **are** vendored. The site's
JavaScript (jQuery, Bootstrap, Owl Carousel, waypoints, `front.js`), the two
`oss.maxcdn.com` shims, the ACCU logo/hamburger images, and the
`ads.accu.org` ad-server `<img>` are **not**: none is needed to read the article,
and archiving a third-party ad beacon offline serves no purpose. The article
contains **no diagrams or figures**.

## Errata found by running the code

All four pages were **executed**, not just read. Seven published commands do not
do what their surrounding prose claims, and *every one of them fails quietly* —
no error, just a wrong, empty, or hung answer. They are archived here
**unmodified**; the corrections live in the lab, not in the archive.

| # | Source | As published | What actually happens |
|---|---|---|---|
| 1 | Krumins, *Set Ops* (throughout) | "if you have a numeric set, then `sort` must take `-n`", e.g. `comm -12 <(sort -n set1) <(sort -n set2)` | **`comm` merges byte-wise, not numerically.** Feeding it `sort -n` output makes it silently miss matches. On `P={1,9,10}`, `Q={10}` the intersection comes back **empty**. The same trap makes his subset test report a subset as *not* a subset. |
| 2 | Krumins, *Set Ops* → Union | `$ set -um set1 set2` | Typo for `sort -um`. In bash, `set -u -m` **enables `nounset`** and assigns `$1`/`$2`; it prints nothing and returns 0. A union that silently changes your shell options. |
| 3 | Krumins, *Set Ops* → Symmetric Difference | `comm -3 <(sort -n A) >(sort -n B)` | `>(…)` is an **output** process substitution. `comm` gets a write-only pipe to read from and **hangs forever**. |
| 4 | Krumins, *Set Ops* → Maximum | `$ head -1 <(sort -n Abig)` printed as `4294906714` | `head -1` of an ascending sort is the **minimum**. The command shown is `head`; the value shown is what `tail -1` returns. |
| 5 | Krumins, *Simplified* → Subset Test | `awk 'NR==FNR { a[$0]; next } { if !($0 in a) exit 1 }'` | **gawk syntax error** — `if` requires parentheses: `if (!($0 in a))`. The cheat-sheet line has never run. |
| 6 | Guest, *Overload* → limitations | `sort -t. +0n -1n +1n -2n +2n -3n +3n IP` | Obsolete POSIX `+POS -POS` key syntax. GNU `sort` still accepts it (even under `POSIXLY_CORRECT`), but **BusyBox `sort` rejects it**: `invalid option -- '1'`. Modern spelling: `sort -t. -k1,1n -k2,2n -k3,3n -k4,4n`, or just `sort -V`. |
| 7 | Guest, *Overload* → intersection | `sort -m IP1 IP2 \| uniq -c \| grep "^ *2"` | Correct **only** for true sets, where counts are 1 or 2 — as he states. Applied to a **multiset**, `^ *2` also matches counts `20`, `21`, `200`… Anchor the field instead: `awk '$1 == 2'`. |

**Erratum 1 is the one that matters**, and the archive contains its own refutation.
Krumins' set-ops article recommends `comm` with `sort -n`. His *puzzle* solution —
the thing that inspired the article — instead uses `sort -nm … | uniq -d`, which is
collation-safe because `uniq` only needs equal lines to be *adjacent*. Running his
article's recipe against his own puzzle's data destroys the answer:

```
4-way intersect, his puzzle pipeline  (sort -nm | uniq -d) -> 7830239
4-way intersect, his article's recipe (comm + sort -n)     -> (empty)
4-way intersect, comm used correctly  (comm + sort)        -> 7830239
```

Proof for each erratum — commands and captured output — is in
[`../MANUAL_TESTING.md`](../MANUAL_TESTING.md#documented-errata-seven-published-commands-that-dont-do-what-they-say).

## License / attribution

**Krumins / catonmat** states **no license** anywhere on the pages or the site, so
the three articles and `setops.txt` are treated as all-rights-reserved.
**ACCU** states **"Copyright (c) 2018-2025 ACCU; all rights reserved."**

All four are reproduced here **verbatim, with attribution, for offline educational
reference** only — not redistribution. All rights remain with the respective
authors and publishers; no endorsement is implied. To remove either archive,
`git rm` its directory.

Sources of truth:
- <https://catonmat.net/solving-google-treasure-hunt-prime-number-problem-four>
- <https://catonmat.net/set-operations-in-unix-shell>
- <https://catonmat.net/set-operations-in-unix-shell-simplified>
- <https://catonmat.net/ftp/setops.txt>
- <https://accu.org/journals/overload/15/80/guest_1410/>
