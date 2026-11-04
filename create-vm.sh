#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/common.sh"

to_mib() {
  local size=${1%?iB}
  if [[ $1 == *GiB ]]; then
    size=$((size * 1024))
  fi
  echo "$size"
}

check_name() {
  if [[ ! $1 =~ ^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo "Use letters, numbers and hyphens, starting with a letter."
    return 1
  fi
  if [[ $1 == "$PROXY_VM" ]]; then
    echo "$PROXY_VM is reserved for the reverse proxy VM."
    return 1
  fi
  if lxc info "$1" >/dev/null 2>&1; then
    echo "An instance named $1 already exists."
    return 1
  fi
}

check_user() {
  if [[ ! $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Use lowercase letters, numbers, hyphens and underscores."
    return 1
  fi
  if [[ $1 == "root" || $1 == "ubuntu" ]]; then
    echo "$1 already exists in the VM, choose another name."
    return 1
  fi
}

check_version() {
  if [[ ! $1 =~ ^[0-9]{2}\.[0-9]{2}$ ]]; then
    echo "Use a version like 24.04."
    return 1
  fi
}

check_size() {
  if [[ ! $1 =~ ^[1-9][0-9]*(MiB|GiB)$ ]]; then
    echo "Use a size like 4GiB or 512MiB."
    return 1
  fi
}

check_ram() {
  check_size "$1" || return 1
  if (($(to_mib "$1") >= TOTAL_MIB)); then
    echo "The server only has $TOTAL_MIB MiB of RAM."
    return 1
  fi
}

check_cpus() {
  if [[ ! $1 =~ ^[1-9][0-9]*$ ]] || (($1 > $(nproc))); then
    echo "Use a number from 1 to $(nproc)."
    return 1
  fi
}

check_ssh_port() {
  check_port "$1" || return 1
  if port_taken "$1"; then
    echo "Port $1 is already used on this server."
    return 1
  fi
}

ask_password() {
  local first second
  while true; do
    IFS= read -rsp "Password for $VM_USER (empty to generate one): " first
    echo
    if [[ -z $first ]]; then
      VM_PASSWORD=$(openssl rand -base64 18)
      PASSWORD_GENERATED=yes
      return 0
    fi
    if ((${#first} < 16)); then
      echo "Use at least 16 characters, because this port is open to the internet."
      continue
    fi
    IFS= read -rsp "Confirm the password: " second
    echo
    if [[ $first == "$second" ]]; then
      VM_PASSWORD=$first
      PASSWORD_GENERATED=no
      return 0
    fi
    echo "The passwords don't match."
  done
}

scan_server
TOTAL_MIB=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
AVAILABLE_MIB=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
POOL=$(lxc profile device get default root pool)

echo "Server: $AVAILABLE_MIB MiB of RAM available out of $TOTAL_MIB MiB, $(nproc) CPUs"
echo "Storage pool $POOL:"
lxc storage info "$POOL" | grep -E 'space used|total space' || true
echo "Existing instances:"
lxc list
echo

ask_valid VM "VM name" "" check_name
ask_valid VM_USER "SSH username" "" check_user
ask_password
ask_valid VERSION "Ubuntu version" "24.04" check_version
ask_valid RAM "RAM" "4GiB" check_ram
ask_valid CPUS "CPUs" "2" check_cpus
ask_valid DISK "Disk" "20GiB" check_size
ask_valid VM_IP "VM IP (inside $BRIDGE_CIDR)" "$(next_free_ip)" check_vm_ip
USED_IPS+=$'\n'$VM_IP
ask_valid SSH_PORT "SSH port on the server" "$(next_free_port 2222)" check_ssh_port
ask_valid SERVER_IP "Server IP to listen on" "$DEFAULT_SERVER_IP" check_server_ip
ask VM_SUDO "Give $VM_USER admin rights (sudo) inside the VM? (y/N)" "n"

ask WEB "Publish web services from this VM through the reverse proxy? (y/N)" "n"
SITES=""
NEW_PROXY=no
if [[ $WEB =~ ^[yY] ]]; then
  ask_proxy
  ask_sites
fi

cat <<EOF

Name:      $VM
Image:     ubuntu:$VERSION
RAM:       $RAM
CPUs:      $CPUS
Disk:      $DISK
VM IP:     $VM_IP
SSH user:  $VM_USER
SSH port:  $SERVER_IP:$SSH_PORT -> $VM_IP:22
EOF
if [[ -n $SITES ]]; then
  print_sites_summary
fi
echo
ask CONFIRM "Create this VM? (y/N)" "n"
if [[ ! $CONFIRM =~ ^[yY] ]]; then
  echo "Nothing was created."
  exit 0
fi

if [[ $NEW_PROXY == "yes" ]]; then
  create_proxy
fi

lxc init "ubuntu:$VERSION" "$VM" --vm -c limits.memory="$RAM" -c limits.cpu="$CPUS" -c boot.autostart=true
PARTIAL_VMS+=" $VM"
lxc config device override "$VM" root size="$DISK"
lxc config device override "$VM" eth0 ipv4.address="$VM_IP"
lxc config device add "$VM" ssh-forward proxy \
  listen=tcp:"$SERVER_IP":"$SSH_PORT" \
  connect=tcp:"$VM_IP":22 \
  nat=true
lxc start "$VM"
wait_for_vm "$VM"

echo "Creating user $VM_USER..."
lxc exec "$VM" -- useradd -m -s /bin/bash "$VM_USER"
printf '%s:%s\n' "$VM_USER" "$VM_PASSWORD" | lxc exec "$VM" -- chpasswd
if [[ $VM_SUDO =~ ^[yY] ]]; then
  lxc exec "$VM" -- usermod -aG sudo "$VM_USER"
fi

# Ubuntu cloud images block password login, so allow it for this user only.
# /run/sshd doesn't exist until SSH has started once, and sshd -t needs it.
lxc exec "$VM" -- sh -c "printf '\nMatch User $VM_USER\n    PasswordAuthentication yes\n' >> /etc/ssh/sshd_config && mkdir -p /run/sshd && sshd -t && systemctl restart ssh"

echo "Installing fail2ban..."
lxc exec "$VM" -- sh -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban ufw"

# Only SSH and, for each service, the proxy VM may connect to this VM
if [[ -n $SITES ]]; then
  lxc exec "$VM" -- sh -c "ufw allow 22/tcp && $(vm_proxy_rules) && ufw --force enable"
fi

if ufw_active; then
  ufw route allow proto tcp to "$VM_IP" port 22
fi

if [[ -n $SITES ]]; then
  open_host_firewall
  echo "Publishing the sites on $PROXY_VM..."
  publish_sites
fi
PARTIAL_VMS=${PARTIAL_VMS/ $VM/}

if ! timeout 5 bash -c "exec 3<>/dev/tcp/$VM_IP/22"; then
  echo "Warning: SSH is not answering on $VM_IP:22 yet." >&2
fi
sleep 3
if ! lxc exec "$VM" -- fail2ban-client status sshd >/dev/null 2>&1; then
  echo "Warning: fail2ban is not watching SSH (check: lxc exec $VM -- fail2ban-client status sshd)." >&2
fi

echo
echo "$VM is ready. Connect with:"
echo
echo "  ssh -p $SSH_PORT $VM_USER@$SERVER_IP"
echo
if [[ $PASSWORD_GENERATED == "yes" ]]; then
  echo "Generated password (shown only once): $VM_PASSWORD"
  echo
fi
echo "If the server's public IP is different from $SERVER_IP, connect to the public IP instead."
echo "If your hosting provider has a firewall, allow TCP port $SSH_PORT there."

if [[ -n $SITES ]]; then
  echo
  print_sites_instructions
fi
