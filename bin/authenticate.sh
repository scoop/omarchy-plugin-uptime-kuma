#!/usr/bin/env bash
#
# Authenticate once, interactively.
#
# Reads the URL and username from shell.json, asks for the password, exchanges
# it for a session token and puts that token in the login keyring. The password
# is not echoed, not stored, and not passed as an argument to anything.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="$HOME/.config/omarchy/shell.json"

die() {
    echo "$1" >&2
    exit 1
}

[[ -f "$config" ]] || die "No shell.json at $config"

entry="$(jq -c '[.bar.layout[]?[]? | select(.id == "scoop.uptime-kuma")] | first // {}' "$config")"
url="$(jq -r '.baseUrl // ""' <<<"$entry")"
username="$(jq -r '.username // ""' <<<"$entry")"

[[ -n "$url" && -n "$username" ]] || die "Set baseUrl and username on the scoop.uptime-kuma entry in $config first."

echo "Uptime Kuma at $url as $username"
read -rsp "Password: " password
echo

read -rp "Two-factor code (blank if you have none): " totp

result="$(jq -cn --arg url "$url" --arg u "$username" --arg p "$password" --arg t "$totp" \
    '{url: $url, username: $u, password: $p, totp: $t}' | "$here/login.sh")"
password=""

if [[ "$(jq -r '.totpRequired // false' <<<"$result")" == "true" ]]; then
    die "That account has two-factor enabled — run this again and enter a code."
fi

if [[ "$(jq -r '.ok // false' <<<"$result")" != "true" ]]; then
    die "$(jq -r '.error // "Login failed"' <<<"$result")"
fi

jq -r '.token' <<<"$result" |
    secret-tool store --label="Uptime Kuma session (scoop.uptime-kuma)" \
        service scoop.uptime-kuma account "$username" ||
    die "Could not write to the login keyring"

echo "Authenticated. The plugin will connect on its own."
