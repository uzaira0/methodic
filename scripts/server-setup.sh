#!/usr/bin/env bash
set -euo pipefail

# Chronicle Server First-Time Setup Script
# Run this on a fresh dedicated server to prepare the supported production deploy path.

REPO_URL="${REPO_URL:-https://github.com/uzaira0/chronicle.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/chronicle}"

echo "=== Chronicle Server Setup ==="
echo "Repo: $REPO_URL"
echo "Install dir: $INSTALL_DIR"
echo ""

# Check if running as root or with sudo
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# Step 1: Install Docker if not present
install_docker() {
    if command -v docker &> /dev/null; then
        echo "[✓] Docker already installed"
        return
    fi

    echo "[*] Installing Docker..."
    
    if command -v apt-get &> /dev/null; then
        $SUDO apt-get update
        $SUDO apt-get install -y docker.io docker-compose-plugin
    elif command -v dnf &> /dev/null; then
        $SUDO dnf install -y docker docker-compose-plugin
    elif command -v yum &> /dev/null; then
        $SUDO yum install -y docker docker-compose-plugin
    else
        echo "ERROR: Unsupported package manager. Install Docker manually."
        exit 1
    fi

    $SUDO systemctl enable --now docker
    
    # Add current user to docker group
    if [ -n "${SUDO_USER:-}" ]; then
        $SUDO usermod -aG docker "$SUDO_USER"
    elif [ "$(id -u)" -ne 0 ]; then
        $SUDO usermod -aG docker "$USER"
    fi

    echo "[✓] Docker installed"
}

# Step 2: Clone the repository
clone_repo() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        echo "[✓] Repository already cloned at $INSTALL_DIR"
        echo "[*] Pulling latest changes..."
        cd "$INSTALL_DIR"
        git pull --recurse-submodules
        return
    fi

    echo "[*] Cloning repository to $INSTALL_DIR..."
    $SUDO mkdir -p "$(dirname "$INSTALL_DIR")"
    $SUDO git clone --recurse-submodules "$REPO_URL" "$INSTALL_DIR"
    
    # Fix ownership if running with sudo
    if [ -n "${SUDO_USER:-}" ]; then
        $SUDO chown -R "$SUDO_USER:$SUDO_USER" "$INSTALL_DIR"
    fi

    echo "[✓] Repository cloned"
}

# Step 3: Configure environment
configure_env() {
    cd "$INSTALL_DIR/docker"
    
    if [ -f .env.production.local ]; then
        echo "[✓] .env.production.local already exists"
        return
    fi

    echo "[*] Creating untracked production env file from template..."
    cp .env.production .env.production.local
    chmod 600 .env.production.local
    
    echo ""
    echo "[!] IMPORTANT: Edit $INSTALL_DIR/docker/.env.production.local and replace every CHANGE_ME value."
    echo "    Keep this file untracked and mode 0600. Do not put production secrets in docker/.env.production."
    echo ""
    echo "[✓] .env.production.local created from the production template"
}

# Step 4: Set up SSL certificates
setup_ssl() {
    echo "[*] Public TLS is expected to terminate at an upstream load balancer."
    echo "    This setup script does not provision Let's Encrypt or public TLS material."
}

# Step 6: Initial build
initial_build() {
    cd "$INSTALL_DIR/docker"
    
    if ! [ -f .env.production.local ]; then
        echo "[!] Skipping validation - .env.production.local not configured"
        return
    fi

    if grep -Eq "CHANGE_ME|chronicle.example.com|example.com" .env.production.local; then
        echo "[!] Skipping compose validation - .env.production.local still contains template values"
        return
    fi

    echo "[*] Validating production compose rendering..."
    docker compose --env-file .env.production.local \
        -f docker-compose.traefik.yml \
        -f docker-compose.production.yml \
        config -q
    echo "[✓] Production compose rendering is valid"
}

# Main
main() {
    install_docker
    clone_repo
    configure_env
    setup_ssl
    initial_build

    echo ""
    echo "=== Setup Complete ==="
    echo ""
    echo "Next steps:"
    echo "  1. Edit $INSTALL_DIR/docker/.env.production.local and replace all placeholders."
    echo "  2. Run: cd $INSTALL_DIR && tests/security/run-all-security.sh deploy /tmp/chronicle-deploy"
    echo "  3. Deploy image releases with:"
    echo "     ./scripts/deploy.sh --environment production --env-file docker/.env.production.local --tag sha-<git-sha>"
    echo "  4. Backend-only live deploys still use the prod-backend branch workflow when intended."
    echo ""
    echo "No GitHub self-hosted runner was installed by this script."
}

main "$@"
