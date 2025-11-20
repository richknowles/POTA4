# POTA4 RMM - OCI One-Stop Deployment Script 🚀

**Comprehensive automated deployment solution for Oracle Cloud Infrastructure**

Created with love by Claude & Rich (Team Hotdog 🌭)

---

## Features

✨ **Complete Automation**
- ✅ One-command deployment from scratch to production
- ✅ Non-interactive mode (perfect for automation)
- ✅ Idempotent (safe to run multiple times)

🐳 **Docker First**
- ✅ Docker Compose deployment (recommended)
- ✅ Ubuntu 22.04 LTS support (plus 20.04, Debian 11, Oracle Linux 8/9)
- ✅ Easy updates and rollbacks

☁️ **Multi-Cloud Object Storage**
- ✅ Wasabi (cost-effective, recommended)
- ✅ OCI Object Storage
- ✅ AWS S3
- ✅ MinIO (self-hosted)
- ✅ Optimized rclone configuration

🔒 **Security & SSL**
- ✅ Let's Encrypt automation (wildcard DNS-01 or HTTP-01)
- ✅ Manual certificate import
- ✅ Automated renewal

💾 **Three-Bucket Architecture**
1. **Backups** - Automated encrypted backups (daily/weekly/monthly)
2. **Scripts** - GitHub/Local/Cloud synchronization
3. **Transfers** - Client file upload/download foundation

🎛️ **Cockpit Integration**
- ✅ Web-based server management
- ✅ Docker container control
- ✅ Service management, logs, terminal access

🔧 **OCI Optimizations**
- ✅ Automatic firewall configuration (iptables + Security Lists)
- ✅ OCI CLI integration
- ✅ Network performance tuning
- ✅ Load balancer preparation (future HA)

📊 **Health Checks**
- ✅ Comprehensive post-installation validation
- ✅ Service status monitoring
- ✅ Certificate expiry tracking
- ✅ Storage connectivity tests

---

## Quick Start

### 1. Initial Setup

```bash
# Clone this repository (or navigate to oci-deploy directory)
cd /home/user/POTA4/oci-deploy

# Generate configuration template
./oci-deploy.sh --init

# Copy Wasabi example (recommended)
cp .env.wasabi.example .env

# Edit configuration
nano .env
```

### 2. Configure Your Environment

Edit `.env` with your settings:

```bash
# Domain Configuration
ROOT_DOMAIN=example.com
API_SUBDOMAIN=api
FRONTEND_SUBDOMAIN=rmm
MESH_SUBDOMAIN=mesh
ADMIN_EMAIL=admin@example.com

# Deployment Mode
DEPLOY_MODE=docker

# SSL Configuration
SSL_METHOD=letsencrypt
LETSENCRYPT_CHALLENGE=dns  # or 'http'

# Wasabi Configuration
OBJECT_STORAGE_PROVIDER=wasabi
WASABI_ACCESS_KEY=YOUR_ACCESS_KEY
WASABI_SECRET_KEY=YOUR_SECRET_KEY
WASABI_REGION=us-east-1

# Bucket Names
BACKUP_BUCKET=pota4-backups
SCRIPTS_BUCKET=pota4-scripts
TRANSFERS_BUCKET=pota4-transfers

# Optional: Cockpit
INSTALL_COCKPIT=true
```

### 3. Deploy!

```bash
./oci-deploy.sh --install
```

Sit back and enjoy the hotdogs! 🌭 The script will:
1. Run pre-flight checks
2. Configure OCI firewall rules
3. Obtain SSL certificates
4. Setup object storage (Wasabi)
5. Deploy Docker containers
6. Configure automated backups
7. Install Cockpit (optional)
8. Run health checks
9. Display your credentials

---

## Usage

### Installation

```bash
# Fresh installation
./oci-deploy.sh --install
```

### Updates

```bash
# Update existing deployment
./oci-deploy.sh --update
```

### Backups

```bash
# Manual backup
./oci-deploy.sh --backup

# Restore from backup
./oci-deploy.sh --restore /path/to/backup.tar.gz.enc
```

### Health Checks

```bash
# Run system health validation
./oci-deploy.sh --health-check
```

---

## Object Storage (Wasabi)

### Bucket Setup

Create three buckets in Wasabi:

1. **pota4-backups**
   - Purpose: Automated encrypted backups
   - Retention: 7 daily, 4 weekly, 12 monthly
   - Encryption: Enabled

2. **pota4-scripts**
   - Purpose: Scripts repository synchronization
   - Versioning: Enabled
   - Sync: GitHub → Local → Wasabi (daily)

3. **pota4-transfers**
   - Purpose: Client file transfers
   - Lifecycle: Auto-delete temp/* after 24h
   - Use: Agent uploads, tech staging

### Access Keys

Generate Wasabi access keys:
1. Log in to Wasabi Console
2. Go to Access Keys
3. Create New Access Key
4. Save Access Key ID and Secret Access Key
5. Add to `.env` file

### Cost Estimate

Typical RMM deployment on Wasabi:
- Backups: ~20-100 GB = $0.70-3.50/month
- Scripts: ~2-10 GB = $0.07-0.35/month
- Transfers: ~10-50 GB = $0.35-1.75/month
- **Total: ~$2-6/month** (vs $50-200 on AWS!)

No egress fees! No API fees! 🎉

---

## SSL Certificates

### Option 1: Let's Encrypt (Wildcard - Recommended)

```bash
SSL_METHOD=letsencrypt
LETSENCRYPT_CHALLENGE=dns
```

You'll be prompted to create a TXT record in your DNS:
```
_acme-challenge.example.com. TXT "random-string-from-letsencrypt"
```

Wait for DNS propagation (check with `dig`), then continue.

### Option 2: Let's Encrypt (HTTP-01)

```bash
SSL_METHOD=letsencrypt
LETSENCRYPT_CHALLENGE=http
```

Requires ports 80/443 open. Simpler but individual certs for each subdomain.

### Option 3: Manual Certificates

```bash
SSL_METHOD=manual
SSL_CERT_PATH=/path/to/fullchain.pem
SSL_KEY_PATH=/path/to/privkey.pem
```

---

## OCI Configuration

### Security List Rules

Add these Ingress Rules to your VCN's Security List:

| Protocol | Source     | Destination Port | Description        |
|----------|------------|------------------|--------------------|
| TCP      | 0.0.0.0/0  | 80               | HTTP               |
| TCP      | 0.0.0.0/0  | 443              | HTTPS              |
| TCP      | 0.0.0.0/0  | 4222             | NATS (Agents)      |
| TCP      | YOUR_IP/32 | 9090             | Cockpit (Admin)    |

### Firewall Commands

The script automatically configures iptables, but you can verify:

```bash
sudo iptables -L -n | grep -E '(80|443|4222|9090)'
```

---

## Cockpit Web UI

If enabled, access at: `https://server.example.com:9090`

**Features:**
- Server monitoring (CPU, RAM, Disk, Network)
- Docker container management
- Service control (start/stop/restart)
- Log viewing
- Terminal access
- File manager

**Login:** Use your SSH/system user credentials

---

## Django S3 Management Commands

Copy Django commands from `django-commands/` to your Django project:

```bash
cp django-commands/*.py /opt/pota4-docker/tactical/api/tacticalrmm/core/management/commands/
```

### Usage Examples

```bash
# Upload file for agent
python manage.py s3_upload --agent 123 --file /path/to/tool.exe

# Download file from agent
python manage.py s3_download --agent 123 --filename screenshot.png --dest /tmp/

# Generate pre-signed URL
python manage.py s3_presign --agent 123 --filename tool.exe --expires 86400
```

---

## Backup & Restore

### Automated Backups

Backups run daily at 2 AM (configurable via `BACKUP_SCHEDULE`).

Check status:
```bash
systemctl status pota4-backup.timer
journalctl -u pota4-backup.service -f
```

### Manual Backup

```bash
./oci-deploy.sh --backup
```

Backups are:
- ✅ Encrypted with AES-256-CBC
- ✅ Uploaded to Wasabi automatically
- ✅ Organized by type (daily/weekly/monthly)
- ✅ Auto-deleted per retention policy

### Restore

```bash
# List available backups
rclone ls pota4-storage:pota4-backups/daily/

# Restore from local file
./oci-deploy.sh --restore /opt/pota4-backups/daily/backup-2025-11-20.tar.gz.enc

# Restore from Wasabi (auto-downloads)
./oci-deploy.sh --restore backup-2025-11-20.tar.gz.enc
```

---

## Troubleshooting

### View Logs

```bash
# Deployment log
tail -f oci-deploy/install-*.log

# Docker container logs
docker logs -f tactical-backend
docker logs -f tactical-meshcentral

# System logs
journalctl -u pota4-backup.service -f
journalctl -u pota4-scripts-sync.service -f
```

### Common Issues

**DNS not resolving?**
- Check DNS propagation: `dig api.example.com`
- Wait up to 48 hours for full propagation
- Script will warn but allow you to continue

**Containers not starting?**
- Check Docker status: `docker ps -a`
- View logs: `docker logs tactical-backend`
- Restart: `cd /opt/pota4-docker && docker compose restart`

**Object storage connection failed?**
- Test rclone: `rclone lsd pota4-storage:`
- Verify credentials in `.env`
- Check network connectivity

**Certificate issues?**
- Check expiry: `openssl x509 -in /path/to/cert.pem -noout -dates`
- Renew: `sudo certbot renew`
- View renewal timer: `systemctl list-timers certbot*`

---

## File Structure

```
oci-deploy/
├── oci-deploy.sh              # Main orchestrator
├── .env                       # Your configuration
├── .env.example               # Configuration template
├── .env.wasabi.example        # Wasabi-specific example
├── lib/                       # Library modules
│   ├── preflight.sh           # Pre-flight checks
│   ├── storage-backend.sh     # Object storage abstraction
│   ├── backup-manager.sh      # Backup/restore operations
│   ├── scripts-sync.sh        # Scripts synchronization
│   ├── transfers-manager.sh   # File transfers
│   ├── ssl-manager.sh         # SSL certificates
│   ├── oci-setup.sh           # OCI configuration
│   ├── docker-deploy.sh       # Docker deployment
│   ├── cockpit-setup.sh       # Cockpit setup
│   └── health-check.sh        # Health validation
├── django-commands/           # Django management commands
│   ├── s3_upload.py
│   ├── s3_download.py
│   └── ...
├── docs/                      # Documentation
│   ├── WASABI_SETUP.md
│   ├── BACKUP_RESTORE.md
│   └── NOTES_TO_DESKTOP_SELF.md
└── README.md                  # This file
```

---

## Advanced Configuration

### Optimization Settings

```bash
# rclone optimizations
RCLONE_OPTIMIZE_MOUNT=true
RCLONE_VFS_CACHE_MODE=writes
RCLONE_BUFFER_SIZE=256M

# Backup retention
BACKUP_RETENTION_DAILY=7
BACKUP_RETENTION_WEEKLY=4
BACKUP_RETENTION_MONTHLY=12

# Scripts sync frequency
SCRIPTS_SYNC_INTERVAL=daily  # hourly, daily, weekly
```

### Multiple Environments

Create environment-specific configs:

```bash
# Production
cp .env .env.production

# Staging
cp .env .env.staging
```

Deploy with specific config:
```bash
cp .env.production .env
./oci-deploy.sh --install
```

---

## Future Enhancements

### Planned Features
- [ ] Rustdesk integration (MeshCentral replacement)
- [ ] Quick Support web-based client onboarding
- [ ] HA deployment with OCI Load Balancer
- [ ] Kubernetes deployment option
- [ ] Web UI for deployment management
- [ ] Automated DNS configuration via OCI CLI

---

## Credits

**Created by:**
- Rich (ITWERKS.net) - Vision & Requirements
- Claude (Anthropic) - Implementation & Engineering

**Special Thanks:**
- The POTA4 RMM community
- Tactical RMM upstream project
- Wasabi Technologies (for awesome pricing!)
- Oracle Cloud Infrastructure

---

## Support

**Issues/Questions:**
- GitHub Issues: https://github.com/rightontron/pota4rmm/issues
- Documentation: https://rightontron.github.io/pota4rmm/

**Contributing:**
Pull requests welcome! This deployment system is open for community improvements.

---

## License

MIT License - Same as POTA4 RMM

---

**Deployment complete? Time for hotdogs!** 🌭

*May your servers stay up and your backups stay encrypted.*

-- Team Hotdog, 2025
