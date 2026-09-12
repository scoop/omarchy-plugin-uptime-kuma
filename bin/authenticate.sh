#!/usr/bin/bash
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
# same way. Every binary is named by absolute path, and the interpreter is
# /usr/bin/bash rather than /usr/bin/env bash, so that PATH does not get to
# choose which jq, curl or secret-tool handles the credential. See the note at
# the top of login.sh, and test/scripts.test.js.

set -uo pipefail

# ${#s} counts characters unless the locale says otherwise, and the config cap
# below is in bytes. See login.sh.
export LC_ALL=C

# shell.json is a few kilobytes in practice; this is the point past which it is
# refused rather than read.
MAX_CONFIG=262144

die() {
    echo "$1" >&2
    exit 1
}

# `dirname` is an external program and would be resolved through PATH like any
# other; the shell can take the directory apart on its own. `./` makes the
# expansion well defined when this was invoked as a bare name.
src="${BASH_SOURCE[0]}"
[[ "$src" == */* ]] || src="./$src"
here="$(cd -- "${src%/*}" && pwd -P)" || die "Cannot find the directory this script is in"

config="$HOME/.config/omarchy/shell.json"

# Read through the bounded helper rather than handing the pathname to jq. `jq
# file` follows a symlink, blocks forever on a FIFO, and reads the whole file
# before any size check could run; testing the name with -f first and opening it
# afterwards is two resolutions of a name another process running as this user
# can change in between. read-bounded.sh does one O_NOFOLLOW|O_NONBLOCK open and
# reads MAX + 1 bytes through that same descriptor, so an oversized file is
# detected here rather than truncated into something that still parses.
# Through supervise.sh like every other helper: the deadline is what stops a
# read of a file on a mount that has gone away, and the process group is what
# makes sure nothing is left running when it does.
config_json="$("$here/supervise.sh" 10 "$here/read-bounded.sh" "$config" "$MAX_CONFIG")" ||
    die "Cannot read shell.json at $config — it must be a plain file that exists, not a symlink or a pipe."
((${#config_json} <= MAX_CONFIG)) ||
    die "shell.json at $config is larger than $MAX_CONFIG bytes; refusing to parse it."
[[ -n "$config_json" ]] || die "shell.json at $config is empty"

entry="$(printf '%s' "$config_json" |
    /usr/bin/jq -c '[.bar.layout[]?[]? | select(.id == "scoop.uptime-kuma")] | first // {}')" ||
    die "Could not parse shell.json at $config"
url="$(printf '%s' "$entry" | /usr/bin/jq -r '.baseUrl // ""')"
username="$(printf '%s' "$entry" | /usr/bin/jq -r '.username // ""')"
allow_plaintext="$(printf '%s' "$entry" |
    /usr/bin/jq -r 'if .allowPlaintext == true then "yes" else "no" end')"

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
    /usr/bin/jq -Rn '[inputs] | {
        url: .[0], username: .[1], password: .[2], totp: .[3],
        allowPlaintext: (.[4] == "yes")
    }' | "$here/supervise.sh" 120 "$here/login.sh")"
password=""

if [[ "$(printf '%s' "$result" | /usr/bin/jq -r '.totpRequired // false')" == "true" ]]; then
    die "That account has two-factor enabled — run this again and enter a code."
fi

if [[ "$(printf '%s' "$result" | /usr/bin/jq -r '.ok // false')" != "true" ]]; then
    die "$(printf '%s' "$result" | /usr/bin/jq -r '.error // "Login failed"')"
fi

printf '%s' "$result" | /usr/bin/jq -r '.token' |
    /usr/bin/secret-tool store --label="Uptime Kuma session (scoop.uptime-kuma)" \
        service scoop.uptime-kuma account "$username" ||
    die "Could not write to the login keyring"

echo "Authenticated. The plugin will connect on its own."
