#!/bin/bash

# ============================================
# CONFIGURATION
APPS=(
  "authentik-worker"
  "Authentik"
  "Dashy"
  "Jellyfin"
  "mariadb"
  "n8n"
  "nextcloud"
  "pihole"
  "portainer"
  "Postgresql"
  "prometheus"
  "redis"
  "socket-proxy"
  "traefik"
)

COMPOSE_DIR="/home/martial/docker/compose/$HOSTNAME"
MAIN_COMPOSE="/home/martial/docker/docker-compose-vm.yml"
BASIC_AUTH_FILE="/home/martial/docker/secrets/basic_auth_credentials"
DOCKER_ROOT="/home/martial/docker"
ENV_FILE="$DOCKER_ROOT/.env"
SECRETS_DIR="$DOCKER_ROOT/secrets"
USER_MARTIAL="martial"

# ============================================
# REQUIRED SYSTEM PACKAGES
sudo apt update
sudo apt install -y acl apache2-utils apt-transport-https argon2 ca-certificates curl gnupg \
  htop libnss-resolve lsb-release nano ncdu net-tools netcat-traditional ntp pwgen \
  software-properties-common ufw unzip zip

# ============================================
# DOCKER & DOCKER COMPOSE INSTALLATION

read -p "Would you like to install Docker and Docker Compose? [y/n]: " install_docker
if [[ "$install_docker" =~ ^[Yy]$ ]]; then
  if ! command -v docker &>/dev/null; then
    echo "Docker not found. Installing Docker..."
    sudo apt update
    sudo apt install -y apt-transport-https ca-certificates curl software-properties-common
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo groupadd docker || true
    sudo usermod -aG docker $USER
    newgrp docker
    sudo systemctl enable --now docker
  else
    echo "Docker already installed."
  fi

  if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
    echo "Docker Compose not found. Installing Docker Compose plugin..."
    sudo curl -SL https://github.com/docker/compose/releases/download/v2.38.2/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
  else
    echo "Docker Compose already installed."
  fi
  echo "Docker and Docker Compose installation complete."
else
  echo "Skipping Docker and Docker Compose installation."
fi

# ============================================
# FILE & FOLDER SECURITY & ACL SETUP

# Secrets directory
sudo mkdir -p "$SECRETS_DIR"
sudo chown root:root "$SECRETS_DIR"
sudo chmod 600 "$SECRETS_DIR"

# Main .env file
sudo touch "$ENV_FILE"
sudo chown root:root "$ENV_FILE"
sudo chmod 600 "$ENV_FILE"

# Docker root folder permissions
sudo apt install -y acl  # Ensure acl is present
sudo chmod 775 "$DOCKER_ROOT"
# Set default ACLs so 'martial' and 'docker' group have full access to everything below /home/martial/docker
sudo setfacl -Rdm u:"$USER_MARTIAL":rwx "$DOCKER_ROOT"
sudo setfacl -Rm u:"$USER_MARTIAL":rwx "$DOCKER_ROOT"
sudo setfacl -Rdm g:docker:rwx "$DOCKER_ROOT"
sudo setfacl -Rm g:docker:rwx "$DOCKER_ROOT"

# ============================================
# SELECT APPS
echo ""
echo "Available apps to install:"
for i in "${!APPS[@]}"; do
  printf "%2d) %s\n" "$((i+1))" "${APPS[$i]}"
done

echo ""
read -p "Enter the number(s) of app(s) you want to install (e.g., 2 5 7): " -a selections

selected_apps=()
for num in "${selections[@]}"; do
  # Support comma-separated numbers
  for splitnum in $(echo "$num" | tr ',' ' '); do
    if [[ "$splitnum" =~ ^[0-9]+$ ]] && (( splitnum >= 1 && splitnum <= ${#APPS[@]} )); then
      app="${APPS[splitnum-1]}"
      selected_apps+=("$app")
    else
      echo "Invalid selection ignored: $splitnum"
    fi
  done
done

# Remove duplicates
unique_apps=($(printf "%s\n" "${selected_apps[@]}" | awk '!seen[$0]++'))

if [[ ${#unique_apps[@]} -eq 0 ]]; then
  echo "No valid apps selected. Exiting."
  exit 1
fi

echo ""
echo "You selected: ${unique_apps[*]}"

# ============================================
# TRAEFIK - BASIC AUTH SETUP (if selected)
if printf '%s\n' "${unique_apps[@]}" | grep -qi '^traefik$'; then
  echo ""
  echo "Traefik selected: Installing required packages and setting up basic auth..."
  read -p "Enter HTTP_USERNAME for Traefik basic auth: " HTTP_USERNAME
  read -sp "Enter HTTP_PASSWORD for Traefik basic auth: " HTTP_PASSWORD
  echo ""
  sudo mkdir -p "$(dirname "$BASIC_AUTH_FILE")"
  sudo chown "$(whoami)":"$(whoami)" "$(dirname "$BASIC_AUTH_FILE")"
  sudo htpasswd -cBb "$BASIC_AUTH_FILE" "$HTTP_USERNAME" "$HTTP_PASSWORD"
  sudo chown root:root "$BASIC_AUTH_FILE"
  sudo chmod 640 "$BASIC_AUTH_FILE"
  echo "Basic auth credentials created at $BASIC_AUTH_FILE"
fi

# ============================================
# GENERATE AUTHENTIK SECRETS IN .env IF SELECTED
if printf '%s\n' "${unique_apps[@]}" | grep -qi '^authentik$'; then
  AUTHENTIK_PG_PASS=$(openssl rand -base64 36 | tr -d '\n')
  AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')
  echo "Setting up secrets for authentik in .env..."
  echo "AUTHENTIK_POSTGRESQL__PASSWORD=$AUTHENTIK_PG_PASS" | sudo tee -a "$ENV_FILE" > /dev/null
  echo "AUTHENTIK_SECRET_KEY=$AUTHENTIK_SECRET_KEY" | sudo tee -a "$ENV_FILE" > /dev/null
fi

# ============================================
# ADD SELECTED APPS TO MAIN DOCKER-COMPOSE
for app in "${unique_apps[@]}"; do
  YAML_FILE="$COMPOSE_DIR/${app}.yml"
  INCLUDE_LINE="- compose/\$HOSTNAME/${app}.yml"
  if [[ -f "$YAML_FILE" ]]; then
    if grep -qF "$INCLUDE_LINE" "$MAIN_COMPOSE"; then
      echo "Entry for $app already exists in main compose file."
    else
      echo "Adding $INCLUDE_LINE to $MAIN_COMPOSE."
      echo "$INCLUDE_LINE" | sudo tee -a "$MAIN_COMPOSE" >/dev/null
    fi
  else
    echo "WARNING: YAML file for ${app} not found at $YAML_FILE."
  fi
done

echo ""
echo "Setup complete. To start or restart your services, run:"
echo "docker compose --profile all -f $MAIN_COMPOSE up -d"
