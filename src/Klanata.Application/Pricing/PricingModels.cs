namespace Klanata.Application.Pricing;

public sealed record PricingRuleBandRequest(string Type, decimal Value);

public sealed record PricingRuleRequest(
    string Name,
    string Direction,
    decimal Threshold,
    PricingRuleBandRequest BelowThreshold,
    PricingRuleBandRequest AtOrAboveThreshold,
    decimal? AbsoluteChangeCap,
    decimal? PercentageChangeCap,
    int CurrencyPrecision = 0,
    string BusinessPriceStrategy = "UNCHANGED");

public sealed record CreatePricingRunRequest(
    string SellerId,
    string MarketplaceId,
    string Initiator,
    PricingRuleRequest Rule,
    string IdempotencyKey);

public sealed record PricingRuleBandView(string Type, decimal Value);

public sealed record PricingRuleView(
    Guid Id,
    int Version,
    string Name,
    string Direction,
    decimal Threshold,
    PricingRuleBandView BelowThreshold,
    PricingRuleBandView AtOrAboveThreshold,
    decimal? AbsoluteChangeCap,
    decimal? PercentageChangeCap,
    string CurrencyCode,
    int CurrencyPrecision,
    string BusinessPriceStrategy);

public sealed record PricingRunSummary(
    int Total,
    int Eligible,
    int Excluded,
    int BusinessPriceModifiedCount);

public sealed record PricingRunItemView(
    Guid Id,
    string Sku,
    string? Asin,
    string? Title,
    bool Eligible,
    IReadOnlyList<string> ExclusionCodes,
    IReadOnlyList<string> ExclusionReasons,
    decimal? CurrentPrice,
    decimal? TargetPrice,
    decimal? PriceChange,
    decimal? PriceChangePercent,
    decimal? CurrentBusinessPrice,
    decimal? TargetBusinessPrice,
    string CurrencyCode,
    long SnapshotVersion,
    DateTimeOffset SynchronizedAtUtc);

public sealed record PricingRunView(
    Guid Id,
    string RunNumber,
    string SellerId,
    string MarketplaceId,
    string Status,
    string InitiatedBy,
    DateTimeOffset CreatedAtUtc,
    PricingRuleView Rule,
    PricingRunSummary Summary,
    IReadOnlyList<PricingRunItemView> Items,
    PricingChangeSetView? ChangeSet);

public sealed record PricingApprovalView(
    Guid Id,
    string Approver,
    bool IdentityVerified,
    string IdentityAssurance,
    bool SellerMarketplaceConfirmed,
    bool RuleVersionConfirmed,
    bool AnomaliesReviewed,
    bool AmazonAcceptanceConfirmed,
    DateTimeOffset ApprovedAtUtc);

public sealed record PricingChangeSetView(
    Guid Id,
    Guid RunId,
    string SellerId,
    string MarketplaceId,
    string Status,
    string InitiatedBy,
    int ItemCount,
    DateTimeOffset CreatedAtUtc,
    DateTimeOffset? ApprovedAtUtc,
    PricingApprovalView? Approval);

public sealed record PricingApprovalConfirmations(
    bool SellerMarketplace,
    bool RuleVersion,
    bool AnomaliesReviewed,
    bool AmazonAcceptance);

public sealed record ApprovePricingChangeSetRequest(
    string Approver,
    PricingApprovalConfirmations Confirmations);

public sealed record PricingSyncStatus(
    string SellerId,
    string MarketplaceId,
    string State,
    bool ReportsExecutorAvailable,
    bool CanStart,
    int ListingCount,
    DateTimeOffset? LastSynchronizedAtUtc,
    long? SnapshotAgeSeconds,
    string Detail);

public sealed record PricingValidationBlock(
    Guid ChangeSetId,
    string Code,
    string Detail,
    bool AmazonWriteAttempted);
