namespace Klanata.Domain.Entities;

public sealed class DeveloperApplication
{
    private DeveloperApplication()
    {
    }

    public DeveloperApplication(
        string name,
        string clientIdFingerprint,
        DateTimeOffset createdAtUtc)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        ArgumentException.ThrowIfNullOrWhiteSpace(clientIdFingerprint);

        Id = Guid.NewGuid();
        Name = name.Trim();
        ClientIdFingerprint = clientIdFingerprint.Trim();
        CreatedAtUtc = createdAtUtc.ToUniversalTime();
        IsActive = true;
    }

    public Guid Id { get; private set; }

    public string Name { get; private set; } = string.Empty;

    public string ClientIdFingerprint { get; private set; } = string.Empty;

    public bool IsActive { get; private set; }

    public DateTimeOffset CreatedAtUtc { get; private set; }

    public DateTimeOffset? LastValidatedAtUtc { get; private set; }

    public void RecordValidation(DateTimeOffset validatedAtUtc)
    {
        LastValidatedAtUtc = validatedAtUtc.ToUniversalTime();
    }

    public void Deactivate()
    {
        IsActive = false;
    }
}
