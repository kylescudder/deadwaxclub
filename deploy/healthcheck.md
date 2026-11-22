# Container health contract

The application image owns its Docker `HEALTHCHECK`, including its command and
retry timings. Production Compose inherits it. This keeps health probes versioned
with the routes and runtime tools they check, instead of leaving an older host
probe active after an application release.

- `Site/Dockerfile`: `http://127.0.0.1:8080/healthz`.
- `Backend/Dockerfile`: `http://127.0.0.1:3147/health/live`.

Probes are bounded, unauthenticated loopback requests with no business-data writes.
Static sites use a dedicated `/healthz` response. API probes keep the service's
existing health semantics; they do not query a voting or other business endpoint.
Deployment acceptance still checks real pages, assets, revision and application
behavior before deploy-core acknowledges the release. Receiver and database
container probes remain separate.
