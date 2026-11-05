#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/common.sh"

check_existing_vm() {
  if [[ $1 == "$PROXY_VM" ]]; then
    echo "$PROXY_VM is the reverse proxy itself, choose the VM that runs the services."
    return 1
  fi
  if ! lxc info "$1" >/dev/null 2>&1; then
    echo "There is no instance named $1."
    return 1
  fi
  if ! is_running "$1"; then
    echo "$1 isn't running (start it with: lxc start $1)."
    return 1
  fi
}

# Ports forwarded from the server into the VM, such as "22/tcp", which must stay open
forwarded_ports() {
  lxc config device show "$VM" |
    sed -n 's/^ *connect: \([a-z]*\):.*:\([0-9,-]*\)$/\2 \1/p' |
    awk '{n = split($1, ports, ","); for (i = 1; i <= n; i++) print ports[i] "/" $2}' |
    tr '\n' ' '
}

vm_forward_rules() {
  local port rules=""
  for port in $(forwarded_ports); do
    rules+="${rules:+ && }ufw allow ${port/-/:}"
  done
  echo "$rules"
}

scan_server
echo "Existing instances:"
lxc list
echo

ask_valid VM "VM to publish" "" check_existing_vm

VM_IP=$(lxc config device get "$VM" eth0 ipv4.address 2>/dev/null || true)
PIN_IP=no
if [[ -z $VM_IP ]]; then
  addresses=$(lxc list -c n4 --format csv)
  VM_IP=$(awk -F, -v vm="$VM" '$1 == vm && match($2, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) {print substr($2, RSTART, RLENGTH); exit}' <<<"$addresses")
  if [[ -z $VM_IP ]]; then
    die "$VM has no IPv4 address yet, so it can't be published."
  fi
  PIN_IP=yes
  echo "$VM has no fixed IP. The proxy needs one, so its current IP $VM_IP will be fixed, which restarts $VM once."
fi

ask_proxy
if [[ $PROXY_KIND == "caddy" ]]; then
  existing=$(lxc exec "$PROXY_VM" -- sh -c "cat /etc/caddy/sites/$VM.caddy 2>/dev/null" | sed -n 's/^\([^ {]*\) {$/\1/p' | tr '\n' ' ' || true)
  if [[ -n $existing ]]; then
    echo "Already published for $VM: $existing"
  fi
fi
ask_sites

VM_UFW=$(lxc exec "$VM" -- sh -c 'command -v ufw >/dev/null && LC_ALL=C ufw status' 2>/dev/null || true)
if [[ $VM_UFW == *"Status: active"* ]]; then
  VM_FIREWALL=add
else
  FORWARDED=$(forwarded_ports)
  FORWARDED=${FORWARDED% }
  echo
  echo "The firewall inside $VM is off, so other VMs on this server can reach all its services directly."
  echo "Turning it on allows the proxy VM and the ports forwarded from the server (${FORWARDED:-none}), and blocks every other incoming connection."
  ask ENABLE_FIREWALL "Turn on the firewall inside $VM? (y/N)" "n"
  if [[ $ENABLE_FIREWALL =~ ^[yY] ]]; then
    VM_FIREWALL=enable
  else
    VM_FIREWALL=skip
  fi
fi

echo
echo "VM:        $VM ($VM_IP)"
if [[ $PIN_IP == "yes" ]]; then
  echo "Fixed IP:  $VM_IP will be fixed, which restarts $VM"
fi
case $VM_FIREWALL in
  add) echo "Firewall:  the proxy VM is allowed in $VM's firewall" ;;
  enable) echo "Firewall:  turned on in $VM" ;;
  skip) echo "Firewall:  left off in $VM" ;;
esac
print_sites_summary
echo
ask CONFIRM "Publish these sites? (y/N)" "n"
if [[ ! $CONFIRM =~ ^[yY] ]]; then
  echo "Nothing was changed."
  exit 0
fi

if [[ $NEW_PROXY == "yes" ]]; then
  create_proxy
fi

if [[ $PIN_IP == "yes" ]]; then
  echo "Fixing the IP of $VM..."
  lxc stop "$VM"
  lxc config device override "$VM" eth0 ipv4.address="$VM_IP"
  lxc start "$VM"
  wait_for_vm "$VM"
fi

case $VM_FIREWALL in
  add)
    lxc exec "$VM" -- sh -c "$(vm_proxy_rules)"
    ;;
  enable)
    forward_rules=$(vm_forward_rules)
    lxc exec "$VM" -- sh -ec "
      command -v ufw >/dev/null || (apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ufw)
      ${forward_rules:+$forward_rules && }$(vm_proxy_rules) && ufw --force enable"
    ;;
esac

open_host_firewall
publish_on_proxy

echo
print_sites_instructions
if [[ $VM_FIREWALL == "skip" ]]; then
  echo "  - The firewall inside $VM is off, so other VMs on this server can still reach these services directly."
fi
