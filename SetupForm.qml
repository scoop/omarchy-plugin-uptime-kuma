import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "src/setup.js" as Setup

// Connecting, without leaving the pane.
//
// Everything this form needs to do it does through `service`: the URL and the
// username are pushed onto it, the password is handed to `authenticate()` and
// forgotten. The password is never stored, never logged and never rendered —
// ADR 0003 — so it exists only as the contents of a masked field, and that
// field is cleared the moment a session exists.
//
// The URL and the username are not secret and belong in shell.json, which is
// what `shell.updateEntryInline` writes. If the host refuses that write, the
// form says so rather than pretending the setting survived a restart.
//
// Keyboard: the parent panel catches keys with `Keys.priority: Keys.BeforeItem`
// and would eat every character typed here. It must stand down while this form
// holds the keyboard — see `editing`, and the wiring note at the bottom.
ColumnLayout {
    id: root

    // The one object this form talks to. See Service.qml.
    property var service: null

    // The host's PluginShellApi, and the shell.json entry id to write to.
    // Without both, the connection still works — it just will not survive a
    // restart, and `persisted` goes false to say so.
    property var shell: null
    property string moduleName: ""

    // Palette. Defaults suit the menu surfaces the Pane is drawn on.
    property color foreground: Color.menu.text
    property string fontFamily: Style.font.menuFamily
    readonly property color dim: Qt.darker(foreground, 1.4)

    // True while any control here holds the keyboard. The parent's key catcher
    // must short-circuit on this or the operator's typing goes to the filter.
    readonly property bool editing:
        urlField.activeFocus ||
        userField.activeFocus ||
        passwordField.activeFocus ||
        totpField.activeFocus ||
        connectButton.activeFocus

    // Escape while a field has focus: the parent should take the keyboard back
    // (a second Escape then closes the pane, as it does everywhere else).
    signal escaped

    readonly property string connection: service ? service.connection : "setup"

    // Between handing the password over and the helper answering, the service
    // is still in "setup" — the submission is ours to remember.
    property bool submitting: false
    readonly property bool busy: submitting || connection === "connecting"

    // Revealed once the server says the account has two-factor enabled. The
    // first login is the only one that is ever asked for a code (ADR 0003).
    property bool totpRequired: false

    // The thing to fix, and which field to fix it in.
    property string problem: ""
    property string problemField: ""

    // False once a write to shell.json was attempted and refused.
    property bool persisted: true

    // The values last written to shell.json, so an unchanged re-submit is not
    // mistaken for a failed write.
    property string _persistedKey: ""

    spacing: Style.space(10)

    // ------------------------------------------------------------------ status

    readonly property string statusText: {
        if (busy) {
            return "Connecting to " + Setup.normalizeUrl(urlField.text) + "…";
        }
        if (problem !== "") {
            return problem;
        }
        if (!persisted) {
            return "Couldn't save to shell.json — add baseUrl and username to this plugin's entry there to keep them.";
        }
        if (totpRequired) {
            return "This account has two-factor enabled. Enter the current code.";
        }
        return "Your password is exchanged for a session token and never stored.";
    }

    readonly property bool statusIsProblem: !busy && (problem !== "" || !persisted)

    // ------------------------------------------------------------------ actions

    /** Put the keyboard where the operator still has something to type. */
    function focusFirstField() {
        if (totpRequired && totpField.text === "") {
            totpField.forceActiveFocus();
        } else if (urlField.text === "") {
            urlField.forceActiveFocus();
        } else if (userField.text === "") {
            userField.forceActiveFocus();
        } else {
            passwordField.forceActiveFocus();
        }
    }

    function focusField(field) {
        if (field === "baseUrl") {
            urlField.forceActiveFocus();
        } else if (field === "username") {
            userField.forceActiveFocus();
        } else if (field === "totp") {
            totpField.forceActiveFocus();
        } else {
            passwordField.forceActiveFocus();
        }
    }

    /** Forget the password and any half-finished attempt. Safe to call on close. */
    function reset() {
        passwordField.text = "";
        totpField.text = "";
        totpRequired = false;
        submitting = false;
        problem = "";
        problemField = "";
        persisted = true;
    }

    /**
     * Take what the service already knows, without ever overwriting typing.
     *
     * The Pane can be built before the Indicator has pushed settings down, so
     * this runs again whenever the service learns something.
     */
    function adoptService() {
        if (!service) {
            return;
        }
        if (urlField.text === "" && !urlField.activeFocus) {
            urlField.text = service.baseUrl;
        }
        if (userField.text === "" && !userField.activeFocus) {
            userField.text = service.username;
        }
    }

    /**
     * Write the non-secret half of the connection to shell.json.
     *
     * `updateEntryInline` replaces the whole entry rather than merging into it,
     * so anything else already on the entry is carried across by hand. It
     * answers false both for "no such entry" and for "nothing changed"; only
     * the first of those is a failure, hence the comparison.
     */
    function persistConnection(url, user) {
        if (!shell || moduleName === "" || typeof shell.updateEntryInline !== "function") {
            return false;
        }
        var key = url + "\n" + user;
        if (_persistedKey === key) {
            return true;
        }
        var entry = _existingEntry();
        var unchanged = entry.baseUrl === url && entry.username === user;
        entry.baseUrl = url;
        entry.username = user;
        var ok = shell.updateEntryInline(moduleName, entry) || unchanged;
        if (ok) {
            _persistedKey = key;
        }
        return ok;
    }

    /** This plugin's bar entry as shell.json currently has it, minus its id. */
    function _existingEntry() {
        var out = {};
        var layout = shell && shell.barConfig ? shell.barConfig.layout : null;
        if (!layout) {
            return out;
        }
        var sections = ["left", "center", "right"];
        for (var s = 0; s < sections.length; s++) {
            var list = layout[sections[s]] || [];
            for (var i = 0; i < list.length; i++) {
                var found = list[i];
                if (!found || String(found.id) !== moduleName) {
                    continue;
                }
                for (var key in found) {
                    if (key !== "id") {
                        out[key] = found[key];
                    }
                }
            }
        }
        return out;
    }

    /** Validate, persist the non-secrets, then spend the password. */
    function submit() {
        if (!service || busy) {
            return;
        }

        var fields = {
            baseUrl: urlField.text,
            username: userField.text,
            password: passwordField.text,
            totp: totpField.text,
            totpRequired: root.totpRequired,
        };
        var trouble = Setup.firstProblem(fields);
        if (trouble) {
            problem = trouble.message;
            problemField = trouble.field;
            focusField(trouble.field);
            return;
        }

        // Show the operator the URL we are actually going to use, rather than
        // silently connecting to something other than what is on screen.
        var url = Setup.normalizeUrl(urlField.text);
        var user = String(userField.text).trim();
        urlField.text = url;
        userField.text = user;

        problem = "";
        problemField = "";
        service.baseUrl = url;
        service.username = user;
        persisted = persistConnection(url, user);

        submitting = true;
        stallTimer.restart();
        service.authenticate(passwordField.text, Setup.normalizeTotp(totpField.text));
    }

    // ------------------------------------------------------------------ service

    Component.onCompleted: adoptService()
    onServiceChanged: adoptService()

    Connections {
        target: root.service

        function onBaseUrlChanged() {
            root.adoptService();
        }

        function onUsernameChanged() {
            root.adoptService();
        }

        function onLoginFailed(message) {
            root.submitting = false;
            stallTimer.stop();
            root.problem = message;
            // A refused code leaves a good password in place, so the code is
            // what to re-type; anything else lands back on the password. Either
            // way the field is selected, so typing replaces rather than appends.
            root.problemField = root.totpRequired ? "totp" : "password";
            root.focusField(root.problemField);
            if (root.problemField === "totp") {
                totpField.selectAll();
            } else {
                passwordField.selectAll();
            }
        }

        function onLoginNeedsTotp() {
            root.submitting = false;
            stallTimer.stop();
            root.totpRequired = true;
            root.problem = "";
            root.problemField = "";
            root.focusField("totp");
        }

        function onConnectionChanged() {
            if (root.connection !== "connected") {
                return;
            }
            // A session exists; the password has served its purpose.
            root.submitting = false;
            stallTimer.stop();
            passwordField.text = "";
            totpField.text = "";
            root.totpRequired = false;
            root.problem = "";
            root.problemField = "";
        }
    }

    // The login helper caps itself at twenty seconds per request and always
    // answers, but a helper that never starts would otherwise leave the form
    // spinning forever with no way back.
    Timer {
        id: stallTimer
        interval: 45000
        repeat: false
        onTriggered: {
            if (root.submitting) {
                root.submitting = false;
                root.problem = "The login helper did not answer";
                root.problemField = "password";
            }
        }
    }

    // ------------------------------------------------------------------- layout

    PanelSectionHeader {
        Layout.fillWidth: true
        text: "CONNECT TO UPTIME KUMA"
        foreground: root.foreground
        fontFamily: root.fontFamily
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        Text {
            Layout.fillWidth: true
            text: "Uptime Kuma URL"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
        }

        TextField {
            id: urlField
            Layout.fillWidth: true
            enabled: !root.busy
            placeholderText: "https://kuma.example.com"
            foreground: root.foreground
            accent: root.problemField === "baseUrl" ? Color.urgent : Color.accent
            font.family: root.fontFamily
            onAccepted: root.submit()
            Keys.onEscapePressed: function (event) {
                root.escaped();
                event.accepted = true;
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        Text {
            Layout.fillWidth: true
            text: "Username"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
        }

        TextField {
            id: userField
            Layout.fillWidth: true
            enabled: !root.busy
            placeholderText: "you"
            foreground: root.foreground
            accent: root.problemField === "username" ? Color.urgent : Color.accent
            font.family: root.fontFamily
            onAccepted: root.submit()
            Keys.onEscapePressed: function (event) {
                root.escaped();
                event.accepted = true;
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        Text {
            Layout.fillWidth: true
            text: "Password"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
        }

        TextField {
            id: passwordField
            Layout.fillWidth: true
            enabled: !root.busy
            // `password` is the kit's name for echoMode: TextInput.Password.
            // This text is read exactly once, by submit(), and goes nowhere
            // else: not to a log, not to a binding, not to disk.
            password: true
            placeholderText: "Exchanged for a token, never stored"
            foreground: root.foreground
            accent: root.problemField === "password" ? Color.urgent : Color.accent
            font.family: root.fontFamily
            onAccepted: root.submit()
            Keys.onEscapePressed: function (event) {
                root.escaped();
                event.accepted = true;
            }
        }
    }

    // Hidden until the server asks for it: most accounts never see this field,
    // and a two-factor box on an account without two-factor reads as a demand.
    ColumnLayout {
        Layout.fillWidth: true
        visible: root.totpRequired
        spacing: Style.space(4)

        Text {
            Layout.fillWidth: true
            text: "Two-factor code"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
        }

        TextField {
            id: totpField
            Layout.fillWidth: true
            enabled: !root.busy
            placeholderText: "123456"
            inputMethodHints: Qt.ImhDigitsOnly
            maximumLength: 8
            foreground: root.foreground
            accent: root.problemField === "totp" ? Color.urgent : Color.accent
            font.family: root.fontFamily
            onAccepted: root.submit()
            Keys.onEscapePressed: function (event) {
                root.escaped();
                event.accepted = true;
            }
        }
    }

    Text {
        Layout.fillWidth: true
        text: root.statusText
        color: root.statusIsProblem ? Color.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
        textFormat: Text.PlainText
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Item {
            Layout.fillWidth: true
        }

        Button {
            id: connectButton
            text: root.busy ? "Connecting" : "Connect"
            // The spinner is the whole progress indication: there is no
            // percentage to report, only that we are waiting on the server.
            iconText: root.busy ? "\uf021" : ""
            iconSpinning: root.busy
            enabled: !root.busy
            focusable: true
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.submit()
            Keys.onEscapePressed: function (event) {
                root.escaped();
                event.accepted = true;
            }
        }
    }
}

// ---------------------------------------------------------------- wiring note
//
// In Pane.qml, where the list goes when there is nothing to list:
//
//     SetupForm {
//         id: setupForm
//         Layout.fillWidth: true
//         visible: root.connection === "setup"
//         service: root.service
//         shell: root.shell
//         moduleName: "scoop.uptime-kuma"
//         foreground: root.foreground
//         fontFamily: root.fontFamily
//         onEscaped: keyCatcher.forceActiveFocus()
//     }
//
// Three things the parent owes it:
//
//   1. Stand down from the keyboard. keyCatcher has Keys.priority:
//      Keys.BeforeItem, so it sees every key first and would put the
//      operator's password into the filter. First line of Keys.onPressed:
//
//          if (setupForm.visible && setupForm.editing) return;
//
//      That covers typing, Enter (the fields submit themselves), Escape
//      (each field emits escaped()) and Tab, which walks the fields on its
//      own once nobody accepts it first.
//
//   2. Give it the keyboard on open. open() ends with
//      keyCatcher.forceActiveFocus(); when the form is up, call
//      setupForm.focusFirstField() instead.
//
//   3. Forget the password on close. close() should call setupForm.reset().
