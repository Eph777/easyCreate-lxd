# Shared by create-vm.sh and publish-sites.sh, not meant to be run on its own

# ufw translates its output, which is parsed below
export LC_ALL=C

# The VM that receives ports 80 and 443 and sends each domain to the right VM
PROXY_VM=proxy
PARTIAL_VMS=""

die() {
  echo "$*" >&2
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (try: sudo $0)"
fi

if ! command -v lxc >/dev/null; then
  die "LXD is not installed (try: snap install lxd, then lxd init)"
fi

on_exit() {
  local status=$? vm
  if [[ $status -ne 0 ]]; then
    for vm in $PARTIAL_VMS; do
      echo "Setup stopped before finishing, so $vm is only partly configured." >&2
      echo "To remove it and start again: lxc delete $vm --force" >&2
    done
  fi
}
trap on_exit EXIT

ask() {
  local var=$1 prompt=$2 default=${3:-} reply
  if [[ -n $default ]]; then
    read -rp "$prompt [$default]: " reply
  else
    read -rp "$prompt: " reply
  fi
  printf -v "$var" '%s' "${reply:-$default}"
}

ask_valid() {
  local var=$1 prompt=$2 default=$3 check=$4
  while true; do
    ask "$var" "$prompt" "$default"
    if "$check" "${!var}"; then
      return 0
    fi
  done
}

is_ipv4() {
  [[ $1 =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
  local octet
  for octet in ${1//./ }; do
    if ((octet > 255)); then
      return 1
    fi
  done
}

ip_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

int_to_ip() {
  echo "$((($1 >> 24) & 255)).$((($1 >> 16) & 255)).$((($1 >> 8) & 255)).$(($1 & 255))"
}

ip_taken() {
  grep -Fxq "$1" <<<"$USED_IPS"
}

next_free_ip() {
  local n
  for ((n = NETWORK + 10; n < BROADCAST; n++)); do
    if ! ip_taken "$(int_to_ip "$n")"; then
      int_to_ip "$n"
      return 0
    fi
  done
}

# USED_PORTS holds single ports and ranges such as 4000-4999
port_taken() {
  local entry
  for entry in $USED_PORTS; do
    if (($1 >= ${entry%-*} && $1 <= ${entry#*-})); then
      return 0
    fi
  done
  return 1
}

next_free_port() {
  local port=$1
  while port_taken "$port"; do
    port=$((port + 1))
  done
  echo "$port"
}

is_running() {
  grep -Fxq "$1,RUNNING" <<<"$(lxc list -c ns --format csv)"
}

ufw_active() {
  command -v ufw >/dev/null && [[ "$(ufw status)" == *"Status: active"* ]]
}

check_vm_ip() {
  if ! is_ipv4 "$1"; then
    echo "That is not a valid IP address."
    return 1
  fi
  local ip_int
  ip_int=$(ip_to_int "$1")
  if ((ip_int <= NETWORK || ip_int >= BROADCAST)); then
    echo "The IP must be inside $BRIDGE_CIDR."
    return 1
  fi
  if ip_taken "$1"; then
    echo "$1 is already used."
    return 1
  fi
}

check_server_ip() {
  if ! grep -Fxq "$1" <<<"$SERVER_IPS"; then
    echo "$1 is not on this server. Addresses found:" $SERVER_IPS
    return 1
  fi
}

check_port() {
  if [[ ! $1 =~ ^[1-9][0-9]{0,4}$ ]] || (($1 > 65535)); then
    echo "Use a port from 1 to 65535."
    return 1
  fi
}

check_app_port() {
  check_port "$1" || return 1
  if [[ $1 == 22 ]]; then
    echo "Port 22 is SSH, use the port your service listens on."
    return 1
  fi
}

check_domain() {
  if [[ ! $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    echo "Use a lowercase domain name like site.com or api.site.com."
    return 1
  fi
  if grep -Fxq "$1" <<<"$USED_DOMAINS"; then
    echo "$1 is already published."
    return 1
  fi
}

check_email() {
  if [[ ! $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "Use an email address like you@example.com."
    return 1
  fi
}

wait_for_vm() {
  local attempts=0
  echo "Waiting for $1 to boot..."
  until lxc exec "$1" -- true 2>/dev/null; do
    attempts=$((attempts + 1))
    if ((attempts >= 90)); then
      die "$1 did not boot within 3 minutes (see: lxc info $1 --show-log)"
    fi
    sleep 2
  done
  # cloud-init exits with 2 on recoverable errors, which don't stop the setup
  lxc exec "$1" -- cloud-init status --wait >/dev/null || true
}

# Finds the bridge VMs attach to, and the IPs and ports already used on this server
scan_server() {
  local instance devices

  # The profile names the bridge under "network" or "parent", depending on how it was set up
  BRIDGE=$(lxc profile device get default eth0 network 2>/dev/null || true)
  if [[ -z $BRIDGE ]]; then
    BRIDGE=$(lxc profile device get default eth0 parent 2>/dev/null || true)
  fi
  if [[ -z $BRIDGE ]]; then
    lxc network list >&2
    die "The default profile has no eth0 network device. Has 'lxd init' been run?"
  fi

  BRIDGE_CIDR=$(ip -4 -o addr show dev "$BRIDGE" | awk 'NR == 1 {print $4}' || true)
  if [[ ! $BRIDGE_CIDR =~ ^([0-9.]+)/([0-9]+)$ ]]; then
    lxc network list >&2
    die "Bridge $BRIDGE has no IPv4 address on this server."
  fi
  GATEWAY=${BASH_REMATCH[1]}
  PREFIX=${BASH_REMATCH[2]}
  MASK=$(((0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF))
  NETWORK=$(($(ip_to_int "$GATEWAY") & MASK))
  BROADCAST=$((NETWORK | (~MASK & 0xFFFFFFFF)))

  USED_IPS=$GATEWAY
  USED_PORTS=$(ss -Htln | awk '{print $4}' | sed 's/.*://' | tr '\n' ' ')
  for instance in $(lxc list -c n --format csv); do
    devices=$(lxc config device show "$instance")
    USED_IPS+=$'\n'$(sed -n 's/^ *ipv4.address: //p' <<<"$devices")
    USED_PORTS+=" "$(sed -n 's/^ *listen: [a-z]*:.*:\([0-9,-]*\)$/\1/p' <<<"$devices" | tr ',\n' '  ')
  done
  USED_IPS+=$'\n'$(lxc list -c 4 --format csv | grep -oE '([0-9]+\.){3}[0-9]+' || true)

  SERVER_IPS=$(ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1)
  DEFAULT_SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' || true)
}

# Sets NEW_PROXY, PROXY_IP and USED_DOMAINS, and asks what a new proxy VM needs
ask_proxy() {
  if lxc info "$PROXY_VM" >/dev/null 2>&1; then
    if ! is_running "$PROXY_VM"; then
      die "The $PROXY_VM VM exists but isn't running (start it with: lxc start $PROXY_VM)"
    fi
    PROXY_IP=$(lxc config device get "$PROXY_VM" eth0 ipv4.address 2>/dev/null || true)
    if [[ -z $PROXY_IP ]]; then
      die "The $PROXY_VM VM has no fixed IP, so other VMs can't be published through it."
    fi
    NEW_PROXY=no
    USED_DOMAINS=$(lxc exec "$PROXY_VM" -- sh -c 'cat /etc/caddy/sites/*.caddy 2>/dev/null' | sed -n 's/^\([^ {]*\) {$/\1/p' || true)
    echo "Using the existing reverse proxy VM $PROXY_VM ($PROXY_IP)."
  else
    if port_taken 80 || port_taken 443; then
      die "Ports 80 or 443 are already used on this server, by a service or by another instance's proxy device. If you set up Caddy inside a VM earlier, remove that VM's http and https devices first (see: lxc config device show <name>)."
    fi
    NEW_PROXY=yes
    USED_DOMAINS=""
    echo "There is no reverse proxy VM yet. It will be created as $PROXY_VM (1GiB RAM, 1 CPU) and receive ports 80 and 443."
    ask_valid PROXY_IP "Proxy VM IP (inside $BRIDGE_CIDR)" "$(next_free_ip)" check_vm_ip
    USED_IPS+=$'\n'$PROXY_IP
    if [[ -z ${SERVER_IP:-} ]]; then
      ask_valid SERVER_IP "Server IP to listen on" "$DEFAULT_SERVER_IP" check_server_ip
    fi
    ask_valid EMAIL "Email for Let's Encrypt certificate notices" "" check_email
  fi
}

# Sets SITES to one "domain port" line per site
ask_sites() {
  SITES=""
  while true; do
    ask DOMAIN "Domain to publish (empty to finish)"
    if [[ -z $DOMAIN ]]; then
      if [[ -n $SITES ]]; then
        break
      fi
      echo "Add at least one domain."
      continue
    fi
    if ! check_domain "$DOMAIN"; then
      continue
    fi
    ask_valid APP_PORT "Port of the service for $DOMAIN inside the VM" "" check_app_port
    SITES+="$DOMAIN $APP_PORT"$'\n'
    USED_DOMAINS+=$'\n'$DOMAIN
  done
}

app_ports() {
  awk '{print $2}' <<<"$SITES" | sort -un | tr '\n' ' '
}

# ufw rules that let only the proxy VM reach the services inside the VM
vm_proxy_rules() {
  local port rules=""
  for port in $(app_ports); do
    rules+="${rules:+ && }ufw allow proto tcp from $PROXY_IP to any port $port"
  done
  echo "$rules"
}

print_sites_summary() {
  local domain port
  if [[ $NEW_PROXY == "yes" ]]; then
    echo "Proxy:     new VM $PROXY_VM at $PROXY_IP, receiving $SERVER_IP:80 and :443"
  else
    echo "Proxy:     existing VM $PROXY_VM at $PROXY_IP"
  fi
  while read -r domain port; do
    if [[ -n $domain ]]; then
      echo "Site:      https://$domain -> $VM_IP:$port"
    fi
  done <<<"$SITES"
}

create_proxy() {
  echo "Creating the reverse proxy VM $PROXY_VM..."
  lxc init "ubuntu:${VERSION:-24.04}" "$PROXY_VM" --vm -c limits.memory=1GiB -c limits.cpu=1 -c boot.autostart=true
  PARTIAL_VMS+=" $PROXY_VM"
  lxc config device override "$PROXY_VM" eth0 ipv4.address="$PROXY_IP"
  lxc config device add "$PROXY_VM" http proxy \
    listen=tcp:"$SERVER_IP":80 \
    connect=tcp:"$PROXY_IP":80 \
    nat=true
  lxc config device add "$PROXY_VM" https proxy \
    listen=tcp:"$SERVER_IP":443 \
    connect=tcp:"$PROXY_IP":443 \
    nat=true
  lxc start "$PROXY_VM"
  wait_for_vm "$PROXY_VM"

  echo "Installing Caddy..."
  lxc exec "$PROXY_VM" -- sh -ec "
    apt-get update
    apt-get install -y curl gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
    mkdir -p /etc/caddy/sites"

  # Each VM gets its own file in /etc/caddy/sites, so removing a VM means removing one file
  printf '{\n\temail %s\n}\n\nimport /etc/caddy/sites/*.caddy\n' "$EMAIL" |
    lxc exec "$PROXY_VM" -- sh -c "cat > /etc/caddy/Caddyfile"
  PARTIAL_VMS=${PARTIAL_VMS/ $PROXY_VM/}
}

open_host_firewall() {
  local port
  if ! ufw_active; then
    return 0
  fi
  if [[ $NEW_PROXY == "yes" ]]; then
    ufw route allow proto tcp to "$PROXY_IP" port 80,443
  fi
  for port in $(app_ports); do
    ufw route allow proto tcp from "$PROXY_IP" to "$VM_IP" port "$port"
  done
}

# Adds the sites to the VM's file on the proxy, and puts the old file back if Caddy rejects it
publish_sites() {
  local domain port previous config="" output file=/etc/caddy/sites/$VM.caddy
  previous=$(lxc exec "$PROXY_VM" -- sh -c "cat $file 2>/dev/null" || true)
  if [[ -n $previous ]]; then
    config=$previous$'\n\n'
  fi
  while read -r domain port; do
    if [[ -n $domain ]]; then
      config+=$(printf '%s {\n\treverse_proxy %s:%s\n}' "$domain" "$VM_IP" "$port")$'\n\n'
    fi
  done <<<"$SITES"

  printf '%s' "$config" | lxc exec "$PROXY_VM" -- sh -c "cat > $file"
  if ! output=$(lxc exec "$PROXY_VM" -- caddy validate --config /etc/caddy/Caddyfile 2>&1); then
    echo "$output" >&2
    if [[ -n $previous ]]; then
      printf '%s\n' "$previous" | lxc exec "$PROXY_VM" -- sh -c "cat > $file"
    else
      lxc exec "$PROXY_VM" -- rm -f "$file"
    fi
    die "Caddy rejected the configuration, so nothing was published. The previous configuration was kept."
  fi
  lxc exec "$PROXY_VM" -- systemctl reload caddy
}

print_sites_instructions() {
  local domain port
  echo "Sites published through $PROXY_VM:"
  while read -r domain port; do
    if [[ -n $domain ]]; then
      echo "  https://$domain -> port $port in $VM"
    fi
  done <<<"$SITES"
  echo
  echo "For HTTPS to work:"
  echo "  - Each domain needs a DNS A record pointing to the server's public IP, and no AAAA record."
  echo "  - Each service must listen on 0.0.0.0 inside $VM, so that $PROXY_VM can reach it."
  if [[ $NEW_PROXY == "yes" ]]; then
    echo "  - If your hosting provider has a firewall, allow TCP ports 80 and 443 there."
  fi
}
