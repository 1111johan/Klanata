namespace Klanata.Domain.Entities;

public sealed class SellerAccount
{
    private SellerAccount()
    {
    }

    public SellerAccount(
        string sellerId,
        string displayName,
        DateTimeOffset discoveredAtUtc)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sellerId);
        ArgumentException.ThrowIfNullOrWhiteSpace(displayName);

        Id = Guid.NewGuid();
        SellerId = sellerId.Trim();
        DisplayName = displayName.Trim();
        IsActive = true;
        DiscoveredAtUtc = discoveredAtUtc.ToUniversalTime();
        LastDiscoveredAtUtc = DiscoveredAtUtc;
    }

    public Guid Id { get; private set; }

    public string SellerId { get; private set; } = string.Empty;

    public string DisplayName { get; private set; } = string.Empty;

    public bool IsActive { get; private set; }

    public DateTimeOffset DiscoveredAtUtc { get; private set; }

    public DateTimeOffset LastDiscoveredAtUtc { get; private set; }

    public void RefreshDiscovery(string displayName, DateTimeOffset discoveredAtUtc)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(displayName);
        DisplayName = displayName.Trim();
        LastDiscoveredAtUtc = discoveredAtUtc.ToUniversalTime();
        IsActive = true;
    }

    public void Deactivate()
    {
        IsActive = false;
    }
}
