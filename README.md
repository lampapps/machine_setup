# Machine Setup

A Bash script for bootstrapping Debian-based Linux machines from a single config file. Install and configure common tools in one run — no Ansible, no dependencies, just `bash` and `sudo`.

---

## Features

- **Selective installs** — toggle each tool on/off with a single flag in `setup.conf`
- **Idempotent** — safe to re-run; already-installed packages are detected and skipped
- **Version tracking** — reports installed, updated, skipped, and failed packages in a summary table
- **NFS auto-discovery** — query all exports from a NAS and mount them automatically
- **Config kept out of git** — `setup.conf` is gitignored; secrets and IPs never leave your machine

### Supported packages

| Flag | Package |
|---|---|
| `INSTALL_GIT` | Git + global identity config |
| `INSTALL_MC` | Midnight Commander |
| `INSTALL_AWSCLI` | AWS CLI v2 (official installer) |
| `INSTALL_DUF` | duf (modern disk usage viewer) |
| `INSTALL_DOCKER` | Docker Engine + Docker Compose |
| `INSTALL_TAILSCALE` | Tailscale VPN |
| `INSTALL_NFS` | NFS client + `/etc/fstab` mounts |

---

## Quick Start

```bash
# 1. Download the script
curl -fsSL https://raw.githubusercontent.com/lampapps/machine_setup/main/setup.sh -o setup.sh

# 2. Download and edit the config
curl -fsSL https://raw.githubusercontent.com/lampapps/machine_setup/main/setup.conf.example -o setup.conf
nano setup.conf

# 3. Run
chmod +x setup.sh && sudo ./setup.sh
```

Or pipe directly (requires `setup.conf` to already exist in the current directory):

```bash
curl -fsSL https://raw.githubusercontent.com/lampapps/machine_setup/main/setup.sh | sudo bash
```

---

## Configuration

Copy the example config and edit it for your machine:

```bash
cp setup.conf.example setup.conf
nano setup.conf
```

`setup.conf` is listed in `.gitignore` and will **not** be committed.

### Example config snippet

```bash
# Toggle installs
INSTALL_GIT=true
INSTALL_DOCKER=true
INSTALL_TAILSCALE=false
INSTALL_NFS=true

# Git identity
GIT_USER_NAME="Your Name"
GIT_USER_EMAIL="you@example.com"

# Docker — user added to the docker group
DOCKER_USER="pi"

# Tailscale
TAILSCALE_AUTH_KEY=""          # leave blank to connect manually later
TAILSCALE_HOSTNAME=""          # blank = use system hostname
TAILSCALE_EXTRA_ARGS="--ssh"

# NFS — auto-discover all exports from a NAS
NFS_SERVER_IP="192.168.1.100"
NFS_VERSION="3"
NFS_MOUNT_BASE="/mnt"
NFS_MOUNT_NAME="nas"
```

See [`setup.conf.example`](setup.conf.example) for the full reference with all options documented.

---

## Advanced Usage

### Custom config path

```bash
sudo ./setup.sh --config /path/to/my.conf
```

### Discover NFS exports

Query all exports advertised by a NAS before configuring mounts:

```bash
sudo ./setup.sh --discover-nfs 192.168.1.100
```

### Manual NFS mounts

Define specific mounts instead of auto-discovery:

```bash
NFS_MOUNTS=(
  "192.168.1.100:/volume1/backups:/mnt/backups:rw,nfsvers=3"
  "192.168.1.100:/volume1/media:/mnt/media:ro,nfsvers=3"
)
```

---

## Requirements

- Debian-based distro (Debian, Ubuntu, Raspberry Pi OS, etc.)
- `bash` 4+
- `sudo` / root access

---

## License

MIT License — Copyright (c) 2026 lampapps

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
