#!/bin/bash

# Set locale to UTF-8 if available
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
  echo "No UTF-8 locale found"
else
  export LC_ALL="$utf8_locale"
  export LANG="$utf8_locale"
  export LANGUAGE="$utf8_locale"
  echo "Locale set to $utf8_locale"
fi

# Ensure /usr/local/bin exists
if [ ! -d "/usr/local/bin" ]; then
  mkdir -p /usr/local/bin
fi

# Define container name
NAME='proxyrack'

# Function to print messages in color
red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
reading() { read -rp "$(green "$1")" "$2"; }

# Ensure the script is run as root
check_root() {
  [[ $(id -u) != 0 ]] && red "The script must be run as root. Please use sudo." && exit 1
}

# Determine the operating system and package manager
check_operating_system() {
  SYS=$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)
  if [[ -z "$SYS" ]]; then
    SYS=$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)
  fi

  if [[ "$SYS" =~ [Uu]buntu|[Dd]ebian|[Rr]aspbian|[Aa]rmbian ]]; then
    PACKAGE_UPDATE="apt -y update"
    PACKAGE_INSTALL="apt -y install"
  elif [[ "$SYS" =~ [Cc]entOS|[Rr]ed[ \t][Hh]at|[Ff]edora|[Rr]ocky|[Aa]lma ]]; then
    PACKAGE_UPDATE="yum -y update"
    PACKAGE_INSTALL="yum -y install"
  elif [[ "$SYS" =~ [Aa]lpine ]]; then
    PACKAGE_UPDATE="apk update"
    PACKAGE_INSTALL="apk add"
  else
    red "Unsupported operating system: $SYS"
    exit 1
  fi
}

# Check for IPv4 connectivity
check_ipv4() {
  if ! curl -s4m8 https://api.ipify.org >/dev/null; then
    red "ERROR: The host must have IPv4 connectivity."
    exit 1
  fi
}

# Determine CPU architecture and set Docker image accordingly
check_architecture() {
  ARCHITECTURE=$(uname -m)
  case "$ARCHITECTURE" in
    x86_64|amd64)
      DOCKER_IMAGE="proxyrack/pop:latest"
      ;;
    armv7l)
      DOCKER_IMAGE="proxyrack/pop:arm32v7"
      ;;
    aarch64|arm64)
      DOCKER_IMAGE="proxyrack/pop:arm64v8"
      ;;
    *)
      red "ERROR: Unsupported architecture: $ARCHITECTURE"
      exit 1
      ;;
  esac
}

# Prompt for Proxyrack API token
input_token() {
  if [ -z "$PRTOKEN" ]; then
    reading "Enter your Proxyrack API Key: " PRTOKEN
  fi
}

# Build and run the Docker container
container_build() {
  green "Installing Docker..."

  # Install Docker if not already installed
  if ! command -v docker &>/dev/null; then
    $PACKAGE_UPDATE
    $PACKAGE_INSTALL docker.io || $PACKAGE_INSTALL docker
    systemctl enable --now docker
  fi

  # Remove existing container if it exists
  if docker ps -a --format '{{.Names}}' | grep -qw "$NAME"; then
    yellow "Removing existing proxyrack container..."
    docker rm -f "$NAME"
  fi

  # Generate unique identifiers
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "$UUID" >/usr/local/bin/proxyrack_uuid
  DNAME="proxyrack-$(date +%s)"
  echo "$DNAME" >/usr/local/bin/proxyrack_dname

  # Pull and run the Docker container
  green "Creating the proxyrack container..."
  docker pull "$DOCKER_IMAGE"
  docker run -d --name "$NAME" --restart always -e UUID="$UUID" "$DOCKER_IMAGE"

  # Register the device with Proxyrack
  green "Registering device with Proxyrack..."
  response=$(curl -s -X POST https://peer.proxyrack.com/api/device/add \
    -H "Api-Key: $PRTOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{\"device_id\":\"$UUID\",\"device_name\":\"$DNAME\"}")
  if [[ "$response" == '{"success":true}' ]]; then
    green "Device registered successfully."
  else
    red "Failed to register device. Response: $response"
  fi

  # Set up Watchtower for automatic updates
  if ! docker ps -a --format '{{.Names}}' | grep -qw "watchtower"; then
    yellow "Setting up Watchtower for automatic updates..."
    docker run -d --name watchtower --restart always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      containrrr/watchtower --cleanup
  fi
}

# Display installation result
result() {
  sleep 5
  if docker ps -a --format '{{.Names}}' | grep -qw "$NAME"; then
    green "Installation successful."
    green "Device ID: $(cat /usr/local/bin/proxyrack_uuid)"
    green "Device Name: $(cat /usr/local/bin/proxyrack_dname)"
  else
    red "Installation failed."
  fi
}

# Uninstall the Proxyrack container and image
uninstall() {
  UUID=$(cat /usr/local/bin/proxyrack_uuid)
  docker rm -f "$NAME"
  docker rmi -f "$DOCKER_IMAGE"
  curl -s -X POST https://peer.proxyrack.com/api/device/delete \
    -H "Api-Key: $PRTOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{\"device_id\":\"$UUID\"}"
  green "Uninstallation complete."
  exit 0
}

# Parse command-line options
while getopts "uT:t:" OPT; do
  case "$OPT" in
    u) uninstall ;;
    T|t) PRTOKEN=$OPTARG ;;
    *) red "Invalid option: -$OPTARG" ;;
  esac
done

# Main script execution
check_root
check_operating_system
check_ipv4
check_architecture
input_token
container_build
result
