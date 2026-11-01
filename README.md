# remnanode-installer

Automated Remnawave Node installation for Ubuntu 24.04 VPS.

## One-command installation

Run as `root` on a fresh Ubuntu 24.04 server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Wanderer-95/remnanode-installer/main/install.sh)
```

The installer will:

- update Ubuntu packages;
- install Docker Engine using Docker's official convenience script (if Docker is not already installed);
- create `/opt/remnanode/docker-compose.yml` and `/opt/remnanode/.env`;
- prompt for the Remnawave Node `SECRET_KEY` without echoing it;
- configure UFW rules for the detected SSH port and TCP ports 2222, 443, 8443, and 80;
- pull and start `remnawave/node:latest`;
- run `xray x25519` and `openssl rand -hex 8`.

## Important

- Use a fresh Ubuntu 24.04 VPS where possible.
- Review `install.sh` before running it; it executes system-level commands as root.
- The repository does not contain your `SECRET_KEY`. The key is entered interactively and stored locally in `/opt/remnanode/.env` with permissions `600`.
- The installer does not change MTU settings.
- UFW is enabled only if it is currently inactive. The detected SSH port is allowed before enabling it. Verify provider-level firewall/security-group rules separately.
- The script allows the listed TCP ports. Add UDP rules separately only if your deployment requires them.
- The script does not configure the Remnawave panel or register the Node automatically.

## Update / rerun

The script can be run again to pull the current `remnawave/node:latest` image and recreate the container using the existing local `.env` only after you enter the key again. Review existing server configuration before rerunning.
