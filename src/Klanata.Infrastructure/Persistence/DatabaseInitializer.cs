using System.Reflection;
using Klanata.Application.Abstractions;
using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;

namespace Klanata.Infrastructure.Persistence;

public sealed class DatabaseInitializer(
    IDbContextFactory<WorkstationDbContext> dbContextFactory,
    IClock clock) : IDatabaseInitializer
{
    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        await dbContext.Database.MigrateAsync(cancellationToken);
        await ConfigureSqliteAsync(dbContext, cancellationToken);

        var now = clock.UtcNow;
        var schemaVersion = await dbContext.AppMetadata.FindAsync(["schema-version"], cancellationToken);
        if (schemaVersion is null)
        {
            dbContext.AppMetadata.Add(new AppMetadata("schema-version", "V4PricingFoundation", now));
        }
        else
        {
            schemaVersion.Update("V4PricingFoundation", now);
        }

        var version = typeof(DatabaseInitializer).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? "4.0.0-p0";
        dbContext.AuditEvents.Add(AuditEvent.Create(
            now,
            "SYSTEM",
            "PLATFORM_STARTED",
            "Platform",
            "Klanata.Inventory.Workstation",
            Guid.NewGuid().ToString("N"),
            Environment.MachineName,
            version));

        await dbContext.SaveChangesAsync(cancellationToken);
    }

    private static async Task ConfigureSqliteAsync(
        WorkstationDbContext dbContext,
        CancellationToken cancellationToken)
    {
        var connection = dbContext.Database.GetDbConnection();
        await connection.OpenAsync(cancellationToken);
        try
        {
            foreach (var statement in new[]
                     {
                         "PRAGMA foreign_keys = ON;",
                         "PRAGMA journal_mode = WAL;",
                         "PRAGMA synchronous = FULL;",
                         "PRAGMA busy_timeout = 5000;"
                     })
            {
                await using var command = connection.CreateCommand();
                command.CommandText = statement;
                await command.ExecuteNonQueryAsync(cancellationToken);
            }
        }
        finally
        {
            await connection.CloseAsync();
        }
    }
}
