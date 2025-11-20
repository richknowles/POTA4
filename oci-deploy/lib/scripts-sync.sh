#!/bin/bash

################################################################################
# Scripts Synchronization Module
#
# Handles bidirectional sync of scripts between:
#   - GitHub repository (upstream)
#   - Local filesystem (working copy)
#   - Object storage (backup/distribution)
################################################################################

SCRIPTS_LOCAL_DIR="/opt/trmm-community-scripts"
SCRIPTS_CUSTOM_DIR="/opt/trmm-custom-scripts"

configure_scripts_sync() {
    log_section "${PACKAGE} Configuring Scripts Synchronization ${PACKAGE}"

    if [[ "${SCRIPTS_SYNC_ENABLED}" != "true" ]]; then
        log_warn "Scripts synchronization is disabled"
        return 0
    fi

    # Create directories
    sudo mkdir -p "${SCRIPTS_LOCAL_DIR}"
    sudo mkdir -p "${SCRIPTS_CUSTOM_DIR}"
    sudo chown -R "$USER:$USER" "${SCRIPTS_LOCAL_DIR}"
    sudo chown -R "$USER:$USER" "${SCRIPTS_CUSTOM_DIR}"

    # Clone community scripts repository
    clone_community_scripts

    # Initial sync to object storage
    sync_scripts_to_storage

    # Setup automated sync
    create_scripts_sync_service
    create_scripts_sync_timer

    log_success "Scripts synchronization configured"
}

clone_community_scripts() {
    log_info "Cloning community scripts repository..."

    if [[ -d "${SCRIPTS_LOCAL_DIR}/.git" ]]; then
        log_info "Community scripts repository already exists, pulling latest..."
        cd "${SCRIPTS_LOCAL_DIR}"
        git pull origin main
    else
        log_info "Cloning community scripts repository..."
        git clone https://github.com/amidaware/community-scripts.git "${SCRIPTS_LOCAL_DIR}"
        cd "${SCRIPTS_LOCAL_DIR}"
        git config user.email "automation@pota4.local"
        git config user.name "POTA4 RMM"
    fi

    local commit_count=$(git rev-list --count HEAD)
    local latest_commit=$(git log -1 --pretty=format:"%h - %s")

    log_success "Community scripts ready (${commit_count} commits)"
    log_info "Latest: ${latest_commit}"
}

sync_scripts_to_storage() {
    if [[ "${OBJECT_STORAGE_PROVIDER}" == "none" ]]; then
        log_warn "Object storage disabled, skipping scripts backup"
        return 0
    fi

    log_info "Syncing scripts to object storage..."

    # Sync community scripts
    if [[ -d "${SCRIPTS_LOCAL_DIR}" ]]; then
        storage_sync "${SCRIPTS_LOCAL_DIR}" "community" "${SCRIPTS_BUCKET}"
        log_success "Community scripts synced to ${SCRIPTS_BUCKET}/community"
    fi

    # Sync custom scripts
    if [[ -d "${SCRIPTS_CUSTOM_DIR}" ]] && [[ -n "$(ls -A "${SCRIPTS_CUSTOM_DIR}")" ]]; then
        storage_sync "${SCRIPTS_CUSTOM_DIR}" "custom" "${SCRIPTS_BUCKET}"
        log_success "Custom scripts synced to ${SCRIPTS_BUCKET}/custom"
    else
        log_info "No custom scripts to sync"
    fi

    # Create a manifest file
    create_scripts_manifest
}

sync_scripts_from_storage() {
    if [[ "${OBJECT_STORAGE_PROVIDER}" == "none" ]]; then
        log_error "Cannot sync from storage: object storage is disabled"
        return 1
    fi

    log_info "Syncing scripts from object storage..."

    # Download community scripts
    if rclone lsd "${RCLONE_REMOTE}:${SCRIPTS_BUCKET}" | grep -q "community"; then
        rclone sync "${RCLONE_REMOTE}:${SCRIPTS_BUCKET}/community" "${SCRIPTS_LOCAL_DIR}" --progress
        log_success "Community scripts synced from storage"
    fi

    # Download custom scripts
    if rclone lsd "${RCLONE_REMOTE}:${SCRIPTS_BUCKET}" | grep -q "custom"; then
        rclone sync "${RCLONE_REMOTE}:${SCRIPTS_BUCKET}/custom" "${SCRIPTS_CUSTOM_DIR}" --progress
        log_success "Custom scripts synced from storage"
    fi
}

create_scripts_manifest() {
    log_info "Creating scripts manifest..."

    local manifest_file="${BACKUP_BASE_DIR}/temp/scripts-manifest.json"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "${manifest_file}" << EOF
{
  "generated": "${timestamp}",
  "community_scripts": {
    "path": "${SCRIPTS_LOCAL_DIR}",
    "count": $(find "${SCRIPTS_LOCAL_DIR}" -type f \( -name "*.ps1" -o -name "*.sh" -o -name "*.py" \) 2>/dev/null | wc -l),
    "git_commit": "$(cd "${SCRIPTS_LOCAL_DIR}" && git rev-parse HEAD 2>/dev/null || echo 'unknown')",
    "git_branch": "$(cd "${SCRIPTS_LOCAL_DIR}" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
  },
  "custom_scripts": {
    "path": "${SCRIPTS_CUSTOM_DIR}",
    "count": $(find "${SCRIPTS_CUSTOM_DIR}" -type f \( -name "*.ps1" -o -name "*.sh" -o -name "*.py" \) 2>/dev/null | wc -l)
  }
}
EOF

    # Upload manifest to storage
    if [[ "${OBJECT_STORAGE_PROVIDER}" != "none" ]]; then
        storage_upload "${manifest_file}" "manifest.json" "${SCRIPTS_BUCKET}"
    fi

    rm -f "${manifest_file}"
    log_success "Scripts manifest created"
}

create_scripts_sync_service() {
    log_info "Creating scripts sync systemd service..."

    sudo tee /etc/systemd/system/pota4-scripts-sync.service > /dev/null << EOF
[Unit]
Description=POTA4 RMM Scripts Synchronization
After=network-online.target

[Service]
Type=oneshot
User=${USER}
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${SCRIPT_DIR}/lib/scripts-sync.sh run_sync
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    log_success "Scripts sync service created"
}

create_scripts_sync_timer() {
    log_info "Creating scripts sync timer..."

    local on_calendar="*-*-* 03:00:00"  # Default: daily at 3 AM

    case "${SCRIPTS_SYNC_INTERVAL}" in
        hourly)
            on_calendar="*-*-* *:00:00"
            ;;
        daily)
            on_calendar="*-*-* 03:00:00"
            ;;
        weekly)
            on_calendar="Sun *-*-* 03:00:00"
            ;;
    esac

    sudo tee /etc/systemd/system/pota4-scripts-sync.timer > /dev/null << EOF
[Unit]
Description=POTA4 RMM Scripts Sync Timer
Requires=pota4-scripts-sync.service

[Timer]
OnCalendar=${on_calendar}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable pota4-scripts-sync.timer
    sudo systemctl start pota4-scripts-sync.timer

    log_success "Scripts sync timer created (${SCRIPTS_SYNC_INTERVAL})"
}

# Function called by systemd service
run_sync() {
    log_info "Running scheduled scripts sync..."

    # Pull latest from GitHub
    if [[ -d "${SCRIPTS_LOCAL_DIR}/.git" ]]; then
        cd "${SCRIPTS_LOCAL_DIR}"
        git pull origin main || log_warn "Failed to pull latest community scripts"
    fi

    # Sync to object storage
    sync_scripts_to_storage

    log_success "Scripts sync complete"
}

# Add a custom script
add_custom_script() {
    local script_file="$1"
    local script_name=$(basename "${script_file}")

    if [[ ! -f "${script_file}" ]]; then
        log_error "Script file not found: ${script_file}"
        return 1
    fi

    log_info "Adding custom script: ${script_name}"

    cp "${script_file}" "${SCRIPTS_CUSTOM_DIR}/"
    chmod +x "${SCRIPTS_CUSTOM_DIR}/${script_name}"

    # Sync to storage
    if [[ "${OBJECT_STORAGE_PROVIDER}" != "none" ]]; then
        storage_upload "${SCRIPTS_CUSTOM_DIR}/${script_name}" "custom/${script_name}" "${SCRIPTS_BUCKET}"
    fi

    log_success "Custom script added: ${script_name}"
}

# List available scripts
list_scripts() {
    log_section "Available Scripts"

    echo ""
    echo "Community Scripts:"
    find "${SCRIPTS_LOCAL_DIR}" -type f \( -name "*.ps1" -o -name "*.sh" -o -name "*.py" \) | wc -l | xargs echo "Total:"

    echo ""
    echo "Custom Scripts:"
    if [[ -d "${SCRIPTS_CUSTOM_DIR}" ]]; then
        find "${SCRIPTS_CUSTOM_DIR}" -type f \( -name "*.ps1" -o -name "*.sh" -o -name "*.py" \) | wc -l | xargs echo "Total:"
        find "${SCRIPTS_CUSTOM_DIR}" -type f \( -name "*.ps1" -o -name "*.sh" -o -name "*.py" \) -exec basename {} \;
    else
        echo "None"
    fi
}

# Export scripts to a specific location (useful for agent deployment)
export_scripts_bundle() {
    local export_dir="$1"
    local bundle_file="${export_dir}/scripts-bundle-$(date +%Y%m%d).tar.gz"

    log_info "Exporting scripts bundle..."

    mkdir -p "${export_dir}"

    tar -czf "${bundle_file}" \
        -C /opt \
        trmm-community-scripts \
        trmm-custom-scripts

    local size=$(du -h "${bundle_file}" | awk '{print $1}')
    log_success "Scripts bundle created: ${bundle_file} (${size})"

    echo "${bundle_file}"
}
