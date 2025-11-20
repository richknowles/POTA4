#!/bin/bash

################################################################################
# Cockpit Setup Module
#
# Installs and configures Cockpit web-based server management UI
# Integrates with Docker for container management
################################################################################

install_cockpit() {
    log_section "Installing Cockpit Web UI"

    if [[ "${INSTALL_COCKPIT}" != "true" ]]; then
        log_warn "Cockpit installation disabled"
        return 0
    fi

    # Install Cockpit
    install_cockpit_package

    # Install Docker plugin
    install_cockpit_docker_plugin

    # Configure Cockpit
    configure_cockpit

    # Configure firewall
    configure_cockpit_firewall

    log_success "Cockpit installed and configured"
    log_info "Access Cockpit at: https://${COCKPIT_SUBDOMAIN}.${ROOT_DOMAIN}:${COCKPIT_PORT}"
    log_info "Login with your system user credentials"
}

install_cockpit_package() {
    log_info "Installing Cockpit..."

    # Update package list
    sudo apt-get update -qq

    # Install Cockpit and common modules
    sudo apt-get install -y \
        cockpit \
        cockpit-machines \
        cockpit-packagekit \
        cockpit-networkmanager \
        cockpit-storaged \
        cockpit-system

    log_success "Cockpit installed"
}

install_cockpit_docker_plugin() {
    log_info "Installing Cockpit Docker plugin..."

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        sudo apt-get install -y cockpit-docker || {
            log_warn "cockpit-docker not available, trying cockpit-podman..."
            sudo apt-get install -y cockpit-podman || {
                log_warn "No Docker plugin available for Cockpit"
            }
        }
    fi
}

configure_cockpit() {
    log_info "Configuring Cockpit..."

    # Create Cockpit configuration directory
    sudo mkdir -p /etc/cockpit

    # Configure Cockpit to allow password authentication
    sudo tee /etc/cockpit/cockpit.conf > /dev/null << EOF
[WebService]
AllowUnencrypted = false
UrlRoot = /
LoginTitle = POTA4 RMM Server Management

[Session]
IdleTimeout = 15

[Log]
Fatal = default
EOF

    # Enable and start Cockpit
    sudo systemctl enable cockpit.socket
    sudo systemctl start cockpit.socket

    # Check status
    if systemctl is-active --quiet cockpit.socket; then
        log_success "Cockpit is running"
    else
        log_error "Cockpit failed to start"
        return 1
    fi
}

configure_cockpit_firewall() {
    log_info "Configuring firewall for Cockpit..."

    # Allow Cockpit port in iptables (for OCI)
    if [[ "${IS_OCI}" == "true" ]]; then
        sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport "${COCKPIT_PORT}" -j ACCEPT

        if command -v netfilter-persistent &> /dev/null; then
            sudo netfilter-persistent save
        fi
    fi

    # Allow in UFW if present
    if command -v ufw &> /dev/null; then
        sudo ufw allow "${COCKPIT_PORT}/tcp" comment "Cockpit"
    fi

    log_success "Firewall configured for Cockpit"
}

create_cockpit_admin_user() {
    local admin_user="${1:-pota4admin}"

    log_info "Creating Cockpit admin user: ${admin_user}"

    # Create user if doesn't exist
    if ! id "${admin_user}" &>/dev/null; then
        sudo useradd -m -s /bin/bash "${admin_user}"
        sudo usermod -aG sudo "${admin_user}"

        # Set random password
        local admin_pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1)
        echo "${admin_user}:${admin_pass}" | sudo chpasswd

        log_success "Admin user created: ${admin_user}"
        log_warn "Password: ${admin_pass}"
        log_warn "SAVE THIS PASSWORD! It will not be shown again."

        # Save to credentials file
        echo "" >> "${SCRIPT_DIR}/cockpit-credentials.txt"
        echo "Cockpit Admin User: ${admin_user}" >> "${SCRIPT_DIR}/cockpit-credentials.txt"
        echo "Cockpit Admin Password: ${admin_pass}" >> "${SCRIPT_DIR}/cockpit-credentials.txt"
        chmod 600 "${SCRIPT_DIR}/cockpit-credentials.txt"
    else
        log_info "User ${admin_user} already exists"
    fi
}

customize_cockpit_interface() {
    log_info "Customizing Cockpit interface..."

    # Create custom branding (optional)
    sudo mkdir -p /usr/share/cockpit/branding/pota4

    sudo tee /usr/share/cockpit/branding/pota4/branding.css > /dev/null << 'EOF'
/* POTA4 RMM Custom Branding */
#index-brand {
    content: url('data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="200" height="40"><text x="10" y="30" font-size="24" fill="%23fff">POTA4 RMM</text></svg>');
}

#index-brand img {
    display: none;
}
EOF

    log_success "Cockpit interface customized"
}

display_cockpit_info() {
    log_section "Cockpit Access Information"

    cat << EOF

${GREEN}Cockpit Web UI is ready!${NC}

Access URL: ${CYAN}https://${COCKPIT_SUBDOMAIN}.${ROOT_DOMAIN}:${COCKPIT_PORT}${NC}

${YELLOW}Login Credentials:${NC}
  - Use your SSH/system user credentials
  - Or use the cockpit admin user if created

${YELLOW}Features Available:${NC}
  ✓ Server monitoring (CPU, RAM, Disk, Network)
  ✓ Docker container management
  ✓ Service management (start/stop/restart)
  ✓ Log viewing
  ✓ Terminal access
  ✓ File manager
  ✓ Network configuration
  ✓ Storage management

${YELLOW}POTA4 Container Management:${NC}
  Navigate to: Podman/Docker → View all containers
  Quick actions: Start, Stop, Restart, View logs

${YELLOW}Security Note:${NC}
  - Cockpit uses system authentication
  - HTTPS is enforced (uses self-signed cert by default)
  - Consider adding your SSL cert for production use
  - Restrict access via firewall to admin IPs only

EOF
}
