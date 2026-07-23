#!/usr/bin/env python3
"""crack.py — recover the FLOPPINUX login password from its $1$ (MD5-crypt) hash.

Educational reproducer for HASH_CRACKING.md: demonstrates on OUR OWN throwaway
lab artifact how weak a classic MD5-crypt password is. The plaintext ("lab") is
already published in the lab README; this shows the *recovery* and its speed.

Self-contained: a pure-Python md5crypt (so it works on any python3, including
3.13+ where the deprecated `crypt` module was removed) — no install, no network,
no GPU. The canonical tools for real work are john / hashcat (see the doc).
"""
import hashlib, itertools, string, time

TARGET = "$1$floppinx$2WKWnHcP/VZpbTpD57PW30"
SALT   = "floppinx"

_ITOA64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def _to64(v, n):
    out = []
    for _ in range(n):
        out.append(_ITOA64[v & 0x3f])
        v >>= 6
    return "".join(out)


def md5crypt(password, salt):
    """Poul-Henning Kamp's MD5-crypt ($1$), pure Python."""
    pw = password.encode()
    sa = salt.encode()
    ctx = hashlib.md5(pw + b"$1$" + sa)
    alt = hashlib.md5(pw + sa + pw).digest()
    i = len(pw)
    while i > 0:
        ctx.update(alt[:min(i, 16)])
        i -= 16
    i = len(pw)
    while i:
        ctx.update(b"\x00" if i & 1 else pw[:1])
        i >>= 1
    final = ctx.digest()
    for i in range(1000):
        c = hashlib.md5()
        c.update(pw if i & 1 else final)
        if i % 3:
            c.update(sa)
        if i % 7:
            c.update(pw)
        c.update(final if i & 1 else pw)
        final = c.digest()
    out = ""
    for a, b, cc in ((0, 6, 12), (1, 7, 13), (2, 8, 14), (3, 9, 15), (4, 10, 5)):
        out += _to64((final[a] << 16) | (final[b] << 8) | final[cc], 4)
    out += _to64(final[11], 2)
    return "$1$" + salt + "$" + out


def test(pw):
    return md5crypt(pw, SALT) == TARGET


def main():
    # 0) prove the pure-Python md5crypt reproduces the shipped hash
    print("recompute of 'lab':", md5crypt("lab", SALT))
    print("== target        :", TARGET, "->", test("lab"))

    # 1) dictionary attack — the realistic method (the head of any rockyou.txt)
    words = ["123456", "password", "qemu", "floppy", "linux", "root", "toor",
             "admin", "kali", "debian", "lab", "test", "letmein", "changeme",
             "floppinux"]
    t0 = time.perf_counter()
    hit = next((w for w in words if test(w)), None)
    dt = time.perf_counter() - t0
    print(f"dictionary ({len(words)} words): found={hit!r} in {dt*1000:.1f} ms")

    # 2) exhaustive brute over the 3-char [a-z] space (26^3 = 17,576)
    t0 = time.perf_counter()
    tried = 0
    found = None
    for combo in itertools.product(string.ascii_lowercase, repeat=3):
        tried += 1
        pw = "".join(combo)
        if test(pw):
            found = pw
            break
    dt = time.perf_counter() - t0
    print(f"brute [a-z]^3: found={found!r} after {tried}/{26**3} in {dt:.2f}s "
          f"({tried/dt:,.0f} guesses/s single-thread pure-python)")


if __name__ == "__main__":
    main()
