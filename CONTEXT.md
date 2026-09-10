# Uptime Kuma Operator Pane

An Omarchy plugin that surfaces the state of an Uptime Kuma instance on the
desktop, so that a failing service is noticed and understood without opening a
browser.

## Language

**Monitor**:
A single check Uptime Kuma performs against one target on a fixed interval.
_Avoid_: Check, service, host, probe

**Group**:
A Monitor whose purpose is to contain other Monitors rather than to check
anything itself. The primary organising axis of the pane. A Group's Status is
the worst Status among its children, never the Status Uptime Kuma records
against the Group itself.
_Avoid_: Folder, category, section, tag

**Heartbeat**:
The recorded outcome of one execution of a Monitor.
_Avoid_: Beat, ping, result, sample

**Status**:
The condition of a Monitor as of its most recent Heartbeat. Exactly three
values are shown: Up, Degraded, Down.
_Avoid_: State, health

**Up**:
A Monitor whose last Heartbeat succeeded.
_Avoid_: OK, green, healthy, passing

**Degraded**:
A Monitor that is neither confirmed working nor confirmed failing — it is
retrying after a failure, or it sits inside a maintenance window.
_Avoid_: Warning, amber, unstable, flapping

**Down**:
A Monitor whose last Heartbeat failed and which has exhausted its retries.
_Avoid_: Failed, red, broken, offline, error

**Paused**:
A Monitor Uptime Kuma is not currently checking. It has no Status, is hidden
from the Pane, and can never raise the Indicator.
_Avoid_: Disabled, inactive, off, muted

**Problems**:
The section of the Pane listing every Down Monitor, flattened out of the Group
hierarchy and pinned above it. Empty whenever nothing is Down.
_Avoid_: Alerts, incidents, issues, errors

**Unreachable**:
The condition of having lost contact with Uptime Kuma itself. A property of the
connection, never of a Monitor — Monitors do not become unknown, our view of
them does. Must be shown distinctly from Down, because stale data that looks
healthy is the one lie this plugin cannot tell.
_Avoid_: Offline, disconnected, unknown, stale, error

**Pane**:
The on-demand window presenting the full state of the instance. Summoned
deliberately; not persistent.
_Avoid_: Dashboard, window, popup, overlay, widget

**Indicator**:
The persistent, minimal presence in the Omarchy bar. Absent while nothing is
wrong; appears to report that something is.
_Avoid_: Widget, tray icon, applet, badge

## Notes on terms deliberately excluded

**Acknowledge** has no meaning in this context. Uptime Kuma has no
acknowledgement primitive, and the operations that resemble one are destructive
or heavier than the word implies. Do not introduce the term without deciding
what it maps to.
