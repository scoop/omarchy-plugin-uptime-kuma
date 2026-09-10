#!/usr/bin/env bash
#
# Exchange a password for a session token, once.
#
# Reads {"url","username","password","totp"} as JSON on stdin and writes one
# JSON object on stdout: {"ok":true,"token":"..."} on success,
# {"ok":false,"totpRequired":true} when the account has two-factor enabled and
# no code was supplied, or {"ok":false,"error":"..."} otherwise.
#
# The password never appears in argv, so it cannot be read out of the process
# table; every request body reaches curl over a pipe.

set -uo pipefail

fail() {
    jq -cn --arg e "$1" '{ok: false, error: $e}'
    exit 0
}

# Uptime Kuma answers with i18n keys, not sentences.
human() {
    case "$1" in
        authIncorrectCreds) echo "Incorrect username or password" ;;
        authInvalidToken) echo "That two-factor code was not accepted" ;;
        authUserInactiveOrDeleted) echo "That account is inactive or deleted" ;;
        "") echo "Login refused" ;;
        *) echo "$1" ;;
    esac
}

input="$(cat)"
url="$(jq -r '.url // ""' <<<"$input")"
username="$(jq -r '.username // ""' <<<"$input")"
password="$(jq -r '.password // ""' <<<"$input")"
totp="$(jq -r '.totp // ""' <<<"$input")"

[[ -n "$url" ]] || fail "No Uptime Kuma URL configured"
[[ "$url" =~ ^https?://[^[:space:]/]+ ]] || fail "URL must be http:// or https://"
[[ -n "$username" ]] || fail "No username configured"

url="${url%/}"
jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT

curl_common=(curl -q -sS --proto '=https,http' --proto-redir '=https,http' --max-time 20
    --max-filesize 20000000 -b "$jar" -c "$jar")

endpoint="$url/socket.io/?EIO=4&transport=polling"

handshake="$("${curl_common[@]}" "$endpoint" 2>&1)" ||
    fail "Cannot reach $url"
[[ "${handshake:0:1}" == "0" ]] || fail "Not an Uptime Kuma socket endpoint"
sid="$(jq -r '.sid // ""' <<<"${handshake:1}")"
[[ -n "$sid" ]] || fail "Handshake returned no session id"

session="$endpoint&sid=$sid"

printf '40' | "${curl_common[@]}" -X POST --data-binary @- "$session" >/dev/null ||
    fail "Could not open the socket namespace"

packet="$(jq -cn --arg u "$username" --arg p "$password" --arg t "$totp" \
    '["login", {username: $u, password: $p, token: $t}]')"
printf '420%s' "$packet" | "${curl_common[@]}" -X POST --data-binary @- "$session" >/dev/null ||
    fail "Could not send credentials"

# The acknowledgement may not be in the first response; the server sends its
# own greeting packets first.
for _ in 1 2 3 4 5 6; do
    body="$("${curl_common[@]}" "$session" 2>/dev/null)" || fail "Connection lost during login"
    while IFS= read -r frame; do
        [[ "$frame" == 2 ]] && printf '3' |
            "${curl_common[@]}" -X POST --data-binary @- "$session" >/dev/null
        [[ "$frame" == 43* ]] || continue
        ack="${frame#43}"
        ack="${ack#"${ack%%[![:digit:]]*}"}"
        result="$(jq -c '.[0] // {}' <<<"$ack" 2>/dev/null)" || continue
        if [[ "$(jq -r '.ok // false' <<<"$result")" == "true" ]]; then
            jq -cn --arg t "$(jq -r '.token // ""' <<<"$result")" '{ok: true, token: $t}'
            exit 0
        fi
        if [[ "$(jq -r '.tokenRequired // false' <<<"$result")" == "true" ]]; then
            jq -cn '{ok: false, totpRequired: true}'
            exit 0
        fi
        fail "$(human "$(jq -r '.msg // "" ' <<<"$result")")"
    done < <(tr '\036' '\n' <<<"$body")
done

fail "Uptime Kuma never acknowledged the login"
