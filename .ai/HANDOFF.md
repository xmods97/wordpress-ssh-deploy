# AI HANDOFF

TEMPLATE_VERSION: existing-projects-v2

HANDOFF_STATUS: READY
TASK_ID: DEPLOY-REVIEW-FIXES-TRAP
TASK_BLOCK_SOURCE: `.ai/STATE.md`
FROM_AGENT: CODEX
TO_AGENT: CODEX
CREATED_AT: 2026-08-10
BASE_COMMIT: 938e4ce
SOURCE_BRANCH: codex/stages-1-5-review-fixes
TARGET_BRANCH: codex/stages-1-5-review-fixes

## Цель

Продолжить развитие `wordpress-ssh-deploy` после завершённых этапов 1–5 без потери контекста и границ безопасности.

## Выполнено

- Этапы 1–5 реализованы в родительском commit `938e4ce`.
- Review fixes для cleanup trap, LOCAL_URL и SQL-disk guard проверены 40 тестами и закоммичены локально.
- Project instructions and accepted risks are tracked in the follow-up documentation commit `69ddc47`.

## Изменённые файлы

- Изменены deploy-код, тесты, документация рисков и служебные project-файлы.

## Проверки

- Пройдено 40 тестов, 0 ошибок; `git diff --check` пройден.

## Нерешённые вопросы

- Ветка не объединена с `main`; этап 6 не начинался.

## Риски

- R-026: при одновременной ошибке импорта и rollback требуется ручное восстановление.
- R-026 и ограничения из `docs/RISKS-RU.md` остаются задокументированными.

## Следующий шаг

- Отдельно принять решение о merge/push; production-деплой не выполнять без двойного подтверждения.

## Требуемое разрешение

- none

Ограничение: не более 250 слов. Файл перезаписывается для текущей передачи и после принятия получает `HANDOFF_STATUS: ACCEPTED`.


## Роль по умолчанию

Если handoff используется только для подключения Claude к уже существующему проекту:

- `FROM_AGENT: CODEX`;
- `TO_AGENT: CLAUDE`;
- управление не передаётся;
- Claude читает handoff только для review и понимания контекста;
- `TASK_LEAD` и `WORK_LOCK` остаются у Codex.
