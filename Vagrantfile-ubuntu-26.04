# -*- mode: ruby -*-
# vi: set ft=ruby :


# Ubuntu 26.04 development workstation for Parallels on Apple Silicon.
#
# Read README.md before the first launch. It explains host requirements, the
# fixed-size 1000G disk, network exposure, MongoDB password handling, service
# access, lifecycle commands, design decisions, and known limitations.
#
# Quick start from this directory (the password must remain in the same shell):
#
#   export VAGRANT_VAGRANTFILE=Vagrantfile-ubuntu-26.04
#   read -s "MONGODB_PASSWORD?MongoDB password: "
#   export MONGODB_PASSWORD
#   printf '\n'
#   ruby test/provisioners_test.rb
#   vagrant validate
#   vagrant up --provider=parallels
#
# This file is Ruby code evaluated on the host. It validates all configuration,
# defines the Parallels VM, and passes explicit inputs to small guest-side shell
# provisioners under provision/ubuntu-26.04. It supports Parallels only.
#
# References:
#   https://developer.hashicorp.com/vagrant/docs
#   https://parallels.github.io/vagrant-parallels/docs/



require "ipaddr"
require_relative "lib/ubuntu_26_04_command_policy"

Vagrant.require_version ">= 2.4.0"

# Ubuntu package operations can leave /run/reboot-required behind. This local
# middleware wraps Vagrant's complete provisioning action, so it also runs after
# `--provision-with` selections that omit a final named provisioner. It asks
# Vagrant to perform one provider-aware reboot only after successful provisioning
# and does nothing for --no-provision operations.
module VagrantPlugins
  module ConditionalReboot
    class Middleware
      def initialize(app, _env)
        @app = app
      end

      def call(env)
        @app.call(env)
        return if env[:provision_enabled] == false

        machine = env.fetch(:machine)
        if machine.communicate.test("test -f /run/reboot-required")
          machine.ui.info("Guest reboot required; rebooting once after provisioning.")
          machine.guest.capability(:reboot)
        else
          machine.ui.info("Guest reboot is not required.")
        end
      end
    end

    class Plugin < Vagrant.plugin("2")
      name "conditional-reboot"

      action_hook(:conditional_reboot_after_provisioning,
                  "Vagrant::Action::Builtin::Provision") do |hook|
        hook.before(Vagrant::Action::Builtin::Provision, Middleware)
      end
    end
  end
end

Vagrant.configure("2") do |config|

  #
  # Config: edit template inputs in this section only.
  #
  # Feature flags affect future provisioning; setting one to false does not
  # uninstall software or remove data created by an earlier run.
  #

  # Stable identity shared by Vagrant, Parallels, the guest hostname, and the
  # MongoDB single-member replica-set address. Keep both names identical.
  VM_NAME = "dev-07"
  PROVIDER_VM_NAME = VM_NAME

  # Per-user development preferences. The GitHub key path is configured inside
  # the guest, but the key itself is never generated or copied by this template.
  DEFAULT_USER = "vagrant"
  GIT_USER_EMAIL = "victor.mezrin@trevo.finance"
  GIT_USER_NAME = "Victor Mezrin"
  GIT_CORE_EDITOR = "code --wait"
  GITHUB_SSH_IDENTITY_FILE = "~/.ssh/my-ssh-key"

  # Adapter 1 is Parallels Shared/NAT and is created by the provider. Adapter 2
  # is the stable host-only address below. Adapter 3 bridges to host Wi-Fi.
  # Lower route metrics win, so Bridged Wi-Fi is preferred and Shared/NAT is the
  # fallback. The private port list becomes interface-scoped UFW rules.
  PRIVATE_NETWORK_IP = "192.168.56.7"
  PRIVATE_NETWORK_CIDR = "192.168.56.0/24"
  BRIDGED_NETWORK_INTERFACE = ENV.fetch("VAGRANT_BRIDGED_INTERFACE", "en0")
  BRIDGED_NETWORK_ROUTE_METRIC = 100
  SHARED_NETWORK_ROUTE_METRIC = 600
  PRIVATE_NETWORK_TCP_PORTS = [
    "22", "80", "443", "3000", "9944",
    "15100:15105", "15200:15205", "15300:15305", "15400:15405",
    "18890:18894", "27017"
  ].freeze

  # Optional feature switches. The baseline packages, network reconciliation,
  # disk growth, and the post-provision reboot check are always configured.
  PROVISION_UBUNTU_DESKTOP = true
  PROVISION_GENERAL_DEV_PACKAGES = true
  PROVISION_DOCKER = true
  PROVISION_RUST_FOR_SUBSTRATE = true
  PROVISION_PYTHON = true
  PROVISION_NODEJS = true
  PROVISION_POSTGRESQL = true
  PROVISION_MONGODB = true
  PROVISION_NGINX = true

  # An empty server-name list creates a private, HTTP-only static site. Public
  # certificates require explicit bridged ingress, valid DNS names, an email,
  # and external reachability on ports 80 and 443.
  NGINX_DEFAULT_SITE_NAME = "vagrant-default"
  NGINX_BRIDGED_INGRESS = false
  NGINX_SERVER_NAMES = [].freeze
  CERTBOT_EMAIL = ""

  # Build one deduplicated Ubuntu package transaction from the enabled features.
  # Ubuntu archive packages intentionally follow signed security updates rather
  # than being frozen to exact versions.
  OS_BASELINE_APT_PACKAGES = %w[
    ca-certificates cloud-guest-utils curl gnupg lvm2 openssl
    network-manager unattended-upgrades ufw
  ].freeze
  GENERAL_DEV_APT_PACKAGES = %w[
    build-essential gcc cmake clang libssl-dev protobuf-compiler
    git colordiff
  ].freeze
  RUST_APT_PACKAGES = %w[
    build-essential git clang libssl-dev protobuf-compiler
  ].freeze
  OS_APT_PACKAGES = (
    OS_BASELINE_APT_PACKAGES +
    (PROVISION_UBUNTU_DESKTOP ? %w[ubuntu-desktop-minimal] : []) +
    (PROVISION_GENERAL_DEV_PACKAGES ? GENERAL_DEV_APT_PACKAGES : []) +
    (PROVISION_RUST_FOR_SUBSTRATE ? RUST_APT_PACKAGES : []) +
    (PROVISION_NGINX ? %w[certbot nginx python3-certbot-nginx] : [])
  ).uniq.freeze

  # Provider and base box are exact, host-side inputs. Vagrant may install the
  # plugin and download the box automatically, but README.md shows explicit
  # commands that make those prerequisites visible before launch.
  VAGRANT_PLUGINS = {
    "vagrant-parallels" => { "version" => "2.4.9" }
  }.freeze

  BASE_BOX = "bento/ubuntu-26.04"
  BASE_BOX_VERSION = "202606.01.0"
  BASE_BOX_ARCHITECTURE = "arm64"

  # External-input policy for software not supplied by Ubuntu:
  # - Vagrant plugins and boxes use exact published versions.
  # - Third-party archives use immutable versioned URLs and pinned SHA-256.
  # - Third-party apt packages use exact versions and signed repositories.
  # - Container images use a readable tag plus immutable manifest digest.
  # Ubuntu archive packages intentionally track signed security updates.

  # Docker's signed apt repository and exact package versions.
  DOCKER_APT_KEY_SHA256 = "1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570"
  DOCKER_APT_KEY_URL = "https://download.docker.com/linux/ubuntu/gpg"
  DOCKER_APT_REPOSITORY_URL = "https://download.docker.com/linux/ubuntu"
  DOCKER_CE_VERSION = "5:29.7.1-1~ubuntu.26.04~resolute"
  DOCKER_CONTAINERD_VERSION = "2.2.6-1~ubuntu.26.04~resolute"
  DOCKER_BUILDX_VERSION = "0.36.0-1~ubuntu.26.04~resolute"
  DOCKER_COMPOSE_VERSION = "5.3.1-1~ubuntu.26.04~resolute"

  # Rustup installer integrity plus exact stable and dated nightly toolchains.
  RUSTUP_VERSION = "1.29.0"
  RUSTUP_INIT_SHA256 = "9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792"
  RUSTUP_INIT_URL = "https://static.rust-lang.org/rustup/archive/#{RUSTUP_VERSION}/aarch64-unknown-linux-gnu/rustup-init"
  RUST_STABLE_TOOLCHAIN = "1.97.1"
  RUST_NIGHTLY_TOOLCHAIN = "nightly-2026-07-31"

  # NVM source, the ARM64 Node.js binary archive, and Corepack package.
  NVM_VERSION = "v0.40.6"
  NVM_ARCHIVE_SHA256 = "17302cad7feedb1ad33ba738f93d2176a90970724f22de119603624fcbdec1a2"
  NVM_ARCHIVE_URL = "https://github.com/nvm-sh/nvm/archive/refs/tags/#{NVM_VERSION}.tar.gz"
  NODE_VERSION = "v22.23.2"
  NODE_ARCHIVE_SHA256 = "013b59cfd2819703a6f4a14ab891fc46fc2a4e3f5bcd92de3fb4929b43e35b30"
  NODE_ARCHIVE_URL = "https://nodejs.org/download/release/#{NODE_VERSION}/node-#{NODE_VERSION}-linux-arm64.tar.gz"
  COREPACK_VERSION = "0.35.0"
  COREPACK_ARCHIVE_SHA256 = "f62535fc7be1f77e4b12cd1e420b8542b8e895cbb14178926963a41a9232a4fe"
  COREPACK_ARCHIVE_URL = "https://registry.npmjs.org/corepack/-/corepack-#{COREPACK_VERSION}.tgz"

  # PostgreSQL's signed PGDG repository and exact server package version.
  POSTGRESQL_APT_KEY_SHA256 = "0144068502a1eddd2a0280ede10ef607d1ec592ce819940991203941564e8e76"
  POSTGRESQL_APT_KEY_URL = "https://www.postgresql.org/media/keys/ACCC4CF8.asc"
  POSTGRESQL_APT_REPOSITORY_URL = "https://apt.postgresql.org/pub/repos/apt"
  POSTGRESQL_MAJOR_VERSION = "18"
  POSTGRESQL_PACKAGE_VERSION = "18.4-1.pgdg26.04+1"
  # Same-major package downgrades are blocked unless this one-run safety gate is
  # explicitly enabled. Cross-major changes always require a manual migration.
  POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE = false

  # System-wide uv binaries and user-owned, uv-managed Python interpreters.
  UV_VERSION = "0.11.16"
  UV_ARCHIVE_SHA256 = "8c9d0f0ee98166ae6ab198747519ba6f25db29d185bd2ae5960ecebc91a5c22a"
  UV_ARCHIVE_URL = "https://github.com/astral-sh/uv/releases/download/#{UV_VERSION}/uv-aarch64-unknown-linux-gnu.tar.gz"
  PYTHON_VERSIONS = ["3.12.13", "3.13.12"].freeze

  # Authenticated development MongoDB. MongoDB 8.x cannot run on the Ubuntu
  # 26.04 box's Linux 7.0.0 kernel because of MongoDB's documented TCMalloc
  # incompatibility, so this template pins the maintained 7.0 release series.
  # The container is replaceable; the named volume retains database data.
  MONGODB_IMAGE = "mongo:7.0.39@sha256:9bdaeb6dac6e7e762e84e2f84103d1f9bb078fa1ba6bde8bb9d2274f655ad173"
  MONGODB_CONTAINER = "mongodb"
  MONGODB_VOLUME = "mongodb-data"
  MONGODB_PORT = 27017
  MONGODB_REPLICA_SET = "rs0"
  MONGODB_REPLICA_MEMBER = "#{VM_NAME}:#{MONGODB_PORT}"
  MONGODB_USERNAME = "vagrant"
  MONGODB_AUTH_DATABASE = "admin"
  MONGODB_PASSWORD_ENVIRONMENT_VARIABLE = "MONGODB_PASSWORD"
  MONGODB_PASSWORD = ENV.fetch(MONGODB_PASSWORD_ENVIRONMENT_VARIABLE, "")
  MONGODB_SECRETS_DIRECTORY = "/etc/mongodb-secrets"
  MONGODB_CONFIG_VERSION = "authenticated-private-v1"
  MONGODB_MANAGED_LABEL = "dev.vagrant.mongodb-managed"
  MONGODB_CONFIG_LABEL = "dev.vagrant.mongodb-config"
  MONGODB_CONFIG_DIGEST_LABEL = "dev.vagrant.mongodb-config-digest"
  MONGODB_STOP_TIMEOUT_SECONDS = 60
  MONGODB_READY_ATTEMPTS = 60
  MONGODB_HEALTH_ATTEMPTS = 30
  MONGODB_RETRY_DELAY_SECONDS = 2
  MONGODB_HEALTH_INTERVAL = "10s"
  MONGODB_HEALTH_TIMEOUT = "10s"
  MONGODB_HEALTH_START_PERIOD = "180s"
  MONGODB_HEALTH_RETRIES = 12
  MONGODB_DIAGNOSTIC_LOG_LINES = 200

  # Parallels resources. The plain 1000G disk is fixed-size and needs its full
  # capacity on the host. The storage workflow can grow but never shrink a disk.
  PARALLELS_RESOURCES_HDD_SIZE = "1000G"
  RESOURCES_CPUS = 8
  RESOURCES_MEMORY = 20000

  # Keep provisioner logic outside this Ruby file so shell syntax can be tested
  # independently. This inventory must match every referenced executable script.
  PROVISION_DIRECTORY = File.expand_path("provision/ubuntu-26.04", __dir__)
  PROVISION_SCRIPTS = %w[
    os-package-security-baseline.sh network-security.sh enlarge-hdd.sh
    ubuntu-desktop.sh general-dev-user.sh docker.sh rust-for-substrate.sh
    python-uv.sh python.sh python-user.sh nodejs.sh postgresql.sh mongodb.sh
    nginx.sh
  ].freeze
  GUEST_INTEGRATION_SCRIPT = File.expand_path("test/guest_integration.sh", __dir__)

  #
  # Validate the complete host-side configuration before plugin installation or
  # any guest mutation begins. Errors are accumulated so one run reports every
  # actionable problem instead of stopping at the first invalid value.
  #
  configuration_errors = []
  validate = lambda do |condition, message|
    configuration_errors << message unless condition
  end

  # Feature flags must be literal booleans. Truthy strings such as "false" would
  # otherwise enable a Ruby conditional and produce surprising results.
  feature_flags = {
    "PROVISION_UBUNTU_DESKTOP" => PROVISION_UBUNTU_DESKTOP,
    "PROVISION_GENERAL_DEV_PACKAGES" => PROVISION_GENERAL_DEV_PACKAGES,
    "PROVISION_DOCKER" => PROVISION_DOCKER,
    "PROVISION_RUST_FOR_SUBSTRATE" => PROVISION_RUST_FOR_SUBSTRATE,
    "PROVISION_PYTHON" => PROVISION_PYTHON,
    "PROVISION_NODEJS" => PROVISION_NODEJS,
    "PROVISION_POSTGRESQL" => PROVISION_POSTGRESQL,
    "PROVISION_MONGODB" => PROVISION_MONGODB,
    "PROVISION_NGINX" => PROVISION_NGINX
  }
  feature_flags.each do |name, value|
    validate.call(value == true || value == false, "#{name} must be true or false")
  end
  validate.call(POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE == true ||
                POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE == false,
                "POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE must be true or false")

  # Validate stable names and route policy used by several downstream scripts.
  validate.call(VM_NAME.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/),
                "VM_NAME must be a valid lowercase DNS hostname")
  validate.call(PROVIDER_VM_NAME == VM_NAME,
                "PROVIDER_VM_NAME must remain identical to VM_NAME")
  validate.call(DEFAULT_USER.match?(/\A[a-z_][a-z0-9_-]*\z/),
                "DEFAULT_USER is not a valid Linux username")
  validate.call(!BRIDGED_NETWORK_INTERFACE.empty? &&
                !BRIDGED_NETWORK_INTERFACE.match?(/[\0\r\n]/),
                "VAGRANT_BRIDGED_INTERFACE must name one host interface")
  validate.call(BRIDGED_NETWORK_ROUTE_METRIC.is_a?(Integer) &&
                BRIDGED_NETWORK_ROUTE_METRIC.positive?,
                "BRIDGED_NETWORK_ROUTE_METRIC must be a positive integer")
  validate.call(SHARED_NETWORK_ROUTE_METRIC.is_a?(Integer) &&
                SHARED_NETWORK_ROUTE_METRIC.positive?,
                "SHARED_NETWORK_ROUTE_METRIC must be a positive integer")
  validate.call(BRIDGED_NETWORK_ROUTE_METRIC < SHARED_NETWORK_ROUTE_METRIC,
                "the Bridged route metric must be lower than the Shared metric")
  validate.call(NGINX_BRIDGED_INGRESS == true || NGINX_BRIDGED_INGRESS == false,
                "NGINX_BRIDGED_INGRESS must be true or false")

  # Parse the host-only CIDR rather than relying on string-prefix comparisons.
  # The address must be a usable IPv4 host inside the configured network.
  begin
    private_address = IPAddr.new(PRIVATE_NETWORK_IP)
    private_network = IPAddr.new(PRIVATE_NETWORK_CIDR)
    private_prefix = Integer(PRIVATE_NETWORK_CIDR.split("/", 2).fetch(1))
    validate.call(private_address.ipv4? && private_network.ipv4?,
                  "the private network must use IPv4")
    validate.call((1..30).cover?(private_prefix),
                  "PRIVATE_NETWORK_CIDR must have a prefix between /1 and /30")
    validate.call(private_network.include?(private_address),
                  "PRIVATE_NETWORK_IP must be inside PRIVATE_NETWORK_CIDR")
    validate.call(private_address != private_network.to_range.first &&
                  private_address != private_network.to_range.last,
                  "PRIVATE_NETWORK_IP must be a usable host address")
  rescue IPAddr::InvalidAddressError, ArgumentError, IndexError
    configuration_errors << "PRIVATE_NETWORK_IP and PRIVATE_NETWORK_CIDR must be valid IPv4 values"
  end

  # Expand individual ports and ranges once on the host. This catches malformed
  # or overlapping UFW rules before the guest firewall is modified.
  private_ports = []
  PRIVATE_NETWORK_TCP_PORTS.each do |port_specification|
    match = port_specification.match(/\A(\d+)(?::(\d+))?\z/)
    unless match
      configuration_errors << "invalid private TCP port specification: #{port_specification.inspect}"
      next
    end

    first_port = Integer(match[1])
    last_port = Integer(match[2] || match[1])
    validate.call((1..65_535).cover?(first_port) &&
                  (1..65_535).cover?(last_port) && first_port <= last_port,
                  "private TCP port range is invalid: #{port_specification}")
    private_ports.concat((first_port..last_port).to_a) if first_port <= last_port
  end
  validate.call(private_ports.length == private_ports.uniq.length,
                "PRIVATE_NETWORK_TCP_PORTS contains overlapping entries")
  validate.call(private_ports.include?(22),
                "PRIVATE_NETWORK_TCP_PORTS must permit host-only SSH")

  # Cross-check feature dependencies and externally visible service ports.
  if PROVISION_NGINX
    validate.call([80, 443].all? { |port| private_ports.include?(port) },
                  "Nginx requires private TCP ports 80 and 443")
    validate.call(NGINX_DEFAULT_SITE_NAME.match?(/\A[a-z0-9][a-z0-9.-]*\z/),
                  "NGINX_DEFAULT_SITE_NAME is invalid")
    valid_server_name = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
    validate.call(NGINX_SERVER_NAMES.uniq == NGINX_SERVER_NAMES &&
                  NGINX_SERVER_NAMES.all? { |name| name.match?(valid_server_name) },
                  "NGINX_SERVER_NAMES must contain unique lowercase DNS names")
    unless NGINX_SERVER_NAMES.empty?
      validate.call(NGINX_BRIDGED_INGRESS,
                    "certificate domains require NGINX_BRIDGED_INGRESS")
      validate.call(CERTBOT_EMAIL.match?(/\A[^@\s]+@[^@\s]+\z/),
                    "certificate domains require a valid CERTBOT_EMAIL")
    end
  end
  if PROVISION_MONGODB
    validate.call(PROVISION_DOCKER, "MongoDB provisioning requires Docker")
    validate.call(private_ports.include?(MONGODB_PORT),
                  "MongoDB requires its port in PRIVATE_NETWORK_TCP_PORTS")
  end

  # Baseline packages are operational dependencies of later scripts. Optional
  # Nginx packages must also be present when its provisioner is enabled.
  required_baseline_packages = %w[
    ca-certificates cloud-guest-utils curl lvm2 openssl
    network-manager unattended-upgrades ufw
  ]
  missing_baseline_packages = required_baseline_packages - OS_BASELINE_APT_PACKAGES
  validate.call(missing_baseline_packages.empty?,
                "OS_BASELINE_APT_PACKAGES is missing: #{missing_baseline_packages.join(', ')}")
  validate.call(OS_APT_PACKAGES.all? { |package| package.match?(/\A[a-z0-9][a-z0-9+.-]*\z/) },
                "OS_APT_PACKAGES contains an invalid package name")
  if PROVISION_NGINX
    missing_nginx_packages = %w[certbot nginx python3-certbot-nginx] - OS_APT_PACKAGES
    validate.call(missing_nginx_packages.empty?,
                  "Nginx/Certbot packages are missing: #{missing_nginx_packages.join(', ')}")
  end

  # Enforce the reproducibility policy structurally: HTTPS transport, lowercase
  # SHA-256 values, exact package versions, and immutable version identifiers.
  # Actual bytes are verified by guest scripts after download.
  external_urls = [
    DOCKER_APT_KEY_URL, DOCKER_APT_REPOSITORY_URL, RUSTUP_INIT_URL,
    NVM_ARCHIVE_URL, NODE_ARCHIVE_URL, COREPACK_ARCHIVE_URL,
    POSTGRESQL_APT_KEY_URL, POSTGRESQL_APT_REPOSITORY_URL, UV_ARCHIVE_URL
  ]
  validate.call(external_urls.all? { |url| url.match?(/\Ahttps:\/\/[^\s]+\z/) },
                "all external inputs must use explicit HTTPS URLs")
  external_sha256_values = [
    DOCKER_APT_KEY_SHA256, RUSTUP_INIT_SHA256, NVM_ARCHIVE_SHA256,
    NODE_ARCHIVE_SHA256, COREPACK_ARCHIVE_SHA256,
    POSTGRESQL_APT_KEY_SHA256, UV_ARCHIVE_SHA256
  ]
  validate.call(external_sha256_values.all? { |digest| digest.match?(/\A[0-9a-f]{64}\z/) },
                "all external archive digests must be lowercase SHA-256 values")
  exact_package_versions = [
    DOCKER_CE_VERSION, DOCKER_CONTAINERD_VERSION,
    DOCKER_BUILDX_VERSION, DOCKER_COMPOSE_VERSION,
    POSTGRESQL_PACKAGE_VERSION
  ]
  validate.call(exact_package_versions.none? { |version| version.empty? || version.match?(/[\s*]/) },
                "third-party apt package versions must be exact")
  validate.call(POSTGRESQL_PACKAGE_VERSION.start_with?("#{POSTGRESQL_MAJOR_VERSION}."),
                "the PostgreSQL package version must match its major version")
  validate.call(POSTGRESQL_MAJOR_VERSION.match?(/\A[1-9][0-9]*\z/),
                "POSTGRESQL_MAJOR_VERSION must be a positive integer")
  validate.call(MONGODB_IMAGE.match?(/\A[^\s:@]+:[^\s@]+@sha256:[0-9a-f]{64}\z/),
                "MONGODB_IMAGE must contain both a tag and sha256 digest")
  validate.call(RUSTUP_VERSION.match?(/\A\d+\.\d+\.\d+\z/) &&
                RUST_STABLE_TOOLCHAIN.match?(/\A\d+\.\d+\.\d+\z/) &&
                RUST_NIGHTLY_TOOLCHAIN.match?(/\Anightly-\d{4}-\d{2}-\d{2}\z/),
                "Rust inputs must use exact stable and dated versions")
  validate.call(NVM_VERSION.match?(/\Av\d+\.\d+\.\d+\z/) &&
                NODE_VERSION.match?(/\Av\d+\.\d+\.\d+\z/) &&
                COREPACK_VERSION.match?(/\A\d+\.\d+\.\d+\z/),
                "Node inputs must use exact semantic versions")
  validate.call(UV_VERSION.match?(/\A\d+\.\d+\.\d+\z/) &&
                PYTHON_VERSIONS.all? { |version| version.match?(/\A\d+\.\d+\.\d+\z/) },
                "Python inputs must use exact semantic versions")
  versioned_urls = {
    RUSTUP_INIT_URL => RUSTUP_VERSION,
    NVM_ARCHIVE_URL => NVM_VERSION,
    NODE_ARCHIVE_URL => NODE_VERSION,
    COREPACK_ARCHIVE_URL => COREPACK_VERSION,
    UV_ARCHIVE_URL => UV_VERSION
  }
  validate.call(versioned_urls.all? { |url, version| url.include?(version) },
                "versioned external URLs must include their configured version")

  # Reject unsupported providers, architecture, box formats, and resource values
  # before Vagrant creates or resizes a VM.
  validate.call(VAGRANT_PLUGINS.keys == ["vagrant-parallels"],
                "this template supports only the Parallels provider plugin")
  validate.call(VAGRANT_PLUGINS.values.all? do |plugin|
                  plugin.fetch("version", "").match?(/\A\d+\.\d+\.\d+\z/)
                end,
                "Vagrant plugins must use exact semantic versions")
  validate.call(BASE_BOX_ARCHITECTURE == "arm64",
                "this Parallels template requires an arm64 base box")
  validate.call(BASE_BOX.match?(/\A[^\s\/]+\/[^\s\/]+\z/),
                "BASE_BOX must use the owner/name form")
  validate.call(BASE_BOX_VERSION.match?(/\A\d{6}\.\d+\.\d+\z/),
                "BASE_BOX_VERSION must be an exact Bento release")
  validate.call(PARALLELS_RESOURCES_HDD_SIZE.match?(/\A[1-9]\d*[GM]\z/),
                "PARALLELS_RESOURCES_HDD_SIZE must be an integer number of G or M")
  validate.call(RESOURCES_CPUS.is_a?(Integer) && RESOURCES_CPUS.positive?,
                "RESOURCES_CPUS must be a positive integer")
  validate.call(RESOURCES_MEMORY.is_a?(Integer) && RESOURCES_MEMORY.positive?,
                "RESOURCES_MEMORY must be a positive integer")

  # Extraction is safe only while the declared inventory, actual files, and
  # executable bits agree. The test suite adds syntax and reference checks.
  missing_provision_scripts = PROVISION_SCRIPTS.reject do |script|
    File.file?(File.join(PROVISION_DIRECTORY, script))
  end
  validate.call(missing_provision_scripts.empty?,
                "provision scripts are missing: #{missing_provision_scripts.join(', ')}")
  non_executable_provision_scripts = PROVISION_SCRIPTS.reject do |script|
    File.executable?(File.join(PROVISION_DIRECTORY, script))
  end
  validate.call(non_executable_provision_scripts.empty?,
                "provision scripts are not executable: #{non_executable_provision_scripts.join(', ')}")
  validate.call(File.file?(GUEST_INTEGRATION_SCRIPT) &&
                File.executable?(GUEST_INTEGRATION_SCRIPT),
                "the guest integration test is missing or not executable")

  # Validate inputs needed only by enabled user-level language/tooling features.
  if PROVISION_GENERAL_DEV_PACKAGES
    validate.call([GIT_USER_EMAIL, GIT_USER_NAME, GIT_CORE_EDITOR,
                   GITHUB_SSH_IDENTITY_FILE].none?(&:empty?),
                  "Git template inputs must not be empty")
  end
  if PROVISION_PYTHON
    validate.call(!PYTHON_VERSIONS.empty? && PYTHON_VERSIONS.uniq == PYTHON_VERSIONS,
                  "PYTHON_VERSIONS must contain unique pinned versions")
  end

  # MongoDB settings participate in container ownership, secret storage,
  # replica-set identity, retry loops, and health checks. Validate all of them
  # even when the current Vagrant command does not start the container.
  validate.call(MONGODB_PORT.is_a?(Integer) && (1..65_535).cover?(MONGODB_PORT),
                "MONGODB_PORT must be a valid TCP port")
  validate.call(MONGODB_REPLICA_MEMBER == "#{VM_NAME}:#{MONGODB_PORT}",
                "MONGODB_REPLICA_MEMBER must use VM_NAME and MONGODB_PORT")
  validate.call(MONGODB_USERNAME.match?(/\A[a-zA-Z0-9_.-]+\z/),
                "MONGODB_USERNAME contains unsupported characters")
  validate.call(MONGODB_CONTAINER.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]+\z/) &&
                MONGODB_VOLUME.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]+\z/),
                "MongoDB container and volume names are invalid")
  validate.call(MONGODB_SECRETS_DIRECTORY.start_with?("/") &&
                MONGODB_SECRETS_DIRECTORY != "/",
                "MONGODB_SECRETS_DIRECTORY must be an absolute non-root path")
  mongodb_labels = [MONGODB_MANAGED_LABEL, MONGODB_CONFIG_LABEL,
                    MONGODB_CONFIG_DIGEST_LABEL]
  validate.call(mongodb_labels.uniq.length == mongodb_labels.length &&
                mongodb_labels.all? { |label| label.match?(/\A[a-z0-9][a-z0-9_.-]+\z/) },
                "MongoDB lifecycle labels must be valid and unique")
  mongodb_positive_integers = [
    MONGODB_STOP_TIMEOUT_SECONDS, MONGODB_READY_ATTEMPTS,
    MONGODB_HEALTH_ATTEMPTS, MONGODB_RETRY_DELAY_SECONDS,
    MONGODB_HEALTH_RETRIES, MONGODB_DIAGNOSTIC_LOG_LINES
  ]
  validate.call(mongodb_positive_integers.all? { |value| value.is_a?(Integer) && value.positive? },
                "MongoDB lifecycle counts and timeouts must be positive integers")
  mongodb_durations = [MONGODB_HEALTH_INTERVAL, MONGODB_HEALTH_TIMEOUT,
                       MONGODB_HEALTH_START_PERIOD]
  validate.call(mongodb_durations.all? { |duration| duration.match?(/\A[1-9]\d*[smh]\z/) },
                "MongoDB health durations must be positive s, m, or h values")
  validate.call(!MONGODB_PASSWORD.match?(/[\0\r\n]/),
                "MONGODB_PASSWORD must not contain NUL or newline characters")

  # Require the secret only when the selected command can actually execute the
  # MongoDB provisioner. Targeting another named provisioner no longer blocks on
  # an unrelated secret; selecting the generic shell type still includes MongoDB.
  mongodb_secret_required = Ubuntu2604CommandPolicy.mongodb_secret_required?(
    ARGV,
    mongodb_enabled: PROVISION_MONGODB
  )
  if mongodb_secret_required
    validate.call(!MONGODB_PASSWORD.empty?,
                  "set #{MONGODB_PASSWORD_ENVIRONMENT_VARIABLE} before provisioning MongoDB")
  end

  # Fail before assigning any Vagrant objects that could install a plugin,
  # download a box, create a VM, or connect to a guest.
  unless configuration_errors.empty?
    formatted_errors = configuration_errors.map { |error| "  - #{error}" }.join("\n")
    abort "Invalid Vagrant template configuration:\n#{formatted_errors}"
  end

  #
  # VM definition
  #

  # Tell Vagrant the only accepted provider plugin and mask the MongoDB secret
  # in provisioner output. Explicit installation instructions remain in README.
  config.vagrant.plugins = VAGRANT_PLUGINS
  config.vagrant.sensitive = [MONGODB_PASSWORD] unless MONGODB_PASSWORD.empty?

  # Use one stable identity for Vagrant's machine key and the guest hostname.
  config.vm.define VM_NAME
  config.vm.hostname = VM_NAME

  # Pin the box release and architecture; automatic update checks are disabled
  # so a later upstream release cannot silently change a rebuild.
  config.vm.box = BASE_BOX
  config.vm.box_version = BASE_BOX_VERSION
  config.vm.box_architecture = BASE_BOX_ARCHITECTURE
  config.vm.box_check_update = false

  # Create a host folder beside this file and mount it through Parallels Tools.
  # The template is macOS/Parallels-only; it does not support Windows hosts.
  config.vm.synced_folder "./synced_folder", "/home/vagrant/synced_folder", create: true

  # Parallels supplies Adapter 1 (Shared/NAT) for Vagrant management. These two
  # declarations append Adapter 2 (host-only) and Adapter 3 (bridged Wi-Fi).
  # Guest Netplan later assigns route metrics and the firewall policy.
  config.vm.network "private_network", ip: PRIVATE_NETWORK_IP
  config.vm.network "public_network",
                    bridge: BRIDGED_NETWORK_INTERFACE,
                    use_dhcp_assigned_default_route: true


  # Parallels provider settings
  #
  # https://parallels.github.io/vagrant-parallels/docs/
  # https://parallels.github.io/vagrant-parallels/docs/configuration.html
  #
  config.vm.provider "parallels" do |prl|

    # A full clone owns an independent disk that can be enlarged without keeping
    # the source box snapshot. The tradeoff is slower creation and higher usage.
    prl.linked_clone = false

    # Keep the name shown in Parallels Control Center stable across rebuilds.
    prl.name = PROVIDER_VM_NAME

    # Shared folders and provider integration depend on compatible guest Tools.
    # An update can add several minutes and may restart the VM during first boot.
    prl.update_guest_tools = true

    # Provider values are CPU count and memory in mebibytes (MiB).
    prl.cpus = RESOURCES_CPUS
    prl.memory = RESOURCES_MEMORY

    # Vagrant's generic disk API does not support Parallels. Apply the desired
    # capacity directly before every boot so increases also reach existing VMs.
    # --no-fs-resize separates host disk capacity from guest partition/LVM growth.
    # Parallels refuses unsupported shrinking; the guest script only grows.
    prl.customize ["set",
                   :id,
                   "--device-set", "hdd0",
                   "--size", PARALLELS_RESOURCES_HDD_SIZE,
                   "--type=plain", "--no-fs-resize"]
  end


  #
  # Provisioning orchestration
  #

  # Resolve scripts relative to this Vagrantfile, not the caller's working
  # directory. Vagrant uploads each script and supplies only its declared inputs.
  provision_script = lambda do |script|
    File.join(PROVISION_DIRECTORY, script)
  end

  # Install the complete Ubuntu package set in one noninteractive transaction,
  # configure unattended security updates, and apply available updates now.
  config.vm.provision "os-package-security-baseline",
                      type: "shell",
                      privileged: true,
                      path: provision_script.call("os-package-security-baseline.sh"),
                      env: {
                        "OS_APT_PACKAGES" => OS_APT_PACKAGES.join(" ")
                      }

  # Reconcile all three guest interfaces, route preference, rollback protection,
  # and UFW rules. Unless provisioning is disabled, run: "always" repairs drift
  # on every up and reload after one-time provisioners are considered complete.
  config.vm.provision "network-security",
                      type: "shell",
                      privileged: true,
                      run: "always",
                      path: provision_script.call("network-security.sh"),
                      env: {
                        "PRIVATE_NETWORK_IP" => PRIVATE_NETWORK_IP,
                        "PRIVATE_NETWORK_CIDR" => PRIVATE_NETWORK_CIDR,
                        "BRIDGED_ROUTE_METRIC" => BRIDGED_NETWORK_ROUTE_METRIC.to_s,
                        "SHARED_ROUTE_METRIC" => SHARED_NETWORK_ROUTE_METRIC.to_s,
                        "NGINX_BRIDGED_INGRESS" => NGINX_BRIDGED_INGRESS.to_s,
                        "PRIVATE_NETWORK_TCP_PORTS" => PRIVATE_NETWORK_TCP_PORTS.join(" ")
                      }

  # Consume host-side disk growth inside the guest. Running on every normal up
  # lets a later increase to the configured Parallels disk size be reconciled.
  # The script preserves free extents that were already present in the root VG.
  config.vm.provision "enlarge-hdd",
                      type: "shell",
                      privileged: true,
                      run: "always",
                      path: provision_script.call("enlarge-hdd.sh")

  # Enable graphical login only after the combined apt baseline installed the
  # Ubuntu desktop packages.
  if PROVISION_UBUNTU_DESKTOP
    config.vm.provision "ubuntu-desktop",
                        type: "shell",
                        privileged: true,
                        path: provision_script.call("ubuntu-desktop.sh")
  end

  # User-owned Git configuration must run without sudo so files land in the
  # vagrant user's home rather than /root.
  if PROVISION_GENERAL_DEV_PACKAGES
    config.vm.provision "general-dev-user",
                        type: "shell",
                        privileged: false,
                        path: provision_script.call("general-dev-user.sh"),
                        env: {
                          "GIT_USER_EMAIL" => GIT_USER_EMAIL,
                          "GIT_USER_NAME" => GIT_USER_NAME,
                          "GIT_CORE_EDITOR" => GIT_CORE_EDITOR,
                          "GITHUB_SSH_IDENTITY_FILE" => GITHUB_SSH_IDENTITY_FILE
                        }
  end

  # Docker is a system service, so installation is privileged. The script adds
  # DEFAULT_USER to the docker group, binds default published ports to the
  # host-only address, and installs a DOCKER-USER policy based on the declared
  # network roles. This second firewall boundary is independent of UFW.
  if PROVISION_DOCKER
    config.vm.provision "docker",
                        type: "shell",
                        privileged: true,
                        path: provision_script.call("docker.sh"),
                        env: {
                          "DOCKER_APT_KEY_URL" => DOCKER_APT_KEY_URL,
                          "DOCKER_APT_REPOSITORY_URL" => DOCKER_APT_REPOSITORY_URL,
                          "DOCKER_APT_KEY_SHA256" => DOCKER_APT_KEY_SHA256,
                          "DOCKER_CE_VERSION" => DOCKER_CE_VERSION,
                          "DOCKER_CONTAINERD_VERSION" => DOCKER_CONTAINERD_VERSION,
                          "DOCKER_BUILDX_VERSION" => DOCKER_BUILDX_VERSION,
                          "DOCKER_COMPOSE_VERSION" => DOCKER_COMPOSE_VERSION,
                          "DEFAULT_USER" => DEFAULT_USER,
                          "PRIVATE_NETWORK_IP" => PRIVATE_NETWORK_IP,
                          "PRIVATE_NETWORK_CIDR" => PRIVATE_NETWORK_CIDR,
                          "BRIDGED_ROUTE_METRIC" => BRIDGED_NETWORK_ROUTE_METRIC.to_s,
                          "SHARED_ROUTE_METRIC" => SHARED_NETWORK_ROUTE_METRIC.to_s
                        }
  end

  # Rustup and toolchains belong to the development user and therefore run
  # unprivileged. Build dependencies were installed by the apt baseline.
  if PROVISION_RUST_FOR_SUBSTRATE
    config.vm.provision "rust-for-substrate",
                        type: "shell",
                        privileged: false,
                        path: provision_script.call("rust-for-substrate.sh"),
                        env: {
                          "RUSTUP_VERSION" => RUSTUP_VERSION,
                          "RUSTUP_INIT_URL" => RUSTUP_INIT_URL,
                          "RUSTUP_INIT_SHA256" => RUSTUP_INIT_SHA256,
                          "RUST_STABLE_TOOLCHAIN" => RUST_STABLE_TOOLCHAIN,
                          "RUST_NIGHTLY_TOOLCHAIN" => RUST_NIGHTLY_TOOLCHAIN
                        }
  end

  # Install trusted uv binaries system-wide, then install Python interpreters
  # and shell policy as the development user. Separating privileges prevents
  # root-owned files in the user's managed Python directories.
  if PROVISION_PYTHON
    config.vm.provision "python-uv",
                        type: "shell",
                        privileged: true,
                        path: provision_script.call("python-uv.sh"),
                        env: {
                          "UV_VERSION" => UV_VERSION,
                          "UV_ARCHIVE_URL" => UV_ARCHIVE_URL,
                          "UV_ARCHIVE_SHA256" => UV_ARCHIVE_SHA256
                        }

    config.vm.provision "python",
                        type: "shell",
                        privileged: false,
                        path: provision_script.call("python.sh"),
                        env: {
                          "PYTHON_VERSIONS" => PYTHON_VERSIONS.join(" ")
                        }

    config.vm.provision "python-user",
                        type: "shell",
                        privileged: false,
                        path: provision_script.call("python-user.sh")
  end

  # NVM, Node.js, and Corepack are per-user tools and must not write into /root.
  if PROVISION_NODEJS
    config.vm.provision "nodejs",
                        type: "shell",
                        privileged: false,
                        path: provision_script.call("nodejs.sh"),
                        env: {
                          "NVM_VERSION" => NVM_VERSION,
                          "NVM_ARCHIVE_URL" => NVM_ARCHIVE_URL,
                          "NVM_ARCHIVE_SHA256" => NVM_ARCHIVE_SHA256,
                          "NODE_VERSION" => NODE_VERSION,
                          "NODE_ARCHIVE_URL" => NODE_ARCHIVE_URL,
                          "NODE_ARCHIVE_SHA256" => NODE_ARCHIVE_SHA256,
                          "COREPACK_VERSION" => COREPACK_VERSION,
                          "COREPACK_ARCHIVE_URL" => COREPACK_ARCHIVE_URL,
                          "COREPACK_ARCHIVE_SHA256" => COREPACK_ARCHIVE_SHA256
                        }
  end

  # PostgreSQL is installed as a guest system service from the signed PGDG apt
  # repository. Database roles and application schemas are intentionally absent.
  if PROVISION_POSTGRESQL
    config.vm.provision "postgresql",
                        type: "shell",
                        privileged: true,
                        path: provision_script.call("postgresql.sh"),
                        env: {
                          "POSTGRESQL_APT_KEY_URL" => POSTGRESQL_APT_KEY_URL,
                          "POSTGRESQL_APT_REPOSITORY_URL" => POSTGRESQL_APT_REPOSITORY_URL,
                          "POSTGRESQL_APT_KEY_SHA256" => POSTGRESQL_APT_KEY_SHA256,
                          "POSTGRESQL_MAJOR_VERSION" => POSTGRESQL_MAJOR_VERSION,
                          "POSTGRESQL_PACKAGE_VERSION" => POSTGRESQL_PACKAGE_VERSION,
                          "POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE" => POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE.to_s
                        }
  end

  # MongoDB is a privileged Docker lifecycle operation. Mark both Vagrant's
  # provisioner and the concrete password value as sensitive so command output
  # does not echo the secret. The script persists data separately from container
  # configuration and refuses implicit password rotation.
  if PROVISION_MONGODB
    config.vm.provision "mongodb",
                        type: "shell",
                        privileged: true,
                        path: provision_script.call("mongodb.sh") do |mongodb|
      mongodb.env = {
        MONGODB_PASSWORD_ENVIRONMENT_VARIABLE => MONGODB_PASSWORD,
        "MONGODB_PASSWORD_ENVIRONMENT_VARIABLE" => MONGODB_PASSWORD_ENVIRONMENT_VARIABLE,
        "MONGODB_CONTAINER" => MONGODB_CONTAINER,
        "MONGODB_IMAGE" => MONGODB_IMAGE,
        "MONGODB_VOLUME" => MONGODB_VOLUME,
        "MONGODB_PORT" => MONGODB_PORT.to_s,
        "MONGODB_SECRETS_DIRECTORY" => MONGODB_SECRETS_DIRECTORY,
        "MONGODB_CONFIG_VERSION" => MONGODB_CONFIG_VERSION,
        "MONGODB_MANAGED_LABEL" => MONGODB_MANAGED_LABEL,
        "MONGODB_CONFIG_LABEL" => MONGODB_CONFIG_LABEL,
        "MONGODB_CONFIG_DIGEST_LABEL" => MONGODB_CONFIG_DIGEST_LABEL,
        "MONGODB_STOP_TIMEOUT_SECONDS" => MONGODB_STOP_TIMEOUT_SECONDS.to_s,
        "MONGODB_READY_ATTEMPTS" => MONGODB_READY_ATTEMPTS.to_s,
        "MONGODB_HEALTH_ATTEMPTS" => MONGODB_HEALTH_ATTEMPTS.to_s,
        "MONGODB_RETRY_DELAY_SECONDS" => MONGODB_RETRY_DELAY_SECONDS.to_s,
        "MONGODB_HEALTH_INTERVAL" => MONGODB_HEALTH_INTERVAL,
        "MONGODB_HEALTH_TIMEOUT" => MONGODB_HEALTH_TIMEOUT,
        "MONGODB_HEALTH_START_PERIOD" => MONGODB_HEALTH_START_PERIOD,
        "MONGODB_HEALTH_RETRIES" => MONGODB_HEALTH_RETRIES.to_s,
        "MONGODB_DIAGNOSTIC_LOG_LINES" => MONGODB_DIAGNOSTIC_LOG_LINES.to_s,
        "VM_NAME" => VM_NAME,
        "PRIVATE_NETWORK_IP" => PRIVATE_NETWORK_IP,
        "MONGODB_REPLICA_SET" => MONGODB_REPLICA_SET,
        "MONGODB_REPLICA_MEMBER" => MONGODB_REPLICA_MEMBER,
        "MONGODB_USERNAME" => MONGODB_USERNAME,
        "MONGODB_AUTH_DATABASE" => MONGODB_AUTH_DATABASE
      }
      mongodb.sensitive = true
    end
  end

  # Reconcile a minimal static Nginx site. Domain and certificate inputs remain
  # empty for private HTTP-only use; populated values enable Certbot behavior.
  if PROVISION_NGINX
    config.vm.provision "nginx",
                        type: "shell",
                        privileged: true,
                        path: provision_script.call("nginx.sh"),
                        env: {
                          "NGINX_SITE_NAME" => NGINX_DEFAULT_SITE_NAME,
                          "NGINX_SERVER_NAMES" => NGINX_SERVER_NAMES.join(" "),
                          "NGINX_PROBE_SERVER_NAME" => NGINX_SERVER_NAMES.first || "localhost",
                          "CERTBOT_EMAIL" => CERTBOT_EMAIL,
                          "CERTBOT_CERTIFICATE_NAME" => NGINX_SERVER_NAMES.first.to_s
                        }
  end

  # This read-only live test never runs during normal provisioning. Invoke it
  # explicitly after the VM is fully configured; run: "never" makes accidental
  # first-boot execution impossible.
  config.vm.provision "integration-test",
                      type: "shell",
                      privileged: true,
                      run: "never",
                      path: GUEST_INTEGRATION_SCRIPT,
                      env: {
                        "PRIVATE_NETWORK_IP" => PRIVATE_NETWORK_IP,
                        "PRIVATE_NETWORK_CIDR" => PRIVATE_NETWORK_CIDR,
                        "BRIDGED_ROUTE_METRIC" => BRIDGED_NETWORK_ROUTE_METRIC.to_s,
                        "SHARED_ROUTE_METRIC" => SHARED_NETWORK_ROUTE_METRIC.to_s,
                        "DOCKER_ENABLED" => PROVISION_DOCKER.to_s,
                        "POSTGRESQL_ENABLED" => PROVISION_POSTGRESQL.to_s,
                        "MONGODB_ENABLED" => PROVISION_MONGODB.to_s,
                        "NGINX_ENABLED" => PROVISION_NGINX.to_s,
                        "POSTGRESQL_MAJOR_VERSION" => POSTGRESQL_MAJOR_VERSION,
                        "POSTGRESQL_PACKAGE_VERSION" => POSTGRESQL_PACKAGE_VERSION,
                        "MONGODB_CONTAINER" => MONGODB_CONTAINER,
                        "MONGODB_IMAGE" => MONGODB_IMAGE,
                        "MONGODB_VOLUME" => MONGODB_VOLUME,
                        "MONGODB_PORT" => MONGODB_PORT.to_s,
                        "MONGODB_MANAGED_LABEL" => MONGODB_MANAGED_LABEL,
                        "MONGODB_SECRETS_DIRECTORY" => MONGODB_SECRETS_DIRECTORY,
                        "NGINX_PROBE_SERVER_NAME" => NGINX_SERVER_NAMES.first || "localhost",
                        "CERTBOT_CERTIFICATE_NAME" => NGINX_SERVER_NAMES.first.to_s
                      }

end
