---
status: accepted
---

# Speak Socket.IO from QML over HTTP long-polling

Omarchy 4.x plugins are QML running inside the Quickshell process, and Uptime
Kuma's only full-fidelity interface is Socket.IO. QML has no WebSocket
(`QtWebSockets` is not installed), and a published plugin cannot assume Node or
Bun exists — neither is an Omarchy dependency, and Omarchy's plugin contract has
no install hooks with which to provision one. So the plugin implements the
Engine.IO v4 polling transport itself over plain HTTP, driven by `curl` through
Quickshell's `Process`, and speaks the Socket.IO protocol on top of it.

## Considered Options

- **Prometheus `/metrics` via `curl`.** Trivial to build, but carries no group
  hierarchy, no heartbeat error text and no event log — it cannot support
  triage, which is this plugin's entire purpose. Creating the first Uptime Kuma
  API key also permanently disables Basic auth on that endpoint, breaking any
  existing scrape.
- **A Node or Bun sidecar** running an existing, tested `socket.io-client`
  implementation. Full fidelity and the code already exists, but it is
  undistributable: provisioning a runtime is impossible within the plugin
  contract, and vendoring a compiled binary means a ~90 MB per-architecture blob
  in git.
- **A WebSocket transport**, rejected only because `QtWebSockets` is absent;
  worth revisiting if Omarchy ever ships it.

## Consequences

The riskiest code in this project is a hand-written client for an interface its
own maintainers describe as internal and subject to breaking changes without
notice. It is therefore isolated in a single layer with its own tests, ported
from a working `socket.io-client` implementation kept as the reference spec.

Long-polling holds a request open until the server has something to say, so
update latency stays close to a true push transport. The cost is one connection
held open continuously and a full re-request cycle per batch of events.
