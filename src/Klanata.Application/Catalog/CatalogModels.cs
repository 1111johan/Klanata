namespace Klanata.Application.Catalog;

public sealed record MarketplaceContext(
    string SellerId,
    string SellerName,
    string MarketplaceId,
    string MarketplaceName,
    string CountryCode,
    string CurrencyCode,
    string Region,
    DateTimeOffset LastVerifiedAtUtc,
    int AuthorizationProfileCount,
    MarketplaceCapabilities Capabilities);

public sealed record MarketplaceCapabilities(
    bool CanReadListings,
    bool CanReadCatalog,
    bool CanReadPricing,
    bool CanCreateDraftChangeSets,
    bool CanSimulatePricing,
    bool CanWritePrices,
    bool CanWriteMfnInventory,
    string WriteBlockReason,
    DateTimeOffset? VerifiedAtUtc);

public sealed record ProductCatalogQuery(
    string SellerId,
    string MarketplaceId,
    string? Search,
    string? Status,
    string? Fulfillment,
    string? Freshness,
    int Page,
    int PageSize);

public sealed record ProductCatalogPage(
    MarketplaceContext Context,
    CatalogMetrics Metrics,
    IReadOnlyList<ProductListingSummary> Items,
    int Page,
    int PageSize,
    int TotalItems,
    int TotalPages,
    DateTimeOffset GeneratedAtUtc);

public sealed record CatalogMetrics(
    int TotalListings,
    int ActiveListings,
    int MfnListings,
    int StaleListings,
    DateTimeOffset? LastSynchronizedAtUtc);

public sealed record ProductListingSummary(
    string Sku,
    string? Asin,
    string? Title,
    string Fulfillment,
    string Status,
    string CurrencyCode,
    decimal? Price,
    decimal? BusinessPrice,
    int? MfnQuantity,
    string Freshness,
    DateTimeOffset SynchronizedAtUtc,
    long SnapshotVersion);

public sealed record ProductListingDetail(
    string SellerId,
    string MarketplaceId,
    string Sku,
    string? Asin,
    string? Title,
    string Fulfillment,
    string Status,
    string CurrencyCode,
    decimal? Price,
    decimal? BusinessPrice,
    int? MfnQuantity,
    string Freshness,
    DateTimeOffset SynchronizedAtUtc,
    DateTimeOffset? AmazonUpdatedAtUtc,
    string? SourceReference,
    long SnapshotVersion);
