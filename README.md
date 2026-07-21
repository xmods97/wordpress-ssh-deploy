# wordpress-ssh-deploy

A small, auditable deployment workflow for moving a local WordPress site to a
remote Linux host over SSH. The Windows-side PowerShell script exports and
uploads data; the remote POSIX shell script backs up the destination and applies
the deployment.

> [!WARNING]
> `db` and `full` replace the remote database. `full` can also replace the
> configured uploads directory. Test on staging and keep independent backups.

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
3. Fill every path, host, database safety lock, and `SyncPaths` entry.
4. Keep `deploy.config.ps1` private. It is excluded by `.gitignore`.
5. Clone the same repository on the remote host.
6. Run a preflight before the first deployment.

```powershell
.\deploy.ps1 -PreflightOnly
```

## Usage

```powershell
# Commit/push code, sync configured paths, replace DB and uploads
.\deploy.ps1 "Describe the release"

# Code only
.\deploy.ps1 "Update checkout" -Mode code

# Database and uploads only; do not create a Git commit
.\deploy.ps1 -Mode db -SkipGit

# Full deploy without uploads
.\deploy.ps1 "Update content" -SkipUploads
```

When tracked files have changed, the script requires a commit message unless
`-SkipGit` is used. The remote checkout follows the `main` branch.

## What each mode changes

| Mode | Code | Database | Uploads | Remote DB backup |
| --- | --- | --- | --- | --- |
| `code` | yes | no | no | no |
| `db` | no | yes | optional | yes |
| `full` | yes | yes | optional | yes |

## Security notes

- Use SSH keys with the minimum required access.
- Do not commit `deploy.config.ps1`, SQL dumps, uploads, `wp-config.php`, or keys.
- Use a dedicated staging environment before adapting this workflow to production.
- The database password is passed to local MySQL tools as a command-line option;
  on shared machines, prefer a protected MySQL option file and adapt the script.
- Review both scripts before use. Deployment automation is environment-specific.

## License

[MIT](LICENSE)
