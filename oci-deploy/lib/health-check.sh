#!/bin/bash

################################################################################
# Health Check Module
#
# Comprehensive post-installation validation
# Checks all services, connectivity, and configurations
################################################################################

run_health_checks() {
    log_section "${GEAR} Running System Health Checks ${GEAR}"

    local all_checks_passed=true

    # Run all health checks
    check_docker_containers || all_checks_passed=false
    check_network_connectivity || all_checks_passed=false
    check_ssl_certificates || all_checks_passed=false
    check_database_connectivity || all_checks_passed=false
    check_api_endpoints || all_checks_passed=false
    check_object_storage || all_checks_passed=false
    check_disk_usage || all_checks_passed=false

    # Display summary
    echo ""
    if [[ "${all_checks_passed}" == "true" ]]; then
        log_success "${CHECK} All health checks PASSED!"
    else
        log_warn "${WARN} Some health checks FAILED. Review above for details."
    fi
}

check_docker_containers() {
    log_info "Checking Docker containers..."

    if [[ "${DEPLOY_MODE}" != "docker" ]]; then
        log_info "Not using Docker deployment, skipping..."
        return 0
    fi

    local expected_containers=(
        "tactical-postgres"
        "tactical-mongodb"
        "tactical-redis"
        "tactical-nats"
        "tactical-meshcentral"
        "tactical-backend"
        "tactical-websockets"
        "tactical-celery"
        "tactical-celerybeat"
        "tactical-nginx"
    )

    local failed_containers=()

    for container in "${expected_containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local status=$(docker inspect --format='{{.State.Status}}' "${container}")
            if [[ "${status}" == "running" ]]; then
                log_success "✓ ${container}: running"
            else
                log_error "✗ ${container}: ${status}"
                failed_containers+=("${container}")
            fi
        else
            log_error "✗ ${container}: not found"
            failed_containers+=("${container}")
        fi
    done

    if [[ ${#failed_containers[@]} -eq 0 ]]; then
        log_success "All Docker containers are healthy"
        return 0
    else
        log_error "Failed containers: ${failed_containers[*]}"
        return 1
    fi
}

check_network_connectivity() {
    log_info "Checking network connectivity..."

    local domains=(
        "${API_DOMAIN}"
        "${FRONTEND_DOMAIN}"
        "${MESH_DOMAIN}"
    )

    local failed_domains=()

    for domain in "${domains[@]}"; do
        if curl -sfk "https://${domain}" -o /dev/null -w "%{http_code}" > /dev/null 2>&1; then
            log_success "✓ ${domain}: reachable"
        else
            log_warn "✗ ${domain}: not reachable (may be starting up)"
            failed_domains+=("${domain}")
        fi
    done

    if [[ ${#failed_domains[@]} -eq 0 ]]; then
        return 0
    else
        log_warn "Some domains not yet reachable: ${failed_domains[*]}"
        return 1
    fi
}

check_ssl_certificates() {
    log_info "Checking SSL certificates..."

    if [[ ! -f "${CERT_PUB_KEY}" ]] || [[ ! -f "${CERT_PRIV_KEY}" ]]; then
        log_error "SSL certificate files not found"
        log_error "  Public: ${CERT_PUB_KEY}"
        log_error "  Private: ${CERT_PRIV_KEY}"
        return 1
    fi

    # Check certificate validity
    if openssl x509 -in "${CERT_PUB_KEY}" -noout -checkend 0 > /dev/null 2>&1; then
        local expiry_date=$(openssl x509 -in "${CERT_PUB_KEY}" -noout -enddate | cut -d= -f2)
        local days_until_expiry=$(( ($(date -d "${expiry_date}" +%s) - $(date +%s)) / 86400 ))

        log_success "✓ SSL certificate valid (expires in ${days_until_expiry} days)"

        if [[ ${days_until_expiry} -lt 30 ]]; then
            log_warn "Certificate expires soon! Consider renewal."
        fi

        return 0
    else
        log_error "SSL certificate is invalid or expired"
        return 1
    fi
}

check_database_connectivity() {
    log_info "Checking database connectivity..."

    if [[ "${DEPLOY_MODE}" != "docker" ]]; then
        log_info "Not using Docker, skipping database checks..."
        return 0
    fi

    # Check PostgreSQL
    if docker exec tactical-postgres pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1; then
        log_success "✓ PostgreSQL: connected"
    else
        log_error "✗ PostgreSQL: connection failed"
        return 1
    fi

    # Check MongoDB
    if docker exec tactical-mongodb mongosh --quiet --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
        log_success "✓ MongoDB: connected"
    else
        # Try older mongo shell for MongoDB 4.x
        if docker exec tactical-mongodb mongo --quiet --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
            log_success "✓ MongoDB: connected"
        else
            log_error "✗ MongoDB: connection failed"
            return 1
        fi
    fi

    # Check Redis
    if docker exec tactical-redis redis-cli -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q "PONG"; then
        log_success "✓ Redis: connected"
    else
        log_error "✗ Redis: connection failed"
        return 1
    fi

    return 0
}

check_api_endpoints() {
    log_info "Checking API endpoints..."

    local api_url="https://${API_DOMAIN}"

    # Check if API is responding
    local http_code=$(curl -sfk "${api_url}/" -o /dev/null -w "%{http_code}")

    if [[ "${http_code}" =~ ^(200|301|302)$ ]]; then
        log_success "✓ API endpoint responding (HTTP ${http_code})"
    else
        log_error "✗ API endpoint not responding (HTTP ${http_code})"
        return 1
    fi

    # Check WebSocket endpoint
    if curl -sfk "${api_url}/ws/test" -o /dev/null 2>&1; then
        log_success "✓ WebSocket endpoint available"
    else
        log_warn "✗ WebSocket endpoint check inconclusive"
    fi

    return 0
}

check_object_storage() {
    log_info "Checking object storage connectivity..."

    if [[ "${OBJECT_STORAGE_PROVIDER}" == "none" ]]; then
        log_info "Object storage disabled, skipping..."
        return 0
    fi

    # Test connection to each bucket
    local buckets=("${BACKUP_BUCKET}")

    if [[ "${SCRIPTS_SYNC_ENABLED}" == "true" ]]; then
        buckets+=("${SCRIPTS_BUCKET}")
    fi

    if [[ "${TRANSFERS_ENABLED}" == "true" ]]; then
        buckets+=("${TRANSFERS_BUCKET}")
    fi

    for bucket in "${buckets[@]}"; do
        if rclone lsd "${RCLONE_REMOTE}:${bucket}" > /dev/null 2>&1; then
            log_success "✓ Bucket accessible: ${bucket}"
        else
            log_error "✗ Bucket not accessible: ${bucket}"
            return 1
        fi
    done

    return 0
}

check_disk_usage() {
    log_info "Checking disk usage..."

    local usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')

    if [[ ${usage} -lt 80 ]]; then
        log_success "✓ Disk usage: ${usage}% (healthy)"
    elif [[ ${usage} -lt 90 ]]; then
        log_warn "⚠ Disk usage: ${usage}% (monitor closely)"
    else
        log_error "✗ Disk usage: ${usage}% (critical!)"
        return 1
    fi

    return 0
}

check_ports() {
    log_info "Checking open ports..."

    local required_ports=(80 443 4222)

    for port in "${required_ports[@]}"; do
        if ss -tuln | grep -q ":${port} "; then
            log_success "✓ Port ${port}: listening"
        else
            log_error "✗ Port ${port}: not listening"
        fi
    done
}

check_services_health() {
    log_info "Checking service health..."

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        # Check Docker service
        if systemctl is-active --quiet docker; then
            log_success "✓ Docker service: running"
        else
            log_error "✗ Docker service: not running"
            return 1
        fi

        # Check container health
        local unhealthy=$(docker ps --filter "health=unhealthy" --format '{{.Names}}')
        if [[ -z "${unhealthy}" ]]; then
            log_success "✓ No unhealthy containers"
        else
            log_error "✗ Unhealthy containers: ${unhealthy}"
            return 1
        fi
    fi

    return 0
}

generate_health_report() {
    log_section "Generating Health Report"

    local report_file="${SCRIPT_DIR}/health-report-$(date +%Y%m%d-%H%M%S).txt"

    {
        echo "POTA4 RMM Health Report"
        echo "Generated: $(date)"
        echo "========================================"
        echo ""
        echo "System Information:"
        echo "  OS: $(lsb_release -d | cut -f2)"
        echo "  Kernel: $(uname -r)"
        echo "  Uptime: $(uptime -p)"
        echo ""
        echo "Deployment Configuration:"
        echo "  Mode: ${DEPLOY_MODE}"
        echo "  Domains:"
        echo "    - Frontend: ${FRONTEND_DOMAIN}"
        echo "    - API: ${API_DOMAIN}"
        echo "    - Mesh: ${MESH_DOMAIN}"
        echo ""
        echo "Services Status:"
        if [[ "${DEPLOY_MODE}" == "docker" ]]; then
            docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        fi
        echo ""
        echo "Disk Usage:"
        df -h /
        echo ""
        echo "Memory Usage:"
        free -h
        echo ""
        if [[ "${OBJECT_STORAGE_PROVIDER}" != "none" ]]; then
            echo "Object Storage:"
            echo "  Provider: ${OBJECT_STORAGE_PROVIDER}"
            echo "  Backup Bucket: ${BACKUP_BUCKET}"
            echo "  Scripts Bucket: ${SCRIPTS_BUCKET}"
            echo "  Transfers Bucket: ${TRANSFERS_BUCKET}"
        fi
    } > "${report_file}"

    log_success "Health report saved: ${report_file}"
    echo "${report_file}"
}
