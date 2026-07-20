namespace Klanata.Domain.Entities;

public sealed class MarketplaceParticipation
{
    private MarketplaceParticipation()
    {
    }

    public MarketplaceParticipation(
        Guid sellerAccountId,
        string marketplaceId,
        string name,
        string countryCode,
        string defaultCurrencyCode,
        AmazonApiRegion region,
        bool isParticipating,
        bool hasSuspendedListings,
        DateTimeOffset discoveredAtUtc)
    {
        if (sellerAccountId == Guid.Empty)
        {
            throw new ArgumentException("Seller account is required.", nameof(sellerAccountId));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(marketplaceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        ArgumentException.ThrowIfNullOrWhiteSpace(countryCode);
        ArgumentException.ThrowIfNullOrWhiteSpace(defaultCurrencyCode);

        Id = Guid.NewGuid();
        SellerAccountId = sellerAccountId;
        MarketplaceId = marketplaceId.Trim();
        Name = name.Trim();
        CountryCode = countryCode.Trim().ToUpperInvariant();
        DefaultCurrencyCode = defaultCurrencyCode.Trim().ToUpperInvariant();
        Region = region;
        IsParticipating = isParticipating;
        HasSuspendedListings = hasSuspendedListings;
        DiscoveredAtUtc = discoveredAtUtc.ToUniversalTime();
        LastVerifiedAtUtc = DiscoveredAtUtc;
    }

    public Guid Id { get; private set; }

    public Guid SellerAccountId { get; private set; }

    public string MarketplaceId { get; private set; } = string.Empty;

    public string Name { get; private set; } = string.Empty;

    public string CountryCode { get; private set; } = string.Empty;

    public string DefaultCurrencyCode { get; private set; } = string.Empty;

    public AmazonApiRegion Region { get; private set; }

    public bool IsParticipating { get; private set; }

    public bool HasSuspendedListings { get; private set; }

    public DateTimeOffset DiscoveredAtUtc { get; private set; }

    public DateTimeOffset LastVerifiedAtUtc { get; private set; }

    public void RefreshDiscovery(
        string name,
        string defaultCurrencyCode,
        bool isParticipating,
        bool hasSuspendedListings,
        DateTimeOffset verifiedAtUtc)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        ArgumentException.ThrowIfNullOrWhiteSpace(defaultCurrencyCode);

        Name = name.Trim();
        DefaultCurrencyCode = defaultCurrencyCode.Trim().ToUpperInvariant();
        IsParticipating = isParticipating;
        HasSuspendedListings = hasSuspendedListings;
        LastVerifiedAtUtc = verifiedAtUtc.ToUniversalTime();
    }
}
