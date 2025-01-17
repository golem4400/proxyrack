#!/bin/bash
# Script hỗ trợ kiến trúc armv7, armv8 và amd64

utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
  echo "No UTF-8 locale found"
else
  export LC_ALL="$utf8_locale"
  export LANG="$utf8_locale"
  export LANGUAGE="$utf8_locale"
  echo "Locale set to $utf8_locale"
fi

if [ ! -d "/usr/local/bin" ]; then
  mkdir -p /usr/local/bin
fi

# 定义容器名
NAME='proxyrack'

red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
reading() { read -rp "$(green "$1")" "$2"; }

check_root() {
  [[ $(id -u) != 0 ]] && red " The script must be run as root. Use sudo." && exit 1
}

check_operating_system() {
  SYS=$(uname -a)
  if [[ $SYS == *"Debian"* || $SYS == *"Ubuntu"* ]]; then
    PACKAGE_UPDATE="apt -y update"
    PACKAGE_INSTALL="apt -y install"
  elif [[ $SYS == *"CentOS"* || $SYS == *"Red Hat"* ]]; then
    PACKAGE_UPDATE="yum -y update"
    PACKAGE_INSTALL="yum -y install"
  else
    red "ERROR: Unsupported system." && exit 1
  fi
}

check_ipv4() {
  API_NET=("ip.sb" "ipget.net" "ip.ping0.cc")
  for p in "${API_NET[@]}"; do
    response=$(curl -s4m8 "$p")
    if [[ $? -eq 0 && $response != *"error"* ]]; then
      IP_API="$p"
      break
    fi
  done
  [[ -z "$IP_API" ]] && red "ERROR: No valid IP API found." && exit 1
}

check_virt() {
  ARCHITECTURE=$(uname -m)
  case "$ARCHITECTURE" in
  x86_64 | amd64) ARCH="latest" ;;
  aarch64) ARCH="arm64v8" ;;
  armv7l) ARCH="arm32v7" ;;
  *) red "ERROR: Unsupported architecture: $ARCHITECTURE" && exit 1 ;;
  esac
}

input_token() {
  [ -z "$PRTOKEN" ] && reading "Enter your API Key: " PRTOKEN
}

container_build() {
  green "Installing Docker..."
  if ! systemctl is-active docker >/dev/null 2>&1; then
    if [[ $PACKAGE_INSTALL ]]; then
      $PACKAGE_UPDATE
      $PACKAGE_INSTALL docker.io
    else
      red "Cannot install Docker. Ensure you have a compatible OS."
      exit 1
    fi
    systemctl enable --now docker
  fi

  docker ps -a | awk '{print $NF}' | grep -qw "$NAME" && \
    yellow "Removing old proxyrack container..." && \
    docker rm -f "$NAME"

  yellow "Creating the proxyrack container..."
  uuid=$(cat /dev/urandom | LC_ALL=C tr -dc 'A-F0-9' | dd bs=1 count=64 2>/dev/null)
  echo "${uuid}" >/usr/local/bin/proxyrack_uuid
  dname="device_$(date +%s)"
  echo "${dname}" >/usr/local/bin/proxyrack_dname

  docker pull proxyrack/pop:$ARCH
  docker run -d --name "$NAME" --restart always -e UUID="$uuid" proxyrack/pop:$ARCH

  echo "UUID: $uuid"
  curl -s \
    -X POST https://peer.proxyrack.com/api/device/add \
    -H "Api-Key: $PRTOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d '{"device_id":"'"$uuid"'","device_name":"'"$dname"'"}'
}

result() {
  docker ps -a | grep -q "$NAME" && \
    green "Device ID: $(cat /usr/local/bin/proxyrack_uuid)" && \
    green "Device Name: $(cat /usr/local/bin/proxyrack_dname)" && \
    green "Install success." || \
    red "Install failed."
}

uninstall() {
  uuid=$(cat /usr/local/bin/proxyrack_uuid)
  docker rm -f "$NAME"
  docker rmi -f proxyrack/pop
  curl -s \
    -X POST https://peer.proxyrack.com/api/device/delete \
    -H "Api-Key: $PRTOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{\"device_id\":\"$uuid\"}"
  green "Uninstalled successfully."
}

while getopts "UuT:t:" OPTNAME; do
  case "$OPTNAME" in
  'U' | 'u') uninstall ;;
  'T' | 't') PRTOKEN=$OPTARG ;;
  esac
done

check_root
check_operating_system
check_ipv4
check_virt
input_token
container_build
result
