#!/usr/bin/env bash
#
# Hold one Engine.IO polling session open and stream what it says.
#
# Reads {"url","token"} as JSON on stdin, then writes one line per HTTP
# response body to stdout — each still framed with 0x1e, for src/engine.js to
# decode. Diagnostics go to stderr; a lost connection exits non-zero so the
# caller can back off and start a new session.
#
# Engine.IO payloads never contain a raw newline (JSON escapes them), which is
# what makes one-body-per-line safe.

set -uo pipefail

die() {
    echo "$1" >&2
    exit 1
}

input="$(head -n 1)"
url="$(jq -r '.url // ""' <<<"$input")"
token="$(jq -r '.token // ""' <<<"$input")"

[[ -n "$url" ]] || die "No Uptime Kuma URL configured"
[[ "$url" =~ ^https?://[^[:space:]/]+ ]] || die "URL must be http:// or https://"
[[ -n "$token" ]] || die "No session token"

url="${url%/}"
jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT

# --max-time must outlast a long poll: the server holds the request open for
# pingInterval (25s by default) before answering with a ping.
curl_common=(curl -q -sS --proto '=https,http' --proto-redir '=https,http' --max-time 60
    --max-filesize 20000000 -b "$jar" -c "$jar")

endpoint="$url/socket.io/?EIO=4&transport=polling"

handshake="$("${curl_common[@]}" "$endpoint")" || die "Cannot reach $url"
[[ "${handshake:0:1}" == "0" ]] || die "Not an Uptime Kuma socket endpoint"
sid="$(jq -r '.sid // ""' <<<"${handshake:1}")"
[[ -n "$sid" ]] || die "Handshake returned no session id"

session="$endpoint&sid=$sid"

post() {
    printf '%s' "$1" | "${curl_common[@]}" -X POST --data-binary @- "$session" >/dev/null
}

post '40' || die "Could not open the socket namespace"

# loginByToken performs no second-factor check, so every reconnect after the
# first is unattended even on an account with two-factor enabled.
packet="$(jq -cn --arg t "$token" '["loginByToken", $t]')"
post "420$packet" || die "Could not present the session token"

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
        if [[ "$(jq -r '.[0].ok // false' <<<"$payload" 2>/dev/null)" != "true" ]]; then
            echo "Session token refused" >&2
            exit 2
        fi
    done < <(tr '\036' '\n' <<<"$ack_body")
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
    done < <(tr '\036' '\n' <<<"$body")
done
