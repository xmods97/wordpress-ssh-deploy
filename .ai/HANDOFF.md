# AI HANDOFF

TEMPLATE_VERSION: existing-projects-v2

HANDOFF_STATUS: ACCEPTED
TASK_ID: STAGING-DB-AFTERMATH-SAFETY
TASK_BLOCK_SOURCE: `.ai/STATE.md`
FROM_AGENT: CODEX
TO_AGENT: CODEX
CREATED_AT: 2026-08-10
BASE_COMMIT: 502a18b
SOURCE_BRANCH: codex/stages-1-5-review-fixes
TARGET_BRANCH: codex/stages-1-5-review-fixes

## Цель

Подготовить безопасный следующий этап после реального staging DB smoke: отдельный план для cleanup случайных `wp_*` таблиц и/или постоянной защиты от table-prefix/case mismatch.

## Выполнено

- Этапы 1–5 и review-fixes находятся в ветке `codex/stages-1-5-review-fixes` (HEAD `502a18b`); ранее прошли 40 тестов.
- Подготовлены isolated fixture repository и cPanel staging `https://staging.example.com/`; code-only smoke прошёл.
- Initial DB smoke exposed a local/remote table-prefix mismatch and added inactive `wp_*` tables without changing active staging content.
- Controlled remediation used a one-run private SQL wrapper that asserted exactly 12 quoted table identifiers and changed only `<staging-prefix-lowercased>` to active Linux prefix `<staging-prefix>`; wrapper removed and config restored after use.
- Remediation DB-only deploy succeeded, created `db-20260810-211841.sql.gz`, skipped Git/uploads, and public staging homepage shows `Staging DB Smoke` marker.
- Активная staging-БД успешно заменена fixture; 12 случайных неактивных `wp_*` таблиц остаются отдельно.

## Изменённые файлы

- Незакоммичены только служебные project-файлы и реестр рисков: `.ai/STATE.md`, `.ai/CHANGELOG.md`, `.ai/HANDOFF.md`, `docs/RISKS-RU.md`.
- Fixture private config restored; SSH keys, SQL, temporary wrapper and server runtime/backup artefacts are not tracked by Git.

## Проверки

- SQL wrapper preflight asserted 12 active `<staging-prefix>*` targets and no source/legacy quoted identifiers.
- Remote post-import: active table count 12, homepage `Staging DB Smoke`, plugin inactive, backup non-empty, HTTPS 200 and public marker present.

## Нерешённые вопросы

- 12 accidental inactive `wp_*` tables remain; removing them requires a new critical plan and backup.
- R-031 is in progress: local source now checks table-prefix/case compatibility, but the current staging runner/private policy still need a separate rollout.
- Откат существует как backup, но deliberate failure/restore не тестировались.

## Риски

- Shared cPanel ownership и PHP 7.4.33 допустимы только для staging.
- Нельзя трактовать успешный smoke как production readiness.

## Следующий шаг

- Next task: plan a code-only staging rollout of the new runner/private-policy guard, using a unique fixture homepage marker for public verification. Do not clean `wp_*` or run rollback without its own backup and double approval.

## Требуемое разрешение

- This checkpoint is complete. A new plan and double approval are required for the staging rollout, `wp_*` cleanup, or rollback test. CODEX remains PROJECT_LEAD/TASK_LEAD and WORK_LOCK owner; Claude is REVIEWER only.

Ограничение: не более 250 слов. Файл перезаписывается для текущей передачи и после принятия получает `HANDOFF_STATUS: ACCEPTED`.


## Роль по умолчанию

Если handoff используется только для подключения Claude к уже существующему проекту:

- `FROM_AGENT: CODEX`;
- `TO_AGENT: CLAUDE`;
- управление не передаётся;
- Claude читает handoff только для review и понимания контекста;
- `TASK_LEAD` и `WORK_LOCK` остаются у Codex.
