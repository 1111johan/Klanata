using Klanata.Application.Abstractions;
using Klanata.Application.Platform;
using Klanata.Application.Catalog;
using Klanata.Infrastructure.Catalog;
using Klanata.Infrastructure.Configuration;
using Klanata.Infrastructure.Files;
using Klanata.Infrastructure.Persistence;
using Klanata.Infrastructure.Platform;
using Klanata.Infrastructure.Pricing;
using Klanata.Infrastructure.Time;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Klanata.Infrastructure;

public static class DependencyInjection
{
    public static IServiceCollection AddKlanataInfrastructure(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.AddOptions<WorkstationOptions>()
            .Bind(configuration.GetSection(WorkstationOptions.SectionName))
            .Validate(
                options => options.AllowedSellerIds?.Any(item => !string.IsNullOrWhiteSpace(item)) is true,
                "Workstation:AllowedSellerIds must contain at least one Amazon Seller ID.")
            .ValidateOnStart();
        services.AddSingleton<IAllowedSellerPolicy, AllowedSellerPolicy>();
        services.AddSingleton<IClock, SystemClock>();
        services.AddSingleton<IDataPathProvider, DataPathProvider>();
        services.AddSingleton(new PlatformRuntimeInfo(Guid.NewGuid().ToString("N"), DateTimeOffset.UtcNow));
        services.AddSingleton<SqlitePragmaInterceptor>();
        services.AddDbContextFactory<WorkstationDbContext>((serviceProvider, options) =>
        {
            var paths = serviceProvider.GetRequiredService<IDataPathProvider>();
            var workstationOptions = serviceProvider.GetRequiredService<Microsoft.Extensions.Options.IOptions<WorkstationOptions>>().Value;
            options
                .UseSqlite($"Data Source={paths.DatabasePath};Cache=Shared;Pooling={workstationOptions.SqlitePooling};Foreign Keys=True;Default Timeout=5")
                .AddInterceptors(serviceProvider.GetRequiredService<SqlitePragmaInterceptor>());
        });
        services.AddScoped<IDatabaseInitializer, DatabaseInitializer>();
        services.AddScoped<ICatalogWorkspaceService, CatalogWorkspaceService>();
        services.AddScoped<Klanata.Application.Pricing.IPricingWorkflowService, PricingWorkflowService>();
        services.AddSingleton<ISystemStatusService, SystemStatusService>();
        return services;
    }
}
