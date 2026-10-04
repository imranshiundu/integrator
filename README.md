# integrator

CI/CD pipeline for [i-love-shopping](https://gitea.kood.tech/imranshiundu/i-love-shopping3) — a B2C e-commerce platform (Spring Boot 3 API + Next.js 14 storefront + PostgreSQL/Redis/RabbitMQ).

The pipeline implements the four required stages as sequential gates on every push to `master`:

```
push ─► 1. build-test ──► 2. security-scan ──► 3. db-migration ──► 4. deliver
         (Java+Node)      (SAST/secrets/       (validate on a       (Docker images,
          unit+flow         dependencies)        clean Postgres,      versioned
          tests)                                 backup-before-       artifacts,
                                                apply semantics)     deploy, validate,
                                                                     rollback)
```

Only code that passes every gate is delivered.

## Pipeline stages

| # | Stage | What happens | Fails the pipeline when |
|---|-------|--------------|------------------------|
| 1 | **Build and Test** | Checks out the target repo, builds the API (Java 21) and the storefront (Node 20), runs the full test suite: 96 unit/API/security tests + the containerized user-flow integration tests, then a production frontend build. Test reports are uploaded as artifacts and summarised in the job output. | any test fails, compilation fails, or the frontend build fails |
| 2 | **Security and Dependency Scan** | [gitleaks](https://github.com/gitleaks/gitleaks) scans the full git history for secrets, [Trivy](https://trivy.dev) scans dependencies (JARs + npm lockfile) for known CVEs, [SpotBugs](https://spotbugs.github.io) statically analyses the compiled API for insecure patterns. | a secret is detected, or a CRITICAL/HIGH vulnerability with a fix is found, or SpotBugs reports a bug |
| 3 | **Database Migration** | Every Flyway migration in the target repo is applied to a **clean, throwaway Postgres 16** container — validating syntax, ordering and applicability (a migration that can't run on a fresh schema never reaches production). The deployment script additionally takes a `pg_dump` backup before touching any real database. | any migration fails or leaves the schema in a non-repeatable state |
| 4 | **Core Delivery** | Builds the production Docker images (`api`, `frontend`) from the target repo's Dockerfiles, stores them as **versioned artifacts** tagged with the commit SHA, delivers them to the target (compose up, environment variables injected from the deployment environment — never from source), runs the deployment validation (health, DB round-trip, critical user flows), and supports one-command rollback to the previous artifact + database backup. | deployment validation fails — which also triggers the documented rollback path |

## Repository layout

```
.github/workflows/pipeline.yml   # the 4-stage pipeline (GitHub Actions / Gitea Actions compatible)
scripts/
  migrate.sh                      # backup -> validate -> apply migrations (deploy target)
  backup-db.sh                    # pg_dump before any migration on a real database
  deploy.sh                       # deliver versioned artifacts, inject env, restart services
  validate-deployment.sh          # health, DB connectivity, critical user flows
  rollback.sh                     # previous image tag + latest database backup
docs/pipeline.md                  # stage-by-stage details + the review demo runbook
```

## Setup

The pipeline runs on **GitHub Actions** (this repo) and is **Gitea Actions compatible** (the same file runs on `gitea.kood.tech` when an act runner is enabled — set `TARGET_REPO` to `imranshiundu/i-love-shopping3` there).

1. Push to `master` (or run **Actions → CI/CD pipeline → Run workflow**) — the run builds and gates the target repo at its latest `master`.
2. Optional deployment target: set the repository secrets `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY` and the pipeline delivers over SSH. Without them, stage 4 performs the local Docker delivery (build, version, store, validate) — enough to demonstrate the full flow end to end.
3. Find every run's artifacts (test reports, security reports, versioned Docker images) attached to the workflow run.

## Usage

```bash
# trigger the full pipeline manually, optionally pinning the target
gh workflow run pipeline.yml -f target_ref=<sha-or-branch>

# watch it
gh run watch

# rollback the deployment target to the previous version + database backup
./scripts/rollback.sh            # on the target host, or via SSH
```

The review runbook (failure simulation, happy path, database change, rollback) lives in [docs/pipeline.md](docs/pipeline.md).
