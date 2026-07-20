using FluentAssertions;
using Klanata.Domain.Entities;

namespace Klanata.Domain.Tests;

public sealed class CommerceContextTests
{
    [Fact]
    public void SellerAuthorizationGrant_AllowsMultipleVerifiedProfilesPerSeller()
    {
        var sellerId = Guid.NewGuid();
        var first = new SellerAuthorizationGrant(
            sellerId,
            Guid.NewGuid(),
            "Primary token",
            0,
            true,
            DateTimeOffset.UtcNow);
        var second = new SellerAuthorizationGrant(
            sellerId,
            Guid.NewGuid(),
            "Backup token",
            10,
            false,
            DateTimeOffset.UtcNow);

        first.CanSubmit.Should().BeTrue();
        second.CanSubmit.Should().BeTrue();
        first.AuthorizationProfileId.Should().NotBe(second.AuthorizationProfileId);

        second.MarkUsed(DateTimeOffset.UtcNow);
        second.LastUsedAtUtc.Should().NotBeNull();
    }

    [Fact]
    public void MarketplaceCapability_ProductionWritesStartLocked()
    {
        var capability = new MarketplaceCapability(
            Guid.NewGuid(),
            true,
            true,
            true,
            DateTimeOffset.UtcNow,
            "Production rollout gate is closed.");

        capability.CanReadListings.Should().BeTrue();
        capability.CanCreateDraftChangeSets.Should().BeFalse();
        capability.CanSimulatePricing.Should().BeFalse();
        capability.CanWritePrices.Should().BeFalse();
        capability.CanWriteMfnInventory.Should().BeFalse();
    }

    [Fact]
    public void PricingDraftWorkflow_EnablesOnlySafeDraftCapabilities()
    {
        var now = DateTimeOffset.UtcNow;
        var capability = new MarketplaceCapability(
            Guid.NewGuid(),
            true,
            true,
            true,
            now,
            "Pricing drafts are disabled.");

        capability.EnablePricingDraftWorkflow(now);

        capability.CanSimulatePricing.Should().BeTrue();
        capability.CanCreateDraftChangeSets.Should().BeTrue();
        capability.CanWritePrices.Should().BeFalse();
        capability.CanWriteMfnInventory.Should().BeFalse();
    }

    [Fact]
    public void ProductListing_CannotMoveAcrossProductionContext()
    {
        var now = DateTimeOffset.UtcNow;
        var listing = new ProductListing(
            Guid.NewGuid(),
            "SELLER-ONE",
            "MARKETPLACE-ONE",
            "SKU-001",
            null,
            "Product",
            FulfillmentChannel.Mfn,
            ListingStatus.Active,
            "USD",
            19.99m,
            null,
            5,
            now);

        var action = () => listing.RefreshSnapshot(
            "SELLER-TWO",
            "MARKETPLACE-ONE",
            null,
            "Product",
            FulfillmentChannel.Mfn,
            ListingStatus.Active,
            "USD",
            19.99m,
            null,
            5,
            now,
            null,
            null);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*cannot move to another Seller or Marketplace*");
        listing.SellerId.Should().Be("SELLER-ONE");
        listing.SnapshotVersion.Should().Be(1);
    }
}
