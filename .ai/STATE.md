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

ACTIVE_TASK_IDS:
- DEPLOY-REVIEW-FIXES-TRAP

Перед работой агент обязан выбрать ровно один `TASK_ID` из списка и работать только в его блоке.

## TASK: DEPLOY-SAFETY-STAGES-1-5

TASK_ID: DEPLOY-SAFETY-STAGES-1-5
TASK_NAME: Безопасность и надёжность deploy, этапы 1–5
DOMAIN: DEPLOYMENT
TASK_LEAD: CODEX
REVIEWER: CLAUDE
STATUS: CHECKPOINT_COMPLETE

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
