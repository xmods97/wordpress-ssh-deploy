# AI HANDOFF

TEMPLATE_VERSION: existing-projects-v2
HANDOFF_STATUS: READY
TASK_ID: MULTISITE-PROFILE-ISOLATION-PR-FIXES
FROM_AGENT: CODEX
TO_AGENT: CODEX
PROJECT_LEAD: CODEX
TASK_LEAD: CODEX
WORK_LOCK: CODEX
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BRANCH: codex/multisite-profile-isolation-p3-followup
COMMIT: 5af268b (pushed; code fixes in d9b6815)

## Цель

Закрыть замечания PR review по изоляции локальных backup-каталогов, переносимости onboarding и mutation-proof проверке exact pull-table manifest. Исправления опубликованы в ветке PR #2; merge и live-действия не выполнялись.

## Контекст и checkpoint

Безопасная загрузка профилей использует `HashtableAst.SafeGetValue()` без dot-sourcing и принимает только literal AST-узлы; динамические, типовые и method expressions отклоняются. Pull требует exact `ExpectedPullDbTableCount`; устаревший `MinimumPullDbTableCount` отклоняется. В PR добавлены: `LocalBackupDirectory` в identity-проверку, drive-independent onboarding с абсолютными существующими путями, мутационные тесты `Assert-PullManifest`, и документация о WP-CLI export на сервере против локального `mysqldump`. Full Pester: 166/166, targeted configuration/pull: 128/128, parser, shell checks и `git diff --check` PASS.

## Выполнено в этом checkpoint

- Shared local backup directories now fail profile-isolation before cleanup.
- Onboarding no longer assumes drive `D:` and reports absolute/missing local paths.
- Manifest exact-count mutations are rejected by real apply-pull validation tests.
- README and PR description document the remote WP-CLI pull export, local mysqldump boundary, and runner reinstall requirement.
- Existing private profiles, VPS, database, deploy, rollback, merge, and profile deletion remain untouched.

## Следующий шаг

Независимый read-only review PR #2. Merge, VPS, DB, deploy, rollback и редактирование private-профилей требуют отдельного плана и подтверждений.
