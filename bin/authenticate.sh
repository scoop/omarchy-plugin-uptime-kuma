#!/usr/bin/env bash
#
# Authenticate once, interactively.
#
# Reads the URL and username from shell.json, asks for the password, exchanges
# it for a session token and puts that token in the login keyring.
#
# The password is not echoed and not stored. Nor is it, or the two-factor code,
# or the token that comes back, ever a command-line argument: /proc/<pid>/cmdline
# is readable by every process running as this user. The request object is built
# by jq from values fed to it on stdin, and the token reaches secret-tool the
# same way. See the note at the top of login.sh, and test/scripts.test.js.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="$HOME/.config/omarchy/shell.json"

die() {
    echo "$1" >&2
    exit 1
}

[[ -f "$config" ]] || die "No shell.json at $config"

entry="$(jq -c '[.bar.layout[]?[]? | select(.id == "scoop.uptime-kuma")] | first // {}' "$config")"
url="$(printf '%s' "$entry" | jq -r '.baseUrl // ""')"
username="$(printf '%s' "$entry" | jq -r '.username // ""')"
allow_plaintext="$(printf '%s' "$entry" | jq -r 'if .allowPlaintext == true then "yes" else "no" end')"

[[ -n "$url" && -n "$username" ]] || die "Set baseUrl and username on the scoop.uptime-kuma entry in $config first."

# Checked here as well as in login.sh, and before the prompt rather than after:
# there is nothing to gain by taking a password this is going to refuse to send.
# The consent lives on the shell.json entry because the service needs it too —
# a login that worked from the terminal but left the panel unable to poll would
# be a worse outcome than this refusal.
host="${url#*://}"
host="${host%%/*}"
host="${host##*@}"
case "$host" in
    \[*\]*) host="${host%%\]*}]" ;;
    *) host="${host%%:*}" ;;
esac
LOOPBACK='^(localhost|127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|\[::1\]|\[::ffff:127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\])$'
if [[ "$url" == http://* ]] && ! [[ "${host,,}" =~ $LOOPBACK ]] && [[ "$allow_plaintext" != "yes" ]]; then
    die "$url is not encrypted, so a password sent to it could be read in transit. Tick the box in the panel's setup form, or add \"allowPlaintext\": true to the scoop.uptime-kuma entry in $config, if that is what you want."
fi

echo "Uptime Kuma at $url as $username"
read -rsp "Password: " password
echo

read -rp "Two-factor code (blank if you have none): " totp

# printf is a shell builtin, so these values are written down a pipe by this
# process rather than handed to a new one as arguments. `read -r` stops at a
# newline, so no field here can contain one and line-delimited input is exact.
result="$(printf '%s\n%s\n%s\n%s\n%s\n' "$url" "$username" "$password" "$totp" "$allow_plaintext" |
    jq -Rn '[inputs] | {
        url: .[0], username: .[1], password: .[2], totp: .[3],
        allowPlaintext: (.[4] == "yes")
    }' | "$here/login.sh")"
password=""

if [[ "$(printf '%s' "$result" | jq -r '.totpRequired // false')" == "true" ]]; then
    die "That account has two-factor enabled — run this again and enter a code."
fi

if [[ "$(printf '%s' "$result" | jq -r '.ok // false')" != "true" ]]; then
    die "$(printf '%s' "$result" | jq -r '.error // "Login failed"')"
fi

printf '%s' "$result" | jq -r '.token' |
    secret-tool store --label="Uptime Kuma session (scoop.uptime-kuma)" \
        service scoop.uptime-kuma account "$username" ||
    die "Could not write to the login keyring"

echo "Authenticated. The plugin will connect on its own."
