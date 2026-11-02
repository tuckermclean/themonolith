# /etc/profile.d/40-advisory.sh (renamed from monolith-advisory.sh in
# Task 6, hint hygiene — see the ordering contract in the monolith-base
# ebuild's src_install, profile.d section: STATUS lines first [20-persist,
# 30-clock], then ACTIONABLE hints [40-advisory, 50-dropbear]. Advisory
# prints before dropbear because a revoked-build security warning outranks
# a "you could enable sshd" convenience hint.)
#
# ACTIONABLE-group /run-flag policy: only fires when
# /run/monolith-advisory exists — most boots print nothing here.
#
# Displays a security warning at login if this build of The Monolith
# has been revoked (new CVEs discovered after the ISO was released).
#
# The advisory file is written by /usr/sbin/monolith-advisory-check
# at boot time (after networking comes up).
#
# This file is sourced by /etc/profile — do NOT use set -e, subshells,
# or command substitutions that could abort profile loading on error.

_monolith_adv="${MONOLITH_ADVISORY_FILE:-/run/monolith-advisory}"
_monolith_rel="${MONOLITH_RELEASE_FILE:-/etc/monolith-release}"
if [ -f "$_monolith_adv" ]; then
    _monolith_ver=
    [ -f "$_monolith_rel" ] && read -r _monolith_ver < "$_monolith_rel"
    printf '\n'
    printf '\033[1;33m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n'
    printf '\033[1;33m!!          SECURITY ADVISORY — ACTION REQUIRED    !!\033[0m\n'
    printf '\033[1;33m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n'
    printf '\033[0;33m\n'
    printf 'This build of The Monolith %s has been marked REVOKED.\n' "$_monolith_ver"
    printf 'One or more CVEs were discovered after this ISO was released.\n'
    printf 'Please obtain a newer build as soon as possible.\n'
    printf '\n'
    # Print CVE IDs if present in the advisory JSON (simple grep extraction)
    if grep -q '"advisories"' "$_monolith_adv" 2>/dev/null; then
        printf 'Affected CVEs: '
        # Extract CVE IDs — grep for CVE-YYYY-NNNNN pattern, one per line
        grep -o 'CVE-[0-9][0-9][0-9][0-9]-[0-9]*' "$_monolith_adv" 2>/dev/null \
            | tr '\n' ' '
        printf '\n'
    fi
    if grep -q '"details_url"' "$_monolith_adv" 2>/dev/null; then
        printf 'Details: '
        # Extract URL value — relies on simple JSON key ordering
        grep -o '"details_url"[^"]*"[^"]*"' "$_monolith_adv" 2>/dev/null \
            | grep -o '"[^"]*"$' \
            | tr -cd 'A-Za-z0-9:/#._?=&%~+-'
        printf '\n'
    fi
    printf '\033[0m\n'
fi
