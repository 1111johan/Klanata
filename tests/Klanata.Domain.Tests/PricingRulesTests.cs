using FluentAssertions;
using Klanata.Domain.Entities;
using Klanata.Domain.Pricing;

namespace Klanata.Domain.Tests;

public sealed class PricingRulesTests
{
    [Fact]
    public void Calculate_UsesLowBandAtThresholdAndKeepsBusinessPriceUnchanged()
    {
        var rule = CreateRule(
            currencyCode: "USD",
            currencyPrecision: 2,
            belowType: PricingAdjustmentType.FixedAmount,
            belowValue: 0.50m,
            upperType: PricingAdjustmentType.Percentage,
            upperValue: 0.90m);

        var result = PricingRuleCalculator.Calculate(rule, 100m, 88.25m);

        result.TargetPrice.Should().Be(100.50m);
        result.ChangeAmount.Should().Be(0.50m);
        result.TargetBusinessPrice.Should().Be(88.25m);
        rule.BusinessPriceStrategy.Should().Be(BusinessPriceStrategy.Unchanged);
    }

    [Fact]
    public void Calculate_UsesHighBandAboveThresholdAndAppliesBothCaps()
    {
        var rule = CreateRule(
            currencyCode: "USD",
            currencyPrecision: 2,
            belowType: PricingAdjustmentType.FixedAmount,
            belowValue: 0.50m,
            upperType: PricingAdjustmentType.Percentage,
            upperValue: 5m,
            absoluteCap: 0.90m,
            percentageCap: 1m);

        var result = PricingRuleCalculator.Calculate(rule, 200m, null);

        result.TargetPrice.Should().Be(200.90m);
        result.ChangeAmount.Should().Be(0.90m);
        result.ChangePercentage.Should().Be(0.45m);
    }

    [Fact]
    public void Calculate_UsesMarketplaceCurrencyPrecision()
    {
        var rule = CreateRule(
            currencyCode: "JPY",
            currencyPrecision: 0,
            belowType: PricingAdjustmentType.FixedAmount,
            belowValue: 0.60m,
            upperType: PricingAdjustmentType.FixedAmount,
            upperValue: 0.60m);

        PricingRuleCalculator.Calculate(rule, 99m, null).TargetPrice.Should().Be(100m);
    }

    [Fact]
    public void PureFbmFilter_ReturnsEveryExplainableExclusion()
    {
        var now = new DateTimeOffset(2026, 7, 17, 7, 0, 0, TimeSpan.Zero);
        var listing = new ProductListing(
            Guid.NewGuid(),
            "SELLER",
            "MARKETPLACE",
            "SKU-EXCLUDED",
            "ASIN-FBA",
            "Excluded item",
            FulfillmentChannel.Fba,
            ListingStatus.Inactive,
            "USD",
            null,
            null,
            0,
            now.AddHours(-13));

        var decision = PureFbmEligibilityEvaluator.Evaluate(
            listing,
            new HashSet<string>(["ASIN-FBA"], StringComparer.OrdinalIgnoreCase),
            now,
            TimeSpan.FromHours(12));

        decision.IsEligible.Should().BeFalse();
        decision.Codes.Should().BeEquivalentTo(
            "NOT_MFN",
            "LISTING_NOT_ACTIVE",
            "NO_SELLABLE_INVENTORY",
            "MISSING_PRICE",
            "STALE_SNAPSHOT",
            "SAME_ASIN_HAS_FBA");
        decision.Reasons.Should().OnlyContain(reason => !string.IsNullOrWhiteSpace(reason));
    }

    [Fact]
    public void ChangeSet_RejectsSelfReview()
    {
        var changeSet = new PricingChangeSet(
            Guid.NewGuid(),
            Guid.NewGuid(),
            Guid.NewGuid(),
            "SELLER",
            "MARKETPLACE",
            "operator-a",
            DateTimeOffset.UtcNow);

        var action = () => changeSet.RecordReview("Operator-A", DateTimeOffset.UtcNow);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*cannot review*");
    }

    [Fact]
    public void ChangeSetItem_RejectsBusinessPriceTarget()
    {
        var action = () => new PricingChangeSetItem(
            Guid.NewGuid(),
            Guid.NewGuid(),
            "SKU-B2B",
            100m,
            100.50m,
            90m,
            90.50m,
            1,
            "idempotency-key");

        action.Should().Throw<ArgumentException>()
            .WithParameterName("targetBusinessPrice");
    }

    private static PricingRuleSet CreateRule(
        string currencyCode,
        int currencyPrecision,
        PricingAdjustmentType belowType,
        decimal belowValue,
        PricingAdjustmentType upperType,
        decimal upperValue,
        decimal? absoluteCap = null,
        decimal? percentageCap = null) =>
        new(
            Guid.NewGuid(),
            Guid.NewGuid(),
            "SELLER",
            "MARKETPLACE",
            "Pricing rule",
            1,
            PricingDirection.Increase,
            100m,
            belowType,
            belowValue,
            upperType,
            upperValue,
            absoluteCap,
            percentageCap,
            currencyCode,
            currencyPrecision,
            BusinessPriceStrategy.Unchanged,
            "operator-a",
            DateTimeOffset.UtcNow);
}
