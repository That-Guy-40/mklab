#!/usr/bin/env bash
# Regression (Review F4): published ports default to a loopback bind so a
# throwaway lab isn't exposed on every host interface (the lab LAN).  An
# explicit bind IP is preserved (opt-in to a wider bind); LAB_PUBLISH_HOST
# overrides the default.  Unit-tests the pure _pub_host transformation.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
source "$LAB_DOCKER"

_done=""
trap '[[ -n "$_done" ]] || printf "FAIL: test exited early (rc=%s)\n" "$?" >&2' EXIT

eq() { [[ "$2" == "$3" ]] || fail "$1: got '$2', want '$3'"; note "$1"; }

# Bare specs get the loopback default.
eq "host:container -> loopback"  "$(_pub_host '8080:80')"      '127.0.0.1:8080:80'
eq "container-only -> loopback"  "$(_pub_host '80')"           '127.0.0.1::80'
eq "proto preserved"             "$(_pub_host '53:53/udp')"    '127.0.0.1:53:53/udp'

# An explicit bind IP is the opt-in to a wider bind — left untouched.
eq "explicit 0.0.0.0 preserved"  "$(_pub_host '0.0.0.0:8080:80')" '0.0.0.0:8080:80'
eq "explicit LAN IP preserved"   "$(_pub_host '1.2.3.4:8080:80')" '1.2.3.4:8080:80'
eq "ipv6 bind preserved"         "$(_pub_host '[::1]:8080:80')"   '[::1]:8080:80'

# LAB_PUBLISH_HOST overrides the default...
eq "override to all-interfaces"  "$(LAB_PUBLISH_HOST=0.0.0.0 _pub_host '8080:80')" '0.0.0.0:8080:80'
# ...and an empty override restores the engine's own default (no rewrite).
eq "empty override = no rewrite" "$(LAB_PUBLISH_HOST= _pub_host '8080:80')"        '8080:80'

_done=1
pass "published ports default to loopback; explicit binds + LAB_PUBLISH_HOST honored"
