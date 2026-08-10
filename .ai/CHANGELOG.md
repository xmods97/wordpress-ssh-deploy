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
