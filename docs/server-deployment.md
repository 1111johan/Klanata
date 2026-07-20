# Linux Server Deployment

## Active Server

- Host: `144.225.124.172`
- SSH user: `user_cyh`
- Operating system: Ubuntu 22.04 x64
- Service: `klanata.service`
- Application: `/opt/klanata/current`
- Persistent data: `/var/lib/klanata`
- Backups: `/var/backups/klanata`
- Server listener: `http://127.0.0.1:4318`

Production v2 is intentionally not exposed on a public port. The complete Amazon compatibility workstation has its own public HTTPS virtual host as documented below; the existing default Docker application on port 8080 remains separate.

## Full Amazon Workstation

The compatibility workstation provides the complete existing Amazon workflow while those capabilities are migrated into production v2:

- Service: `klanata-amazon.service`
- Container: `klanata-amazon`
- Server listener: `http://127.0.0.1:4319`
- Persistent runtime: `/var/lib/klanata-amazon`
- Encrypted profiles: `/etc/klanata/amazon-profiles.enc`
- Root-only encryption key: `/etc/klanata/credential.key`
- Encrypted workstation store: `/var/lib/klanata-amazon/runtime/authorization-store.json`
- Workstation store key: `/etc/klanata/workstation-store.key`
- Backups: `/var/backups/klanata-amazon`

The container runs as UID 10001 with a read-only filesystem, dropped Linux capabilities, resource limits, and no public listener. `/var/lib/klanata-amazon/runtime` is the only persistent writable application mount. The installer creates a dedicated 32-byte workstation-store key owned by `root:10001` with mode `0440`; systemd mounts it read-only at `/run/secrets/workstation-store.key` and sets `KLANATA_CREDENTIAL_KEY_PATH` to that path. Two valid North America authorization profiles are decrypted only in memory during service startup and are automatically verified with Amazon SP-API.

## Amazon OAuth Configuration

Before enabling the public authorization button, configure the production Amazon application in Seller Central Developer Central with these exact values:

- OAuth redirect/callback URL: `https://www.klanata.com/api/auth/oauth/callback`
- Amazon Application ID / Solution ID: the identifier issued for the registered SP-API application
- LWA Client ID and LWA Client Secret: the global developer-application credentials

The Amazon Application ID / Solution ID is required to start the Seller Central authorization flow. It is not the Seller ID and is not interchangeable with the LWA Client ID. Store it with the administrator-level Amazon application configuration; Seller ID, Refresh Token, participating Marketplaces, region, and endpoint are populated from the OAuth callback and SP-API discovery.

## Open The Server Workstation

From the repository root on the authorized Windows workstation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\open-server-tunnel.ps1 -Background
```

Open `http://127.0.0.1:4320/` for the production-v2 status console.

Open the complete Amazon workstation with a second tunnel:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\open-server-tunnel.ps1 -LocalPort 4321 -RemotePort 4319 -Background
```

Then open `http://127.0.0.1:4321/`. The local workstation on port 4317 remains available only in read-only fallback mode.

The complete workstation is published at:

- `https://klanata.com/`
- `https://www.klanata.com/`
- compatibility URL: `http://144.225.124.172.nip.io/`

HTTP requests for the two named domains redirect to HTTPS. The Let's Encrypt certificate covers both names and is renewed by `certbot.timer`; `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` reloads Nginx after renewal.

Port 443 is shared without changing the external Xray client endpoint. Nginx stream SNI routing sends `klanata.com` and `www.klanata.com` to the local HTTPS listener on `127.0.0.1:8444`; all other SNI values, including Xray Reality's `www.microsoft.com`, are forwarded to Xray on `127.0.0.1:8443`.

## Service Operations

```bash
ssh user_cyh@144.225.124.172
su -
systemctl status klanata.service
systemctl restart klanata.service
journalctl -u klanata.service -n 100 --no-pager
systemctl status klanata-amazon.service
systemctl restart klanata-amazon.service
journalctl -u klanata-amazon.service -n 100 --no-pager
systemctl status nginx.service xray.service certbot.timer
certbot renew --dry-run --no-random-sleep-on-renew
```

## Backup

The backup script stops the service for a consistent SQLite copy, verifies SHA-256, starts the service, and waits for readiness:

```bash
cd /home/user_cyh/klanata-deploy
./backup.sh
```

Back up the complete Amazon workstation, including job state, the encrypted workstation store, its dedicated key, and encrypted authorization profiles:

```bash
cd /home/user_cyh/klanata-amazon-deploy
./backup.sh
```

## Upgrade

Build the self-contained release on the Windows workstation:

```powershell
$env:PATH = 'C:\Program Files\nodejs;' + $env:PATH
dotnet publish src\Klanata.Api\Klanata.Api.csproj `
  -c Release `
  -r linux-x64 `
  --self-contained true `
  -p:PublishSingleFile=false `
  -o publish\linux-x64
tar.exe -czf publish\klanata-linux-x64.tar.gz -C publish\linux-x64 .
scp.exe publish\klanata-linux-x64.tar.gz user_cyh@144.225.124.172:/home/user_cyh/klanata-deploy/
```

Then connect to the server, elevate with `su -`, and run:

```bash
cd /home/user_cyh/klanata-deploy
./backup.sh
./install.sh ./klanata-linux-x64.tar.gz ./klanata.service
```

Do not store the root password, Amazon Client Secret, or Refresh Token in deployment files or shell history.

The backup archive includes both `/var/lib/klanata-amazon` and `/etc/klanata`. The backup script verifies that `/etc/klanata/workstation-store.key`, and `/var/lib/klanata-amazon/runtime/authorization-store.json` when present, are in the archive before publishing its SHA-256 manifest. Restore the encrypted store and its 32-byte key as a matched set: losing or replacing the key makes the store unrecoverable. The legacy `/etc/klanata/credential.key` and `/etc/klanata/amazon-profiles.enc` must likewise remain paired.

To rotate profiles, upload a temporary JSON array containing `clientId`, `clientSecret`, `refreshToken`, and the verified `sellerId`, then run `deploy/linux/legacy/provision-credentials.sh` as root. Region and endpoint are discovered from the authorized Marketplaces. The script validates, encrypts, and securely removes the plaintext file by default. Restart `klanata-amazon.service` to load the new profiles.
