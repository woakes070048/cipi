# Changelog

All notable changes to Cipi are documented in this file.

---

## [4.0.3] — 2026-03-05

### Fixed

- `cipi app logs` now includes Laravel daily logs (`laravel-YYYY-MM-DD.log`) from `shared/storage/logs/`
- Added `--type=laravel` option to tail only Laravel application logs

---

## [4.0.2] — 2026-03-04

### Added

- `cipi deploy <app> --trust-host=<host[:port]>` — trust a custom Git server by scanning and persisting its SSH host key
- Custom Git server support in the deploy workflow (non-GitHub/GitLab repositories)
- `cipi backup prune [app] --weeks=N` — delete S3 backups older than N weeks, per-app or globally

### Fixed

- Installer (`setup.sh`) fix for edge cases during provisioning

### Changed

- Documentation updated to reflect new deploy and backup commands

---

## [4.0.1] — 2026-03-03

### Changed

- Self-update mechanism revised: version check and install script updated
- Installer link updated to new canonical URL (`cipi.sh/setup.sh`)
- README refreshed (condensed, up-to-date command reference)

---

## [4.0.0] — 2026-03-03

Complete rewrite of the Cipi CLI from the ground up.

### Added

- New modular shell architecture: each domain split into its own library (`lib/app.sh`, `lib/deploy.sh`, `lib/db.sh`, `lib/backup.sh`, `lib/ssl.sh`, `lib/php.sh`, `lib/firewall.sh`, `lib/service.sh`, `lib/worker.sh`, `lib/self-update.sh`, `lib/common.sh`)
- `lib/common.sh` — shared helpers: `parse_args`, `validate_*`, `generate_password`, `read_input`, `confirm`, `log_action`, and app registry helpers (`app_exists`, `app_get`, `app_set`, `app_save`, `app_remove`)
- `cipi service list|restart|start|stop` — full service management for nginx, mariadb, supervisor, fail2ban, php-fpm
- `cipi deploy <app> --unlock` — unlock a stuck Deployer process
- `cipi deploy <app> --webhook` — display webhook URL and token
- `cipi deploy <app> --key` — display the SSH deploy public key
- `cipi deploy <app> --releases` — list available releases
- `cipi deploy <app> --rollback` — roll back to the previous release
- `cipi backup configure` — interactive S3 configuration wizard
- `cipi backup run [app]` — run backup for a specific app or all apps
- `cipi backup list [app]` — list S3 backups per-app or globally (supports multiple S3 providers)
- `cipi self-update [--check]` — update Cipi in place; `--check` shows available version without installing
- `cipi app artisan <app> <cmd>` — run arbitrary Artisan commands
- `cipi app tinker <app>` — open Laravel Tinker for an app
- `cipi app logs <app> [--type=nginx|php|worker|deploy|laravel|all]` — tail app logs by type
- PHP 8.4 and 8.5 support
- `lib/cipi-worker` — standalone helper script for queue worker management via sudoers
- Nginx security headers (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`) in generated vhosts
- App registry stored as JSON (`/etc/cipi/apps.json`) with full CRUD via `app_save`/`app_remove`
- Structured action logging to `/var/log/cipi`

### Changed

- `cipi app create` now provisions: Linux user, directories, SSH deploy key, MariaDB database, `.env`, PHP-FPM pool, Nginx vhost, Supervisor worker, crontab (scheduler + deploy trigger), Deployer config, sudoers entry
- Deployer recipe uses `recipe/laravel.php` with automatic `artisan:migrate`, `artisan:optimize`, `artisan:storage:link`, `artisan:queue:restart`, and `workers:restart` hooks
- `cipi app edit` supports `--php`, `--branch`, `--repository` flags and updates all affected config files atomically
- `cipi app delete` performs full cleanup: workers, nginx, php-fpm, database, crontab, sudoers, SSL certificate, home directory
- `cipi alias add/remove` regenerates the Nginx vhost and reloads nginx
- `cipi db` commands (`create`, `list`, `delete`, `backup`, `restore`) rewritten with MariaDB-native tooling
- `cipi ssl install` uses Certbot with all aliases included in the certificate SAN
- `cipi php install` manages PHP-FPM installs per version
- `cipi firewall allow/list` wraps `ufw`
- Removed legacy `lib/commands.sh`, `lib/domain.sh`, `lib/nginx.sh`, `lib/database.sh`
- Removed Redis dependency from the default stack

### Fixed

- SSL Certbot integration with multi-domain vhosts
- Worker restart via supervisor with app-scoped naming
- PHP-FPM pool `open_basedir` set correctly per app
- Deploy key `authorized_keys` and `known_hosts` permissions hardened
