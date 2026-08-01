#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: make the guest root filesystem consume capacity added to the virtual
# disk by Parallels. Runs as root after the provider changes hdd0.
# Supported layout: one partition-backed LVM physical volume in the root volume
# group with an ext4 or XFS root. The script grows partition -> PV -> LV ->
# filesystem and never shrinks. Free extents that predate a disk expansion are
# preserved rather than assigning the entire VG to root.
# Repeat behavior: a small transaction file records the pre-resize free extent
# count, allowing a run interrupted after pvresize or lvextend to resume safely.

echo "\n\n###\n### Grow the root filesystem when the virtual disk expanded\n###\n"

# Fail with a direct message instead of producing a confusing error halfway
# through a storage mutation.
for COMMAND in findmnt lsblk lvs pvs vgs growpart pvresize lvextend; do
  if ! command -v "$COMMAND" > /dev/null 2>&1; then
    echo "Required disk-growth command is missing: $COMMAND" >&2
    exit 1
  fi
done

# Resolve the mounted root device and prove it is an LVM logical volume before
# modifying any partition table or volume metadata.
ROOT_SOURCE="$(findmnt --noheadings --output SOURCE /)"
if [ -z "$ROOT_SOURCE" ] || ! lvs "$ROOT_SOURCE" > /dev/null 2>&1; then
  echo "Root filesystem is not on an LVM logical volume: $ROOT_SOURCE" >&2
  exit 1
fi

# Growing the filesystem is kept separate from lvextend so a later run can
# finish this step if an earlier run stopped after changing the LV metadata.
ROOT_FILESYSTEM="$(findmnt --noheadings --output FSTYPE / | xargs)"
case "$ROOT_FILESYSTEM" in
  ext4)
    FILESYSTEM_GROW_COMMAND=(resize2fs "$ROOT_SOURCE")
    ;;
  xfs)
    FILESYSTEM_GROW_COMMAND=(xfs_growfs /)
    ;;
  *)
    echo "Unsupported root filesystem for automatic growth: $ROOT_FILESYSTEM" >&2
    exit 1
    ;;
esac
if ! command -v "${FILESYSTEM_GROW_COMMAND[0]}" > /dev/null 2>&1; then
  echo "Required filesystem-growth command is missing: ${FILESYSTEM_GROW_COMMAND[0]}" >&2
  exit 1
fi

# The expected Bento layout has exactly one PV in the root volume group. Refuse
# multi-disk or otherwise unfamiliar layouts rather than selecting one by guess.
VG_NAME="$(lvs --noheadings --options vg_name "$ROOT_SOURCE" | xargs)"
mapfile -t PV_DEVICES < <(
  pvs --noheadings --options pv_name --select "vg_name=$VG_NAME" | xargs --no-run-if-empty -n1
)
if [ "${#PV_DEVICES[@]}" -ne 1 ]; then
  echo "Expected one physical volume for root VG $VG_NAME, found ${#PV_DEVICES[@]}." >&2
  printf 'Physical volume: %s\n' "${PV_DEVICES[@]}" >&2
  exit 1
fi

# Discover the parent block device and partition number from the PV itself, so
# the script does not hard-code names such as /dev/sda or /dev/nvme0n1.
PV_DEVICE="${PV_DEVICES[0]}"
PARTITION_NUMBER="$(lsblk --nodeps --noheadings --output PARTN "$PV_DEVICE" | xargs)"
PARENT_DEVICE_NAME="$(lsblk --nodeps --noheadings --output PKNAME "$PV_DEVICE" | xargs)"
if [ -z "$PARTITION_NUMBER" ] || [ -z "$PARENT_DEVICE_NAME" ]; then
  echo "Cannot resolve the parent disk and partition for $PV_DEVICE." >&2
  exit 1
fi
PARENT_DEVICE="/dev/$PARENT_DEVICE_NAME"
if [ ! -b "$PV_DEVICE" ] || [ ! -b "$PARENT_DEVICE" ]; then
  echo "Resolved disk devices are invalid: $PARENT_DEVICE $PV_DEVICE" >&2
  exit 1
fi

# Save the free-space target before changing the partition table. Some LVM and
# kernel combinations notice a new partition boundary before pvresize runs, so
# a later checkpoint could mistake newly exposed capacity for intentional free
# space. If a previous run left this state file behind, resume toward its saved
# target instead of taking a new snapshot from partially modified storage.
STATE_DIRECTORY="/var/lib/vagrant/storage"
STATE_FILE="$STATE_DIRECTORY/root-vg-growth"
VG_UUID="$(vgs --noheadings --options vg_uuid "$VG_NAME" | xargs)"
CURRENT_FREE_EXTENTS="$(vgs --noheadings --options vg_free_count "$VG_NAME" | xargs)"
if [[ ! "$CURRENT_FREE_EXTENTS" =~ ^[0-9]+$ ]] || [ -z "$VG_UUID" ]; then
  echo "Cannot determine a reliable UUID/free-extent count for VG $VG_NAME." >&2
  exit 1
fi

install -d -m 0700 "$STATE_DIRECTORY"
if [ -e "$STATE_FILE" ]; then
  if ! read -r SAVED_VG_UUID RESERVED_FREE_EXTENTS EXTRA_STATE < "$STATE_FILE"; then
    echo "Disk-growth state is empty or unreadable: $STATE_FILE" >&2
    exit 1
  fi
  if [ -n "${EXTRA_STATE:-}" ] || [ "$SAVED_VG_UUID" != "$VG_UUID" ] || \
     [[ ! "$RESERVED_FREE_EXTENTS" =~ ^[0-9]+$ ]]; then
    echo "Disk-growth state does not match root VG $VG_NAME; refusing mutation." >&2
    exit 1
  fi
else
  RESERVED_FREE_EXTENTS="$CURRENT_FREE_EXTENTS"
  STATE_TEMP="$(mktemp "$STATE_DIRECTORY/.root-vg-growth.XXXXXX")"
  trap 'rm -f "$STATE_TEMP"' EXIT
  printf '%s %s\n' "$VG_UUID" "$RESERVED_FREE_EXTENTS" > "$STATE_TEMP"
  chmod 0600 "$STATE_TEMP"
  mv "$STATE_TEMP" "$STATE_FILE"
  trap - EXIT
fi

# growpart returns a non-zero status for some harmless NOCHANGE results. Preserve
# real errors while allowing repeat provisioning of an already-grown partition.
GROWPART_STATUS=0
GROWPART_OUTPUT="$(growpart "$PARENT_DEVICE" "$PARTITION_NUMBER" 2>&1)" || GROWPART_STATUS=$?
printf '%s\n' "$GROWPART_OUTPUT"
if [ "$GROWPART_STATUS" -ne 0 ] && [[ "$GROWPART_OUTPUT" != *NOCHANGE* ]]; then
  exit "$GROWPART_STATUS"
fi

# Extend LVM metadata to the new partition boundary, then assign only newly
# available extents to root. This keeps the recorded VG reserve unchanged.
pvresize "$PV_DEVICE"

FREE_EXTENTS="$(vgs --noheadings --options vg_free_count "$VG_NAME" | xargs)"
if [[ ! "$FREE_EXTENTS" =~ ^[0-9]+$ ]]; then
  echo "Cannot determine free extents after resizing $PV_DEVICE." >&2
  exit 1
fi
if [ "$FREE_EXTENTS" -lt "$RESERVED_FREE_EXTENTS" ]; then
  echo "VG free space fell below the saved reserve; refusing to consume more." >&2
  echo "Saved: $RESERVED_FREE_EXTENTS extents; current: $FREE_EXTENTS extents." >&2
  exit 1
fi

NEW_EXTENTS=$((FREE_EXTENTS - RESERVED_FREE_EXTENTS))
if [ "$NEW_EXTENTS" -gt 0 ]; then
  lvextend --extents "+$NEW_EXTENTS" "$ROOT_SOURCE"
else
  echo "Root logical volume already has all newly added extents."
fi

# Both commands are safe when the filesystem already fills the LV. Running this
# on every reconciliation repairs an interruption between LV and filesystem
# growth without extending the LV a second time.
"${FILESYSTEM_GROW_COMMAND[@]}"

FINAL_FREE_EXTENTS="$(vgs --noheadings --options vg_free_count "$VG_NAME" | xargs)"
if [ "$FINAL_FREE_EXTENTS" != "$RESERVED_FREE_EXTENTS" ]; then
  echo "VG reserve reconciliation failed: expected $RESERVED_FREE_EXTENTS, found $FINAL_FREE_EXTENTS." >&2
  exit 1
fi
rm -f "$STATE_FILE"

echo "Root storage is reconciled; preserved $RESERVED_FREE_EXTENTS free VG extents."
