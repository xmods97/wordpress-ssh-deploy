# AI HANDOFF

TEMPLATE_VERSION: existing-projects-v2

HANDOFF_STATUS: READY
TASK_ID: DEPLOY-BIDIRECTIONAL-SYNC-REVIEW-FIXES-ROUND3
TASK_BLOCK_SOURCE: `.ai/STATE.md`
FROM_AGENT: CODEX
TO_AGENT: CLAUDE
CREATED_AT: 2026-08-13
BASE_COMMIT: 626bddf
SOURCE_BRANCH: main
TARGET_BRANCH: main

## CURRENT CHECKPOINT

Codex remains PROJECT_LEAD/TASK_LEAD and owns WORK_LOCK. This handoff requests
independent read-only Claude review only; it does not authorize edits, commit,
push, runner rollout, staging pull, or local apply.

Implemented in the current Codex worktree (uncommitted on `main`):

- Full deploy sends ordinary `SYNC_PATHS` separately from `FULL_SYNC_PATHS`; the
  runner validates both and selects the active list by mode.
- The server protected-path policy is authoritative: ordinary sync sends no
  protected list, while explicit replacement must match the server policy.
- Protected replacement is staged after database import and can restore the
  protected backup on replacement failure; transient protected copies are trap
  managed and removed on success.
- Local `mysql` import forces a no-preamble console encoding before Windows
  PowerShell creates StandardInput, then closes the raw pipe without changing
  SQL bytes; apply-pull checks the staged workspace and compares the local
  table prefix with `StringComparison.Ordinal` before import, and restores the
  local database only after an import has started.
- SyncPaths and FullSyncPaths are both checked for overlap with protected paths.
- `.pull/` and `.codex-remote-attachments/` are ignored and cannot enter a commit accidentally.
- Windows PowerShell 5.1-safe reverse file rollback is covered by a real temp
  file test.

Checks: full Pester suite 126/126; PowerShell parsing passed; `sh -n` and the
server smoke probes passed; `git diff --check` passed. No private configs were
read or changed.

Open: independent review, then separately approved commit/push, protected
runner rollout, real staging pull, and real local apply.

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
