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
- Private staging runner/policy and artifact directories under `/home/<cpanel-account>`.

Checks:
- Fixture config schema and runner POSIX syntax passed; staging preflight passed; code-only deployment passed; local/remote plugin SHA-256 matched; plugin is inactive; HTTPS returned 200.

Risks:
- Shared cPanel cannot provide administrator-owned runner isolation. PHP 7.4.33 is end-of-life. DB/full modes, a real site, and rollback remain untested.

Approvals:
- PLAN_APPROVED: YES (2026-08-10)
- EXECUTION_APPROVED: YES (2026-08-10)

2026-08-10 | STAGING-SSH-PREFLIGHT-SETUP | CODEX | CHECKPOINT_COMPLETE

Result:
- Created a dedicated local ed25519 key; its public half was imported and authorized in cPanel. Verified external SSH on the hosting provider's official virtual-hosting port <ssh-port> and completed the approved read-only server inventory.

Files:
- `.ai/STATE.md`, `.ai/HANDOFF.md`, `.ai/CHANGELOG.md`.

Checks:
- TCP SSH on port <ssh-port> reachable; authenticated SSH inventory completed. Git, PHP, WP-CLI, MySQL client, mysqldump, unzip, and rsync are available.

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
- Read-only prefix verification found local `wp_` versus active staging `<staging-prefix>`. The completed import added `wp_*` tables but did not replace the active staging WordPress tables; old WP credentials correctly remain valid.

Risk:
- The staging database now has an unused imported table family. No cleanup, deletion, or rerun was performed; remediation requires a revised critical plan and fresh double approval.

2026-08-10 | STAGING-DB-REMEDIATION-HOMEPAGE | CODEX | BLOCKED

Result:
- Local fixture received the homepage marker and was structurally inspected, but Windows MySQL emitted table names as `<staging-prefix-lowercased>` while active Linux staging requires `<staging-prefix>`.

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
- Fixture suite: 43 passed, 0 failed; HTTPS 200; remote policy `<staging-prefix>` confirmed.

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
- Exported local Windows SQL, asserted exactly 12 source tables, normalized only quoted `<staging-prefix-lowercased>` identifiers to `<staging-prefix>`, and completed DB-only staging smoke.

Checks:
- Backup `db-20260811-173734.sql.gz`; active prefix `<staging-prefix>`; 14 active tables; 12 inactive `wp_*` tables retained; marker `STAGING-DB-SMOKE-20260811-02` returned over HTTPS 200.
- Negative wrong-prefix preflight rejected before DB actions.

Risk:
- Rollback testing and cleanup of inactive `wp_*` tables remain separate critical tasks. Stop before Claude review.

2026-08-11 | DEPLOY-SQL-CASE-NORMALIZATION-ROLLOUT | CODEX | IMPLEMENTED

Result:
- Added persistent deploy-time normalization for exactly 12 lower-case Windows table identifiers, limited to `<staging-prefix-lowercased>` to configured prefix, followed by final prefix validation.

Checks:
- Main and fixture suites: 45 passed, 0 failed; `git diff --check` passed.

Next:
- Commit/push the deploy-tool changes, then rerun the approved staging DB smoke before the next independent review.

Correction:
- The subsequent DB import restored the local `active_plugins` option, so `deploy-smoke-plugin` is currently inactive; the DB homepage marker remains publicly verified.

2026-08-12 | DEPLOY-BIDIRECTIONAL-SYNC | CLAUDE (implementer by user assignment) | READY_FOR_REVIEW

Result:
- Added the pull direction (staging -> local) as `pull-db`, `pull-files`, and `pull-full` with `-DryRun`, `-Confirm`, and `-Mirror`, alongside the unchanged `code`, `db`, and `full` push modes.
- Pull is side-by-side by construction: it imports nothing, replaces no working file, and requires `LocalDatabaseTarget` to differ from `LocalDbName`, so a failed pull leaves the working local site untouched and needs no rollback.
- Downloaded artifacts are verified before use: gzip integrity via the recorded ISIZE, SQL structure, exact table count, table prefix, and an archive listing checked for traversal, symlinks, and denied paths before a single byte is extracted.
- `server-deploy.sh` gained `pull-db` and `pull-files` export modes that never import, never rotate backups, and never rewrite WordPress; production pull is refused there as well.
- `-Mirror` is defined by the contract but fail-closed: it refuses both without and with `AllowDestructiveLocalReplace`.

Files:
- `deploy.ps1`, `src/WordPressSshDeploy.psm1`, `server-deploy.sh`, `deploy.config.example.ps1`, `tests/pull.Tests.ps1` (new), `README.md`, `docs/DEVELOPMENT-PLAN-RU.md`, `docs/RISKS-RU.md`, `.ai/STATE.md`, `.ai/CHANGELOG.md`, `.ai/HANDOFF.md`.

Checks:
- Full suite: 107 passed, 0 failed; `git diff --check` clean; PowerShell syntax check over 7 files clean; `sh -n` clean for `server-deploy.sh` and both test shell scripts.
- No private hostname, account, path, database name, prefix, port, or credential in the working tree; private configs were never created or read.

Risk:
- The runner installed on staging does not know the pull modes yet, so no real pull is possible until it is reinstalled under a separate approval (R-032).
- Pull was verified only by local mock tests; the runner pull modes were checked statically and with `sh -n`, never executed (R-033).
- Activating a pulled copy stays manual (R-034). See R-035, R-036, R-037 for the remaining limitations.

Next:
- Independent Codex review of the branch, then integration. Staging, the local working database, commit, and push were not touched.

2026-08-12 | DEPLOY-BIDIRECTIONAL-SYNC-FULL-BRIDGE | CODEX | CHECKPOINT_COMPLETE

Result:
- Added explicit full-push and full-pull path lists, a separate protected archive with paired confirmations, and remote protected-file backup/replacement.
- Added `apply-pull` to back up the local database and configured pull paths, map the remote URL to the local URL, and atomically replace the verified workspace files.
- Updated the example configuration, README, and development plan.

Checks:
- Full Pester suite: 116 passed, 0 failed; PowerShell parsing passed; `sh -n server-deploy.sh` passed; `git diff --check` passed.

Risk:
- No commit, push, runner rollout, staging pull, or real local apply was executed. Site-specific full path lists and protected runner policy still require review and separate rollout approval.

Next:
- Stop for independent Claude review.

2026-08-13 | DEPLOY-BIDIRECTIONAL-SYNC-REVIEW-FIXES | CODEX | CHECKPOINT_COMPLETE

Result:
- Fixed full-mode server policy enforcement and blocked protected paths from ordinary sync.
- Added byte-preserving native SQL import, PS5.1-safe file rollback, partial-import DB restore, protected replacement restore handling, and apply-pull workspace revalidation.
- Updated pull activation documentation and added executable server smoke probes.

Checks:
- Full Pester suite: 124 passed, 0 failed; PowerShell parser checks passed; `sh -n` passed; `git diff --check` passed.
- Server smoke probes passed for full ordinary-path policy mismatch and protected ordinary-sync rejection.

Risk:
- Commit, push, runner rollout, staging pull, and real local apply remain intentionally unexecuted.

Next:
- Stop for independent read-only Claude review.

2026-08-13 | DEPLOY-BIDIRECTIONAL-SYNC-COMMIT-PUSH | CODEX | COMMITTED_PUSHED

Result:
- Independent Round3 review passed; commit `03d36eb` was pushed to `origin/main`.
- The worktree is clean and the remote `main` resolves to the pushed commit.

Checks:
- Pester 126/126, PowerShell parser, shell syntax, server smoke, and `git diff --check` had already passed before commit.

Risk:
- Protected runner rollout, staging pull, and real local apply remain intentionally unexecuted.

Next:
- Plan and approve those live actions separately.

2026-08-13 | DEPLOY-BIDIRECTIONAL-SYNC-REVIEW-FIXES-ROUND2 | CODEX | CHECKPOINT_COMPLETE

Result:
- Fixed separate ordinary/full path policy handling and made the server protected-path list authoritative.
- Made local SQL import byte-safe, added local prefix validation, and limited rollback to imports that actually started.
- Added protected transient cleanup/recovery, moved protected replacement after WordPress cleanup, and extended protected-path containment checks to both sync lists.

Checks:
- Full Pester suite: 125 passed, 0 failed; PowerShell parser checks passed; `sh -n` passed; server smoke probes passed; `git diff --check` passed.

Risk:
- Commit, push, runner rollout, staging pull, and real local apply remain intentionally unexecuted.

Next:
- Stop for independent read-only Claude review.

2026-08-13 | DEPLOY-BIDIRECTIONAL-SYNC-REVIEW-FIXES-ROUND3 | CODEX | CHECKPOINT_COMPLETE

Result:
- Fixed Windows PowerShell SQL stdin handling by forcing a no-preamble encoding before StandardInput creation and restoring the caller setting afterward.
- Made local WordPress table-prefix validation explicitly ordinal and added regression coverage for both defects.
- Added Git exclusions for local pull workspaces and Codex remote attachments before the commit checkpoint.

Checks:
- Full Pester suite: 126 passed, 0 failed; PowerShell parser checks passed; `sh -n` passed; server smoke probes passed; `git diff --check` passed.

Risk:
- Commit, push, runner rollout, staging pull, and real local apply remain intentionally unexecuted.

Next:
- Stop for independent read-only Claude review.
