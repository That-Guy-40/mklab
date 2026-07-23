# Cracking the FLOPPINUX login hash — how weak a `$1$` password really is

> **Scope.** This recovers a password from **our own throwaway lab artifact**, on
> our own machine, for teaching. The plaintext (`lab`) is *already published* in
> [`README.md`](README.md) — the point isn't to *learn* the secret, it's to show
> the recovery and, more importantly, explain **why it's this easy** and what to
> use instead. Not aimed at any third party's system.

## The target

The QoL + login build (`LOGIN=1`, the 2.88 MB image) ships this account in
`/etc/passwd`:

```
root:$1$floppinx$2WKWnHcP/VZpbTpD57PW30:0:0:root:/home:/bin/sh
```

The password field decomposes as **`$id$salt$hash`**:

| field | value | meaning |
|---|---|---|
| `$1$` | `1` | the hash **scheme**: `1` = **MD5-crypt** (`$5$`=SHA-256-crypt, `$6$`=SHA-512-crypt, `$2b$`=bcrypt, `$argon2id$`=Argon2) |
| `floppinx` | 8-char **salt** | mixed into the hash so identical passwords hash differently |
| `2WKWnHcP/VZpbTpD57PW30` | the 22-char **digest** | MD5-crypt's 1000-round output, base64-ish encoded |

## Recovery — three ways, all trivial

Everything below ran on the verification host with no special hardware
(`openssl` + `python3`; no GPU, no `john` install needed).

### 1. Confirm the hash *is* `lab` (one MD5-crypt call)

MD5-crypt is deterministic given the salt, so you don't even need a cracker to
*check* a guess — just recompute with the same salt and compare:

```console
$ openssl passwd -1 -salt floppinx lab
$1$floppinx$2WKWnHcP/VZpbTpD57PW30      # ← byte-identical to the shipped hash
```

### 2. Dictionary attack — the realistic method

Real attackers don't brute-force blind; they run a wordlist of common/leaked
passwords first. A 15-word "weak passwords" list (the kind that leads every
`rockyou.txt`) finds it instantly:

```console
$ python3 crack.py
dictionary (15 words): found='lab' in 3.2 ms
```

The canonical tools do the same at scale — the exact commands (they need a
package install, so they're listed for you to run):

```console
# John the Ripper — autodetects $1$ as md5crypt
$ echo 'root:$1$floppinx$2WKWnHcP/VZpbTpD57PW30' > hash.txt
$ john --format=md5crypt --wordlist=/usr/share/wordlists/rockyou.txt hash.txt
$ john --show hash.txt
root:lab:...

# hashcat — mode 500 is md5crypt
$ hashcat -m 500 -a 0 hash.txt /usr/share/wordlists/rockyou.txt
```

`lab` is a 3-letter dictionary word, so it falls in the first millisecond of any
wordlist run.

### 3. Exhaustive brute force — the ceiling

Even if `lab` were *not* in any wordlist, the keyspace is laughably small. All
three-letter lowercase strings is `26³ = 17,576` candidates:

```console
$ python3 crack.py
brute [a-z]^3: found='lab' after 7438/17576 in 2.12s (3,502 guesses/s single-thread pure-python)
```

About two seconds, single-threaded, in *interpreted Python* with a hand-rolled
md5crypt (a compiled `crypt(3)` is ~4× faster still). `john`/`hashcat` on the
same CPU do **millions** of MD5-crypt guesses/sec (and a mid-range GPU does
**hundreds of millions**), so the entire 3-char space falls in well under a
millisecond, and every 6-char lowercase password (`26⁶ ≈ 3×10⁸`) in seconds. The
reproducer is [`crack.py`](crack.py) — no install, no network.

## The *why* — this is the part worth keeping

**`$1$` (MD5-crypt) is fast, and fast is the whole problem.** It runs a fixed
**1000 iterations** of MD5. That was defensible in 1994; today a commodity GPU
computes MD5 by the tens of billions per second, so 1000 rounds barely dents an
attacker's throughput. A password is only as safe as the *time per guess* times
the *number of guesses you force* — and MD5-crypt makes the time per guess
almost free.

**What the salt does — and doesn't.** The `floppinx` salt earns its keep against
*batch* attacks:

- ✅ It defeats **rainbow tables** (precomputed hash→password lookups): the
  attacker would need a separate table per salt, which is infeasible.
- ✅ It makes **identical passwords hash differently**, so a stolen `/etc/shadow`
  doesn't reveal that two users share a password.
- ❌ It does **nothing** to slow a *targeted* guess. Cracking *this one* hash
  means hashing candidates with *this one* salt — exactly what we did above. Salt
  raises the cost of attacking *many* hashes at once; it does not raise the cost
  of attacking *yours*.

**What to use instead.** Modern schemes are deliberately **slow and/or
memory-hard**, and the cost is *tunable* so it can rise with hardware:

| scheme | knob | why it resists cracking |
|---|---|---|
| `$6$` SHA-512-crypt | `rounds=` (default 5000, often 100k+) | orders of magnitude more work per guess than `$1$` |
| **bcrypt** (`$2b$`) | cost factor (2^cost rounds) | slow *by design*; decades of scrutiny |
| **Argon2id** | time + **memory** + parallelism | memory-hard → defeats cheap GPU/ASIC parallelism |

Same password `lab`, hashed as Argon2id at sane parameters, would cost an
attacker *many orders of magnitude* more per guess — though note that **no KDF
saves a 3-character password**: a weak scheme makes a *strong* password
crackable, but a strong scheme still can't rescue a password with only 17,576
possibilities. Length/entropy and a slow KDF are two independent defenses; you
need both.

## Lab-hygiene takeaway

A **published, throwaway credential is completely fine here** — this is an
air-gapped floppy with no network, booted in QEMU or on a retro box, and the
whole system already drops to root anyway (see [`README.md`](README.md) →
⚠️ Security). The exercise is a *demonstration*, not a vulnerability.

The transferable lesson is the mirror image: **this is exactly why you never ship
`LOGIN=1` (or any `$1$`/reused/dictionary credential) on a networked system.** On
a real host, `/etc/shadow` uses `$6$`/bcrypt/Argon2, passwords have real entropy,
and you never hard-code a shared secret into an image. FLOPPINUX gets to be
careless *because* it's disconnected — remove that assumption and every shortcut
here becomes a finding.
