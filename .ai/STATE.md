# AI STATE

TEMPLATE_VERSION: existing-projects-v2

## PROJECT

PROJECT_ID: wordpress-ssh-deploy
PROJECT_LEAD: CODEX
DEFAULT_REVIEWER: CLAUDE
MAX_PARALLEL_TASKS: 1

## DOMAIN OWNERS

DESIGN_LEAD: INHERIT
UX_LEAD: INHERIT
FRONTEND_LEAD: INHERIT
BACKEND_LEAD: INHERIT
AI_LOGIC_LEAD: INHERIT
SECURITY_REVIEW_LEAD: INHERIT
SEO_CONTENT_LEAD: INHERIT
TECHNICAL_SEO_LEAD: INHERIT
DEPLOYMENT_LEAD: INHERIT

`INHERIT` означает использование `PROJECT_LEAD`.

Можно добавлять или удалять направления. Менять владельца может только пользователь или главный агент после дословного разрешения пользователя.

## ACTIVE TASK INDEX

ACTIVE_TASK_IDS: DEPLOY-BIDIRECTIONAL-SYNC



Перед работой агент обязан выбрать ровно один `TASK_ID` из списка и работать только в его блоке.

## TASK: DEPLOY-BIDIRECTIONAL-SYNC

TASK_ID: DEPLOY-BIDIRECTIONAL-SYNC
TASK_NAME: Обратная синхронизация staging → local
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CLAUDE (по отдельному назначению пользователя)
REVIEWER: CODEX
STATUS: READY_FOR_REVIEW

BRANCH: agent/deploy-bidirectional-sync
WORKTREE: отдельный worktree Claude, вне рабочей копии и вне worktree Codex
BASE_COMMIT: b907e4a
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_SUMMARY: Спроектировать и реализовать направление pull (staging → local) так, чтобы оно не могло изменить рабочую локальную БД и рабочие файлы. Скачанные артефакты складываются side-by-side и активируются только вручную. Реальный pull, импорт в локальную БД и обновление runner на staging в объём не входили.
PLAN_APPROVED: YES (2026-08-12)
EXECUTION_APPROVED: YES (2026-08-12, только локальные изменения и mock-тесты)

### SCOPE

IN_SCOPE:
- контракт режимов `pull-db`, `pull-files`, `pull-full` и флагов `-DryRun`, `-Confirm`, `-Mirror`
- схема и валидация pull-ключей конфигурации
- верификаторы скачиваемых артефактов и политика путей
- режимы `pull-db`/`pull-files` в `server-deploy.sh` (файл репозитория)
- обвязка в `deploy.ps1`, mock-тесты, документация

OUT_OF_SCOPE:
- реальный pull, импорт в локальную БД, активация скачанной копии
- переустановка runner на staging, production, rollback
- commit, push, merge
- приватные конфигурации и любые реальные значения инфраструктуры

STATUS_DETAIL: этапы A–E завершены локально; направление push не изменялось.

LIMIT_STATUS: SAVE
STOP_AFTER_CHECKPOINT: YES

RESULT:
- pull реализован как side-by-side: `LocalDatabaseTarget` обязан отличаться от `LocalDbName`, рабочие файлы не заменяются, локальный rollback не нужен и не реализован
- production pull отвергается независимо валидацией конфигурации, локальным гейтом режима и runner
- `-Mirror` определён контрактом и fail-closed: отказ и без `AllowDestructiveLocalReplace`, и с ним
- скачанные артефакты проверяются до использования: gzip integrity через ISIZE, структура SQL, точное число таблиц, prefix, отсутствие чужих и смешанных идентификаторов, листинг архива на traversal и symlink
- runner при pull не импортирует, не ротирует backups и не переписывает WordPress

CHECKS:
- полный набор: 107 passed, 0 failed (было 52 до задачи)
- `git diff --check` без замечаний; PowerShell syntax check по 7 файлам без ошибок; `sh -n server-deploy.sh` и оба тестовых `.sh` — код 0
- поиск приватных значений по рабочему дереву — ноль совпадений
- приватные `deploy.config.ps1` и `server.config.sh` в worktree отсутствуют и не создавались

RISKS:
- R-032: runner на staging не обновлён, реальный pull пока невозможен
- R-033: режимы pull проверены только статически, ни разу не исполнялись
- R-034: активация скачанной копии остаётся ручной
- R-035, R-036, R-037: см. реестр рисков

## TASK: DEPLOY-SAFETY-STAGES-1-5

TASK_ID: DEPLOY-SAFETY-STAGES-1-5
TASK_NAME: Безопасность и надёжность deploy, этапы 1–5
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: BLOCKED

BRANCH: codex/stages-1-5-safety
WORKTREE: D:\OneDrive\Документы\Scripts of deploy
BASE_COMMIT: 328132e
LAST_SYNC_COMMIT: 938e4ce
WORK_LOCK: CODEX

CRITICAL: NO

Поля ниже обязательны только при `CRITICAL: YES`:

PLAN_SUMMARY: none
PLAN_APPROVED: NOT_REQUIRED
EXECUTION_APPROVED: NOT_REQUIRED

### SCOPE

IN_SCOPE:
- синхронизация фактического состояния завершённых этапов 1–5
- подготовка к независимому review Claude

OUT_OF_SCOPE:
- изменение рабочего кода
- merge в main и production-деплой

ALLOWED_FILES:
- .ai/STATE.md
- .ai/CHANGELOG.md
- .ai/HANDOFF.md

BLOCKED_BY_TASKS:
- none

### CURRENT CHECKPOINT

RESULT:
- этапы 1–5 реализованы, проверены, закоммичены и опубликованы в отдельной ветке
- Codex остаётся главным агентом; Claude назначен ревьюером
- закрыты review-пункты по проверке временных путей, LOCAL_URL и локальному месту после SQL-экспорта

FILES_CHANGED:
- рабочие файлы deploy и тестов изменены в follow-up review; служебные файлы .ai синхронизированы

CHECKS:
- 39 тестов пройдено, 0 ошибок перед commit 938e4ce
- ветка соответствует origin/codex/stages-1-5-safety
- последующий review-fix checkpoint: 40 тестов пройдено, 0 ошибок; git diff --check пройден

RISKS:
- R-026: двойная ошибка импорта и rollback требует ручного восстановления
- ветка ещё не прошла независимый review и не объединена с main
- POSIX shell syntax check прошёл внутри Pester через bundled shell

NEXT_ACTION:
- после локального commit решить вопрос merge в main; этап 6 остаётся заблокированным

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: SAVE
STOP_AFTER_CHECKPOINT: YES

## TASK: DEPLOY-REVIEW-FIXES-TRAP

TASK_ID: DEPLOY-REVIEW-FIXES-TRAP
TASK_NAME: Security review follow-up for deploy safety
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: codex/stages-1-5-review-fixes
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: 938e4ce
LAST_SYNC_COMMIT: 69ddc47
WORK_LOCK: CODEX

IN_SCOPE:
- prevent cleanup trap from deleting paths with dot-segments outside the server temporary directory
- add a behavioral canary regression test
- add behavioral LOCAL_URL rejection checks
- retain a focused regression check for SQL dump disk accounting

OUT_OF_SCOPE:
- merge, push, staging, production deploy

ALLOWED_FILES:
- server-deploy.sh
- deploy.ps1
- tests/server-safety.smoke.sh
- tests/safety.Tests.ps1
- .ai/STATE.md
- .ai/CHANGELOG.md

RESULT:
- temporary file paths are validated before trap installation and again inside cleanup
- canary outside the temporary directory survives a failed validation
- LOCAL_URL rejection cases are covered by the shell smoke test
- scoped deployment changes committed as da13e48; project controls and risk registry committed as 69ddc47

CHECKS:
- 40 tests passed, 0 failed; git diff --check passed

RISKS:
- branch is local and has not been pushed or merged
- no real server or production environment was used

NEXT_ACTION:
- stop after checkpoint; push, merge, and deploy require separate authorization

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: SAVE
STOP_AFTER_CHECKPOINT: YES

## TASK: STAGING-SSH-PREFLIGHT-SETUP

TASK_ID: STAGING-SSH-PREFLIGHT-SETUP
TASK_NAME: Staging SSH access and read-only server inventory
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: codex/stages-1-5-review-fixes
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: 502a18b
LAST_SYNC_COMMIT: 502a18b
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_SUMMARY: Create a dedicated local ed25519 key; import and authorize only its public half in cPanel; then collect read-only SSH inventory for staging.example.com. No server files, directories, WordPress, database, repository, or domains may be changed.
PLAN_APPROVED: YES (2026-08-10)
EXECUTION_APPROVED: YES (2026-08-10)

### SCOPE

IN_SCOPE:
- local dedicated SSH key creation for staging.example.com
- public-key import and authorization in the cPanel account <cpanel-account>
- read-only SSH inventory: current user, OS, free disk space, Git, PHP, WP-CLI, and MySQL client availability

OUT_OF_SCOPE:
- remote filesystem writes or directory creation
- WordPress, database, Git checkout, runner, server policy, domain, DNS, or TLS changes
- deployment, preflight runner execution, merge, push, and production

ALLOWED_FILES:
- .ai/STATE.md
- .ai/CHANGELOG.md
- .ai/HANDOFF.md

NEXT_ACTION:
- create a separately approved plan for cPanel-compatible staging preparation; do not deploy yet

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: SAVE
STOP_AFTER_CHECKPOINT: YES

RESULT:
- dedicated local ed25519 key was created and its public half was imported and authorized in cPanel as <cpanel-account>
- the hosting provider's official virtual-hosting SSH port <ssh-port> is reachable; port 22 is not
- approved SSH inventory completed without remote writes

CHECKS:
- TCP: <ssh-host>:<ssh-port> reachable
- SSH: <ssh-user>@<ssh-host>:<ssh-port> connected with the dedicated key
- remote tools available: Git, PHP, WP-CLI, MySQL client, mysqldump, unzip, and rsync

RISKS:
- this is a cPanel virtual-hosting environment; the protected administrator-owned runner design has not been proven compatible
- staging WordPress, a separate database, and a repository checkout have not been prepared

## TASK: STAGING-WORDPRESS-FIXTURE

TASK_ID: STAGING-WORDPRESS-FIXTURE
TASK_NAME: Isolated WordPress staging fixture and code-only deployment smoke test
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: main (private fixture repository)
WORKTREE: dedicated fixture workspace (local path intentionally omitted)
BASE_COMMIT: 502a18b
LAST_SYNC_COMMIT: 26a57c8
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_SUMMARY: Prepare a clean WordPress only at https://staging.example.com/, use the supplied fixture repository, create only staging-owned runner and artifact directories, then run preflight and a code-only smoke deployment. Existing sites, production, databases, and main remain out of scope.
PLAN_APPROVED: YES (2026-08-10)
EXECUTION_APPROVED: YES (2026-08-10)

INPUTS:
- fixture repository: https://github.com/xmods97/wordpress-staging-fixture.git
- staging target: https://staging.example.com/

IN_SCOPE:
- verification and use of the existing fresh WordPress installation and separate database for staging.example.com only
- fixture workspace and a minimal test plugin in the supplied fixture repository
- private local deploy configuration and cPanel-compatible staging runner setup
- preflight and code-only smoke deployment to the new staging site

OUT_OF_SCOPE:
- example.com and portfolio.example.com
- existing databases, production, public main merge, and deployment of a real site
- db or full deployment modes

ALLOWED_FILES:
- .ai/STATE.md
- .ai/CHANGELOG.md
- .ai/HANDOFF.md
- dedicated fixture workspace only

RISKS:
- cPanel shared hosting cannot provide the administrator-owned runner protection used by production; the staging runner will be an explicitly accepted lower-isolation setup
- a new database and WordPress installation are destructive only within the newly created staging target

NEXT_ACTION:
- do not run db or full deployment; choose a separate next stage only after reviewing the cPanel isolation limitation

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: SAVE
STOP_AFTER_CHECKPOINT: YES

RESULT:
- existing fresh WordPress at staging.example.com was verified and retained; its separate database is <staging-db-name>
- private fixture repository was bootstrapped at commit 26a57c8 with a single inactive smoke plugin
- staging runner/policy was installed outside WordPress and the Git checkout; GitHub access uses a read-only deploy key over SSH port 443
- WP_ENVIRONMENT_TYPE=staging was added after a timestamped backup of wp-config.php
- preflight and code-only smoke deployment completed successfully

CHECKS:
- fixture config schema validation and runner POSIX syntax validation passed
- preflight completed against the real staging server
- code-only smoke deployment completed; remote fixture is clean at 26a57c8
- local and remote plugin SHA-256 values match; plugin is present and inactive
- HTTPS staging endpoint returned 200 OK

RISKS:
- cPanel shared hosting runner/policy is owned by <cpanel-account> rather than an administrator; this lower isolation is accepted for this staging fixture only
- PHP 7.4.33 is end-of-life; do not treat this staging host as production-ready
- db and full deployment modes, real-site content, and rollback behavior remain untested

## TASK: LOCAL-WORDPRESS-FIXTURE-DB

TASK_ID: LOCAL-WORDPRESS-FIXTURE-DB
TASK_NAME: Disposable local WordPress fixture and database for staging DB smoke
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: main (private fixture repository)
WORKTREE: dedicated fixture workspace (local path intentionally omitted)
BASE_COMMIT: 26a57c8
LAST_SYNC_COMMIT: 26a57c8
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_SUMMARY: Verify Laragon before writes; create only the new wordpress_staging_fixture database and local WordPress at D:\laragon\www\wordpress-staging-fixture.local; then update only the ignored fixture deploy.config.ps1. Stop on an existing database, directory, or database authentication requirement.
PLAN_APPROVED: YES (2026-08-10)
EXECUTION_APPROVED: YES (2026-08-10)

IN_SCOPE:
- read-only Laragon capability and collision checks
- new database wordpress_staging_fixture only
- new local WordPress fixture at D:\laragon\www\wordpress-staging-fixture.local only
- ignored fixture deploy.config.ps1 update to actual local paths

OUT_OF_SCOPE:
- any existing Laragon database, site, configuration, hosts file, or virtual host
- remote staging, production, GitHub, db/full deploy, and rollback test

ALLOWED_FILES:
- .ai/STATE.md
- .ai/CHANGELOG.md
- .ai/HANDOFF.md
- dedicated fixture workspace private config only
- D:\laragon\www\wordpress-staging-fixture.local only

RISKS:
- local database creation and WordPress installation are intentionally isolated but still write to Laragon
- this task must stop if root database access is not passwordless or the requested names already exist

NEXT_ACTION:
- prepare a separately approved DB-only staging smoke plan; do not deploy yet

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: SAVE
STOP_AFTER_CHECKPOINT: YES

RESULT:
- created only the new Laragon database wordpress_staging_fixture and WordPress fixture at D:\laragon\www\wordpress-staging-fixture.local
- updated only the ignored fixture deploy.config.ps1 to the real local path and database

CHECKS:
- pre-write collision checks confirmed the target database and directory were absent
- local database has 12 WordPress tables; home and siteurl are http://wordpress-staging-fixture.local
- fixture deploy config schema validation passed

RISKS:
- the local fixture has no hosts-file or virtual-host mapping by design; it is a CLI/database source for DB smoke only
- the local wp-config.php uses the isolated Laragon root database connection and must remain local
- remote staging DB has not been modified; DB/full modes and rollback remain untested

## TASK: STAGING-DB-SMOKE

TASK_ID: STAGING-DB-SMOKE
TASK_NAME: Isolated staging database deployment smoke test
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: main (private fixture repository)
WORKTREE: dedicated fixture workspace (local path intentionally omitted)
BASE_COMMIT: 26a57c8
LAST_SYNC_COMMIT: 26a57c8
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_SUMMARY: Export only the isolated local wordpress_staging_fixture database, run the private fixture deployment in db mode with Git and uploads skipped, retain the runner-created backup of the staging database, then verify the staging URL, WordPress tables, backup artifact, and HTTPS. This plan is blocked after discovering that the local wp_ table prefix does not match the active staging <staging-prefix> prefix.
PLAN_APPROVED: YES (2026-08-10)
EXECUTION_APPROVED: YES (2026-08-10)

IN_SCOPE:
- export only the local wordpress_staging_fixture database
- database-only deployment to staging.example.com using the existing private fixture configuration
- runner-created backup and post-deploy verification of staging database, URL, and HTTPS

OUT_OF_SCOPE:
- Git pull or fixture code changes
- uploads, production, example.com, portfolio.example.com, merge, push, and rollback fault injection

ALLOWED_FILES:
- .ai/STATE.md
- .ai/CHANGELOG.md
- .ai/HANDOFF.md
- dedicated fixture workspace private config and generated temporary SQL artifact only
- staging database <staging-db-name> and runner-managed backup artifact only

RISKS:
- this will replace the current staging WordPress database and its users; the existing staging WP-admin credentials will cease to work
- rollback is backup-based but is not proven by a deliberate failure test in this task
- no production database or site is in scope

NEXT_ACTION:
- prepare a revised, separately double-approved remediation plan; do not delete tables or rerun DB deployment

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: SAVE
STOP_AFTER_CHECKPOINT: YES

RESULT:
- the DB-only command completed and created the non-empty staging backup db-20260810-200530.sql.gz; Git and uploads were skipped
- it did not replace the active staging WordPress data because the local dump used wp_ while staging wp-config.php uses <staging-prefix>
- the staging database now contains an additional inactive wp_ table family beside the active <staging-prefix> family

CHECKS:
- local source configuration validated; local fixture database had 12 tables and the fixture Git clone was clean
- read-only prefix verification: local wp-config.php uses wp_; remote wp-config.php uses <staging-prefix>
- remote database contains both table families; prior WP-CLI URL/plugin checks therefore assessed the old active <staging-prefix> tables
- public HTTPS returned 200; this proves the existing staging site, not the intended fixture import

RISKS:
- the current staging content and old WP users remain active, but the database contains unused imported wp_ tables
- deleting the unused tables or replacing active tables is destructive and requires a revised plan and fresh double approval
- PHP 7.4.33 and shared cPanel ownership remain staging-only limitations

## TASK: STAGING-DB-REMEDIATION-HOMEPAGE

TASK_ID: STAGING-DB-REMEDIATION-HOMEPAGE
TASK_NAME: Correct staging database table prefix and prove replacement with homepage marker
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: BLOCKED

BRANCH: main (private fixture repository)
WORKTREE: dedicated fixture workspace (local path intentionally omitted)
BASE_COMMIT: 26a57c8
LAST_SYNC_COMMIT: 26a57c8
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_SUMMARY: This approved plan is blocked before remote deployment: Windows MySQL lowercased the aligned local table family to <staging-prefix-lowercased>, while Linux staging requires case-sensitive <staging-prefix>. A generated SQL identifier transformation requires a revised plan and fresh approvals.
PLAN_APPROVED: YES (2026-08-10)
EXECUTION_APPROVED: YES (2026-08-10)

IN_SCOPE:
- current staging database backup created by the existing runner
- isolated local fixture database prefix alignment and homepage smoke-marker content only
- DB-only staging deployment with Git and uploads skipped
- read-only verification of public homepage, active table prefix, backup, and HTTPS

OUT_OF_SCOPE:
- production, example.com, portfolio.example.com, Git changes, uploads, full mode, merge, push, and rollback fault injection
- direct edits to the current staging WordPress outside the runner-mediated database replacement

ALLOWED_FILES:
- .ai/STATE.md
- .ai/CHANGELOG.md
- .ai/HANDOFF.md
- dedicated local fixture database, WordPress directory, private config, and generated temporary SQL artifact only
- staging database <staging-db-name> and runner-managed backup artifact only

RISKS:
- this replaces the active staging table family and changes the staging WordPress content/users
- prior accidental inactive wp_ tables must not be deleted unless the generated SQL and backup are verified first
- rollback backup exists but deliberate failure/restore remains out of scope

NEXT_ACTION:
- prepare a revised plan for a generated SQL identifier transformation with exact source/target family assertions; do not run remote DB deployment

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: SAVE
STOP_AFTER_CHECKPOINT: YES

RESULT:
- local fixture tables were renamed from wp_ to the Windows-normalized <staging-prefix-lowercased> family and received the homepage marker Staging DB Smoke
- structural dump inspection stopped the task before remote deployment because its DROP TABLE statements target <staging-prefix-lowercased>, not staging <staging-prefix>

CHECKS:
- local fixture contains 12 <staging-prefix-lowercased> tables; its structural dump has DROP TABLE IF EXISTS only for that lowercased family
- active staging prefix remains <staging-prefix> from read-only wp-config.php inspection
- no remote DB import, deletion, cleanup, or homepage change was performed in this task

RISKS:
- a direct import would create another inactive table family on case-sensitive staging instead of replacing the active tables
- any SQL identifier transformation must be fully asserted and separately approved before staging use

## TASK: STAGING-DB-REMEDIATION-SQL-PREFIX

TASK_ID: STAGING-DB-REMEDIATION-SQL-PREFIX
TASK_NAME: SQL identifier-safe staging database remediation and homepage smoke proof
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: main (private fixture repository)
WORKTREE: dedicated fixture workspace (local path intentionally omitted)
BASE_COMMIT: 26a57c8
LAST_SYNC_COMMIT: 26a57c8
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_SUMMARY: Create a new current staging backup, generate SQL only from the isolated local fixture database, transform only quoted SQL table identifiers from <staging-prefix-lowercased> to <staging-prefix>, assert that exactly the active staging family is targeted and no source/old family identifiers remain, then import only the asserted SQL through the existing runner with Git and uploads skipped. Verify the public homepage marker, active prefix, backup, and HTTPS. Do not clean accidental wp_ tables in this task.
PLAN_APPROVED: YES (2026-08-10)
EXECUTION_APPROVED: YES (2026-08-10)

IN_SCOPE:
- generated temporary local SQL artifact from wordpress_staging_fixture only
- exact quoted-identifier prefix transformation and assertions
- runner-created staging backup and DB-only import to <staging-db-name>
- public homepage smoke marker, active prefix, backup, and HTTPS verification

OUT_OF_SCOPE:
- Git, uploads, full mode, production, other hosted sites, merge, push, rollback fault injection, and cleanup of accidental wp_ tables
- broad text replacement or transformation of SQL values, serialized content, credentials, or arbitrary identifiers

ALLOWED_FILES:
- .ai/STATE.md
- .ai/CHANGELOG.md
- .ai/HANDOFF.md
- dedicated local fixture database, private config, and generated temporary SQL artifact only
- staging database <staging-db-name> and runner-managed backup artifact only

RISKS:
- this replaces the active staging table family and staging users/content
- a prefix transformation is safe only if strict assertions prove all affected identifiers are quoted table names and exactly 12 tables are targeted
- current accidental wp_ tables remain untouched

NEXT_ACTION:
- stop; any cleanup of accidental wp_ tables or a permanent deploy-tool prefix guard requires a new critical task and approvals

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: SAVE
STOP_AFTER_CHECKPOINT: YES

RESULT:
- a private one-run SQL wrapper transformed only asserted quoted table identifiers from <staging-prefix-lowercased> to <staging-prefix>; it was removed after use and the private config was restored to the real mysqldump executable
- DB-only runner deployment replaced the active <staging-prefix> staging table family, created backup db-20260810-211841.sql.gz, and did not run Git or uploads
- staging public homepage now renders the fixture marker Staging DB Smoke

CHECKS:
- wrapper preflight: exactly 12 active-prefix DROP TABLE statements; no quoted source <staging-prefix-lowercased> or legacy wp_ identifiers remained
- existing runner preflight passed before import
- post-import: active <staging-prefix> table count 12, show_on_front page, front-page title Staging DB Smoke, plugin inactive, backup non-empty, HTTPS 200, marker present in public response
- restored private fixture configuration schema validation passed

RISKS:
- 12 accidental inactive wp_ tables from the first failed DB smoke remain in the staging database and were intentionally not deleted
- the deploy tool does not detect local/remote WordPress table-prefix or case mismatch before a database import; this is a separate critical safety fix
- deliberate failure/restore remains untested; PHP 7.4.33 and shared cPanel ownership remain staging-only limitations

## TASK: STAGING-DB-AFTERMATH-SAFETY

TASK_ID: STAGING-DB-AFTERMATH-SAFETY
TASK_NAME: Handoff for staging DB aftermath and permanent prefix safety planning
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: codex/stages-1-5-review-fixes
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: 502a18b
LAST_SYNC_COMMIT: 502a18b
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_SUMMARY: Add a permanent local/remote WordPress table-prefix and case compatibility guard with regression tests. Establish a staging-test rule: before every approved staging deploy test, update the local fixture homepage with a unique current-stage marker/version and verify that marker publicly after deployment. Do not clean accidental wp_ tables or touch production.
PLAN_APPROVED: YES (2026-08-11, updated plan)
EXECUTION_APPROVED: YES (2026-08-11)

IN_SCOPE:
- read-only review of the staging DB aftermath and project deployment code
- plan and tests for a permanent local/remote WordPress table-prefix and case compatibility guard
- deterministic homepage marker/version update before each staging deploy test and public marker verification afterward
- separately scoped proposal for safe cleanup of accidental inactive wp_ tables

OUT_OF_SCOPE:
- any remote or local destructive SQL, DB import, deploy, rollback, Git changes, push, merge, production, or cleanup without a new plan and double approval

ALLOWED_FILES:
- .ai/STATE.md
- .ai/CHANGELOG.md
- .ai/HANDOFF.md
- docs/RISKS-RU.md
- README.md
- deploy.config.example.ps1
- deploy.ps1
- server.config.example.sh
- server-deploy.sh
- src/WordPressSshDeploy.psm1
- tests/configuration.Tests.ps1
- tests/configuration.smoke.ps1
- tests/quoting.Tests.ps1
- tests/server-safety.smoke.sh
- tests/database-rollback.smoke.sh
- tests/fixtures/fake-php.sh
- tests/fixtures/server.config.production.sh
- tests/fixtures/server.config.staging.sh

RISKS:
- R-031 rollout is complete for staging: source, runner, and private policy now reject local/remote prefix or case mismatches
- 12 accidental inactive wp_ tables remain on staging

NEXT_ACTION:
- stop before independent Claude review; DB rollback and wp_* cleanup remain separate critical tasks

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: STOP_AFTER_CHECKPOINT
STOP_AFTER_CHECKPOINT: YES

RESULT:
- added ExpectedDbTablePrefix as a required local and server policy lock
- local deploy validates emitted SQL CREATE TABLE prefixes with ordinal case comparison; server validates client policy, active WordPress prefix, and incoming SQL before backup/import
- documented the required unique homepage marker/version before every staging database deploy test
- published fixture commit 63b8908 and completed code-only staging rollout; remote policy is <staging-prefix>
- activated deploy-smoke-plugin before the DB smoke; the later DB import restored local active_plugins and plugin is now inactive
- normalized transient Windows SQL after exact 12-table assertions and completed DB-only staging smoke
- implemented persistent deploy-time normalization for the exact lower-case Windows prefix and exported regression coverage

CHECKS:
- full suite passed: 45 tests, 0 failed; fixture suite also passed 45 tests, 0 failed
- local/remote configuration, emitted SQL case mismatch, client prefix mismatch, WordPress prefix mismatch, and incoming SQL mismatch are covered
- git diff --check passed
- staging code-only deploy completed; HTTPS 200; public marker verified from imported homepage content
- DB-only smoke through persistent deploy normalization: backup db-20260811-173734.sql.gz, active prefix <staging-prefix>, 14 active tables, 12 inactive wp_* tables retained; marker STAGING-DB-SMOKE-20260811-02 returned over HTTPS 200
- negative wrong-prefix preflight rejected with exit code 1 before DB actions
- main project and fixture test suites pass 45/45 after normalization implementation

RISKS:
- R-031 is resolved for staging runner/config; public marker verification completed
- 12 accidental inactive wp_ tables remain on staging; cleanup is a separate critical operation

---

Для каждой новой активной задачи скопируй блок `## TASK: CURRENT-CODEX-TASK`, замени заголовок на `## TASK: TASK-ID` и добавь её ID в `ACTIVE_TASK_IDS`.

Завершённые задачи удаляются из `ACTIVE_TASK_IDS`, но их итог сохраняется в `.ai/CHANGELOG.md` и Git.


## EXISTING PROJECT MIGRATION RULES

MIGRATION_MODE: CODEX_RETAINS_CONTROL
CURRENT_PROJECT_OWNER: CODEX
CURRENT_TASK_OWNER: CODEX
CLAUDE_DEFAULT_MODE: REVIEW_ONLY
AUTO_TAKEOVER_BY_CLAUDE: FORBIDDEN
CODEX_LIMIT_EXHAUSTION_CHANGES_ROLE: NO
FUTURE_REASSIGNMENT_REQUIRES_USER_COMMAND: YES

При первом запуске Codex обязан обновить только значения состояния, не меняя рабочий код:

- `PROJECT_ID`;
- фактический `TASK_ID`;
- `TASK_NAME`;
- `DOMAIN`;
- `STATUS`;
- `BRANCH`;
- `WORKTREE`;
- `BASE_COMMIT`;
- `LAST_SYNC_COMMIT`;
- `IN_SCOPE`, `OUT_OF_SCOPE`, `ALLOWED_FILES`;
- текущий checkpoint.

При этом Codex обязан сохранить:

- `PROJECT_LEAD: CODEX`;
- `TASK_LEAD: CODEX` для уже начатой задачи;
- `REVIEWER: CLAUDE`;
- `WORK_LOCK: CODEX`.
