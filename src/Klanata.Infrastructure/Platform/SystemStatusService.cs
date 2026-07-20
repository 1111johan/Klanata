using System.Reflection;
using System.Runtime.InteropServices;
using Klanata.Application.Abstractions;
using Klanata.Application.Platform;
using Klanata.Infrastructure.Configuration;
using Klanata.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

namespace Klanata.Infrastructure.Platform;

public sealed class SystemStatusService(
    IDbContextFactory<WorkstationDbContext> dbContextFactory,
    IDataPathProvider paths,
    IClock clock,
    IHostEnvironment environment,
    IConfiguration configuration,
    IOptions<WorkstationOptions> options,
    PlatformRuntimeInfo runtimeInfo) : ISystemStatusService
{
    public async Task<SystemHealthSnapshot> GetHealthAsync(CancellationToken cancellationToken)
    {
        var now = clock.UtcNow;
        var database = await GetDatabaseHealthAsync(cancellationToken);
        var (disk, availableBytes) = GetDiskHealth();
        var worker = await GetWorkerHealthAsync(now, cancellationToken);
        var bindAddress = configuration["Urls"] ?? "http://127.0.0.1:4317";

        return SystemHealthSnapshot.Create(
            ComponentHealth.Healthy($"Instance {runtimeInfo.InstanceId[..8]} is running."),
            database,
            disk,
            worker,
            ComponentHealth.NotConfigured("Encrypted authorization vault migration is pending; no secrets are stored in this service."),
            environment.EnvironmentName,
            bindAddress,
            paths.DataRoot,
            availableBytes,
            now);
    }

    public async Task<SystemVersionSnapshot> GetVersionAsync(CancellationToken cancellationToken)
    {
        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        var schema = await dbContext.AppMetadata
            .Where(item => item.Key == "schema-version")
            .Select(item => item.Value)
            .SingleOrDefaultAsync(cancellationToken) ?? "uninitialized";
        var version = typeof(SystemStatusService).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? "4.0.0-p0";

        return new SystemVersionSnapshot(
            version,
            "V4 P0 - API-native Pricing Foundation",
            RuntimeInformation.FrameworkDescription,
            "SQLite / EF Core 10",
            RuntimeInformation.RuntimeIdentifier,
            schema,
            runtimeInfo.StartedAtUtc);
    }

    private async Task<ComponentHealth> GetDatabaseHealthAsync(CancellationToken cancellationToken)
    {
        try
        {
            await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
            await dbContext.Database.ExecuteSqlRawAsync("SELECT 1;", cancellationToken);
            var appliedMigrations = await dbContext.Database.GetAppliedMigrationsAsync(cancellationToken);
            return ComponentHealth.Healthy($"SQLite is writable; {appliedMigrations.Count()} migration(s) applied.");
        }
        catch (Exception exception)
        {
            return ComponentHealth.Unhealthy($"SQLite check failed: {exception.GetType().Name}");
        }
    }

    private (ComponentHealth Health, long AvailableBytes) GetDiskHealth()
    {
        try
        {
            var root = Path.GetPathRoot(paths.DataRoot) ?? paths.DataRoot;
            var availableBytes = new DriveInfo(root).AvailableFreeSpace;
            if (availableBytes < options.Value.MinimumOperationalFreeBytes)
            {
                return (ComponentHealth.Unhealthy("Available disk space is below the operational limit."), availableBytes);
            }

            if (availableBytes < options.Value.MinimumStartupFreeBytes)
            {
                return (ComponentHealth.Degraded("Available disk space is below the recommended startup limit."), availableBytes);
            }

            return (ComponentHealth.Healthy("Disk space is within the configured limit."), availableBytes);
        }
        catch (Exception exception)
        {
            return (ComponentHealth.Unhealthy($"Disk check failed: {exception.GetType().Name}"), 0);
        }
    }

    private async Task<ComponentHealth> GetWorkerHealthAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        try
        {
            await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
            var heartbeat = await dbContext.WorkerLeases
                .AsNoTracking()
                .SingleOrDefaultAsync(item => item.LeaseKey == "platform-heartbeat", cancellationToken);
            if (heartbeat?.HeartbeatAtUtc is null)
            {
                return ComponentHealth.Degraded("Background worker heartbeat has not been recorded yet.");
            }

            var age = now - heartbeat.HeartbeatAtUtc.Value;
            return age <= TimeSpan.FromSeconds(options.Value.WorkerLeaseSeconds)
                ? ComponentHealth.Healthy($"Last heartbeat was {Math.Max(0, (int)age.TotalSeconds)} second(s) ago.")
                : ComponentHealth.Unhealthy("Background worker heartbeat is stale.");
        }
        catch (Exception exception)
        {
            return ComponentHealth.Unhealthy($"Worker check failed: {exception.GetType().Name}");
        }
    }
}
