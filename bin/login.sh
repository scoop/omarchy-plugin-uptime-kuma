#!/usr/bin/bash
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
#
# Every binary is named by its absolute path, and the interpreter is
# /usr/bin/bash rather than /usr/bin/env bash, because PATH is inherited from
# whatever started the shell: a `curl` planted earlier in it is handed the
# password, and a `jq` planted earlier in it is handed the password on stdin.
# That needs no privilege beyond running as this user, which is exactly the
# boundary this script exists on.

set -uo pipefail

# ${#s} counts characters, and a byte cap measured in characters is not a byte
# cap: a UTF-8 body can be well over the limit while its character count is
# still under it. C is the locale where the two are the same number.
export LC_ALL=C

# The ceiling on one HTTP response body, and on the object this script prints.
# Both are applied by the reader rather than trusted to curl; see fetch() for
# why --max-filesize is not the cap.
# The snapshot Uptime Kuma sends at login carries every monitor's heartbeat
# history, so it scales with the instance: an 86-monitor instance was measured
# at 2.4 MB. Eight is room for an instance several times that size while still
# being a number the shell can be asked to hold without thinking about it.
MAX_BODY=8000000
MAX_OUTPUT=65536

fail() {
    /usr/bin/jq -cn --arg e "$1" '{ok: false, error: $e}'
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

input="$(/usr/bin/cat)"

# $input carries the password, so it is piped rather than expanded into an
# argument. The filters below name fields; they never name values.
url="$(printf '%s' "$input" | /usr/bin/jq -r '.url // ""')"
username="$(printf '%s' "$input" | /usr/bin/jq -r '.username // ""')"
allow_plaintext="$(printf '%s' "$input" |
    /usr/bin/jq -r 'if .allowPlaintext == true then "yes" else "no" end')"

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

# The cookie jar holds an authenticated Engine.IO session id, which for the life
# of the session is worth what the token is worth. `mktemp` with no directory
# puts it in shared /tmp, where every account on the machine can read it, so
# this refuses to run without a private per-user runtime directory rather than
# falling back to one. The trap still removes it on every exit path.
[[ -n "${XDG_RUNTIME_DIR:-}" ]] ||
    fail "XDG_RUNTIME_DIR is not set, so there is nowhere private to keep the session cookie"
umask 077
jar="$(/usr/bin/mktemp -p "$XDG_RUNTIME_DIR" scoop-uptime-kuma-jar.XXXXXXXXXX)" ||
    fail "Could not create a private file for the session cookie"
trap '/usr/bin/rm -f -- "$jar"' EXIT

# --fail so a 4xx or 5xx body is a failure rather than an answer to parse: an
# error page shaped like a handshake would otherwise be believed. --noproxy '*'
# because https_proxy is an ordinary environment variable that any process
# starting this one can set, and a proxy of someone else's choosing is then
# handed the password.
curl_common=(/usr/bin/curl -q -sS --fail --noproxy '*' --proto "$protos"
    --proto-redir "$protos" --max-time 20 --max-filesize "$MAX_BODY" -b "$jar" -c "$jar")

# Every byte curl produces passes through head before it exists as a value in
# this shell. --max-filesize is a second opinion, not the cap: it is defined in
# terms of a declared Content-Length, and whether a given curl also stops a
# chunked body mid-transfer is a property of that build. head does not care, so
# it is the one that decides. It is given MAX + 1 bytes so an overrun is
# detected rather than truncated into something that still parses.
#
# The length is checked before the pipeline's status, because head exiting on
# its MAX + 1st byte kills curl with SIGPIPE and would otherwise make too much
# data look like a dropped connection. curl's own 63 is the same refusal by the
# other route. Returns 2 for too much data, 1 for anything else.
fetch() {
    local out
    local rc
    out="$("${curl_common[@]}" "$@" | /usr/bin/head -c $((MAX_BODY + 1)))"
    rc=$?
    if ((${#out} > MAX_BODY)) || ((rc == 63)); then
        return 2
    fi
    ((rc == 0)) || return 1
    printf '%s' "$out"
}

endpoint="$url/socket.io/?EIO=4&transport=polling"

# A POST's response is bounded the same way, even though the server only ever
# answers "ok": it is a response from the network like any other.
post() {
    "${curl_common[@]}" -X POST --data-binary @- "$session" |
        /usr/bin/head -c $((MAX_BODY + 1)) >/dev/null
}

handshake="$(fetch "$endpoint")"
case $? in
    0) ;;
    2) fail "$url sent more data than this can handle" ;;
    *) fail "Cannot reach $url" ;;
esac

[[ "${handshake:0:1}" == "0" ]] || fail "Not an Uptime Kuma socket endpoint"
sid="$(printf '%s' "${handshake:1}" | /usr/bin/jq -r '.sid // ""')"
[[ -n "$sid" ]] || fail "Handshake returned no session id"

session="$endpoint&sid=$sid"

printf '40' | post || fail "Could not open the socket namespace"

# The one place the password is used, and it moves from stdin to stdin: jq
# builds the packet from the request object without the password ever being a
# shell word, and hands it straight to curl.
printf '%s' "$input" |
    /usr/bin/jq -j '"420", ([
        "login",
        {username: .username, password: (.password // ""), token: (.totp // "")}
    ] | tojson)' |
    post ||
    fail "Could not send credentials"

# The acknowledgement may not be in the first response; the server sends its
# own greeting packets first.
for _ in 1 2 3 4 5 6; do
    body="$(fetch "$session")"
    case $? in
        0) ;;
        2) fail "$url sent more data than this can handle" ;;
        *) fail "Connection lost during login" ;;
    esac

    while IFS= read -r frame; do
        [[ "$frame" == 2 ]] && printf '3' | post
        [[ "$frame" == 43* ]] || continue
        ack="${frame#43}"
        ack="${ack#"${ack%%[![:digit:]]*}"}"
        result="$(printf '%s' "$ack" | /usr/bin/jq -c '.[0] // {}' 2>/dev/null)" || continue
        if [[ "$(printf '%s' "$result" | /usr/bin/jq -r '.ok // false')" == "true" ]]; then
            # $result holds the token now, so it is piped like everything else.
            # The cap applies to what leaves this script as well as to what came
            # in: a token that never ends is refused here rather than forwarded
            # into the panel, where nothing would bound it either.
            out="$(printf '%s' "$result" |
                /usr/bin/jq -c '{ok: true, token: (.token // "")}' |
                /usr/bin/head -c $((MAX_OUTPUT + 1)))"
            ((${#out} <= MAX_OUTPUT)) || fail "That session token is too large to be real"
            printf '%s\n' "$out"
            exit 0
        fi
        if [[ "$(printf '%s' "$result" | /usr/bin/jq -r '.tokenRequired // false')" == "true" ]]; then
            /usr/bin/jq -cn '{ok: false, totpRequired: true}'
            exit 0
        fi
        fail "$(human "$(printf '%s' "$result" | /usr/bin/jq -r '.msg // ""')")"
    done < <(printf '%s\n' "$body" | /usr/bin/tr '\036' '\n')
done

fail "Uptime Kuma never acknowledged the login"
