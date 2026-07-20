namespace Klanata.Domain.Entities;

public enum AmazonApiRegion
{
    NorthAmerica,
    Europe,
    FarEast
}

public enum AuthorizationProfileStatus
{
    Pending,
    Verified,
    Invalid,
    Revoked
}

public sealed class AuthorizationProfile
{
    private AuthorizationProfile()
    {
    }

    public AuthorizationProfile(
        Guid developerApplicationId,
        string name,
        AmazonApiRegion region,
        string encryptedSecretReference,
        DateTimeOffset createdAtUtc)
    {
        if (developerApplicationId == Guid.Empty)
        {
            throw new ArgumentException("Developer application is required.", nameof(developerApplicationId));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        ArgumentException.ThrowIfNullOrWhiteSpace(encryptedSecretReference);

        Id = Guid.NewGuid();
        DeveloperApplicationId = developerApplicationId;
        Name = name.Trim();
        Region = region;
        EncryptedSecretReference = encryptedSecretReference.Trim();
        Status = AuthorizationProfileStatus.Pending;
        CreatedAtUtc = createdAtUtc.ToUniversalTime();
    }

    public Guid Id { get; private set; }

    public Guid DeveloperApplicationId { get; private set; }

    public string Name { get; private set; } = string.Empty;

    public AmazonApiRegion Region { get; private set; }

    public string EncryptedSecretReference { get; private set; } = string.Empty;

    public AuthorizationProfileStatus Status { get; private set; }

    public DateTimeOffset CreatedAtUtc { get; private set; }

    public DateTimeOffset? LastVerifiedAtUtc { get; private set; }

    public void MarkVerified(DateTimeOffset verifiedAtUtc)
    {
        Status = AuthorizationProfileStatus.Verified;
        LastVerifiedAtUtc = verifiedAtUtc.ToUniversalTime();
    }

    public void MarkInvalid()
    {
        Status = AuthorizationProfileStatus.Invalid;
    }

    public void Revoke()
    {
        Status = AuthorizationProfileStatus.Revoked;
    }
}
