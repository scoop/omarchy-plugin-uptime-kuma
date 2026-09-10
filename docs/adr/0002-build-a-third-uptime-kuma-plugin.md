---
status: accepted
---

# Build a third Uptime Kuma plugin rather than contribute to the two that exist

Two Uptime Kuma plugins were already published to the Omarchy plugin directory
before this one started — `daan.uptime-kuma`, which reads the Prometheus
`/metrics` endpoint, and `io.github.p145085.uptime-kuma`, which reads the public
status-page JSON. Both are competent, and neither can show a monitor group
hierarchy, the error text of a failed check, or an update sooner than its poll
interval. Those three are the entire reason this plugin exists, and the reason
none of them is reachable is the interface each chose, not the quality of its
code: `/metrics` has no notion of parent and child and no message field at all,
and the status-page API blanks `msg` at the source and is server-cached for one
to five minutes. Reaching them requires Socket.IO, which replaces the data layer
wholesale and takes the rendering with it.

## Considered Options

- **Contribute the operator view upstream.** Rejected on evidence of
  responsiveness rather than on merit: `daan.uptime-kuma` has a trivial
  twenty-eight-line pull request that has sat unanswered for twelve days, while
  the maintainer pushed his own commit twelve hours after it was filed;
  `io.github.p145085.uptime-kuma` has never received a contribution of any kind.
  A change of this size is not landing in either.
- **Fork `io.github.p145085.uptime-kuma`**, the more salvageable of the two — its
  separation of a pure model from a service from a panel is the right shape, and
  its status rollup, formatters and keyboard cursor would survive. Rejected
  because everything below that line is a status-page client we would delete,
  and carrying it as inherited debt is worse than borrowing the parts we want
  under its MIT licence with attribution.

## Consequences

We are the third entry for the same service in a directory where users pick by
name, so the README has to make the distinction legible immediately: groups,
error text, push. We also owe attribution to both projects — the panel layering
and hardening practices are learned from one, the credential handling from the
other.
