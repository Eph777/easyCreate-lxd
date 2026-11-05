# incus-installer

A simple script to install or update [Incus](https://linuxcontainers.org/incus/) on Ubuntu, using the official [Zabbly](https://github.com/zabbly/incus) package repository.

## What it does

- Adds the Zabbly repository and its signing key
- Installs Incus if it isn't installed yet
- Updates Incus if it is already installed (and tells you whether a new version was installed)

It is safe to run more than once.

## Requirements

- An Ubuntu release supported by Zabbly, such as 22.04 (Jammy) or 24.04 (Noble). Older releases like 20.04 (Focal) are not supported; the script checks this and stops before changing anything.
- Root access

## Usage

```bash
git clone https://github.com/<your-username>/incus-installer.git
cd incus-installer
sudo bash incus-installer.sh
```

After a fresh install, initialize Incus:

```bash
sudo incus admin init
```

Use `sudo incus admin init --minimal` to accept the defaults.

## Security

Incus is meant to be used with root privileges only. The script does not add any user to the `incus-admin` or `incus` groups, so normal users have no access to Incus. Use `sudo incus ...` or run commands as root.

## Updating

Run the script again:

```bash
sudo bash incus-installer.sh
```

Only Incus is upgraded; other system packages are left untouched. Running containers and VMs keep running during the update.

## Creating a VM

`create-vm.sh` creates a VM on a server running LXD and gives one user SSH access to it, with their own password and without any access to the server:

```bash
sudo ./create-vm.sh
```

It asks for the VM's name, user, password, resources, IP and SSH port, and suggests free values. It can also publish the VM's websites over HTTPS through a shared reverse proxy VM running [Nginx Proxy Manager](https://nginxproxymanager.com/), so many VMs can host sites behind a single server IP.

To publish websites from a VM that already exists, or to add domains to a VM later:

```bash
sudo ./publish-sites.sh
```

To create the reverse proxy VM on its own, or to switch an existing one from Caddy to Nginx Proxy Manager:

```bash
sudo ./install-npm.sh
```

The scripts share their code through `common.sh`, so keep all the files in the same folder. [VM-GUIDE.md](VM-GUIDE.md) explains each step and how to monitor and manage the VMs.
