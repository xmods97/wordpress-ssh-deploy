# wordpress-ssh-deploy

A small, auditable deployment workflow for moving a local WordPress site to a
remote Linux host over SSH. The Windows-side PowerShell script exports and
uploads data; the remote POSIX shell script backs up the destination and applies
the deployment.

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

1. Copy these files into the root of the WordPress code repository.
2. Copy `deploy.config.example.ps1` to `deploy.config.ps1`.
3. Select the target `Environment`: `development`, `staging`, or `production`.
4. Fill every path, host, database safety lock, and `SyncPaths` entry.
5. Set `ExpectedRemoteDomain`, `ExpectedRemoteWpPath`,
   `ExpectedRemoteDbName`, and `ExpectedDbTablePrefix` to the exact expected
   target values.
6. Keep `deploy.config.ps1` private. It is excluded by `.gitignore`.
7. Clone the same repository on the remote host.
8. Create a protected runner directory outside the Git checkout, for example
   `/usr/local/libexec/wordpress-ssh-deploy/example-site/`.
9. Install `server-deploy.sh` and a filled `server.config.sh` in that directory.
   Set `RemoteRunnerPath` to the installed `server-deploy.sh`.
10. Keep the directory and both files administrator-owned. A typical setup is
    mode `0755` for the directory and runner, and `0640` for
    `server.config.sh` with read access for the deploy user's group.
11. Set `WP_ENVIRONMENT_TYPE` in the target WordPress configuration to the same
    environment value.
12. Run a preflight before the first deployment.

```powershell
.\deploy.ps1 -PreflightOnly
```

### Configuration validation

`deploy.ps1` validates the complete configuration before creating temporary
files or connecting over SSH. Unknown keys, missing values, unsupported
environment names, mismatched target locks, unsafe `SyncPaths`, invalid ports,
and malformed URLs stop the operation.

`SyncPaths` accepts non-empty repository-relative paths written with `/`.
Absolute paths, dot segments, `.`, `.git`, `.deploy`, `wp-config.php`, trailing
slashes, backslashes, and duplicate entries are rejected.

Existing private configurations must add:

```powershell
Environment = 'staging'
ExpectedRemoteDomain = 'staging.example.com'
ExpectedDbTablePrefix = 'wp_'
MinimumLocalFreeSpaceMB = 1024
MinimumRemoteFreeSpaceMB = 1024
```

The private server policy independently verifies the environment, URL,
WordPress path, repository path, temporary path, backup path, database name,
and WordPress table prefix (including its exact case).
On Windows, the database export may lowercase table identifiers. For the staging
fixture, `db` mode accepts exactly twelve expected lower-case identifiers and
normalizes only the quoted `kqsmtmooh_` prefix to the configured `kqSmtmoOH_`
prefix before the final validation. Unexpected table names or counts fail the
deployment.
It also pins the Git SSH key, PHP/WP-CLI executables, synchronized paths, backup
retention, and lock location. Client-provided expected values cannot replace
this policy. Production accepts only `code`; both local and remote scripts
reject `db` and `full`. The server validates its policy and the actual WordPress
target before updating the deployment repository. The installed runner and
policy live outside the writable Git checkout so a pull cannot replace them.

### Internal structure

- `deploy.ps1` is the command entry point and orchestration layer.
- `src/WordPressSshDeploy.psm1` contains reusable configuration validation,
  shell quoting, remote-command construction, and checked process execution.
- `deploy.config.ps1` contains private, site-specific values and is never
  committed.

## Usage

```powershell
# Default and safest operation: code only
.\deploy.ps1
.\deploy.ps1 -Mode code

# Database and uploads on development/staging only
.\deploy.ps1 -Mode db -SkipGit

# Code and database on development/staging only, without uploads
.\deploy.ps1 -Mode full -SkipUploads
```

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
