namespace Klanata.Domain.Entities;

public sealed class WorkerLease
{
    private WorkerLease()
    {
    }

    public WorkerLease(string leaseKey)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(leaseKey);
        LeaseKey = leaseKey.Trim();
    }

    public string LeaseKey { get; private set; } = string.Empty;

    public string? OwnerInstanceId { get; private set; }

    public DateTimeOffset? AcquiredAtUtc { get; private set; }

    public DateTimeOffset? ExpiresAtUtc { get; private set; }

    public DateTimeOffset? HeartbeatAtUtc { get; private set; }

    public long Version { get; private set; }

    public bool IsExpired(DateTimeOffset now) => ExpiresAtUtc is null || ExpiresAtUtc <= now.ToUniversalTime();

    public bool TryAcquire(string ownerInstanceId, DateTimeOffset now, TimeSpan duration)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerInstanceId);
        if (duration <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(duration));
        }

        var utcNow = now.ToUniversalTime();
        if (!string.Equals(OwnerInstanceId, ownerInstanceId, StringComparison.Ordinal) && !IsExpired(utcNow))
        {
            return false;
        }

        OwnerInstanceId = ownerInstanceId.Trim();
        AcquiredAtUtc ??= utcNow;
        HeartbeatAtUtc = utcNow;
        ExpiresAtUtc = utcNow.Add(duration);
        Version++;
        return true;
    }

    public void Release(string ownerInstanceId, DateTimeOffset now)
    {
        if (!string.Equals(OwnerInstanceId, ownerInstanceId, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Only the lease owner can release the lease.");
        }

        HeartbeatAtUtc = now.ToUniversalTime();
        ExpiresAtUtc = HeartbeatAtUtc;
        OwnerInstanceId = null;
        Version++;
    }
}
