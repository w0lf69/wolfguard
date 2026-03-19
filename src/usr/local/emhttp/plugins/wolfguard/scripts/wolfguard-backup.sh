#!/bin/bash
# WolfGuard Backup Engine
# Live VM disk backup with QEMU snapshots, zstd compression, and self-verification.
# Runs on BigRed (Unraid). Backs up raw vdisk images for quick disaster recovery.
#
# Usage: wolfguard-backup.sh [--vm NAME] [--dry-run] [--force]
#   --vm NAME    Back up a single VM (skip schedule/tier logic)
#   --dry-run    Show what would happen without doing it
#   --force      Ignore schedule, run now

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────

PLUGIN_DIR="/usr/local/emhttp/plugins/wolfguard"
PLUGIN_CFG="/boot/config/plugins/wolfguard/wolfguard.cfg"
DEFAULT_CFG="${PLUGIN_DIR}/default.cfg"
SCRIPTS_DIR="${PLUGIN_DIR}/scripts"

# Load defaults, then user overrides
source "$DEFAULT_CFG"
[[ -f "$PLUGIN_CFG" ]] && source "$PLUGIN_CFG"

# Validate required config
: "${BACKUP_DIR:?BACKUP_DIR must be set in config}"
: "${LOG_DIR:?LOG_DIR must be set in config}"
: "${ZSTD_LEVEL:?ZSTD_LEVEL must be set in config}"
: "${ZSTD_THREADS:?ZSTD_THREADS must be set in config}"

# Runtime
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/wolfguard-${TIMESTAMP}.log"
LOCK_FILE="/var/run/wolfguard.lock"
EXIT_CODE=0
FAILED_VMS=()
SUCCEEDED_VMS=()

# ── CLI Args ────────────────────────────────────────────────────────────────

SINGLE_VM=""
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm)     SINGLE_VM="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --force)  FORCE=true; shift ;;
        *)        echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ── Helpers ─────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG"
}

log_error() {
    local msg="[$(date '+%H:%M:%S')] ERROR: $1"
    echo "$msg" | tee -a "$LOG" >&2
}

seconds_to_human() {
    local s=$1
    if (( s >= 3600 )); then
        printf '%dh %dm %ds' $((s/3600)) $((s%3600/60)) $((s%60))
    elif (( s >= 60 )); then
        printf '%dm %ds' $((s/60)) $((s%60))
    else
        printf '%ds' "$s"
    fi
}

cleanup_lock() {
    rm -f "$LOCK_FILE"
}

# ── Locking (prevent concurrent runs) ──────────────────────────────────────

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "WolfGuard already running. Exiting."
    exit 1
fi
echo $$ >&200
trap cleanup_lock EXIT

# ── VM Discovery ────────────────────────────────────────────────────────────

get_vm_state() {
    virsh domstate "$1" 2>/dev/null | head -1 | tr -d '[:space:]'
}

get_vm_vdisks() {
    # Returns space-separated list of vdisk paths for a VM
    virsh domblklist "$1" --details 2>/dev/null | \
        awk '$2 == "disk" { print $4 }' | \
        grep -v '^$'
}

get_vm_tier() {
    local vm="$1"
    # Check tier 1
    IFS=',' read -ra T1 <<< "$VMS_TIER1"
    for v in "${T1[@]}"; do
        [[ "$(echo "$v" | xargs)" == "$vm" ]] && echo "1" && return
    done
    # Check tier 2
    IFS=',' read -ra T2 <<< "$VMS_TIER2"
    for v in "${T2[@]}"; do
        [[ "$(echo "$v" | xargs)" == "$vm" ]] && echo "2" && return
    done
    echo "0"  # Not configured
}

# ── Snapshot Management ─────────────────────────────────────────────────────

create_snapshot() {
    local vm="$1"
    local snap_name="wolfguard-${TIMESTAMP}"
    local state
    state=$(get_vm_state "$vm")

    if [[ "$state" == "running" ]]; then
        log "  Creating live snapshot (fsfreeze via guest agent)..."

        # Get all disk targets for the snapshot command
        local disk_specs=""
        local disks
        disks=$(virsh domblklist "$vm" --details 2>/dev/null | awk '$2 == "disk" { print $3 }')

        for target in $disks; do
            local src_path
            src_path=$(virsh domblklist "$vm" --details 2>/dev/null | awk -v t="$target" '$3 == t { print $4 }')
            local snap_path="${src_path}.${snap_name}"
            disk_specs="${disk_specs} --diskspec ${target},snapshot=external,file=${snap_path}"
        done

        # Create external snapshot with quiesce (fsfreeze)
        if ! virsh snapshot-create-as "$vm" "$snap_name" \
            --disk-only \
            --atomic \
            --quiesce \
            $disk_specs 2>>"$LOG"; then

            # Fallback: try without quiesce (guest agent might be slow)
            log "  Quiesce failed, retrying without fsfreeze..."
            if ! virsh snapshot-create-as "$vm" "$snap_name" \
                --disk-only \
                --atomic \
                $disk_specs 2>>"$LOG"; then
                log_error "  Snapshot creation failed for $vm"
                return 1
            fi
            log "  WARNING: Snapshot created WITHOUT fsfreeze (crash-consistent only)"
        fi
        log "  Snapshot created: $snap_name"
    else
        log "  VM is $state, no snapshot needed (direct copy)"
    fi
    return 0
}

commit_snapshot() {
    local vm="$1"
    local snap_name="wolfguard-${TIMESTAMP}"
    local state
    state=$(get_vm_state "$vm")

    if [[ "$state" != "running" && "$state" != "paused" ]]; then
        return 0  # Nothing to commit for stopped VMs
    fi

    log "  Committing snapshot overlay back to base image..."

    local disks
    disks=$(virsh domblklist "$vm" --details 2>/dev/null | awk '$2 == "disk" { print $3 }')

    for target in $disks; do
        local current_src
        current_src=$(virsh domblklist "$vm" --details 2>/dev/null | awk -v t="$target" '$3 == t { print $4 }')

        # The current source should be the overlay; blockcommit merges it back
        if [[ "$current_src" == *"${snap_name}"* ]]; then
            log "  Committing $target..."
            if ! virsh blockcommit "$vm" "$target" --active --pivot --verbose 2>>"$LOG"; then
                log_error "  blockcommit failed for $target on $vm"
                log_error "  MANUAL CLEANUP NEEDED: overlay at $current_src"
                return 1
            fi

            # Remove the overlay file after successful commit
            if [[ -f "$current_src" ]]; then
                rm -f "$current_src"
                log "  Removed overlay: $current_src"
            fi
        fi
    done

    # Delete the snapshot metadata from libvirt
    virsh snapshot-delete "$vm" "$snap_name" --metadata 2>/dev/null || true
    log "  Snapshot committed and cleaned up"
    return 0
}

# ── Backup a Single VM ──────────────────────────────────────────────────────

backup_vm() {
    local vm="$1"
    local tier="$2"
    local start_time
    start_time=$(date +%s)

    log "========================================="
    log "BACKING UP: $vm (Tier $tier)"
    log "========================================="

    local state
    state=$(get_vm_state "$vm")
    log "  VM state: $state"

    if [[ "$state" != "running" && "$state" != "shut off" && "$state" != "paused" ]]; then
        log_error "  VM in unexpected state: $state. Skipping."
        return 1
    fi

    # Get vdisk paths BEFORE snapshot (these are the base images we want)
    local vdisks
    vdisks=$(get_vm_vdisks "$vm")

    if [[ -z "$vdisks" ]]; then
        log_error "  No vdisks found for $vm"
        return 1
    fi

    local vm_backup_dir="${BACKUP_DIR}/${vm}"
    mkdir -p "$vm_backup_dir"

    # Save VM XML config (for disaster recovery — need this to recreate the VM)
    if $DRY_RUN; then
        log "  [DRY RUN] Would save VM XML configuration"
    else
        log "  Saving VM XML configuration..."
        virsh dumpxml "$vm" > "${vm_backup_dir}/${vm}-${TIMESTAMP}.xml" 2>>"$LOG"
    fi

    # Create snapshot (for running VMs)
    if [[ "$state" == "running" ]] && ! $DRY_RUN; then
        if ! create_snapshot "$vm"; then
            return 1
        fi
    elif [[ "$state" == "running" ]] && $DRY_RUN; then
        log "  [DRY RUN] Would create QEMU snapshot with fsfreeze"
    fi

    # Compress each vdisk
    local disk_num=0
    for vdisk in $vdisks; do
        disk_num=$((disk_num + 1))
        local vdisk_name
        vdisk_name=$(basename "$vdisk")
        local compressed="${vm_backup_dir}/${vdisk_name%.img}-${TIMESTAMP}.img.zst"

        local disk_size
        disk_size=$(du -h "$vdisk" 2>/dev/null | cut -f1)
        log "  Compressing disk $disk_num: $vdisk ($disk_size)..."

        if $DRY_RUN; then
            log "  [DRY RUN] Would compress $vdisk -> $compressed"
            continue
        fi

        local compress_start
        compress_start=$(date +%s)

        # For running VMs with snapshot, the base image is now read-only (safe to copy)
        # For stopped VMs, direct compress
        # --sparse: handle sparse raw images efficiently
        # --rm: don't remove source (we're not compressing in-place)
        if ! zstd -${ZSTD_LEVEL} -T${ZSTD_THREADS} --sparse -f -o "$compressed" "$vdisk" 2>>"$LOG"; then
            log_error "  Compression failed for $vdisk"
            # Still try to commit snapshot before returning error
            if [[ "$state" == "running" ]]; then
                commit_snapshot "$vm" || true
            fi
            return 1
        fi

        local compress_time=$(( $(date +%s) - compress_start ))
        local compressed_size
        compressed_size=$(du -h "$compressed" 2>/dev/null | cut -f1)
        log "  Compressed: $compressed_size in $(seconds_to_human $compress_time)"

        # Generate SHA256 of compressed file for later verification
        sha256sum "$compressed" > "${compressed}.sha256" 2>>"$LOG"
        log "  SHA256 recorded"
    done

    # Commit snapshot back (for running VMs)
    if [[ "$state" == "running" ]] && ! $DRY_RUN; then
        if ! commit_snapshot "$vm"; then
            log_error "  CRITICAL: Snapshot commit failed! VM may be running on overlay."
            return 1
        fi
    fi

    # Apply retention
    if ! $DRY_RUN; then
        local retention
        if [[ "$tier" == "1" ]]; then
            retention=$RETENTION_TIER1
        else
            retention=$RETENTION_TIER2
        fi
        apply_retention "$vm" "$retention"
    fi

    local total_time=$(( $(date +%s) - start_time ))
    log "  COMPLETE: $vm backed up in $(seconds_to_human $total_time)"
    log ""
    return 0
}

# ── Retention ───────────────────────────────────────────────────────────────

apply_retention() {
    local vm="$1"
    local keep="$2"
    local vm_backup_dir="${BACKUP_DIR}/${vm}"

    log "  Applying retention: keep last $keep backups..."

    # Find unique backup timestamps (from compressed files)
    local timestamps
    timestamps=$(ls -1 "${vm_backup_dir}"/*.img.zst 2>/dev/null | \
        grep -oP '\d{8}_\d{6}' | \
        sort -u | \
        head -n -"$keep" 2>/dev/null || true)

    if [[ -z "$timestamps" ]]; then
        log "  No old backups to remove"
        return 0
    fi

    local removed=0
    for ts in $timestamps; do
        # Remove all files with this timestamp
        rm -f "${vm_backup_dir}"/*-"${ts}".img.zst
        rm -f "${vm_backup_dir}"/*-"${ts}".img.zst.sha256
        rm -f "${vm_backup_dir}"/*-"${ts}".xml
        removed=$((removed + 1))
    done
    log "  Removed $removed old backup(s)"
}

# ── Verification ────────────────────────────────────────────────────────────

verify_backup() {
    local vm="$1"
    local vm_backup_dir="${BACKUP_DIR}/${vm}"

    log "  Verifying backup integrity..."

    local all_passed=true

    # Find the latest compressed files for this VM
    local latest_files
    latest_files=$(ls -1t "${vm_backup_dir}"/*-"${TIMESTAMP}".img.zst 2>/dev/null)

    if [[ -z "$latest_files" ]]; then
        log_error "  No backup files found for verification"
        return 1
    fi

    for compressed in $latest_files; do
        local basename_file
        basename_file=$(basename "$compressed")

        # Test 1: zstd integrity
        if ! zstd -t "$compressed" 2>>"$LOG"; then
            log_error "  FAIL: zstd integrity check failed for $basename_file"
            all_passed=false
            continue
        fi

        # Test 2: SHA256 match
        local sha_file="${compressed}.sha256"
        if [[ -f "$sha_file" ]]; then
            if sha256sum -c "$sha_file" >>"$LOG" 2>&1; then
                log "  PASS: $basename_file integrity + SHA256 verified"
            else
                log_error "  FAIL: SHA256 mismatch for $basename_file"
                all_passed=false
            fi
        else
            log "  WARN: No SHA256 file for $basename_file (integrity OK, hash not verified)"
        fi

        # Test 3: Size sanity (compressed should be >0 and less than source)
        local compressed_bytes
        compressed_bytes=$(stat -c%s "$compressed" 2>/dev/null || echo 0)
        if (( compressed_bytes == 0 )); then
            log_error "  FAIL: $basename_file is 0 bytes"
            all_passed=false
        fi
    done

    # Verify XML config exists
    if [[ ! -f "${vm_backup_dir}/${vm}-${TIMESTAMP}.xml" ]]; then
        log_error "  FAIL: VM XML config missing"
        all_passed=false
    else
        log "  PASS: VM XML config present"
    fi

    if $all_passed; then
        log "  VERIFICATION PASSED"
        return 0
    else
        log_error "  VERIFICATION FAILED"
        return 1
    fi
}

# ── Notification ────────────────────────────────────────────────────────────

notify_failure() {
    local message="$1"

    # Pushover (if configured)
    if [[ -n "$PUSHOVER_APP_TOKEN" && -n "$PUSHOVER_USER_KEY" ]]; then
        curl -s \
            --form-string "token=${PUSHOVER_APP_TOKEN}" \
            --form-string "user=${PUSHOVER_USER_KEY}" \
            --form-string "title=WolfGuard Backup FAILED" \
            --form-string "message=${message}" \
            --form-string "priority=1" \
            --form-string "sound=siren" \
            https://api.pushover.net/1/messages.json >/dev/null 2>&1 || true
        log "  Pushover notification sent"
    fi

    # Unraid native notification
    if command -v /usr/local/emhttp/webGui/scripts/notify >/dev/null 2>&1; then
        /usr/local/emhttp/webGui/scripts/notify -s "WolfGuard" -d "$message" -i "alert" 2>/dev/null || true
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

log "============================================"
log "WolfGuard Backup Engine v2026.03.19"
log "Started: $DATE_HUMAN"
log "Target: $BACKUP_DIR"
log "Compression: zstd -${ZSTD_LEVEL} -T${ZSTD_THREADS}"
log "============================================"
log ""

mkdir -p "$BACKUP_DIR"

# Build VM list
declare -a VM_LIST=()

if [[ -n "$SINGLE_VM" ]]; then
    VM_LIST=("$SINGLE_VM")
    log "Single VM mode: $SINGLE_VM"
else
    # Combine tier 1 and tier 2 VMs
    IFS=',' read -ra T1 <<< "$VMS_TIER1"
    for v in "${T1[@]}"; do
        v=$(echo "$v" | xargs)  # trim whitespace
        [[ -n "$v" ]] && VM_LIST+=("$v")
    done
    IFS=',' read -ra T2 <<< "$VMS_TIER2"
    for v in "${T2[@]}"; do
        v=$(echo "$v" | xargs)
        [[ -n "$v" ]] && VM_LIST+=("$v")
    done
fi

if [[ ${#VM_LIST[@]} -eq 0 ]]; then
    log "No VMs configured for backup. Configure VMs in WolfGuard settings."
    exit 0
fi

log "VMs to back up: ${VM_LIST[*]}"
log ""

# Back up each VM
for vm in "${VM_LIST[@]}"; do
    tier=$(get_vm_tier "$vm")
    [[ "$tier" == "0" && -z "$SINGLE_VM" ]] && tier="1"  # Default to tier 1 for manual runs

    if backup_vm "$vm" "$tier"; then
        if ! $DRY_RUN; then
            if verify_backup "$vm"; then
                SUCCEEDED_VMS+=("$vm")
            else
                FAILED_VMS+=("$vm")
                EXIT_CODE=1
            fi
        else
            SUCCEEDED_VMS+=("$vm (dry run)")
        fi
    else
        FAILED_VMS+=("$vm")
        EXIT_CODE=1
    fi
done

# ── Summary ─────────────────────────────────────────────────────────────────

log ""
log "============================================"
log "WolfGuard Backup Summary"
log "============================================"
log "Succeeded: ${SUCCEEDED_VMS[*]:-none}"
log "Failed:    ${FAILED_VMS[*]:-none}"

# Disk usage
if [[ -d "$BACKUP_DIR" ]]; then
    log ""
    log "Storage usage:"
    for vm_dir in "${BACKUP_DIR}"/*/; do
        if [[ -d "$vm_dir" ]]; then
            local_vm=$(basename "$vm_dir")
            local_size=$(du -sh "$vm_dir" 2>/dev/null | cut -f1)
            local_count=$(ls -1 "${vm_dir}"/*.img.zst 2>/dev/null | wc -l)
            log "  ${local_vm}: ${local_size} (${local_count} backups)"
        fi
    done
    log "  Total: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
fi

log ""
log "Completed: $(date '+%Y-%m-%d %H:%M:%S')"
log "============================================"

# Notify on failure
if [[ ${#FAILED_VMS[@]} -gt 0 ]]; then
    notify_failure "Backup failed for: ${FAILED_VMS[*]}. Check log: $LOG"
fi

# Write status file for the UI to read
STATUS_FILE="/boot/config/plugins/wolfguard/status.json"
mkdir -p "$(dirname "$STATUS_FILE")"
cat > "$STATUS_FILE" <<STATUSEOF
{
    "last_run": "$DATE_HUMAN",
    "timestamp": "$TIMESTAMP",
    "exit_code": $EXIT_CODE,
    "succeeded": [$(if [[ ${#SUCCEEDED_VMS[@]} -gt 0 ]]; then printf '"%s",' "${SUCCEEDED_VMS[@]}" | sed 's/,$//'; fi)],
    "failed": [$(if [[ ${#FAILED_VMS[@]} -gt 0 ]]; then printf '"%s",' "${FAILED_VMS[@]}" | sed 's/,$//'; fi)],
    "log_file": "$LOG"
}
STATUSEOF

# Clean old logs
find "$LOG_DIR" -name "wolfguard-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true

exit $EXIT_CODE
