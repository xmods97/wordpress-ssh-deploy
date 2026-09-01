# Матрица компонентов deploy

Каждый сайт использует один и тот же contract, но сам профиль и server policy явно разрешают только нужные компоненты.

| Режим | Компоненты |
| --- | --- |
| `code` | `SyncPaths` (код) |
| `db` | SQL import с remote backup и rollback |
| `code-db` | код, затем БД |
| `uploads` | только `wp-content/uploads` |
| `plugins` | только `PluginSyncPaths` |
| `full` | код, БД, uploads и настроенные plugin paths |
| `preflight` | проверка без deploy-веток |

`SyncPaths` и `PluginSyncPaths` разделены и ограничены runner-ом: code допускает только дочерние темы в `wp-content/themes`, plugins — только `wp-content/plugins`. `wp-config.php`, Divi и mu-plugins отвергаются до копирования; для них нужен отдельный будущий компонент и site-specific approval.

## Политика

- `AllowedDeployModes` в локальном profile — разрешённое подмножество режимов для сайта.
- `SERVER_ALLOWED_DEPLOY_MODES` на сервере — независимая верхняя граница.
- Старые profiles без `AllowedDeployModes` сохраняют legacy policy до отдельной миграции. Для старого production server config без `SERVER_ALLOWED_DEPLOY_MODES` runner fail-closed оставляет только `preflight`, `code` и gated `full`; новые независимые компоненты требуют явного server allowlist.
- Production `full` дополнительно сохраняет existing dual opt-in. Другие компоненты разрешаются только после явной миграции обоих policy layers.
- `-SkipUploads` удалён из нового contract: `code-db` однозначно означает код + БД без uploads.

## Bella SSH transport contract

Bella wrapper принимает тот же assignment-протокол, который формирует клиент: `SYNC_PATHS`, `PLUGIN_SYNC_PATHS`, `ALLOWED_DEPLOY_MODES`, `DEPLOY_MODE`, `PRODUCTION_FULL_OPT_IN`, `SQL_FILE` и `UPLOADS_ZIP` вместе с общими site/path параметрами. Пустой `PLUGIN_SYNC_PATHS=''` допустим для режимов без plugin sync и проверяется как отдельное значение.

Wrapper проверяет single-quoted values, уникальность assignments, режимы, plugin paths, production full opt-in и фиксированный runner path; неподдержанные токены отклоняются до запуска runner. Client/runner отклоняют `mu-plugins`, и wrapper не предоставляет им скрытого разрешения.

## Rollout

Bella Maria — пилот. После independent review для неё создаётся отдельная migration/install задача с новой парой approvals. Остальные сайты мигрируются по одному: profile capability, private server policy, runner SHA install, preflight, затем отдельное production approval для выбранного режима.
