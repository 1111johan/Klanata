using Klanata.Application.Abstractions;
using Klanata.Domain.Entities;
using Klanata.Infrastructure.Configuration;
using Klanata.Infrastructure.Persistence;
using Klanata.Infrastructure.Platform;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Klanata.Workers;

public sealed class PlatformHeartbeatWorker(
    IDbContextFactory<WorkstationDbContext> dbContextFactory,
    IClock clock,
    IOptions<WorkstationOptions> options,
    PlatformRuntimeInfo runtimeInfo,
    ILogger<PlatformHeartbeatWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(options.Value.WorkerHeartbeatSeconds));
        do
        {
            await WriteHeartbeatAsync(stoppingToken);
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    private async Task WriteHeartbeatAsync(CancellationToken cancellationToken)
    {
        try
        {
            await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
            var lease = await dbContext.WorkerLeases
                .SingleOrDefaultAsync(item => item.LeaseKey == "platform-heartbeat", cancellationToken);
            if (lease is null)
            {
                lease = new WorkerLease("platform-heartbeat");
                dbContext.WorkerLeases.Add(lease);
            }

            if (!lease.TryAcquire(
                    runtimeInfo.InstanceId,
                    clock.UtcNow,
                    TimeSpan.FromSeconds(options.Value.WorkerLeaseSeconds)))
            {
                logger.LogWarning("Platform heartbeat lease is owned by another active instance.");
                return;
            }

            await dbContext.SaveChangesAsync(cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            logger.LogError(exception, "Failed to persist the platform worker heartbeat.");
        }
    }
}
