# AI HANDOFF

TEMPLATE_VERSION: existing-projects-v2
HANDOFF_STATUS: READY
TASK_ID: MULTISITE-PROFILE-ISOLATION-P3-FOLLOWUP
FROM_AGENT: CODEX
TO_AGENT: CODEX
PROJECT_LEAD: CODEX
TASK_LEAD: CODEX
WORK_LOCK: CODEX
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BRANCH: codex/multisite-profile-isolation-p3-followup
COMMIT: 0ff764b (pushed)

## Цель

Закрыть follow-up после ROUND4: устранить вырожденность exact pull-table regression-теста и привести metadata в безопасное, актуальное состояние. Реализация опубликована отдельной веткой; merge и live-действия не выполнялись.

## Контекст и checkpoint

Безопасная загрузка профилей использует `HashtableAst.SafeGetValue()` без dot-sourcing и дополнительно принимает только literal AST-узлы. Null `EndBlock`, dynamic/type/method expressions отклоняются. Pull теперь использует только обязательный exact `ExpectedPullDbTableCount`; устаревший `MinimumPullDbTableCount` отклоняется. Exact pull-проверка количества таблиц покрыта невырожденными тестами: pull-профиль в фикстуре использует 17 таблиц против push-значения 12. `New-ApplyPullPlan` отдельно проверяет оба exact-count поля и передаёт их в table-set validation. WinPS 5.1 подтверждён: full Pester 165/165, pull 88/88, parser, `sh -n` для runner/wrapper и `git diff --check` PASS. Рабочее дерево содержит 17 изменённых tracked-файлов и 2 untracked-файла; все изменения незакоммичены.

## Обязательные пункты

- восстановить append-only структуру `.ai/CHANGELOG.md`, не переписывая опубликованную историю;
- синхронизировать STATE/CHANGELOG; старые root-профили остаются нетронутыми и явно вне этой задачи;
- безопасно обработать `$ast.EndBlock = $null`;
- убрать machine-specific hardcoded profiles path через конфигурацию/явную передачу пути;
- уточнить README о полном data-only контракте;
- вернуть или явно реализовать точную pull-проверку количества таблиц;
- документировать миграцию существующих private pull-профилей на exact `ExpectedPullDbTableCount`;
- переименовать затеняющие `$profile` переменные;
- добавить Pester для parse/dynamic/method отказов.

## Следующий шаг

Проверить опубликованную ветку и при необходимости открыть PR. Merge, VPS, DB, deploy, rollback и редактирование private-профилей требуют отдельного плана и подтверждений.
