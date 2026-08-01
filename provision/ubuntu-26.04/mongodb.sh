#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: reconcile an authenticated, single-member MongoDB replica set in a
# Docker container bound only to the guest's host-only address. Runs as root.
# Inputs: secret name/value, pinned image, container/volume identity, replica-set
# identity, bind address, lifecycle labels, and bounded retry/health settings.
# Data model: the container is replaceable, while its named local Docker volume
# persists across reprovisioning. The script never deletes the data volume.
# Limitations: development use only; there is no TLS, backup, high availability,
# automated password rotation, or least-privilege application user.

# `${!VARIABLE:?}` validates every named Vagrant input, including the password,
# before Docker, volumes, containers, or guest secret files are touched.
for VARIABLE in \
  MONGODB_PASSWORD MONGODB_PASSWORD_ENVIRONMENT_VARIABLE MONGODB_CONTAINER \
  MONGODB_IMAGE MONGODB_VOLUME MONGODB_PORT MONGODB_SECRETS_DIRECTORY \
  MONGODB_CONFIG_VERSION MONGODB_MANAGED_LABEL MONGODB_CONFIG_LABEL \
  MONGODB_CONFIG_DIGEST_LABEL MONGODB_STOP_TIMEOUT_SECONDS \
  MONGODB_READY_ATTEMPTS MONGODB_HEALTH_ATTEMPTS \
  MONGODB_RETRY_DELAY_SECONDS MONGODB_HEALTH_INTERVAL \
  MONGODB_HEALTH_TIMEOUT MONGODB_HEALTH_START_PERIOD \
  MONGODB_HEALTH_RETRIES MONGODB_DIAGNOSTIC_LOG_LINES VM_NAME \
  PRIVATE_NETWORK_IP MONGODB_REPLICA_SET MONGODB_REPLICA_MEMBER \
  MONGODB_USERNAME MONGODB_AUTH_DATABASE; do
  : "${!VARIABLE:?}"
done

echo "\n\n###\n### Run authenticated MongoDB on the host-only network\n###\n"

# Guest secret files are root-controlled and mounted read-only at a separate
# container path. JavaScript helpers read the password from a file so it is not
# embedded in generated scripts or Docker's environment metadata.
MONGODB_KEYFILE="$MONGODB_SECRETS_DIRECTORY/keyfile"
MONGODB_PASSWORD_FILE="$MONGODB_SECRETS_DIRECTORY/root-password"
MONGODB_INITIALIZE_SCRIPT="$MONGODB_SECRETS_DIRECTORY/initialize-replica-set.js"
MONGODB_USER_SCRIPT="$MONGODB_SECRETS_DIRECTORY/ensure-user.js"
MONGODB_INSPECT_REPLICA_SCRIPT="$MONGODB_SECRETS_DIRECTORY/inspect-replica-member.js"
MONGODB_RECONCILE_REPLICA_SCRIPT="$MONGODB_SECRETS_DIRECTORY/reconcile-replica-member.js"
MONGODB_RESTORE_REPLICA_SCRIPT="$MONGODB_SECRETS_DIRECTORY/restore-replica-member.js"
MONGODB_VERIFY_SCRIPT="$MONGODB_SECRETS_DIRECTORY/verify.js"
MONGODB_PREVIOUS_REPLICA_MEMBER_FILE="$MONGODB_SECRETS_DIRECTORY/previous-replica-member"
MONGODB_OWNERSHIP_MARKER="$MONGODB_SECRETS_DIRECTORY/.vagrant-managed"
CONTAINER_SECRETS_DIRECTORY="/run/secrets/mongodb"
CONTAINER_KEYFILE="$CONTAINER_SECRETS_DIRECTORY/keyfile"
CONTAINER_PASSWORD_FILE="$CONTAINER_SECRETS_DIRECTORY/root-password"
CONTAINER_VERIFY_SCRIPT="$CONTAINER_SECRETS_DIRECTORY/verify.js"

# On any failure, remove an unfinished secret file and include useful container
# state/logs in Vagrant output. A successful run disables this EXIT handler.
MONGODB_SECRET_TEMP=""
MONGODB_ROLLBACK_CONTAINER=""
MONGODB_EXISTING_CONTAINER_PRESENT=false
MONGODB_EXISTING_WAS_RUNNING=false
MONGODB_REPLICA_MEMBER_MIGRATED=false
MONGODB_SECRET_TRANSACTION_DIRECTORY=""
MONGODB_SECRET_SNAPSHOT=""
MONGODB_SECRETS_PREEXISTED=false
diagnose_mongodb_failure() {
  local status=$?
  trap - EXIT
  [ -z "$MONGODB_SECRET_TEMP" ] || rm -f "$MONGODB_SECRET_TEMP"
  if [ "$status" -ne 0 ] && \
     docker container inspect "$MONGODB_CONTAINER" > /dev/null 2>&1; then
    echo "MongoDB container state:" >&2
    docker container inspect --format '{{json .State}}' \
      "$MONGODB_CONTAINER" >&2 || true
    echo "Last $MONGODB_DIAGNOSTIC_LOG_LINES MongoDB log lines:" >&2
    docker container logs --tail "$MONGODB_DIAGNOSTIC_LOG_LINES" \
      "$MONGODB_CONTAINER" >&2 || true
  fi

  # A replica-member rename changes persistent database metadata. Reverse that
  # change before restoring an older container definition when a later health or
  # binding check fails.
  if [ "$status" -ne 0 ] && [ "$MONGODB_REPLICA_MEMBER_MIGRATED" = true ] && \
     docker container inspect "$MONGODB_CONTAINER" > /dev/null 2>&1; then
    echo "Restoring the previous MongoDB replica-set member address." >&2
    docker exec "$MONGODB_CONTAINER" mongosh --quiet \
      --file "$CONTAINER_SECRETS_DIRECTORY/restore-replica-member.js" \
      > /dev/null 2>&1 || \
      echo "Could not reverse the replica member migration automatically." >&2
  fi

  # During replacement, the prior managed container is renamed rather than
  # deleted. Put it back if the candidate fails; the shared data volume is never
  # mounted by both containers at the same time.
  if [ "$status" -ne 0 ] && [ -n "$MONGODB_ROLLBACK_CONTAINER" ]; then
    echo "Restoring the previous MongoDB container definition." >&2
    docker container rm --force "$MONGODB_CONTAINER" > /dev/null 2>&1 || true
    if docker container rename "$MONGODB_ROLLBACK_CONTAINER" \
         "$MONGODB_CONTAINER"; then
      MONGODB_ROLLBACK_CONTAINER=""
    else
      echo "Could not restore container $MONGODB_ROLLBACK_CONTAINER automatically." >&2
    fi
  fi

  # Generated health/replica scripts are bind-mounted, so an old container also
  # needs the exact secret-directory snapshot that accompanied its definition.
  if [ "$status" -ne 0 ] && [ "$MONGODB_SECRETS_PREEXISTED" = true ] && \
     [ -d "$MONGODB_SECRET_SNAPSHOT" ]; then
    if [ -d "$MONGODB_SECRETS_DIRECTORY" ] && \
       [ ! -L "$MONGODB_SECRETS_DIRECTORY" ]; then
      find "$MONGODB_SECRETS_DIRECTORY" -depth -delete
    fi
    cp -a -- "$MONGODB_SECRET_SNAPSHOT" "$MONGODB_SECRETS_DIRECTORY" || \
      echo "Could not restore the previous MongoDB secret directory." >&2
  fi
  if [ "$status" -ne 0 ] && [ "$MONGODB_EXISTING_CONTAINER_PRESENT" = true ] && \
     docker container inspect "$MONGODB_CONTAINER" > /dev/null 2>&1; then
    if [ "$MONGODB_EXISTING_WAS_RUNNING" = true ]; then
      docker container start "$MONGODB_CONTAINER" > /dev/null || true
    else
      docker container stop --timeout "$MONGODB_STOP_TIMEOUT_SECONDS" \
        "$MONGODB_CONTAINER" > /dev/null 2>&1 || true
    fi
  fi
  rm -f "$MONGODB_PREVIOUS_REPLICA_MEMBER_FILE"
  if [ -n "$MONGODB_SECRET_TRANSACTION_DIRECTORY" ] && \
     [ -d "$MONGODB_SECRET_TRANSACTION_DIRECTORY" ]; then
    find "$MONGODB_SECRET_TRANSACTION_DIRECTORY" -depth -delete
  fi
  exit "$status"
}
trap diagnose_mongodb_failure EXIT

# Confirm the daemon is usable and fetch the immutable image reference before
# changing local container state.
docker info > /dev/null

# Refuse an unowned same-named container before pulling images, creating volumes,
# or changing secret files. A template-managed container must carry the ownership
# label and mount exactly the declared persistent data volume; a version-label
# match alone is not evidence of ownership.
if docker container inspect "$MONGODB_CONTAINER" > /dev/null 2>&1; then
  MONGODB_EXISTING_CONTAINER_PRESENT=true
  if [ "$(docker container inspect --format '{{.State.Running}}' \
          "$MONGODB_CONTAINER")" = true ]; then
    MONGODB_EXISTING_WAS_RUNNING=true
  fi
  PREFLIGHT_MANAGED_LABEL="$(docker container inspect \
    --format "{{index .Config.Labels \"$MONGODB_MANAGED_LABEL\"}}" \
    "$MONGODB_CONTAINER")"
  PREFLIGHT_MONGODB_VOLUME="$(docker container inspect \
    --format '{{range .Mounts}}{{if eq .Destination "/data/db"}}{{.Name}}{{end}}{{end}}' \
    "$MONGODB_CONTAINER")"
  if [ "$PREFLIGHT_MANAGED_LABEL" != true ]; then
    echo "Container $MONGODB_CONTAINER is not marked as template-owned; refusing to modify it." >&2
    exit 1
  fi
  if [ "$PREFLIGHT_MONGODB_VOLUME" != "$MONGODB_VOLUME" ]; then
    echo "Managed MongoDB uses unexpected data volume: $PREFLIGHT_MONGODB_VOLUME" >&2
    exit 1
  fi
fi

docker pull "$MONGODB_IMAGE"

# Create the persistent volume when absent. Refuse non-local drivers because the
# ownership, durability, and cleanup expectations in this template assume local
# guest storage.
if ! docker volume inspect "$MONGODB_VOLUME" > /dev/null 2>&1; then
  docker volume create \
    --label "$MONGODB_MANAGED_LABEL=true" \
    "$MONGODB_VOLUME" > /dev/null
fi
if [ "$(docker volume inspect --format '{{.Driver}}' "$MONGODB_VOLUME")" != "local" ]; then
  echo "MongoDB volume $MONGODB_VOLUME must use Docker's local driver." >&2
  exit 1
fi
if [ "$(docker volume inspect \
        --format "{{index .Labels \"$MONGODB_MANAGED_LABEL\"}}" \
        "$MONGODB_VOLUME")" != "true" ]; then
  echo "Volume $MONGODB_VOLUME is not marked as template-owned; refusing to use it." >&2
  exit 1
fi

# Secret file ownership must match the numeric mongodb account inside the pinned
# image. Query the image instead of assuming its UID/GID never changes.
MONGODB_UID="$(docker run --rm --entrypoint id "$MONGODB_IMAGE" -u mongodb)"
MONGODB_GID="$(docker run --rm --entrypoint id "$MONGODB_IMAGE" -g mongodb)"
if ! [[ "$MONGODB_UID" =~ ^[0-9]+$ && "$MONGODB_GID" =~ ^[0-9]+$ ]]; then
  echo "Cannot resolve the MongoDB image's numeric user and group." >&2
  exit 1
fi

# Adopt an older template directory only when every existing entry has a known
# generated name. The marker prevents silently taking ownership of an arbitrary
# administrator directory after the first successful run.
if [ -L "$MONGODB_SECRETS_DIRECTORY" ]; then
  echo "MongoDB secrets path must not be a symbolic link." >&2
  exit 1
fi
if [ -d "$MONGODB_SECRETS_DIRECTORY" ] && \
   [ ! -f "$MONGODB_OWNERSHIP_MARKER" ]; then
  while IFS= read -r -d '' EXISTING_SECRET_PATH; do
    EXISTING_SECRET_NAME="${EXISTING_SECRET_PATH##*/}"
    if [ -L "$EXISTING_SECRET_PATH" ] || [ ! -f "$EXISTING_SECRET_PATH" ]; then
      echo "Refusing to adopt non-regular MongoDB secret resource: $EXISTING_SECRET_NAME" >&2
      exit 1
    fi
    case "$EXISTING_SECRET_NAME" in
      keyfile|root-password|initialize-replica-set.js|ensure-user.js|verify.js) ;;
      *)
        echo "Refusing to adopt unknown file in MongoDB secrets directory: $EXISTING_SECRET_NAME" >&2
        exit 1
        ;;
    esac
  done < <(find "$MONGODB_SECRETS_DIRECTORY" -mindepth 1 -maxdepth 1 -print0)
elif [ -e "$MONGODB_SECRETS_DIRECTORY" ] && \
     [ ! -d "$MONGODB_SECRETS_DIRECTORY" ]; then
  echo "MongoDB secrets path exists but is not a directory." >&2
  exit 1
fi

# Snapshot the whole existing generated directory before updating any marker,
# credential, or JavaScript helper. It remains root-only and is removed after a
# successful run; the EXIT handler restores it when an existing deployment fails.
install -d -m 0700 /var/lib/vagrant/mongodb-transactions
MONGODB_SECRET_TRANSACTION_DIRECTORY="$(
  mktemp -d /var/lib/vagrant/mongodb-transactions/transaction.XXXXXX
)"
if [ -d "$MONGODB_SECRETS_DIRECTORY" ]; then
  MONGODB_SECRETS_PREEXISTED=true
  MONGODB_SECRET_SNAPSHOT="$MONGODB_SECRET_TRANSACTION_DIRECTORY/secrets"
  cp -a -- "$MONGODB_SECRETS_DIRECTORY" "$MONGODB_SECRET_SNAPSHOT"
fi
install -d -o root -g "$MONGODB_GID" -m 0750 "$MONGODB_SECRETS_DIRECTORY"
for MANAGED_SECRET_PATH in \
  "$MONGODB_OWNERSHIP_MARKER" "$MONGODB_KEYFILE" "$MONGODB_PASSWORD_FILE" \
  "$MONGODB_INITIALIZE_SCRIPT" "$MONGODB_USER_SCRIPT" \
  "$MONGODB_INSPECT_REPLICA_SCRIPT" "$MONGODB_RECONCILE_REPLICA_SCRIPT" \
  "$MONGODB_RESTORE_REPLICA_SCRIPT" "$MONGODB_VERIFY_SCRIPT" \
  "$MONGODB_PREVIOUS_REPLICA_MEMBER_FILE"; do
  if [ -L "$MANAGED_SECRET_PATH" ]; then
    echo "Managed MongoDB secret path must not be a symbolic link: $MANAGED_SECRET_PATH" >&2
    exit 1
  fi
done
printf '%s\n' "$MONGODB_CONFIG_VERSION" > "$MONGODB_OWNERSHIP_MARKER"
chown root:root "$MONGODB_OWNERSHIP_MARKER"
chmod 0400 "$MONGODB_OWNERSHIP_MARKER"

# The keyfile authenticates members of the replica set. Generate it once with
# strong randomness, then continuously enforce the permissions MongoDB requires.
if [ ! -s "$MONGODB_KEYFILE" ]; then
  umask 077
  MONGODB_SECRET_TEMP="$(mktemp "$MONGODB_SECRETS_DIRECTORY/keyfile.XXXXXX")"
  openssl rand -base64 756 > "$MONGODB_SECRET_TEMP"
  chown "$MONGODB_UID:$MONGODB_GID" "$MONGODB_SECRET_TEMP"
  chmod 0400 "$MONGODB_SECRET_TEMP"
  mv "$MONGODB_SECRET_TEMP" "$MONGODB_KEYFILE"
  MONGODB_SECRET_TEMP=""
fi
chown "$MONGODB_UID:$MONGODB_GID" "$MONGODB_KEYFILE"
chmod 0400 "$MONGODB_KEYFILE"

# The stored credential is a guard against accidental lockout. Changing only the
# host environment variable is not a database password rotation, so stop before
# replacing a working container when values differ.
if [ -s "$MONGODB_PASSWORD_FILE" ] && \
   ! cmp --silent "$MONGODB_PASSWORD_FILE" <(printf '%s' "$MONGODB_PASSWORD"); then
  echo "$MONGODB_PASSWORD_ENVIRONMENT_VARIABLE differs from the stored MongoDB credential." >&2
  echo "Rotate the database password explicitly before changing the template secret." >&2
  exit 1
fi
umask 077
MONGODB_SECRET_TEMP="$(mktemp "$MONGODB_SECRETS_DIRECTORY/root-password.XXXXXX")"
printf '%s' "$MONGODB_PASSWORD" > "$MONGODB_SECRET_TEMP"
# The official entrypoint drops privileges before it resolves the *_FILE
# variable. Keep host-side ownership with root, while granting the pinned
# image's dynamically discovered mongodb group read-only access.
chown "root:$MONGODB_GID" "$MONGODB_SECRET_TEMP"
chmod 0440 "$MONGODB_SECRET_TEMP"
mv "$MONGODB_SECRET_TEMP" "$MONGODB_PASSWORD_FILE"
MONGODB_SECRET_TEMP=""

# Initialize the replica set only when MongoDB reports code 94 (not initialized).
# Authentication may fail before the first user exists because MongoDB's localhost
# exception is expected during bootstrap; other status errors remain fatal.
cat > "$MONGODB_INITIALIZE_SCRIPT" <<MONGOSH
const admin = db.getSiblingDB("$MONGODB_AUTH_DATABASE");
const fs = require("fs");
const password = fs.readFileSync("/run/secrets/mongodb/root-password", "utf8");
try {
  admin.auth({ user: "$MONGODB_USERNAME", pwd: password });
} catch (_error) {
  // The localhost exception permits initialization before the first user exists.
}

try {
  const status = rs.status();
  if (status.ok !== 1) quit(1);
} catch (error) {
  const notInitialized = error.code === 94 ||
    String(error.message).includes("no replset config has been received");
  if (!notInitialized) {
    if (error.code === 13) {
      console.error(
        "MongoDB authorization failed. Existing credentials may differ " +
        "from $MONGODB_PASSWORD_ENVIRONMENT_VARIABLE."
      );
    }
    throw error;
  }

  const result = rs.initiate({
    _id: "$MONGODB_REPLICA_SET",
    members: [{ _id: 0, host: "$MONGODB_REPLICA_MEMBER" }]
  });
  if (result.ok !== 1) quit(1);
}
MONGOSH

# Ensure the configured administrative user exists and accepts the supplied
# password. Existing databases must authenticate; only a fresh localhost-exception
# bootstrap is allowed to create the user.
cat > "$MONGODB_USER_SCRIPT" <<MONGOSH
const admin = db.getSiblingDB("$MONGODB_AUTH_DATABASE");
const fs = require("fs");
const password = fs.readFileSync("/run/secrets/mongodb/root-password", "utf8");
let authenticated = false;

try {
  authenticated = admin.auth({ user: "$MONGODB_USERNAME", pwd: password });
} catch (_error) {
  authenticated = false;
}

if (!authenticated) {
  try {
    admin.createUser({
      user: "$MONGODB_USERNAME",
      pwd: password,
      roles: [{ role: "root", db: "$MONGODB_AUTH_DATABASE" }]
    });
  } catch (error) {
    console.error(
      "Unable to create the MongoDB user. Existing credentials may differ " +
      "from $MONGODB_PASSWORD_ENVIRONMENT_VARIABLE."
    );
    throw error;
  }

  if (!admin.auth({ user: "$MONGODB_USERNAME", pwd: password })) quit(1);
}
MONGOSH

# Read and validate the persistent replica configuration independently of the
# container labels. A fresh database may still be using MongoDB's localhost
# exception; a changed member address requires the existing administrator
# credential before it can be migrated.
cat > "$MONGODB_INSPECT_REPLICA_SCRIPT" <<MONGOSH
const admin = db.getSiblingDB("$MONGODB_AUTH_DATABASE");
const fs = require("fs");
const password = fs.readFileSync("/run/secrets/mongodb/root-password", "utf8");
let authenticated = false;
try {
  authenticated = admin.auth({ user: "$MONGODB_USERNAME", pwd: password });
} catch (_error) {
  authenticated = false;
}

const config = rs.conf();
if (config._id !== "$MONGODB_REPLICA_SET" || config.members.length !== 1) {
  console.error("Expected one member in replica set $MONGODB_REPLICA_SET.");
  quit(1);
}
const currentMember = config.members[0].host;
if (currentMember !== "$MONGODB_REPLICA_MEMBER" && !authenticated) {
  console.error("Authentication is required to migrate the replica member address.");
  quit(1);
}
print(currentMember);
MONGOSH

# A VM-name or private-port change is a supported single-member migration. Force
# is appropriate only because this template explicitly rejects multi-member
# replica sets above and there is no second voting member to coordinate with.
cat > "$MONGODB_RECONCILE_REPLICA_SCRIPT" <<MONGOSH
const admin = db.getSiblingDB("$MONGODB_AUTH_DATABASE");
const fs = require("fs");
const password = fs.readFileSync("/run/secrets/mongodb/root-password", "utf8");
if (!admin.auth({ user: "$MONGODB_USERNAME", pwd: password })) quit(1);
const config = rs.conf();
if (config._id !== "$MONGODB_REPLICA_SET" || config.members.length !== 1) quit(1);
config.members[0].host = "$MONGODB_REPLICA_MEMBER";
const result = rs.reconfig(config, { force: true });
if (result.ok !== 1) quit(1);
MONGOSH

# The EXIT handler uses this script only after a later failure. The preceding
# member value is written to a root-created, MongoDB-readable file before the
# forward reconfiguration starts.
cat > "$MONGODB_RESTORE_REPLICA_SCRIPT" <<MONGOSH
const admin = db.getSiblingDB("$MONGODB_AUTH_DATABASE");
const fs = require("fs");
const password = fs.readFileSync("/run/secrets/mongodb/root-password", "utf8");
const previousMember = fs.readFileSync(
  "/run/secrets/mongodb/previous-replica-member", "utf8"
);
if (!admin.auth({ user: "$MONGODB_USERNAME", pwd: password })) quit(1);
const config = rs.conf();
if (config._id !== "$MONGODB_REPLICA_SET" || config.members.length !== 1) quit(1);
config.members[0].host = previousMember;
const result = rs.reconfig(config, { force: true });
if (result.ok !== 1) quit(1);
MONGOSH

# This script is both the final authenticated assertion and Docker health check.
# It proves the credential works and persistent topology exactly matches inputs.
cat > "$MONGODB_VERIFY_SCRIPT" <<MONGOSH
const admin = db.getSiblingDB("$MONGODB_AUTH_DATABASE");
const fs = require("fs");
const password = fs.readFileSync("/run/secrets/mongodb/root-password", "utf8");
if (!admin.auth({ user: "$MONGODB_USERNAME", pwd: password })) quit(1);
const status = rs.status();
if (status.ok !== 1 || status.set !== "$MONGODB_REPLICA_SET") quit(1);
const config = rs.conf();
if (config._id !== "$MONGODB_REPLICA_SET" ||
    config.members.length !== 1 ||
    config.members[0].host !== "$MONGODB_REPLICA_MEMBER") quit(1);
MONGOSH
chown root:root \
  "$MONGODB_INITIALIZE_SCRIPT" \
  "$MONGODB_USER_SCRIPT" \
  "$MONGODB_INSPECT_REPLICA_SCRIPT" \
  "$MONGODB_RECONCILE_REPLICA_SCRIPT" \
  "$MONGODB_RESTORE_REPLICA_SCRIPT" \
  "$MONGODB_VERIFY_SCRIPT"
chmod 0400 \
  "$MONGODB_INITIALIZE_SCRIPT" \
  "$MONGODB_USER_SCRIPT" \
  "$MONGODB_INSPECT_REPLICA_SCRIPT" \
  "$MONGODB_RECONCILE_REPLICA_SCRIPT" \
  "$MONGODB_RESTORE_REPLICA_SCRIPT" \
  "$MONGODB_VERIFY_SCRIPT"

# Hash every container-shaping input except the secret value. Labels store this
# digest so a changed bind, image, mount, replica identity, or health policy
# triggers controlled container replacement while retaining database data.
DESIRED_CONFIG_DIGEST="$(
  printf '%s\0' \
    "$MONGODB_CONFIG_VERSION" \
    "$MONGODB_IMAGE" \
    "$MONGODB_VOLUME" \
    "$VM_NAME" \
    "$PRIVATE_NETWORK_IP:$MONGODB_PORT:27017" \
    "$MONGODB_REPLICA_SET" \
    "$MONGODB_REPLICA_MEMBER" \
    "$MONGODB_USERNAME" \
    "$MONGODB_AUTH_DATABASE" \
    "$MONGODB_SECRETS_DIRECTORY:$CONTAINER_SECRETS_DIRECTORY:ro" \
    "$MONGODB_STOP_TIMEOUT_SECONDS" \
    "$MONGODB_HEALTH_INTERVAL" \
    "$MONGODB_HEALTH_TIMEOUT" \
    "$MONGODB_HEALTH_START_PERIOD" \
    "$MONGODB_HEALTH_RETRIES" | sha256sum | awk '{ print $1 }'
)"

# Inspect an existing same-named container before acting. Refuse a clearly
# unrelated container and any unexpected data volume. A managed container is
# stopped and removed only when its declared configuration no longer matches.
if docker container inspect "$MONGODB_CONTAINER" > /dev/null 2>&1; then
  CURRENT_MANAGED_LABEL="$(docker container inspect \
    --format "{{index .Config.Labels \"$MONGODB_MANAGED_LABEL\"}}" \
    "$MONGODB_CONTAINER")"
  CURRENT_CONFIG_VERSION="$(docker container inspect \
    --format "{{index .Config.Labels \"$MONGODB_CONFIG_LABEL\"}}" \
    "$MONGODB_CONTAINER")"
  CURRENT_CONFIG_DIGEST="$(docker container inspect \
    --format "{{index .Config.Labels \"$MONGODB_CONFIG_DIGEST_LABEL\"}}" \
    "$MONGODB_CONTAINER")"
  CURRENT_MONGODB_IMAGE="$(docker container inspect \
    --format '{{.Config.Image}}' "$MONGODB_CONTAINER")"
  CURRENT_MONGODB_VOLUME="$(docker container inspect \
    --format '{{range .Mounts}}{{if eq .Destination "/data/db"}}{{.Name}}{{end}}{{end}}' \
    "$MONGODB_CONTAINER")"

  if [ "$CURRENT_MANAGED_LABEL" != "true" ]; then
    echo "Container $MONGODB_CONTAINER is not managed by this template; refusing to replace it." >&2
    exit 1
  fi
  if [ "$CURRENT_MONGODB_VOLUME" != "$MONGODB_VOLUME" ]; then
    echo "Managed MongoDB uses unexpected data volume: $CURRENT_MONGODB_VOLUME" >&2
    exit 1
  fi

  if [ "$CURRENT_MONGODB_IMAGE" != "$MONGODB_IMAGE" ] || \
     [ "$CURRENT_CONFIG_VERSION" != "$MONGODB_CONFIG_VERSION" ] || \
     [ "$CURRENT_CONFIG_DIGEST" != "$DESIRED_CONFIG_DIGEST" ]; then
    MONGODB_ROLLBACK_CONTAINER="${MONGODB_CONTAINER}-vagrant-rollback"
    if docker container inspect "$MONGODB_ROLLBACK_CONTAINER" \
         > /dev/null 2>&1; then
      echo "Rollback container $MONGODB_ROLLBACK_CONTAINER already exists; inspect it before retrying." >&2
      exit 1
    fi
    if [ "$(docker container inspect --format '{{.State.Running}}' \
            "$MONGODB_CONTAINER")" = "true" ]; then
      docker container stop --timeout "$MONGODB_STOP_TIMEOUT_SECONDS" \
        "$MONGODB_CONTAINER" > /dev/null
    fi
    docker container rename "$MONGODB_CONTAINER" \
      "$MONGODB_ROLLBACK_CONTAINER"
  fi
fi

# Create the desired container when absent; otherwise restart the matching one.
# The published port is explicitly bound to Adapter 2. Secrets are read-only,
# the data volume is persistent, privilege escalation is disabled, and Docker
# restarts the service after guest reboots unless it was deliberately stopped.
if ! docker container inspect "$MONGODB_CONTAINER" > /dev/null 2>&1; then
  docker run --detach \
    --name "$MONGODB_CONTAINER" \
    --hostname "$VM_NAME" \
    --label "$MONGODB_MANAGED_LABEL=true" \
    --label "$MONGODB_CONFIG_LABEL=$MONGODB_CONFIG_VERSION" \
    --label "$MONGODB_CONFIG_DIGEST_LABEL=$DESIRED_CONFIG_DIGEST" \
    --publish "$PRIVATE_NETWORK_IP:$MONGODB_PORT:27017" \
    --restart unless-stopped \
    --stop-timeout "$MONGODB_STOP_TIMEOUT_SECONDS" \
    --init \
    --security-opt no-new-privileges=true \
    --health-cmd "mongosh --quiet --file $CONTAINER_VERIFY_SCRIPT" \
    --health-interval "$MONGODB_HEALTH_INTERVAL" \
    --health-timeout "$MONGODB_HEALTH_TIMEOUT" \
    --health-start-period "$MONGODB_HEALTH_START_PERIOD" \
    --health-retries "$MONGODB_HEALTH_RETRIES" \
    --env "MONGO_INITDB_ROOT_USERNAME=$MONGODB_USERNAME" \
    --env "MONGO_INITDB_ROOT_PASSWORD_FILE=$CONTAINER_PASSWORD_FILE" \
    --volume "$MONGODB_VOLUME:/data/db" \
    --volume "$MONGODB_SECRETS_DIRECTORY:$CONTAINER_SECRETS_DIRECTORY:ro" \
    "$MONGODB_IMAGE" \
    --replSet "$MONGODB_REPLICA_SET" \
    --bind_ip_all \
    --keyFile "$CONTAINER_KEYFILE" > /dev/null
else
  docker start "$MONGODB_CONTAINER" > /dev/null
fi

# First wait for the MongoDB process to answer a local ping. This proves startup,
# not authentication or replica-set readiness, which are checked in later stages.
MONGODB_READY=false
for _attempt in $(seq 1 "$MONGODB_READY_ATTEMPTS"); do
  if docker exec "$MONGODB_CONTAINER" mongosh --quiet \
    --eval 'quit(db.adminCommand({ ping: 1 }).ok === 1 ? 0 : 1)' \
    > /dev/null 2>&1; then
    MONGODB_READY=true
    break
  fi
  sleep "$MONGODB_RETRY_DELAY_SECONDS"
done
if [ "$MONGODB_READY" != true ]; then
  echo "MongoDB did not become ready within $((MONGODB_READY_ATTEMPTS * MONGODB_RETRY_DELAY_SECONDS)) seconds." >&2
  exit 1
fi

# Initialize the configured single-member replica set when necessary.
docker exec "$MONGODB_CONTAINER" mongosh --quiet \
  --file "$CONTAINER_SECRETS_DIRECTORY/initialize-replica-set.js"

# Inspect the data volume's persisted member address. When a VM/port rename is
# detected, record the old value before applying a one-member force reconfig so
# the EXIT handler can reverse it if a later assertion fails.
CURRENT_REPLICA_MEMBER="$(docker exec "$MONGODB_CONTAINER" mongosh --quiet \
  --file "$CONTAINER_SECRETS_DIRECTORY/inspect-replica-member.js")"
if [[ ! "$CURRENT_REPLICA_MEMBER" =~ ^[A-Za-z0-9.-]+:[1-9][0-9]*$ ]]; then
  echo "MongoDB reported an invalid persisted replica member: $CURRENT_REPLICA_MEMBER" >&2
  exit 1
fi
if [ "$CURRENT_REPLICA_MEMBER" != "$MONGODB_REPLICA_MEMBER" ]; then
  printf '%s' "$CURRENT_REPLICA_MEMBER" > "$MONGODB_PREVIOUS_REPLICA_MEMBER_FILE"
  chown root:root "$MONGODB_PREVIOUS_REPLICA_MEMBER_FILE"
  chmod 0400 "$MONGODB_PREVIOUS_REPLICA_MEMBER_FILE"
  MONGODB_REPLICA_MEMBER_MIGRATED=true
  docker exec "$MONGODB_CONTAINER" mongosh --quiet \
    --file "$CONTAINER_SECRETS_DIRECTORY/reconcile-replica-member.js"
fi

# Replica-set initialization is asynchronous. Wait for this only member to become
# writable primary before creating or checking the administrative user.
MONGODB_PRIMARY=false
for _attempt in $(seq 1 "$MONGODB_READY_ATTEMPTS"); do
  if docker exec "$MONGODB_CONTAINER" mongosh --quiet \
    --eval 'quit(db.hello().isWritablePrimary === true ? 0 : 1)' \
    > /dev/null 2>&1; then
    MONGODB_PRIMARY=true
    break
  fi
  sleep "$MONGODB_RETRY_DELAY_SECONDS"
done
if [ "$MONGODB_PRIMARY" != true ]; then
  echo "MongoDB did not elect the single replica-set member as primary." >&2
  exit 1
fi

# Reconcile the user, run an authenticated replica-set assertion immediately,
# then wait for Docker's independently scheduled health check to agree.
docker exec "$MONGODB_CONTAINER" mongosh --quiet \
  --file "$CONTAINER_SECRETS_DIRECTORY/ensure-user.js"
docker exec "$MONGODB_CONTAINER" mongosh --quiet \
  --file "$CONTAINER_SECRETS_DIRECTORY/verify.js"

MONGODB_HEALTHY=false
for _attempt in $(seq 1 "$MONGODB_HEALTH_ATTEMPTS"); do
  HEALTH_STATUS="$(docker container inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
    "$MONGODB_CONTAINER")"
  if [ "$HEALTH_STATUS" = "healthy" ]; then
    MONGODB_HEALTHY=true
    break
  fi
  if [ "$HEALTH_STATUS" = "unhealthy" ]; then
    # Elections and forced one-member reconfiguration can temporarily exhaust
    # Docker's health retries. Keep waiting within the configured outer bound;
    # the final failure path prints container health and recent server logs.
    echo "MongoDB is temporarily unhealthy; waiting for reconciliation." >&2
  fi
  sleep "$MONGODB_RETRY_DELAY_SECONDS"
done
if [ "$MONGODB_HEALTHY" != true ]; then
  echo "MongoDB did not report healthy within $((MONGODB_HEALTH_ATTEMPTS * MONGODB_RETRY_DELAY_SECONDS)) seconds." >&2
  exit 1
fi

# Finish with externally relevant invariants: exact host bind, restart policy,
# and persistent volume. These checks catch subtle Docker argument regressions.
PORT_BINDING="$(docker container port "$MONGODB_CONTAINER" 27017/tcp)"
if [ "$PORT_BINDING" != "$PRIVATE_NETWORK_IP:$MONGODB_PORT" ]; then
  echo "MongoDB has an unexpected host binding: $PORT_BINDING" >&2
  exit 1
fi
if [ "$(docker container inspect --format '{{.HostConfig.RestartPolicy.Name}}' \
        "$MONGODB_CONTAINER")" != "unless-stopped" ]; then
  echo "MongoDB has an unexpected restart policy." >&2
  exit 1
fi
if [ "$(docker container inspect \
        --format '{{range .Mounts}}{{if eq .Destination "/data/db"}}{{.Name}}{{end}}{{end}}' \
        "$MONGODB_CONTAINER")" != "$MONGODB_VOLUME" ]; then
  echo "MongoDB has an unexpected data volume." >&2
  exit 1
fi
if [ "$(docker container inspect \
        --format "{{index .Config.Labels \"$MONGODB_MANAGED_LABEL\"}}" \
        "$MONGODB_CONTAINER")" != true ] || \
   [ "$(docker volume inspect \
        --format "{{index .Labels \"$MONGODB_MANAGED_LABEL\"}}" \
        "$MONGODB_VOLUME")" != true ]; then
  echo "MongoDB container or volume lost its template ownership label." >&2
  exit 1
fi

# The candidate has passed authenticated topology, Docker health, bind, restart,
# and volume checks. Only now discard the prior container definition and the
# temporary reverse-migration input.
if [ -n "$MONGODB_ROLLBACK_CONTAINER" ]; then
  docker container rm "$MONGODB_ROLLBACK_CONTAINER" > /dev/null
  MONGODB_ROLLBACK_CONTAINER=""
fi
MONGODB_REPLICA_MEMBER_MIGRATED=false
MONGODB_SECRETS_PREEXISTED=false
rm -f "$MONGODB_PREVIOUS_REPLICA_MEMBER_FILE" || true
if [ -d "$MONGODB_SECRET_TRANSACTION_DIRECTORY" ]; then
  find "$MONGODB_SECRET_TRANSACTION_DIRECTORY" -depth -delete || true
fi
MONGODB_SECRET_TRANSACTION_DIRECTORY=""

# Do not print the password or full URI. Provide only safe connection parameters.
echo "MongoDB is available only at $PRIVATE_NETWORK_IP:$MONGODB_PORT."
echo "Use authSource=$MONGODB_AUTH_DATABASE, replicaSet=$MONGODB_REPLICA_SET, and directConnection=true."
trap - EXIT
