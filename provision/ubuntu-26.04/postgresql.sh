#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: install an exact PostgreSQL server package from PostgreSQL's signed
# PGDG repository. Runs as root.
# Inputs: repository/key metadata, major version, exact package version, and a
# same-major package-downgrade safety gate.
# Scope: package installation only; roles, databases, passwords, listeners,
# backups, TLS, and application schemas are intentionally left to the developer.

# Validate every Vagrant-supplied input before trusting or changing apt sources.
for VARIABLE in \
  POSTGRESQL_APT_KEY_URL POSTGRESQL_APT_REPOSITORY_URL \
  POSTGRESQL_APT_KEY_SHA256 POSTGRESQL_MAJOR_VERSION \
  POSTGRESQL_PACKAGE_VERSION POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE; do
  : "${!VARIABLE:?}"
done

export DEBIAN_FRONTEND=noninteractive
POSTGRESQL_PACKAGE="postgresql-$POSTGRESQL_MAJOR_VERSION"

case "$POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE" in
  true|false) ;;
  *)
    echo "POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE must be true or false." >&2
    exit 1
    ;;
esac
if [[ ! "$POSTGRESQL_MAJOR_VERSION" =~ ^[1-9][0-9]*$ ]]; then
  echo "POSTGRESQL_MAJOR_VERSION must be a positive integer." >&2
  exit 1
fi

# PostgreSQL data formats are major-version specific. Refuse to install a target
# major while any different-major cluster remains registered. An upgrade needs
# pg_upgrade or dump/restore; a downgrade needs a dump from the newer server and
# restore into a newly initialized older cluster. Package installation cannot
# safely perform either migration implicitly.
if command -v pg_lsclusters > /dev/null 2>&1; then
  while read -r EXISTING_MAJOR CLUSTER_NAME; do
    [ -n "$EXISTING_MAJOR" ] || continue
    if [ "$EXISTING_MAJOR" = "$POSTGRESQL_MAJOR_VERSION" ]; then
      continue
    fi
    if [ "$EXISTING_MAJOR" -lt "$POSTGRESQL_MAJOR_VERSION" ]; then
      TRANSITION="upgrade"
    else
      TRANSITION="downgrade"
    fi
    echo "PostgreSQL major $TRANSITION blocked: cluster $EXISTING_MAJOR/$CLUSTER_NAME exists, target is $POSTGRESQL_MAJOR_VERSION." >&2
    echo "Back up the cluster and complete a documented pg_upgrade or dump/restore migration first." >&2
    exit 1
  done < <(pg_lsclusters --no-header | awk '{ print $1, $2 }')
elif compgen -G '/etc/postgresql/[0-9]*/*' > /dev/null; then
  echo "PostgreSQL cluster configuration exists but pg_lsclusters is unavailable; refusing a version change." >&2
  exit 1
fi

# A package downgrade inside one major does not change the data format, but it
# can still be incompatible. Require an explicit reviewed opt-in and pass apt's
# matching flag only in that case.
INSTALLED_POSTGRESQL_VERSION=""
if dpkg-query --show "$POSTGRESQL_PACKAGE" > /dev/null 2>&1; then
  INSTALLED_POSTGRESQL_VERSION="$(
    dpkg-query --show --showformat='${Version}' "$POSTGRESQL_PACKAGE"
  )"
fi
if [ -n "$INSTALLED_POSTGRESQL_VERSION" ] && \
   dpkg --compare-versions "$INSTALLED_POSTGRESQL_VERSION" gt "$POSTGRESQL_PACKAGE_VERSION" && \
   [ "$POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE" != true ]; then
  echo "PostgreSQL package downgrade blocked: $INSTALLED_POSTGRESQL_VERSION -> $POSTGRESQL_PACKAGE_VERSION." >&2
  echo "Back up the database, review compatibility, then temporarily set POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE to true." >&2
  exit 1
fi

echo "\n\n###\n### Install PostgreSQL\n###\n"

# Verify the downloaded signing key before giving it authority over apt metadata.
# The temporary file is removed automatically on any earlier failure.
install -d -m 0755 /usr/share/postgresql-common/pgdg
POSTGRESQL_KEY_TEMP="$(mktemp)"
trap 'rm -f "$POSTGRESQL_KEY_TEMP"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL "$POSTGRESQL_APT_KEY_URL" \
  -o "$POSTGRESQL_KEY_TEMP"
printf '%s  %s\n' "$POSTGRESQL_APT_KEY_SHA256" "$POSTGRESQL_KEY_TEMP" | \
  sha256sum --check -
install -m 0644 "$POSTGRESQL_KEY_TEMP" \
  /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
rm -f "$POSTGRESQL_KEY_TEMP"
trap - EXIT

# Declare the PGDG source in Deb822 format, scoped to the guest architecture and
# the verified key. Remove the legacy one-line source to avoid duplicate entries.
. /etc/os-release
printf '%s\n' \
  'Types: deb' \
  "URIs: $POSTGRESQL_APT_REPOSITORY_URL" \
  "Suites: $VERSION_CODENAME-pgdg" \
  'Components: main' \
  "Architectures: $(dpkg --print-architecture)" \
  'Signed-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc' \
  > /etc/apt/sources.list.d/pgdg.sources
rm -f /etc/apt/sources.list.d/pgdg.list

# Pin above priority 1000 so apt converges to the reviewed exact version instead
# of silently selecting the newest repository release.
cat > /etc/apt/preferences.d/postgresql <<APT_PREFERENCES
Package: $POSTGRESQL_PACKAGE
Pin: version $POSTGRESQL_PACKAGE_VERSION
Pin-Priority: 1001
APT_PREFERENCES

# The package creates and enables PostgreSQL using PGDG's normal Ubuntu defaults.
apt-get update
APT_DOWNGRADE_ARGUMENTS=()
if [ "$POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE" = true ]; then
  APT_DOWNGRADE_ARGUMENTS+=(--allow-downgrades)
fi
apt-get install --assume-yes "${APT_DOWNGRADE_ARGUMENTS[@]}" \
  "$POSTGRESQL_PACKAGE=$POSTGRESQL_PACKAGE_VERSION"

# Check dpkg's installed result independently of apt's return status.
INSTALLED_POSTGRESQL_VERSION="$(
  dpkg-query --show --showformat='${Version}' "$POSTGRESQL_PACKAGE"
)"
if [ "$INSTALLED_POSTGRESQL_VERSION" != "$POSTGRESQL_PACKAGE_VERSION" ]; then
  echo "$POSTGRESQL_PACKAGE version $INSTALLED_POSTGRESQL_VERSION does not match $POSTGRESQL_PACKAGE_VERSION." >&2
  exit 1
fi

# Require the default target-major cluster to exist and accept connections. A
# successful dpkg transaction alone does not prove that the database is usable.
TARGET_CLUSTER="$(
  pg_lsclusters --no-header | \
    awk -v major="$POSTGRESQL_MAJOR_VERSION" '$1 == major && $2 == "main" { print $3, $4; exit }'
)"
read -r TARGET_PORT TARGET_STATUS <<< "$TARGET_CLUSTER"
if [ -z "${TARGET_PORT:-}" ] || [ "$TARGET_STATUS" != online ]; then
  echo "PostgreSQL cluster $POSTGRESQL_MAJOR_VERSION/main is missing or offline." >&2
  pg_lsclusters >&2 || true
  exit 1
fi
systemctl enable postgresql
if ! pg_isready --quiet --host /var/run/postgresql --port "$TARGET_PORT"; then
  echo "PostgreSQL $POSTGRESQL_MAJOR_VERSION/main is not accepting connections on port $TARGET_PORT." >&2
  exit 1
fi
