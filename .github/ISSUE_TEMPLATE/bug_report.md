---
name: Something is wrong
about: The panel, the indicator or the connection is not behaving
labels: bug
---

**What happened, and what you expected instead**

**Which Uptime Kuma version.** This plugin supports 2.x only; 1.x is not
supported and will refuse to connect.

**What the plugin thinks its state is**

```
omarchy-shell scoop.uptime-kuma.service status
```

**Anything the shell logged.** Errors from the plugin land in the journal under
the shell's own tag:

```
journalctl --user -t omarchy-shell --since "-10 min" | grep -i kuma
```

Please read it before pasting. It contains the addresses this plugin talks to,
and if you are debugging a login problem it may contain the name of your
account. It should not contain your password or session token — if it does,
that is itself the bug and worth saying so plainly.

**Your Omarchy version** (`omarchy version`) and whether the address is https,
plain http, or loopback.
