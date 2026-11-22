# Shared Better Auth implementation

The files listed in shared-auth.sha256 are byte-for-byte identical in Diald and Deadwax: backend policy, auth tables, route allowlist, email delivery, native OAuth code exchange, native session/auth state, API transport, OAuth presentation, nonce handling and their common regression tests.

Run `sh Scripts/check-shared-auth.sh`. Both auth CI and iOS CI run it. Apply common edits and regenerated manifests to both repos together, compare the actual files, and run both native and backend suites.

App-specific values live in Backend/src/auth-app.ts and native Auth/AuthAppConfiguration.swift. These preserve branding, cookie prefixes, callback schemes, email budget locks, Keychain services, profile endpoints and each app's existing bootstrap failure presentation. Offline database queries, UI, API dispatch/error envelopes and domain-specific adapters stay local. The table extraction changes no database columns or migration history.

This alignment preserves existing sign-in methods and open signup. It does not introduce passkeys, OTP, magic links, an allowlist, a provider change, or a production deployment. Those require separate product work. Existing secrets and sessions retain their identifiers.
