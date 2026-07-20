namespace Klanata.Domain.Entities;

public enum SellerAuthorizationGrantStatus
{
    Verified,
    Suspended,
    Invalid
}

public sealed class SellerAuthorizationGrant
{
    private SellerAuthorizationGrant()
    {
    }

    public SellerAuthorizationGrant(
        Guid sellerAccountId,
        Guid authorizationProfileId,
        string label,
        int priority,
        bool isPrimary,
        DateTimeOffset verifiedAtUtc)
    {
        if (sellerAccountId == Guid.Empty)
        {
            throw new ArgumentException("Seller account is required.", nameof(sellerAccountId));
        }

        if (authorizationProfileId == Guid.Empty)
        {
            throw new ArgumentException("Authorization profile is required.", nameof(authorizationProfileId));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(label);
        if (priority < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(priority));
        }

        Id = Guid.NewGuid();
        SellerAccountId = sellerAccountId;
        AuthorizationProfileId = authorizationProfileId;
        Label = label.Trim();
        Priority = priority;
        IsPrimary = isPrimary;
        Status = SellerAuthorizationGrantStatus.Verified;
        VerifiedAtUtc = verifiedAtUtc.ToUniversalTime();
    }

    public Guid Id { get; private set; }

    public Guid SellerAccountId { get; private set; }

    public Guid AuthorizationProfileId { get; private set; }

    public string Label { get; private set; } = string.Empty;

    public int Priority { get; private set; }

    public bool IsPrimary { get; private set; }

    public SellerAuthorizationGrantStatus Status { get; private set; }

    public DateTimeOffset VerifiedAtUtc { get; private set; }

    public DateTimeOffset? LastUsedAtUtc { get; private set; }

    public bool CanSubmit => Status == SellerAuthorizationGrantStatus.Verified;

    public void MarkUsed(DateTimeOffset usedAtUtc)
    {
        if (!CanSubmit)
        {
            throw new InvalidOperationException("Only a verified Seller authorization grant can be used.");
        }

        LastUsedAtUtc = usedAtUtc.ToUniversalTime();
    }

    public void SetPrimary(bool isPrimary)
    {
        IsPrimary = isPrimary;
    }

    public void Suspend()
    {
        Status = SellerAuthorizationGrantStatus.Suspended;
        IsPrimary = false;
    }

    public void MarkInvalid()
    {
        Status = SellerAuthorizationGrantStatus.Invalid;
        IsPrimary = false;
    }

    public void Reactivate(DateTimeOffset verifiedAtUtc)
    {
        Status = SellerAuthorizationGrantStatus.Verified;
        VerifiedAtUtc = verifiedAtUtc.ToUniversalTime();
    }
}
