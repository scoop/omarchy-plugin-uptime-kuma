---
status: accepted
---

# Store a session token, never the password

Uptime Kuma API keys authenticate exactly one route, `/metrics`, and are
rejected by Socket.IO, so the interface this plugin depends on leaves only
username-and-password login. Rather than keep that password, the setup form
exchanges it once for the JWT that `login` returns, stores that, and reconnects
with `loginByToken` from then on. The password is never written anywhere.

The token is worth roughly what the password is worth while it is valid, so this
is not a claim of reduced privilege. What it buys is revocation: the JWT embeds
a hash of the password, so changing the Uptime Kuma password invalidates every
token issued against it, without touching anything else on the instance. That is
the property an API key would have given us if one had been usable here.

## Consequences

The token lives in the login keyring via `secret-tool`, which gnome-keyring
provides as an Omarchy dependency. Neither it nor the password is ever a
command-line argument or an environment variable of any process — not `curl`,
not `jq`, not `secret-tool` — because `/proc/<pid>/cmdline` and
`/proc/<pid>/environ` are readable by everything else running as this user. The
request object is piped into `jq`, which writes the packet, which is piped into
`curl`; the token is piped into `secret-tool`. The practice is taken from
`daan.uptime-kuma`; `test/scripts.test.js` enforces it by running the helpers
with a `jq` that records its own argv. A password change logs the plugin out, which surfaces
as a prompt to authenticate again; this is correct behaviour, not a fault.

Two-factor authentication is fully supported as a consequence of this design.
The time-based code is demanded only by the `login` handler, and only the first
login goes through it — a login a person is already sitting in front of, typing
a password. `loginByToken` performs no second-factor check, so every reconnect
thereafter is unattended. The setup form therefore carries an optional code
field and re-prompts when the server answers `tokenRequired`. The token itself
is signed without an expiry claim, so it remains valid until the password
changes.
