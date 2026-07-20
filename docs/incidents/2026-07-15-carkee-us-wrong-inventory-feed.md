# Carkee US wrong inventory Feed recovery

## Incident

- Seller: Carkee (`AC7OMGZBRADKF`)
- Marketplace: Amazon US (`ATVPDKIKX0DER`)
- Feed ID: `441216020649`
- Source file: `PriceAndQuantity-us.txt`
- Submitted: 2026-07-15 11:48 CST
- Amazon result: `DONE`, 289 processed and accepted, 0 errors, 0 warnings
- Submitted quantities: 256 records at 0 and 33 records at 999

The file belonged to another store and was submitted to Carkee by mistake.

## Containment

The local and production Amazon workstations were put into read-only mode before
recovery. Feed submission remained disabled throughout investigation, cleanup,
and verification.

## Investigation

A GET-only Listings Items audit was run for all 289 Seller SKUs. Every SKU had:

- no ASIN;
- no listing summary or listing status;
- no current fulfillment availability response;
- only the `fulfillment_availability` attribute written by Feed `441216020649`;
- an attribute quantity exactly equal to the submitted 0 or 999 value.

A known Carkee listing returned its ASIN, dates, status, and FBA channel during
the same audit. A random SKU returned 404. This confirmed that the 289 affected
SKUs were incomplete orphan records created by the wrong Feed, rather than
existing Carkee listings whose inventory had been overwritten.

## Recovery

The 289 proven orphan records were deleted through the Listings Items API.
Amazon accepted all 289 delete operations and returned no failures.

A full post-delete GET verification then returned 404 for all 289 SKUs:

- found: 0
- not found: 289
- remaining orphan attribute records: 0

The legitimate Carkee listings and their warehouse quantities did not require a
quantity rollback because they were not targeted by these Seller SKUs.

## Evidence

- `runtime/feed-input-9ce10c4e7263427a8de3fa5de69d209c.json`
- `runtime/feed-processing-report-441216020649.json`
- `runtime/recovery-listings-20260715-v2.json`
- `runtime/recovery-delete-result-20260715.json`
- `runtime/recovery-post-delete-verification-20260715.json`

The same recovery artifacts are retained on the production server under
`/home/user_cyh/klanata-amazon-deploy/`.
