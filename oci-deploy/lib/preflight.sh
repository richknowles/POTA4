#!/bin/bash

################################################################################
# Pre-flight Checks Module
#
# Validates system requirements before installation
################################################################################

run_preflight_checks() {
    log_section "${GEAR} Pre-Flight System Checks ${GEAR}"

    check_os_version
    check_system_resources
    check_network_connectivity
    check_dns_resolution
    check_port_availability
    check_required_commands
    check_disk_space
    check_locale

    log_success "All pre-flight checks passed!"
}

check_os_version() {
    log_info "Checking operating system version..."

    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot determine OS version (/etc/os-release not found)"
        exit 1
    fi

    source /etc/os-release

    local os_name="${ID}"
    local os_version="${VERSION_ID}"

    log_info "Detected OS: ${NAME} ${VERSION}"

    # Supported OS versions
    case "${os_name}" in
        ubuntu)
            if [[ "${os_version}" == "22.04" ]] || [[ "${os_version}" == "20.04" ]]; then
                log_success "Ubuntu ${os_version} is supported"
            else
                log_warn "Ubuntu ${os_version} may not be fully tested"
                log_warn "Recommended versions: 22.04 LTS, 20.04 LTS"
            fi
            ;;
        debian)
            if [[ "${os_version}" == "11" ]] || [[ "${os_version}" == "10" ]]; then
                log_success "Debian ${os_version} is supported"
            else
                log_warn "Debian ${os_version} may not be fully tested"
            fi
            ;;
        ol)  # Oracle Linux
            if [[ "${os_version}" == "8" ]] || [[ "${os_version}" == "9" ]]; then
                log_success "Oracle Linux ${os_version} is supported"
            else
                log_warn "Oracle Linux ${os_version} may not be fully tested"
            fi
            ;;
        *)
            log_error "Unsupported OS: ${NAME}"
            log_error "Supported: Ubuntu 22.04/20.04, Debian 11/10, Oracle Linux 8/9"
            exit 1
            ;;
    esac
}

check_system_resources() {
    log_info "Checking system resources..."

    # Check CPU cores
    local cpu_cores=$(nproc)
    log_info "CPU cores: ${cpu_cores}"
    if [[ ${cpu_cores} -lt 2 ]]; then
        log_warn "Less than 2 CPU cores detected. Performance may be impacted."
        log_warn "Recommended: 4+ cores for production use"
    else
        log_success "CPU cores: ${cpu_cores} (adequate)"
    fi

    # Check RAM
    local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_gb=$((total_ram_kb / 1024 / 1024))
    log_info "Total RAM: ${total_ram_gb} GB"

    if [[ ${total_ram_gb} -lt 4 ]]; then
        log_error "Insufficient RAM. Minimum 4 GB required, 8 GB recommended."
        exit 1
    elif [[ ${total_ram_gb} -lt 8 ]]; then
        log_warn "RAM is below recommended amount (8 GB)"
    else
        log_success "RAM: ${total_ram_gb} GB (adequate)"
    fi
}

check_network_connectivity() {
    log_info "Checking network connectivity..."

    # Check internet connectivity
    if ping -c 1 -W 5 8.8.8.8 &> /dev/null; then
        log_success "Internet connectivity: OK"
    else
        log_error "No internet connectivity detected"
        exit 1
    fi

    # Check DNS resolution
    if ping -c 1 -W 5 google.com &> /dev/null; then
        log_success "DNS resolution: OK"
    else
        log_error "DNS resolution failed"
        exit 1
    fi
}

check_dns_resolution() {
    log_info "Checking DNS resolution for configured domains..."

    # Construct domain names
    API_DOMAIN="${API_SUBDOMAIN}.${ROOT_DOMAIN}"
    FRONTEND_DOMAIN="${FRONTEND_SUBDOMAIN}.${ROOT_DOMAIN}"
    MESH_DOMAIN="${MESH_SUBDOMAIN}.${ROOT_DOMAIN}"

    export API_DOMAIN FRONTEND_DOMAIN MESH_DOMAIN

    local domains=("${API_DOMAIN}" "${FRONTEND_DOMAIN}" "${MESH_DOMAIN}")
    local all_resolved=true

    for domain in "${domains[@]}"; do
        if host "${domain}" &> /dev/null; then
            local resolved_ip=$(host "${domain}" | grep "has address" | awk '{print $4}' | head -1)
            if [[ -n "${resolved_ip}" ]]; then
                log_success "DNS: ${domain} → ${resolved_ip}"
            else
                log_warn "DNS: ${domain} resolves but no A record found"
                all_resolved=false
            fi
        else
            log_warn "DNS: ${domain} does not resolve yet"
            log_warn "You may continue if DNS is pending propagation"
            all_resolved=false
        fi
    done

    if [[ "${all_resolved}" == "false" ]]; then
        log_warn "Some domains do not resolve yet"
        log_warn "Ensure DNS records are configured before proceeding"

        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Installation aborted by user"
            exit 1
        fi
    fi
}

check_port_availability() {
    log_info "Checking port availability..."

    local required_ports=(80 443 4222)
    local ports_in_use=()

    for port in "${required_ports[@]}"; do
        if ss -tulpn 2>/dev/null | grep -q ":${port} "; then
            ports_in_use+=("${port}")
            log_warn "Port ${port} is already in use"
        else
            log_success "Port ${port} is available"
        fi
    done

    if [[ ${#ports_in_use[@]} -gt 0 ]]; then
        log_error "The following required ports are in use: ${ports_in_use[*]}"
        log_error "Please stop services using these ports or choose different ports"
        exit 1
    fi
}

check_required_commands() {
    log_info "Checking for required system commands..."

    local required_commands=()

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        required_commands+=("docker" "docker-compose")
    fi

    required_commands+=("curl" "wget" "git" "openssl" "systemctl")

    local missing_commands=()

    for cmd in "${required_commands[@]}"; do
        if command -v "${cmd}" &> /dev/null; then
            log_success "Found: ${cmd}"
        else
            missing_commands+=("${cmd}")
            log_warn "Missing: ${cmd}"
        fi
    done

    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_warn "Missing commands: ${missing_commands[*]}"
        log_info "Installing missing dependencies..."
        install_dependencies "${missing_commands[@]}"
    fi
}

install_dependencies() {
    log_info "Installing system dependencies..."

    # Update package list
    sudo apt-get update -qq

    # Install basic dependencies
    sudo apt-get install -y \
        curl \
        wget \
        git \
        openssl \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common

    # Install Docker if needed
    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        if ! command -v docker &> /dev/null; then
            log_info "Installing Docker..."

            # Add Docker's official GPG key
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

            # Set up the repository
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
              $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

            # Install Docker Engine
            sudo apt-get update -qq
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

            # Add current user to docker group
            sudo usermod -aG docker "$USER"

            log_success "Docker installed successfully"
            log_warn "You may need to log out and back in for Docker group membership to take effect"
        fi

        # Install docker-compose (standalone) if not available as plugin
        if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
            log_info "Installing docker-compose..."
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
            log_success "docker-compose installed"
        fi
    fi

    log_success "Dependencies installed successfully"
}

check_disk_space() {
    log_info "Checking disk space..."

    local available_space_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    log_info "Available disk space: ${available_space_gb} GB"

    if [[ ${available_space_gb} -lt 20 ]]; then
        log_error "Insufficient disk space. Minimum 20 GB free required."
        log_error "Recommended: 50+ GB for production use"
        exit 1
    elif [[ ${available_space_gb} -lt 50 ]]; then
        log_warn "Disk space below recommended amount (50 GB)"
        log_warn "Current: ${available_space_gb} GB available"
    else
        log_success "Disk space: ${available_space_gb} GB (adequate)"
    fi
}

check_locale() {
    log_info "Checking system locale..."

    if [[ "$LANG" != *".UTF-8" ]]; then
        log_error "System locale must be UTF-8"
        log_error "Current locale: ${LANG}"
        log_error "Run: sudo dpkg-reconfigure locales"
        exit 1
    else
        log_success "Locale: ${LANG} (OK)"
    fi
}

check_firewall_status() {
    log_info "Checking firewall status..."

    if command -v ufw &> /dev/null; then
        local ufw_status=$(sudo ufw status | head -1)
        log_info "UFW status: ${ufw_status}"

        if [[ "${ufw_status}" == *"active"* ]]; then
            log_warn "UFW firewall is active"
            log_warn "Make sure ports 80, 443, and 4222 are allowed"
            log_info "Run: sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw allow 4222/tcp"
        fi
    fi

    if command -v firewall-cmd &> /dev/null; then
        local firewalld_status=$(sudo firewall-cmd --state 2>/dev/null || echo "not running")
        log_info "Firewalld status: ${firewalld_status}"

        if [[ "${firewalld_status}" == "running" ]]; then
            log_warn "Firewalld is active"
            log_warn "Make sure required ports are allowed"
        fi
    fi
}

verify_oci_environment() {
    log_info "Checking for OCI environment..."

    # Check if running on OCI
    if [[ -f /sys/class/dmi/id/chassis_asset_tag ]]; then
        local asset_tag=$(cat /sys/class/dmi/id/chassis_asset_tag)
        if [[ "${asset_tag}" == "OracleCloud"* ]]; then
            log_success "Running on Oracle Cloud Infrastructure"
            export IS_OCI=true

            # Get instance metadata
            if command -v curl &> /dev/null; then
                local instance_id=$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/id 2>/dev/null || echo "unknown")
                local region=$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/region 2>/dev/null || echo "unknown")

                log_info "OCI Instance ID: ${instance_id}"
                log_info "OCI Region: ${region}"
                export OCI_INSTANCE_ID="${instance_id}"
                export OCI_INSTANCE_REGION="${region}"
            fi
        fi
    else
        log_info "Not running on OCI (or cannot detect)"
        export IS_OCI=false
    fi
}
