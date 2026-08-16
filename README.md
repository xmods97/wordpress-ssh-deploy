# wordpress-ssh-deploy

A small, auditable, multi-site deployment workflow for moving a local WordPress
site to a remote Linux host over SSH. The deploy tool is separate from each
site's private Git repository; a profile binds one site code checkout, one
working-artifact root, one local database, and one remote target.

> [!WARNING]
> `db` and `full` replace the remote database. `full` can also replace the
> configured uploads directory. Both modes are forbidden when the local or
> server environment is `production`.

## Features

- `code`, `db`, and `full` deployment modes
- configurable theme/plugin directories
- remote database backup before import
- WordPress-aware URL replacement through WP-CLI
- optional uploads synchronization
- explicit path and database safety locks
- configurable backup retention
- local and remote preflight checks
- profile-bound pull workspaces with manifest and SHA-256 artifact checks
- separate site Git status/commit/push commands and a guarded PowerShell menu
- local and remote backup retention

## Requirements

Local Windows machine:

- PowerShell 5.1 or newer
- OpenSSH client (`ssh` and `scp`)
- Git
- `mysqldump`
- a local WordPress installation

Remote Linux host:

- SSH access and a checked-out copy of the site repository
- POSIX shell, Git, PHP, WP-CLI, MySQL client tools, and `unzip`
- `rsync` is recommended; `cp` is used as a fallback

## Setup

1. Keep this tool in its own repository; do not copy it into a site's code repository.
2. Copy `deploy.config.example.ps1` to a private site profile under
   `<ProfilesDirectory>\` (for example, a private directory on the D: drive).
3. Set a unique lowercase `SiteId`, `CodeRepositoryPath`, and `WorkRoot`.
   `CodeRepositoryPath` is the private Git repository for this site; `WorkRoot`
   stores pull workspaces, logs, and local deployment artifacts outside both repos.
   When migrating an older private profile, remove `LocalDatabaseTarget`: it is
   intentionally unsupported. `apply-pull` backs up and replaces the one local
   WordPress database, `LocalDbName`, after its separate confirmation.
4. Select the target `Environment`: `development`, `staging`, or `production`.
5. Fill every path, host, database safety lock, and `SyncPaths` entry.
6. Set `ExpectedRemoteDomain`, `ExpectedRemoteWpPath`,
   `ExpectedRemoteDbName`, and `ExpectedDbTablePrefix` to the exact expected
   target values.
7. Keep all private `deploy.config*.ps1` profiles private. They are excluded by
   `.gitignore`. Select a profile explicitly with `-ConfigPath` or choose it in
   `menu.ps1`; there is no implicit default profile. Pass the shared profile
   catalog explicitly with `-ProfilesDirectory`, or set
   `WORDPRESS_SSH_DEPLOY_PROFILES_DIRECTORY` for the menu. Isolation validation
   scans that catalog and the tool root's `deploy.config*.ps1` files, so stale
   copies cannot silently coexist with an active profile.
   Profile files are strict data-only PowerShell files: they must contain exactly
   one direct `$DeployConfig = @{ ... }` assignment. Values may only be literal
   strings, numbers, booleans, null, arrays, or nested hashtables; variables,
   expandable strings, casts, operators, subexpressions, commands, methods,
   redirections, and multiple statements are rejected before evaluation.
8. Clone the site's private code repository on the remote host.
9. Create a protected runner directory outside the Git checkout, for example
   `/usr/local/libexec/wordpress-ssh-deploy/example-site/`.
10. Install `server-deploy.sh` and a filled `server.config.sh` in that directory.
   Set `RemoteRunnerPath` to the installed `server-deploy.sh`.
11. Keep the directory and both files administrator-owned. A typical setup is
    mode `0755` for the directory and runner, and `0640` for
    `server.config.sh` with read access for the deploy user's group.
    If the runner is installed behind a root forced-command SSH key, set
    `SERVER_FILE_OWNER` and `SERVER_FILE_GROUP` in the private server policy.
    The runner then restores that owner/group on every path it replaces; the
    root key must never be configured as an unrestricted shell. Set
    `UseLegacyScp = $true` only for that wrapper profile.
12. Set `WP_ENVIRONMENT_TYPE` in the target WordPress configuration to the same
    environment value.
13. Run a preflight before the first deployment.

```powershell
.\deploy.ps1 -ConfigPath <ProfilesDirectory>\example-site.ps1 -PreflightOnly
```

For a different site profile:

```powershell
.\deploy.ps1 -ConfigPath .\deploy.config.portfolio.ps1 -Mode pull-full -Confirm
```

### Configuration validation

`deploy.ps1` validates the complete profile before creating temporary
files or connecting over SSH. Unknown keys, missing values, unsupported
environment names, mismatched target locks, unsafe `SyncPaths`, invalid ports,
and malformed URLs stop the operation.

`SyncPaths` accepts non-empty repository-relative paths written with `/`.
Absolute paths, dot segments, `.`, `.git`, `.deploy`, `wp-config.php`, trailing
slashes, backslashes, and duplicate entries are rejected.
Forced-command wrapper profiles additionally reject whitespace, quotes, and
other shell-unsafe characters in remote values and sync paths. This fail-closed
restriction keeps the wrapper's token parser unambiguous.

Existing private configurations must add:

```powershell
Environment = 'staging'
ExpectedRemoteDomain = 'staging.example.com'
ExpectedDbTablePrefix = 'wp_'
ExpectedDbTableCount = 12
MinimumLocalFreeSpaceMB = 1024
MinimumRemoteFreeSpaceMB = 1024
```

`ExpectedDbTableCount` is the exact number of tables for a push export.
Pull-enabled profiles must also set `ExpectedPullDbTableCount` to the exact
number of active tables expected from the remote site. A pull with any other
count is rejected; a minimum table floor is never used as a substitute for the
exact profile value.

When upgrading an existing private profile, add the exact site-specific value
`ExpectedPullDbTableCount` before setting `PullEnabled = $true`. The former
`MinimumPullDbTableCount` setting is obsolete and is rejected; remove it rather
than using it as a fallback. Run `onboard-site.ps1` after the edit to verify the
profile before any pull. Private profiles are local-only and are never stored
in this repository.

The private server policy independently verifies the environment, URL,
WordPress path, repository path, temporary path, backup path, database name,
and WordPress table prefix (including its exact case).

On Windows, the database export may lowercase table identifiers. In `db` and
`full` modes the export is checked against `ExpectedDbTableCount`, and if every
table carries the all-lower-case form of `ExpectedDbTablePrefix`, that prefix is
restored to the configured spelling before the final validation. The rewrite is
byte-safe: it changes only the ASCII bytes of backtick-quoted table identifiers
in executable statements, leaves string literals and comments untouched, and
preserves every other byte of the dump exactly. Mixed, foreign, or unexpected
table names and any other table count fail the deployment instead of being
rewritten. Exports use `--hex-blob` so binary columns are emitted as ASCII hex.
It also pins the Git SSH key, PHP/WP-CLI executables, synchronized paths, backup
retention, and lock location. Client-provided expected values cannot replace
this policy. Production accepts only `code`; both local and remote scripts
reject `db` and `full`. The server validates its policy and the actual WordPress
target before updating the deployment repository. The installed runner and
policy live outside the writable Git checkout so a pull cannot replace them.

### Direction: push and pull

The tool has two directions and they are not symmetric.

**Push (`code`, `db`, `full`) sends local → staging.** It replaces remote data,
so the remote runner takes a backup first and can roll the database back.

**Pull (`pull-db`, `pull-files`, `pull-full`) brings staging → local.** The
download phase never replaces anything locally: it stores verified artifacts
side-by-side under `WorkRoot\.pull\<SiteId>\<timestamp>\` and stops:

- the database arrives as a verified `database.sql`. Download does not touch the
  local site; a separate `apply-pull -Confirm` first backs up and then replaces
  the one working local database (`LocalDbName`) used by `LocalWpPath`;
- files arrive extracted under `files/`, additively. No working file is
  replaced, moved, or deleted during download;
- `apply-pull -PullWorkspace <workspace> -Confirm` is the separate activation
  step. It revalidates the staged workspace (including reparse-point checks),
  backs up the local database and every configured pull path, imports the
  database byte-for-byte through `mysql`, maps the remote URL to `LocalUrl`,
  then atomically replaces the configured files. A failed apply attempts local
  database and file restore, including when the import fails part-way through.
  This is intentionally one local copy per site: it is both the test workspace
  and the rollback target; there is no secondary local database to maintain.

Every download run ends with `Pull artifacts prepared side-by-side; working
local site was not replaced.` Activation is explicit and separate.

Every download run also writes `manifest.json` with the selected profile, path
classes, database expectations, and SHA-256 hashes for downloaded archives,
extracted SQL, and the extracted files tree. Applying a workspace refuses a
missing, foreign, or hash-mismatched manifest.

Pull is off unless `PullEnabled = $true`, and it is **never** allowed when
`Environment` is `production` — refused by configuration validation, by the
local mode gate, and by the remote runner independently.

`-DryRun` prints the full plan (paths, targets, artifacts) and exits without
downloading, writing, or changing anything. Run it first.

`pull-db` and `pull-full` additionally require `-Confirm`; `pull-files` is
additive and does not. `-Mirror` — a files pull that would delete local files
the remote no longer has — is part of the contract but **is not implemented**
and refuses to run even with `AllowDestructiveLocalReplace = $true`.

On the way in, a pulled database must match `ExpectedPullDbTableCount` and
`ExpectedDbTablePrefix` exactly; a file archive is rejected whole if any entry
escapes the allowed paths, is a symlink, or matches the permanent deny list
(`wp-config*`, `.git`, `.ssh`, `.env`, key material, caches, backups).
`ExcludedPullPaths` extends that deny list and can never shorten it. Pull and
push backups are retained according to `KeepBackups`; local apply backups use
`KeepLocalBackups`, `KeepBackupDays`, and `MaxBackupSizeMB`.

The core/content/media contract is explicit: `CorePolicy = 'preserve-local-core'`
means pull never downloads or replaces WordPress core; `PullContentPaths`
controls code content, and `PullMediaPaths` controls uploads. The local
installation must already be a working WordPress copy with a configured
database before apply. The permanent deny list always wins. See
`docs/RISKS-RU.md` for residual risks and the required live rollout gate.

### Internal structure

- `deploy.ps1` is the command entry point and orchestration layer.
- `src/WordPressSshDeploy.psm1` contains reusable configuration validation,
  shell quoting, remote-command construction, and checked process execution.
- `deploy.config.ps1` contains private, site-specific values and is never
  committed.
- `site-git.ps1` operates only on `CodeRepositoryPath`; it never commits the
  deploy-tool repository.
- `menu.ps1` provides guarded status, verify, Git, pull, apply, and preflight
  actions. It intentionally does not expose `db` or `full` as one-click menu
  actions.
- `onboard-site.ps1` performs a read-only local onboarding preflight. It checks
  profile isolation and reports which operational paths are missing or still
  outside `D:`; it never connects to a server or changes a database.

## Usage

```powershell
# Default and safest operation: code only
.\deploy.ps1 -ConfigPath <ProfilesDirectory>\example-site.ps1
.\deploy.ps1 -ConfigPath <ProfilesDirectory>\example-site.ps1 -Mode code

# Database and uploads on development/staging only
.\deploy.ps1 -ConfigPath <ProfilesDirectory>\example-site.ps1 -Mode db -SkipGit

# Code and database on development/staging only, without uploads
.\deploy.ps1 -ConfigPath <ProfilesDirectory>\example-site.ps1 -Mode full -SkipUploads

# Pull staging -> local. Always start with a dry run: it changes nothing.
.\deploy.ps1 -ConfigPath <ProfilesDirectory>\example-site.ps1 -Mode pull-db -DryRun
.\deploy.ps1 -ConfigPath <ProfilesDirectory>\example-site.ps1 -Mode pull-files -DryRun

# Additive files pull; working files are never replaced or deleted
.\deploy.ps1 -ConfigPath <ProfilesDirectory>\example-site.ps1 -Mode pull-files

# Database and full pull require an explicit confirmation
.\deploy.ps1 -ConfigPath <ProfilesDirectory>\example-site.ps1 -Mode pull-db -Confirm
.\deploy.ps1 -ConfigPath <ProfilesDirectory>\example-site.ps1 -Mode pull-full -Confirm

# Activate a verified pull workspace locally after reviewing its contents.
.\deploy.ps1 -ConfigPath D:\wordpress-ssh-deploy\profiles\example-site.ps1 -Mode apply-pull -PullWorkspace <WorkRoot>\.pull\<SiteId>\<timestamp> -DryRun
.\deploy.ps1 -ConfigPath D:\wordpress-ssh-deploy\profiles\example-site.ps1 -Mode apply-pull -PullWorkspace <WorkRoot>\.pull\<SiteId>\<timestamp> -Confirm

# Use the site repository, not the deploy-tool repository, for Git operations.
.\site-git.ps1 -Action status -ConfigPath .\deploy.config.portfolio.ps1
.\site-git.ps1 -Action commit -ConfigPath .\deploy.config.portfolio.ps1 -Message 'Homepage update' -ConfirmCommit
.\site-git.ps1 -Action push -ConfigPath .\deploy.config.portfolio.ps1 -ConfirmPush
.\backup-cleanup.ps1 -ConfigPath .\deploy.config.portfolio.ps1
.\onboard-site.ps1 -ConfigPath <ProfilesDirectory>\example-site.ps1
.\menu.ps1
```

Pull switches (`-DryRun`, `-Confirm`, `-Mirror`) are rejected for push modes,
and push switches (`-SkipGit`, `-SkipUploads`, `-PreflightOnly`) are rejected
for pull modes. Protected push files are never taken from Git: `full` requires
both `-ReplaceProtected` and `-ConfirmProtected`, transfers a separately
staged archive, and the remote runner creates a backup before replacement.

Code deployment never creates commits or pushes. Commit and push separately
before running deploy. For `code` and `full`, the local checkout must be clean
and `HEAD` must match its configured upstream. The remote checkout follows the
`main` branch. The legacy positional commit message is rejected with a migration
message; `-SkipGit` is retained only for `db`.

## What each mode changes

| Mode | Code | Database | Uploads | Remote DB backup |
| --- | --- | --- | --- | --- |
| `code` | yes | no | no | no |
| `db` | no | yes | optional | yes |
| `full` | yes | yes | optional | yes |

Before creating or accepting artifacts, both sides check their configured free
space reserve. SQL dumps and ZIP archives are validated before use. Code and
uploads are staged in temporary directories and swapped only after preparation.
If a database import fails, the server immediately attempts to restore the
backup created in the same operation and preserves that backup for manual
recovery if rollback also fails.

### Staging test marker

Before every approved staging deploy test that changes the database, update the
local fixture homepage with a unique current-stage marker, for example
`STAGING-DB-AFTERMATH-SAFETY-20260811-01`. After deployment, verify that exact
marker in the public staging homepage. Never use this procedure on production.

## Tests

The autonomous safety suite does not connect to a real site. It validates the
configuration schema, production restrictions, shell quoting, remote command
construction, exit-code handling, cleanup guards, server policy, lock cleanup,
artifact integrity, free-space checks, database rollback, atomic replacement,
POSIX syntax, and LF line endings.

Requirements: Windows PowerShell 5.1 or PowerShell 7, Pester 3.4 or newer, and a
POSIX `sh` supplied by Git for Windows.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
```

## Security notes

- Use SSH keys with the minimum required access.
- Do not commit `deploy.config.ps1`, `server.config.sh`, SQL dumps, uploads,
  `wp-config.php`, or keys.
- Use a dedicated staging environment before adapting this workflow to production.
- Database passwords are passed to MySQL tools through the process environment,
  not command-line arguments. Use dedicated least-privilege database users.
- The remote script uses an atomic lock directory and rejects concurrent runs.
- Temporary files are removed on normal failures. If SSH is interrupted before
  cleanup can be confirmed, the next successful invocation removes matching
  temporary files older than one day.
- Review both scripts before use. Deployment automation is environment-specific.

## License

[MIT](LICENSE)
