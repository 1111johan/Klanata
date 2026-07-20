# Pricing Workstation Safe Simulation

## Scope

The compatibility workstation now includes a non-mutating pricing workflow based on the production implementation plan dated 2026-07-16.

It provides:

- verified authorization profile and single-Marketplace binding;
- CSV, TXT, TSV, XLSX, and XLSM snapshot import without running workbook macros;
- common English and Chinese column-name detection;
- MFN/FBA/unknown fulfillment normalization;
- pure-FBM eligibility and same-ASIN FBA exclusion;
- fixed-amount and percentage price segments using decimal arithmetic;
- maximum absolute change enforcement;
- existing Amazon Business discount-ratio preservation and three alternative preview modes;
- minimum price, maximum price, cost, currency, duplicate SKU, status, and quantity guards;
- exclusion summaries, item-level price differences, risk classification, and CSV export.

## Production Gate

The module does not submit prices to Amazon. `Submit for approval` remains disabled because these decisions are not yet approved:

1. The exact formula for prices at or below 100.
2. The exact formula for prices above 100.
3. Whether `0.9` means a fixed change, a maximum change, or an ending-price rule.
4. The required direction model for each batch.
5. The approved Amazon Business price strategy.
6. Cost, minimum margin, minimum price, and maximum price sources.

## Required Snapshot Fields

Seller SKU/MSKU is mandatory. Eligibility additionally requires ASIN, quantity, fulfillment channel, Listing status, and current price. Currency, Amazon Business price, minimum/maximum allowed price, and cost are optional guards.

Records missing an eligibility field are not inferred as safe. They are returned as `EXCLUDED_INCOMPLETE`.

## Verification

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-pricing-simulation.ps1
```

The verification covers 99.99, 100, 100.01, the 0.90 cap, up/down direction, existing Business price ratios, missing Business prices, same-ASIN FBA, inactive Listings, zero inventory, unknown fulfillment, and duplicate SKUs.
