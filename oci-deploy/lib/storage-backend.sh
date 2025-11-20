#!/bin/bash

################################################################################
# Object Storage Backend Module
#
# Multi-provider S3-compatible storage abstraction using rclone
# Supports: Wasabi, OCI Object Storage, AWS S3, MinIO
################################################################################

setup_object_storage() {
    log_section "${CLOUD} Configuring Object Storage (${OBJECT_STORAGE_PROVIDER}) ${CLOUD}"

    install_rclone
    configure_rclone
    test_storage_connection
    create_buckets
    set_lifecycle_policies

    log_success "Object storage configured successfully"
}

install_rclone() {
    log_info "Installing rclone..."

    if command -v rclone &> /dev/null; then
        local rclone_version=$(rclone --version | head -1)
        log_info "rclone already installed: ${rclone_version}"
    else
        log_info "Downloading and installing rclone..."
        curl https://rclone.org/install.sh | sudo bash
        log_success "rclone installed successfully"
    fi

    # Install s3cmd as backup tool
    if ! command -v s3cmd &> /dev/null; then
        log_info "Installing s3cmd..."
        sudo apt-get install -y s3cmd
    fi
}

configure_rclone() {
    log_info "Configuring rclone for ${OBJECT_STORAGE_PROVIDER}..."

    local rclone_config_dir="${HOME}/.config/rclone"
    mkdir -p "${rclone_config_dir}"

    case "${OBJECT_STORAGE_PROVIDER}" in
        wasabi)
            configure_rclone_wasabi
            ;;
        oci)
            configure_rclone_oci
            ;;
        aws)
            configure_rclone_aws
            ;;
        minio)
            configure_rclone_minio
            ;;
        none)
            log_warn "Object storage disabled (OBJECT_STORAGE_PROVIDER=none)"
            return 0
            ;;
        *)
            log_error "Unknown object storage provider: ${OBJECT_STORAGE_PROVIDER}"
            exit 1
            ;;
    esac

    log_success "rclone configured for ${OBJECT_STORAGE_PROVIDER}"
}

configure_rclone_wasabi() {
    log_info "Configuring Wasabi storage..."

    # Validate required variables
    if [[ -z "${WASABI_ACCESS_KEY}" ]] || [[ -z "${WASABI_SECRET_KEY}" ]]; then
        log_error "WASABI_ACCESS_KEY and WASABI_SECRET_KEY must be set"
        exit 1
    fi

    # Determine Wasabi endpoint based on region
    local wasabi_endpoint
    case "${WASABI_REGION}" in
        us-east-1)
            wasabi_endpoint="s3.wasabisys.com"
            ;;
        us-east-2)
            wasabi_endpoint="s3.us-east-2.wasabisys.com"
            ;;
        us-west-1)
            wasabi_endpoint="s3.us-west-1.wasabisys.com"
            ;;
        eu-central-1)
            wasabi_endpoint="s3.eu-central-1.wasabisys.com"
            ;;
        ap-northeast-1)
            wasabi_endpoint="s3.ap-northeast-1.wasabisys.com"
            ;;
        *)
            wasabi_endpoint="${WASABI_ENDPOINT:-s3.wasabisys.com}"
            ;;
    esac

    # Create rclone config
    cat > "${HOME}/.config/rclone/rclone.conf" << EOF
[pota4-storage]
type = s3
provider = Wasabi
access_key_id = ${WASABI_ACCESS_KEY}
secret_access_key = ${WASABI_SECRET_KEY}
region = ${WASABI_REGION}
endpoint = https://${wasabi_endpoint}
acl = private
EOF

    # Optimization settings
    if [[ "${RCLONE_OPTIMIZE_MOUNT}" == "true" ]]; then
        cat >> "${HOME}/.config/rclone/rclone.conf" << EOF
chunk_size = 64M
upload_concurrency = 4
EOF
    fi

    export RCLONE_REMOTE="pota4-storage"
    log_success "Wasabi configuration complete"
}

configure_rclone_oci() {
    log_info "Configuring OCI Object Storage..."

    if [[ -z "${OCI_NAMESPACE}" ]] || [[ -z "${OCI_ACCESS_KEY}" ]] || [[ -z "${OCI_SECRET_KEY}" ]]; then
        log_error "OCI_NAMESPACE, OCI_ACCESS_KEY, and OCI_SECRET_KEY must be set"
        exit 1
    fi

    local oci_endpoint="${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oraclecloud.com"

    cat > "${HOME}/.config/rclone/rclone.conf" << EOF
[pota4-storage]
type = s3
provider = Other
access_key_id = ${OCI_ACCESS_KEY}
secret_access_key = ${OCI_SECRET_KEY}
region = ${OCI_REGION}
endpoint = https://${oci_endpoint}
acl = private
EOF

    if [[ "${RCLONE_OPTIMIZE_MOUNT}" == "true" ]]; then
        cat >> "${HOME}/.config/rclone/rclone.conf" << EOF
chunk_size = 64M
upload_concurrency = 4
EOF
    fi

    export RCLONE_REMOTE="pota4-storage"
    log_success "OCI Object Storage configuration complete"
}

configure_rclone_aws() {
    log_info "Configuring AWS S3..."

    if [[ -z "${AWS_ACCESS_KEY}" ]] || [[ -z "${AWS_SECRET_KEY}" ]]; then
        log_error "AWS_ACCESS_KEY and AWS_SECRET_KEY must be set"
        exit 1
    fi

    cat > "${HOME}/.config/rclone/rclone.conf" << EOF
[pota4-storage]
type = s3
provider = AWS
access_key_id = ${AWS_ACCESS_KEY}
secret_access_key = ${AWS_SECRET_KEY}
region = ${AWS_REGION}
acl = private
EOF

    if [[ "${RCLONE_OPTIMIZE_MOUNT}" == "true" ]]; then
        cat >> "${HOME}/.config/rclone/rclone.conf" << EOF
chunk_size = 64M
upload_concurrency = 4
storage_class = INTELLIGENT_TIERING
EOF
    fi

    export RCLONE_REMOTE="pota4-storage"
    log_success "AWS S3 configuration complete"
}

configure_rclone_minio() {
    log_info "Configuring MinIO..."

    if [[ -z "${MINIO_ENDPOINT}" ]] || [[ -z "${MINIO_ACCESS_KEY}" ]] || [[ -z "${MINIO_SECRET_KEY}" ]]; then
        log_error "MINIO_ENDPOINT, MINIO_ACCESS_KEY, and MINIO_SECRET_KEY must be set"
        exit 1
    fi

    local minio_protocol="http"
    if [[ "${MINIO_USE_SSL}" == "true" ]]; then
        minio_protocol="https"
    fi

    cat > "${HOME}/.config/rclone/rclone.conf" << EOF
[pota4-storage]
type = s3
provider = Minio
access_key_id = ${MINIO_ACCESS_KEY}
secret_access_key = ${MINIO_SECRET_KEY}
endpoint = ${minio_protocol}://${MINIO_ENDPOINT}
acl = private
EOF

    if [[ "${RCLONE_OPTIMIZE_MOUNT}" == "true" ]]; then
        cat >> "${HOME}/.config/rclone/rclone.conf" << EOF
chunk_size = 64M
upload_concurrency = 4
EOF
    fi

    export RCLONE_REMOTE="pota4-storage"
    log_success "MinIO configuration complete"
}

test_storage_connection() {
    log_info "Testing object storage connection..."

    if [[ "${OBJECT_STORAGE_PROVIDER}" == "none" ]]; then
        log_warn "Skipping storage connection test (provider=none)"
        return 0
    fi

    # Test connection by listing buckets
    if rclone lsd "${RCLONE_REMOTE}:" &> /dev/null; then
        log_success "Object storage connection successful"
    else
        log_error "Failed to connect to object storage"
        log_error "Please check your credentials and network connectivity"
        exit 1
    fi
}

create_buckets() {
    log_info "Creating storage buckets..."

    if [[ "${OBJECT_STORAGE_PROVIDER}" == "none" ]]; then
        return 0
    fi

    local buckets=()

    # Always create backup bucket
    buckets+=("${BACKUP_BUCKET}")

    # Create scripts bucket if enabled
    if [[ "${SCRIPTS_SYNC_ENABLED}" == "true" ]]; then
        buckets+=("${SCRIPTS_BUCKET}")
    fi

    # Create transfers bucket if enabled
    if [[ "${TRANSFERS_ENABLED}" == "true" ]]; then
        buckets+=("${TRANSFERS_BUCKET}")
    fi

    for bucket in "${buckets[@]}"; do
        if rclone lsd "${RCLONE_REMOTE}:" | grep -q "${bucket}"; then
            log_info "Bucket already exists: ${bucket}"
        else
            log_info "Creating bucket: ${bucket}"
            rclone mkdir "${RCLONE_REMOTE}:${bucket}"
            log_success "Created bucket: ${bucket}"
        fi
    done
}

set_lifecycle_policies() {
    log_info "Setting up lifecycle policies..."

    if [[ "${OBJECT_STORAGE_PROVIDER}" == "none" ]]; then
        return 0
    fi

    # Create lifecycle policy for transfers bucket (24h expiry on temp files)
    if [[ "${TRANSFERS_ENABLED}" == "true" ]]; then
        case "${OBJECT_STORAGE_PROVIDER}" in
            wasabi|aws)
                create_aws_lifecycle_policy
                ;;
            oci)
                log_warn "OCI lifecycle policies must be set via OCI Console or CLI"
                log_info "Set lifecycle rule for: ${TRANSFERS_BUCKET}/temp/* → Delete after 1 day"
                ;;
            minio)
                log_warn "MinIO lifecycle policies must be set via mc client"
                log_info "Run: mc ilm add --expiry-days 1 myminio/${TRANSFERS_BUCKET}/temp/"
                ;;
        esac
    fi
}

create_aws_lifecycle_policy() {
    log_info "Creating lifecycle policy for transfers bucket..."

    # This is a template - actual implementation depends on provider
    local policy_file="/tmp/lifecycle-policy.json"

    cat > "${policy_file}" << EOF
{
    "Rules": [{
        "Id": "Delete temp files after 24 hours",
        "Prefix": "temp/",
        "Status": "Enabled",
        "Expiration": {
            "Days": 1
        }
    }]
}
EOF

    log_info "Lifecycle policy template created: ${policy_file}"
    log_warn "Apply this policy manually via provider console/CLI"
    rm -f "${policy_file}"
}

# Helper function to upload file to object storage
storage_upload() {
    local local_file="$1"
    local remote_path="$2"
    local bucket="${3:-${BACKUP_BUCKET}}"

    if [[ ! -f "${local_file}" ]]; then
        log_error "File not found: ${local_file}"
        return 1
    fi

    log_info "Uploading: ${local_file} → ${bucket}/${remote_path}"

    if [[ "${RCLONE_OPTIMIZE_MOUNT}" == "true" ]]; then
        rclone copy "${local_file}" "${RCLONE_REMOTE}:${bucket}/${remote_path}" \
            --buffer-size="${RCLONE_BUFFER_SIZE:-256M}" \
            --s3-upload-concurrency=4 \
            --progress
    else
        rclone copy "${local_file}" "${RCLONE_REMOTE}:${bucket}/${remote_path}" \
            --progress
    fi

    if [[ $? -eq 0 ]]; then
        log_success "Upload successful"
        return 0
    else
        log_error "Upload failed"
        return 1
    fi
}

# Helper function to download file from object storage
storage_download() {
    local remote_path="$1"
    local local_file="$2"
    local bucket="${3:-${BACKUP_BUCKET}}"

    log_info "Downloading: ${bucket}/${remote_path} → ${local_file}"

    if [[ "${RCLONE_OPTIMIZE_MOUNT}" == "true" ]]; then
        rclone copy "${RCLONE_REMOTE}:${bucket}/${remote_path}" "$(dirname "${local_file}")" \
            --buffer-size="${RCLONE_BUFFER_SIZE:-256M}" \
            --progress
    else
        rclone copy "${RCLONE_REMOTE}:${bucket}/${remote_path}" "$(dirname "${local_file}")" \
            --progress
    fi

    if [[ $? -eq 0 ]]; then
        log_success "Download successful"
        return 0
    else
        log_error "Download failed"
        return 1
    fi
}

# Helper function to list files in bucket
storage_list() {
    local bucket="$1"
    local path="${2:-}"

    rclone ls "${RCLONE_REMOTE}:${bucket}/${path}"
}

# Helper function to sync directory to storage
storage_sync() {
    local local_dir="$1"
    local remote_path="$2"
    local bucket="${3:-${BACKUP_BUCKET}}"

    log_info "Syncing: ${local_dir} → ${bucket}/${remote_path}"

    if [[ "${RCLONE_OPTIMIZE_MOUNT}" == "true" ]]; then
        rclone sync "${local_dir}" "${RCLONE_REMOTE}:${bucket}/${remote_path}" \
            --buffer-size="${RCLONE_BUFFER_SIZE:-256M}" \
            --fast-list \
            --transfers=4 \
            --progress
    else
        rclone sync "${local_dir}" "${RCLONE_REMOTE}:${bucket}/${remote_path}" \
            --progress
    fi

    if [[ $? -eq 0 ]]; then
        log_success "Sync successful"
        return 0
    else
        log_error "Sync failed"
        return 1
    fi
}

# Helper function to generate pre-signed URL (requires s3cmd or aws cli)
storage_presign() {
    local remote_path="$1"
    local bucket="$2"
    local expiry_seconds="${3:-86400}"  # Default 24 hours

    log_info "Generating pre-signed URL for: ${bucket}/${remote_path}"

    case "${OBJECT_STORAGE_PROVIDER}" in
        wasabi|aws)
            if command -v aws &> /dev/null; then
                local url=$(aws s3 presign "s3://${bucket}/${remote_path}" --expires-in "${expiry_seconds}" 2>/dev/null)
                if [[ -n "${url}" ]]; then
                    echo "${url}"
                    return 0
                fi
            fi

            if command -v s3cmd &> /dev/null; then
                local url=$(s3cmd signurl "s3://${bucket}/${remote_path}" "+${expiry_seconds}" 2>/dev/null | grep -o 'http.*')
                if [[ -n "${url}" ]]; then
                    echo "${url}"
                    return 0
                fi
            fi
            ;;
        oci)
            log_warn "Pre-signed URLs for OCI require oci CLI"
            log_info "Use: oci os preauth-request create --bucket-name ${bucket} --object-name ${remote_path}"
            return 1
            ;;
        minio)
            log_warn "Pre-signed URLs for MinIO require mc client"
            log_info "Use: mc share download myminio/${bucket}/${remote_path}"
            return 1
            ;;
    esac

    log_error "Unable to generate pre-signed URL"
    log_error "Install aws-cli or s3cmd for this feature"
    return 1
}

# Helper function to delete old backups based on retention policy
storage_cleanup_old_backups() {
    local bucket="${BACKUP_BUCKET}"

    log_info "Cleaning up old backups per retention policy..."

    # Delete daily backups older than retention period
    local daily_cutoff_date=$(date -d "${BACKUP_RETENTION_DAILY} days ago" +%Y-%m-%d)
    log_info "Deleting daily backups older than ${daily_cutoff_date}..."

    rclone delete "${RCLONE_REMOTE}:${bucket}/daily" \
        --min-age "${BACKUP_RETENTION_DAILY}d" \
        --verbose

    # Weekly backups
    local weekly_cutoff_date=$(date -d "$((BACKUP_RETENTION_WEEKLY * 7)) days ago" +%Y-%m-%d)
    log_info "Deleting weekly backups older than ${weekly_cutoff_date}..."

    rclone delete "${RCLONE_REMOTE}:${bucket}/weekly" \
        --min-age "$((BACKUP_RETENTION_WEEKLY * 7))d" \
        --verbose

    # Monthly backups
    local monthly_cutoff_date=$(date -d "$((BACKUP_RETENTION_MONTHLY * 30)) days ago" +%Y-%m-%d)
    log_info "Deleting monthly backups older than ${monthly_cutoff_date}..."

    rclone delete "${RCLONE_REMOTE}:${bucket}/monthly" \
        --min-age "$((BACKUP_RETENTION_MONTHLY * 30))d" \
        --verbose

    log_success "Backup cleanup complete"
}

# Display storage statistics
show_storage_stats() {
    log_section "Object Storage Statistics"

    if [[ "${OBJECT_STORAGE_PROVIDER}" == "none" ]]; then
        log_warn "Object storage is disabled"
        return 0
    fi

    for bucket in "${BACKUP_BUCKET}" "${SCRIPTS_BUCKET}" "${TRANSFERS_BUCKET}"; do
        if rclone lsd "${RCLONE_REMOTE}:" | grep -q "${bucket}"; then
            log_info "Bucket: ${bucket}"
            rclone size "${RCLONE_REMOTE}:${bucket}" | grep "Total"
            echo ""
        fi
    done
}
