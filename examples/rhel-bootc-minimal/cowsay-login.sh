# shellcheck shell=sh  # A /etc/profile.d snippet: SOURCED by the login shell, so it has no
# shebang. Without this directive shellcheck reads the first comment line as a malformed one
# (SC1008/SC1113/SC2096) -- three errors about a shebang that was never meant to be there.
# /etc/profile.d/00-cowsay-login.sh — greet interactive logins with a cow.
# Installed by Containerfile.cowsay.  Only fires for interactive shells (so scp,
# sftp, and scripts stay quiet) and only if cowsay is actually present.
case "$-" in
    *i*) command -v cowsay >/dev/null 2>&1 && \
         cowsay "Minimal bootc base, now with 100% more moo.  (image mode for RHEL)" ;;
esac
