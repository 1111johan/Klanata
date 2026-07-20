using Klanata.Application.Platform;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace Klanata.Api.Health;

public sealed class PlatformReadinessHealthCheck(ISystemStatusService systemStatusService) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context,
        CancellationToken cancellationToken = default)
    {
        var snapshot = await systemStatusService.GetHealthAsync(cancellationToken);
        return snapshot.OverallStatus switch
        {
            "healthy" => HealthCheckResult.Healthy("Platform is ready."),
            "degraded" => HealthCheckResult.Degraded("Platform is running with degraded components."),
            _ => HealthCheckResult.Unhealthy("Platform is not ready.")
        };
    }
}
