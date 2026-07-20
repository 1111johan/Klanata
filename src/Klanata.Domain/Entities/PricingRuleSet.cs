namespace Klanata.Domain.Entities;

public enum PricingAdjustmentType
{
    FixedAmount,
    Percentage
}

public enum PricingDirection
{
    Increase,
    Decrease
}

public enum BusinessPriceStrategy
{
    Unchanged
}

public sealed class PricingRuleSet
{
    private PricingRuleSet()
    {
    }

    public PricingRuleSet(
        Guid marketplaceParticipationId,
        Guid authorizationProfileId,
        string sellerId,
        string marketplaceId,
        string name,
        int version,
        PricingDirection direction,
        decimal threshold,
        PricingAdjustmentType belowThresholdType,
        decimal belowThresholdValue,
        PricingAdjustmentType atOrAboveThresholdType,
        decimal atOrAboveThresholdValue,
        decimal? absoluteChangeCap,
        decimal? percentageChangeCap,
        string currencyCode,
        int currencyPrecision,
        BusinessPriceStrategy businessPriceStrategy,
        string createdBy,
        DateTimeOffset createdAtUtc)
    {
        if (marketplaceParticipationId == Guid.Empty)
        {
            throw new ArgumentException("Marketplace participation is required.", nameof(marketplaceParticipationId));
        }

        if (authorizationProfileId == Guid.Empty)
        {
            throw new ArgumentException("Authorization profile is required.", nameof(authorizationProfileId));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(sellerId);
        ArgumentException.ThrowIfNullOrWhiteSpace(marketplaceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        ArgumentException.ThrowIfNullOrWhiteSpace(currencyCode);
        ArgumentException.ThrowIfNullOrWhiteSpace(createdBy);
        if (version < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(version));
        }

        if (threshold <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(threshold));
        }

        if (belowThresholdValue <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(belowThresholdValue));
        }

        if (atOrAboveThresholdValue <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(atOrAboveThresholdValue));
        }

        if (absoluteChangeCap is <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(absoluteChangeCap));
        }

        if (percentageChangeCap is <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(percentageChangeCap));
        }

        if (currencyPrecision is < 0 or > 4)
        {
            throw new ArgumentOutOfRangeException(nameof(currencyPrecision));
        }

        if (businessPriceStrategy != BusinessPriceStrategy.Unchanged)
        {
            throw new ArgumentException(
                "V4 P0 only permits the UNCHANGED business-price strategy.",
                nameof(businessPriceStrategy));
        }

        Id = Guid.NewGuid();
        MarketplaceParticipationId = marketplaceParticipationId;
        AuthorizationProfileId = authorizationProfileId;
        SellerId = sellerId.Trim();
        MarketplaceId = marketplaceId.Trim();
        Name = name.Trim();
        Version = version;
        Direction = direction;
        Threshold = threshold;
        BelowThresholdType = belowThresholdType;
        BelowThresholdValue = belowThresholdValue;
        AtOrAboveThresholdType = atOrAboveThresholdType;
        AtOrAboveThresholdValue = atOrAboveThresholdValue;
        AbsoluteChangeCap = absoluteChangeCap;
        PercentageChangeCap = percentageChangeCap;
        CurrencyCode = currencyCode.Trim().ToUpperInvariant();
        CurrencyPrecision = currencyPrecision;
        BusinessPriceStrategy = businessPriceStrategy;
        CreatedBy = createdBy.Trim();
        CreatedAtUtc = createdAtUtc.ToUniversalTime();
    }

    public Guid Id { get; private set; }

    public Guid MarketplaceParticipationId { get; private set; }

    public Guid AuthorizationProfileId { get; private set; }

    public string SellerId { get; private set; } = string.Empty;

    public string MarketplaceId { get; private set; } = string.Empty;

    public string Name { get; private set; } = string.Empty;

    public int Version { get; private set; }

    public PricingDirection Direction { get; private set; }

    public decimal Threshold { get; private set; }

    public PricingAdjustmentType BelowThresholdType { get; private set; }

    public decimal BelowThresholdValue { get; private set; }

    public PricingAdjustmentType AtOrAboveThresholdType { get; private set; }

    public decimal AtOrAboveThresholdValue { get; private set; }

    public decimal? AbsoluteChangeCap { get; private set; }

    public decimal? PercentageChangeCap { get; private set; }

    public string CurrencyCode { get; private set; } = string.Empty;

    public int CurrencyPrecision { get; private set; }

    public BusinessPriceStrategy BusinessPriceStrategy { get; private set; }

    public string CreatedBy { get; private set; } = string.Empty;

    public DateTimeOffset CreatedAtUtc { get; private set; }
}
