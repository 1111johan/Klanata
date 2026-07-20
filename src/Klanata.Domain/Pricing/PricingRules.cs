using Klanata.Domain.Entities;

namespace Klanata.Domain.Pricing;

public sealed record PricingCalculation(
    decimal TargetPrice,
    decimal ChangeAmount,
    decimal ChangePercentage,
    decimal? TargetBusinessPrice);

public static class PricingRuleCalculator
{
    public static PricingCalculation Calculate(
        PricingRuleSet ruleSet,
        decimal currentPrice,
        decimal? currentBusinessPrice)
    {
        ArgumentNullException.ThrowIfNull(ruleSet);
        if (currentPrice <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(currentPrice));
        }

        var isBelowThreshold = currentPrice <= ruleSet.Threshold;
        var type = isBelowThreshold
            ? ruleSet.BelowThresholdType
            : ruleSet.AtOrAboveThresholdType;
        var value = isBelowThreshold
            ? ruleSet.BelowThresholdValue
            : ruleSet.AtOrAboveThresholdValue;
        var changeMagnitude = type == PricingAdjustmentType.FixedAmount
            ? value
            : currentPrice * value / 100m;

        if (ruleSet.AbsoluteChangeCap is decimal absoluteCap)
        {
            changeMagnitude = Math.Min(changeMagnitude, absoluteCap);
        }

        if (ruleSet.PercentageChangeCap is decimal percentageCap)
        {
            changeMagnitude = Math.Min(changeMagnitude, currentPrice * percentageCap / 100m);
        }

        var signedChange = ruleSet.Direction == PricingDirection.Increase
            ? changeMagnitude
            : -changeMagnitude;
        var target = decimal.Round(
            currentPrice + signedChange,
            ruleSet.CurrencyPrecision,
            MidpointRounding.AwayFromZero);
        if (target <= 0)
        {
            throw new InvalidOperationException("The pricing rule produces a non-positive target price.");
        }

        var actualChange = target - currentPrice;
        var actualPercentage = decimal.Round(
            actualChange / currentPrice * 100m,
            4,
            MidpointRounding.AwayFromZero);

        return new PricingCalculation(
            target,
            actualChange,
            actualPercentage,
            ruleSet.BusinessPriceStrategy == BusinessPriceStrategy.Unchanged
                ? currentBusinessPrice
                : throw new InvalidOperationException("Unsupported business-price strategy."));
    }
}

public sealed record PricingEligibilityDecision(
    bool IsEligible,
    IReadOnlyList<string> Codes,
    IReadOnlyList<string> Reasons);

public static class PureFbmEligibilityEvaluator
{
    public static PricingEligibilityDecision Evaluate(
        ProductListing listing,
        IReadOnlySet<string> fbaAsins,
        DateTimeOffset now,
        TimeSpan maximumSnapshotAge)
    {
        ArgumentNullException.ThrowIfNull(listing);
        ArgumentNullException.ThrowIfNull(fbaAsins);
        if (maximumSnapshotAge <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumSnapshotAge));
        }

        var codes = new List<string>();
        var reasons = new List<string>();

        AddIf(
            listing.FulfillmentChannel != FulfillmentChannel.Mfn,
            "NOT_MFN",
            "非 MFN（卖家配送）商品",
            codes,
            reasons);
        AddIf(
            listing.Status != ListingStatus.Active,
            "LISTING_NOT_ACTIVE",
            "商品状态不是在线可售",
            codes,
            reasons);
        AddIf(
            listing.MfnQuantity is null or <= 0,
            "NO_SELLABLE_INVENTORY",
            "MFN 可售库存为 0 或缺失",
            codes,
            reasons);
        AddIf(
            listing.Price is null or <= 0,
            "MISSING_PRICE",
            "当前售价缺失或无效",
            codes,
            reasons);
        AddIf(
            now.ToUniversalTime() - listing.SynchronizedAtUtc > maximumSnapshotAge,
            "STALE_SNAPSHOT",
            "商品快照已过期，必须重新同步",
            codes,
            reasons);
        AddIf(
            !string.IsNullOrWhiteSpace(listing.Asin) && fbaAsins.Contains(listing.Asin),
            "SAME_ASIN_HAS_FBA",
            "同一 ASIN 存在 FBA 商品，已按纯 FBM 规则排除",
            codes,
            reasons);

        return new PricingEligibilityDecision(codes.Count == 0, codes, reasons);
    }

    private static void AddIf(
        bool condition,
        string code,
        string reason,
        ICollection<string> codes,
        ICollection<string> reasons)
    {
        if (!condition)
        {
            return;
        }

        codes.Add(code);
        reasons.Add(reason);
    }
}
