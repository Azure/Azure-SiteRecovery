#!/bin/bash

###############################################################################
# trigger_resync.sh
#
# Purpose: Triggers a resync on the source machine by stopping filtering on
#          all protected disks. When filtering is stopped and the agent is
#          restarted, the replication pipeline initiates a resync.
#
# Prerequisites:
#   - Agent version must be 7759 or higher (otherwise upgrade first)
#   - Driver must not be a faulty version (otherwise reboot first)
#
# Usage:   sudo bash trigger_resync.sh
#
# Notes:
#   - Must be run as root
#   - This will cause a full resync of all protected disks
#   - The agent service will be restarted automatically
#   - Logs are appended to svagents_curr log in agent format
###############################################################################

VX_VERSION_FILE="/usr/local/.vx_version"
MIN_AGENT_BUILD=7759

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

if [ ! -f "$VX_VERSION_FILE" ]; then
    echo "ERROR: $VX_VERSION_FILE not found. ASR Mobility Agent does not appear to be installed."
    exit 1
fi

INSTALL_DIR=$(grep ^INSTALLATION_DIR $VX_VERSION_FILE | cut -d"=" -f2 | tr -d " ")
if [ -z "$INSTALL_DIR" ]; then
    echo "ERROR: INSTALLATION_DIR not found in $VX_VERSION_FILE."
    exit 1
fi

INM_DMIT="${INSTALL_DIR}/bin/inm_dmit"
if [ ! -x "$INM_DMIT" ]; then
    echo "ERROR: inm_dmit binary not found or not executable at ${INM_DMIT}."
    exit 1
fi

# --- Pre-check 1: Agent version must be >= 7759 ---
AGENT_VERSION=$(grep ^VERSION= $VX_VERSION_FILE | cut -d"=" -f2 | tr -d " ")
AGENT_BUILD=$(echo "$AGENT_VERSION" | cut -d"." -f4)
if [ -z "$AGENT_BUILD" ] || [ "$AGENT_BUILD" -lt "$MIN_AGENT_BUILD" ]; then
    echo "ERROR: Agent version is $AGENT_VERSION (build $AGENT_BUILD)."
    echo "Minimum required build is $MIN_AGENT_BUILD."
    echo "Please upgrade the Mobility Agent to version 9.67.0.$MIN_AGENT_BUILD or higher before running this script."
    exit 1
fi
echo "Agent version check passed: $AGENT_VERSION (build $AGENT_BUILD)"

# --- Pre-check 2: Driver must not be faulty (9.66.1.7691-7749) ---
DRIVER_VERSION=$(${INM_DMIT} --op=get_driver_version 2>/dev/null | grep "Product Version" | sed 's/[^0-9,]//g' | tr -d ' ')
if [ -n "$DRIVER_VERSION" ]; then
    DRV_MAJOR=$(echo "$DRIVER_VERSION" | cut -d',' -f1)
    DRV_MINOR=$(echo "$DRIVER_VERSION" | cut -d',' -f2)
    DRV_PATCH=$(echo "$DRIVER_VERSION" | cut -d',' -f3)
    DRV_BUILD=$(echo "$DRIVER_VERSION" | cut -d',' -f4)

    if [ "$DRV_MAJOR" = "9" ] && [ "$DRV_MINOR" = "66" ] && [ "$DRV_PATCH" = "1" ]; then
        if [ "$DRV_BUILD" -ge 7691 ] && [ "$DRV_BUILD" -lt 7750 ]; then
            echo "ERROR: Faulty driver detected (version: $DRV_MAJOR.$DRV_MINOR.$DRV_PATCH.$DRV_BUILD)."
            echo "Please reboot the machine and run this script again."
            exit 1
        fi
    fi
    echo "Driver version check passed: $DRV_MAJOR.$DRV_MINOR.$DRV_PATCH.$DRV_BUILD"
else
    echo "WARNING: Could not determine driver version. Proceeding anyway."
fi

# --- Both checks passed, proceed with resync ---
echo "All pre-checks passed. Triggering resync..."

# Step 1: Stop the agent service (no logging before this)
${INSTALL_DIR}/bin/stop 2>&1
stop_ret=$?
if [ "$stop_ret" -ne 0 ]; then
    echo "ERROR: Failed to stop agent service. Return value: $stop_ret"
    exit 1
fi

# Now that service is stopped, read the last sequence number from svagents log
SVAGENTS_LOG=$(ls -t /var/log/svagents_curr_*.log 2>/dev/null | head -1)
TEMP_LOG="/tmp/trigger_resync_$$.log"
PID=$$
TID=$(cat /proc/self/stat | awk '{print $1}')
SEQ_NUM=$(awk '{print $7}' "$SVAGENTS_LOG" | grep -E '^[0-9]+$' | tail -1)
SEQ_NUM=${SEQ_NUM:-0}

# Log in svagents format to temp file:
# #~> (MM-DD-YYYY HH:MM:SS):  LEVEL  PID TID SEQNUM Message
log_message()
{
    local LEVEL="$1"
    shift
    local MESSAGE="$*"
    SEQ_NUM=$((SEQ_NUM + 1))
    local DATE_TIME=$(date '+%m-%d-%Y %H:%M:%S')
    local LOG_ENTRY="#~> (${DATE_TIME}):  ${LEVEL}  ${PID} ${TID} ${SEQ_NUM} ${MESSAGE}"
    echo "$LOG_ENTRY" >> "${TEMP_LOG}"
    echo "$LOG_ENTRY"
}

log_message "ALWAYS" "trigger_resync.sh: Agent service stopped successfully."
log_message "ALWAYS" "trigger_resync.sh: Agent version: $AGENT_VERSION, Driver version: $DRV_MAJOR.$DRV_MINOR.$DRV_PATCH.$DRV_BUILD"

# Step 2: Stop filtering on all protected disks (this causes resync)
log_message "ALWAYS" "trigger_resync.sh: Stopping filtering on all protected disks..."
${INM_DMIT} --op=stop_flt_all >> ${TEMP_LOG} 2>&1
stop_flt_ret=$?
if [ "$stop_flt_ret" -ne 0 ]; then
    log_message " ERROR" "trigger_resync.sh: inm_dmit --op=stop_flt_all failed. Return value: $stop_flt_ret"
    log_message "ALWAYS" "trigger_resync.sh: Attempting to start agent service anyway..."
fi

if [ "$stop_flt_ret" -eq 0 ]; then
    log_message "ALWAYS" "trigger_resync.sh: Filtering stopped on all disks."
fi

# Step 3: Verify and cleanup /etc/vxagent/involflt (preserve common/)
INVOLFLT_DIR="/etc/vxagent/involflt"
if [ -d "$INVOLFLT_DIR" ]; then
    remaining_dirs=$(find "$INVOLFLT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name "common" 2>/dev/null)
    if [ -n "$remaining_dirs" ]; then
        log_message "ALWAYS" "trigger_resync.sh: Found remaining directories under $INVOLFLT_DIR after stop_flt_all:"
        echo "$remaining_dirs" | while IFS= read -r dir; do
            [ -z "$dir" ] && continue
            log_message "ALWAYS" "trigger_resync.sh: Cleaning up: $dir"
            rm -rf "$dir"
        done
        log_message "ALWAYS" "trigger_resync.sh: Cleanup complete. All disks will resync on next start."
    else
        log_message "ALWAYS" "trigger_resync.sh: No remaining directories under $INVOLFLT_DIR (excluding common/). All clean."
    fi
else
    log_message "ALWAYS" "trigger_resync.sh: $INVOLFLT_DIR not found. Skipping cleanup."
fi

# Step 4: Log protection status for all disks
log_message "ALWAYS" "trigger_resync.sh: Querying protected volume list status..."
${INM_DMIT} --get_protected_volume_list >> ${TEMP_LOG} 2>&1
log_message "ALWAYS" "trigger_resync.sh: Protection status logged. All disks should resync on next start."

# Step 5: Append temp log to svagents_curr before starting service
cat "${TEMP_LOG}" >> "${SVAGENTS_LOG}"
rm -f "${TEMP_LOG}"

# Step 6: Start the agent service (resync begins automatically)
${INSTALL_DIR}/bin/start

exit 0
