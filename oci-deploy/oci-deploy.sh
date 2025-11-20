#!/bin/bash

################################################################################
# POTA4 RMM - OCI Deployment Script
#
# Comprehensive one-stop deployment solution for Oracle Cloud Infrastructure
# Supports: Docker deployment, Ubuntu 22.04/20.04, Debian 11, Oracle Linux 8/9
#
# Features:
#   - Automated Let's Encrypt SSL certificates
#   - Multi-provider object storage (Wasabi, OCI, AWS S3, MinIO)
#   - Automated encrypted backups
#   - Scripts repository synchronization
#   - File transfer infrastructure
#   - Cockpit web UI integration
#   - OCI CLI integration for firewall/DNS
#   - Load balancer preparation
#   - Health checks and validation
#
# Usage:
#   ./oci-deploy.sh --init              # Generate configuration template
#   ./oci-deploy.sh --install           # Fresh installation
#   ./oci-deploy.sh --update            # Update existing installation
#   ./oci-deploy.sh --backup            # Manual backup
#   ./oci-deploy.sh --restore <file>    # Restore from backup
#   ./oci-deploy.sh --health-check      # System health validation
#
# Author: Created with Claude (Anthropic)
# Version: 1.0.0
################################################################################

set -e  # Exit on error
set -o pipefail  # Exit on pipe failure

# Script metadata
SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_LOG="${SCRIPT_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Emojis for fun (because why not?)
ROCKET="🚀"
CHECK="✅"
CROSS="❌"
WARN="⚠️"
INFO="ℹ️"
GEAR="⚙️"
PACKAGE="📦"
LOCK="🔒"
CLOUD="☁️"
HOTDOG="🌭"

################################################################################
# Logging Functions
################################################################################

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$INSTALL_LOG"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$INSTALL_LOG"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] ${CHECK}${NC} $*" | tee -a "$INSTALL_LOG"
}

log_warn() {
    echo -e "${YELLOW}[WARN] ${WARN}${NC} $*" | tee -a "$INSTALL_LOG"
}

log_error() {
    echo -e "${RED}[ERROR] ${CROSS}${NC} $*" | tee -a "$INSTALL_LOG"
}

log_section() {
    echo "" | tee -a "$INSTALL_LOG"
    echo -e "${CYAN}========================================${NC}" | tee -a "$INSTALL_LOG"
    echo -e "${CYAN}${1}${NC}" | tee -a "$INSTALL_LOG"
    echo -e "${CYAN}========================================${NC}" | tee -a "$INSTALL_LOG"
}

print_banner() {
    clear
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║   ██████╗  ██████╗ ████████╗ █████╗ ██╗  ██╗    ██████╗ ███╗   ███╗ ║
║   ██╔══██╗██╔═══██╗╚══██╔══╝██╔══██╗██║  ██║    ██╔══██╗████╗ ████║ ║
║   ██████╔╝██║   ██║   ██║   ███████║███████║    ██████╔╝██╔████╔██║ ║
║   ██╔═══╝ ██║   ██║   ██║   ██╔══██║╚════██║    ██╔══██╗██║╚██╔╝██║ ║
║   ██║     ╚██████╔╝   ██║   ██║  ██║     ██║    ██║  ██║██║ ╚═╝ ██║ ║
║   ╚═╝      ╚═════╝    ╚═╝   ╚═╝  ╚═╝     ╚═╝    ╚═╝  ╚═╝╚═╝     ╚═╝ ║
║                                                                       ║
║              OCI Deployment Script - One Stop Shop Edition           ║
║                         Version: 1.0.0                                ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝

EOF
}

print_hotdog_banner() {
    cat << "EOF"

    🌭 Deployment Complete! Time for hotdogs! 🌭

       .-"""-.
      /       \
     |  o   o  |
     |    ^    |
      \  ~~~  /
       '-...-'

    Your POTA4 RMM instance is ready to serve!

EOF
}

################################################################################
# Load Library Modules
################################################################################

source_lib() {
    local lib_file="$1"
    if [[ -f "${SCRIPT_DIR}/lib/${lib_file}" ]]; then
        source "${SCRIPT_DIR}/lib/${lib_file}"
        log_info "Loaded library: ${lib_file}"
    else
        log_error "Required library not found: ${lib_file}"
        exit 1
    fi
}

load_libraries() {
    log_section "Loading Library Modules"
    source_lib "preflight.sh"
    source_lib "storage-backend.sh"
    source_lib "backup-manager.sh"
    source_lib "scripts-sync.sh"
    source_lib "transfers-manager.sh"
    source_lib "ssl-manager.sh"
    source_lib "oci-setup.sh"
    source_lib "docker-deploy.sh"
    source_lib "cockpit-setup.sh"
    source_lib "health-check.sh"
    log_success "All libraries loaded successfully"
}

################################################################################
# Configuration Management
################################################################################

load_config() {
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        log_info "Loading configuration from .env file..."
        set -a  # Export all variables
        source "${SCRIPT_DIR}/.env"
        set +a
        log_success "Configuration loaded"
    else
        log_warn "No .env file found. Run with --init to create template."
    fi
}

validate_config() {
    log_section "Validating Configuration"

    local required_vars=(
        "ROOT_DOMAIN"
        "API_SUBDOMAIN"
        "FRONTEND_SUBDOMAIN"
        "MESH_SUBDOMAIN"
        "ADMIN_EMAIL"
        "DEPLOY_MODE"
    )

    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required configuration variables:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        log_error "Please configure .env file or run --init"
        exit 1
    fi

    log_success "Configuration validation passed"
}

generate_config_template() {
    log_section "Generating Configuration Template"

    cat > "${SCRIPT_DIR}/.env.example" << 'EOF'
################################################################################
# POTA4 RMM - OCI Deployment Configuration
################################################################################

#==============================================================================
# Domain Configuration
#==============================================================================
ROOT_DOMAIN=example.com
API_SUBDOMAIN=api
FRONTEND_SUBDOMAIN=rmm
MESH_SUBDOMAIN=mesh
ADMIN_EMAIL=admin@example.com

# Full domain names (auto-constructed, but can override)
# API_DOMAIN=${API_SUBDOMAIN}.${ROOT_DOMAIN}
# FRONTEND_DOMAIN=${FRONTEND_SUBDOMAIN}.${ROOT_DOMAIN}
# MESH_DOMAIN=${MESH_SUBDOMAIN}.${ROOT_DOMAIN}

#==============================================================================
# Deployment Mode
#==============================================================================
DEPLOY_MODE=docker  # Options: docker, baremetal

#==============================================================================
# SSL Certificate Configuration
#==============================================================================
SSL_METHOD=letsencrypt  # Options: letsencrypt, manual, selfsigned
LETSENCRYPT_CHALLENGE=dns  # Options: dns, http (dns required for wildcard)
LETSENCRYPT_DNS_PROVIDER=  # Options: cloudflare, route53, oci, etc. (for dns-01)

# If using manual certificates
SSL_CERT_PATH=
SSL_KEY_PATH=

#==============================================================================
# Object Storage Configuration
#==============================================================================
OBJECT_STORAGE_PROVIDER=wasabi  # Options: wasabi, oci, aws, minio, none

# Wasabi Configuration
WASABI_ACCESS_KEY=
WASABI_SECRET_KEY=
WASABI_REGION=us-east-1
WASABI_ENDPOINT=s3.wasabisys.com

# OCI Object Storage Configuration
OCI_NAMESPACE=
OCI_REGION=us-phoenix-1
OCI_ACCESS_KEY=
OCI_SECRET_KEY=

# AWS S3 Configuration
AWS_ACCESS_KEY=
AWS_SECRET_KEY=
AWS_REGION=us-east-1

# MinIO Configuration
MINIO_ENDPOINT=
MINIO_ACCESS_KEY=
MINIO_SECRET_KEY=
MINIO_USE_SSL=true

#==============================================================================
# Storage Buckets
#==============================================================================
BACKUP_BUCKET=pota4-backups
BACKUP_RETENTION_DAILY=7
BACKUP_RETENTION_WEEKLY=4
BACKUP_RETENTION_MONTHLY=12
BACKUP_ENCRYPTION=true
BACKUP_SCHEDULE="0 2 * * *"  # Daily at 2 AM

SCRIPTS_BUCKET=pota4-scripts
SCRIPTS_SYNC_ENABLED=true
SCRIPTS_SYNC_INTERVAL=daily  # Options: hourly, daily, weekly

TRANSFERS_BUCKET=pota4-transfers
TRANSFERS_TEMP_EXPIRY=24h
TRANSFERS_ENABLED=true

#==============================================================================
# OCI Integration
#==============================================================================
OCI_CONFIGURE_FIREWALL=true
OCI_CONFIGURE_DNS=false  # Requires OCI CLI and proper permissions
OCI_COMPARTMENT_ID=

#==============================================================================
# Optional Components
#==============================================================================
INSTALL_COCKPIT=true
COCKPIT_SUBDOMAIN=server  # Will be server.example.com
COCKPIT_PORT=9090

#==============================================================================
# Database Credentials (leave empty for auto-generation)
#==============================================================================
POSTGRES_USER=
POSTGRES_PASSWORD=
POSTGRES_DB=tacticalrmm

MONGO_INITDB_ROOT_USERNAME=
MONGO_INITDB_ROOT_PASSWORD=

REDIS_PASSWORD=

#==============================================================================
# Application Credentials (leave empty for auto-generation)
#==============================================================================
DJANGO_SECRET_KEY=
MESH_USER=
MESH_PASSWORD=
TRMM_USER=
TRMM_PASS=

#==============================================================================
# Advanced Settings
#==============================================================================
RCLONE_OPTIMIZE_MOUNT=true
RCLONE_VFS_CACHE_MODE=writes
RCLONE_BUFFER_SIZE=256M

# Timezone
TZ=America/New_York

# Logging
LOG_LEVEL=INFO  # Options: DEBUG, INFO, WARNING, ERROR

# Update channel
UPDATE_CHANNEL=stable  # Options: stable, beta, develop

EOF

    log_success "Created .env.example template"

    # Also create a Wasabi-specific example
    cat > "${SCRIPT_DIR}/.env.wasabi.example" << 'EOF'
################################################################################
# POTA4 RMM - Wasabi Configuration Example
################################################################################

# This is a pre-configured example for Wasabi object storage

ROOT_DOMAIN=yourdomain.com
API_SUBDOMAIN=api
FRONTEND_SUBDOMAIN=rmm
MESH_SUBDOMAIN=mesh
ADMIN_EMAIL=admin@yourdomain.com

DEPLOY_MODE=docker

SSL_METHOD=letsencrypt
LETSENCRYPT_CHALLENGE=dns

# Wasabi Configuration
OBJECT_STORAGE_PROVIDER=wasabi
WASABI_ACCESS_KEY=YOUR_WASABI_ACCESS_KEY_HERE
WASABI_SECRET_KEY=YOUR_WASABI_SECRET_KEY_HERE
WASABI_REGION=us-east-1  # Options: us-east-1, us-east-2, us-west-1, eu-central-1, ap-northeast-1
WASABI_ENDPOINT=s3.wasabisys.com

# Three-bucket architecture
BACKUP_BUCKET=pota4-backups
SCRIPTS_BUCKET=pota4-scripts
TRANSFERS_BUCKET=pota4-transfers

BACKUP_RETENTION_DAILY=7
BACKUP_RETENTION_WEEKLY=4
BACKUP_RETENTION_MONTHLY=12
BACKUP_ENCRYPTION=true
BACKUP_SCHEDULE="0 2 * * *"

SCRIPTS_SYNC_ENABLED=true
SCRIPTS_SYNC_INTERVAL=daily

TRANSFERS_ENABLED=true
TRANSFERS_TEMP_EXPIRY=24h

# OCI Settings
OCI_CONFIGURE_FIREWALL=true

# Optional: Cockpit
INSTALL_COCKPIT=true
COCKPIT_SUBDOMAIN=server

# Optimization
RCLONE_OPTIMIZE_MOUNT=true
RCLONE_VFS_CACHE_MODE=writes
RCLONE_BUFFER_SIZE=256M

EOF

    log_success "Created .env.wasabi.example template"

    echo ""
    log_info "Configuration templates created!"
    log_info "Next steps:"
    echo "  1. Copy .env.wasabi.example to .env"
    echo "  2. Edit .env and add your Wasabi credentials"
    echo "  3. Run: ./oci-deploy.sh --install"
    echo ""
}

################################################################################
# Main Operations
################################################################################

do_install() {
    print_banner
    log_section "${ROCKET} Starting POTA4 RMM Installation ${ROCKET}"

    # Load and validate configuration
    load_config
    validate_config

    # Pre-flight checks
    run_preflight_checks

    # OCI-specific setup
    if [[ "${OCI_CONFIGURE_FIREWALL}" == "true" ]]; then
        configure_oci_firewall
    fi

    # SSL certificate management
    setup_ssl_certificates

    # Object storage setup
    if [[ "${OBJECT_STORAGE_PROVIDER}" != "none" ]]; then
        setup_object_storage
        configure_backups
        configure_scripts_sync
        configure_transfers
    fi

    # Main application deployment
    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        deploy_docker
    else
        deploy_baremetal
    fi

    # Optional: Cockpit installation
    if [[ "${INSTALL_COCKPIT}" == "true" ]]; then
        install_cockpit
    fi

    # Post-installation health checks
    run_health_checks

    # Display completion message
    print_hotdog_banner
    display_credentials

    log_success "${CHECK} Installation completed successfully!"
    log_info "Installation log saved to: ${INSTALL_LOG}"
}

do_update() {
    log_section "${PACKAGE} Starting POTA4 RMM Update ${PACKAGE}"

    load_config

    # Backup before update
    log_info "Creating backup before update..."
    do_backup

    # Update based on deployment mode
    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        update_docker
    else
        update_baremetal
    fi

    # Run health checks
    run_health_checks

    log_success "Update completed successfully!"
}

do_backup() {
    log_section "${CLOUD} Creating Backup ${CLOUD}"

    load_config

    create_full_backup

    log_success "Backup completed successfully!"
}

do_restore() {
    local backup_file="$1"

    if [[ -z "$backup_file" ]]; then
        log_error "No backup file specified"
        echo "Usage: ./oci-deploy.sh --restore <backup-file>"
        exit 1
    fi

    log_section "Restoring from Backup"

    load_config

    restore_from_backup "$backup_file"

    log_success "Restore completed successfully!"
}

do_health_check() {
    log_section "${GEAR} Running Health Checks ${GEAR}"

    load_config
    run_health_checks

    log_success "Health check completed!"
}

display_credentials() {
    local creds_file="${SCRIPT_DIR}/credentials-$(date +%Y%m%d-%H%M%S).txt"

    cat > "$creds_file" << EOF
################################################################################
# POTA4 RMM - Installation Credentials
# Generated: $(date)
################################################################################

Web Interface: https://${FRONTEND_DOMAIN}
API Endpoint: https://${API_DOMAIN}
MeshCentral: https://${MESH_DOMAIN}

Admin Email: ${ADMIN_EMAIL}

Django Admin URL: https://${API_DOMAIN}/${DJANGO_ADMIN_URL}/
Django Username: ${TRMM_USER}
Django Password: ${TRMM_PASS}

MeshCentral Username: ${MESH_USER}
MeshCentral Password: ${MESH_PASSWORD}

Database:
  PostgreSQL User: ${POSTGRES_USER}
  PostgreSQL Password: ${POSTGRES_PASSWORD}
  PostgreSQL Database: ${POSTGRES_DB}

  MongoDB User: ${MONGO_INITDB_ROOT_USERNAME}
  MongoDB Password: ${MONGO_INITDB_ROOT_PASSWORD}

  Redis Password: ${REDIS_PASSWORD}

EOF

    if [[ "${INSTALL_COCKPIT}" == "true" ]]; then
        cat >> "$creds_file" << EOF

Cockpit Web UI: https://${COCKPIT_SUBDOMAIN}.${ROOT_DOMAIN}:${COCKPIT_PORT}
(Use your system user credentials to login)

EOF
    fi

    cat >> "$creds_file" << EOF

Object Storage:
  Provider: ${OBJECT_STORAGE_PROVIDER}
  Backup Bucket: ${BACKUP_BUCKET}
  Scripts Bucket: ${SCRIPTS_BUCKET}
  Transfers Bucket: ${TRANSFERS_BUCKET}

################################################################################
# IMPORTANT: Keep this file secure!
################################################################################

EOF

    chmod 600 "$creds_file"

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Installation Complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Web Interface: ${CYAN}https://${FRONTEND_DOMAIN}${NC}"
    echo -e "Username: ${CYAN}${TRMM_USER}${NC}"
    echo -e "Password: ${CYAN}${TRMM_PASS}${NC}"
    echo ""
    echo -e "${YELLOW}Full credentials saved to: ${creds_file}${NC}"
    echo ""
}

################################################################################
# Usage Information
################################################################################

show_usage() {
    cat << EOF

Usage: ./oci-deploy.sh [OPTION]

Options:
    --init              Generate configuration template (.env.example)
    --install           Perform fresh installation
    --update            Update existing installation
    --backup            Create manual backup
    --restore <file>    Restore from backup file
    --health-check      Run system health validation
    --help              Show this help message
    --version           Show script version

Examples:
    # First-time setup
    ./oci-deploy.sh --init
    cp .env.wasabi.example .env
    # Edit .env with your settings
    ./oci-deploy.sh --install

    # Update existing installation
    ./oci-deploy.sh --update

    # Manual backup
    ./oci-deploy.sh --backup

    # Restore from backup
    ./oci-deploy.sh --restore /path/to/backup.tar.gz

    # Health check
    ./oci-deploy.sh --health-check

For more information, see: ${SCRIPT_DIR}/docs/README.md

EOF
}

################################################################################
# Main Entry Point
################################################################################

main() {
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        log_error "Do NOT run this script as root. Please run as a regular user."
        exit 1
    fi

    # Parse command line arguments
    case "${1:-}" in
        --init)
            print_banner
            generate_config_template
            ;;
        --install)
            load_libraries
            do_install
            ;;
        --update)
            load_libraries
            do_update
            ;;
        --backup)
            load_libraries
            do_backup
            ;;
        --restore)
            load_libraries
            do_restore "$2"
            ;;
        --health-check)
            load_libraries
            do_health_check
            ;;
        --version)
            echo "POTA4 RMM OCI Deployment Script v${SCRIPT_VERSION}"
            ;;
        --help|*)
            show_usage
            ;;
    esac
}

# Run main function
main "$@"
