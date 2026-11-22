# Shared backend infrastructure

The Compose, Dockerfile, PostgreSQL provisioning engine, migration orchestration, recovery fencing and proof publisher, health verifier, release/check workflows and infra tests in shared-infra.sha256 must remain byte-for-byte identical in both apps. Each app's `Backend/deploy/compose.yaml` may differ only in its `<project>-api` and `<project>-sync` service names; the check normalizes those before comparing. Run `sh Scripts/check-shared-infra.sh`; backend CI runs the same check.

App-specific fields live in Backend/deploy/app.json and the environment examples. Domain migrations and PowerSync streams remain app-specific. Both data databases and their separate PowerSync storage databases use Herman's existing PostgreSQL server on platform-db. There is no per-app PostgreSQL service or separate cluster.

Never edit or rename an applied migration, and never point tests at production. The common deployment code never changes shared WAL settings or restarts PostgreSQL. See Backend/deploy/README.md for provisioning, backup and release.
