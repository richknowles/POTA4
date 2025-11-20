#!/bin/bash

################################################################################
# OCI Setup Module
#
# OCI-specific configuration and integration
# Handles firewall rules, DNS, and OCI CLI operations
################################################################################

configure_oci_firewall() {
    log_section "Configuring OCI Firewall Rules"

    if [[ "${IS_OCI}" != "true" ]]; then
        log_warn "Not running on OCI, skipping OCI-specific configuration"
        return 0
    fi

    # Configure iptables rules (required on OCI even with Security Lists)
    configure_iptables

    # Display Security List instructions
    display_security_list_instructions

    # Optionally configure via OCI CLI
    if [[ "${OCI_CONFIGURE_DNS}" == "true" ]]; then
        configure_oci_cli
    fi

    log_success "OCI firewall configuration complete"
}

configure_iptables() {
    log_info "Configuring iptables rules for OCI..."

    # OCI instances require iptables rules in addition to Security Lists

    # Allow HTTP (80)
    sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT

    # Allow HTTPS (443)
    sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT

    # Allow NATS (4222)
    sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 4222 -j ACCEPT

    # Allow Cockpit if enabled
    if [[ "${INSTALL_COCKPIT}" == "true" ]]; then
        sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport "${COCKPIT_PORT}" -j ACCEPT
    fi

    # Save iptables rules
    if command -v netfilter-persistent &> /dev/null; then
        sudo netfilter-persistent save
    elif command -v iptables-save &> /dev/null; then
        sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null
    fi

    log_success "iptables rules configured"
}

display_security_list_instructions() {
    log_section "OCI Security List Configuration Required"

    cat << EOF

${YELLOW}IMPORTANT: Configure OCI Security Lists${NC}

You must add the following Ingress Rules to your VCN's Security List:

┌──────────┬──────────────┬─────────────┬───────────────────┐
│ Protocol │ Source CIDR  │ Destination │ Description       │
├──────────┼──────────────┼─────────────┼───────────────────┤
│ TCP      │ 0.0.0.0/0    │ 80          │ HTTP             │
│ TCP      │ 0.0.0.0/0    │ 443         │ HTTPS            │
│ TCP      │ 0.0.0.0/0    │ 4222        │ NATS (Agents)    │
EOF

    if [[ "${INSTALL_COCKPIT}" == "true" ]]; then
        echo "│ TCP      │ YOUR_IP/32   │ ${COCKPIT_PORT}         │ Cockpit (Admin)  │"
    fi

    cat << EOF
└──────────┴──────────────┴─────────────┴───────────────────┘

${CYAN}How to add these rules:${NC}

1. Go to: OCI Console → Networking → Virtual Cloud Networks
2. Select your VCN → Security Lists → Default Security List
3. Click "Add Ingress Rules"
4. Add each rule listed above

${YELLOW}Note: Cockpit port should be restricted to your admin IP for security${NC}

EOF

    read -p "Press Enter when Security List rules have been added..."
}

configure_oci_cli() {
    log_info "Configuring OCI CLI..."

    # Check if OCI CLI is installed
    if ! command -v oci &> /dev/null; then
        log_info "Installing OCI CLI..."
        bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
        export PATH=$PATH:$HOME/bin
    fi

    # Check if OCI CLI is configured
    if [[ ! -f ~/.oci/config ]]; then
        log_warn "OCI CLI not configured"
        log_info "Run: oci setup config"
        log_info "You'll need: User OCID, Tenancy OCID, Region, and API key"
    else
        log_success "OCI CLI configured"

        # Test OCI CLI
        if oci iam region list &> /dev/null; then
            log_success "OCI CLI connection successful"
        else
            log_warn "OCI CLI connection test failed"
        fi
    fi
}

# Helper: Get OCI instance metadata
get_oci_metadata() {
    local metadata_endpoint="http://169.254.169.254/opc/v2/instance/"

    log_info "Fetching OCI instance metadata..."

    local instance_id=$(curl -sf -H "Authorization: Bearer Oracle" "${metadata_endpoint}id" || echo "unknown")
    local region=$(curl -sf -H "Authorization: Bearer Oracle" "${metadata_endpoint}region" || echo "unknown")
    local shape=$(curl -sf -H "Authorization: Bearer Oracle" "${metadata_endpoint}shape" || echo "unknown")
    local availability_domain=$(curl -sf -H "Authorization: Bearer Oracle" "${metadata_endpoint}availabilityDomain" || echo "unknown")

    export OCI_INSTANCE_ID="${instance_id}"
    export OCI_INSTANCE_REGION="${region}"
    export OCI_INSTANCE_SHAPE="${shape}"
    export OCI_AVAILABILITY_DOMAIN="${availability_domain}"

    log_info "Instance ID: ${instance_id}"
    log_info "Region: ${region}"
    log_info "Shape: ${shape}"
    log_info "Availability Domain: ${availability_domain}"
}

# Helper: Configure OCI block volume for backups (optional)
setup_oci_block_volume() {
    local volume_mount_point="/mnt/pota4-backups"

    log_info "Setting up OCI block volume for backups..."

    # This is a placeholder - actual implementation requires OCI CLI
    log_warn "Block volume setup requires manual configuration"
    log_info "Steps:"
    log_info "1. Create Block Volume in OCI Console"
    log_info "2. Attach volume to this instance"
    log_info "3. Run: sudo fdisk -l (to find device, e.g., /dev/sdb)"
    log_info "4. Run: sudo mkfs.ext4 /dev/sdb"
    log_info "5. Run: sudo mkdir -p ${volume_mount_point}"
    log_info "6. Run: sudo mount /dev/sdb ${volume_mount_point}"
    log_info "7. Add to /etc/fstab for persistence"
}

# Helper: Configure OCI Load Balancer (future HA setup)
display_load_balancer_instructions() {
    log_section "OCI Load Balancer Setup (Optional - For HA)"

    cat << EOF

${CYAN}Setting up OCI Load Balancer for High Availability:${NC}

1. Create OCI Load Balancer:
   - Type: Network Load Balancer
   - Visibility: Public
   - Backend Set: POTA4-Backend

2. Configure Backend Servers:
   - Add this instance: ${OCI_INSTANCE_ID:-current instance}
   - Health Check: HTTPS on port 443, path /
   - Port: 443 (HTTPS), 4222 (NATS)

3. Configure Listeners:
   - HTTPS Listener: Port 443 → Backend Set
   - NATS Listener: Port 4222 → Backend Set

4. Update DNS:
   - Point A records to Load Balancer IP instead of instance IP

5. SSL Termination:
   - Option A: Terminate SSL at Load Balancer (upload certs)
   - Option B: Pass-through to backend (current setup)

${YELLOW}Note: Load balancer setup is for future horizontal scaling${NC}
${YELLOW}Current single-server setup does not require this${NC}

EOF
}

# Helper: Optimize for OCI network performance
optimize_oci_network() {
    log_info "Optimizing network settings for OCI..."

    # Increase network buffer sizes (OCI has high-throughput network)
    sudo tee -a /etc/sysctl.conf > /dev/null << 'EOF'

# OCI Network Optimizations
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 5000
EOF

    sudo sysctl -p

    log_success "Network optimizations applied"
}
