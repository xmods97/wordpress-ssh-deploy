# Матрица компонентов deploy

Каждый сайт использует один и тот же contract, но сам профиль и server policy явно разрешают только нужные компоненты.

| Режим | Компоненты |
| --- | --- |
| `code` | `SyncPaths` (код) |
| `db` | SQL import с remote backup и rollback |
| `code-db` | код, затем БД |
| `uploads` | только `wp-content/uploads` |
| `plugins` | только `PluginSyncPaths` |
| `mu-plugins` | только `MuPluginSyncPaths` под `wp-content/mu-plugins` |
| `components` | выбранное сочетание `code`, `db`, `uploads`, `plugins`, `mu-plugins` в одном запуске |
| `full` | код, БД, uploads, настроенные plugin paths и настроенные MU-plugin paths |
| `preflight` | проверка без deploy-веток |

`SyncPaths`, `PluginSyncPaths` и `MuPluginSyncPaths` разделены и ограничены runner-ом: code допускает только дочерние темы в `wp-content/themes`, plugins — только `wp-content/plugins`, а `mu-plugins` — только явно перечисленные дочерние пути в `wp-content/mu-plugins`. `wp-config.php`, Divi и широкие/неявные content paths отвергаются до копирования.

Для одного запуска со всеми компонентами используй явный полный снимок uploads:

```powershell
.\deploy.ps1 -Mode components -Components code,db,uploads,plugins,mu-plugins -UploadsTransferMode full -ConfirmUploadsFullSnapshot
.\deploy.ps1 -Mode components -Components code,db,uploads,plugins,mu-plugins -UploadsTransferMode full -ConfirmUploadsFullSnapshot -PreflightOnly
```

Первая команда выполняет запуск. Вторая проверяет локальные источники и общий remote readiness; сам выбранный набор и server allowlists runner повторно проверяет перед изменением файлов сайта или БД. Клиент собирает SQL, ZIP полного дерева uploads и манифест; runner применяет code, plugins и MU-plugins, затем импортирует БД и атомарно заменяет дерево uploads после проверки манифеста. В Production сочетание `db` с `uploads`, `plugins` или `mu-plugins` требует отдельного opt-in на уровне профиля и server policy.

Комбинированный запуск сохраняет прежние asset-компоненты перед заменой и автоматически откатывает импорт БД при ошибке БД или uploads. Уже заменённые code, plugins и MU-plugins остаются в целевой системе при последующей ошибке; для их возврата используй сохранённый и проверенный asset backup.

Перед full-equivalent заменой code, настроенных plugin- и MU-plugin путей и uploads runner сохраняет их текущее состояние в `BACKUP_DIR/component-backup-<timestamp>/`: `asset-backup.tar`, `manifest.tsv` и SHA-256. В архив входят целые настроенные директории и весь `wp-content/uploads`, если передан uploads archive. Проверяются свободное место, список путей архива и checksum; каталог имеет права `700`, файлы — `600`, владелец — `root`. После успешной операции сохраняются два последних проверенных full asset backup. При ошибке retention не запускается, чтобы сохранить точку восстановления.

Для отдельного согласованного rollback сначала проверь checksum и `manifest.tsv`, затем замени каждый текущий target из манифеста: существовавшие до deploy пути удали и извлеки из архива, а ранее отсутствовавшие оставь удалёнными. Простое извлечение поверх текущих каталогов не удалит новые файлы неудачного релиза.

## Политика

- `AllowedDeployModes` в локальном profile — разрешённое подмножество режимов для сайта.
- `SERVER_ALLOWED_DEPLOY_MODES` на сервере — независимая верхняя граница.
- Старые profiles без `AllowedDeployModes` сохраняют legacy policy до отдельной миграции. Для старого production server config без `SERVER_ALLOWED_DEPLOY_MODES` runner fail-closed оставляет только `preflight`, `code` и gated `full`; новые независимые компоненты требуют явного server allowlist.
- Production `full` дополнительно сохраняет existing dual opt-in. Другие компоненты разрешаются только после явной миграции обоих policy layers.
- `-SkipUploads` удалён из нового contract: `code-db` однозначно означает код + БД без uploads.

## Bella SSH transport contract

Bella wrapper принимает тот же assignment-протокол, который формирует клиент: `SYNC_PATHS`, `PLUGIN_SYNC_PATHS`, `MU_PLUGIN_SYNC_PATHS`, `ALLOWED_DEPLOY_MODES`, `DEPLOY_MODE`, `PRODUCTION_FULL_OPT_IN`, `SQL_FILE` и `UPLOADS_ZIP` вместе с общими site/path параметрами. Пустые `PLUGIN_SYNC_PATHS=''` и `MU_PLUGIN_SYNC_PATHS=''` допустимы для режимов без соответствующего sync и проверяются как отдельные значения.

Wrapper проверяет single-quoted values, уникальность assignments, режимы, plugin/MU-plugin paths, production full opt-in и фиксированный runner path; неподдержанные токены отклоняются до запуска runner. MU-plugins не получают скрытого разрешения: и клиент, и wrapper, и runner требуют отдельный режим, явный allowlist и согласованный server policy.

## Rollout

Bella Maria — пилот. После independent review для неё создаётся отдельная migration/install задача с новой парой approvals. Остальные сайты мигрируются по одному: profile capability, private server policy, runner SHA install, preflight, затем отдельное production approval для выбранного режима.
