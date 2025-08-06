#!/bin/bash

# ============================================
# CONFIGURATION
APPS=(
  "authentik-worker"
  "authentik"
  "dashy"
  "jellyfin"
  "mariadb"
  "n8n"
  "nextcloud"
  "pihole"
  "portainer"
  "postgresql"
  "prometheus"
  "redis"
  "socket-proxy"
  "traefik"
  "vaultwarden"
)

COMPOSE_DIR="/home/martial/docker/compose/$HOSTNAME"
MAIN_COMPOSE="/home/martial/docker/docker-compose-vm.yml"
BASIC_AUTH_FILE="/home/martial/docker/secrets/basic_auth_credentials"
DOCKER_ROOT="/home/martial/docker"
APPDATA_ROOT="$DOCKER_ROOT/appdata/traefik3"
ENV_FILE="$DOCKER_ROOT/.env"
SECRETS_DIR="$DOCKER_ROOT/secrets"
USER_MARTIAL="martial"
LOG_FILE="$DOCKER_ROOT/app-setup.log"

# ============================================
# LOGGING FUNCTION
log() {
  echo "[`date +"%Y-%m-%d %H:%M:%S"`] $*" | tee -a "$LOG_FILE"
}

# ============================================
# CHECK PREREQUISITES (sudo & docker daemon)
check_prerequisites() {
  if ! sudo -v >/dev/null 2>&1; then
    echo "This script requires sudo access."
    exit 1
  fi

  if ! sudo docker info >/dev/null 2>&1; then
    echo "Docker daemon is not running or you do not have permissions to run Docker commands."
    exit 1
  fi
}

# ============================================
# INSTALL REQUIRED SYSTEM PACKAGES
install_packages() {
  log "Updating package lists and installing required packages..."
  sudo apt update
  sudo apt install -y acl apache2-utils apt-transport-https argon2 ca-certificates curl gnupg \
      htop libnss-resolve lsb-release nano ncdu net-tools netcat-traditional ntp pwgen \
      software-properties-common ufw unzip zip
  log "Required packages installed."
}

# ============================================
# SELECT APPLICATIONS
select_apps() {
  echo ""
  echo "Available apps to install:"
  for i in "${!APPS[@]}"; do
    printf "%2d) %s\n" "$((i + 1))" "${APPS[$i]}"
  done
  echo ""

  while true; do
    read -r -p "Enter the number(s) of app(s) you want to install (spaces or comma separated): " -a selections

    selected_apps=()
    for num in "${selections[@]}"; do
      for splitnum in $(echo "$num" | tr ',' ' '); do
        if [[ "$splitnum" =~ ^[0-9]+$ ]] && (( splitnum >= 1 && splitnum <= ${#APPS[@]} )); then
          app="${APPS[splitnum-1]}"
          selected_apps+=("$app")
        else
          echo "Ignoring invalid selection: $splitnum"
        fi
      done
    done

    # Remove duplicates
    unique_apps=($(printf "%s\n" "${selected_apps[@]}" | awk '!seen[$0]++'))

    if [[ ${#unique_apps[@]} -gt 0 ]]; then
      echo "You have selected: ${unique_apps[*]}"
      break
    else
      echo "No valid apps selected. Please try again."
    fi
  done
}

# ============================================
# ENFORCE DEPENDENCIES FOR AUTHENTIK/APPS
enforce_dependencies() {
  while true; do
    if printf '%s\n' "${unique_apps[@]}" | grep -Eiq '^(authentik|authentik-worker)$'; then
      echo ""
      echo "authentik or authentik-worker selected."
      echo "Required apps to install in order:"
      echo "  1) postgresql"
      echo "  2) redis"
      echo "  3) authentik"
      echo "  4) authentik-worker"
      read -r -p "Install these required apps in order? [y/n]: " resp
      if [[ "$resp" =~ ^[Yy]$ ]]; then
        required_apps=(postgresql redis authentik authentik-worker)
        extra_apps=()
        for app in "${unique_apps[@]}"; do
          skip=false
          for r in "${required_apps[@]}"; do
            if [[ "$app" == "$r" ]]; then
              skip=true
              break
            fi
          done
          $skip || extra_apps+=("$app")
        done
        unique_apps=("${required_apps[@]}" "${extra_apps[@]}")
        echo "Final install order: ${unique_apps[*]}"
        break
      else
        echo "You declined required dependency installation. Please re-select apps."
        return 1
      fi
    else
      break
    fi
  done
  return 0
}

# ============================================
# DETECT POSTGRES CONTAINER NAME
detect_postgres_container() {
  local container
  container=$(sudo docker ps --format '{{.Names}}' | grep -m 1 -E 'postgresql|postgres')
  if [[ -z "$container" ]]; then
    log "WARNING: PostgreSQL container not found running."
  fi
  echo "$container"
}

# ============================================
# RUN PSQL COMMAND INSIDE POSTGRES CONTAINER
postgres_exec() {
  local sql="$1"
  local container="$2"
  [[ -z "$container" ]] && container=$(detect_postgres_container)
  if [[ -z "$container" ]]; then
    log "ERROR: PostgreSQL container not found. Cannot execute: $sql"
    return 1
  fi
  sudo docker exec -i "$container" psql -U "postgres_user" -d postgres -c "$sql"
}

# ============================================
# CREATE DATABASE IF NOT EXISTS
postgres_create_db() {
  local db="$1"
  local container="$2"
  local exists
  exists=$(postgres_exec "SELECT 1 FROM pg_database WHERE datname='$db';" "$container" 2>/dev/null | grep -q 1 && echo 1)
  if [[ "$exists" != "1" ]]; then
    log "Creating PostgreSQL database '$db'..."
    postgres_exec "CREATE DATABASE $db;" "$container"
  else
    log "PostgreSQL database '$db' already exists."
  fi
}

# ============================================
# CREATE USER IF NOT EXISTS
postgres_create_user() {
  local user="$1"
  local pass="$2"
  local container="$3"
  local exists
  exists=$(postgres_exec "SELECT 1 FROM pg_roles WHERE rolname='$user';" "$container" 2>/dev/null | grep -q 1 && echo 1)
  if [[ "$exists" != "1" ]]; then
    log "Creating PostgreSQL user '$user' with password."
    postgres_exec "CREATE USER $user WITH PASSWORD '$pass';" "$container"
  else
    log "PostgreSQL user '$user' already exists."
  fi
}

# ============================================
# GENERATE SECRETS / SETUP PASSWORDS
generate_secrets_and_setup() {
  sudo mkdir -p "$SECRETS_DIR"
  sudo chown "$USER_MARTIAL":"$USER_MARTIAL" "$SECRETS_DIR"

  POSTGRES_CONT=$(detect_postgres_container)

  for app in "${unique_apps[@]}"; do
    log "Setting up app: $app"

    case "$app" in
      postgresql)
        POSTGRES_PASS_FILE="$SECRETS_DIR/postgres_default_password"
        if [[ ! -f "$POSTGRES_PASS_FILE" ]]; then
          POSTGRES_PASS=$(openssl rand -base64 36 | tr -d '\n')
          echo "$POSTGRES_PASS" | sudo tee "$POSTGRES_PASS_FILE" > /dev/null
          sudo chmod 600 "$POSTGRES_PASS_FILE"
          sudo chown "$USER_MARTIAL":"$USER_MARTIAL" "$POSTGRES_PASS_FILE"
          mkdir -p "$DOCKER_ROOT/appdata/postgresql"
          sudo chown -R "$USER_MARTIAL":"$USER_MARTIAL" "$DOCKER_ROOT/appdata/postgresql"
          log "PostgreSQL password generated."
        else
          log "PostgreSQL password file already exists."
        fi
        ;;

      redis)
        mkdir -p "$DOCKER_ROOT/appdata/redis"
        sudo chown -R "$USER_MARTIAL":"$USER_MARTIAL" "$DOCKER_ROOT/appdata/redis"
        log "Redis appdata permissions set."
        ;;

      n8n)
        N8N_PASS_FILE="$SECRETS_DIR/n8n_postgres_password"
        if [[ ! -f "$N8N_PASS_FILE" ]]; then
          N8N_PASS=$(openssl rand -base64 36 | tr -d '\n')
          echo "$N8N_PASS" | sudo tee "$N8N_PASS_FILE" > /dev/null
          sudo chmod 600 "$N8N_PASS_FILE"
          sudo chown "$USER_MARTIAL":"$USER_MARTIAL" "$N8N_PASS_FILE"
          log "N8N PostgreSQL password generated."
        else
          N8N_PASS=$(cat "$N8N_PASS_FILE")
        fi

        if [[ -n "$POSTGRES_CONT" ]]; then
          postgres_create_db "n8n_db" "$POSTGRES_CONT"
          postgres_create_user "n8n_user" "$N8N_PASS" "$POSTGRES_CONT"
          postgres_exec "GRANT ALL PRIVILEGES ON DATABASE n8n_db TO n8n_user;" "$POSTGRES_CONT"
          postgres_exec "ALTER DATABASE n8n_db OWNER TO n8n_user;" "$POSTGRES_CONT"
          postgres_exec "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO n8n_user;" "$POSTGRES_CONT"
          postgres_exec "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO n8n_user;" "$POSTGRES_CONT"
          postgres_exec "GRANT CREATE ON SCHEMA public TO n8n_user;" "$POSTGRES_CONT"
        else
          log "Warning: Cannot configure n8n DB; PostgreSQL container not found."
        fi
        ;;

      traefik)
        if [[ -f "$APPDATA_ROOT/acme/acme.json" ]]; then
          sudo chmod 600 "$APPDATA_ROOT/acme/acme.json"
        fi
        echo ""
        echo "Setting up Traefik basic auth credentials..."
        read -r -p "HTTP_USERNAME: " HTTP_USERNAME
        read -r -s -p "HTTP_PASSWORD: " HTTP_PASSWORD
        echo ""
        sudo mkdir -p "$(dirname "$BASIC_AUTH_FILE")"
        sudo chown "$USER_MARTIAL":"$USER_MARTIAL" "$(dirname "$BASIC_AUTH_FILE")"
        sudo htpasswd -cBb "$BASIC_AUTH_FILE" "$HTTP_USERNAME" "$HTTP_PASSWORD"
        sudo chown root:root "$BASIC_AUTH_FILE"
        sudo chmod 640 "$BASIC_AUTH_FILE"
        log "Traefik basic auth credentials set."
        ;;

      authentik)
        AUTH_SECRET_FILE="$SECRETS_DIR/authentik_secret_key"
        AUTH_PASS_FILE="$SECRETS_DIR/authentik_postgres_password"
        if [[ ! -f "$AUTH_SECRET_FILE" ]]; then
          AUTH_SECRET=$(openssl rand -base64 60 | tr -d '\n')
          echo "$AUTH_SECRET" | sudo tee "$AUTH_SECRET_FILE" > /dev/null
          sudo chmod 600 "$AUTH_SECRET_FILE"
          sudo chown "$USER_MARTIAL":"$USER_MARTIAL" "$AUTH_SECRET_FILE"
          log "Authentik secret key generated."
        fi
        if [[ ! -f "$AUTH_PASS_FILE" ]]; then
          AUTH_PASS=$(openssl rand -base64 60 | tr -d '\n')
          echo "$AUTH_PASS" | sudo tee "$AUTH_PASS_FILE" > /dev/null
          sudo chmod 600 "$AUTH_PASS_FILE"
          sudo chown "$USER_MARTIAL":"$USER_MARTIAL" "$AUTH_PASS_FILE"
          log "Authentik postgres password generated."
        else
          AUTH_PASS=$(cat "$AUTH_PASS_FILE")
        fi

        if [[ -n "$POSTGRES_CONT" ]]; then
          postgres_create_db "authentik" "$POSTGRES_CONT"
          postgres_create_user "authentik_db_user" "$AUTH_PASS" "$POSTGRES_CONT"
          postgres_exec "GRANT ALL PRIVILEGES ON DATABASE authentik TO authentik_db_user;" "$POSTGRES_CONT"
          postgres_exec "ALTER DATABASE authentik OWNER TO authentik_db_user;" "$POSTGRES_CONT"
          postgres_exec "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO authentik_db_user;" "$POSTGRES_CONT"
          postgres_exec "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO authentik_db_user;" "$POSTGRES_CONT"
          postgres_exec "GRANT CREATE ON SCHEMA public TO authentik_db_user;" "$POSTGRES_CONT"
        else
          log "Warning: Cannot configure authentik DB; PostgreSQL container not found."
        fi
        ;;

      mariadb)
        MARIADB_PASS_FILE="$SECRETS_DIR/mariadb_root_password"
        if [[ ! -f "$MARIADB_PASS_FILE" ]]; then
          MARIADB_PASS=$(openssl rand -base64 60 | tr -d '\n')
          echo "$MARIADB_PASS" | sudo tee "$MARIADB_PASS_FILE" > /dev/null
          sudo chmod 600 "$MARIADB_PASS_FILE"
          sudo chown "$USER_MARTIAL":"$USER_MARTIAL" "$MARIADB_PASS_FILE"
          log "MariaDB root password generated."
        else
          log "MariaDB root password file exists."
        fi
        ;;

      nextcloud)
        NEXTCLOUD_PASS_FILE="$SECRETS_DIR/nextcloud_admin_password"
        if [[ ! -f "$NEXTCLOUD_PASS_FILE" ]]; then
          sudo touch "$NEXTCLOUD_PASS_FILE"
          sudo chmod 600 "$NEXTCLOUD_PASS_FILE"
          sudo chown "$USER_MARTIAL":"$USER_MARTIAL" "$NEXTCLOUD_PASS_FILE"
          echo "Please enter the Nextcloud admin password (input hidden):"
          while true; do
            read -r -s -p "Password: " NC_PASS_1
            echo ""
            read -r -s -p "Confirm Password: " NC_PASS_2
            echo ""
            if [[ "$NC_PASS_1" == "$NC_PASS_2" ]] && [[ -n "$NC_PASS_1" ]]; then
              echo "$NC_PASS_1" | sudo tee "$NEXTCLOUD_PASS_FILE" > /dev/null
              log "Nextcloud admin password saved."
              break
            else
              echo "Passwords do not match or empty, please try again."
            fi
          done
        else
          log "Nextcloud admin password file exists."
        fi
        ;;

      # Add additional app-specific secret setup here as needed

      *)
        log "No special setup required for $app"
        ;;
    esac
  done
}

# ============================================
# UPDATE docker-compose-vm.yml WITH SELECTED APPS (INCLUDE entries)
update_compose_main() {
  log "Updating $MAIN_COMPOSE with selected apps..."

  # Backup existing main compose file first
  sudo cp "$MAIN_COMPOSE" "$MAIN_COMPOSE.bak.$(date +%Y%m%d%H%M%S)" || {
    log "Failed to backup $MAIN_COMPOSE"
  }

  # Remove existing include entries for apps (to avoid duplicates)
  # We only want to keep non-app include entries if any, so better parse carefully.
  # Here, a simple approach is to remove all lines starting with "  - compose/<hostname>/*.yml"
  # leaving other include entries intact.

  sudo sed -i "/^[[:space:]]*-[[:space:]]*compose\/$HOSTNAME\/.*\.yml$/d" "$MAIN_COMPOSE"

  # Insert include lines just below the existing 'include:' key line
  INCLUDE_LINE="include:"
  if ! grep -q "^include:" "$MAIN_COMPOSE"; then
    # Add include: block near the end if missing
    echo -e "\ninclude:" | sudo tee -a "$MAIN_COMPOSE" > /dev/null
  fi

  # Append selected app includes
  for app in "${unique_apps[@]}"; do
    YAML_PATH="compose/$HOSTNAME/${app}.yml"
    if [[ -f "$COMPOSE_DIR/${app}.yml" ]]; then
      # Check that line not already present before appending just in case
      if ! grep -q "^[[:space:]]*-[[:space:]]*$YAML_PATH" "$MAIN_COMPOSE"; then
        echo "  - $YAML_PATH" | sudo tee -a "$MAIN_COMPOSE" > /dev/null
        log "Added app include for $app"
      else
        log "Include entry for $app already present in $MAIN_COMPOSE"
      fi
    else
      log "WARNING: Compose YAML file for app '$app' not found in $COMPOSE_DIR"
    fi
  done
}

# ============================================
# SCRIPT MAIN LOOP
main() {
  log "Starting setup script..."

  check_prerequisites
  install_packages

  while true; do
    echo "==== App Selection ===="
    select_apps || continue

    if ! enforce_dependencies; then
      # User declined dependencies, start over
      continue
    fi

    generate_secrets_and_setup

    update_compose_main

    echo ""
    log "Setup complete."
    echo "Run your stack with:"
    echo "  docker compose up -d"
    echo "(The include plugin will automatically load your included Compose files.)"
    echo ""

    while true; do
      read -r -p "Exit the setup script? [y/N]: " exit_choice
      case "$exit_choice" in
        [Yy]* )
          log "User chose to exit. Goodbye."
          exit 0
          ;;
        [Nn]* | "" )
          echo "Restarting app selection..."
          break
          ;;
        * )
          echo "Please enter 'y' or 'n'."
          ;;
      esac
    done
  done
}

main "$@"

