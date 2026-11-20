# Shared backend infrastructure

The Compose, Dockerfile, PostgreSQL provisioning engine, migration orchestration, recovery fencing and proof publisher, health verifier, release/check workflows, central hook and infra tests in shared-infra.sha256 must remain byte-for-byte identical in both apps. Run `sh Scripts/check-shared-infra.sh`; backend CI runs the same check.

App-specific fields live in Backend/deploy/app.json and the environment examples. Actual domain migrations, SQL adapters and PowerSync queries remain app-specific. Both data databases and their separate PowerSync storage databases use Herman's existing PostgreSQL server on platform-db. There is no per-app PostgreSQL service or separate cluster.

Preserve deployed migration journals. Do not rename old migrations or point tests at production. The common deployment code never changes shared WAL settings, restarts PostgreSQL or imports source production data. The matching host Compose/registry/hooks require an operator-reviewed deploy-core release before API_DEPLOY_CONTRACT=shared-backend-v1 can enable webhook delivery. See Backend/deploy/README.md for provisioning, backup and rollout order.
