# Production V2 Release Checklist

- [x] `scripts/verify-phase1.ps1` passes.
- [x] NuGet and npm vulnerability scans report no findings.
- [x] Release publish succeeds for `win-x64` self-contained.
- [x] Health and readiness endpoints return an acceptable state.
- [x] SQLite migration and backup are verified, including backup SHA-256 hashes.
- [x] Service binds only to `127.0.0.1`.
- [x] Security headers and local HttpOnly/SameSite cookie are present.
- [ ] Windows Service restart and reboot recovery are rehearsed.
- [x] Legacy and v2 are not allowed to submit simultaneously; Phase 1 has no submission endpoint.
- [x] Linux `systemd` service is enabled and survived an explicit service restart.
- [x] Linux SQLite backup completed, passed SHA-256 validation, and recovered to ready state.
- [x] Server port 4318 is loopback-only and accessible through an authenticated SSH tunnel.
- [x] Complete Amazon workstation is active on server loopback port 4319 and tunnel port 4321.
- [x] Two same-region Refresh Tokens remain active simultaneously after restart.
- [x] Authorization profiles are encrypted at rest and decrypted only by the root-controlled startup loader.
- [x] Both authorization profiles passed Amazon Marketplace discovery and Seller `VALIDATION_PREVIEW`.
- [x] Local port 4317 is read-only, preventing dual Feed submissions during migration.
- [x] Public Nginx endpoint passed UI, UTF-8 file upload, analysis, two-profile authorization recovery, and Seller preview validation.
- [x] Public Nginx endpoint accepts Amazon XLSX/XLSM templates and parses the `Template` worksheet without executing macros.
- [x] Template `contributorId` and `primaryMarketplaceId` mismatches are rejected before Seller preview or Feed submission.

Last workstation verification: 2026-07-15 on `production-v2`, using port `4318`.

The Windows Service rehearsal remains open because the legacy production workstation is using port `4317`. It must be completed during an approved cutover window.

The Linux service restart was rehearsed without rebooting the VPS because it also hosts unrelated Nginx and Docker workloads.

No Feed mutation was executed as part of the version `1.2` verification. The earlier wrong-account Feed and its completed cleanup are documented in `docs/incidents/2026-07-15-carkee-us-wrong-inventory-feed.md`.

Amazon compatibility workstation version `1.2` was verified on 2026-07-15 with three existing Carkee US SKUs. All three returned `BUYABLE`, current MFN quantity 1000, and a `VALID` inventory preview. No Feed was submitted during this verification.
