#!/usr/bin/bash
#
# Read at most N bytes of a file, refusing anything that is not a plain file
# opened directly.
#
# `cat`, a shell redirect and Quickshell's FileView all follow a symlink, block
# forever on a FIFO, and read the whole file before any size check runs. Another
# process running as this user can plant either at a predictable path, so the
# open itself has to carry the guarantees: O_NOFOLLOW refuses a symlinked final
# component, O_NONBLOCK refuses to hang on a FIFO, and the count stops the read
# before an oversized file is in memory rather than after.
#
# The interpreter and dd are named by absolute path rather than found through
# PATH: this helper is on the path that reads the credential configuration, and
# PATH is inherited from whoever started the shell.
#
# Usage: read-bounded.sh <path> <max-bytes>
# Writes the bytes to stdout. Exits non-zero, silently, on anything unexpected.

set -uo pipefail

path="${1:-}"
max="${2:-65536}"

[[ -n "$path" ]] || exit 1
[[ "$max" =~ ^[0-9]+$ ]] || exit 1

# One open, with the refusals attached to it. count_bytes makes count a byte
# count; reading max+1 means an oversized file is detected rather than silently
# truncated by the caller.
/usr/bin/dd if="$path" \
    iflag=nofollow,nonblock,count_bytes,fullblock \
    bs=4096 count=$((max + 1)) status=none 2>/dev/null
