# Shared push registration core

The four Swift files recorded in `shared-push-core.sha256` must remain byte-for-byte identical in Diald and Deadwax. `SharedPushRegistrationLifecycleTests.swift` is also identical in both test targets, with conditional module imports.

App-specific permission handling, Keychain storage, logging, auth and API fallback adapters remain outside this core.

Run `sh Scripts/check-shared-push-core.sh` from either repository. The iOS CI workflow runs the same command. When changing the core, apply the same files and refreshed checksum manifest to both repositories, compare them byte for byte, and run both iOS suites. Update the common regression tests in both repos when behavior changes.
