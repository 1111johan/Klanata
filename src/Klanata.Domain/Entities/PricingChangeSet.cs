namespace Klanata.Domain.Entities;

public enum PricingChangeSetStatus
{
    PendingReview,
    ReviewRecorded
}

public sealed class PricingChangeSet
{
    private PricingChangeSet()
    {
    }

    public PricingChangeSet(
        Guid pricingRunId,
        Guid pricingRuleSetId,
        Guid authorizationProfileId,
        string sellerId,
        string marketplaceId,
        string initiatedBy,
        DateTimeOffset createdAtUtc)
    {
        if (pricingRunId == Guid.Empty)
        {
            throw new ArgumentException("Pricing run is required.", nameof(pricingRunId));
        }

        if (pricingRuleSetId == Guid.Empty)
        {
            throw new ArgumentException("Pricing rule set is required.", nameof(pricingRuleSetId));
        }

        if (authorizationProfileId == Guid.Empty)
        {
            throw new ArgumentException("Authorization profile is required.", nameof(authorizationProfileId));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(sellerId);
        ArgumentException.ThrowIfNullOrWhiteSpace(marketplaceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(initiatedBy);

        Id = Guid.NewGuid();
        PricingRunId = pricingRunId;
        PricingRuleSetId = pricingRuleSetId;
        AuthorizationProfileId = authorizationProfileId;
        SellerId = sellerId.Trim();
        MarketplaceId = marketplaceId.Trim();
        InitiatedBy = initiatedBy.Trim();
        Status = PricingChangeSetStatus.PendingReview;
        CreatedAtUtc = createdAtUtc.ToUniversalTime();
    }

    public Guid Id { get; private set; }

    public Guid PricingRunId { get; private set; }

    public Guid PricingRuleSetId { get; private set; }

    public Guid AuthorizationProfileId { get; private set; }

    public string SellerId { get; private set; } = string.Empty;

    public string MarketplaceId { get; private set; } = string.Empty;

    public string InitiatedBy { get; private set; } = string.Empty;

    public PricingChangeSetStatus Status { get; private set; }

    public DateTimeOffset CreatedAtUtc { get; private set; }

    public DateTimeOffset? ApprovedAtUtc { get; private set; }

    public void RecordReview(string reviewer, DateTimeOffset reviewedAtUtc)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(reviewer);
        if (string.Equals(InitiatedBy, reviewer.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("The pricing run initiator cannot review the same change set.");
        }

        if (Status != PricingChangeSetStatus.PendingReview)
        {
            throw new InvalidOperationException("Only a pending change set can record a review.");
        }

        Status = PricingChangeSetStatus.ReviewRecorded;
        ApprovedAtUtc = reviewedAtUtc.ToUniversalTime();
    }
}

public sealed class PricingChangeSetItem
{
    private PricingChangeSetItem()
    {
    }

    public PricingChangeSetItem(
        Guid pricingChangeSetId,
        Guid pricingRunItemId,
        string sku,
        decimal currentPrice,
        decimal targetPrice,
        decimal? currentBusinessPrice,
        decimal? targetBusinessPrice,
        long snapshotVersion,
        string idempotencyKey)
    {
        if (pricingChangeSetId == Guid.Empty)
        {
            throw new ArgumentException("Pricing change set is required.", nameof(pricingChangeSetId));
        }

        if (pricingRunItemId == Guid.Empty)
        {
            throw new ArgumentException("Pricing run item is required.", nameof(pricingRunItemId));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(sku);
        ArgumentException.ThrowIfNullOrWhiteSpace(idempotencyKey);
        if (targetBusinessPrice is not null)
        {
            throw new ArgumentException(
                "V4 P0 change sets cannot contain a target business price.",
                nameof(targetBusinessPrice));
        }

        if (snapshotVersion < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(snapshotVersion));
        }

        Id = Guid.NewGuid();
        PricingChangeSetId = pricingChangeSetId;
        PricingRunItemId = pricingRunItemId;
        Sku = sku.Trim();
        CurrentPrice = currentPrice;
        TargetPrice = targetPrice;
        CurrentBusinessPrice = currentBusinessPrice;
        TargetBusinessPrice = targetBusinessPrice;
        BusinessPriceModified = false;
        SnapshotVersion = snapshotVersion;
        IdempotencyKey = idempotencyKey.Trim();
    }

    public Guid Id { get; private set; }

    public Guid PricingChangeSetId { get; private set; }

    public Guid PricingRunItemId { get; private set; }

    public string Sku { get; private set; } = string.Empty;

    public decimal CurrentPrice { get; private set; }

    public decimal TargetPrice { get; private set; }

    public decimal? CurrentBusinessPrice { get; private set; }

    public decimal? TargetBusinessPrice { get; private set; }

    public bool BusinessPriceModified { get; private set; }

    public long SnapshotVersion { get; private set; }

    public string IdempotencyKey { get; private set; } = string.Empty;
}

public sealed class PricingApproval
{
    private PricingApproval()
    {
    }

    public PricingApproval(
        Guid pricingChangeSetId,
        string approver,
        bool sellerMarketplaceConfirmed,
        bool ruleVersionConfirmed,
        bool anomaliesReviewed,
        bool amazonAcceptanceConfirmed,
        DateTimeOffset approvedAtUtc)
    {
        if (pricingChangeSetId == Guid.Empty)
        {
            throw new ArgumentException("Pricing change set is required.", nameof(pricingChangeSetId));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(approver);
        if (!sellerMarketplaceConfirmed ||
            !ruleVersionConfirmed ||
            !anomaliesReviewed ||
            !amazonAcceptanceConfirmed)
        {
            throw new ArgumentException("All four production confirmations are required.");
        }

        Id = Guid.NewGuid();
        PricingChangeSetId = pricingChangeSetId;
        Approver = approver.Trim();
        SellerMarketplaceConfirmed = sellerMarketplaceConfirmed;
        RuleVersionConfirmed = ruleVersionConfirmed;
        AnomaliesReviewed = anomaliesReviewed;
        AmazonAcceptanceConfirmed = amazonAcceptanceConfirmed;
        ApprovedAtUtc = approvedAtUtc.ToUniversalTime();
    }

    public Guid Id { get; private set; }

    public Guid PricingChangeSetId { get; private set; }

    public string Approver { get; private set; } = string.Empty;

    public bool SellerMarketplaceConfirmed { get; private set; }

    public bool RuleVersionConfirmed { get; private set; }

    public bool AnomaliesReviewed { get; private set; }

    public bool AmazonAcceptanceConfirmed { get; private set; }

    public DateTimeOffset ApprovedAtUtc { get; private set; }
}
