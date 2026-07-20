# Production V2 Implementation Status

## Current Phase

Phase 1 - Foundation

## 1. Completed

- Created the `production-v2` branch without reverting legacy worktree changes.
- Added the .NET 10 layered solution and React TypeScript application.
- Added SQLite with EF Core migrations and required PRAGMA initialization.
- Added persistent audit events, application metadata, and worker leases.
- Added Serilog rolling file logging and Windows Service hosting support.
- Added localhost host validation, security headers, local session cookie, and Anti-CSRF foundation.
- Added `/api/v2/system/health`, `/api/v2/system/version`, and `/api/v2/system/session`.
- Added a real system status UI backed by the v2 API.
- Added domain, application, infrastructure, and API integration tests.
- Added CI, install, uninstall, backup, and local verification scripts.
- Added Linux systemd installation, backup, uninstall, and SSH tunnel tooling.
- Deployed the self-contained `linux-x64` build to the authorized Ubuntu server as `klanata.service`.
- Deployed the complete Amazon workstation as the hardened `klanata-amazon.service` compatibility container.
- Added same-region multi-token support and Marketplace deduplication.
- Added AES-256/PBKDF2 encrypted authorization profiles with automatic in-memory recovery after service restarts.
- Added a compatibility-workstation pricing safety module with verified Marketplace binding, CSV/TXT/TSV/XLSX/XLSM import, pure-FBM filtering, same-ASIN FBA exclusion, decimal rule simulation, business-price preview, risk summaries, and CSV export.
- Kept all production price mutation and approval actions locked until the pricing formula and `0.9` business meaning are formally approved.
- Redesigned the compatibility workstation as a continuous, data-dense operations console with semantic color and typography tokens, persistent target context, responsive navigation, hash-deep-linked views, 44px interaction targets, stable boot rendering, and reduced-motion support.
- Added six-viewport browser regression coverage for all four workstation views; Chrome DevTools Lighthouse scores are 100 for accessibility, best practices, SEO, and agentic browsing on desktop and mobile.

## 2. Files Added Or Changed

- `Klanata.slnx`, `global.json`, `Directory.Build.props`
- `src/Klanata.Api`
- `src/Klanata.Application`
- `src/Klanata.Domain`
- `src/Klanata.Infrastructure`
- `src/Klanata.Workers`
- `src/Klanata.Web`
- `tests/*`
- `deploy/*`
- `scripts/*`
- `.github/workflows/ci.yml`

## 3. Database Migration

- `InitialPlatform`
- Tables: `AppMetadata`, `AuditEvents`, `WorkerLeases`
- SQLite: foreign keys enabled, WAL journal mode, FULL synchronous mode, 5-second busy timeout.

## 4. API Changes

- `GET /api/v2/system/health`
- `GET /api/v2/system/version`
- `GET /api/v2/system/session`
- `GET /health/live`
- `GET /health/ready`

## 5. Test Result

- Release build: 0 warnings and 0 errors.
- Domain tests: 4 passed for audit events and worker lease ownership.
- Application tests: 3 passed for platform health aggregation.
- Infrastructure tests: 1 passed for migration, startup audit, and SQLite PRAGMAs.
- API integration tests: 4 passed for version, health, session cookie, security headers, and invalid-host rejection.
- React typecheck, lint, and production build passed.
- NuGet and npm vulnerability scans found no vulnerable packages.
- Self-contained `win-x64` publish passed and produced a runnable deployment directory.
- Live verification passed on `http://127.0.0.1:4318` for health, readiness, static assets, security headers, cookie policy, database migration, worker heartbeat, and invalid-host rejection.
- Offline backup rehearsal copied three SQLite files and verified all manifest SHA-256 hashes.
- Linux systemd verification passed for isolated loopback binding, automatic restart policy, service restart recovery, SQLite backup, SHA-256 validation, and SSH tunnel access.
- Complete workstation verification passed for 289-SKU analysis, two simultaneous NA authorization sessions, Amazon Marketplace discovery, and two Seller/Marketplace `VALIDATION_PREVIEW` checks with zero issues.
- Local port 4317 was cut over to read-only fallback mode; server tunnel port 4321 is the only submission-capable workstation.
- Published the complete workstation through the dedicated Nginx host `http://144.225.124.172.nip.io/` and verified the full non-mutating workflow from outside the server.

## 6. Not Completed

- Phase 2 authorization profiles and encrypted secret storage.
- Production Windows Service installation and reboot rehearsal while the legacy service occupies port 4317.
- Full server reboot rehearsal, because the VPS also hosts unrelated Docker and Nginx workloads.
- A real inventory Feed was not submitted during migration because the current file would set 256 of 289 SKUs to zero inventory.
- Amazon clients, inventory import, snapshots, change sets, submissions, verification, and rollback.

## 7. Risks And Assumptions

- The legacy PowerShell workstation remains the only production submission path until later phases pass the release gates.
- The v2 development service uses port 4318; production remains configured for 4317 after cutover.
- The Linux server service uses server loopback port 4318 and is reached through local SSH tunnel port 4320.
- Secret storage reports `not-configured` by design until Phase 2 is implemented.

## 8. Manual Verification

1. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-phase1.ps1`.
2. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-v2.ps1`.
3. Open `http://127.0.0.1:4318/`.
4. Confirm database, disk, worker, local session, version, and security status.
5. Do not install the Windows Service on port 4317 until the legacy cutover is scheduled.
