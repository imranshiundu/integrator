# CI/CD Pipeline — integrator

A single pipeline, four sequential gates, for the i-love-shopping e-commerce
platform. `.github/workflows/pipeline.yml` runs on GitHub Actions and is Gitea
Actions compatible (enable an act runner on gitea.kood.tech and set
`TARGET_REPO=imranshiundu/i-love-shopping3`).

Only code that passes every gate is delivered.

## Stage 1 — Build & Test

Goes from source to deployable artifact with a quality gate in between.

- Checks out the target repo at a recorded revision — every later stage pins
  that exact SHA, never "whatever master is now".
- Build environment: Java 21 (Temurin) with Maven cache, Node 20 with npm
  cache — the same images every run, so "works on my machine" disappears.
- Compilation + bundling: `./mvnw -B -ntp verify` builds both API artifact
  and the interface (`npm ci && npm run build` produces the standalone
  Next.js build).
- Test execution: 96 unit/API/security tests in the conventional phase,
  followed by the containerized user-flow suite that boots real PostgreSQL,
  Redis and RabbitMQ and drives a shopper through HTTP: anonymous browse,
  blocked foreign-order reads, register → login → cart → checkout → order,
  403 on admin routes.
- Failure handling: the job stops on the first failing test but still
  uploads reports (see `if: always()`), so evidence exists precisely when
  you need it.
- Test reporting: per-suite table (tests/failures/errors/skipped) is written
  into the run summary, and raw surefire/failsafe reports are uploaded as
  artifacts — that is the running quality record reviewers can diff over time.

## Stage 2 — Security & Dependency Scan

Hunts vulnerabilities, exposed secrets and risky dependencies before they
ship. All three scanners gate the pipeline independently.

| Gate | Tool | Finds | Blocks on |
|---|---|---|---|
| Secrets in history | gitleaks (full git history) | API keys, tokens, private keys, passwords with high entropy | any finding not on the documented allowlist (`i-love-shopping/.gitleaks.toml`) |
| Dependency CVEs | trivy, offline scan | CRITICAL/HIGH vulnerabilities with a fix available | the jar's embedded dependency jars + the npm lockfile |
| Static analysis (SAST) | SpotBugs (effort=Max, threshold=High) | insecure patterns: SQL/XSS risk, static-state races, weak RNG, bad crypto use | any high-severity bug |

The scan runs on the **built artifact**: the Spring Boot fat jar embeds every
dependency under `BOOT-INF/lib`; extracting them gives trivy a complete,
accurate view with zero network resolution (MAVEN Central frequently 429s CI
runners for pom/BOM expansion, so we never make those calls).

Example of the gate earning its keep: on day one it blew the whistle on
`next@14.2.35` — CVE-2026-75604, an unauthenticated RCE with fixes only on
the 15.5/16 lines. The storefront was upgraded, the gate cleared, and two
more variants of PostCSS and Toaster fixes stopped a real downgrade path.

## Stage 3 — Database Migration

The platform uses Flyway already; the pipeline promotes it to a gate.

- Detection: lists every `backend/src/main/resources/db/migration/*` file in
  execution order before touching anything.
- Validation: applies them all to a **clean, throwaway Postgres 16** service
  container on the job network, then runs `migrate` again — the second run
  must print "No migrations found" / "up to date" (idempotence check), and
  `flyway validate` passes.
- Execution on a real deployment: `scripts/migrate.sh` performs backup →
  dry-run on a scratch database → apply-at-restart → verify.
- Backup creation: `scripts/backup-db.sh` writes a compressed `pg_dump`
  before anything changes and verifies the backup restores into a scratch
  database. A backup that has never been restored isn't a backup.
- Rollback: `scripts/rollback.sh` (see below).

## Stage 4 — Core Delivery

Tested, scanned, migration-ready code goes live.

- **Versioned artifacts**: the production Docker images are built from the
  target's compose file, tagged `iloveshopping/api:<sha7>` and
  `iloveshopping/frontend:<sha7>`, stored gzipped as runner artifacts — the
  exact bytes that can be restored later.
- **Deployment**: `scripts/deploy.sh` stops the app tier first (data stays),
  deploys with environment injected from the deployment environment (never
  baked into source — the API even refuses to boot without it), brings
  dependencies healthy, takes a verified database backup, applies pending
  migrations, then starts the new version.
- **Environment variable injection**: `(deploy.sh)` writes
  `docker/.env.deployment` from the exported pipeline secrets and passes it
  with `--env-file`, so secrets move through the environment, not source
  control.
- **Service restart automation**: dependencies in dependency order
  (DB/cache/queue healthy → app tier).
- **Validation**: `scripts/validate-deployment.sh` proves the deployment is
  real — API health, storefront responds, register, login, catalogue read,
  add-to-cart, guest checkout creates an order, the order row is visible in
  the live database. Non-zero exit → the pipeline red flags immediately.
- **Rollback trigger**: `./scripts/rollback.sh` restores the previous image
  tag plus the latest `pg_dump` backup, restarts, and re-runs the full
  validation. Nothing "should work" — it either validates or it errored.

## Remote delivery

Point the same flow at any reachable host by adding repository secrets:

`DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY` — the pipeline delivers over
SSH/SCP with the same script set. Local mode (no secrets) delivers inside
the runner and is used by default for review evidence.

## Review runbook

### Happy path (what just happened)

`git push` (or Actions → Run workflow) → watch `gh run watch`. All four
stages green with their artifacts attached to the run.

### Simulate a failing test (stage-1 gate)

```bash
# in the i-love-shopping checkout
sed -i 's/mat/abc/' backend/src/test/java/com/iloveshopping/security/SecurityTest.java
git commit -am "oops: break the security test on purpose" && git push github master
# then run the integrator pipeline — it dies in stage 1 with the test name
# in the summary, deploy never runs
gh workflow run pipeline.yml -R imranshiundu/integrator
git revert HEAD && git push github master     # fixed — next run is green again
```

### Simulate a security failure (stage-2 gate)

```bash
echo "apikey = dGhpcy1pcy1hLXJlYWwtcGVyb20tc2VjcmV0LWtleS1kZXN0aW5lZC10" >> docs/testing.md
git commit -am "demo: accidental secret" && git push github master
gh workflow run pipeline.yml -R imranshiundu/integrator
# gitleaks flags the high-entropy line; stage 1 passed, stage 2 blocks
git revert HEAD && git push github master     # gate satisfied again
```

### Database change + rollback

```bash
# in i-love-shopping: create backend/src/main/resources/db/migration/V21__demo_table.sql
echo "CREATE TABLE demo_pipeline_marker (id VARCHAR(36) PRIMARY KEY, note VARCHAR(100));" \
  > backend/src/main/resources/db/migration/V21__demo_table.sql
git commit -am "feat: demo table" && git push github master
# happy path runs stage 3 against a clean DB — the new table applies there.

# now break something else and show rollback:
./scripts/rollback.sh --compose docker/docker-compose.yml
# → restores the previous image tag + database backup, revalidates.
```

## Design decisions worth explaining

| Decision | Why |
|---|---|
| Pin every stage to the same target SHA | "gate 2 ran against gate 1's green commit" is a strong integrity guarantee |
| Scan the built jar, not the source tree | artifacts = what actually ships; and it dodges Maven Central's 429s |
| Fixed-port Testcontainers | loopback source ports can collide with random mapped ports under load |
| Secrets never from source | injected via `--env-file` at deploy time; the API refuses to boot without them |
| Backup verification | the backup-script restores into a scratch database before it calls itself a backup |
| `workflow_dispatch` input `target_ref` | lets you gate any branch/PR of the target without switching defaults |
