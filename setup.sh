#!/bin/bash

# --------------------------------------
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
MAIN_COMPOSE="/home/martial/docker/docker-compose-vpn.yml"
BASIC_AUTH_FILE="/home/martial/docker/secrets/basic_auth_credentials"

# --------------------------------------
# (1) ASK TO INSTALL DOCKER & DOCKER COMPOSE

read -p "Would you like to install Docker and Docker Compose? [y/n]: " install_docker
if [[ "$install_docker" =~ ^[Yy]$ ]]; then
  # Docker installation
  if ! command -v docker &>/dev/null; then
    echo "Docker not found. Installing Docker..."
    sudo apt update
    sudo apt install -y apt-transport-https ca-certificates curl software-properties-common
	sudo install -m 0755 -d /etc/apt/keyrings
	sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
	sudo chmod a+r /etc/apt/keyrings/docker.asc
	# Add the repository to Apt sources:
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update

    sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	sudo groupadd docker
	sudo usermod -aG docker $USER
	newgrp docker
    sudo systemctl enable --now docker
  else
    echo "Docker already installed."
  fi

  # Docker Compose installation (using plugin)
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

# --------------------------------------
# (2) SHOW APPS LIST AND GET USER SELECTION

echo ""
echo "Available apps to install:"
for i in "${!APPS[@]}"; do
  printf "%2d) %s\n" "$((i+1))" "${APPS[$i]}"
done

echo ""
read -p "Enter the number(s) of app(s) you want to install (e.g., 2 5 7): " -a selections

selected_apps=()
for num in "${selections[@]}"; do
  # Support comma-separated numbers as well
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

# --------------------------------------
# (3) IF TRAEFIK IS SELECTED, INSTALL BASIC PACKAGES AND CREATE BASIC AUTH FILE

if printf '%s\n' "${unique_apps[@]}" | grep -qi '^traefik$'; then
  echo ""
  echo "Traefik selected: Installing required packages and setting up basic auth..."

  # Install required packages for Traefik setup
  sudo apt update
  sudo apt install -y acl apache2-utils apt-transport-https argon2 ca-certificates curl gnupg \
    htop libnss-resolve lsb-release nano ncdu net-tools netcat-traditional ntp pwgen \
    software-properties-common ufw unzip zip

  # Prompt for HTTP basic auth credentials
  read -p "Enter HTTP_USERNAME for Traefik basic auth: " HTTP_USERNAME
  read -sp "Enter HTTP_PASSWORD for Traefik basic auth: " HTTP_PASSWORD
  echo ""

  # Make sure secrets directory exists
  sudo mkdir -p "$(dirname "$BASIC_AUTH_FILE")"
  sudo chown "$(whoami)":"$(whoami)" "$(dirname "$BASIC_AUTH_FILE")"

  # Create basic auth credentials file (overwrites if exists)
  sudo htpasswd -cBb "$BASIC_AUTH_FILE" "$HTTP_USERNAME" "$HTTP_PASSWORD"
  sudo chown root:root "$BASIC_AUTH_FILE"
  sudo chmod 640 "$BASIC_AUTH_FILE"

  echo "Basic auth credentials created at $BASIC_AUTH_FILE"
fi

# --------------------------------------
# (4) PROCESS EACH SELECTED APP: CHECK YAML AND ADD INCLUDE LINE

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
