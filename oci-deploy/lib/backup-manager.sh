#!/bin/bash

################################################################################
# Backup Manager Module
#
# Handles automated encrypted backups to object storage
# Supports PostgreSQL, MongoDB, configuration files, and certificates
################################################################################

BACKUP_BASE_DIR="/opt/pota4-backups"
BACKUP_ENCRYPTION_KEY_FILE="${BACKUP_BASE_DIR}/.backup-encryption-key"

configure_backups() {
    log_section "${LOCK} Configuring Automated Backups ${LOCK}"

    # Create backup directories
    sudo mkdir -p "${BACKUP_BASE_DIR}"/{daily,weekly,monthly,temp}
    sudo chown -R "$USER:$USER" "${BACKUP_BASE_DIR}"

    # Generate encryption key if it doesn't exist
    if [[ "${BACKUP_ENCRYPTION}" == "true" ]]; then
        generate_backup_encryption_key
    fi

    # Setup backup systemd service and timer
    create_backup_service
    create_backup_timer

    # Enable and start timer
    sudo systemctl daemon-reload
    sudo systemctl enable pota4-backup.timer
    sudo systemctl start pota4-backup.timer

    log_success "Automated backups configured"
    log_info "Backup schedule: ${BACKUP_SCHEDULE}"
    log_info "Next backup: $(systemctl list-timers pota4-backup.timer | grep pota4-backup | awk '{print $1, $2}')"
}

generate_backup_encryption_key() {
    if [[ ! -f "${BACKUP_ENCRYPTION_KEY_FILE}" ]]; then
        log_info "Generating backup encryption key..."
        openssl rand -base64 32 > "${BACKUP_ENCRYPTION_KEY_FILE}"
        chmod 600 "${BACKUP_ENCRYPTION_KEY_FILE}"
        log_success "Backup encryption key generated"
        log_warn "IMPORTANT: Backup encryption key stored at: ${BACKUP_ENCRYPTION_KEY_FILE}"
        log_warn "Keep this key secure! You'll need it to restore backups."
    else
        log_info "Backup encryption key already exists"
    fi
}

create_backup_service() {
    log_info "Creating backup systemd service..."

    sudo tee /etc/systemd/system/pota4-backup.service > /dev/null << EOF
[Unit]
Description=POTA4 RMM Automated Backup
After=network-online.target

[Service]
Type=oneshot
User=${USER}
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${SCRIPT_DIR}/oci-deploy.sh --backup
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    log_success "Backup service created"
}

create_backup_timer() {
    log_info "Creating backup systemd timer..."

    # Parse cron schedule to systemd timer format
    # Default: "0 2 * * *" (daily at 2 AM)
    local on_calendar="*-*-* 02:00:00"  # Default

    # Simple parser for common cron formats
    if [[ "${BACKUP_SCHEDULE}" =~ ^0[[:space:]]([0-9]+)[[:space:]]\*[[:space:]]\*[[:space:]]\*$ ]]; then
        local hour="${BASH_REMATCH[1]}"
        on_calendar="*-*-* ${hour}:00:00"
    fi

    sudo tee /etc/systemd/system/pota4-backup.timer > /dev/null << EOF
[Unit]
Description=POTA4 RMM Backup Timer
Requires=pota4-backup.service

[Timer]
OnCalendar=${on_calendar}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

    log_success "Backup timer created (schedule: ${on_calendar})"
}

create_full_backup() {
    log_section "${CLOUD} Creating Full Backup ${CLOUD}"

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_date=$(date +%Y-%m-%d)
    local day_of_week=$(date +%u)  # 1-7 (Monday-Sunday)
    local day_of_month=$(date +%d)

    # Determine backup type (daily/weekly/monthly)
    local backup_type="daily"
    if [[ "${day_of_month}" == "01" ]]; then
        backup_type="monthly"
    elif [[ "${day_of_week}" == "7" ]]; then  # Sunday
        backup_type="weekly"
    fi

    local backup_dir="${BACKUP_BASE_DIR}/temp/backup-${timestamp}"
    mkdir -p "${backup_dir}"

    log_info "Backup type: ${backup_type}"
    log_info "Backup directory: ${backup_dir}"

    # Backup PostgreSQL
    backup_postgres "${backup_dir}"

    # Backup MongoDB
    backup_mongodb "${backup_dir}"

    # Backup Redis (if applicable)
    backup_redis "${backup_dir}"

    # Backup configuration files
    backup_configs "${backup_dir}"

    # Backup SSL certificates
    backup_certificates "${backup_dir}"

    # Create tarball
    local backup_tarball="${BACKUP_BASE_DIR}/${backup_type}/backup-${backup_date}.tar.gz"
    log_info "Creating backup archive..."
    tar -czf "${backup_tarball}" -C "$(dirname "${backup_dir}")" "$(basename "${backup_dir}")"

    # Encrypt if enabled
    if [[ "${BACKUP_ENCRYPTION}" == "true" ]]; then
        log_info "Encrypting backup..."
        openssl enc -aes-256-cbc -salt -pbkdf2 \
            -in "${backup_tarball}" \
            -out "${backup_tarball}.enc" \
            -pass file:"${BACKUP_ENCRYPTION_KEY_FILE}"

        rm -f "${backup_tarball}"
        backup_tarball="${backup_tarball}.enc"
        log_success "Backup encrypted"
    fi

    # Upload to object storage
    if [[ "${OBJECT_STORAGE_PROVIDER}" != "none" ]]; then
        log_info "Uploading backup to object storage..."
        storage_upload "${backup_tarball}" "${backup_type}/$(basename "${backup_tarball}")" "${BACKUP_BUCKET}"

        # Cleanup old backups
        storage_cleanup_old_backups
    fi

    # Cleanup temp directory
    rm -rf "${backup_dir}"

    log_success "Backup completed: ${backup_tarball}"
}

backup_postgres() {
    local backup_dir="$1"

    log_info "Backing up PostgreSQL database..."

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        # Docker deployment
        docker exec tactical-postgres pg_dumpall -U "${POSTGRES_USER:-tactical}" | gzip > "${backup_dir}/postgres-dump.sql.gz"
    else
        # Bare metal deployment
        sudo -u postgres pg_dumpall | gzip > "${backup_dir}/postgres-dump.sql.gz"
    fi

    if [[ -f "${backup_dir}/postgres-dump.sql.gz" ]]; then
        local size=$(du -h "${backup_dir}/postgres-dump.sql.gz" | awk '{print $1}')
        log_success "PostgreSQL backup complete (${size})"
    else
        log_error "PostgreSQL backup failed!"
        return 1
    fi
}

backup_mongodb() {
    local backup_dir="$1"

    log_info "Backing up MongoDB database..."

    local mongo_backup_dir="${backup_dir}/mongodb"
    mkdir -p "${mongo_backup_dir}"

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        # Docker deployment
        docker exec tactical-mongodb mongodump --out /tmp/mongodb-backup
        docker cp tactical-mongodb:/tmp/mongodb-backup "${mongo_backup_dir}/"
        docker exec tactical-mongodb rm -rf /tmp/mongodb-backup
    else
        # Bare metal deployment
        mongodump --out "${mongo_backup_dir}"
    fi

    # Compress MongoDB backup
    if [[ -d "${mongo_backup_dir}" ]]; then
        tar -czf "${backup_dir}/mongodb-dump.tar.gz" -C "${mongo_backup_dir}" .
        rm -rf "${mongo_backup_dir}"

        local size=$(du -h "${backup_dir}/mongodb-dump.tar.gz" | awk '{print $1}')
        log_success "MongoDB backup complete (${size})"
    else
        log_warn "MongoDB backup directory not found, skipping..."
    fi
}

backup_redis() {
    local backup_dir="$1"

    log_info "Backing up Redis data..."

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        # Docker deployment - copy RDB file
        if docker exec tactical-redis test -f /data/dump.rdb; then
            docker cp tactical-redis:/data/dump.rdb "${backup_dir}/redis-dump.rdb"
            gzip "${backup_dir}/redis-dump.rdb"
            log_success "Redis backup complete"
        else
            log_warn "Redis dump file not found, skipping..."
        fi
    else
        # Bare metal deployment
        if [[ -f /var/lib/redis/dump.rdb ]]; then
            cp /var/lib/redis/dump.rdb "${backup_dir}/redis-dump.rdb"
            gzip "${backup_dir}/redis-dump.rdb"
            log_success "Redis backup complete"
        else
            log_warn "Redis dump file not found, skipping..."
        fi
    fi
}

backup_configs() {
    local backup_dir="$1"

    log_info "Backing up configuration files..."

    local config_backup_dir="${backup_dir}/configs"
    mkdir -p "${config_backup_dir}"

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        # Backup docker-compose.yml and .env
        if [[ -f "${SCRIPT_DIR}/../docker/docker-compose.yml" ]]; then
            cp "${SCRIPT_DIR}/../docker/docker-compose.yml" "${config_backup_dir}/"
        fi
        if [[ -f "${SCRIPT_DIR}/../docker/.env" ]]; then
            cp "${SCRIPT_DIR}/../docker/.env" "${config_backup_dir}/"
        fi
    else
        # Backup nginx configs
        if [[ -d /etc/nginx/sites-available ]]; then
            cp -r /etc/nginx/sites-available "${config_backup_dir}/nginx-sites"
        fi

        # Backup systemd services
        mkdir -p "${config_backup_dir}/systemd"
        for service in rmm daphne celery celerybeat nats nats-api meshcentral; do
            if [[ -f "/etc/systemd/system/${service}.service" ]]; then
                cp "/etc/systemd/system/${service}.service" "${config_backup_dir}/systemd/"
            fi
        done

        # Backup Django local_settings.py
        if [[ -f /rmm/api/tacticalrmm/tacticalrmm/local_settings.py ]]; then
            cp /rmm/api/tacticalrmm/tacticalrmm/local_settings.py "${config_backup_dir}/"
        fi

        # Backup MeshCentral config
        if [[ -f /meshcentral/meshcentral-data/config.json ]]; then
            cp /meshcentral/meshcentral-data/config.json "${config_backup_dir}/"
        fi
    fi

    # Backup deployment script configuration
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        cp "${SCRIPT_DIR}/.env" "${config_backup_dir}/oci-deploy.env"
    fi

    tar -czf "${backup_dir}/configs.tar.gz" -C "${config_backup_dir}" .
    rm -rf "${config_backup_dir}"

    log_success "Configuration backup complete"
}

backup_certificates() {
    local backup_dir="$1"

    log_info "Backing up SSL certificates..."

    local cert_backup_dir="${backup_dir}/certificates"
    mkdir -p "${cert_backup_dir}"

    # Backup Let's Encrypt certificates
    if [[ -d /etc/letsencrypt ]]; then
        sudo tar -czf "${cert_backup_dir}/letsencrypt.tar.gz" -C /etc letsencrypt
        sudo chown "$USER:$USER" "${cert_backup_dir}/letsencrypt.tar.gz"
    fi

    # Backup manual certificates if they exist
    if [[ -n "${SSL_CERT_PATH}" ]] && [[ -f "${SSL_CERT_PATH}" ]]; then
        cp "${SSL_CERT_PATH}" "${cert_backup_dir}/"
        cp "${SSL_KEY_PATH}" "${cert_backup_dir}/"
    fi

    if [[ -d "${cert_backup_dir}" ]]; then
        tar -czf "${backup_dir}/certificates.tar.gz" -C "${cert_backup_dir}" .
        rm -rf "${cert_backup_dir}"
        log_success "Certificate backup complete"
    fi
}

restore_from_backup() {
    local backup_file="$1"

    log_section "Restoring from Backup"

    # Check if backup file exists locally
    if [[ ! -f "${backup_file}" ]]; then
        # Try to download from object storage
        log_info "Backup file not found locally, checking object storage..."

        if [[ "${OBJECT_STORAGE_PROVIDER}" != "none" ]]; then
            local remote_file=$(basename "${backup_file}")
            log_info "Downloading from object storage: ${remote_file}"

            storage_download "${remote_file}" "${BACKUP_BASE_DIR}/temp/${remote_file}" "${BACKUP_BUCKET}"
            backup_file="${BACKUP_BASE_DIR}/temp/${remote_file}"
        else
            log_error "Backup file not found and object storage is disabled"
            exit 1
        fi
    fi

    # Decrypt if encrypted
    if [[ "${backup_file}" == *.enc ]]; then
        log_info "Decrypting backup..."

        if [[ ! -f "${BACKUP_ENCRYPTION_KEY_FILE}" ]]; then
            log_error "Backup encryption key not found: ${BACKUP_ENCRYPTION_KEY_FILE}"
            log_error "Cannot decrypt backup without encryption key!"
            exit 1
        fi

        local decrypted_file="${backup_file%.enc}"
        openssl enc -aes-256-cbc -d -pbkdf2 \
            -in "${backup_file}" \
            -out "${decrypted_file}" \
            -pass file:"${BACKUP_ENCRYPTION_KEY_FILE}"

        backup_file="${decrypted_file}"
        log_success "Backup decrypted"
    fi

    # Extract backup
    local restore_dir="${BACKUP_BASE_DIR}/temp/restore-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${restore_dir}"

    log_info "Extracting backup..."
    tar -xzf "${backup_file}" -C "${restore_dir}"

    # Find the backup directory (it's nested one level)
    local backup_data_dir=$(find "${restore_dir}" -type d -name "backup-*" | head -1)

    if [[ -z "${backup_data_dir}" ]]; then
        log_error "Invalid backup structure"
        exit 1
    fi

    # Restore PostgreSQL
    if [[ -f "${backup_data_dir}/postgres-dump.sql.gz" ]]; then
        restore_postgres "${backup_data_dir}/postgres-dump.sql.gz"
    fi

    # Restore MongoDB
    if [[ -f "${backup_data_dir}/mongodb-dump.tar.gz" ]]; then
        restore_mongodb "${backup_data_dir}/mongodb-dump.tar.gz"
    fi

    # Restore Redis
    if [[ -f "${backup_data_dir}/redis-dump.rdb.gz" ]]; then
        restore_redis "${backup_data_dir}/redis-dump.rdb.gz"
    fi

    # Restore configurations
    if [[ -f "${backup_data_dir}/configs.tar.gz" ]]; then
        log_warn "Configuration files found in backup"
        log_warn "Manual review recommended before restoring configs"
        log_info "Extract configs: tar -xzf ${backup_data_dir}/configs.tar.gz"
    fi

    # Restore certificates
    if [[ -f "${backup_data_dir}/certificates.tar.gz" ]]; then
        restore_certificates "${backup_data_dir}/certificates.tar.gz"
    fi

    # Cleanup
    rm -rf "${restore_dir}"

    log_success "Restore completed successfully!"
    log_warn "Please restart all services for changes to take effect"
}

restore_postgres() {
    local dump_file="$1"

    log_info "Restoring PostgreSQL database..."

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        gunzip -c "${dump_file}" | docker exec -i tactical-postgres psql -U "${POSTGRES_USER:-tactical}"
    else
        gunzip -c "${dump_file}" | sudo -u postgres psql
    fi

    log_success "PostgreSQL restore complete"
}

restore_mongodb() {
    local dump_file="$1"

    log_info "Restoring MongoDB database..."

    local temp_mongo_dir="${BACKUP_BASE_DIR}/temp/mongodb-restore"
    mkdir -p "${temp_mongo_dir}"
    tar -xzf "${dump_file}" -C "${temp_mongo_dir}"

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        docker cp "${temp_mongo_dir}" tactical-mongodb:/tmp/mongodb-restore
        docker exec tactical-mongodb mongorestore /tmp/mongodb-restore
        docker exec tactical-mongodb rm -rf /tmp/mongodb-restore
    else
        mongorestore "${temp_mongo_dir}"
    fi

    rm -rf "${temp_mongo_dir}"
    log_success "MongoDB restore complete"
}

restore_redis() {
    local dump_file="$1"

    log_info "Restoring Redis data..."

    gunzip -c "${dump_file}" > "${BACKUP_BASE_DIR}/temp/dump.rdb"

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        docker stop tactical-redis
        docker cp "${BACKUP_BASE_DIR}/temp/dump.rdb" tactical-redis:/data/dump.rdb
        docker start tactical-redis
    else
        sudo systemctl stop redis-server
        sudo cp "${BACKUP_BASE_DIR}/temp/dump.rdb" /var/lib/redis/dump.rdb
        sudo chown redis:redis /var/lib/redis/dump.rdb
        sudo systemctl start redis-server
    fi

    rm -f "${BACKUP_BASE_DIR}/temp/dump.rdb"
    log_success "Redis restore complete"
}

restore_certificates() {
    local cert_file="$1"

    log_info "Restoring SSL certificates..."

    local temp_cert_dir="${BACKUP_BASE_DIR}/temp/certificates"
    mkdir -p "${temp_cert_dir}"
    tar -xzf "${cert_file}" -C "${temp_cert_dir}"

    if [[ -f "${temp_cert_dir}/letsencrypt.tar.gz" ]]; then
        sudo tar -xzf "${temp_cert_dir}/letsencrypt.tar.gz" -C /etc/
        log_success "Let's Encrypt certificates restored"
    fi

    rm -rf "${temp_cert_dir}"
}

list_backups() {
    log_section "Available Backups"

    if [[ "${OBJECT_STORAGE_PROVIDER}" != "none" ]]; then
        log_info "Backups in object storage (${BACKUP_BUCKET}):"
        echo ""

        echo "Daily backups:"
        storage_list "${BACKUP_BUCKET}" "daily" | head -10

        echo ""
        echo "Weekly backups:"
        storage_list "${BACKUP_BUCKET}" "weekly" | head -10

        echo ""
        echo "Monthly backups:"
        storage_list "${BACKUP_BUCKET}" "monthly" | head -10
    fi

    log_info "Local backups:"
    ls -lh "${BACKUP_BASE_DIR}"/{daily,weekly,monthly}/*.tar.gz 2>/dev/null || log_warn "No local backups found"
}
