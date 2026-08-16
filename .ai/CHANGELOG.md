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
- Created only a new local fixture database and WordPress fixture at private local paths; updated the ignored fixture client configuration.

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
- Superseded by MULTISITE-FOUNDATION-REVIEW-FIXES: download remains side-by-side, while a separate confirmed apply backs up and replaces the one working local WordPress copy with rollback on failure.
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

2026-08-14 | SDOUTDOORLIVING-ROOT-WRAPPER-REVIEW-ROUND2 | CODEX | READY_FOR_REVIEW

Result:
- Made root UID detection fail closed in the wrapper and server runner; wrapper no longer inherits `SCP_BIN` from the SSH environment.
- Released the deploy lock before ownership restoration, delayed successful completion output until cleanup succeeds, and restored ownership for WP-CLI runtime files.
- Added a behavioral fake-root smoke test for root policy, runtime ownership, failed chown, and lock cleanup.

Checks:
- Full Pester: 145/145.
- Shell syntax, server safety, database rollback, root wrapper, root ownership smoke, and `git diff --check` passed.

Risk:
- No live VPS action, commit, push, merge, deploy, pull, rollback, or cleanup was performed.

Next:
- Stop for independent read-only Claude review before commit/push or VPS rollout.

2026-08-14 | SDOUTDOORLIVING-ROOT-WRAPPER-LOCK-ORDER | CODEX | READY_FOR_REVIEW

Result:
- Kept the deploy lock through root ownership restoration and released it after the restore attempt regardless of success.
- Extended the fake-root smoke to fail if chown starts after lock release, while preserving failed-chown lock cleanup coverage.

Checks:
- Full Pester: 145/145.
- Root ownership smoke and `git diff --check` passed.

Risk:
- No live VPS action, commit, push, merge, deploy, pull, rollback, or cleanup was performed.

Next:
- Stop for independent read-only Claude review before commit/push or VPS rollout.

2026-08-14 | SDOUTDOORLIVING-ROOT-WRAPPER-REVIEW-FIXES | CODEX | READY_FOR_REVIEW

Result:
- Implemented the generic root SSH forced-command wrapper with fixed runner/tmp protocol, strict command parsing, scp containment, and no interactive shell.
- Added profile-scoped legacy scp selection, wrapper-safe configuration validation, and root-runner owner/group restoration after replacement.
- Added adversarial wrapper smoke coverage and generic documentation/examples.

Checks:
- Full Pester: 144/144.
- Shell syntax, server safety smoke, root wrapper smoke, and `git diff --check` passed.

Risk:
- No live VPS action, commit, push, merge, deploy, pull, rollback, or cleanup was performed.

Next:
- Stop for independent read-only Claude review.

2026-08-13 | MULTISITE-FOUNDATION-REVIEW-FIXES | CODEX | READY_FOR_REVIEW

Result:
- Reconciled `apply-pull` with one working local WordPress copy: `LocalDbName`, WP-CLI URL mapping, backup and rollback now target the same database.
- Added manifest verification for extracted SQL and files, a shared backup-retention planner that retains the newest group, preserved-local-core checks, and guarded profile/menu/site-Git behavior.
- Replaced tracked real infrastructure values in AI metadata with non-sensitive descriptions.

Files:
- `deploy.ps1`, `src/WordPressSshDeploy.psm1`, `backup-cleanup.ps1`, `site-git.ps1`, `menu.ps1`, `deploy.config.example.ps1`, `README.md`, `docs/RISKS-RU.md`, `tests/pull.Tests.ps1`, `.ai/STATE.md`, `.ai/CHANGELOG.md`.

Checks:
- Full Pester: 138 passed, 0 failed; PowerShell parser and `git diff --check` passed.

Risks:
- No live SSH, pull/apply, server change, database import/rollback, commit, push or merge was performed. Manual restoration after a later local change remains a follow-up command.

Approvals:
- PLAN_APPROVED (2026-08-13)
- EXECUTION_APPROVED (2026-08-13, local implementation and tests only)

2026-08-13 | MULTISITE-FOUNDATION-REVIEW-FIXES | CODEX | REVIEW_FOLLOWUP_COMPLETE

Result:
- Closed reviewer P2 sanitation and private-profile migration findings: public metadata was further redacted, and legacy `LocalDatabaseTarget` was removed from ignored private profiles.
- Existing profiles now fail closed until their operator explicitly supplies `SiteId`, `CodeRepositoryPath` and `WorkRoot`; no paths or repositories were guessed.

Checks:
- Full Pester: 139 passed, 0 failed; PowerShell parser and `git diff --check` passed.

Risk:
- The removed historical values exist in the parent commit and are not rewritten without a separate history-rewrite decision. No new sensitive values are added by the current public diff.

2026-08-13 | MULTISITE-FOUNDATION-COMMIT-PUSH | CODEX | APPROVED_FOR_EXECUTION

Approvals:
- PLAN_APPROVED (2026-08-13)
- EXECUTION_APPROVED (2026-08-13)

Scope:
- Commit and push the reviewed multisite foundation and review-follow-up diff to `main`; no server, database or deploy action.

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

2026-08-13 | STAGING-PULL-LOCAL-APPLY-VISIBLE | CODEX | READY_FOR_REVIEW

Result:
- Fixed pull DB export to select only active prefix tables and added GNU tar long-name metadata handling.
- Completed verified staging pull and local apply with local DB/files backup.
- Local homepage marker `STAGING-PULL-FULL-VERIFY-20260813-01` is visible over HTTP 200; screenshot saved outside the repository.

Checks:
- Full Pester suite reached 127/127 before the final backup-path fix; pull suite passed 70/70 after the final fix.
- SQL artifact: 14 active tables, no inactive `wp_*` tables; local prefix and URL verified.

Risk:
- Changes are uncommitted; independent Claude review is the next gate. No commit, push, merge, rollback, or production action was performed.

Next:
- Stop for independent read-only Claude review.

2026-08-13 | PORTFOLIO-PRODUCTION-READONLY-PULL | CODEX | READY_FOR_REVIEW

Result:
- Added explicit two-factor production read-only pull gating and a separate portfolio production runner policy.
- Pulled portfolio DB/files into `.pull\20260813-194801` without changing production or the working local site.
- Fixed UTF-8 tar header decoding for Cyrillic media filenames.

Checks:
- The expected SQL table set and selected-file count matched between remote export and local workspace.
- Full Pester: 133/133; shell syntax and `git diff --check` passed.
- Remote runner/config backup retained in the private server runtime.

Risk:
- Artifacts are verified but not applied locally; no commit, push, merge, production deploy, rollback, or Claude review performed.

Next:
- Stop for independent read-only Claude review; local apply needs a separate approved task.

2026-08-13 | PORTFOLIO-LOCAL-FULL-APPLY | CODEX | READY_FOR_REVIEW

Result:
- Applied the verified production pull to a private side-by-side local target with a separate local database and pre-apply database/files backups.
- Local URL mapping completed; all 9,151 pulled files and uploads are present, with the required 16 standard WordPress root/core files restored from the local bootstrap template because the production sync paths omit them.

Checks:
- Local HTTP 200 and visible portfolio homepage; screenshot saved outside the repository.
- Local `home/siteurl` pointed to the private local URL; active configured-prefix table count matched; this historical run used the superseded separate-target design.
- Full Pester: 133/133; shell syntax and `git diff --check` passed.

Risk:
- Production was not modified. Repository changes remain uncommitted; no push, merge, or Claude review performed.

Next:
- Stop for independent read-only Claude review.

2026-08-15 | SITE-A-PULL-DB-WPCLI-FIX | CODEX | CHECKPOINT_COMPLETE

Result:
- Switched the production pull backup path to WP-CLI db export after mysqldump authentication failed on the host.
- Updated and installed the runner, completed a verified full pull, and applied the database plus themes/plugins/uploads to the single local test copy.
- Local prefix and home/siteurl were verified; the production site remained read-only.

Checks:
- Full Pester: 146/146; direct pull-db smoke and git diff --check passed.
- 18 active tables verified, HTTP 200, 892 uploads present, and the local homepage was captured in a browser screenshot.

Risk:
- Code and metadata are uncommitted. No commit, push, merge, remote cleanup, rollback, or Claude review performed.

Next:
- Stop for independent read-only Claude review before commit/push.
2026-08-13 | MULTISITE-FOUNDATION-MVP | CODEX | READY_FOR_REVIEW

Result:
- Added multi-site profile isolation (`SiteId`, `CodeRepositoryPath`, `WorkRoot`), pull path classes, profile-bound manifests with SHA-256 verification, JSONL logs, and backup retention.
- Added guarded site Git commands, read-only verify, backup cleanup preview, and a PowerShell management menu; deploy-tool Git is no longer the site code repository.
- Updated example config, README, and pull regression tests.

Checks:
- Full Pester: 135/135; PowerShell parser/import passed; Git Bash `sh -n` passed; `git diff --check` passed.
- No live pull/deploy, SSH, database import, commit, push, merge, or independent review performed.

Next:
- Stop for independent read-only Claude review.

2026-08-15 | MULTISITE-PROFILE-ISOLATION-ONBOARDING | CODEX | CHECKPOINT_COMPLETE | Добавлены явный выбор профиля, межпрофильная изоляция SiteId/путей/БД, D:-ориентированный private runtime, read-only onboarding preflight и pull sanity-порог таблиц; 149/149 тестов.

2026-08-15 | MULTISITE-PROFILE-ISOLATION-P3-FIXES | CODEX | HANDOFF_READY

Result:
- Создан компактный handoff с полным контекстом ROUND4 и всеми оставшимися P2/P3 пунктами review.

Files:
- `.ai/HANDOFF.md`
- `.ai/STATE.md`

Checks:
- Безопасная загрузка профилей ранее подтверждена WinPS 5.1: 154/154 и configuration 35/35.

Risks:
- Новая critical-задача ожидала отдельные двойные подтверждения; commit/push и live-действия не выполнялись.

2026-08-15 | MULTISITE-PROFILE-ISOLATION-REVIEW-FIXES-ROUND4 | CODEX | CHECKPOINT_COMPLETE

Result:
- Исправлена совместимость безопасной загрузки профилей с Windows PowerShell 5.1: удалён PowerShell 7-only аргумент у `SafeGetValue()`.
- Диагностика ошибок безопасного чтения больше не маскируется под dynamic expressions.
- Добавлен regression-тест для строк, массивов, bool и вложенной hashtable.

Files:
- `src/WordPressSshDeploy.psm1`
- `tests/configuration.Tests.ps1`
- `.ai/STATE.md`
- `.ai/CHANGELOG.md`

Checks:
- Pester 154/154; configuration 35/35; parser, `sh -n`, `git diff --check` — PASS.

Risks:
- Старые root-профили не удалялись; commit/push и live-действия не выполнялись.

2026-08-15 18:46 | MULTISITE-PROFILE-ISOLATION-REVIEW-FIXES-ROUND3 | CODEX | CHECKPOINT_COMPLETE

Result:
- Убран dot-sourcing обнаруженных профилей: изоляция читает только безопасное значение `HashtableAst.SafeGetValue()` после статической проверки единственного присваивания `$DeployConfig`.
- Добавлены regression-тесты против редиректа в файл и изменения `$env`.

Files:
- `src/WordPressSshDeploy.psm1`
- `tests/configuration.Tests.ps1`
- `.ai/STATE.md`
- `.ai/CHANGELOG.md`

Checks:
- Pester 153/153; configuration 34/34; parser, `sh -n`, `git diff --check` — PASS.

Risks:
- Старые root-профили намеренно не удалялись; commit/push и live-действия не выполнялись.

Approvals:
- Plan and execution approved by user.
- PLAN_APPROVED
- EXECUTION_APPROVED

2026-08-15 | MULTISITE-PROFILE-ISOLATION-REVIEW-FIXES | CODEX | CHECKPOINT_COMPLETE

Result:
- Closed the P1 profile-isolation gap by making canonical scope explicit and checking the selected catalog, tool-root private profiles, and D:\wordpress-ssh-deploy\profiles together.
- Added split-catalog collision coverage, filtered non-profile tool scripts, ignored local .claude settings, and raised the pull sanity floor to 12 WordPress core tables.

Checks:
- Full Pester 150/150; configuration tests 31/31; PowerShell parser clean; Git Bash shell syntax clean; git diff --check clean.
- Read-only D onboarding fails closed on the two stale root duplicates; no server or database was contacted.

Next:
- Stop for independent read-only Claude review; do not commit/push or run live actions.

2026-08-15 | MULTISITE-PROFILE-ISOLATION-REVIEW-FIXES-ROUND2 | CODEX | CHECKPOINT_COMPLETE

Result:
- Sanitized the current metadata additions to generic site labels and verification values.
- Added static data-only validation before profile dot-sourcing; arbitrary command- or method-bearing `.ps1` files are rejected.
- Added a regression test proving command output cannot pollute isolation errors.

Checks:
- Full Pester 151/151; configuration tests 32/32; PowerShell parser clean; Git Bash shell syntax clean; git diff --check clean.
- No server, database, commit, push, or live action performed.

Next:
- Stop for independent read-only Claude review.

2026-08-15 | SITE-A-LOCAL-WORDPRESS-BOOTSTRAP | CODEX | CHECKPOINT_COMPLETE

Result:
- Created one empty local site database and a clean local WordPress core target in the separate site Git repository.
- Created a private local `wp-config.php`, separate work root, and profile mapping for `SiteId`, code repository, local target, and backups.
- Added the site-repository ignore policy so core, runtime content, secrets, and deployment artifacts cannot be committed as site code.

Checks:
- Private profile validation passed; local database table count is 0.
- Generated `wp-config.php` passed PHP syntax validation; Laragon returned the expected WordPress-install redirect.
- Git-ignore verification passed; only the intentional baseline `.gitignore` is uncommitted in the separate site repository.

Risk:
- No VPS, SSH, remote runner, pull, deploy, SQL import, rollback, commit, or push action was performed.

Next:
- Resume the separately approved root-wrapper VPS rollout; do not run pull or deploy.

2026-08-15 | MULTISITE-PROFILE-ISOLATION-P3-FIXES | CODEX | READY_FOR_REVIEW

Result:
- Closed the remaining metadata and P3 findings: append-only metadata repair, null `EndBlock` handling, literal-only AST validation, explicit profile-directory wiring, exact pull table-count plans, variable rename, README contract, and regression coverage.

Files:
- `src/WordPressSshDeploy.psm1`, entry-point `.ps1` files, `README.md`, `deploy.config.example.ps1`, `tests/configuration.Tests.ps1`, `tests/pull.Tests.ps1`, `.ai/STATE.md`, `.ai/CHANGELOG.md`, `.ai/HANDOFF.md`

Checks:
- WinPS 5.1 Pester: 159/159; PowerShell parser, Git Bash `sh -n`, and `git diff --check` passed.

Risks:
- Changes remain uncommitted in a detached worktree; old root profiles remain intentionally untouched. No live action was performed.

Next:
- Stop for fresh independent read-only Claude review before commit/push or any VPS/DB action.

2026-08-15 | MULTISITE-PROFILE-ISOLATION-P3-FOLLOWUP | CODEX | READY_FOR_REVIEW

Result:
- Удалён мёртвый `MinimumPullDbTableCount` из схемы; pull-enabled профили используют только обязательный exact `ExpectedPullDbTableCount`.
- README дополнен миграцией существующих private-профилей; fail-closed validation теперь явно отклоняет устаревший ключ.

Files:
- `src/WordPressSshDeploy.psm1`
- `tests/pull.Tests.ps1`
- `README.md`
- `.ai/STATE.md`
- `.ai/HANDOFF.md`
- `.ai/CHANGELOG.md`

Checks:
- WinPS 5.1 Pester: 160/160; obsolete-key regression, parser, Git Bash `sh -n`, and `git diff --check` passed.

Risks:
- Existing private profiles were not edited; they require a separate local migration of `ExpectedPullDbTableCount` before pull use. No live action, commit, push, or merge was performed.

Next:
- Stop for fresh independent read-only Claude review.

2026-08-15 | MULTISITE-PROFILE-ISOLATION-P3-FOLLOWUP-FIX | CLAUDE | READY_FOR_REVIEW

Result:
- Устранена вырожденность regression-теста exact `ExpectedPullDbTableCount`: фикстура pull-профиля теперь использует 17 таблиц против push-значения 12, поэтому подмена источника количества больше не проходит незамеченной.
- Добавлены сценарии на мутацию только exact-count и только внутреннего `MinimumTableCount`, на отказ при 16 и 18 таблицах и на раздельность push- и pull-значений.
- Runtime-код и схема не изменялись: exact-проверка не ослаблена, `MinimumPullDbTableCount` в схему не возвращён.

Files:
- `tests/pull.Tests.ps1`
- `.ai/STATE.md`
- `.ai/HANDOFF.md`
- `.ai/CHANGELOG.md`

Checks:
- WinPS 5.1 full Pester: 164/164; pull 87/87; configuration 39/39; parser, `git diff --check` — PASS.
- Mutation-proof: подмена плана на push-count даёт 3 падения, hardcode внутреннего минимума — 1, отключение exact-проверки — 4, возврат устаревшего ключа в схему — 1. До правки первые две мутации не выявлялись.

Risks:
- Приватные профили не редактировались и по-прежнему требуют отдельной локальной миграции. Live-действий, commit, push и merge не выполнялось.

Approvals:
- Узкая правка только тестов, явно назначенная пользователем CLAUDE; CODEX сохраняет PROJECT_LEAD, TASK_LEAD и WORK_LOCK.

Next:
- Передать результат CODEX для нового review.

2026-08-16 | MULTISITE-PROFILE-ISOLATION-P3-FOLLOWUP-APPLY-TEST-FIX | CODEX | READY_FOR_REVIEW

Result:
- Добавлен regression-тест для `New-ApplyPullPlan`: exact `ExpectedTableCount` и `MinimumTableCount` проверяются отдельно и используются в реальной table-set validation.
- Mutation-probe на временной копии подтверждает, что подмена каждого из apply-план полей приводит к отказу тестов.

Files:
- `tests/pull.Tests.ps1`
- `.ai/STATE.md`
- `.ai/HANDOFF.md`
- `.ai/CHANGELOG.md`

Checks:
- WinPS 5.1 full Pester: 165/165; pull: 88/88.
- Parser, Git Bash `sh -n`, and `git diff --check`: PASS.
- No runtime code, private profiles, server, database, deploy, rollback, commit, push, or merge was changed or executed.

Next:
- Independent read-only review before commit/push.

2026-08-16 | MULTISITE-PROFILE-ISOLATION-P3-FOLLOWUP-METADATA-CORRECTION | CODEX | READY_FOR_COMMIT

Result:
- Corrected the current STATE wording: each of the two apply-plan mutation probes produced one failing test in its temporary copy.
- Preserved the existing CHANGELOG history and append-only order; no earlier entry was moved, rewritten, or deleted. This correction is appended at EOF.

Checks:
- Metadata-only correction; no runtime code, private profiles, server, database, deploy, rollback, or live action changed.

2026-08-16 | MULTISITE-PROFILE-ISOLATION-P3-FOLLOWUP-COMMITTED-PUSHED | CODEX | COMMITTED_PUSHED

Result:
- Независимый read-only review завершён с вердиктом PASS; два некритичных metadata-замечания исправлены.
- Reviewed implementation committed as `0ff764b` and pushed to `origin/codex/multisite-profile-isolation-p3-followup`.

Checks:
- Pull Pester: 88 passed, 0 failed; `git diff --check` passed before commit.
- No merge, VPS, database, deploy, rollback, or private-profile edit was performed.

Next:
- Review the published branch and merge only with separate authorization.

2026-08-16 | MULTISITE-PROFILE-ISOLATION-PR-FIXES | CODEX | READY_FOR_COMMIT

Result:
- Closed the PR review findings for local backup-directory isolation, drive-independent onboarding preflight, and exact pull-manifest mutation coverage.
- Documented that remote pull DB export uses WP-CLI, local push-side export/backups use mysqldump, and an updated server runner must be reinstalled.

Files:
- `src/WordPressSshDeploy.psm1`
- `onboard-site.ps1`
- `tests/configuration.Tests.ps1`
- `tests/pull.Tests.ps1`
- `README.md`
- `.ai/STATE.md`

Checks:
- Targeted configuration and pull tests: 128/128.
- Full Pester: 166/166; parser and git diff --check passed.
- No server, database, deploy, rollback, merge, or private-profile edit was performed.

Next:
- Commit and push the branch, update PR documentation, then stop for independent read-only review.

2026-08-16 | MULTISITE-PROFILE-ISOLATION-PR-FIXES-COMMITTED-PUSHED | CODEX | COMMITTED_PUSHED

Result:
- Committed and pushed the PR review fixes as `d9b6815`.
- Updated PR #2 description with the corrected validation totals and the remote WP-CLI/local mysqldump runner note; PR remains draft.

Checks:
- Targeted configuration and pull tests: 128/128.
- Full Pester: 166/166; parser, shell checks, and git diff --check passed.
- No server, SSH, database, deploy, rollback, merge, or private-profile edit was performed.

Next:
- Stop for independent read-only review; merge and live actions require separate authorization.
