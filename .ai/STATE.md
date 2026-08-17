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

ACTIVE_TASK_IDS: WP-CLI-ROOT-PULL-FIX-REVIEW-FOLLOWUP



Перед работой агент обязан выбрать ровно один `TASK_ID` из списка и работать только в его блоке.

## TASK: MULTISITE-PROFILE-ISOLATION-PR-FIXES

TASK_ID: MULTISITE-PROFILE-ISOLATION-PR-FIXES
TASK_NAME: Close PR review findings for backup isolation, onboarding portability, and pull manifest mutation coverage
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: COMMITTED_PUSHED

BRANCH: codex/multisite-profile-isolation-p3-followup
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: 09054c5
LAST_SYNC_COMMIT: 5af268b
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-16)
EXECUTION_APPROVED: YES (2026-08-16)
LIVE_ACTIONS: NONE

IN_SCOPE:
- include LocalBackupDirectory in profile-isolation identity checks
- make onboarding preflight drive-independent while requiring absolute existing paths
- add exact pull-manifest mutation regression coverage
- document local mysqldump versus remote WP-CLI pull export and runner reinstallation

OUT_OF_SCOPE:
- merge, VPS/production, SSH, database, pull/apply, deploy, rollback, profile migration, and profile deletion

RESULT:
- Shared local backup directories now cause profile-isolation collisions before backup cleanup can run.
- Onboarding no longer hardcodes D:; it reports absolute-path and existence checks while preserving read-only behavior.
- Pull manifest mutations of ExpectedDbTableCount and MinimumDbTableCount are rejected by real Assert-PullManifest tests.
- README documents the server WP-CLI pull export and the need to reinstall an updated runner.

CHECKS:
- Targeted configuration and pull tests: 128 passed, 0 failed.
- Full Pester: 166 passed, 0 failed.
- PowerShell parser: PASS; Git Bash shell checks covered by full Pester; git diff --check: PASS.
- No server, database, deploy, rollback, merge, or private-profile edit was performed.

NEXT_ACTION:
- Independent read-only review of PR #2; merge and live actions require separate authorization.

CONTEXT_STATUS: NORMAL
STOP_AFTER_CHECKPOINT: YES

## TASK: MULTISITE-PROFILE-ISOLATION-P3-FOLLOWUP

TASK_ID: MULTISITE-PROFILE-ISOLATION-P3-FOLLOWUP
TASK_NAME: Remove obsolete pull-count configuration and prove exact-count regression coverage
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CLAUDE (previously assigned narrow test fix)
REVIEWER: CODEX
STATUS: COMMITTED_PUSHED

BRANCH: codex/multisite-profile-isolation-p3-followup
WORKTREE: dedicated Codex worktree 9963
BASE_COMMIT: 4ae5be7
LAST_SYNC_COMMIT: 0ff764b
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-15)
EXECUTION_APPROVED: YES (2026-08-15)
LIVE_ACTIONS: LOCAL_ONLY

IN_SCOPE:
- remove obsolete `MinimumPullDbTableCount` from the runtime schema
- require exact `ExpectedPullDbTableCount` for pull-enabled profiles
- make exact-count regression coverage mutation-proof and non-degenerate
- sanitize current HANDOFF metadata without changing code or private profiles

OUT_OF_SCOPE:
- private profile migration, merge, VPS/production, SSH, database, pull/apply, deploy, rollback, and profile deletion

RESULT:
- `MinimumPullDbTableCount` is rejected as an unknown configuration key; it is not present in the runtime schema.
- Pull validation keeps exact `ExpectedPullDbTableCount`; push and pull counts are intentionally different in the fixture (17 versus 12).
- Regression coverage includes mutations of the exact count and internal minimum, wrong table counts, push/pull separation, and obsolete-key rejection.
- `New-ApplyPullPlan` now has direct exact-count assertions for both `ExpectedTableCount` and `MinimumTableCount`; its values are used in a real table-set validation.
- `.ai/HANDOFF.md` no longer contains a machine-specific local path; this task is now recorded separately from its parent task.

CHECKS:
- WinPS 5.1 full Pester: 165 passed, 0 failed; pull tests: 88 passed, 0 failed.
- PowerShell parser: PASS; Git Bash `sh -n`: PASS; `git diff --check`: PASS.
- Mutation probes confirm each apply-plan mutation now fails (one failure per mutation in temporary copies).
- Commit `0ff764b` was pushed to `origin/codex/multisite-profile-isolation-p3-followup`.
- No server, database, deploy, rollback, merge, or private-profile edit was performed.

RISKS:
- Existing private pull profiles still require a separate approved local migration to add exact `ExpectedPullDbTableCount` and remove the obsolete key.

NEXT_ACTION:
- Review the published branch and open or merge a PR only with separate authorization; do not run live actions.

CONTEXT_STATUS: NORMAL
STOP_AFTER_CHECKPOINT: YES

## TASK: MULTISITE-PROFILE-ISOLATION-P3-FIXES

TASK_ID: MULTISITE-PROFILE-ISOLATION-P3-FIXES
TASK_NAME: Close all remaining metadata and P3 findings from the ROUND4 review
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: detached HEAD 4ae5be7
WORKTREE: dedicated Codex worktree 9963
BASE_COMMIT: 4ae5be7
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-15)
EXECUTION_APPROVED: YES (2026-08-15)
LIVE_ACTIONS: LOCAL_ONLY

IN_SCOPE:
- repair append-only metadata and synchronize STATE/CHANGELOG without history rewrite
- handle null EndBlock explicitly in profile AST loading
- remove machine-specific canonical profile path coupling
- document the complete data-only profile contract
- restore or explicitly enforce exact pull DB table-count validation
- rename shadowing `$profile` variables
- add parse, dynamic-expression, and method-invocation regression tests

OUT_OF_SCOPE:
- commit, push, merge, VPS/production, live pull/apply, deploy, rollback, SQL mutation, and deleting or moving old profiles

CHECKPOINT:
- ROUND4 code review PASS; WinPS 5.1 full Pester 154/154 and configuration 35/35.
- P3 implementation checkpoint: safe literal AST allowlist, explicit profile-directory wiring, exact pull table-count plans, and regression tests are in the uncommitted worktree.

RESULT:
- Handled null `EndBlock`; rejected dynamic/type/method-bearing profile values before safe evaluation; renamed profile loop variables.
- Removed runtime hardcoded canonical profile paths; callers now pass `ProfilesDirectory` or use the environment variable for the menu.
- Pull plans now require and enforce `ExpectedPullDbTableCount`; README documents the complete data-only profile contract.
- Restored append-only CHANGELOG structure and synchronized metadata without rewriting committed history.
- Removed obsolete `MinimumPullDbTableCount`; existing pull-enabled private profiles must add their exact `ExpectedPullDbTableCount` and remove the obsolete key before use.
- Follow-up fix (CLAUDE as assigned implementer, tests only): the exact pull table-count regression no longer relies on the example profile's identical push/pull value of 12; it pins the pull count to 17 and fails when either the exact count or the internal minimum is mutated.

CHECKS:
- WinPS 5.1 full Pester: 164 passed, 0 failed.
- WinPS 5.1 parser: PASS; Git Bash `sh -n` for runner and wrapper: PASS; `git diff --check`: PASS.
- No server, database, deploy, rollback, commit, push, merge, or profile deletion was performed.

RISKS:
- Worktree remains detached and changes are uncommitted; old root profiles remain intentionally untouched and require a separate approved migration/cleanup task.
- Existing private profiles were not edited; until their pull settings are migrated, fail-closed validation will block them.

NEXT_ACTION:
- Request fresh independent read-only Claude review; do not commit, push, merge, or run live actions before review.

CONTEXT_STATUS: NORMAL
STOP_AFTER_CHECKPOINT: YES

## TASK: MULTISITE-PROFILE-ISOLATION-REVIEW-FIXES-ROUND4

TASK_ID: MULTISITE-PROFILE-ISOLATION-REVIEW-FIXES-ROUND4
TASK_NAME: Restore Windows PowerShell 5.1 compatibility for safe profile loading
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: detached HEAD 4ae5be7
WORKTREE: dedicated Codex worktree 9963
BASE_COMMIT: 4ae5be7
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-15)
EXECUTION_APPROVED: YES (2026-08-15)
LIVE_ACTIONS: LOCAL_ONLY

IN_SCOPE:
- use the Windows PowerShell 5.1-compatible zero-argument `SafeGetValue()` overload
- improve safe-evaluation error diagnostics
- add a regression test for literal strings, arrays, booleans, and nested hashtables
- correct ROUND4 verification metadata

OUT_OF_SCOPE:
- deleting or moving old private profiles, VPS/production changes, live pull/apply, deploy, rollback, SQL mutation, commit, push, or merge

RESULT:
- Safe profile loading now uses `HashtableAst.SafeGetValue()` without the PowerShell 7-only boolean overload.
- Valid data-only profiles load again; command, redirection, environment, method, parse, and dynamic-expression cases remain fail-closed.

CHECKS:
- Full Pester: 154 passed, 0 failed.
- Configuration tests: 35 passed, 0 failed.
- PowerShell 5.1 parser: pass.
- Git Bash `sh -n` for `server-deploy.sh` and `root-ssh-wrapper.sh`: passed.
- `git diff --check`: passed.
- No server or database was contacted.

RISKS:
- Old root private profiles remain intentionally untouched and require a separate approved local migration or cleanup step.
- Worktree is detached and all project changes remain uncommitted; independent review is required before commit/push.

NEXT_ACTION:
- Independent read-only Claude review of the WinPS 5.1-compatible AST loader and updated tests. Do not commit/push or run live actions before review.

CONTEXT_STATUS: OVERLOADED
LIMIT_STATUS: STOP_AFTER_CHECKPOINT
STOP_AFTER_CHECKPOINT: YES

## TASK: MULTISITE-PROFILE-ISOLATION-REVIEW-FIXES-ROUND3

TASK_ID: MULTISITE-PROFILE-ISOLATION-REVIEW-FIXES-ROUND3
TASK_NAME: Close AST profile-loading bypasses found in the second independent review
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: main
WORKTREE: dedicated Codex worktree f6a5
BASE_COMMIT: 4ae5be7
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-15)
EXECUTION_APPROVED: YES (2026-08-15)
LIVE_ACTIONS: LOCAL_ONLY

IN_SCOPE:
- remove dot-sourcing of discovered profile candidates from the isolation scan
- require one direct data-only `$DeployConfig` hashtable assignment
- add mutation coverage for redirection and environment-assignment side effects
- keep the current metadata diff free of real site-specific values

OUT_OF_SCOPE:
- deleting or moving old private profiles, VPS/production changes, live pull/apply, deploy, rollback, SQL mutation, commit, push, or merge

RESULT:
- Discovered profile candidates are parsed and loaded through `HashtableAst.SafeGetValue()`; profile code is never executed by the isolation scan.
- Profiles with commands, methods, multiple statements, redirections, environment assignments, parse errors, or dynamic values fail closed.
- Added regression tests proving redirection does not create a file and environment assignment does not change the process environment.

CHECKS:
- Full Pester: 153 passed, 0 failed.
- Configuration tests: 34 passed, 0 failed.
- PowerShell parser: pass for all `.ps1` files and `src/WordPressSshDeploy.psm1`.
- Git Bash `sh -n` for `server-deploy.sh` and `root-ssh-wrapper.sh`: passed.
- `git diff --check`: passed.
- Public example profile loaded through the safe AST path; no server or database was contacted.

RISKS:
- Old root private profiles remain intentionally untouched; they still require a separate approved local migration or cleanup step before D profiles can pass onboarding.
- Code and metadata remain uncommitted; independent review is required before commit/push.

NEXT_ACTION:
- Independent read-only Claude review of the AST-only profile loading, mutation tests, metadata sanitization, and complete regression results. Do not commit/push or run live actions before review.

CONTEXT_STATUS: OVERLOADED
LIMIT_STATUS: STOP_AFTER_CHECKPOINT
STOP_AFTER_CHECKPOINT: YES

## TASK: MULTISITE-PROFILE-ISOLATION-REVIEW-FIXES

TASK_ID: MULTISITE-PROFILE-ISOLATION-REVIEW-FIXES
TASK_NAME: Close second-round review findings in profile isolation and profile loading safety
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: main
WORKTREE: dedicated Codex worktree f6a5
BASE_COMMIT: 4ae5be7
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-15)
EXECUTION_APPROVED: YES (2026-08-15)
LIVE_ACTIONS: LOCAL_ONLY

IN_SCOPE:
- make profile isolation compare the selected catalog, tool-root private profiles, and canonical D: profiles
- add regression coverage for profiles split across separate catalogs
- raise the automatic pull table sanity floor to 12 standard WordPress core tables
- keep private local agent settings out of Git
- keep the current metadata diff free of real site-specific values

OUT_OF_SCOPE:
- deleting or moving old private profiles, VPS/production changes, live pull/apply, deploy, rollback, SQL mutation, commit, push, or merge

RESULT:
- Profile isolation now has an explicit canonical-scope switch used by every entry point; it scans the selected profile directory plus root `deploy.config*.ps1` and `D:\wordpress-ssh-deploy\profiles`.
- Duplicate profile files are detected across catalogs with fail-closed identity collisions; non-profile tool scripts are not loaded as profiles.
- Profile candidates are statically parsed as data-only files before any dot-sourcing; command- or method-bearing `.ps1` files are rejected.
- Added split-catalog and unsafe-script mutation tests and ignored `.claude/` local settings.
- Raised the fallback and example/private profile pull sanity floor from 5 to 12 tables.
- Sanitized current STATE/CHANGELOG additions to neutral site labels and generic verification values.

CHECKS:
- Full Pester: 151 passed, 0 failed.
- Configuration tests: 32 passed, 0 failed.
- PowerShell parser: clean for changed scripts/module.
- Git Bash `sh -n` for `server-deploy.sh` and `root-ssh-wrapper.sh`: passed.
- `git diff --check`: clean.
- Read-only D onboarding correctly fails closed on two stale root profile duplicates; no server or database was contacted.

RISKS:
- Old root private profiles remain intentionally untouched; they must be migrated or removed under a separate approved local cleanup step before D profiles can pass onboarding.
- Code and metadata remain uncommitted; independent review is still required before commit/push.

NEXT_ACTION:
- Independent read-only Claude review of canonical profile scope, safe profile loading, metadata sanitization, threshold change, and regression coverage. Do not commit/push or run live actions before review.

CONTEXT_STATUS: OVERLOADED
LIMIT_STATUS: STOP_AFTER_CHECKPOINT
STOP_AFTER_CHECKPOINT: YES

## TASK: MULTISITE-PROFILE-ISOLATION-ONBOARDING

TASK_ID: MULTISITE-PROFILE-ISOLATION-ONBOARDING
TASK_NAME: Isolate site profiles and prepare D:-based local onboarding
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: main
WORKTREE: dedicated Codex worktree f6a5
BASE_COMMIT: 4ae5be7
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-15)
EXECUTION_APPROVED: YES (2026-08-15)
LIVE_ACTIONS: LOCAL_ONLY

IN_SCOPE:
- require explicit profile selection for deploy, site Git, verify, and backup cleanup
- validate SiteId and local/remote path/database/runtime isolation across profiles
- use D:\wordpress-ssh-deploy for private profiles, workspaces, logs, backups, and WP-CLI
- add read-only onboarding preflight and automatic pull table sanity validation
- split the local staging fixture profile from the production profile

OUT_OF_SCOPE:
- VPS/production changes, live pull/apply, deploy, rollback, SQL mutation, cleanup, commit, push, merge, or Claude review

RESULT:
- Added profile collision detection for SiteId, code repository, WorkRoot, local site/DB, and remote runtime identities.
- Removed implicit deploy.config.ps1 fallback; menu now selects only explicit profiles from D:\wordpress-ssh-deploy\profiles.
- Added read-only onboard-site.ps1 and menu onboarding/revalidation actions.
- Pull validation now accepts automatic server table discovery with a configurable minimum sanity floor when no exact pull count is set.
- Updated private local profiles no longer share local paths, DB, SiteId, or WorkRoot.
- Created D:\wordpress-ssh-deploy\profiles, tools, and per-site sites/backups/logs directories; copied the local WP-CLI and profiles there.

CHECKS:
- Full Pester: 149 passed, 0 failed.
- Configuration tests: 30 passed; pull tests: 81 passed.
- PowerShell parser: clean for changed scripts/module.
- git diff --check: clean.
- Both D: profile onboarding preflights: READY; no server or database was contacted.

RISKS:
- Code and metadata remain uncommitted; commit/push and independent review are still pending.
- Existing old C: pull workspaces are preserved and not deleted; new runs use D: and new SiteIds.
- Existing remote runners/profiles were not changed, so live use of the renamed profiles requires a separate rollout plan.

NEXT_ACTION:
- Independent read-only Claude review of profile isolation, explicit selection, D: path policy, and pull table validation; do not commit/push or run live actions before review.

CONTEXT_STATUS: OVERLOADED
LIMIT_STATUS: STOP_AFTER_CHECKPOINT
STOP_AFTER_CHECKPOINT: YES

## TASK: SITE-A-LOCAL-WORDPRESS-BOOTSTRAP

TASK_ID: SITE-A-LOCAL-WORDPRESS-BOOTSTRAP
TASK_NAME: Bootstrap one clean local WordPress target and private site profile for site-a.example
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: main
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: 4ae5be7
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-15)
EXECUTION_APPROVED: YES (2026-08-15)
LIVE_ACTIONS: LOCAL_ONLY

IN_SCOPE:
- create one new local database and a clean local WordPress core target
- bind the private multisite profile to the new local site code repository and work root
- create a Git ignore boundary for core, runtime files, backups, and secrets

OUT_OF_SCOPE:
- VPS changes, SSH onboarding, remote runner installation, pull, deploy, SQL import, rollback, commit, or push

RESULT:
- Created the empty local site database with utf8mb4 encoding.
- Bootstrapped a clean WordPress core and private local `wp-config.php` in the separate site repository; runtime salts are newly generated and not tracked.
- Created the private work root and updated the ignored profile with `SiteId`, `CodeRepositoryPath`, and the new local target values.
- Local Laragon URL returned the expected WordPress-install redirect; the database intentionally contains zero tables until a separately approved verified pull/apply.

CHECKS:
- Private profile validation passed.
- Local database table count: 0.
- PHP syntax check passed for generated `wp-config.php`.
- Local HTTP returned 302 for the WordPress install flow.
- Git-ignore policy excludes WordPress core, runtime files, and `wp-config.php`; only the new `.gitignore` is uncommitted in the separate site repository.

RISKS:
- No VPS, SSH, remote runner, pull, deploy, SQL import, rollback, commit, or push action was performed.
- The private site repository contains only its baseline `.gitignore`; it must receive site code only after a separately approved pull/apply or local implementation task.

NEXT_ACTION:
- Resume the already approved root-wrapper VPS rollout; do not run pull or deploy.

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: STOP_AFTER_CHECKPOINT
STOP_AFTER_CHECKPOINT: YES

## TASK: SITE-A-PULL-DB-WPCLI-FIX

TASK_ID: SITE-A-PULL-DB-WPCLI-FIX
TASK_NAME: Use WP-CLI for production pull exports and verify the full local apply
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

BRANCH: main
WORKTREE: dedicated Codex worktree f6a5
BASE_COMMIT: 4ae5be7
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-15)
EXECUTION_APPROVED: YES (2026-08-15)
LIVE_ACTIONS: PRODUCTION_READ_ONLY_PULL_AND_LOCAL_APPLY

IN_SCOPE:
- use WP-CLI db export for the production pull backup path where mysqldump failed
- add pull-db regression coverage and update the production runner
- pull the production site into a verified workspace and apply it to the one local test copy
- verify active table prefix, local URL, uploads, and visible homepage

OUT_OF_SCOPE:
- production database/site writes beyond temporary pull artifacts and server backup creation
- deleting inactive wp_* tables, remote cleanup, rollback, commit, push, merge, or Claude review

RESULT:
- Updated server-deploy.sh pull backup to export the active configured tables through WP-CLI.
- Installed the updated runner on the target VPS.
- Completed pull-full into the verified workspace 20260815-131419; the remote production site remained read-only.
- Applied the verified database and themes/plugins/uploads to the single local test copy after creating local backups.
- Changed the local private wp-config.php prefix to the configured local prefix and bootstrapped an empty local database so the apply backup guard could operate.
- Removed only the absent optional wp-content/mu-plugins path from the ignored site profile.

CHECKS:
- Full Pester: 146 passed, 0 failed.
- Direct pull-db smoke and git diff --check passed.
- Pull workspace SQL verified: 18 tables with the configured prefix; file archive verified and applied.
- Local verification: 18 tables, configured local home/siteurl, HTTP 200, and upload files present.
- Browser screenshot captured showing the pulled local homepage and media.

RISKS:
- Code, tests, and project metadata are uncommitted; no push or merge was performed.
- Independent Claude review remains required before commit/push.
- Production wp-content/mu-plugins does not exist and is intentionally not included in this site profile.

NEXT_ACTION:
- Stop for independent read-only Claude review; do not commit/push or deploy without a separate approval.

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: STOP_AFTER_CHECKPOINT
STOP_AFTER_CHECKPOINT: YES

## TASK: SDOUTDOORLIVING-ROOT-WRAPPER-LOCK-ORDER

TASK_ID: SDOUTDOORLIVING-ROOT-WRAPPER-LOCK-ORDER
TASK_NAME: Keep the deploy lock through root ownership restoration and release it reliably after failure
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: COMMITTED_PUSHED

BRANCH: main
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: 2a338f6
LAST_SYNC_COMMIT: 4ae5be7
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-14)
EXECUTION_APPROVED: YES (2026-08-14, local implementation and tests only)
LIVE_ACTIONS: NOT_EXECUTED

IN_SCOPE:
- preserve the deploy lock through root ownership restoration
- release the lock after both successful and failed ownership restoration
- behaviorally verify lock ordering with the fake-root smoke

OUT_OF_SCOPE:
- VPS installation, SSH onboarding, deploy, pull, rollback, database mutation, commit, push, merge, or cleanup of remote backups

RESULT:
- Ownership restoration now runs while the deploy lock is still held.
- Lock release runs after both successful and failed ownership restoration, before returning the final operation status.
- The fake-root smoke rejects any ownership restore that begins after lock release and still verifies lock removal after a failed chown.

CHECKS:
- Full Pester: 145 passed, 0 failed.
- Root ownership smoke and `git diff --check` passed.

RISKS:
- No VPS installation, SSH onboarding, deploy, pull, rollback, database mutation, commit, push, or merge was performed.

NEXT_ACTION:
- resume the separately approved VPS wrapper rollout; do not deploy, pull, or mutate the remote database

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: STOP_AFTER_CHECKPOINT
STOP_AFTER_CHECKPOINT: YES

## TASK: SDOUTDOORLIVING-ROOT-WRAPPER-REVIEW-ROUND2

TASK_ID: SDOUTDOORLIVING-ROOT-WRAPPER-REVIEW-ROUND2
TASK_NAME: Close round-two independent review findings for root UID detection, ownership cleanup, and behavioral tests
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: READY_TO_COMMIT

BRANCH: main
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: 2a338f6
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-14)
EXECUTION_APPROVED: YES (2026-08-14, local implementation and tests only)
LIVE_ACTIONS: NOT_EXECUTED

IN_SCOPE:
- fail-closed root UID detection in wrapper and server runner
- lock-safe ownership restoration including WordPress runtime files
- behavioral fake-root tests for ownership and failed chown cleanup
- directly related wrapper hardening and regression checks

OUT_OF_SCOPE:
- VPS installation, SSH onboarding, deploy, pull, rollback, database mutation, commit, push, merge, or cleanup of remote backups

RESULT:
- Root wrapper now sets a fixed system PATH before UID detection and rejects an unavailable or malformed UID.
- Server runner validates its effective UID fail-closed, requires `getent` for root policy validation, and no longer inherits `SCP_BIN` from the SSH environment.
- Lock cleanup runs before ownership restoration; completion output is emitted only after successful cleanup.
- Ownership restoration now covers `.htaccess`, `wp-content/cache`, and `wp-content/upgrade` after WP-CLI cleanup.
- Added behavioral fake-root smoke coverage for invalid UID, missing owner policy, runtime ownership restoration, failed `chown`, suppressed success output, and lock removal.

CHECKS:
- Full Pester: 145 passed, 0 failed.
- Shell syntax checks passed for runner, wrapper, and root ownership smoke.
- Server safety smoke, database rollback smoke, root wrapper smoke, root ownership smoke, and `git diff --check` passed.

RISKS:
- No VPS installation, SSH onboarding, deploy, pull, rollback, database mutation, commit, push, or merge was performed.
- The generic root wrapper has not yet been installed or exercised against a real server.

NEXT_ACTION:
- stop for a new independent read-only Claude review before commit/push or VPS rollout

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: STOP_AFTER_CHECKPOINT
STOP_AFTER_CHECKPOINT: YES

## TASK: SDOUTDOORLIVING-ROOT-WRAPPER-REVIEW-FIXES

TASK_ID: SDOUTDOORLIVING-ROOT-WRAPPER-REVIEW-FIXES
TASK_NAME: Close independent-review findings for the generic root SSH wrapper and server ownership restoration
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: READY_FOR_REVIEW

BRANCH: main
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: 2a338f6
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-14)
EXECUTION_APPROVED: YES (2026-08-14, local implementation and tests only)
LIVE_ACTIONS: NOT_EXECUTED

RESULT:
- Added the generic `root-ssh-wrapper.sh` with fixed runner/tmp protocol, strict command parsing, path containment, and no interactive shell.
- Added profile-scoped `UseLegacyScp`; legacy `scp -O` is no longer global.
- Added wrapper-safe configuration/path validation and root-runner owner/group policy with cleanup-time ownership restoration.
- Added wrapper adversarial smoke coverage and updated generic documentation/examples.

FILES_CHANGED:
- README.md
- deploy.config.example.ps1
- deploy.ps1
- root-ssh-wrapper.sh
- server-deploy.sh
- server.config.example.sh
- src/WordPressSshDeploy.psm1
- tests/configuration.Tests.ps1
- tests/quoting.Tests.ps1
- tests/root-ssh-wrapper.smoke.sh
- tests/safety.Tests.ps1
- tests/server.Tests.ps1

CHECKS:
- Full Pester: 144 passed, 0 failed.
- Shell syntax checks passed for `server-deploy.sh`, `root-ssh-wrapper.sh`, and wrapper smoke.
- Server safety smoke and root wrapper smoke passed.
- `git diff --check` passed.

RISKS:
- No live VPS installation, SSH onboarding, deploy, pull, rollback, commit, push, or merge was performed.
- Independent Claude review is required before any commit/push or live rollout.

NEXT_ACTION:
- Stop for independent read-only Claude review.

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: STOP_AFTER_CHECKPOINT
STOP_AFTER_CHECKPOINT: YES

## TASK: MULTISITE-FOUNDATION-REVIEW-FIXES

TASK_ID: MULTISITE-FOUNDATION-REVIEW-FIXES
TASK_NAME: Correct independent review findings for the single-local-copy multisite foundation
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: READY_FOR_COMMIT_PUSH

BRANCH: main
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: 1ff1287
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-13)
EXECUTION_APPROVED: YES (2026-08-13, local implementation and tests only)
LIVE_ACTIONS: NOT_EXECUTED

RESULT:
- `apply-pull` backs up, imports, URL-rewrites and rolls back the same `LocalDbName` used by `LocalWpPath`; the former separate target database contract was removed.
- Downloaded archives, extracted SQL and extracted files tree are bound to the manifest before apply.
- Backup cleanup shares one retention planner, preserves the newest backup group, and a retention failure cannot roll back a completed apply.
- Local core is preserved and structurally checked in the working copy; an optional expected core version is checked through WP-CLI.
- Menu shows profile context and confirms the selected site/server or local database; site Git verifies branch, cleanliness and upstream.
- Tracked AI metadata no longer contains real infrastructure paths, host values, ports, database prefixes or URLs.
- Legacy `LocalDatabaseTarget` was removed from the two ignored private profiles. They intentionally remain blocked until their operator supplies the required `SiteId`, `CodeRepositoryPath` and `WorkRoot` values.

CHECKS:
- Full Pester suite: 139 passed, 0 failed.
- PowerShell parser: deploy, module, management scripts and pull tests passed.
- `git diff --check`: passed.
- Direct local Bash invocation is blocked by the Windows/WSL sandbox; shell parsing passed inside the Pester test harness.

RISKS:
- A live pull/apply remains unexecuted and requires a separate approved rollout after review.
- Manual restoration of a successfully applied local backup remains a follow-up command; automatic rollback covers failed apply only.

SCOPE:
- Reconcile apply-pull with one working local WordPress copy and its LocalDbName.
- Fix backup retention, extracted-artifact integrity, local core policy, menu and site Git safeguards.
- Redact real infrastructure values from tracked AI metadata.

OUT_OF_SCOPE:
- Live SSH, server changes, database imports, rollback, commit, push, merge and production rollout.

NEXT_ACTION:
- Commit and push approved after independent review and P2 follow-up checks; no live action is included.

## TASK: MULTISITE-FOUNDATION-MVP

TASK_ID: MULTISITE-FOUNDATION-MVP
TASK_NAME: Multi-site profile foundation and guarded management workflow
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: READY_FOR_REVIEW

BRANCH: main
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: 1ff1287
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-13)
EXECUTION_APPROVED: YES (2026-08-13, local implementation and tests only)
LIVE_ACTIONS: NOT_EXECUTED

### RESULT

- Разделены `ToolRoot`, `CodeRepositoryPath` и профильный `WorkRoot`; workspace pull теперь привязан к `SiteId`.
- Добавлены `PullContentPaths`, `PullMediaPaths`, `CorePolicy`, отдельный `ExpectedPullDbTableCount` и настройки локальной ротации backup.
- Pull создаёт `manifest.json` с профилем, классами путей и SHA-256 архивов; apply-pull проверяет manifest и хэши до локальной записи.
- Добавлены JSONL run logs, локальная ротация backup по количеству/возрасту/размеру и удалённая ротация database/protected backup.
- Добавлены `site-git.ps1`, read-only `verify.ps1`, `backup-cleanup.ps1` и guarded `menu.ps1`; Git-команды работают только с репозиторием сайта, не с репозиторием инструмента.
- Обновлены example config, README и regression-тесты; локальные pull-workspaces и remote attachments остаются в `.gitignore`.

### CHECKS

- Full Pester: 135 passed, 0 failed.
- PowerShell parser/import: passed for deploy, menu, site-git, verify and relevant tests.
- Git Bash `-n server-deploy.sh`: passed.
- `git diff --check`: passed; warnings только о возможной нормализации LF/CRLF Git.
- Live SSH, staging/production pull or deploy, database import, rollback, commit, push, merge and Claude review: not executed.

### RISKS

- Existing private site profiles must add `SiteId`, `CodeRepositoryPath`, and `WorkRoot` before use.
- Superseded by MULTISITE-FOUNDATION-REVIEW-FIXES: the one supported policy is `preserve-local-core` for the existing working local installation.
- New runner retention and profile behavior require a separate staging rollout and visible marker check.

NEXT_ACTION:
- Independent read-only Claude review of the local diff; after review, decide whether to commit/push and schedule staging rollout.

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: STOP_AFTER_CHECKPOINT
STOP_AFTER_CHECKPOINT: YES

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
- Историческая side-by-side модель с отдельной `LocalDatabaseTarget` заменена единым локальным рабочим сайтом: подтверждённый apply создаёт backup и восстанавливает его при ошибке.
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
PLAN_SUMMARY: Verify the local PHP/MySQL environment; create only a new fixture database and local WordPress directory; then update only the ignored fixture configuration. Stop on an existing database, directory, or database authentication requirement.
PLAN_APPROVED: YES (2026-08-10)
EXECUTION_APPROVED: YES (2026-08-10)

IN_SCOPE:
- read-only Laragon capability and collision checks
- new database wordpress_staging_fixture only
- new local WordPress fixture at a private local path only
- ignored fixture deploy.config.ps1 update to actual local paths

OUT_OF_SCOPE:
- any existing Laragon database, site, configuration, hosts file, or virtual host
- remote staging, production, GitHub, db/full deploy, and rollback test

ALLOWED_FILES:
- .ai/STATE.md
- .ai/CHANGELOG.md
- .ai/HANDOFF.md
- dedicated fixture workspace private config only
- a private local fixture path only

RISKS:
- local database creation and WordPress installation are intentionally isolated but still write to Laragon
- this task must stop if root database access is not passwordless or the requested names already exist

NEXT_ACTION:
- prepare a separately approved DB-only staging smoke plan; do not deploy yet

CONTEXT_STATUS: NORMAL
LIMIT_STATUS: SAVE
STOP_AFTER_CHECKPOINT: YES

RESULT:
- created only a new local fixture database and WordPress fixture at a private local path
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


## TASK: DEPLOY-BIDIRECTIONAL-SYNC-REVIEW-FIXES-ROUND3

TASK_ID: DEPLOY-BIDIRECTIONAL-SYNC-REVIEW-FIXES-ROUND3
TASK_NAME: Third-round review fixes for SQL import and prefix validation
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: COMMITTED_PUSHED

BRANCH: main
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: 626bddf
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-13)
EXECUTION_APPROVED: YES (2026-08-13, local implementation and tests only)

RESULT:
- Full deploy now sends ordinary `SYNC_PATHS` and separate `FULL_SYNC_PATHS`; the runner validates both and selects the effective list by mode.
- Server protected policy is authoritative: ordinary deploys send no protected list, while explicit replacement must match `SERVER_PROTECTED_PATHS`; ordinary sync rejects protected paths.
- Native SQL import forces a no-preamble console encoding before Windows PowerShell creates StandardInput, then streams the raw bytes; apply-pull checks the local WordPress prefix with StringComparison.Ordinal before import.
- Database rollback has one owner and starts only after import begins; protected transient files are registered in the trap, restored on failure, and replaced after remote WP-CLI cleanup.
- Sync-path containment now covers both ordinary and full lists.
- Local pull workspaces and Codex attachment directories are excluded from Git.
- Independent Round3 review passed; commit `03d36eb` was pushed to `origin/main`.

CHECKS:
- Full Pester suite: 126 passed, 0 failed.
- PowerShell parser checks passed for deploy.ps1 and WordPressSshDeploy.psm1.
- POSIX shell syntax check passed for server-deploy.sh.
- git diff --check passed.
- Independent server smoke passed: full ordinary-path policy mismatch and protected ordinary-sync rejection.
- Server smoke also passed ordinary preflight with a declared protected policy.

RISKS:
- Protected runner rollout, staging pull, and real local apply remain unexecuted.
- FullSyncPaths/FullPullPaths are explicit configuration lists; they must be completed per site before claiming a 100% site transfer.
- Protected server runner/config/keys remain outside ordinary Git deployment and require a separate protected rollout.
- No live SQL import or rollback was executed; byte-stream and rollback behavior are covered by local fixtures.
- No live server protected replacement was executed.

NEXT:
- Use separate approvals for protected runner rollout and staging DB/pull smoke; do not run live actions as part of this commit.

## TASK: STAGING-PULL-LOCAL-APPLY-VISIBLE

TASK_ID: STAGING-PULL-LOCAL-APPLY-VISIBLE
TASK_NAME: Apply verified staging pull to local WordPress and verify visibly
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: READY_FOR_REVIEW

BRANCH: main
WORKTREE: dedicated Codex worktree f6a5
BASE_COMMIT: 1ff1287
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-13)
EXECUTION_APPROVED: YES (2026-08-13)

RESULT:
- Pull runner exports only the active configured-prefix tables; inactive alternative-prefix tables were not exported or deleted.
- Full staging pull completed to `.pull\\20260813-180905` with remote DB backup, verified SQL, code, themes, plugins, and uploads archive.
- Local apply created a DB/files backup, imported the verified SQL, mapped URLs to the Laragon vhost, and replaced configured full-pull paths.
- Local homepage visibly shows marker `STAGING-PULL-FULL-VERIFY-20260813-01`.
- Screenshot saved outside the repository at `staging-pull-local-homepage.png`.

CHECKS:
- Full Pester suite: 127 passed, 0 failed before the final local backup-path fix; pull suite: 70 passed, 0 failed after it.
- Staging pull artifact: 14 CREATE TABLE statements, all active prefix, zero foreign/`wp_*` tables.
- Local verification: home/siteurl used the private local URL; active configured-prefix table count matched; HTTP 200 and marker visible.
- Local DB backup exists under `D:\\laragon\\backups\\wordpress-staging-fixture`.

RISKS:
- Current code and tests are uncommitted; no push or merge was performed.
- The live runner was updated on staging and its previous version was saved remotely.
- Independent Claude review is still required before commit/push of these new fixes.

NEXT:
- Stop for independent read-only Claude review.

## TASK: PORTFOLIO-PRODUCTION-READONLY-PULL

TASK_ID: PORTFOLIO-PRODUCTION-READONLY-PULL
TASK_NAME: Production portfolio full read-only pull to local side-by-side workspace
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: READY_FOR_REVIEW

BRANCH: main
WORKTREE: dedicated Codex worktree f6a5
BASE_COMMIT: 1ff1287
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-13)
EXECUTION_APPROVED: YES (2026-08-13)

RESULT:
- Added explicit production read-only pull guard: private `AllowProductionPull = $true` plus CLI `-AllowProductionPull`; production db/full/apply-pull remain forbidden.
- Installed a separate production-read-only pull runner/policy; the prior remote runner/config was backed up in the private server runtime.
- Completed a production-read-only `pull-full` into a private local workspace; working local site and database were not replaced.
- Fixed UTF-8 tar header decoding so Cyrillic media names survive extraction on Windows.

CHECKS:
- Production pull artifacts: expected SQL table set and selected-file count matched between remote export and local workspace.
- Remote DB backup exists; pull temp artifacts were cleaned; inactive tables and production content were not deleted or rewritten.
- Full Pester suite: 133 passed, 0 failed; `sh -n` runner and smoke scripts passed; `git diff --check` passed.

RISKS:
- The portfolio staged copy is verified but not applied to the local WordPress site; local DB target remains unused.
- Current code, tests, and private profile changes are uncommitted; no push, merge, local apply, production deploy, rollback, or Claude review performed.
- The successful `.pull` workspace is a large ignored runtime artifact and is intentionally excluded from the private-material scan.

NEXT:
- Stop for independent read-only Claude review. Local apply requires a separate plan and double approval.

## TASK: PORTFOLIO-LOCAL-FULL-APPLY

TASK_ID: PORTFOLIO-LOCAL-FULL-APPLY
TASK_NAME: Apply verified portfolio pull to a side-by-side local WordPress copy
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: READY_FOR_REVIEW

BRANCH: main
WORKTREE: dedicated Codex worktree f6a5
BASE_COMMIT: 1ff1287
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-13)
EXECUTION_APPROVED: YES (2026-08-13)

RESULT:
- Bootstrapped a private local target from an existing local WordPress core, using a separate local database under the superseded two-local-copy design.
- Created database and file backups in a private local backup directory before apply.
- Applied a verified pull workspace into a private local target database and local files, including uploads/media; mapped `home` and `siteurl` to the private local URL.
- Removed only bootstrap leftovers absent from the verified pull, then restored the 16 standard WordPress root/core files required locally because the production pull profile does not include them as sync paths. No stale `et-cache` files remain.

CHECKS:
- Local HTTP: 200; homepage visibly rendered the expected pulled content.
- Local DB: `home` and `siteurl` pointed to the local URL; active configured-prefix table count matched; this historical run used the superseded separate-target design.
- Files: all 9,151 verified pulled files present by exact path/size comparison; 0 missing and 0 stale pulled-path files; 1,860 upload files present. Local core bootstrap files are tracked separately from the 9,151 pull files.
- Screenshot retained only in private local evidence storage.
- Full Pester suite: 133 passed, 0 failed; shell syntax checks and `git diff --check` passed.

RISKS:
- Production was read-only throughout; no production deploy, SQL write, cleanup of remote inactive tables, rollback, commit, push, merge, or Claude review was performed.
- Current repository code/profile changes remain uncommitted. Independent Claude review is still required before commit/push.
- Exact byte-level hash comparison of all files was not required after the verified archive extraction; current path/size comparison and visible runtime verification passed.

NEXT:
- Stop for independent read-only Claude review.

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

## TASK: WP-CLI-ROOT-PULL-FIX-REVIEW-FOLLOWUP

TASK_ID: WP-CLI-ROOT-PULL-FIX-REVIEW-FOLLOWUP
TASK_NAME: Close independent review findings for WP-CLI root compatibility pull coverage
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
IMPLEMENTER: CODEX
REVIEWER: CLAUDE
STATUS: READY_FOR_REVIEW

BRANCH: codex/multisite-profile-isolation-p3-followup
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BASE_COMMIT: c219297
WORK_LOCK: CODEX

CRITICAL: YES
PLAN_APPROVED: YES (2026-08-17)
EXECUTION_APPROVED: YES (2026-08-17, local implementation and tests only)
LIVE_ACTIONS: NONE

IN_SCOPE:
- pass `--allow-root` to WP-CLI when the runner's effective UID is 0
- add behavioral root and non-root runner regression coverage
- correct smoke stderr capture and reduce unavailable-command assumptions
- synchronize current metadata without rewriting journal history
- run local shell, Pester, and diff checks

OUT_OF_SCOPE:
- VPS, SSH, database, pull, deploy, rollback, cleanup, runner reinstall, and merge
- private profiles and server configuration

RESULT:
- `server-deploy.sh` now adds `--allow-root` only for root execution; non-root execution keeps the prior invocation.
- `tests/wp-cli-root.smoke.sh` now runs both root and non-root cases; the fake WP-CLI rejects a missing root flag and an unexpected root flag.
- Smoke diagnostics now remain visible when the runner fails; each root/non-root case clears the prior pull artifact before execution.
- Smoke uses a PID-suffixed temporary root and real `awk`, `gzip`, and `df` when available, with portable fallbacks otherwise.
- The prior metadata claim about stderr capture was corrected by this follow-up; the CHANGELOG remains append-only.

CHECKS:
- Full Pester: 167 passed, 0 failed; targeted server/pull tests: 99 passed, 0 failed.
- Root smoke and shell syntax pass under Laragon Git Bash.
- `git diff --check`: PASS.
- Mutation checks: removing the root flag fails; always passing the root flag fails the non-root case.
- No VPS, SSH, database, pull, deploy, rollback, runner reinstall, commit, push, or merge was performed.

NEXT:
- Commit and push this approved branch, then stop for independent read-only review.
