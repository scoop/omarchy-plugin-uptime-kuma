// The shapes the plugin actually handles, named once so the JSDoc in src/ can
// refer to them instead of saying `object` and hoping.
//
// Two vocabularies live here and they are deliberately separate. The `Kuma*`
// types are what Uptime Kuma puts on the wire — its field names, its status
// codes, its spellings. Everything else is the vocabulary in CONTEXT.md, which
// is what the panel renders. The translation between them happens in model.js,
// and keeping the names apart is what stops the wire format leaking into the UI.

/** A monitor exactly as `monitorList` sends it. */
interface KumaMonitor {
    id: number;
    name: string;
    /** `"group"` for a container; anything else is a real check. */
    type?: string;
    parent?: number | null;
    active?: boolean;
    /** Set when an ancestor group is paused, so a monitor is not checked. */
    forceInactive?: boolean;
    childrenIDs?: number[];
    url?: string | null;
    [key: string]: unknown;
}

/** One recorded check outcome. Status: 0 down, 1 up, 2 pending, 3 maintenance. */
interface KumaHeartbeat {
    monitorID?: number;
    status: number;
    /** `"YYYY-MM-DD HH:MM:SS"`, in UTC despite saying nothing about it. */
    time: string;
    msg?: string;
    ping?: number | null;
    important?: boolean;
    [key: string]: unknown;
}

/** The figures Uptime Kuma reports separately from the heartbeats. */
interface MonitorStats {
    uptime24?: number | null;
    avgPing?: number | null;
    certDays?: number | null;
}

/** One monitor, reduced to what the panel shows. */
interface MonitorView {
    id: number;
    name: string;
    status: string;
    statusText: string;
    error: string;
    ping: number | null;
    latencyText: string;
    time: string | null;
    since: string | null;
    held: string;
    uptime24: number | null;
    uptimeText: string;
    avgPing: number | null;
    avgPingText: string;
    certDays: number | null;
    certText: string;
    samples: { status: string; level: number }[];
    beats: KumaHeartbeat[];
}

/** A group and the monitors under it, with its worst-child status. */
interface GroupView {
    id: number;
    name: string;
    status: string;
    children: MonitorView[];
}

/** How many monitors are in each state. */
interface ViewCounts {
    up: number;
    degraded: number;
    down: number;
    paused: number;
    total: number;
}

/** Everything the panel renders, derived from the wire shapes. */
interface View {
    groups: GroupView[];
    ungrouped: MonitorView[];
    problems: MonitorView[];
    counts: ViewCounts;
}

/** One line in the flattened list the keyboard moves through. */
interface Row {
    type: "section" | "group" | "monitor";
    id: number | string;
    label: string;
    detail: string;
    status: string;
    error: string;
    selectable: boolean;
    monitor: MonitorView | null;
}

/** The connection details the setup form collects. */
interface ConnectionFields {
    baseUrl?: string;
    username?: string;
    password?: string;
    totp?: string;
    allowPlaintext?: boolean;
    totpRequired?: boolean;
}
