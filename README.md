
# Remnawave Node Installer

Automated Remnawave Node installation for Ubuntu 24.04 VPS.

**Version:** 1.0.0

**Repository:** https://github.com/Wanderer-95/remnanode-installer

## One-command installation

Run as `root`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Wanderer-95/remnanode-installer/main/install.sh)
```

The installer displays an interactive menu with two installation modes.

## Installation modes

### 1. Fresh installation

Use this mode on a clean Ubuntu VPS.

The installer will:

- Check the operating system.
- Check whether the Remnawave Node container already exists.
- Check whether `/opt/remnanode` already exists.
- Check whether TCP port 2222 is occupied.
- Update Ubuntu packages.
- Install Docker Engine if it is not installed.
- Verify Docker Compose.
- Detect the active SSH port.
- Request the Remnawave Node `SECRET_KEY` interactively.
- Create `/opt/remnanode/docker-compose.yml`.
- Create `/opt/remnanode/.env`.
- Configure UFW without resetting existing rules.
- Pull `remnawave/node:latest`.
- Start the Remnawave Node container.
- Generate X25519 parameters and an additional random value.

### 2. Full removal and reinstallation

Use this mode to completely reinstall Remnawave Node.

The installer requests confirmation by entering:

```text
DELETE
```

After confirmation, it will:

- Verify Docker Engine availability.
- Verify the identity of the existing `remnanode` container.
- Stop and remove the existing container.
- Remove `/opt/remnanode`.
- Remove the previous `.env` and `SECRET_KEY`.
- Remove the local `remnawave/node` image if it is not used by other containers.
- Create a new configuration.
- Request a new `SECRET_KEY`.
- Pull the image and start a new container.

If an existing container named `remnanode` uses an unrelated image, the installer aborts rather than deleting it.

## What is preserved

The reinstall mode only targets Remnawave Node components.

| Component | Action |
|---|---|
| Ubuntu | Preserved |
| SSH configuration | Preserved |
| UFW configuration | Preserved |
| Existing UFW rules | Preserved |
| Docker Engine | Preserved |
| Docker Compose | Preserved |
| Other Docker containers | Preserved |
| Other Docker images | Preserved |
| Other directories | Preserved |
| System network settings | Preserved |
| MTU configuration | Preserved |

The installer does not execute `docker system prune`, reset UFW, or uninstall system packages.

## Security

- `SECRET_KEY` is entered without terminal echo.
- The secret is stored locally in `/opt/remnanode/.env`.
- The `.env` file has permissions `600`.
- The installation directory has permissions `700`.
- The Compose configuration has permissions `600`.
- The destructive operation requires explicit confirmation.

## Network and firewall

The installer detects the SSH port and allows it before enabling UFW.

The following TCP ports are allowed:

| Port | Purpose |
|---|---|
| 2222 | Remnawave Node |
| 443 | HTTPS / deployment |
| 8443 | Deployment |
| 80 | HTTP |

Existing UFW rules are not reset.

Check provider-level firewall and security-group rules separately.

## Docker configuration

The Node container uses:

- Image: `remnawave/node:latest`
- Container: `remnanode`
- Network mode: `host`
- Node port: `2222`
- Capability: `NET_ADMIN`
- Restart policy: `always`
- File descriptor limit: `1048576`

## Useful commands

Check container status:

```bash
docker ps -a --filter "name=^/remnanode$"
```

View logs:

```bash
docker logs -f remnanode
```

Restart Node:

```bash
docker restart remnanode
```

Stop Node:

```bash
docker stop remnanode
```

Check UFW:

```bash
ufw status
```

Check Docker Compose configuration:

```bash
cd /opt/remnanode
docker compose config
```

## Important

- Recommended OS: Ubuntu 24.04.
- Run the installer as root.
- Keep your `SECRET_KEY` private.
- The installer does not configure the Remnawave panel or register the Node automatically.
- The installer does not modify MTU settings.
- The installer does not install or remove nginx.
- Review the script before executing it on production servers.
