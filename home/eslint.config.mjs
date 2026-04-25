// Canonical flat ESLint config. Symlinked into each JS-containing repo
// (see ~/.claude/CLAUDE.md). Zero-dependency on purpose: ESLint built-in
// rules only, no plugin imports, so the symlink resolves cleanly from the
// pre-commit managed env without a ~/node_modules install.
//
// Per-repo tuning: add an `eslint.local.config.mjs` in the repo root and
// import/compose it here if you grow to need plugins (e.g. typescript-
// eslint, eslint-plugin-promise). Keep this file plugin-free.

export default [
  {
    files: ["**/*.{js,jsx,mjs,cjs,ts,tsx}"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: {
        // Node.js built-ins used across the Lambdas in this workspace.
        console: "readonly",
        process: "readonly",
        Buffer: "readonly",
        URL: "readonly",
        URLSearchParams: "readonly",
        setTimeout: "readonly",
        clearTimeout: "readonly",
        setInterval: "readonly",
        clearInterval: "readonly",
        setImmediate: "readonly",
        clearImmediate: "readonly",
        global: "readonly",
        globalThis: "readonly",
        // Undici-in-Node.js fetch surface (Node 18+).
        fetch: "readonly",
        Response: "readonly",
        Request: "readonly",
        Headers: "readonly",
        AbortController: "readonly",
        AbortSignal: "readonly",
      },
    },
    rules: {
      // --- correctness ---
      "no-undef": "error",
      "no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_", caughtErrorsIgnorePattern: "^_" },
      ],
      "no-const-assign": "error",
      "no-dupe-keys": "error",
      "no-dupe-args": "error",
      "no-dupe-else-if": "error",
      "no-duplicate-case": "error",
      "no-unreachable": "error",
      "no-fallthrough": "error",
      "no-empty": ["error", { allowEmptyCatch: true }],
      "no-constant-condition": ["error", { checkLoops: false }],
      "no-self-assign": "error",
      "no-self-compare": "error",
      "use-isnan": "error",
      "valid-typeof": "error",

      // --- async / await footguns ---
      "require-await": "warn",
      "no-async-promise-executor": "error",
      "no-promise-executor-return": "error",
      "no-return-await": "warn",

      // --- style of substance (not cosmetic — Prettier handles those) ---
      eqeqeq: ["error", "always", { null: "ignore" }],
      "no-var": "error",
      "prefer-const": "error",
      "no-throw-literal": "error",
      "no-useless-catch": "error",
      "no-useless-return": "error",
    },
  },
];
