#!/bin/bash

################################################################################
# SSL Certificate Manager Module
#
# Handles SSL certificate provisioning via:
#   - Let's Encrypt (DNS-01 challenge for wildcard)
#   - Let's Encrypt (HTTP-01 challenge for individual certs)
#   - Manual certificate import
#   - Self-signed certificates (development only)
################################################################################

setup_ssl_certificates() {
    log_section "${LOCK} Configuring SSL Certificates ${LOCK}"

    case "${SSL_METHOD}" in
        letsencrypt)
            setup_letsencrypt
            ;;
        manual)
            setup_manual_certificates
            ;;
        selfsigned)
            log_warn "Self-signed certificates are for development only!"
            setup_selfsigned_certificates
            ;;
        *)
            log_error "Unknown SSL method: ${SSL_METHOD}"
            exit 1
            ;;
    esac

    log_success "SSL certificates configured"
}

setup_letsencrypt() {
    log_info "Setting up Let's Encrypt certificates..."

    # Install certbot
    install_certbot

    case "${LETSENCRYPT_CHALLENGE}" in
        dns)
            obtain_wildcard_certificate
            ;;
        http)
            obtain_http_certificates
            ;;
        *)
            log_error "Unknown Let's Encrypt challenge: ${LETSENCRYPT_CHALLENGE}"
            exit 1
            ;;
    esac

    # Setup auto-renewal
    setup_certificate_renewal

    # Export certificate paths
    export_certificate_paths
}

install_certbot() {
    log_info "Installing certbot..."

    if command -v certbot &> /dev/null; then
        log_info "certbot already installed"
        return 0
    fi

    # Install certbot via snap (recommended method)
    if command -v snap &> /dev/null; then
        sudo snap install --classic certbot
        sudo ln -sf /snap/bin/certbot /usr/bin/certbot
    else
        # Fallback to apt
        sudo apt-get update
        sudo apt-get install -y certbot
    fi

    log_success "certbot installed"
}

obtain_wildcard_certificate() {
    log_info "Obtaining wildcard certificate for *.${ROOT_DOMAIN}..."

    # DNS-01 challenge requires manual intervention or DNS provider plugin
    log_warn "DNS-01 challenge requires manual DNS record creation"

    echo ""
    echo "=========================================="
    echo "Let's Encrypt Wildcard Certificate Setup"
    echo "=========================================="
    echo ""
    echo "Domain: *.${ROOT_DOMAIN}"
    echo "Challenge: DNS-01"
    echo ""
    echo "You will be prompted to create a TXT record in your DNS."
    echo "Do NOT press Enter until the record has propagated!"
    echo ""
    read -p "Press Enter to continue..."

    sudo certbot certonly \
        --manual \
        --preferred-challenges dns \
        --agree-tos \
        --no-eff-email \
        --email "${ADMIN_EMAIL}" \
        -d "*.${ROOT_DOMAIN}" \
        -d "${ROOT_DOMAIN}"

    if [[ $? -eq 0 ]]; then
        log_success "Wildcard certificate obtained successfully"
    else
        log_error "Failed to obtain wildcard certificate"
        log_error "Please check DNS propagation and try again"
        exit 1
    fi
}

obtain_http_certificates() {
    log_info "Obtaining individual certificates via HTTP-01 challenge..."

    # Temporarily stop any web server
    if systemctl is-active --quiet nginx; then
        sudo systemctl stop nginx
    fi

    # Obtain certificates for each subdomain
    local domains=(
        "${API_DOMAIN}"
        "${FRONTEND_DOMAIN}"
        "${MESH_DOMAIN}"
    )

    if [[ "${INSTALL_COCKPIT}" == "true" ]]; then
        domains+=("${COCKPIT_SUBDOMAIN}.${ROOT_DOMAIN}")
    fi

    for domain in "${domains[@]}"; do
        log_info "Obtaining certificate for: ${domain}"

        sudo certbot certonly \
            --standalone \
            --preferred-challenges http \
            --agree-tos \
            --no-eff-email \
            --email "${ADMIN_EMAIL}" \
            -d "${domain}"

        if [[ $? -ne 0 ]]; then
            log_error "Failed to obtain certificate for ${domain}"
            exit 1
        fi
    done

    log_success "All certificates obtained successfully"
}

setup_manual_certificates() {
    log_info "Setting up manual certificates..."

    if [[ -z "${SSL_CERT_PATH}" ]] || [[ -z "${SSL_KEY_PATH}" ]]; then
        log_error "SSL_CERT_PATH and SSL_KEY_PATH must be set for manual certificates"
        exit 1
    fi

    if [[ ! -f "${SSL_CERT_PATH}" ]] || [[ ! -f "${SSL_KEY_PATH}" ]]; then
        log_error "Certificate files not found:"
        log_error "  Cert: ${SSL_CERT_PATH}"
        log_error "  Key: ${SSL_KEY_PATH}"
        exit 1
    fi

    # Copy certificates to standard location
    sudo mkdir -p /etc/ssl/pota4/{certs,private}
    sudo cp "${SSL_CERT_PATH}" /etc/ssl/pota4/certs/fullchain.pem
    sudo cp "${SSL_KEY_PATH}" /etc/ssl/pota4/private/privkey.pem
    sudo chmod 644 /etc/ssl/pota4/certs/fullchain.pem
    sudo chmod 600 /etc/ssl/pota4/private/privkey.pem

    log_success "Manual certificates installed"

    export CERT_PUB_KEY="/etc/ssl/pota4/certs/fullchain.pem"
    export CERT_PRIV_KEY="/etc/ssl/pota4/private/privkey.pem"
}

setup_selfsigned_certificates() {
    log_warn "Creating self-signed certificates (DEVELOPMENT ONLY)..."

    sudo mkdir -p /etc/ssl/pota4/{certs,private}

    # Generate self-signed certificate
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/pota4/private/privkey.pem \
        -out /etc/ssl/pota4/certs/fullchain.pem \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=*.${ROOT_DOMAIN}"

    sudo chmod 644 /etc/ssl/pota4/certs/fullchain.pem
    sudo chmod 600 /etc/ssl/pota4/private/privkey.pem

    log_warn "Self-signed certificate created"
    log_warn "Browsers will show security warnings!"

    export CERT_PUB_KEY="/etc/ssl/pota4/certs/fullchain.pem"
    export CERT_PRIV_KEY="/etc/ssl/pota4/private/privkey.pem"
}

setup_certificate_renewal() {
    if [[ "${SSL_METHOD}" != "letsencrypt" ]]; then
        log_info "Certificate auto-renewal not applicable for ${SSL_METHOD}"
        return 0
    fi

    log_info "Setting up certificate auto-renewal..."

    # Certbot automatically creates a systemd timer for renewal
    # Let's verify it exists and is enabled
    if systemctl list-timers | grep -q certbot; then
        log_success "Certbot renewal timer is active"
    else
        # Create manual renewal timer
        create_manual_renewal_timer
    fi

    # Test renewal (dry run)
    log_info "Testing certificate renewal..."
    sudo certbot renew --dry-run

    if [[ $? -eq 0 ]]; then
        log_success "Certificate renewal test passed"
    else
        log_warn "Certificate renewal test failed (may be OK if cert is new)"
    fi
}

create_manual_renewal_timer() {
    log_info "Creating manual certificate renewal timer..."

    sudo tee /etc/systemd/system/certbot-renewal.service > /dev/null << 'EOF'
[Unit]
Description=Certbot Renewal

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF

    sudo tee /etc/systemd/system/certbot-renewal.timer > /dev/null << 'EOF'
[Unit]
Description=Certbot Renewal Timer

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable certbot-renewal.timer
    sudo systemctl start certbot-renewal.timer

    log_success "Certificate renewal timer created"
}

export_certificate_paths() {
    if [[ "${SSL_METHOD}" == "letsencrypt" ]]; then
        if [[ "${LETSENCRYPT_CHALLENGE}" == "dns" ]]; then
            # Wildcard certificate
            export CERT_PUB_KEY="/etc/letsencrypt/live/${ROOT_DOMAIN}/fullchain.pem"
            export CERT_PRIV_KEY="/etc/letsencrypt/live/${ROOT_DOMAIN}/privkey.pem"
        else
            # Individual certificates (use first domain)
            export CERT_PUB_KEY="/etc/letsencrypt/live/${API_DOMAIN}/fullchain.pem"
            export CERT_PRIV_KEY="/etc/letsencrypt/live/${API_DOMAIN}/privkey.pem"
        fi

        # Make certificates readable by current user
        sudo chown -R "$USER:$USER" /etc/letsencrypt || true
        sudo chmod -R 755 /etc/letsencrypt || true
    fi

    log_info "Certificate paths:"
    log_info "  Public: ${CERT_PUB_KEY}"
    log_info "  Private: ${CERT_PRIV_KEY}"
}

# Helper: Check certificate expiry
check_certificate_expiry() {
    local cert_file="${CERT_PUB_KEY}"

    if [[ ! -f "${cert_file}" ]]; then
        log_warn "Certificate file not found: ${cert_file}"
        return 1
    fi

    local expiry_date=$(openssl x509 -enddate -noout -in "${cert_file}" | cut -d= -f2)
    local expiry_epoch=$(date -d "${expiry_date}" +%s)
    local now_epoch=$(date +%s)
    local days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

    log_info "Certificate expiry: ${expiry_date}"
    log_info "Days remaining: ${days_remaining}"

    if [[ ${days_remaining} -lt 30 ]]; then
        log_warn "Certificate expires in less than 30 days!"
    else
        log_success "Certificate is valid"
    fi
}
