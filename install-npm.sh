#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/common.sh"

# Lists "domain -> target" for each site in Caddy's site files
caddy_sites_table() {
  awk '/^[^ \t].* \{$/ {domain = $1} $1 == "reverse_proxy" {print "  " domain "  ->  " $2}'
}

scan_server

if ! lxc info "$PROXY_VM" >/dev/null 2>&1; then
  ask_new_proxy
  echo
  ask CONFIRM "Create $PROXY_VM with Nginx Proxy Manager? (y/N)" "n"
  if [[ ! $CONFIRM =~ ^[yY] ]]; then
    echo "Nothing was changed."
    exit 0
  fi
  if ufw_active; then
    ufw route allow proto tcp to "$PROXY_IP" port 80,443
  fi
  create_proxy
  echo
  echo "$PROXY_VM is ready."
  echo
  print_npm_access
  echo "If your hosting provider has a firewall, allow TCP ports 80 and 443 there."
  exit 0
fi

if ! is_running "$PROXY_VM"; then
  die "The $PROXY_VM VM exists but isn't running (start it with: lxc start $PROXY_VM)"
fi
if proxy_uses_npm; then
  die "Nginx Proxy Manager is already installed on $PROXY_VM. To update it: lxc exec $PROXY_VM -- sh -c \"cd /opt/npm && docker compose pull && docker compose up -d\""
fi

# Keep a copy of the Caddy sites on the server, since they have to be added again in Nginx Proxy Manager
SITES_BACKUP=/root/caddy-sites-before-npm.txt
lxc exec "$PROXY_VM" -- sh -c 'cat /etc/caddy/sites/*.caddy 2>/dev/null' >"$SITES_BACKUP" || true
SITES_TABLE=$(caddy_sites_table <"$SITES_BACKUP")

echo "$PROXY_VM runs Caddy. Nginx Proxy Manager will replace it in the same VM, which keeps its IP,"
echo "its ports 80 and 443, and the firewall rules that let it reach your other VMs."
echo
if [[ -n $SITES_TABLE ]]; then
  echo "These sites will need to be added again in Nginx Proxy Manager:"
  echo "$SITES_TABLE"
  echo
  echo "They will be offline from the moment Caddy stops until you add them, usually a few minutes."
  echo "Docker and Nginx Proxy Manager are downloaded first, while the sites are still online."
else
  echo "No Caddy sites were found, so nothing goes offline."
fi
echo
ask CONFIRM "Replace Caddy with Nginx Proxy Manager on $PROXY_VM? (y/N)" "n"
if [[ ! $CONFIRM =~ ^[yY] ]]; then
  rm -f "$SITES_BACKUP"
  echo "Nothing was changed."
  exit 0
fi

SNAPSHOT=before-npm-$(date +%Y%m%d-%H%M%S)
echo "Taking a snapshot of $PROXY_VM ($SNAPSHOT)..."
lxc snapshot "$PROXY_VM" "$SNAPSHOT"

install_npm

FAILURE_HINT="To bring Caddy back: lxc exec $PROXY_VM -- sh -c 'cd /opt/npm && docker compose down; systemctl enable --now caddy'"
echo "Stopping Caddy..."
lxc exec "$PROXY_VM" -- sh -c "systemctl disable --now caddy || true"
start_npm
FAILURE_HINT=""

echo
echo "Nginx Proxy Manager is running on $PROXY_VM."
echo
print_npm_access
echo "On the first visit, create the admin account, or log in with admin@example.com / changeme and change both."
if [[ -n $SITES_TABLE ]]; then
  echo
  echo "Then add each site under Hosts > Proxy Hosts > Add Proxy Host, with Request a new SSL Certificate,"
  echo "Force SSL and HTTP/2 Support on the SSL tab. Use scheme https for targets starting with https://, http otherwise:"
  echo "$SITES_TABLE"
  echo
  echo "This list is saved in $SITES_BACKUP."
fi
echo
echo "To go back to Caddy:"
echo "  lxc exec $PROXY_VM -- sh -c 'cd /opt/npm && docker compose down; systemctl enable --now caddy'"
echo "The snapshot $SNAPSHOT also holds $PROXY_VM as it was before."
