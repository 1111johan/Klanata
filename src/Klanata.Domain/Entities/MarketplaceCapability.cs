namespace Klanata.Domain.Entities;

public sealed class MarketplaceCapability
{
    private MarketplaceCapability()
    {
    }

    public MarketplaceCapability(
        Guid marketplaceParticipationId,
        bool canReadListings,
        bool canReadCatalog,
        bool canReadPricing,
        DateTimeOffset verifiedAtUtc,
        string writeBlockReason)
    {
        if (marketplaceParticipationId == Guid.Empty)
        {
            throw new ArgumentException("Marketplace participation is required.", nameof(marketplaceParticipationId));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(writeBlockReason);

        Id = Guid.NewGuid();
        MarketplaceParticipationId = marketplaceParticipationId;
        CanReadListings = canReadListings;
        CanReadCatalog = canReadCatalog;
        CanReadPricing = canReadPricing;
        CanCreateDraftChangeSets = false;
        CanSimulatePricing = false;
        CanWritePrices = false;
        CanWriteMfnInventory = false;
        VerifiedAtUtc = verifiedAtUtc.ToUniversalTime();
        WriteBlockReason = writeBlockReason.Trim();
    }

    public Guid Id { get; private set; }

    public Guid MarketplaceParticipationId { get; private set; }

    public bool CanReadListings { get; private set; }

    public bool CanReadCatalog { get; private set; }

    public bool CanReadPricing { get; private set; }

    public bool CanCreateDraftChangeSets { get; private set; }

    public bool CanSimulatePricing { get; private set; }

    public bool CanWritePrices { get; private set; }

    public bool CanWriteMfnInventory { get; private set; }

    public DateTimeOffset VerifiedAtUtc { get; private set; }

    public string WriteBlockReason { get; private set; } = string.Empty;

    public void RefreshReadCapabilities(
        bool canReadListings,
        bool canReadCatalog,
        bool canReadPricing,
        DateTimeOffset verifiedAtUtc)
    {
        CanReadListings = canReadListings;
        CanReadCatalog = canReadCatalog;
        CanReadPricing = canReadPricing;
        VerifiedAtUtc = verifiedAtUtc.ToUniversalTime();
    }

    public void EnablePricingDraftWorkflow(DateTimeOffset verifiedAtUtc)
    {
        if (!CanReadListings || !CanReadPricing)
        {
            throw new InvalidOperationException(
                "Pricing simulation requires verified Listings and Pricing read capabilities.");
        }

        CanCreateDraftChangeSets = true;
        CanSimulatePricing = true;
        CanWritePrices = false;
        VerifiedAtUtc = verifiedAtUtc.ToUniversalTime();
        WriteBlockReason = "V4 pricing drafts are enabled; Amazon price writes remain blocked by production validation.";
    }
}
