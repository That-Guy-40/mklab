# /etc/profile.d/00-cowsay-login.sh — greet interactive logins with a cow.
# Installed by Containerfile.cowsay.  Only fires for interactive shells (so scp,
# sftp, and scripts stay quiet) and only if cowsay is actually present.
case "$-" in
    *i*) command -v cowsay >/dev/null 2>&1 && \
         cowsay "Minimal bootc base, now with 100% more moo.  (image mode for RHEL)" ;;
esac
