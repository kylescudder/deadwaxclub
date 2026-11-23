# Shared push registration core

The Swift files recorded in `shared-push-core.sha256` must remain byte-for-byte identical in every app:

- the registration core: `PushGatewayConfiguration`, `GatewayPushRegistrationTransport`, `PushRegistrationTransport` and `PushRegistrationLifecycle`;
- the adapters around it: `PushManager` (authorization, lifecycle wiring and the notification-center delegate), `PushRegistration` (the Keychain installation ID, the app API transport, transport selection and the system registrar) and `AuthClient+PushIdentity` (the push identity and the API's `/api/devices` calls).

`App/AppDelegate.swift`, which forwards APNs callbacks to `PushManager`, and the `SharedPushRegistrationLifecycleTests`, `SharedPushAdapterTests` and `SharedPushGatewayTests` test files are in `shared-ios-core.sha256`.

App-specific values live in `Notifications/PushAppConfiguration.swift`: the Keychain service and accessibility of the existing installation ID (changing them would register every device as a new installation), the fallback bundle ID, and `route(for:)`, which maps a tapped notification to a `NotificationCenter` post. App-only notification features, such as local reminders, stay outside this core.

Exactly one registration path is active: the shared gateway when `PUSH_GATEWAY_URL` is configured (`docs/push-gateway.md`), otherwise the app API. Registration and unregistration always use the signed-in account's current bearer token, and sign-out unregisters before the session is invalidated.

Run `sh Scripts/check-shared-push-core.sh` from any app. The iOS CI workflow runs the same command. When changing the core, apply the same files and refreshed checksum manifest to every app, compare them byte for byte, and run every iOS suite. Update the common regression tests in every app when behavior changes.
