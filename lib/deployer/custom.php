<?php
namespace Deployer;

// No recipe/common.php — classic deploy: no releases, no shared, no symlink.
// Deploys directly into deploy_path/htdocs (clone or pull).

set('application', '__CIPI_APP_USER__');
set('repository', '__CIPI_REPOSITORY__');
set('branch', '__CIPI_BRANCH__');
set('deploy_path', '__CIPI_DEPLOY_PATH__');
set('git_ssh_command', 'ssh -i __CIPI_DEPLOY_PATH__/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new');
set('bin/php', '/usr/bin/php__CIPI_PHP_VERSION__');

host('localhost')
    ->set('remote_user', '__CIPI_APP_USER__')
    ->set('deploy_path', '__CIPI_DEPLOY_PATH__')
    ->set('ssh_arguments', ['-o StrictHostKeyChecking=accept-new', '-i __CIPI_DEPLOY_PATH__/.ssh/id_ed25519']);

task('deploy', function () {
    $repo = get('repository');
    if ($repo === '' || $repo === null) {
        writeln('<info>No Git repository configured — upload files via SFTP to {{deploy_path}}/htdocs</info>');
        return;
    }
    $branch = get('branch');
    if (test("[ -d {{deploy_path}}/htdocs/.git ]")) {
        run("cd {{deploy_path}}/htdocs && git fetch origin && git reset --hard origin/{{branch}}");
    } else {
        run("cd {{deploy_path}} && git clone -b {{branch}} {{repository}} htdocs");
    }
})->desc('Classic deploy: clone or pull into htdocs (no releases/shared)');
