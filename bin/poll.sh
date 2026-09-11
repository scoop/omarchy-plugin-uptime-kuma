#!/usr/bin/bash
#
# Hold one Engine.IO polling session open and stream what it says.
#
# Reads {"url","token","allowPlaintext"} as JSON on stdin, then writes one line
# per HTTP response body to stdout — each still framed with 0x1e, for
# src/engine.js to decode. Diagnostics go to stderr; a lost connection exits
# non-zero so the caller can back off and start a new session, and a refused
# token exits 2 so the caller can ask for credentials instead of retrying.
#
# Engine.IO payloads never contain a raw newline (JSON escapes them), which is
# what makes one-body-per-line safe.
#
# The session token is worth what the password is worth, so it is handled the
# same way: never an argument, never an environment variable, only ever a pipe
# between jq and curl, and every binary named by absolute path so that PATH
# cannot decide which curl receives it. See the note at the top of login.sh.

set -uo pipefail

# ${#s} counts characters unless the locale says otherwise, and a byte cap
# measured in characters is not a byte cap. See login.sh.
export LC_ALL=C

# The ceiling on one HTTP response body, applied by the reader rather than
# trusted to curl; see fetch() for why --max-filesize is not the cap.
# The snapshot Uptime Kuma sends at login carries every monitor's heartbeat
# history, so it scales with the instance: an 86-monitor instance was measured
# at 2.4 MB. Eight is room for an instance several times that size while still
# being a number the shell can be asked to hold without thinking about it.
MAX_BODY=8000000

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

input="$(/usr/bin/head -n 1)"
url="$(printf '%s' "$input" | /usr/bin/jq -r '.url // ""')"
allow_plaintext="$(printf '%s' "$input" |
    /usr/bin/jq -r 'if .allowPlaintext == true then "yes" else "no" end')"

[[ -n "$url" ]] || die "No Uptime Kuma URL configured"
[[ "$url" =~ ^https?://[^[:space:]/]+ ]] || die "URL must be http:// or https://"

# The token itself is checked without ever becoming a shell word: jq answers
# the question rather than handing over the value.
[[ "$(printf '%s' "$input" |
    /usr/bin/jq -r 'if (.token // "") == "" then "no" else "yes" end')" == "yes" ]] ||
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

# The jar holds the authenticated session id for as long as this runs. Shared
# /tmp is not a place to keep that, and there is no fallback to it: without a
# private per-user runtime directory this refuses to start.
[[ -n "${XDG_RUNTIME_DIR:-}" ]] ||
    die "XDG_RUNTIME_DIR is not set, so there is nowhere private to keep the session cookie"
umask 077
jar="$(/usr/bin/mktemp -p "$XDG_RUNTIME_DIR" scoop-uptime-kuma-jar.XXXXXXXXXX)" ||
    die "Could not create a private file for the session cookie"
trap '/usr/bin/rm -f -- "$jar"' EXIT

# --max-time must outlast a long poll: the server holds the request open for
# pingInterval (25s by default) before answering with a ping. --fail so an error
# page is not decoded as a batch of frames, and --noproxy '*' so an inherited
# https_proxy cannot route the session token through someone else's machine.
curl_common=(/usr/bin/curl -q -sS --fail --noproxy '*' --proto "$protos"
    --proto-redir "$protos" --max-time 60 --max-filesize "$MAX_BODY" -b "$jar" -c "$jar")

# See login.sh. head is the cap that decides, --max-filesize a second opinion
# that only some builds apply to a chunked body; the length is checked before
# the pipeline's status because head exiting early kills curl with SIGPIPE, and
# curl's own 63 is the same refusal by the other route. 2 means too much data.
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

handshake="$(fetch "$endpoint")"
case $? in
    0) ;;
    2) die "$url sent more data than this can handle" ;;
    *) die "Cannot reach $url" ;;
esac

[[ "${handshake:0:1}" == "0" ]] || die "Not an Uptime Kuma socket endpoint"
sid="$(printf '%s' "${handshake:1}" | /usr/bin/jq -r '.sid // ""')"
[[ -n "$sid" ]] || die "Handshake returned no session id"

session="$endpoint&sid=$sid"

# A POST's answer is bounded like every other response, even though the server
# only ever says "ok" to one.
post() {
    printf '%s' "$1" | "${curl_common[@]}" -X POST --data-binary @- "$session" |
        /usr/bin/head -c $((MAX_BODY + 1)) >/dev/null
}

post '40' || die "Could not open the socket namespace"

# loginByToken performs no second-factor check, so every reconnect after the
# first is unattended even on an account with two-factor enabled.
#
# The packet is built by jq from stdin and piped straight to curl, so the token
# is a command-line argument to nothing.
printf '%s' "$input" |
    /usr/bin/jq -j '"420", (["loginByToken", .token] | tojson)' |
    "${curl_common[@]}" -X POST --data-binary @- "$session" |
    /usr/bin/head -c $((MAX_BODY + 1)) >/dev/null ||
    die "Could not present the session token"

# A refused token does not close the socket: the server simply never sends a
# snapshot, so an unchecked session would poll forever looking connected but
# empty. Read the acknowledgement and say so, with a distinct exit code the
# caller can turn into "ask for credentials again" rather than "retry later".
for _ in 1 2 3 4 5 6; do
    ack_body="$(fetch "$session")"
    case $? in
        0) ;;
        2) die "$url sent more data than this can handle" ;;
        *) die "Connection lost during sign-in" ;;
    esac

    ack_seen=""
    while IFS= read -r frame; do
        [[ "$frame" == 2 ]] && post '3'
        [[ "$frame" == 43* ]] || continue
        ack_seen="yes"
        payload="${frame#43}"
        payload="${payload#"${payload%%[![:digit:]]*}"}"
        if [[ "$(printf '%s' "$payload" |
            /usr/bin/jq -r '.[0].ok // false' 2>/dev/null)" != "true" ]]; then
            echo "Session token refused" >&2
            exit 2
        fi
    done < <(printf '%s\n' "$ack_body" | /usr/bin/tr '\036' '\n')
    # The greeting arrives in the same batch as the acknowledgement; anything
    # already streamed must still reach the caller.
    [[ -n "$ack_body" ]] && printf '%s\n' "$ack_body"
    [[ -n "$ack_seen" ]] && break
done

while :; do
    body="$(fetch "$session")"
    case $? in
        0) ;;
        2) die "$url sent more data than this can handle" ;;
        *) die "Connection lost" ;;
    esac

    # An empty body means the poll timed out with nothing to say; that is normal.
    [[ -n "$body" ]] || continue

    printf '%s\n' "$body"

    # Answer any ping in this batch, or the server drops the session.
    while IFS= read -r frame; do
        [[ "$frame" == 2 ]] && post '3'
    done < <(printf '%s\n' "$body" | /usr/bin/tr '\036' '\n')
done
