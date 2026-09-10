# Uptime Kuma for Omarchy

An operator view of an [Uptime Kuma](https://github.com/louislam/uptime-kuma)
instance, for Omarchy 4.x.

The bar stays empty while everything is healthy. When something breaks, an
indicator appears; `Super + U` opens the full view, with whatever is broken
pinned to the top and the error message Uptime Kuma actually recorded.

## Why another one

Two Uptime Kuma plugins already exist. Both are good at what they are, and both
read an interface that cannot carry what an operator view needs:

|                         | `/metrics`    | status page           | this     |
| ----------------------- | ------------- | --------------------- | -------- |
| Monitor groups          | no            | page sections only    | **yes**  |
| Error text of a failure | no            | blanked at the source | **yes**  |
| Update latency          | poll interval | 1–5 min server cache  | **push** |

This plugin speaks Uptime Kuma's Socket.IO interface — the one its own web UI
uses — so it sees the real parent/child hierarchy, the heartbeat message of a
failed check, and every state change as it happens.

## Requirements

- Omarchy 4.x (Quickshell shell)
- **Uptime Kuma 2.x** — 1.x is not supported
- An account **without** two-factor, or with, if you can enter a code once
- `curl`, `jq`, `secret-tool` — all present on a stock Omarchy

## Install

```bash
omarchy plugin add https://github.com/scoop/omarchy-plugin-uptime-kuma --enable
```

## Configure

The shell has no settings form for plugins yet, so the connection lives in
`~/.config/omarchy/shell.json`, on this plugin's bar entry:

```json
{ "id": "scoop.uptime-kuma", "baseUrl": "https://kuma.example.com", "username": "you" }
```

Then authenticate once. Your password is exchanged for a session token and is
never stored:

```bash
~/.config/omarchy/plugins/scoop.uptime-kuma/bin/authenticate.sh
```

The token goes into the login keyring. Changing your Uptime Kuma password
revokes it, which logs the plugin out — that is intended.

## Keybinding

The plugin cannot install a binding for you. Add to your Hyprland config:

```
bindd = SUPER, U, Uptime Kuma, exec, omarchy-shell shell toggle scoop.uptime-kuma
```

Clicking the indicator opens the same view.

## Using it

| Key     | Does                                 |
| ------- | ------------------------------------ |
| type    | filter monitors                      |
| `↑` `↓` | move                                 |
| `Enter` | open in Uptime Kuma, or fold a group |
| `Esc`   | clear the filter, then close         |

Selecting a row shows its full error message; the others stay on one line.

Groups are folded shut by default, so a healthy instance is a dozen rows rather
than a wall of green. Anything down is pinned above the tree regardless, so
folding never hides a problem.

Paused monitors are hidden and only counted — Uptime Kuma is not checking them,
so they have nothing to report.

When the connection to Uptime Kuma is lost, the view says so and greys out. It
will not show you stale data that looks healthy.

## Developing

Clone into `~/.config/omarchy/plugins/scoop.uptime-kuma` and work there —
plugin folders may not contain symlinks, so the usual symlink-the-repo trick
does not apply. Saving a file hot-reloads the shell.

```bash
bun test      # the wire codec, the domain model, the row builder
bun run lint
```

The QML lives in three thin files; everything with logic in it is plain
JavaScript under `src/`, so it can be tested without a running shell.

Two gotchas worth knowing:

- **If an error's line number stops moving when you edit the file, restart the
  shell.** The QML engine caches a plugin's compiled component for the life of
  the shell process; hot-reload and even disable/enable will keep serving the
  old one. `omarchy-restart-shell`.
- `qmllint` and `qmlformat` in current Qt cannot parse typed function syntax
  (`function f(): void`), which Quickshell's IPC handlers require. They fail on
  a minimal example too. Do not chase it.

## Credit

Two plugins came first and taught this one things:

- [`p145085/omarchy-uptime-kuma`](https://github.com/p145085/omarchy-uptime-kuma)
  — the model/service/panel split, and a thorough hardening posture
- [`daanlenaerts/omakuma`](https://github.com/daanlenaerts/omakuma) — passing
  secrets to `curl` on stdin so they never reach the process table

Both MIT.

## License

MIT
