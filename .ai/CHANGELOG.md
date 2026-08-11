# AI CHANGELOG

TEMPLATE_VERSION: existing-projects-v2

Append-only. Агент читает только последние релевантные записи.

## Формат рутинной задачи

`YYYY-MM-DD HH:MM | TASK-ID | AGENT | STATUS | краткий результат`

Files: только если были изменения.
Check: только если выполнялась проверка.
Risk: только если есть реальный риск.

---

## Формат критической задачи

`YYYY-MM-DD HH:MM | TASK-ID | AGENT | STATUS`

Result:
- краткий результат

Files:
- изменённые файлы

Checks:
- выполненные точечные проверки

Risks:
- важные риски или ограничения

Approvals:
- PLAN_APPROVED
- EXECUTION_APPROVED

---

## Entries

2026-08-10 | LOCAL-WORDPRESS-FIXTURE-DB | CODEX | CHECKPOINT_COMPLETE

Result:
- Created only the new Laragon database `wordpress_staging_fixture` and WordPress fixture at `D:\laragon\www\wordpress-staging-fixture.local`; updated the ignored fixture client config to actual local paths.

Files:
- Private fixture `deploy.config.ps1` and local fixture WordPress files outside the tracked repository.

Checks:
- Collision checks passed before writes; database has 12 WordPress tables; home/siteurl are the fixture URL; deploy config schema validation passed.

Risks:
- No hosts-file or virtual-host mapping was created. Remote staging DB, DB/full modes, and rollback remain untested.

Approvals:
- PLAN_APPROVED: YES (2026-08-10)
- EXECUTION_APPROVED: YES (2026-08-10)

2026-08-10 | STAGING-WORDPRESS-FIXTURE | CODEX | CHECKPOINT_COMPLETE

Result:
- Verified and retained the fresh WordPress staging site; bootstrapped private fixture commit `26a57c8`; installed the cPanel-compatible runner/policy; and completed a real preflight plus code-only smoke deployment.

Files:
- Private fixture files: `deploy.config.ps1`, `server.config.sh`, and local `wp-config.php`.
- Private staging runner/policy and artifact directories under `/home4/panchukw`.

Checks:
- Fixture config schema and runner POSIX syntax passed; staging preflight passed; code-only deployment passed; local/remote plugin SHA-256 matched; plugin is inactive; HTTPS returned 200.

Risks:
- Shared cPanel cannot provide administrator-owned runner isolation. PHP 7.4.33 is end-of-life. DB/full modes, a real site, and rollback remain untested.

Approvals:
- PLAN_APPROVED: YES (2026-08-10)
- EXECUTION_APPROVED: YES (2026-08-10)

2026-08-10 | STAGING-SSH-PREFLIGHT-SETUP | CODEX | CHECKPOINT_COMPLETE

Result:
- Created a dedicated local ed25519 key; its public half was imported and authorized in cPanel. Verified external SSH on official HOSTiQ virtual-hosting port 21098 and completed the approved read-only server inventory.

Files:
- `.ai/STATE.md`, `.ai/HANDOFF.md`, `.ai/CHANGELOG.md`.

Checks:
- TCP SSH on port 21098 reachable; authenticated SSH inventory completed. Git, PHP, WP-CLI, MySQL client, mysqldump, unzip, and rsync are available.

Risks:
- No server files, WordPress, database, Git checkout, or deployment runner were changed. cPanel compatibility with the administrator-owned runner model remains unproven.

Approvals:
- PLAN_APPROVED: YES (2026-08-10)
- EXECUTION_APPROVED: YES (2026-08-10)

2026-08-10 | DEPLOY-SAFETY-STAGES-1-5 | CODEX | CHECKPOINT_COMPLETE | Первично синхронизировано состояние существующего проекта; Codex сохранён главным, Claude назначен ревьюером.

Files: `.ai/STATE.md`, `.ai/CHANGELOG.md`, `.ai/HANDOFF.md`.
Check: commit `938e4ce`, ветка `codex/stages-1-5-safety` синхронизирована с origin; ранее пройдено 39 тестов.
Risk: R-026; ветка ещё не прошла независимый review и не объединена с main.

2026-08-10 | DEPLOY-SAFETY-STAGES-1-5 | CODEX | REVIEW_FIXES_COMPLETE | Закрыты review-пункты по LOCAL_URL, временным путям и проверке места после SQL-экспорта.

Files: `server-deploy.sh`, `deploy.ps1`, `tests/safety.Tests.ps1`, `tests/server-safety.smoke.sh`.
Check: 41 тест пройден, 0 ошибок; `git diff --check` пройден.
Risk: этап 6 и merge в main не выполнялись; требуется повторный независимый review Claude.

2026-08-10 | DEPLOY-REVIEW-FIXES-TRAP | CODEX | CHECKPOINT_COMPLETE | Закрыт обход cleanup trap через dot-segment в SQL_FILE/UPLOADS_ZIP/ARCHIVE_LISTING; добавлен поведенческий canary smoke-тест.

Files: `server-deploy.sh`, `tests/server-safety.smoke.sh`.
Check: 39 тестов пройдено, 0 ошибок; `git diff --check` пройден.
Risk: изменения не закоммичены; реальный сервер и production не использовались.

2026-08-10 | DEPLOY-REVIEW-FIXES-TRAP | CODEX | FINAL_CHECKPOINT | Добавлены поведенческие проверки LOCAL_URL и точечный regression guard для размера SQL-дампа; служебное состояние приведено в соответствие.

Files: `deploy.ps1`, `server-deploy.sh`, `tests/server-safety.smoke.sh`, `tests/safety.Tests.ps1`, `.ai/STATE.md`.
Check: 40 тестов пройдено, 0 ошибок; `git diff --check` пройден.
Risk: commit, push, merge, staging и production deploy не выполнялись.

2026-08-10 | DEPLOY-REVIEW-FIXES-TRAP | CODEX | COMMITTED | Scoped deployment safety fixes committed locally as `da13e48` on `codex/stages-1-5-review-fixes`.

Files: six scoped files from the final checkpoint.
Check: commit created successfully; no push, merge, staging environment, or production deploy.
Risk: local branch has not been pushed or merged.

2026-08-10 | DEPLOY-REVIEW-FIXES-TRAP | CODEX | DOCUMENTATION_COMMITTED | Project instructions, handoff, and accepted review limitations committed as `69ddc47`.

Files: `.ai/`, `AGENTS.md`, `CLAUDE.md`, `FIRST_RUN_INSTRUCTIONS.md`, `docs/RISKS-RU.md`.
Check: staged documentation diff passed `git diff --check`.
Risk: local branch has not been pushed or merged; main remains at the earlier prototype.

2026-08-10 | DEPLOY-REVIEW-FIXES-TRAP | CODEX | RISK_REGISTER_CLARIFIED | Уточнена запись R-018: структурная проверка дампа и `gzip -t` выполняются, но фактическая восстановимость backup не подтверждается.

Files: `docs/RISKS-RU.md`, `.ai/CHANGELOG.md`.
Check: `git diff --check`.
Risk: изменение не закоммичено и не опубликовано.

2026-08-10 | STAGING-DB-SMOKE | CODEX | CHECKPOINT_COMPLETE

Result:
- DB-only smoke deployment replaced only the isolated staging database from the local fixture; Git and uploads were skipped.

Checks:
- runner created non-empty backup `db-20260810-200530.sql.gz`; staging home/siteurl use HTTPS, WordPress has 25 tables, smoke plugin is inactive, and HTTPS returned 200.

Risks:
- staging users now come from the local fixture and no known WP-admin password was retained; rollback failure path remains untested.

2026-08-10 | STAGING-DB-SMOKE | CODEX | CORRECTION_BLOCKED

Result:
- Read-only prefix verification found local `wp_` versus active staging `kqSmtmoOH_`. The completed import added `wp_*` tables but did not replace the active staging WordPress tables; old WP credentials correctly remain valid.

Risk:
- The staging database now has an unused imported table family. No cleanup, deletion, or rerun was performed; remediation requires a revised critical plan and fresh double approval.

2026-08-10 | STAGING-DB-REMEDIATION-HOMEPAGE | CODEX | BLOCKED

Result:
- Local fixture received the homepage marker and was structurally inspected, but Windows MySQL emitted table names as `kqsmtmooh_` while active Linux staging requires `kqSmtmoOH_`.

Risk:
- Remote deploy was not run. A direct import would create another inactive table family; a revised SQL identifier-transformation plan and new approvals are required.

2026-08-10 | STAGING-DB-REMEDIATION-SQL-PREFIX | CODEX | CHECKPOINT_COMPLETE

Result:
- A private one-run SQL wrapper strictly transformed only quoted fixture table identifiers to the active staging case-sensitive prefix. It was removed after use and private config restored.
- DB-only runner deployment replaced the active staging table family, created backup `db-20260810-211841.sql.gz`, skipped Git/uploads, and made the public homepage marker visible.

Checks:
- exactly 12 active-prefix DROP targets; no source or legacy identifiers in asserted SQL; runner preflight passed.
- active table count 12, front page `Staging DB Smoke`, plugin inactive, HTTPS 200, marker present; restored private config validates.

Risks:
- 12 accidental inactive `wp_*` tables remain. The tool lacks a pre-import table-prefix/case compatibility guard; cleanup and permanent safety fix require separate critical tasks.

2026-08-10 | STAGING-DB-AFTERMATH-SAFETY | CODEX | HANDOFF_READY

Result:
- Added critical risk R-031 to `docs/RISKS-RU.md`: deploy does not reject local/remote WordPress table-prefix or case mismatch before DB import.
- Prepared a separate no-write task and handoff for the next chat.

Risk:
- 12 accidental inactive `wp_*` tables remain on staging; cleanup and the permanent safety guard both require new scoped plans and double approval.

2026-08-11 | STAGING-DB-AFTERMATH-SAFETY | CODEX | PLAN_UPDATED

Result:
- The approved plan now includes a unique homepage marker/version update before every staging deploy test and public marker verification afterward.

Status:
- Plan approved; execution authorization is still pending. No code, fixture homepage, or staging database was changed in this step.

2026-08-11 | STAGING-DB-AFTERMATH-SAFETY | CODEX | CHECKPOINT_COMPLETE

Result:
- Added the permanent prefix/case guard: local emitted SQL, client policy, active WordPress prefix, and incoming server SQL must agree before a DB import can proceed.
- Documented the unique homepage marker/version procedure for each approved staging DB deploy test.

Checks:
- Full suite: 43 passed, 0 failed; `git diff --check` passed.

Risk:
- R-031 remains in progress until the separate staging runner/private policy rollout. No staging deploy or database change occurred.

2026-08-11 | STAGING-PREFIX-GUARD-ROLLOUT | CODEX | CHECKPOINT_COMPLETE

Result:
- Published fixture commit 63b8908 and installed the runner plus private prefix policy on staging; no DB/import/full mode was run.

Checks:
- Fixture suite: 43 passed, 0 failed; HTTPS 200; remote policy `kqSmtmoOH_` confirmed.

Risk:
- Public marker is not visible because `deploy-smoke-plugin` is inactive; activation would require a separate scoped DB/write approval. The 12 inactive `wp_*` tables remain untouched.

2026-08-11 | STAGING-MARKER-ACTIVATION | CODEX | CHECKPOINT_COMPLETE

Result:
- Activated only `deploy-smoke-plugin` on staging; no DB import, rollback, or table cleanup was performed.

Checks:
- Plugin status active; HTTPS 200; marker `STAGING-PREFIX-GUARD-ROLLOUT-20260811` verified with cache-busting requests.

Risk:
- The 12 inactive `wp_*` tables remain untouched and require a separate critical task.

2026-08-11 | STAGING-DB-SQL-CASE-NORMALIZATION | CODEX | CHECKPOINT_COMPLETE

Result:
- Exported local Windows SQL, asserted exactly 12 source tables, normalized only quoted `kqsmtmooh_` identifiers to `kqSmtmoOH_`, and completed DB-only staging smoke.

Checks:
- Backup `db-20260811-170351.sql.gz`; active prefix `kqSmtmoOH_`; 14 active tables; 12 inactive `wp_*` tables retained; HTTPS 200 and DB marker verified.
- Negative wrong-prefix preflight rejected before DB actions.

Risk:
- Rollback testing and cleanup of inactive `wp_*` tables remain separate critical tasks. Stop before Claude review.

2026-08-11 | DEPLOY-SQL-CASE-NORMALIZATION-ROLLOUT | CODEX | IMPLEMENTED

Result:
- Added persistent deploy-time normalization for exactly 12 lower-case Windows table identifiers, limited to `kqsmtmooh_` to configured prefix, followed by final prefix validation.

Checks:
- Main and fixture suites: 45 passed, 0 failed; `git diff --check` passed.

Next:
- Commit/push the deploy-tool changes, then rerun the approved staging DB smoke before the next independent review.

Correction:
- The subsequent DB import restored the local `active_plugins` option, so `deploy-smoke-plugin` is currently inactive; the DB homepage marker remains publicly verified.
