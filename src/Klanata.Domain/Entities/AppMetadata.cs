namespace Klanata.Domain.Entities;

public sealed class AppMetadata
{
    private AppMetadata()
    {
    }

    public AppMetadata(string key, string value, DateTimeOffset updatedAtUtc)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        ArgumentNullException.ThrowIfNull(value);
        Key = key.Trim();
        Value = value;
        UpdatedAtUtc = updatedAtUtc.ToUniversalTime();
    }

    public string Key { get; private set; } = string.Empty;

    public string Value { get; private set; } = string.Empty;

    public DateTimeOffset UpdatedAtUtc { get; private set; }

    public void Update(string value, DateTimeOffset updatedAtUtc)
    {
        ArgumentNullException.ThrowIfNull(value);
        Value = value;
        UpdatedAtUtc = updatedAtUtc.ToUniversalTime();
    }
}
