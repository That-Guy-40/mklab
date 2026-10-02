#!/usr/bin/env bash
# build-pacme.sh — build GNU poke's acme-style UI (pacme) FROM SOURCE into a
# lab-local prefix, no sudo. The Spike 3-full enabler: with pacme built and
# tools/ttydrive driving it, the interactive tmux TUI becomes GRADEABLE
# (smoke-pacme-ui.sh).
#
# pacme is a set of C "pokelets" (plet-repl/-out/-in/-poke-disas) collated by
# tmux; they talk to the `poked` daemon over a Unix socket. It does NOT link
# libpoke, so there is no GPLv3 linkage into anything — it runs beside poked on
# the host, which is the lab's standing framing (design note §1). Its only
# bootstrap dependency is gnulib.
#
# What this does, all under $HERE (gitignored), nothing installed system-wide:
#   1. clone pacme (sourceware) + gnulib (savannah), shallow, into .pacme-build/
#   2. ./bootstrap (gnulib import + autoreconf) — with a makeinfo STUB, see below
#   3. ./configure --prefix=$PACME_PREFIX ; make ; make install
# Idempotent: if $PACME_PREFIX/bin/pacme already exists it prints the prefix and
# stops. Prints the install prefix on the last line (smoke-pacme-ui.sh reads it).
#
# THE makeinfo STUB (measured 2026-10-02): gnulib's bootstrap has an inherited
# `buildreq` entry `makeinfo 6.0`, but pacme itself has NO .texi targets — it is
# never invoked by `make`. Rather than demand `sudo apt-get install texinfo` for
# a tool the build does not use, we satisfy the version gate with a stub on PATH
# (bootstrap honors $MAKEINFO). If you prefer the real thing, install texinfo and
# unset the stub — the build is identical.
#
# Deps (SKIP 77 by name if missing; install recipes printed): git, a C compiler,
# autoconf, automake, make, pkg-config, tmux, poked (GNU poke), readline headers.
# Capstone is OPTIONAL — configure only warns, and plet-cpu-disasm (unused by the
# lab) is simply not built.
#
# Exit: 0 built (prefix on stdout) / 77 a prereq is missing / 1 build failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${PACME_BUILD_DIR:-$HERE/.pacme-build}"
PREFIX="${PACME_PREFIX:-$HERE/.pacme}"
PACME_URL="https://sourceware.org/git/pacme.git"
GNULIB_URL="https://git.savannah.gnu.org/git/gnulib.git"
GNULIB_MIRROR="https://github.com/coreutils/gnulib.git"   # fallback if savannah hiccups
# the pacme commit this lab validated Spike 3-full against (master, 2026-10-02)
PACME_PIN="83b0f2383172c0a56a9cc79208985823282edbad"

note() { printf '  - %s\n' "$*" >&2; }
skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# already built?
if [[ -x "$PREFIX/bin/pacme" ]]; then
    note "pacme already built at $PREFIX (remove it to rebuild)"
    echo "$PREFIX"; exit 0
fi

# ── prerequisites (name what is missing, with the recipe) ───────────────────────
miss=0
need() { command -v "$1" >/dev/null || { printf '  MISSING %-10s %s\n' "$1" "$2" >&2; miss=1; }; }
need git        "install git"
need "${CC:-cc}" "install gcc"
need autoconf   "sudo apt-get install -y autoconf"
need automake   "sudo apt-get install -y automake"
need make       "sudo apt-get install -y make"
need pkg-config "sudo apt-get install -y pkg-config"
need tmux       "sudo apt-get install -y tmux   (pacme's screen manager)"
need poked      "sudo apt-get install -y poke   (the poke daemon the pokelets talk to)"
[[ -f /usr/include/readline/readline.h ]] || pkg-config --exists readline 2>/dev/null \
    || { printf '  MISSING %-10s %s\n' readline "sudo apt-get install -y libreadline-dev" >&2; miss=1; }
(( miss == 0 )) || skip "missing build prerequisites (see above)"
command -v makeinfo >/dev/null || note "makeinfo absent — using a stub (pacme has no .texi targets; it is never run by make)"

mkdir -p "$BUILD" || fail "cannot create $BUILD"

# ── 1. sources (shallow clones; source fetch, not a prebuilt-toolchain fetch) ───
# A clone of a big repo over the network can hiccup; retry, and for gnulib fall
# back to a mirror — a transient savannah timeout should not fail the build.
PSRC="$BUILD/pacme"; GSRC="$BUILD/gnulib"
try_clone() {  # DEST then one-or-more URLs; tries each URL up to 3x
    local dest="$1"; shift
    local url i
    for url in "$@"; do
        for i in 1 2 3; do
            rm -rf "$dest"
            if git clone --quiet --depth 1 "$url" "$dest" 2>/dev/null; then return 0; fi
            note "clone of $url failed (attempt $i) — retrying"; sleep 3
        done
    done
    return 1
}
if [[ ! -d "$PSRC/.git" ]]; then
    note "cloning pacme …"
    try_clone "$PSRC" "$PACME_URL" || fail "git clone pacme failed (offline? $PACME_URL)"
fi
got="$(git -C "$PSRC" rev-parse HEAD 2>/dev/null)"
if [[ "$got" == "$PACME_PIN" ]]; then note "pacme at ${got:0:12} (== validated pin)"
else note "pacme at ${got:0:12} (NOTE: differs from validated pin ${PACME_PIN:0:12})"; fi
if [[ ! -x "$GSRC/gnulib-tool" ]]; then
    note "cloning gnulib (shallow; savannah, then mirror) …"
    try_clone "$GSRC" "$GNULIB_URL" "$GNULIB_MIRROR" \
        || fail "git clone gnulib failed from both savannah and the mirror (offline?)"
fi
[[ -x "$GSRC/gnulib-tool" ]] || fail "gnulib-tool not found in $GSRC"

# ── 2. bootstrap (gnulib import + autoreconf), with the makeinfo stub ───────────
if [[ ! -x "$BUILD/stubbin/makeinfo" ]]; then
    mkdir -p "$BUILD/stubbin"
    cat > "$BUILD/stubbin/makeinfo" <<'STUB'
#!/bin/sh
# stub: pacme has no .texi targets; this only satisfies gnulib bootstrap's
# inherited `makeinfo 6.0` buildreq gate. It is never invoked by `make`.
case "$1" in --version) echo "makeinfo (GNU texinfo) 7.1" ;; *) exit 0 ;; esac
STUB
    chmod +x "$BUILD/stubbin/makeinfo"
fi
if [[ ! -x "$PSRC/configure" ]]; then
    note "bootstrap (gnulib import + autoreconf) …"
    ( cd "$PSRC" && GNULIB_SRCDIR="$GSRC" MAKEINFO="$BUILD/stubbin/makeinfo" \
        PATH="$BUILD/stubbin:$PATH" ./bootstrap --copy ) >"$BUILD/bootstrap.log" 2>&1 \
        || { tail -20 "$BUILD/bootstrap.log" >&2; fail "bootstrap failed — see $BUILD/bootstrap.log"; }
fi
[[ -x "$PSRC/configure" ]] || fail "bootstrap produced no configure script"

# ── 3. configure + make + install ──────────────────────────────────────────────
note "configure --prefix=$PREFIX …"
( cd "$PSRC" && ./configure --prefix="$PREFIX" ) >"$BUILD/configure.log" 2>&1 \
    || { tail -20 "$BUILD/configure.log" >&2; fail "configure failed — see $BUILD/configure.log"; }
note "make …"
( cd "$PSRC" && make -j"$(nproc 2>/dev/null || echo 2)" ) >"$BUILD/make.log" 2>&1 \
    || { tail -25 "$BUILD/make.log" >&2; fail "make failed — see $BUILD/make.log"; }
( cd "$PSRC" && make install ) >"$BUILD/install.log" 2>&1 \
    || { tail -15 "$BUILD/install.log" >&2; fail "make install failed — see $BUILD/install.log"; }

[[ -x "$PREFIX/bin/pacme" && -x "$PREFIX/bin/plet-repl" && -x "$PREFIX/bin/plet-out" ]] \
    || fail "install did not produce pacme + plet-repl + plet-out in $PREFIX/bin"
note "built: $(cd "$PREFIX/bin" && echo pacme plet-* )"
echo "$PREFIX"
