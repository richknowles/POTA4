#!/bin/bash

################################################################################
# File Transfers Manager Module
#
# Foundation for client-side file transfers using object storage
# Provides CLI tools and Django integration preparation
################################################################################

configure_transfers() {
    log_section "Configuring File Transfers Infrastructure"

    if [[ "${TRANSFERS_ENABLED}" != "true" ]]; then
        log_warn "File transfers disabled"
        return 0
    fi

    if [[ "${OBJECT_STORAGE_PROVIDER}" == "none" ]]; then
        log_warn "Cannot enable transfers without object storage"
        return 0
    fi

    # Create local staging directory
    sudo mkdir -p /opt/pota4-transfers/{uploads,downloads,staging,temp}
    sudo chown -R "$USER:$USER" /opt/pota4-transfers

    # Setup cleanup cron for temp files
    create_transfers_cleanup_timer

    log_success "File transfers infrastructure configured"
}

create_transfers_cleanup_timer() {
    log_info "Creating transfers cleanup timer..."

    # Service to cleanup temp files
    sudo tee /etc/systemd/system/pota4-transfers-cleanup.service > /dev/null << 'EOF'
[Unit]
Description=POTA4 Transfers Cleanup
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'find /opt/pota4-transfers/temp -type f -mtime +1 -delete'
StandardOutput=journal
StandardError=journal
EOF

    # Timer to run cleanup daily
    sudo tee /etc/systemd/system/pota4-transfers-cleanup.timer > /dev/null << EOF
[Unit]
Description=POTA4 Transfers Cleanup Timer

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable pota4-transfers-cleanup.timer
    sudo systemctl start pota4-transfers-cleanup.timer

    log_success "Transfers cleanup timer created"
}

# Upload file for agent
upload_file_for_agent() {
    local agent_id="$1"
    local local_file="$2"
    local remote_name="${3:-$(basename "$local_file")}"

    if [[ ! -f "${local_file}" ]]; then
        log_error "File not found: ${local_file}"
        return 1
    fi

    log_info "Uploading file for agent ${agent_id}: ${remote_name}"

    local remote_path="tech-staging/${agent_id}/${remote_name}"
    storage_upload "${local_file}" "${remote_path}" "${TRANSFERS_BUCKET}"

    log_success "File uploaded: ${remote_name}"
    log_info "Remote path: ${remote_path}"
}

# Download file from agent
download_file_from_agent() {
    local agent_id="$1"
    local remote_name="$2"
    local local_dir="${3:-/opt/pota4-transfers/downloads}"

    mkdir -p "${local_dir}"

    local remote_path="agent-uploads/${agent_id}/${remote_name}"
    local local_file="${local_dir}/${remote_name}"

    log_info "Downloading file from agent ${agent_id}: ${remote_name}"

    storage_download "${remote_path}" "${local_file}" "${TRANSFERS_BUCKET}"

    log_success "File downloaded: ${local_file}"
    echo "${local_file}"
}

# Generate pre-signed URL for file
generate_transfer_url() {
    local agent_id="$1"
    local filename="$2"
    local direction="${3:-download}"  # upload or download
    local expiry="${4:-86400}"  # 24 hours default

    local remote_path
    if [[ "${direction}" == "upload" ]]; then
        remote_path="agent-uploads/${agent_id}/${filename}"
    else
        remote_path="tech-staging/${agent_id}/${filename}"
    fi

    log_info "Generating pre-signed URL..."
    log_info "Path: ${remote_path}"
    log_info "Expiry: ${expiry} seconds"

    local url=$(storage_presign "${remote_path}" "${TRANSFERS_BUCKET}" "${expiry}")

    if [[ -n "${url}" ]]; then
        log_success "Pre-signed URL generated"
        echo "${url}"
        return 0
    else
        log_error "Failed to generate pre-signed URL"
        return 1
    fi
}

# List files for agent
list_agent_files() {
    local agent_id="$1"
    local direction="${2:-all}"  # uploads, staging, or all

    log_info "Listing files for agent: ${agent_id}"

    if [[ "${direction}" == "uploads" ]] || [[ "${direction}" == "all" ]]; then
        echo "Agent Uploads:"
        storage_list "${TRANSFERS_BUCKET}" "agent-uploads/${agent_id}/" || echo "  None"
        echo ""
    fi

    if [[ "${direction}" == "staging" ]] || [[ "${direction}" == "all" ]]; then
        echo "Tech Staging:"
        storage_list "${TRANSFERS_BUCKET}" "tech-staging/${agent_id}/" || echo "  None"
        echo ""
    fi
}

# Delete file from transfers bucket
delete_transfer_file() {
    local remote_path="$1"

    log_info "Deleting: ${remote_path}"

    rclone delete "${RCLONE_REMOTE}:${TRANSFERS_BUCKET}/${remote_path}"

    if [[ $? -eq 0 ]]; then
        log_success "File deleted"
    else
        log_error "Failed to delete file"
        return 1
    fi
}

# Create a temporary upload link for quick support
create_quick_support_upload() {
    local session_id="$1"
    local expiry="${2:-3600}"  # 1 hour default for quick support

    local remote_path="temp/quick-support/${session_id}/upload"

    log_info "Creating quick support upload URL (session: ${session_id})"

    local url=$(storage_presign "${remote_path}" "${TRANSFERS_BUCKET}" "${expiry}")

    if [[ -n "${url}" ]]; then
        log_success "Quick support upload URL created"
        log_info "Expires in: $((expiry / 60)) minutes"
        echo "${url}"
        return 0
    else
        log_error "Failed to create upload URL"
        return 1
    fi
}

# Helper: Show transfer statistics
show_transfer_stats() {
    log_section "File Transfer Statistics"

    if [[ "${OBJECT_STORAGE_PROVIDER}" == "none" ]]; then
        log_warn "Transfers disabled"
        return 0
    fi

    echo "Transfers Bucket: ${TRANSFERS_BUCKET}"
    echo ""

    echo "Agent Uploads:"
    rclone size "${RCLONE_REMOTE}:${TRANSFERS_BUCKET}/agent-uploads" 2>/dev/null || echo "  No data"
    echo ""

    echo "Tech Staging:"
    rclone size "${RCLONE_REMOTE}:${TRANSFERS_BUCKET}/tech-staging" 2>/dev/null || echo "  No data"
    echo ""

    echo "Temporary Files:"
    rclone size "${RCLONE_REMOTE}:${TRANSFERS_BUCKET}/temp" 2>/dev/null || echo "  No data"
}
