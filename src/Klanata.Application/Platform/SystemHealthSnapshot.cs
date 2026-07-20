namespace Klanata.Application.Platform;

public sealed record SystemHealthSnapshot(
    string OverallStatus,
    ComponentHealth Service,
    ComponentHealth Database,
    ComponentHealth Disk,
    ComponentHealth Worker,
    ComponentHealth SecretStore,
    string Environment,
    string BindAddress,
    string DataRoot,
    long AvailableDiskBytes,
    DateTimeOffset CheckedAtUtc)
{
    public static SystemHealthSnapshot Create(
        ComponentHealth service,
        ComponentHealth database,
        ComponentHealth disk,
        ComponentHealth worker,
        ComponentHealth secretStore,
        string environment,
        string bindAddress,
        string dataRoot,
        long availableDiskBytes,
        DateTimeOffset checkedAtUtc)
    {
        var requiredStatuses = new[] { service.Status, database.Status, disk.Status, worker.Status };
        var overallStatus = requiredStatuses.Contains("unhealthy", StringComparer.Ordinal)
            ? "unhealthy"
            : requiredStatuses.Contains("degraded", StringComparer.Ordinal)
                ? "degraded"
                : "healthy";

        return new SystemHealthSnapshot(
            overallStatus,
            service,
            database,
            disk,
            worker,
            secretStore,
            environment,
            bindAddress,
            dataRoot,
            availableDiskBytes,
            checkedAtUtc.ToUniversalTime());
    }
}
