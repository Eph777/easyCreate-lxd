# VM guide: create, open to SSH, monitor

How to create a VM on the server and give someone access to it, without giving them access to the server. Follow it once per VM.

These commands are for **LXD 4.0 on Ubuntu 20.04**, which is why ports are forwarded with proxy devices and not `lxc network forward`. After a move to Incus, replace `lxc` with `incus` and `lxdbr0` with `incusbr0`.

To do sections 1 to 5 in one go, run `sudo ./create-vm.sh` on the server. It asks for each value, then gives you the SSH command to hand over. It can also publish the VM's websites through the shared proxy VM (section 8). Section 7 onwards still applies to VMs created this way.

Each block says where to run it:

| Label | Machine |
|---|---|
| **Server** | The Ubuntu server running LXD, logged in over SSH |
| **Mac** | Your personal computer |
| **Inside the VM** | A shell opened with `sudo lxc shell <name>` |

## 1. Check there is room

**Server:**

```bash
free -h                            # RAM available on the server
sudo lxc storage info default      # disk space left in the storage pool
sudo lxc list                      # existing VMs and the IPs already used
```

Keep the RAM of all VMs added together below what the server has, with some left over for the server itself.

## 2. Choose the values for this VM

Four values must be different for every VM:

| Value | Why it must be unique | Example |
|---|---|---|
| Name | Identifies the VM in every command | `vm2` |
| VM IP | Two VMs can't share an address | `10.158.92.11` |
| SSH port | One server port can only lead to one VM | `2223` |
| App ports on the server | Same reason (see section 7) | `5556` |

**Server:** these two commands give you the values to build on.

```bash
sudo lxc network get lxdbr0 ipv4.address   # your subnet, e.g. 10.158.92.1/24
ip -br a                                   # the server IP on the main interface
```

A VM IP keeps the first three numbers of the subnet. Choose a last number from 2 to 254 that `lxc list` doesn't show.

Keep track of what you assign:

| VM | VM IP | SSH port | App ports | RAM | CPU | Disk | User |
|---|---|---|---|---|---|---|---|
| vm1 | | 2222 | | | | | |
| vm2 | | 2223 | | | | | |

## 3. Create and start the VM

**Server:** set the values for this VM. Run this first, and run everything after it in the same terminal.

```bash
VM=vm2
VM_USER=bob
VM_IP=10.158.92.11
SSH_PORT=2223
RAM=4GiB
CPUS=2
DISK=20GiB
SERVER_IP=203.0.113.25
```

**Server:** create the VM. `lxc init` creates it without starting it, so everything can be set up before the first boot and you avoid the stop/start that devices need on this LXD version.

```bash
sudo lxc init ubuntu:24.04 "$VM" --vm -c limits.memory="$RAM" -c limits.cpu="$CPUS"
sudo lxc config device override "$VM" root size="$DISK"
sudo lxc config device override "$VM" eth0 ipv4.address="$VM_IP"
sudo lxc config device add "$VM" ssh-forward proxy \
  listen=tcp:"$SERVER_IP":"$SSH_PORT" \
  connect=tcp:"$VM_IP":22 \
  nat=true
sudo lxc start "$VM"
```

**Server:** wait until the VM has finished booting. This usually takes under a minute. If it never returns, press Ctrl+C and check `sudo lxc info "$VM" --show-log`.

```bash
until sudo lxc exec "$VM" -- true 2>/dev/null; do sleep 2; done
sudo lxc exec "$VM" -- cloud-init status --wait
```

## 4. Create the user and allow password login

**Server:** create the account. It asks you to choose the password, and you can press Enter through the name questions.

```bash
sudo lxc exec "$VM" -- adduser "$VM_USER"
```

**Server:** allow password login for this user only. All other accounts stay key-only.

```bash
sudo lxc exec "$VM" -- sh -c "printf '\nMatch User $VM_USER\n    PasswordAuthentication yes\n' >> /etc/ssh/sshd_config && mkdir -p /run/sshd && sshd -t && systemctl restart ssh"
```

**Server:** only if this user needs to be admin of the VM. They stay limited to the VM.

```bash
sudo lxc exec "$VM" -- usermod -aG sudo "$VM_USER"
```

**Server:** install fail2ban, then check that it's watching SSH.

```bash
sudo lxc exec "$VM" -- sh -c "apt-get update && apt-get install -y fail2ban"
sudo lxc exec "$VM" -- fail2ban-client status sshd
```

## 5. Open the firewall

**Server:** allow forwarded traffic to the VM. The port here is the one **inside the VM** (22), not the server port.

```bash
sudo ufw route allow proto tcp to "$VM_IP" port 22
```

**Hosting provider's panel:** if it has a firewall, allow TCP on the server port (`2223` in this example).

## 6. Test, then hand over access

**Server:** test the VM directly. You should get a password prompt.

```bash
ssh "$VM_USER@$VM_IP"
```

**Mac:** test from outside, using the real values.

```bash
ssh -p 2223 bob@203.0.113.25
```

Give the person that command and their password. Use at least 16 random characters, because this port is open to the whole internet. Tell them that several wrong passwords in a row lock them out for about 10 minutes.

### Your own access (optional)

You can always get in from the server without any setup:

**Server:**

```bash
sudo lxc shell "$VM"
```

To connect directly from your Mac, add your key to the VM.

**Mac:** copy your public key.

```bash
pbcopy < ~/.ssh/id_ed25519.pub
```

**Server:** paste it in place of `PASTE_YOUR_KEY_HERE`.

```bash
sudo lxc exec "$VM" -- sh -c '
  mkdir -p /home/ubuntu/.ssh &&
  echo "PASTE_YOUR_KEY_HERE" >> /home/ubuntu/.ssh/authorized_keys &&
  chown -R ubuntu:ubuntu /home/ubuntu/.ssh &&
  chmod 700 /home/ubuntu/.ssh &&
  chmod 600 /home/ubuntu/.ssh/authorized_keys'
```

**Mac:** add one block per VM to `~/.ssh/config`. This assumes the `Host prod` block for the server is already there. After that, `ssh vm2` connects you through the server.

```
Host vm2
    HostName 10.158.92.11
    User ubuntu
    ProxyJump prod
```

## 7. Forward an app port (optional)

Use this for a service that isn't a website, or for quick tests. For public websites, use the proxy VM (section 8): it gives you HTTPS and normal addresses. Two VMs can use the same port inside, but each needs its own port on the server. Here port `5556` on the server leads to port `5555` in the VM.

**Server:** the VM must be stopped to add a device.

```bash
sudo lxc stop "$VM"
sudo lxc config device add "$VM" web-5555 proxy \
  listen=tcp:"$SERVER_IP":5556 \
  connect=tcp:"$VM_IP":5555 \
  nat=true
sudo lxc start "$VM"
sudo ufw route allow proto tcp to "$VM_IP" port 5555
```

Allow TCP `5556` in the hosting provider's firewall too. The site is then at `http://<server-ip>:5556/`.

The app must listen on `0.0.0.0`, not `127.0.0.1`. Check with `sudo lxc exec "$VM" -- ss -tlnp`.

## 8. Publish websites through the proxy VM

With a single server IP, ports 80 and 443 can only lead to one place. All websites therefore go through one VM, `proxy`, which runs **Nginx Proxy Manager** (NPM). NPM sends each domain to the right VM and gets HTTPS certificates, and you manage the domains in its web interface.

```
Internet ──> server :80/:443 ──> proxy VM (NPM) ──┬──> site.com      → vm2:5555
                                                   └──> api.site.com  → vm3:4444
```

### Setting up the proxy VM

**Server:**

```bash
sudo ./install-npm.sh
```

- **No proxy VM yet:** it creates `proxy` with NPM. `create-vm.sh` and `publish-sites.sh` also do this the first time you publish a site.
- **A proxy VM running Caddy** (set up before the switch to NPM): it replaces Caddy with NPM in the same VM. It takes a snapshot first, downloads NPM while the sites are still online, then lists the sites to add again in NPM, and saves that list in `/root/caddy-sites-before-npm.txt`.

### Opening the admin interface

The admin page only listens inside the proxy VM, so it's never exposed to the internet. Open it from your **Mac** through an SSH tunnel, using your SSH login to the proxy VM:

```bash
# with a password user and its port on the server
ssh -p 2230 -L 8181:127.0.0.1:81 alice@<server-public-ip>

# or with a "proxy-vm" entry in ~/.ssh/config
ssh -L 8181:127.0.0.1:81 proxy-vm
```

Keep that terminal open, then go to **http://localhost:8181**. On the first visit, create the admin account. If a login page appears instead, sign in with `admin@example.com` / `changeme` and change both.

### Adding a site

A site needs two things: the VM's firewall must let the proxy VM reach the service's port, and NPM needs to know where to send the domain. NPM can't change firewalls in other VMs, so the scripts do that part.

1. **Server:** run `sudo ./create-vm.sh` (for a new VM) or `sudo ./publish-sites.sh` (for an existing one) and enter the domains and ports. The script opens the firewall ports and prints what to enter in NPM.
2. **NPM:** go to **Hosts → Proxy Hosts → Add Proxy Host** and fill in:

| Tab | Field | Value |
|---|---|---|
| Details | Domain Names | `app.site.com` |
| Details | Scheme | `http`, or `https` if the service itself speaks HTTPS |
| Details | Forward Hostname / IP | The VM's IP |
| Details | Forward Port | The service's port |
| Details | Block Common Exploits | On |
| Details | Websockets Support | On if the app uses live updates. Harmless otherwise |
| SSL | SSL Certificate | Request a new SSL Certificate |
| SSL | Force SSL, HTTP/2 Support | On |

Click **Save**. The certificate takes a few seconds, and the site is online.

To open a port by hand instead of with the scripts, on the **server**:

```bash
sudo lxc exec vm2 -- ufw allow proto tcp from <proxy-ip> to any port 3000
sudo ufw route allow proto tcp from <proxy-ip> to <vm2-ip> port 3000
```

A site only works when all of these are true:

- The domain has a DNS **A record** pointing to the server's public IP, and **no AAAA record**.
- The service listens on `0.0.0.0` inside its VM.
- TCP 80 and 443 are allowed in the hosting provider's firewall.

### Maintaining NPM

All on the **server**:

| Task | Command |
|---|---|
| Check it's running | `sudo lxc exec proxy -- docker ps` |
| Read its log | `sudo lxc exec proxy -- docker logs --tail 50 npm` |
| Update it (snapshot first) | `sudo lxc snapshot proxy before-update` then `sudo lxc exec proxy -- sh -c "cd /opt/npm && docker compose pull && docker compose up -d"` |
| Go back to Caddy (after `install-npm.sh`) | `sudo lxc exec proxy -- sh -c 'cd /opt/npm && docker compose down; systemctl enable --now caddy'` |

NPM keeps its sites and certificates in `/opt/npm` inside the proxy VM, so snapshots of the VM back them up.

## 9. Monitor

**All VMs**, on the **server**:

```bash
sudo lxc list                 # state and IP of every VM
sudo lxc list -c ns4mDu       # adds memory, disk and CPU usage
```

**One VM**, on the **server**:

```bash
sudo lxc info vm2                         # state, resources and network
sudo lxc config show vm2                  # RAM, CPU and other settings
sudo lxc config device show vm2           # disk, IP and forwarded ports
sudo lxc exec vm2 -- free -h              # RAM seen inside the VM
sudo lxc exec vm2 -- df -h /              # disk seen inside the VM
sudo lxc exec vm2 -- uptime               # load and time since boot
```

**Who is connecting**, on the **server**:

```bash
sudo lxc exec vm2 -- who                           # logged in right now
sudo lxc exec vm2 -- last -n 10                    # recent logins
sudo lxc exec vm2 -- fail2ban-client status sshd   # banned IPs
```

**The server itself**, on the **server**:

```bash
free -h
df -h
sudo lxc storage info default
sudo lxc info --resources
```

## 10. Daily management

All on the **server**:

| Task | Command |
|---|---|
| Start, stop, restart | `sudo lxc start vm2`, `sudo lxc stop vm2`, `sudo lxc restart vm2` |
| Force a stuck VM to stop | `sudo lxc stop vm2 --force` |
| Open a shell | `sudo lxc shell vm2` |
| Open the console (leave with Ctrl+a, then q) | `sudo lxc console vm2` |
| Change the RAM or CPU (stop the VM first) | `sudo lxc config set vm2 limits.memory=8GiB limits.cpu=4` |
| Grow the disk (it can't shrink) | `sudo lxc config device set vm2 root size=40GiB` |
| Take a snapshot before a risky change | `sudo lxc snapshot vm2 before-change` |
| Go back to a snapshot | `sudo lxc restore vm2 before-change` |
| Reset a user's password | `sudo lxc exec vm2 -- passwd bob` |
| Unban an IP | `sudo lxc exec vm2 -- fail2ban-client set sshd unbanip <ip>` |

Disk growth usually applies after the next restart.

## 11. Remove access or delete a VM

All on the **server**.

Remove one person, and keep the VM:

```bash
sudo lxc exec vm2 -- deluser --remove-home bob
```

Close a forwarded port, and keep the VM:

```bash
sudo lxc stop vm2
sudo lxc config device remove vm2 ssh-forward
sudo lxc start vm2
```

Delete a VM. **This can't be undone:** its disk and snapshots are gone.

```bash
sudo lxc delete vm2 --force
sudo ufw status numbered       # find the VM's rules
sudo ufw delete <number>       # repeat for each; the numbers shift after each delete
```

If the VM had websites on the proxy VM, remove them too. Otherwise the proxy keeps answering those domains with errors. In NPM, open **Hosts → Proxy Hosts**, then use the **⋮** menu of each of the VM's hosts to delete it. If the proxy VM still runs Caddy, remove the VM's site file on the **server** instead:

```bash
sudo lxc exec proxy -- rm /etc/caddy/sites/vm2.caddy
sudo lxc exec proxy -- systemctl reload caddy
```

Don't delete the `proxy` VM itself while other VMs still have websites on it.

## 12. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `Connection timed out` from outside | A firewall is blocking the traffic | Redo section 5, including the hosting provider's firewall |
| `Connection refused` from outside, but `ssh` from the server works | fail2ban banned that IP (bans lift after about 10 minutes) | Run `fail2ban-client status sshd`, then unban the IP |
| `Connection refused` from the server too | SSH isn't running, or the IP is wrong | Check `sudo lxc list`, then `sudo lxc exec vm2 -- ss -tlnp` for `:22` |
| `Permission denied` with no password prompt | Password login isn't enabled for this user | Redo the password step in section 4 |
| `Permission denied` after typing the password | Wrong password | Reset it with `passwd` (section 10) |
| `Device cannot be added when instance is running` | LXD 4.0 needs the VM stopped | Stop the VM, add the device, start it |
| `VM agent isn't currently running` | The VM is still booting | Wait 30 seconds and try again |
| `unknown command "forward"` | LXD 4.0 doesn't have this command | Use a proxy device (section 3) |
| A website gets `Connection refused` | The app only listens on `127.0.0.1` | Make it listen on `0.0.0.0` |
| A proxied site shows `502 Bad Gateway` | The service isn't running, listens on `127.0.0.1` only, the VM's ufw blocks the proxy, or the scheme is wrong (`http` for a service that speaks HTTPS) | Check `ss -tlnp` and `ufw status` inside the VM, then the Scheme field in NPM |
| NPM can't get a certificate | DNS isn't pointing to the server, there's an AAAA record, or port 80 is blocked | Check `dig +short <domain>` on your Mac and the firewalls, then request it again |
| `http://localhost:8181` doesn't load | The SSH tunnel isn't open, or NPM isn't running | Open the tunnel (section 8), then check `docker ps` in the proxy VM |

To see where an SSH connection stops, add `-v`: `ssh -v -p 2223 bob@<server-ip>`.
