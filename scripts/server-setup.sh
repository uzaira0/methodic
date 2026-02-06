#!/usr/bin/env bash
set -euo pipefail

# Chronicle Server First-Time Setup Script
# Run this on a fresh server to set up Chronicle with GitHub Actions self-hosted runner

REPO_URL="${REPO_URL:-git@github.com:methodic-labs/methodic.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/chronicle}"
RUNNER_VERSION="${RUNNER_VERSION:-2.311.0}"

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
    
    if [ -f .env ]; then
        echo "[✓] .env already exists"
        return
    fi

    echo "[*] Creating .env from template..."
    cp .env.example .env
    
    # Generate secure secrets
    JWT_SECRET=$(openssl rand -base64 64 | tr -d '\n')
    POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '\n')
    MOBILE_APP_KEY=$(openssl rand -hex 32)
    
    # Update .env with generated secrets
    sed -i "s|JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" .env
    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" .env
    sed -i "s|MOBILE_APP_KEY=.*|MOBILE_APP_KEY=$MOBILE_APP_KEY|" .env
    
    echo ""
    echo "[!] IMPORTANT: Edit $INSTALL_DIR/docker/.env to set:"
    echo "    - DOMAIN (your domain name)"
    echo "    - LETSENCRYPT_EMAIL (for SSL certs)"
    echo ""
    echo "[✓] .env created with secure secrets"
}

# Step 4: Set up SSL certificates
setup_ssl() {
    cd "$INSTALL_DIR/docker"
    
    if [ -f certs/fullchain.pem ] && [ -f certs/privkey.pem ]; then
        echo "[✓] SSL certificates already exist"
        return
    fi

    echo "[*] Run ./init-ssl.sh to set up SSL certificates"
    echo "    Options: self-signed (testing) or Let's Encrypt (production)"
}

# Step 5: Install GitHub Actions Runner
install_runner() {
    RUNNER_DIR="$INSTALL_DIR/actions-runner"
    
    if [ -d "$RUNNER_DIR" ] && [ -f "$RUNNER_DIR/.runner" ]; then
        echo "[✓] GitHub Actions runner already configured"
        return
    fi

    echo ""
    echo "[*] Setting up GitHub Actions self-hosted runner..."
    echo ""
    echo "You need a runner token from GitHub:"
    echo "  1. Go to: https://github.com/methodic-labs/methodic/settings/actions/runners/new"
    echo "  2. Copy the token shown in the 'Configure' section"
    echo ""
    read -p "Enter your GitHub runner token (or 'skip' to skip): " RUNNER_TOKEN
    
    if [ "$RUNNER_TOKEN" = "skip" ]; then
        echo "[!] Skipping runner setup. Set it up manually later."
        return
    fi

    mkdir -p "$RUNNER_DIR"
    cd "$RUNNER_DIR"

    # Download runner
    curl -o actions-runner.tar.gz -L \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    tar xzf actions-runner.tar.gz
    rm actions-runner.tar.gz

    # Configure runner
    ./config.sh --url "https://github.com/methodic-labs/methodic" \
        --token "$RUNNER_TOKEN" \
        --name "chronicle-server" \
        --labels "self-hosted,chronicle" \
        --work "$INSTALL_DIR/_work" \
        --unattended

    # Install as service
    $SUDO ./svc.sh install
    $SUDO ./svc.sh start

    echo "[✓] GitHub Actions runner installed and started"
}

# Step 6: Initial build
initial_build() {
    cd "$INSTALL_DIR/docker"
    
    if ! [ -f .env ]; then
        echo "[!] Skipping initial build - .env not configured"
        return
    fi

    # Check if DOMAIN is still the example value
    if grep -q "DOMAIN=chronicle.example.com" .env; then
        echo "[!] Skipping initial build - DOMAIN not configured in .env"
        return
    fi

    echo "[*] Running initial build..."
    docker compose -f docker-compose.prod.yml up -d --build

    echo "[✓] Chronicle is running!"
    docker compose -f docker-compose.prod.yml ps
}

# Main
main() {
    install_docker
    clone_repo
    configure_env
    setup_ssl
    install_runner
    initial_build

    echo ""
    echo "=== Setup Complete ==="
    echo ""
    echo "Next steps:"
    echo "  1. Edit $INSTALL_DIR/docker/.env (set DOMAIN, email)"
    echo "  2. Run: cd $INSTALL_DIR/docker && ./init-ssl.sh"
    echo "  3. Run: docker compose -f docker-compose.prod.yml up -d --build"
    echo ""
    echo "Future deployments will be automatic when you push to GitHub."
}

main "$@"
