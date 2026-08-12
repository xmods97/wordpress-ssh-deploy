# AI HANDOFF

TEMPLATE_VERSION: existing-projects-v2

HANDOFF_STATUS: READY
TASK_ID: DEPLOY-BIDIRECTIONAL-SYNC
TASK_BLOCK_SOURCE: `.ai/STATE.md`
FROM_AGENT: CLAUDE
TO_AGENT: CODEX
CREATED_AT: 2026-08-12
BASE_COMMIT: b907e4a
SOURCE_BRANCH: agent/deploy-bidirectional-sync
TARGET_BRANCH: main

## Цель

Передать Codex на независимый review реализованное направление pull (staging → local), не изменившее staging, локальную рабочую БД и направление push.

## Выполнено

- Режимы `pull-db`, `pull-files`, `pull-full` и флаги `-DryRun`, `-Confirm`, `-Mirror`; push-режимы `code`, `db`, `full` не изменены.
- Принцип side-by-side: pull ничего не импортирует и не заменяет; `LocalDatabaseTarget` обязан отличаться от `LocalDbName`. Локальный rollback не нужен и намеренно не реализован.
- Проверка артефактов до использования: gzip integrity через ISIZE, структура SQL, точное число таблиц, prefix, отсутствие чужих и смешанных идентификаторов, листинг архива на traversal/symlink/deny-list до распаковки.
- Режимы pull в `server-deploy.sh`: не импортируют, не ротируют backups, не переписывают WordPress; production pull отвергается.
- `-Mirror` fail-closed: отказ и без `AllowDestructiveLocalReplace`, и с ним.

## Изменённые файлы

- `deploy.ps1`, `src/WordPressSshDeploy.psm1`, `server-deploy.sh`, `deploy.config.example.ps1`, `tests/pull.Tests.ps1` (новый), `README.md`, `docs/DEVELOPMENT-PLAN-RU.md`, `docs/RISKS-RU.md`, `.ai/STATE.md`, `.ai/CHANGELOG.md`, `.ai/HANDOFF.md`.
- Всё незакоммичено. Приватные конфигурации не создавались и не читались.

## Проверки

- Полный набор: 107 passed, 0 failed. `git diff --check` чист. PowerShell syntax check по 7 файлам без ошибок. `sh -n` чист для `server-deploy.sh` и обоих тестовых `.sh`.
- Поиск приватных значений по рабочему дереву — ноль совпадений.

## Нерешённые вопросы

- R-032: runner на staging не обновлён, реальный pull невозможен до переустановки.
- R-034: активация скачанной копии остаётся ручной.
- R-035: нужен ли отдельный ожидаемый счётчик таблиц для направления pull.

## Риски

- R-033: режимы pull в runner проверены статически и `sh -n`, но ни разу не исполнялись.
- Успешные mock-тесты нельзя трактовать как готовность к реальному pull.

## Следующий шаг

- Независимый review Codex, затем интеграция. Первый реальный pull требует отдельного плана: переустановка runner, ручное создание пустой `LocalDatabaseTarget`, запуск строго с `-DryRun` до `-Confirm`.

## Требуемое разрешение

- Управление не передавалось: CODEX остаётся PROJECT_LEAD, TASK_LEAD и владельцем WORK_LOCK. Claude выполнял только отдельно назначенную задачу в собственной ветке и worktree. Commit, push, merge, staging deploy, rollback и реальный pull не выполнялись.

Ограничение: не более 250 слов. Файл перезаписывается для текущей передачи и после принятия получает `HANDOFF_STATUS: ACCEPTED`.


## Роль по умолчанию

Если handoff используется только для подключения Claude к уже существующему проекту:

- `FROM_AGENT: CODEX`;
- `TO_AGENT: CLAUDE`;
- управление не передаётся;
- Claude читает handoff только для review и понимания контекста;
- `TASK_LEAD` и `WORK_LOCK` остаются у Codex.
