import QtQuick
import Quickshell
import Quickshell.Io

// A child process whose output cannot outgrow a budget, and whose environment
// is the one we chose rather than the one we inherited.
//
// StdioCollector keeps everything the child writes and only then lets you
// measure it — by the time a length check runs, the bytes are already in the
// shell's heap. This counts each chunk as it arrives, stops at the ceiling, and
// kills the child rather than truncating: an answer that outgrew its budget is
// a refusal, not a value to salvage.
//
// The environment matters for the same reason the argv does. Everything this
// spawns is on the path of a password or a session token, and an inherited
// environment carries BASH_ENV, LD_PRELOAD, PYTHONPATH and the proxy variables
// into it — each of which lets another process running as this user decide what
// code runs, or where the credential goes.
Process {
    id: root

    /** Ceiling for everything the child writes to stdout, in characters. */
    property int maxBytes: 65536

    /** Emitted once per run, after the child has exited. */
    signal finishedWith(string text, bool tooLarge)

    property string _collected: ""
    property bool _overflowed: false

    clearEnvironment: true
    environment: ({
            // Fixed, absolute, and short: nothing here is resolved through a
            // directory another process can prepend to.
            PATH: "/usr/bin:/bin",
            // secret-tool reaches the login keyring over the session bus, so
            // this one is not optional.
            DBUS_SESSION_BUS_ADDRESS: Quickshell.env("DBUS_SESSION_BUS_ADDRESS"),
            XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
            HOME: Quickshell.env("HOME"),
            // Byte semantics for the helpers' own length checks.
            LC_ALL: "C",
        })

    onStarted: {
        _collected = "";
        _overflowed = false;
    }

    stdout: SplitParser {
        // No marker: raw chunks. A line-delimited parser has to buffer until
        // the delimiter before it can hand anything over, so the ceiling would
        // arrive after the allocation it is meant to prevent.
        splitMarker: ""
        onRead: function (chunk) {
            if (root._overflowed) {
                return;
            }
            if (root._collected.length + chunk.length > root.maxBytes) {
                root._overflowed = true;
                root._collected = "";
                root.signal(15);
                killTimer.restart();
                return;
            }
            root._collected += chunk;
        }
    }

    onExited: {
        killTimer.stop();
        root.finishedWith(root._collected, root._overflowed);
        root._collected = "";
        root._overflowed = false;
    }

    // A child that ignores TERM does not get to keep running.
    //
    // Declared as a property rather than a child: Process has no default
    // property, so it cannot hold one.
    property Timer killTimer: Timer {
        interval: 2000
        repeat: false
        onTriggered: root.signal(9)
    }
}
