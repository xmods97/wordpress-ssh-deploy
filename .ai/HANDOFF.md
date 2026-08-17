# AI HANDOFF

TEMPLATE_VERSION: existing-projects-v2
HANDOFF_STATUS: READY
TASK_ID: WP-CLI-ROOT-PULL-FIX-REVIEW-FOLLOWUP
FROM_AGENT: CODEX
TO_AGENT: CODEX
PROJECT_LEAD: CODEX
TASK_LEAD: CODEX
WORK_LOCK: CODEX
WORKTREE: dedicated Codex worktree (local path intentionally omitted)
BRANCH: codex/multisite-profile-isolation-p3-followup
COMMIT: c219297 (working tree contains approved uncommitted local fix)

## Цель

Закрыть независимые review-замечания по WP-CLI root-run pull: корректно захватить stderr, доказать отсутствие `--allow-root` для non-root и сохранить переносимость локального smoke-теста. VPS, SSH, БД, pull retry и другие live-действия остаются за пределами текущего этапа.

## Контекст и checkpoint

В `server-deploy.sh` функция `wp_cli()` выбирает root-совместимый вызов по UID; обычный пользовательский вызов не меняется. `tests/wp-cli-root.smoke.sh` выполняет root и non-root сценарии: fake WP-CLI отклоняет отсутствие либо лишнее наличие `--allow-root`. Smoke корректно захватывает stdout/stderr даже при ошибке runner, очищает pull-артефакт между сценариями, не требует внешних `chmod`/`ln`, использует PID-суффикс и условно применяет реальные `awk`/`gzip`/`df`, когда они доступны.

## Выполнено в этом checkpoint

- Runner передаёт `--allow-root` только при effective UID 0.
- Добавлен root compatibility smoke-тест с проверкой завершения pull-экспорта и артефакта.
- Исправлены захват stderr при ошибке, очистка артефакта между сценариями, уникальность временного каталога, root/non-root асимметрия и переносимость smoke без `chmod`/`ln`.
- Metadata синхронизирована с follow-up; старые записи CHANGELOG не переписывались.
- Приватные профили, VPS, БД, deploy, rollback, merge и profile deletion не затрагивались.

## Следующий шаг

Проверки: полный Pester — 167/167, targeted `server.Tests.ps1` и `pull.Tests.ps1` — 99/99; smoke и shell syntax проходят под Laragon Git Bash; mutation-проверки ловят удаление root-флага и его ошибочную передачу non-root; `git diff --check` чист.

Следующий шаг: commit и push этой утверждённой ветки, затем независимый read-only review. После review потребуется отдельное разрешение на reinstall runner и повтор production pull.
