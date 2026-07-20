namespace Klanata.Infrastructure.Configuration;

public sealed class WorkstationOptions
{
    public const string SectionName = "Workstation";

    public string? DataRoot { get; init; }

    public string DatabaseFileName { get; init; } = "klanata.db";

    public bool SqlitePooling { get; init; } = true;

    public bool SingleInstanceEnabled { get; init; } = true;

    public string[] AllowedSellerIds { get; init; } = [];

    public long MinimumStartupFreeBytes { get; init; } = 2L * 1024 * 1024 * 1024;

    public long MinimumOperationalFreeBytes { get; init; } = 500L * 1024 * 1024;

    public int WorkerHeartbeatSeconds { get; init; } = 15;

    public int WorkerLeaseSeconds { get; init; } = 45;
}
