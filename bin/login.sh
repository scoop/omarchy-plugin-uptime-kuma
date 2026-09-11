#!/usr/bin/env bash
#
# Exchange a password for a session token, once.
#
# Reads {"url","username","password","totp","allowPlaintext"} as JSON on stdin
# and writes one JSON object on stdout: {"ok":true,"token":"..."} on success,
# {"ok":false,"totpRequired":true} when the account has two-factor enabled and
# no code was supplied, or {"ok":false,"error":"..."} otherwise.
#
# No credential is ever a command-line argument or an environment variable.
# /proc/<pid>/cmdline and /proc/<pid>/environ are readable by every process
# running as this user, so a secret that reaches either is a secret anyone on
# the machine can read for as long as the process lives. Everything carrying
# one moves over a pipe instead: jq reads the request object on stdin and
# writes the packet, curl reads the packet on stdin. `test/scripts.test.js`
# runs this script against a stub server with a jq that records its own argv,
# and fails if a secret shows up in it.

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

# The addresses http:// can be trusted with, because nothing is transmitted
# anywhere. Kept identical to LOOPBACK in src/setup.js: the form and the helper
# must agree on what counts, or one of them is decoration.
LOOPBACK='^(localhost|127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|\[::1\]|\[::ffff:127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\])$'

# The host part of a URL, without userinfo or port.
host_of() {
    local authority="${1#*://}"
    authority="${authority%%/*}"
    authority="${authority##*@}"
    case "$authority" in
        \[*\]*) printf '%s' "${authority%%\]*}]" ;;
        *) printf '%s' "${authority%%:*}" ;;
    esac
}

input="$(cat)"

# $input carries the password, so it is piped rather than expanded into an
# argument. The filters below name fields; they never name values.
url="$(printf '%s' "$input" | jq -r '.url // ""')"
username="$(printf '%s' "$input" | jq -r '.username // ""')"
allow_plaintext="$(printf '%s' "$input" | jq -r 'if .allowPlaintext == true then "yes" else "no" end')"

[[ -n "$url" ]] || fail "No Uptime Kuma URL configured"
[[ "$url" =~ ^https?://[^[:space:]/]+ ]] || fail "URL must be http:// or https://"
[[ -n "$username" ]] || fail "No username configured"

url="${url%/}"

authority="${url#*://}"
authority="${authority%%/*}"
case "$authority" in
    *@*) fail "The address must not carry a username or password" ;;
esac

# A password and a session token are the whole of this account. They go over
# TLS, or to this machine, or only where the person has said in as many words
# that they should. `protos` then holds curl to that decision as well, so a
# redirect cannot walk the request down to http on its own.
host="$(host_of "$url")"
if [[ "$url" == https://* ]]; then
    protos="=https"
elif [[ "${host,,}" =~ $LOOPBACK ]]; then
    protos="=https,http"
elif [[ "$allow_plaintext" == "yes" ]]; then
    protos="=https,http"
else
    fail "That address is not encrypted, so a password sent to it could be read in transit"
fi

jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT

curl_common=(curl -q -sS --proto "$protos" --proto-redir "$protos" --max-time 20
    --max-filesize 4000000 -b "$jar" -c "$jar")

endpoint="$url/socket.io/?EIO=4&transport=polling"

handshake="$("${curl_common[@]}" "$endpoint" 2>&1)" ||
    fail "Cannot reach $url"
[[ "${handshake:0:1}" == "0" ]] || fail "Not an Uptime Kuma socket endpoint"
sid="$(printf '%s' "${handshake:1}" | jq -r '.sid // ""')"
[[ -n "$sid" ]] || fail "Handshake returned no session id"

session="$endpoint&sid=$sid"

printf '40' | "${curl_common[@]}" -X POST --data-binary @- "$session" >/dev/null ||
    fail "Could not open the socket namespace"

# The one place the password is used, and it moves from stdin to stdin: jq
# builds the packet from the request object without the password ever being a
# shell word, and hands it straight to curl.
printf '%s' "$input" |
    jq -j '"420", ([
        "login",
        {username: .username, password: (.password // ""), token: (.totp // "")}
    ] | tojson)' |
    "${curl_common[@]}" -X POST --data-binary @- "$session" >/dev/null ||
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
        result="$(printf '%s' "$ack" | jq -c '.[0] // {}' 2>/dev/null)" || continue
        if [[ "$(printf '%s' "$result" | jq -r '.ok // false')" == "true" ]]; then
            # $result holds the token now, so it is piped like everything else.
            printf '%s' "$result" | jq -c '{ok: true, token: (.token // "")}'
            exit 0
        fi
        if [[ "$(printf '%s' "$result" | jq -r '.tokenRequired // false')" == "true" ]]; then
            jq -cn '{ok: false, totpRequired: true}'
            exit 0
        fi
        fail "$(human "$(printf '%s' "$result" | jq -r '.msg // ""')")"
    done < <(printf '%s\n' "$body" | tr '\036' '\n')
done

fail "Uptime Kuma never acknowledged the login"
