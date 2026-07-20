using Microsoft.Extensions.DependencyInjection;

namespace Klanata.Workers;

public static class DependencyInjection
{
    public static IServiceCollection AddKlanataWorkers(this IServiceCollection services)
    {
        services.AddHostedService<PlatformHeartbeatWorker>();
        return services;
    }
}
