# Production V2 Recovery

## Database Backup

Run from an elevated PowerShell session:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy\backup.ps1
```

The script briefly stops the service, copies the database and protected key material, writes SHA-256 hashes, and restarts the service.

## Failed Startup

1. Check `C:\ProgramData\Klanata Inventory Workstation\logs`.
2. Confirm at least 2 GB free disk space.
3. Confirm the database and key directories are writable by `LOCAL SERVICE`.
4. Verify no second v2 process owns the single-instance mutex.
5. Keep the legacy PowerShell workstation in read-only fallback mode until v2 recovery is complete.
