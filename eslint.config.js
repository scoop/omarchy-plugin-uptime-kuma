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
];
