# frozen_string_literal: true

# Fast safety and policy tests for Vagrantfile, its extracted Bash
# provisioners, and the opt-in guest integration test. These tests do not start a
# VM or contact external repositories; the guest script exercises live behavior
# separately after an engineer explicitly selects it.

require "minitest/autorun"
require "open3"
require_relative "../lib/ubuntu_26_04_command_policy"

class Ubuntu2604ProvisionersTest < Minitest::Test
  # Derive paths from this test file so the suite works regardless of the
  # caller's current directory.
  VAGRANT_DIRECTORY = File.expand_path("..", __dir__)
  VAGRANTFILE = File.join(VAGRANT_DIRECTORY, "Vagrantfile")
  PROVISION_DIRECTORY = File.join(VAGRANT_DIRECTORY, "provision", "ubuntu-26.04")
  GUEST_INTEGRATION_SCRIPT = File.join(VAGRANT_DIRECTORY, "test", "guest_integration.sh")
  EXPECTED_SCRIPTS = %w[
    development-kernel-limits.sh docker.sh enlarge-hdd.sh general-dev-user.sh
    github-cli.sh mongodb.sh network-security.sh nginx.sh nodejs.sh
    network-link-recovery.sh os-package-security-baseline.sh postgresql.sh
    python-user.sh python-uv.sh python.sh rust-for-substrate.sh ubuntu-desktop.sh
  ].freeze

  # Vagrantfiles are Ruby DSL files, so Ruby's parser can validate them without
  # loading Vagrant, installing a provider, or requiring a MongoDB password.
  def test_vagrantfile_has_valid_ruby_syntax
    _stdout, stderr, status = Open3.capture3("ruby", "-c", VAGRANTFILE)
    assert status.success?, stderr
  end

  # Provisioner bodies belong in independently testable files. These patterns
  # prevent large inline heredocs from being reintroduced into the Vagrantfile.
  def test_vagrantfile_contains_no_inline_shell_provisioners
    source = File.read(VAGRANTFILE)
    refute_match(/\binline\s*(?:=|:)/, source)
    refute_match(/<<-SHELL/, source)
  end

  # Keep three views synchronized: files on disk, the validation inventory, and
  # paths actually attached to Vagrant provisioners.
  def test_script_inventory_matches_the_vagrantfile
    actual_scripts = Dir.glob(File.join(PROVISION_DIRECTORY, "*.sh"))
                        .map { |path| File.basename(path) }
                        .sort
    assert_equal EXPECTED_SCRIPTS.sort, actual_scripts

    source = File.read(VAGRANTFILE)
    configured_match = source.match(/PROVISION_SCRIPTS = %w\[(.*?)\]\.freeze/m)
    refute_nil configured_match
    configured_scripts = configured_match[1].split.sort
    assert_equal EXPECTED_SCRIPTS.sort, configured_scripts

    referenced_scripts = source.scan(/provision_script\.call\("([^"]+\.sh)"\)/)
                               .flatten
                               .uniq
                               .sort
    assert_equal EXPECTED_SCRIPTS.sort, referenced_scripts
  end

  # Vagrant executes these files directly. Require a portable Bash shebang,
  # executable mode, and strict error handling near the top of every script.
  def test_scripts_are_executable_fail_fast_bash
    provision_scripts.each do |script|
      source = File.read(script)
      assert File.executable?(script), "#{script} is not executable"
      assert_equal "#!/usr/bin/env bash\n", source.lines.first
      assert_includes source.lines.first(5), "set -Eeuo pipefail\n"
    end
  end

  # bash -n parses without running privileged or network-changing commands.
  def test_scripts_have_valid_bash_syntax
    provision_scripts.each do |script|
      _stdout, stderr, status = Open3.capture3("bash", "-n", script)
      assert status.success?, "#{script}: #{stderr}"
    end
  end

  # Consistent LF endings and no trailing spaces avoid guest parsing surprises
  # and keep shell diffs reviewable.
  def test_scripts_have_no_trailing_whitespace_or_crlf
    (provision_scripts + [GUEST_INTEGRATION_SCRIPT]).each do |script|
      source = File.binread(script)
      refute_includes source, "\r", "#{script} contains CRLF"
      source.lines.each_with_index do |line, index|
        refute_match(/[ \t]+\n\z/, line, "#{script}:#{index + 1} has trailing whitespace")
      end
    end
  end

  # This is behavioral rather than source matching: exercise both option forms,
  # generic provisioner-type selection, lifecycle commands, and disabled MongoDB.
  def test_mongodb_secret_command_policy
    cases = {
      ["validate"] => false,
      ["status"] => false,
      ["up"] => true,
      ["up", "--no-provision"] => false,
      ["up", "--provision-with", "nginx"] => false,
      ["up", "--provision-with=mongodb"] => true,
      ["provision"] => true,
      ["provision", "--provision-with", "nginx,postgresql"] => false,
      ["provision", "--provision-with=integration-test"] => false,
      ["provision", "--provision-with=shell"] => true,
      ["reload"] => false,
      ["reload", "--provision"] => true,
      ["reload", "--provision-with", "mongodb"] => true,
      ["resume", "--provision-with=network-security"] => false
    }

    cases.each do |arguments, expected|
      actual = Ubuntu2604CommandPolicy.mongodb_secret_required?(
        arguments,
        mongodb_enabled: true
      )
      assert_equal expected, actual, "unexpected policy for #{arguments.inspect}"
    end
    refute Ubuntu2604CommandPolicy.mongodb_secret_required?(
      ["provision"],
      mongodb_enabled: false
    )
  end

  # A protected, ignored local file makes the standard `vagrant up` command
  # self-contained. The environment remains an explicit automation override,
  # and the credential value must never be committed into the template.
  def test_mongodb_host_secret_policy
    source = File.read(VAGRANTFILE)
    gitignore = File.read(File.join(VAGRANT_DIRECTORY, ".gitignore"))

    assert_includes gitignore, "/.secrets/"
    assert_includes source,
                    'MONGODB_PASSWORD_DIRECTORY = File.expand_path(".secrets", __dir__)'
    assert_includes source,
                    'MONGODB_PASSWORD_FILE = File.join(MONGODB_PASSWORD_DIRECTORY, "mongodb-password")'
    assert_includes source,
                    "MONGODB_PASSWORD_FROM_ENVIRONMENT = ENV.key?(MONGODB_PASSWORD_ENVIRONMENT_VARIABLE)"
    assert_includes source, "!File.symlink?(MONGODB_PASSWORD_FILE)"
    assert_includes source, "File.stat(MONGODB_PASSWORD_DIRECTORY).mode & 0o077"
    assert_includes source, "File.stat(MONGODB_PASSWORD_FILE).mode & 0o077"
    assert_includes source, "config.vagrant.sensitive = [MONGODB_PASSWORD]"
    refute_match(/MONGODB_PASSWORD\s*=\s*["'][^"']+["']/, source)
  end

  # Guard the critical network/firewall behavior as a coherent policy: explicit
  # dual-stack metrics, no private IPv6, per-run rollback, and Docker filtering
  # that does not depend on UFW's packet path.
  def test_network_and_docker_security_invariants
    network = provision_source("network-security.sh")
    assert_operator network.scan("dhcp6: true").length, :>=, 2
    assert_operator network.scan("accept-ra: true").length, :>=, 2
    refute_includes network, "ra-overrides:"
    assert_operator network.scan("[IPv6AcceptRA]").length, :>=, 2
    assert_includes network, "50-vagrant-ra-route-metric.conf"
    assert_includes network, "snapshot_foreign_policy_rules"
    assert_includes network, "restore_foreign_policy_rules"
    assert_includes network, "ipv4-policy-rules"
    assert_includes network, "ipv6-policy-rules"
    assert_includes network, 'read -r -a rule_spec <<< "${rule#*:}"'
    assert_includes network, 'ip "$family" rule add priority "$priority" "${rule_spec[@]}"'
    refute_includes network, "eval "
    assert_includes network, "NETWORKD_SNAPSHOT"
    assert_includes network, "renderer: networkd"
    assert_includes network, "unmanaged-devices=mac:"
    assert_includes network, "NETWORKMANAGER_SNAPSHOT"
    assert_includes network, "dhcp6: false"
    assert_includes network, "accept-ra: false"
    assert_includes network, "link-local: []"
    assert_includes network, "/var/lib/vagrant/network-transactions"
    assert_includes network, "UFW_SNAPSHOT"
    assert_includes network, "trap rollback_on_exit EXIT"
    assert_includes network, "state established '( sport = :22 )'"
    assert_includes network, 'marker="pid=$CURRENT_PID,"'
    assert_includes network, "TRUSTED_VPN_TUNNEL_INTERFACES"
    assert_includes network, "Vagrant managed: trusted VPN tunnel"
    assert_includes network, 'ufw allow in on "$VPN_INTERFACE"'
    refute_includes network, "delete allow 'Nginx Full'"

    link_recovery = provision_source("network-link-recovery.sh")
    assert_includes link_recovery, "PathChanged=/run/systemd/network"
    assert_includes link_recovery, "vagrant-networkd-runtime-repair.path"
    assert_includes link_recovery, "chmod 0640"
    assert_includes link_recovery, 'chown root:systemd-network'
    assert_includes link_recovery, 'networkctl reconfigure "${PHYSICAL_INTERFACES[@]}"'
    assert_includes link_recovery, "restore_foreign_policy_rules"
    assert_includes link_recovery, "/run/vagrant-network-rollback-state"
    refute_includes link_recovery, "/usr/lib/parallels-tools"

    vagrantfile = File.read(VAGRANTFILE)
    recovery_block = vagrantfile.match(
      /config\.vm\.provision "network-link-recovery",.*?path: provision_script\.call\("network-link-recovery\.sh"\)/m
    )
    refute_nil recovery_block
    assert_includes recovery_block[0], 'run: "always"'

    docker = provision_source("docker.sh")
    assert_includes docker, "DOCKER-USER"
    assert_includes docker, "VAGRANT-DOCKER-INGRESS"
    assert_includes docker, '"default-ulimits"'
    assert_includes docker, '"Soft": $DOCKER_DEFAULT_NOFILE_LIMIT'
    assert_includes docker, '"Hard": $DOCKER_DEFAULT_NOFILE_LIMIT'
    assert_includes docker, '--in-interface "$SHARED_INTERFACE" --jump DROP'
    assert_includes docker, '--in-interface "$BRIDGED_INTERFACE" --jump DROP'
    assert_includes docker, "vagrant-docker-ingress.service"
    assert_includes docker, "for (field_index = 1; field_index <= NF; field_index++)"
    refute_includes docker, "for (index = 1; index <= NF; index++)"
  end

  # Assert ordering and state mechanisms that make repeat provisioning safe.
  def test_reconciliation_and_service_lifecycle_invariants
    apt = provision_source("os-package-security-baseline.sh")
    assert_includes apt, "export NEEDRESTART_MODE=l"
    refute_includes apt, "export NEEDRESTART_MODE=a"
    assert_operator apt.index("trap restore_automatic_updates EXIT"), :<,
                    apt.index("systemctl stop apt-daily.timer")
    assert_match(/systemctl unmask apt-daily\.service apt-daily-upgrade\.service.*?systemctl daemon-reload.*?systemctl enable --now apt-daily\.timer/m,
                 apt)
    assert_match(/for update_unit in.*?systemctl reset-failed "\$update_unit".*?\|\| true/m,
                 apt)
    assert_includes apt,
                    "systemctl is-enabled --quiet apt-daily.timer apt-daily-upgrade.timer"
    assert_includes apt,
                    "systemctl is-active --quiet apt-daily.timer apt-daily-upgrade.timer"
    assert_includes apt, 'Unattended-Upgrade::OnlyOnACPower "false";'

    kernel_limits = provision_source("development-kernel-limits.sh")
    assert_includes kernel_limits,
                    "/etc/sysctl.d/90-vagrant-development-inotify.conf"
    assert_includes kernel_limits, "fs.inotify.max_user_watches="
    assert_includes kernel_limits, "fs.inotify.max_user_instances="
    assert_includes kernel_limits, 'sysctl --load "$SYSCTL_CONFIG"'
    assert_includes kernel_limits,
                    'sysctl --values fs.inotify.max_user_watches'
    assert_includes kernel_limits,
                    'sysctl --values fs.inotify.max_user_instances'

    disk = provision_source("enlarge-hdd.sh")
    assert_includes disk, "root-vg-growth"
    assert_includes disk, "RESERVED_FREE_EXTENTS"
    assert_includes disk, 'NEW_EXTENTS=$((FREE_EXTENTS - RESERVED_FREE_EXTENTS))'
    assert_includes disk, '"${FILESYSTEM_GROW_COMMAND[@]}"'
    refute_match(/\b(?:lvs|pvs|vgs)\b[^\n]*--output\b/, disk)
    assert_includes disk, "lvs --noheadings --options vg_name"
    assert_includes disk, "pvs --noheadings --options pv_name"
    assert_includes disk, "vgs --noheadings --options vg_free_count"
    assert_includes disk, "lsblk --nodeps --noheadings --output PARTN"
    assert_includes disk, "lsblk --nodeps --noheadings --output PKNAME"
    assert_operator disk.index('mv "$STATE_TEMP" "$STATE_FILE"'), :<,
                    disk.index('growpart "$PARENT_DEVICE" "$PARTITION_NUMBER"')
    assert_operator disk.index('growpart "$PARENT_DEVICE" "$PARTITION_NUMBER"'), :<,
                    disk.index('pvresize "$PV_DEVICE"')
    vagrantfile = File.read(VAGRANTFILE)
    disk_block = vagrantfile.match(/config\.vm\.provision "enlarge-hdd",.*?path: provision_script\.call\("enlarge-hdd\.sh"\)/m)
    refute_nil disk_block
    assert_includes disk_block[0], 'run: "always"'

    docker = provision_source("docker.sh")
    assert_includes docker, "DOCKER_PACKAGES_CHANGED"
    assert_includes docker, "DOCKER_CONFIG_CHANGED"
    assert_match(/if systemctl is-active --quiet docker;.*?systemctl restart docker/m,
                 docker)

    rust = provision_source("rust-for-substrate.sh")
    assert_includes rust, 'RUSTUP_TEMP_DIRECTORY="$(mktemp --directory)"'
    assert_includes rust, 'RUSTUP_INIT="$RUSTUP_TEMP_DIRECTORY/rustup-init"'

    uv = provision_source("python-uv.sh")
    assert_includes uv, '[[ "$reported_version" != "$command $UV_VERSION "* ]]'
    assert_includes uv, "verify_uv_version uv"
    assert_includes uv, "verify_uv_version uvx"

    github_cli = provision_source("github-cli.sh")
    assert_includes github_cli, "GITHUB_CLI_ARCHIVE_SHA256"
    assert_includes github_cli, "sha256sum --check --strict"
    assert_includes github_cli, "--proto-redir '=https'"
    assert_includes github_cli, 'dpkg --print-architecture'
    assert_includes github_cli, 'install -o root -g root -m 0755'
    assert_includes github_cli, "/usr/local/bin/gh --version"
    assert_includes github_cli, "/usr/local/bin/gh help"

    integration = File.read(GUEST_INTEGRATION_SCRIPT)
    assert_includes integration,
                    "for (field_index = 1; field_index <= NF; field_index++)"
    refute_includes integration, "for (index = 1; index <= NF; index++)"
  end

  # Version transitions and transactional services must fail before discarding
  # the last known-good state, then verify the resulting live state.
  def test_database_and_web_transaction_invariants
    postgresql = provision_source("postgresql.sh")
    assert_includes postgresql, "PostgreSQL major $TRANSITION blocked"
    assert_includes postgresql, "POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE"
    assert_includes postgresql, "--allow-downgrades"
    assert_includes postgresql, "pg_isready --quiet"

    nginx = provision_source("nginx.sh")
    assert_includes nginx, "/var/lib/vagrant/nginx-transactions"
    assert_includes nginx, "rollback_transaction"
    assert_includes nginx, "CERTBOT_ARCHIVE"
    assert_includes nginx, 'NGINX_INDEX_FILE="/var/www/html/index.html"'
    assert_includes nginx, '"$NGINX_INDEX_FILE"'
    assert_includes nginx, 'install -o root -g root -m 0644'
    assert_includes nginx, "--renew-with-new-domains"
    assert_includes nginx, '"https://$NGINX_PROBE_SERVER_NAME/"'

    mongodb = provision_source("mongodb.sh")
    vagrantfile = File.read(VAGRANTFILE)
    assert_match(/MONGODB_IMAGE = "mongo:7\.0\.39@sha256:[0-9a-f]{64}"/, vagrantfile)
    assert_includes mongodb, 'PREFLIGHT_MANAGED_LABEL'
    assert_includes mongodb, 'MONGODB_ROLLBACK_CONTAINER'
    assert_includes mongodb, 'restore-replica-member.js'
    assert_includes mongodb, 'rs.reconfig(config, { force: true })'
    assert_includes mongodb, 'MONGODB_SECRET_SNAPSHOT'
    assert_includes mongodb, 'chown "root:$MONGODB_GID" "$MONGODB_SECRET_TEMP"'
    assert_includes mongodb, 'chmod 0440 "$MONGODB_SECRET_TEMP"'
    assert_includes mongodb,
                    '--ulimit "nofile=$MONGODB_NOFILE_LIMIT:$MONGODB_NOFILE_LIMIT"'
    assert_includes mongodb, 'CONFIGURED_NOFILE_LIMIT'
    assert_includes mongodb, 'RUNTIME_NOFILE_LIMIT'
    assert_operator mongodb.scan("> /dev/null 2>&1; then").length, :>=, 2
    refute_match(/\bcat\(/, mongodb)
    assert_equal 7, mongodb.scan("fs.readFileSync").length
    assert_match(/docker container rm "\$MONGODB_ROLLBACK_CONTAINER".*?trap - EXIT/m,
                 mongodb)
  end

  def test_targeted_reboot_hook_wraps_the_provision_action
    source = File.read(VAGRANTFILE)
    assert_includes source, '"Vagrant::Action::Builtin::Provision"'
    assert_includes source,
                    "hook.before(Vagrant::Action::Builtin::Provision, Middleware)"
    assert_includes source, "return if env[:provision_enabled] == false"
    assert_includes source,
                    "machine.action(:reload, provision_enabled: false)"
    refute_includes source, "machine.guest.capability(:reboot)"
    refute_match(/config\.vm\.provision "conditional-reboot"/, source)
  end

  # The live suite is intentionally opt-in and read-only. Parse it locally and
  # guard against accidentally adding obvious mutation commands.
  def test_guest_integration_script_is_executable_read_only_bash
    assert File.executable?(GUEST_INTEGRATION_SCRIPT)
    _stdout, stderr, status = Open3.capture3("bash", "-n", GUEST_INTEGRATION_SCRIPT)
    assert status.success?, stderr

    source = File.read(GUEST_INTEGRATION_SCRIPT)
    assert_includes source, "iptables --wait --check"
    assert_includes source, "pg_isready --quiet"
    assert_includes source, "/run/secrets/mongodb/verify.js"
    assert_includes source, 'pass "pinned GitHub CLI"'
    assert_includes source, 'daemon_config["default-ulimits"]["nofile"]'
    assert_includes source, 'MONGODB_NOFILE_LIMIT:$MONGODB_NOFILE_LIMIT'
    assert_includes source, '"https://$NGINX_PROBE_SERVER_NAME/"'
    refute_match(/\b(?:apt-get|docker run|ufw allow|ufw delete)\b/, source)
    refute_match(/systemctl (?:start|stop|restart|reload|enable|disable)\b/, source)

    vagrantfile = File.read(VAGRANTFILE)
    integration_block = vagrantfile.match(
      /config\.vm\.provision "integration-test",.*?path: GUEST_INTEGRATION_SCRIPT/m
    )
    refute_nil integration_block
    assert_includes integration_block[0], 'run: "never"'
  end

  private

  # Return absolute paths in the explicit expected order for shared assertions.
  def provision_scripts
    EXPECTED_SCRIPTS.map { |script| File.join(PROVISION_DIRECTORY, script) }
  end

  def provision_source(script)
    File.read(File.join(PROVISION_DIRECTORY, script))
  end
end
