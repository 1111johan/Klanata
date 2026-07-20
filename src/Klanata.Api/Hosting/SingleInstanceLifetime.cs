using Klanata.Infrastructure.Configuration;
using Microsoft.Extensions.Options;

namespace Klanata.Api.Hosting;

public sealed class SingleInstanceLifetime(
    IOptions<WorkstationOptions> options,
    ILogger<SingleInstanceLifetime> logger) : IHostedService, IDisposable
{
    private Mutex? _mutex;
    private bool _ownsMutex;

    public Task StartAsync(CancellationToken cancellationToken)
    {
        if (!options.Value.SingleInstanceEnabled)
        {
            logger.LogInformation("Single-instance enforcement is disabled for this environment.");
            return Task.CompletedTask;
        }

        _mutex = new Mutex(true, "Local\\Klanata.Inventory.Workstation.V2", out _ownsMutex);
        if (!_ownsMutex)
        {
            throw new InvalidOperationException("Another Klanata Inventory Workstation v2 instance is already running.");
        }

        logger.LogInformation("Single-instance mutex acquired.");
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        ReleaseMutex();
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        ReleaseMutex();
        _mutex?.Dispose();
    }

    private void ReleaseMutex()
    {
        if (!_ownsMutex || _mutex is null)
        {
            return;
        }

        _mutex.ReleaseMutex();
        _ownsMutex = false;
    }
}
