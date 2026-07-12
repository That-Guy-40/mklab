# Vendored upstream — two attempts at decimal arithmetic in pure Bash

Byte-exact archives of the **two** sources this lab operationalizes, so both read
offline and their provenance is explicit (web pages move, rot, and repos get
force-pushed).

The pair is not an arbitrary editorial choice. **shellmath's own README names the
Stack Overflow answer as its prior art** — the two sources are already in
conversation, and the lab simply runs both sides of it:

> *"A [diamond-in-the-rough](http://stackoverflow.com/a/24431665/3776858) buried
> elsewhere on Stack Overflow. This down-and-dirty milestone computes the decimal
> quotient of two integer arguments. At a casual glance, it seems to have drawn
> inspiration from the Euclidean algorithm for computing GCDs, an entirely
> different approach than `shellmath`'s."*
> — [`shellmath/README.md`](shellmath/README.md), §Background

Read **Cyrus** for the *minimum viable* decimal (one algorithm, 12 lines, integers
only); read **Wood** for the *fully general* one (four operations, arbitrary arity,
scientific notation, and an argument about why you would do this at all rather than
shelling out to `bc`).

## Provenance

| Field | Cyrus (Stack Overflow) | Michael Wood (`shellmath`) |
|---|---|---|
| Title | **Division in script and floating-point** (the question); this lab uses **answer `24431665`** | **Shellmath** — *"Yes, Virginia, you can do floating-point arithmetic in Bash!"* |
| Author | **Cyrus**, "modified by community" (see the post's *Timeline*) | **Michael Wood** (`clarity20`) |
| Canonical URL | <https://stackoverflow.com/a/24431665> | <https://github.com/clarity20/shellmath> |
| Published | Answer posted **2014-06-26** (question 2012) | Repo © **2020–2022**; archived commit **2023-09-28** |
| **Retrieved** | **2026-07-12** | **2026-07-12** |
| **Pinned at** | answer id `24431665` (revision as retrieved) | commit **`f2cbc6cb99c676ce56de493133890370f3b002f7`** (`master`) |
| License | **CC BY-SA 4.0** (Stack Exchange contributor terms) | **GPL-3.0** — *"Shellmath is copyright (c) 2020-2022 by Michael Wood"* |

## What is mirrored, and what is only *cited*

Per this repo's provenance convention — *vendor a page, cite a codebase*:

- **The Stack Overflow answer is a page** → the whole question thread is archived
  byte-exact ([`stackoverflow/index.html`](stackoverflow/index.html)), and Cyrus's
  `div` function is reproduced **verbatim** as a runnable script in
  [`../bin/div`](../bin/div) — the object of study.
- **shellmath is a codebase, not a page** → only its **README** (the tutorial) is
  vendored ([`shellmath/README.md`](shellmath/README.md)), together with the one
  image it inlines ([`shellmath/image.png`](shellmath/image.png)), so the page renders
  offline as published. The library itself is **cited and pinned**:
  `setup-workshop.sh` clones it at the exact commit above. A moving `master` would
  silently change the errata below, so the SHA is pinned, not floating.

## Files & `sha256`

```
f67e6a941a90b0c9599271d67e71a56b17a9c70ed6998fdb7c1c602250ce01b4  shellmath/README.md
db7e21c3012bc7e72adbdd6063fc4529a4270039d70cbf84547074d648085a23  shellmath/image.png
0fffe06c242a5e695a6b656f60b338eec854cbaca815145cbb9e0dc9072326e5  stackoverflow/index.html
```

Verify any time (from this directory):

```bash
sha256sum -c <<'EOF'
f67e6a941a90b0c9599271d67e71a56b17a9c70ed6998fdb7c1c602250ce01b4  shellmath/README.md
db7e21c3012bc7e72adbdd6063fc4529a4270039d70cbf84547074d648085a23  shellmath/image.png
0fffe06c242a5e695a6b656f60b338eec854cbaca815145cbb9e0dc9072326e5  stackoverflow/index.html
EOF
```

## Not vendored

**Stack Overflow** — the page's **stylesheets are linked by absolute URL**
(`https://stackoverflow.com/Content/...`), not relatively, so a vendored copy could
not resolve without editing the byte-exact HTML. Opened over `file://` the archive
therefore renders **unstyled** — the question, Cyrus's answer, the other answers and
all the comments are entirely present and readable. The page's JavaScript and images
(avatars, sprites, ad/analytics beacons) are likewise left as live absolute links.

**shellmath** — everything except the README and its inline image: the library
(`shellmath.sh`), its two demos (`slower_e_demo.sh`, `faster_e_demo.sh`), `assert.sh`,
`runTests.sh`, `testCases.in` and `timingData.txt`. All are fetched at the pinned
commit by `setup-workshop.sh`. The two wiki pages the README links (on arbitrary
precision, and on runtime efficiency) live in the GitHub wiki, not the repo, and are
cited only.

## Errata found by running the code

Both sources were **executed**, not just read — on Debian 13 (bash 5.2, glibc) and
Alpine (bash 5.3, musl). **Four published things do not do what they say**, and all
four fail *quietly*: no error, no non-zero exit, just a wrong answer that looks
plausible. They are archived here **unmodified**; the corrections live in the lab
([`../bin/fixed/`](../bin/fixed/)), never in the archive.

| # | Source | As published | What it actually does |
|---|---|---|---|
| 1 | **Cyrus**, `div` | `div -7 2` (nothing restricts the arguments to positives) | Emits **`-3.-5`** — not a number at all. Bash's `/` truncates toward zero, so the remainder is negative too, and *every recursive digit carries its own minus sign*: `div -1 3` → `0.-3-3-3-3-3-3-3-3-3-3-3-3`. Exit status **0**. |
| 2 | **Cyrus**, `div` | `div 999999999999999999 1000000000000000000` — innocent, positive integers | Each step computes `e*10` where `0 ≤ e < divisor`. Once the divisor exceeds `INTMAX/10`, that product **wraps int64** and you get the same negative-digit garbage: `0.-8-4-4-6-7-4-40-7-3-70` (`bc`: `.999999999999`). Silent. |
| 3 | **Wood**, `shellmath` | `_shellmath_add 1.009 4.223e-2` — **the README's own headline example** | Returns **`1.2643e0`**; the answer is **`1.05123`**. `add`/`subtract` treat *any* exponent ≤ `e-2` as though it were `e-1` (`1 + 2e-2` → `1.2`, `1 + 2e-3` → `1.2`, `1 + 2e-4` → `1.2`). `multiply`/`divide` handle the same operands correctly. Workaround: expand to plain decimal first ([`../bin/fixed/sci2dec`](../bin/fixed/sci2dec)). |
| 4 | **Wood**, `shellmath` README | *"`$ slower_e_demo.sh 15` → `e = 2.7182818284589936`"* | At the pinned commit the demo prints **`e = 2.718281828458994464`**. The published string cannot be reproduced by the code the repo ships (the README's figure was evidently captured from an older build / another platform — the author's timings are from minGW64 on Windows). Both demos still agree *with each other* and with `bc`'s `e` to 10 decimals. |

Erratum **3** is the sharpest, because it is the library's *own documented example*
in its *own* README — the very first call a new user copies — and it is wrong by an
order of magnitude, silently. Erratum **2** is the most dangerous in practice: the
inputs are ordinary positive integers.

Proof for each — commands and captured output on both distros — is in
[`../MANUAL_TESTING.md`](../MANUAL_TESTING.md#errata-four-published-things-that-dont-do-what-they-say).
None of the four undermines either author's central claim: **you really can do
floating-point arithmetic in Bash**, and both sources demonstrate it.

## License / attribution

- **Cyrus's answer** is licensed **CC BY-SA 4.0** under the Stack Exchange
  contributor terms. It is reproduced here with attribution (author, canonical URL,
  retrieval date) and the `div` function is reused in [`../bin/`](../bin/) under the
  same licence; the corrected twin in [`../bin/fixed/`](../bin/fixed/) is a
  derivative work and is likewise **CC BY-SA 4.0**.
- **shellmath** is **GPL-3.0**, © Michael Wood 2020–2022. Its README is reproduced
  here verbatim with attribution for offline educational reference. The library is
  **not** redistributed — it is fetched from the author's repository at a pinned
  commit. No endorsement is implied.

To remove either archive, `git rm` its directory.

Sources of truth:
- <https://stackoverflow.com/a/24431665>
- <https://github.com/clarity20/shellmath>
