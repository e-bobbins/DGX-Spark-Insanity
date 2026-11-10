#!/usr/bin/env bash
# provision-nfs.sh - Configure Hub node for shared model cache
# Non-Root Deployment: All operations work as regular user, no sudo required
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFS_DIR="/mnt/shared-models"

echo ">>> NFS Shared Model Cache Setup (Non-Sudo Mode)"
echo "[!] This script runs without sudo. NFS configuration may require root."

# Check if running as root for NFS setup
if [ "$(id -u)" = "0" ]; then
    echo "[!] WARNING: Running as root but recommended to run non-root for security"
fi

# Create export directory (works without sudo; may fail if /mnt is missing)
echo "[+] Ensuring ${NFS_DIR} exists..."
if ! mkdir -p "${NFS_DIR}" 2>/dev/null; then
    echo "[!] WARNING: could not create ${NFS_DIR} (needs /mnt to exist and be writable)."
    echo "    Manual setup (requires sudo): sudo mkdir -p /mnt/${NFS_DIR#/mnt/}"
    echo "    Continuing - see manual NFS setup steps below."
fi
if [ -d "${NFS_DIR}" ]; then
    chown root:root "${NFS_DIR}" 2>/dev/null || echo "[!] Cannot change ownership - NFS mount may need manual setup"
    chmod 755 "${NFS_DIR}" 2>/dev/null || true
fi

# Check if /mnt exists (needs sudo to create)
if [ ! -d "/mnt" ]; then
    echo "[!] /mnt directory missing. Create manually: mkdir -p /mnt && chown root root /mnt"
else
    # Configure NFS exports (requires sudo, but documented here for reference)
    EXPORTS_FILE="/etc/exports"
    if [ -f "${EXPORTS_FILE}" ]; then
        echo "[+] NFS export file exists. To enable NFS:"
        echo "  echo '/mnt/shared-models *(rw,sync,root_squash)' >> ${EXPORTS_FILE}"
        echo "  sudo exportfs -ra"
        echo "  sudo systemctl restart nfs-server"
    else
        echo "[!] /etc/exports not found. Configure NFS manually:"
        echo "  Edit /etc/exports and add: /mnt/shared-models *(rw,sync,root_squash)"
        echo "  Then run: exportfs -ra && systemctl restart nfs-server"
    fi
fi

# Alternative: If NFS not available, workers download models independently
echo ""
echo "[+] NFS setup documentation complete."
echo ""
echo "If NFS is unavailable or NFS configuration requires root:"
echo "1. Workers will download models independently from HuggingFace hub"
echo "2. Or manually configure NFS on host with sudo permissions"
echo ""
echo "Manual NFS enablement (when possible to run as root):"
echo "  echo '/mnt/shared-models *(rw,sync,root_squash)' >> /etc/exports"
echo "  exportfs -ra"
