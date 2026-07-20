using FluentAssertions;
using Klanata.Application.Abstractions;
using Klanata.Infrastructure;
using Klanata.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Hosting;

namespace Klanata.Infrastructure.Tests;

public sealed class DatabaseInitializerTests : IAsyncLifetime
{
    private readonly string _dataRoot = Path.Combine(Path.GetTempPath(), "klanata-tests", Guid.NewGuid().ToString("N"));

    public Task InitializeAsync() => Task.CompletedTask;

    public Task DisposeAsync()
    {
        if (Directory.Exists(_dataRoot))
        {
            Directory.Delete(_dataRoot, true);
        }
        return Task.CompletedTask;
    }

    [Fact]
    public async Task InitializeAsync_AppliesMigrationPragmasAndStartupAudit()
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Workstation:DataRoot"] = _dataRoot,
                ["Workstation:SingleInstanceEnabled"] = "false",
                ["Workstation:SqlitePooling"] = "false",
                ["Workstation:AllowedSellerIds:0"] = "SELLER-TEST"
            })
            .Build();
        var services = new ServiceCollection();
        services.AddSingleton<IHostEnvironment>(new TestHostEnvironment(_dataRoot));
        services.AddKlanataInfrastructure(configuration);
        await using var provider = services.BuildServiceProvider();

        await using (var scope = provider.CreateAsyncScope())
        {
            var initializer = scope.ServiceProvider.GetRequiredService<IDatabaseInitializer>();
            await initializer.InitializeAsync(CancellationToken.None);
        }

        var factory = provider.GetRequiredService<IDbContextFactory<WorkstationDbContext>>();
        await using var dbContext = await factory.CreateDbContextAsync();
        (await dbContext.AppMetadata.SingleAsync()).Value.Should().Be("V4PricingFoundation");
        (await dbContext.AuditEvents.SingleAsync()).Action.Should().Be("PLATFORM_STARTED");

        var connection = dbContext.Database.GetDbConnection();
        await dbContext.Database.OpenConnectionAsync();
        try
        {
            (await ReadPragmaAsync(connection, "foreign_keys")).Should().Be("1");
            (await ReadPragmaAsync(connection, "journal_mode")).Should().Be("wal");
            (await ReadPragmaAsync(connection, "synchronous")).Should().Be("2");
            (await ReadPragmaAsync(connection, "busy_timeout")).Should().Be("5000");
        }
        finally
        {
            await dbContext.Database.CloseConnectionAsync();
        }
    }

    [Fact]
    public async Task MultipleAuthorizationMigration_PreservesExistingSellerBindingAsPrimaryGrant()
    {
        Directory.CreateDirectory(_dataRoot);
        var databasePath = Path.Combine(_dataRoot, "migration-preservation.db");
        var options = new DbContextOptionsBuilder<WorkstationDbContext>()
            .UseSqlite($"Data Source={databasePath};Foreign Keys=True;Pooling=False")
            .Options;
        await using var dbContext = new WorkstationDbContext(options);
        var migrator = dbContext.Database.GetService<IMigrator>();
        await migrator.MigrateAsync("20260716071915_V3CommerceContextReadModel");

        var now = new DateTimeOffset(2026, 7, 16, 8, 0, 0, TimeSpan.Zero);
        var applicationId = Guid.NewGuid();
        var profileId = Guid.NewGuid();
        var sellerAccountId = Guid.NewGuid();
        await dbContext.Database.ExecuteSqlInterpolatedAsync($"""
            INSERT INTO "DeveloperApplications"
                ("Id", "Name", "ClientIdFingerprint", "IsActive", "CreatedAtUtc", "LastValidatedAtUtc")
            VALUES
                ({applicationId}, {"Existing application"}, {"sha256:existing"}, {true}, {now}, {now});
            """);
        await dbContext.Database.ExecuteSqlInterpolatedAsync($"""
            INSERT INTO "AuthorizationProfiles"
                ("Id", "DeveloperApplicationId", "Name", "Region", "EncryptedSecretReference", "Status", "CreatedAtUtc", "LastVerifiedAtUtc")
            VALUES
                ({profileId}, {applicationId}, {"Existing token"}, {"NorthAmerica"}, {"secret:existing"}, {"Verified"}, {now}, {now});
            """);
        await dbContext.Database.ExecuteSqlInterpolatedAsync($"""
            INSERT INTO "SellerAccounts"
                ("Id", "AuthorizationProfileId", "SellerId", "DisplayName", "IsActive", "DiscoveredAtUtc", "LastDiscoveredAtUtc")
            VALUES
                ({sellerAccountId}, {profileId}, {"SELLER-EXISTING"}, {"Existing Store"}, {true}, {now}, {now});
            """);

        await migrator.MigrateAsync();

        var grant = await dbContext.SellerAuthorizationGrants.AsNoTracking().SingleAsync();
        grant.SellerAccountId.Should().Be(sellerAccountId);
        grant.AuthorizationProfileId.Should().Be(profileId);
        grant.IsPrimary.Should().BeTrue();
        grant.Status.Should().Be(Klanata.Domain.Entities.SellerAuthorizationGrantStatus.Verified);
    }

    private static async Task<string> ReadPragmaAsync(
        System.Data.Common.DbConnection connection,
        string name)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = $"PRAGMA {name};";
        return Convert.ToString(await command.ExecuteScalarAsync(), System.Globalization.CultureInfo.InvariantCulture)
            ?? string.Empty;
    }

    private sealed class TestHostEnvironment(string contentRoot) : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = "Testing";
        public string ApplicationName { get; set; } = "Klanata.Infrastructure.Tests";
        public string ContentRootPath { get; set; } = contentRoot;
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
}
