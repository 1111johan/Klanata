namespace Klanata.Domain.Entities;

public enum PricingRunStatus
{
    Simulated,
    PendingReview,
    ReviewRecorded
}

public sealed class PricingRun
{
    private PricingRun()
    {
    }

    public PricingRun(
        Guid pricingRuleSetId,
        Guid marketplaceParticipationId,
        Guid authorizationProfileId,
        string runNumber,
        string idempotencyKey,
        string requestFingerprint,
        string sellerId,
        string marketplaceId,
        string initiatedBy,
        DateTimeOffset createdAtUtc)
    {
        if (pricingRuleSetId == Guid.Empty)
        {
            throw new ArgumentException("Pricing rule set is required.", nameof(pricingRuleSetId));
        }

        if (marketplaceParticipationId == Guid.Empty)
        {
            throw new ArgumentException("Marketplace participation is required.", nameof(marketplaceParticipationId));
        }

        if (authorizationProfileId == Guid.Empty)
        {
            throw new ArgumentException("Authorization profile is required.", nameof(authorizationProfileId));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(runNumber);
        ArgumentException.ThrowIfNullOrWhiteSpace(idempotencyKey);
        ArgumentException.ThrowIfNullOrWhiteSpace(requestFingerprint);
        ArgumentException.ThrowIfNullOrWhiteSpace(sellerId);
        ArgumentException.ThrowIfNullOrWhiteSpace(marketplaceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(initiatedBy);

        Id = Guid.NewGuid();
        PricingRuleSetId = pricingRuleSetId;
        MarketplaceParticipationId = marketplaceParticipationId;
        AuthorizationProfileId = authorizationProfileId;
        RunNumber = runNumber.Trim();
        IdempotencyKey = idempotencyKey.Trim();
        RequestFingerprint = requestFingerprint.Trim();
        SellerId = sellerId.Trim();
        MarketplaceId = marketplaceId.Trim();
        InitiatedBy = initiatedBy.Trim();
        Status = PricingRunStatus.Simulated;
        CreatedAtUtc = createdAtUtc.ToUniversalTime();
    }

    public Guid Id { get; private set; }

    public Guid PricingRuleSetId { get; private set; }

    public Guid MarketplaceParticipationId { get; private set; }

    public Guid AuthorizationProfileId { get; private set; }

    public string RunNumber { get; private set; } = string.Empty;

    public string IdempotencyKey { get; private set; } = string.Empty;

    public string RequestFingerprint { get; private set; } = string.Empty;

    public string SellerId { get; private set; } = string.Empty;

    public string MarketplaceId { get; private set; } = string.Empty;

    public string InitiatedBy { get; private set; } = string.Empty;

    public PricingRunStatus Status { get; private set; }

    public DateTimeOffset CreatedAtUtc { get; private set; }

    public void MarkPendingReview()
    {
        if (Status == PricingRunStatus.Simulated)
        {
            Status = PricingRunStatus.PendingReview;
        }
    }

    public void MarkReviewRecorded()
    {
        if (Status != PricingRunStatus.PendingReview)
        {
            throw new InvalidOperationException("Only a pending pricing run can record a review.");
        }

        Status = PricingRunStatus.ReviewRecorded;
    }
}

public sealed class PricingRunItem
{
    private PricingRunItem()
    {
    }

    public PricingRunItem(
        Guid pricingRunId,
        Guid productListingId,
        string sku,
        string? asin,
        string? title,
        string currencyCode,
        decimal? currentPrice,
        decimal? targetPrice,
        decimal? priceChange,
        decimal? priceChangePercent,
        decimal? currentBusinessPrice,
        decimal? targetBusinessPrice,
        bool isEligible,
        IReadOnlyCollection<string> exclusionCodes,
        IReadOnlyCollection<string> exclusionReasons,
        long snapshotVersion,
        DateTimeOffset synchronizedAtUtc)
    {
        if (pricingRunId == Guid.Empty)
        {
            throw new ArgumentException("Pricing run is required.", nameof(pricingRunId));
        }

        if (productListingId == Guid.Empty)
        {
            throw new ArgumentException("Product listing is required.", nameof(productListingId));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(sku);
        ArgumentException.ThrowIfNullOrWhiteSpace(currencyCode);
        if (snapshotVersion < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(snapshotVersion));
        }

        if (isEligible && (currentPrice is null || targetPrice is null))
        {
            throw new ArgumentException("Eligible items require current and target prices.", nameof(targetPrice));
        }

        if (isEligible && (exclusionCodes.Count > 0 || exclusionReasons.Count > 0))
        {
            throw new ArgumentException("Eligible items cannot have exclusion reasons.", nameof(exclusionCodes));
        }

        if (!isEligible && (exclusionCodes.Count == 0 || exclusionCodes.Count != exclusionReasons.Count))
        {
            throw new ArgumentException("Excluded items require matching codes and reasons.", nameof(exclusionCodes));
        }

        Id = Guid.NewGuid();
        PricingRunId = pricingRunId;
        ProductListingId = productListingId;
        Sku = sku.Trim();
        Asin = Normalize(asin);
        Title = Normalize(title);
        CurrencyCode = currencyCode.Trim().ToUpperInvariant();
        CurrentPrice = currentPrice;
        TargetPrice = targetPrice;
        PriceChange = priceChange;
        PriceChangePercent = priceChangePercent;
        CurrentBusinessPrice = currentBusinessPrice;
        TargetBusinessPrice = targetBusinessPrice;
        IsEligible = isEligible;
        ExclusionCodesData = string.Join('|', exclusionCodes);
        ExclusionReasonsData = string.Join('\n', exclusionReasons);
        SnapshotVersion = snapshotVersion;
        SynchronizedAtUtc = synchronizedAtUtc.ToUniversalTime();
    }

    public Guid Id { get; private set; }

    public Guid PricingRunId { get; private set; }

    public Guid ProductListingId { get; private set; }

    public string Sku { get; private set; } = string.Empty;

    public string? Asin { get; private set; }

    public string? Title { get; private set; }

    public string CurrencyCode { get; private set; } = string.Empty;

    public decimal? CurrentPrice { get; private set; }

    public decimal? TargetPrice { get; private set; }

    public decimal? PriceChange { get; private set; }

    public decimal? PriceChangePercent { get; private set; }

    public decimal? CurrentBusinessPrice { get; private set; }

    public decimal? TargetBusinessPrice { get; private set; }

    public bool IsEligible { get; private set; }

    public string ExclusionCodesData { get; private set; } = string.Empty;

    public string ExclusionReasonsData { get; private set; } = string.Empty;

    public IReadOnlyList<string> ExclusionCodes => Split(ExclusionCodesData, '|');

    public IReadOnlyList<string> ExclusionReasons => Split(ExclusionReasonsData, '\n');

    public long SnapshotVersion { get; private set; }

    public DateTimeOffset SynchronizedAtUtc { get; private set; }

    private static IReadOnlyList<string> Split(string value, char separator) =>
        string.IsNullOrEmpty(value)
            ? []
            : value.Split(separator, StringSplitOptions.RemoveEmptyEntries);

    private static string? Normalize(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
