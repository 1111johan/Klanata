namespace Klanata.Domain.Entities;

public enum FulfillmentChannel
{
    Mfn,
    Fba
}

public enum ListingStatus
{
    Active,
    Inactive,
    Incomplete,
    Suppressed,
    Unknown
}

public sealed class ProductListing
{
    private ProductListing()
    {
    }

    public ProductListing(
        Guid marketplaceParticipationId,
        string sellerId,
        string marketplaceId,
        string sku,
        string? asin,
        string? title,
        FulfillmentChannel fulfillmentChannel,
        ListingStatus status,
        string currencyCode,
        decimal? price,
        decimal? businessPrice,
        int? mfnQuantity,
        DateTimeOffset synchronizedAtUtc,
        DateTimeOffset? amazonUpdatedAtUtc = null,
        string? sourceReference = null)
    {
        if (marketplaceParticipationId == Guid.Empty)
        {
            throw new ArgumentException("Marketplace participation is required.", nameof(marketplaceParticipationId));
        }

        ValidateContext(sellerId, marketplaceId, sku, currencyCode, mfnQuantity);

        Id = Guid.NewGuid();
        MarketplaceParticipationId = marketplaceParticipationId;
        SellerId = sellerId.Trim();
        MarketplaceId = marketplaceId.Trim();
        Sku = sku.Trim();
        Asin = Normalize(asin);
        Title = Normalize(title);
        FulfillmentChannel = fulfillmentChannel;
        Status = status;
        CurrencyCode = currencyCode.Trim().ToUpperInvariant();
        Price = price;
        BusinessPrice = businessPrice;
        MfnQuantity = mfnQuantity;
        SynchronizedAtUtc = synchronizedAtUtc.ToUniversalTime();
        SynchronizedUnixTimeSeconds = SynchronizedAtUtc.ToUnixTimeSeconds();
        AmazonUpdatedAtUtc = amazonUpdatedAtUtc?.ToUniversalTime();
        SourceReference = Normalize(sourceReference);
        SnapshotVersion = 1;
    }

    public Guid Id { get; private set; }

    public Guid MarketplaceParticipationId { get; private set; }

    public string SellerId { get; private set; } = string.Empty;

    public string MarketplaceId { get; private set; } = string.Empty;

    public string Sku { get; private set; } = string.Empty;

    public string? Asin { get; private set; }

    public string? Title { get; private set; }

    public FulfillmentChannel FulfillmentChannel { get; private set; }

    public ListingStatus Status { get; private set; }

    public string CurrencyCode { get; private set; } = string.Empty;

    public decimal? Price { get; private set; }

    public decimal? BusinessPrice { get; private set; }

    public int? MfnQuantity { get; private set; }

    public DateTimeOffset SynchronizedAtUtc { get; private set; }

    public long SynchronizedUnixTimeSeconds { get; private set; }

    public DateTimeOffset? AmazonUpdatedAtUtc { get; private set; }

    public string? SourceReference { get; private set; }

    public long SnapshotVersion { get; private set; }

    public void RefreshSnapshot(
        string sellerId,
        string marketplaceId,
        string? asin,
        string? title,
        FulfillmentChannel fulfillmentChannel,
        ListingStatus status,
        string currencyCode,
        decimal? price,
        decimal? businessPrice,
        int? mfnQuantity,
        DateTimeOffset synchronizedAtUtc,
        DateTimeOffset? amazonUpdatedAtUtc,
        string? sourceReference)
    {
        if (!string.Equals(SellerId, sellerId.Trim(), StringComparison.Ordinal) ||
            !string.Equals(MarketplaceId, marketplaceId.Trim(), StringComparison.Ordinal))
        {
            throw new InvalidOperationException("A listing snapshot cannot move to another Seller or Marketplace.");
        }

        ValidateContext(sellerId, marketplaceId, Sku, currencyCode, mfnQuantity);
        Asin = Normalize(asin);
        Title = Normalize(title);
        FulfillmentChannel = fulfillmentChannel;
        Status = status;
        CurrencyCode = currencyCode.Trim().ToUpperInvariant();
        Price = price;
        BusinessPrice = businessPrice;
        MfnQuantity = mfnQuantity;
        SynchronizedAtUtc = synchronizedAtUtc.ToUniversalTime();
        SynchronizedUnixTimeSeconds = SynchronizedAtUtc.ToUnixTimeSeconds();
        AmazonUpdatedAtUtc = amazonUpdatedAtUtc?.ToUniversalTime();
        SourceReference = Normalize(sourceReference);
        SnapshotVersion++;
    }

    private static void ValidateContext(
        string sellerId,
        string marketplaceId,
        string sku,
        string currencyCode,
        int? mfnQuantity)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sellerId);
        ArgumentException.ThrowIfNullOrWhiteSpace(marketplaceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(sku);
        ArgumentException.ThrowIfNullOrWhiteSpace(currencyCode);
        if (mfnQuantity < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(mfnQuantity));
        }
    }

    private static string? Normalize(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
