# Production V2 Operations

The active Linux server deployment and SSH tunnel instructions are documented in `docs/server-deployment.md`.

## Development

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-phase1.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-v2.ps1
```

The run script installs the locked frontend dependencies, builds the React client, binds to `http://127.0.0.1:4318`, and stores data under `src/Klanata.Api/runtime-v2`.

## Release Publish

```powershell
dotnet publish src/Klanata.Api/Klanata.Api.csproj `
  -c Release `
  -r win-x64 `
  --self-contained true `
  -p:PublishSingleFile=false `
  -o publish/win-x64
```

Publishing builds the React client and includes it in the API `wwwroot` output.

## Windows Service

After the legacy workstation has been stopped and the cutover window is approved:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy\install.ps1
```

The service runs as `LocalService`, listens only on localhost, and stores mutable data under ProgramData.

## Linux Systemd Service

The Ubuntu deployment uses `deploy/linux/install.sh`, `deploy/linux/backup.sh`, and `deploy/linux/klanata.service`. It runs as the dedicated `klanata` account, listens only on `127.0.0.1:4318`, and stores mutable data under `/var/lib/klanata`.

The complete Amazon compatibility workstation uses `deploy/linux/legacy`, runs as the hardened `klanata-amazon.service` container, and listens only on server loopback port 4319. Use local tunnel port 4321 for administration, or the public HTTPS endpoint `https://klanata.com/`. Nginx shares public port 443 with the existing Xray Reality service through SNI routing; see `docs/server-deployment.md` for the listener topology and certificate renewal checks.
