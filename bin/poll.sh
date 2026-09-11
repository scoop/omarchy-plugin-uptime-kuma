#!/usr/bin/env bash
#
# Hold one Engine.IO polling session open and stream what it says.
#
# Reads {"url","token","allowPlaintext"} as JSON on stdin, then writes one line
# per HTTP response body to stdout — each still framed with 0x1e, for
# src/engine.js to decode. Diagnostics go to stderr; a lost connection exits
# non-zero so the caller can back off and start a new session.
#
# Engine.IO payloads never contain a raw newline (JSON escapes them), which is
# what makes one-body-per-line safe.
#
# The session token is worth what the password is worth, so it is handled the
# same way: never an argument, never an environment variable, only ever a pipe
# between jq and curl. See the note at the top of login.sh.

set -uo pipefail

die() {
    echo "$1" >&2
    exit 1
}

# Identical to LOOPBACK in login.sh and src/setup.js. All three must agree.
LOOPBACK='^(localhost|127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|\[::1\]|\[::ffff:127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\])$'

host_of() {
    local authority="${1#*://}"
    authority="${authority%%/*}"
    authority="${authority##*@}"
    case "$authority" in
        \[*\]*) printf '%s' "${authority%%\]*}]" ;;
        *) printf '%s' "${authority%%:*}" ;;
    esac
}

input="$(head -n 1)"
url="$(printf '%s' "$input" | jq -r '.url // ""')"
allow_plaintext="$(printf '%s' "$input" | jq -r 'if .allowPlaintext == true then "yes" else "no" end')"

[[ -n "$url" ]] || die "No Uptime Kuma URL configured"
[[ "$url" =~ ^https?://[^[:space:]/]+ ]] || die "URL must be http:// or https://"

# The token itself is checked without ever becoming a shell word: jq answers
# the question rather than handing over the value.
[[ "$(printf '%s' "$input" | jq -r 'if (.token // "") == "" then "no" else "yes" end')" == "yes" ]] ||
    die "No session token"

url="${url%/}"

authority="${url#*://}"
authority="${authority%%/*}"
case "$authority" in
    *@*) die "The address must not carry a username or password" ;;
esac

host="$(host_of "$url")"
if [[ "$url" == https://* ]]; then
    protos="=https"
elif [[ "${host,,}" =~ $LOOPBACK ]]; then
    protos="=https,http"
elif [[ "$allow_plaintext" == "yes" ]]; then
    protos="=https,http"
else
    die "That address is not encrypted, so a session token sent to it could be read in transit"
fi

jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT

# --max-time must outlast a long poll: the server holds the request open for
# pingInterval (25s by default) before answering with a ping.
curl_common=(curl -q -sS --proto "$protos" --proto-redir "$protos" --max-time 60
    --max-filesize 4000000 -b "$jar" -c "$jar")

endpoint="$url/socket.io/?EIO=4&transport=polling"

handshake="$("${curl_common[@]}" "$endpoint")" || die "Cannot reach $url"
[[ "${handshake:0:1}" == "0" ]] || die "Not an Uptime Kuma socket endpoint"
sid="$(printf '%s' "${handshake:1}" | jq -r '.sid // ""')"
[[ -n "$sid" ]] || die "Handshake returned no session id"

session="$endpoint&sid=$sid"

post() {
    printf '%s' "$1" | "${curl_common[@]}" -X POST --data-binary @- "$session" >/dev/null
}

post '40' || die "Could not open the socket namespace"

# loginByToken performs no second-factor check, so every reconnect after the
# first is unattended even on an account with two-factor enabled.
#
# The packet is built by jq from stdin and piped straight to curl, so the token
# is a command-line argument to nothing.
printf '%s' "$input" |
    jq -j '"420", (["loginByToken", .token] | tojson)' |
    "${curl_common[@]}" -X POST --data-binary @- "$session" >/dev/null ||
    die "Could not present the session token"

# A refused token does not close the socket: the server simply never sends a
# snapshot, so an unchecked session would poll forever looking connected but
# empty. Read the acknowledgement and say so, with a distinct exit code the
# caller can turn into "ask for credentials again" rather than "retry later".
for _ in 1 2 3 4 5 6; do
    ack_body="$("${curl_common[@]}" "$session")" || die "Connection lost during sign-in"
    ack_seen=""
    while IFS= read -r frame; do
        [[ "$frame" == 2 ]] && post '3'
        [[ "$frame" == 43* ]] || continue
        ack_seen="yes"
        payload="${frame#43}"
        payload="${payload#"${payload%%[![:digit:]]*}"}"
        if [[ "$(printf '%s' "$payload" | jq -r '.[0].ok // false' 2>/dev/null)" != "true" ]]; then
            echo "Session token refused" >&2
            exit 2
        fi
    done < <(printf '%s\n' "$ack_body" | tr '\036' '\n')
    # The greeting arrives in the same batch as the acknowledgement; anything
    # already streamed must still reach the caller.
    [[ -n "$ack_body" ]] && printf '%s\n' "$ack_body"
    [[ -n "$ack_seen" ]] && break
done

while :; do
    body="$("${curl_common[@]}" "$session")" || die "Connection lost"

    # An empty body means the poll timed out with nothing to say; that is normal.
    [[ -n "$body" ]] || continue

    printf '%s\n' "$body"

    # Answer any ping in this batch, or the server drops the session.
    while IFS= read -r frame; do
        [[ "$frame" == 2 ]] && post '3'
    done < <(printf '%s\n' "$body" | tr '\036' '\n')
done
