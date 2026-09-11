import js from "@eslint/js";

export default [
    js.configs.recommended,
    {
        files: ["**/*.js"],
        languageOptions: {
            ecmaVersion: 2022,
            sourceType: "module",
            globals: { console: "readonly", module: "writable" },
        },
        rules: {
            // Optional catch binding would be the tidy fix for an unused error,
            // but these files also run in QML's JavaScript engine, whose support
            // for it we have not verified. Naming the binding and leaving it
            // unread is the portable form, so it is not reported.
            "no-unused-vars": ["error", { caughtErrors: "none" }],
        },
    },
    {
        // The tests run under Bun rather than in QML, so they have a runtime
        // the files in src/ deliberately do not: these are the globals that
        // environment actually provides, declared rather than silenced.
        files: ["test/**/*.js"],
        languageOptions: {
            globals: {
                Bun: "readonly",
                process: "readonly",
                URL: "readonly",
                Response: "readonly",
                TextEncoder: "readonly",
                setTimeout: "readonly",
            },
        },
    },
];
