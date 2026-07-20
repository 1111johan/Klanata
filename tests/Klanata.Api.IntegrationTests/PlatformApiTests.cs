using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Klanata.Application.Abstractions;
using Klanata.Application.Pricing;
using Klanata.Application.Platform;
using Klanata.Domain.Entities;
using Klanata.Infrastructure.Configuration;
using Klanata.Infrastructure.Persistence;
using Klanata.Infrastructure.Pricing;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace Klanata.Api.IntegrationTests;

public sealed class PlatformApiTests : IClassFixture<KlanataApiFactory>
{
    private readonly HttpClient _client;

    public PlatformApiTests(KlanataApiFactory factory)
    {
        _client = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = new Uri("http://localhost")
        });
    }

    [Fact]
    public async Task Version_ReturnsAppliedDatabaseSchema()
    {
        var response = await _client.GetAsync("/api/v2/system/version");
        var body = await response.Content.ReadFromJsonAsync<SystemVersionSnapshot>();

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        body.Should().NotBeNull();
        body!.Version.Should().Contain("4.0.0-p0");
        body.DatabaseSchema.Should().Be("V4PricingFoundation");
    }

    [Fact]
    public async Task Session_ReturnsCsrfTokenAndStrictCookie()
    {
        var response = await _client.GetAsync("/api/v2/system/session");
        var body = await response.Content.ReadFromJsonAsync<LocalSessionResponse>();

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        body!.CsrfToken.Should().NotBeNullOrWhiteSpace();
        response.Headers.GetValues("Set-Cookie").Single().ToLowerInvariant()
            .Should().Contain("httponly").And.Contain("samesite=strict");
    }

    [Fact]
    public async Task Health_ReturnsSecurityHeadersAndPlatformState()
    {
        var response = await _client.GetAsync("/api/v2/system/health");
        var body = await response.Content.ReadFromJsonAsync<SystemHealthSnapshot>();

        response.StatusCode.Should().BeOneOf(HttpStatusCode.OK, HttpStatusCode.ServiceUnavailable);
        body.Should().NotBeNull();
        body!.Database.Status.Should().Be("healthy");
        response.Headers.GetValues("X-Frame-Options").Single().Should().Be("DENY");
        response.Headers.GetValues("X-Content-Type-Options").Single().Should().Be("nosniff");
    }

    [Fact]
    public async Task InvalidHost_IsRejected()
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/v2/system/version");
        request.Headers.Host = "example.com";

        var response = await _client.SendAsync(request);

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }
}

public sealed record LocalSessionResponse(string CsrfToken);

public sealed class KlanataApiFactory : WebApplicationFactory<Program>, IAsyncLifetime
{
    private readonly string _dataRoot = Path.Combine(Path.GetTempPath(), "klanata-api-tests", Guid.NewGuid().ToString("N"));

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.ConfigureAppConfiguration((_, configuration) =>
        {
            configuration.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Workstation:DataRoot"] = _dataRoot,
                ["Workstation:SingleInstanceEnabled"] = "false",
                ["Workstation:SqlitePooling"] = "false",
                ["Workstation:AllowedSellerIds:0"] = "SELLER-TEST",
                ["Urls"] = "http://127.0.0.1:4318"
            });
        });
    }

    public Task InitializeAsync() => Task.CompletedTask;

    public async Task SeedCatalogAsync()
    {
        await using var scope = Services.CreateAsyncScope();
        var dbContextFactory = scope.ServiceProvider.GetRequiredService<IDbContextFactory<WorkstationDbContext>>();
        await using var dbContext = await dbContextFactory.CreateDbContextAsync();
        if (await dbContext.DeveloperApplications.AnyAsync())
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var application = new DeveloperApplication("Integration Amazon application", "sha256:test-application", now);
        var profile = new AuthorizationProfile(
            application.Id,
            "Integration profile",
            AmazonApiRegion.NorthAmerica,
            "test-secret-reference",
            now);
        profile.MarkVerified(now);
        var backupProfile = new AuthorizationProfile(
            application.Id,
            "Integration backup profile",
            AmazonApiRegion.NorthAmerica,
            "test-secret-reference-backup",
            now);
        backupProfile.MarkVerified(now);
        var seller = new SellerAccount("SELLER-TEST", "Test Store", now);
        var grant = new SellerAuthorizationGrant(
            seller.Id,
            profile.Id,
            "Primary integration authorization",
            0,
            true,
            now);
        var backupGrant = new SellerAuthorizationGrant(
            seller.Id,
            backupProfile.Id,
            "Backup integration authorization",
            10,
            false,
            now);
        var marketplace = new MarketplaceParticipation(
            seller.Id,
            "MARKETPLACE-TEST",
            "United States",
            "US",
            "USD",
            AmazonApiRegion.NorthAmerica,
            true,
            false,
            now);
        var capability = new MarketplaceCapability(
            marketplace.Id,
            true,
            true,
            true,
            now,
            "Production writes are disabled by the V3 rollout gate.");
        capability.EnablePricingDraftWorkflow(now);
        var listing = new ProductListing(
            marketplace.Id,
            seller.SellerId,
            marketplace.MarketplaceId,
            "SKU-TEST-001",
            "ASINTEST01",
            "Integration listing",
            FulfillmentChannel.Mfn,
            ListingStatus.Active,
            "USD",
            29.99m,
            27.99m,
            12,
            now,
            now,
            "integration-report");

        dbContext.AddRange(
            application,
            profile,
            backupProfile,
            seller,
            grant,
            backupGrant,
            marketplace,
            capability,
            listing);
        await dbContext.SaveChangesAsync();
    }

    public async Task SeedPricingAsync()
    {
        await SeedCatalogAsync();
        await using var scope = Services.CreateAsyncScope();
        var dbContextFactory = scope.ServiceProvider.GetRequiredService<IDbContextFactory<WorkstationDbContext>>();
        await using var dbContext = await dbContextFactory.CreateDbContextAsync();
        if (await dbContext.ProductListings.AnyAsync(item => item.Sku == "SKU-PRICING-FBA"))
        {
            return;
        }

        var marketplace = await dbContext.MarketplaceParticipations.SingleAsync(
            item => item.MarketplaceId == "MARKETPLACE-TEST");
        var now = DateTimeOffset.UtcNow;
        var listings = new[]
        {
            new ProductListing(
                marketplace.Id, "SELLER-TEST", "MARKETPLACE-TEST", "SKU-PRICING-FBA",
                "ASIN-COMMON", "FBA item", FulfillmentChannel.Fba, ListingStatus.Active,
                "USD", 42m, null, null, now, now, "integration-report"),
            new ProductListing(
                marketplace.Id, "SELLER-TEST", "MARKETPLACE-TEST", "SKU-PRICING-SAME-ASIN",
                "ASIN-COMMON", "MFN item sharing an FBA ASIN", FulfillmentChannel.Mfn, ListingStatus.Active,
                "USD", 43m, null, 5, now, now, "integration-report"),
            new ProductListing(
                marketplace.Id, "SELLER-TEST", "MARKETPLACE-TEST", "SKU-PRICING-INACTIVE",
                "ASIN-INACTIVE", "Inactive item", FulfillmentChannel.Mfn, ListingStatus.Inactive,
                "USD", 44m, null, 5, now, now, "integration-report"),
            new ProductListing(
                marketplace.Id, "SELLER-TEST", "MARKETPLACE-TEST", "SKU-PRICING-ZERO",
                "ASIN-ZERO", "Zero inventory item", FulfillmentChannel.Mfn, ListingStatus.Active,
                "USD", 45m, null, 0, now, now, "integration-report"),
            new ProductListing(
                marketplace.Id, "SELLER-TEST", "MARKETPLACE-TEST", "SKU-PRICING-NO-PRICE",
                "ASIN-NO-PRICE", "Missing price item", FulfillmentChannel.Mfn, ListingStatus.Active,
                "USD", null, null, 5, now, now, "integration-report"),
            new ProductListing(
                marketplace.Id, "SELLER-TEST", "MARKETPLACE-TEST", "SKU-PRICING-STALE",
                "ASIN-STALE", "Stale item", FulfillmentChannel.Mfn, ListingStatus.Active,
                "USD", 46m, null, 5, now.AddHours(-13), now.AddHours(-13), "integration-report"),
            new ProductListing(
                marketplace.Id, "SELLER-TEST", "MARKETPLACE-TEST", "SKU-PRICING-CURRENCY",
                "ASIN-CURRENCY", "Wrong currency item", FulfillmentChannel.Mfn, ListingStatus.Active,
                "EUR", 47m, null, 5, now, now, "integration-report")
        };
        dbContext.ProductListings.AddRange(listings);
        await dbContext.SaveChangesAsync();
    }

    public async Task SeedPricingContextWithoutCapabilityAsync()
    {
        await SeedCatalogAsync();
        await using var scope = Services.CreateAsyncScope();
        var dbContextFactory = scope.ServiceProvider.GetRequiredService<IDbContextFactory<WorkstationDbContext>>();
        await using var dbContext = await dbContextFactory.CreateDbContextAsync();
        if (await dbContext.MarketplaceParticipations.AnyAsync(
                item => item.MarketplaceId == "MARKETPLACE-NO-CAPABILITY"))
        {
            return;
        }

        var seller = await dbContext.SellerAccounts.SingleAsync(item => item.SellerId == "SELLER-TEST");
        var now = DateTimeOffset.UtcNow;
        var marketplace = new MarketplaceParticipation(
            seller.Id,
            "MARKETPLACE-NO-CAPABILITY",
            "No Capability Marketplace",
            "US",
            "USD",
            AmazonApiRegion.NorthAmerica,
            true,
            false,
            now);
        var listing = new ProductListing(
            marketplace.Id,
            seller.SellerId,
            marketplace.MarketplaceId,
            "SKU-NO-CAPABILITY",
            "ASIN-NO-CAPABILITY",
            "Listing without a capability record",
            FulfillmentChannel.Mfn,
            ListingStatus.Active,
            "USD",
            25m,
            null,
            3,
            now,
            now,
            "integration-report");
        dbContext.AddRange(marketplace, listing);
        await dbContext.SaveChangesAsync();
    }

    public async Task SeedDisallowedCatalogAsync()
    {
        await SeedCatalogAsync();
        await using var scope = Services.CreateAsyncScope();
        var dbContextFactory = scope.ServiceProvider.GetRequiredService<IDbContextFactory<WorkstationDbContext>>();
        await using var dbContext = await dbContextFactory.CreateDbContextAsync();
        if (await dbContext.SellerAccounts.AnyAsync(item => item.SellerId == "SELLER-OTHER"))
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var profile = await dbContext.AuthorizationProfiles
            .SingleAsync(item => item.Name == "Integration profile");
        var seller = new SellerAccount("SELLER-OTHER", "Other Store", now);
        var grant = new SellerAuthorizationGrant(
            seller.Id,
            profile.Id,
            "Disallowed integration authorization",
            0,
            true,
            now);
        var marketplace = new MarketplaceParticipation(
            seller.Id,
            "MARKETPLACE-OTHER",
            "Other Marketplace",
            "US",
            "USD",
            AmazonApiRegion.NorthAmerica,
            true,
            false,
            now);
        var capability = new MarketplaceCapability(
            marketplace.Id,
            true,
            true,
            true,
            now,
            "Disallowed Seller fixture; production writes remain disabled.");
        capability.EnablePricingDraftWorkflow(now);
        var listing = new ProductListing(
            marketplace.Id,
            seller.SellerId,
            marketplace.MarketplaceId,
            "SKU-OTHER-001",
            "ASIN-OTHER-001",
            "Other Seller listing",
            FulfillmentChannel.Mfn,
            ListingStatus.Active,
            "USD",
            24.99m,
            null,
            2,
            now,
            now,
            "integration-other-report");

        dbContext.AddRange(seller, grant, marketplace, capability, listing);
        await dbContext.SaveChangesAsync();
    }

    public async Task<DisallowedPricingWorkflowSeed> SeedDisallowedPricingWorkflowAsync()
    {
        await SeedDisallowedCatalogAsync();
        await using var scope = Services.CreateAsyncScope();
        var dbContextFactory = scope.ServiceProvider.GetRequiredService<IDbContextFactory<WorkstationDbContext>>();
        var clock = scope.ServiceProvider.GetRequiredService<IClock>();
        var policy = new AllowedSellerPolicy(Options.Create(new WorkstationOptions
        {
            AllowedSellerIds = ["SELLER-OTHER"]
        }));
        var service = new PricingWorkflowService(dbContextFactory, clock, policy);
        var request = new CreatePricingRunRequest(
            "SELLER-OTHER",
            "MARKETPLACE-OTHER",
            "operator-other",
            new PricingRuleRequest(
                "Other Seller pricing rule",
                "INCREASE",
                100m,
                new PricingRuleBandRequest("FIXED_AMOUNT", 0.50m),
                new PricingRuleBandRequest("PERCENTAGE", 0.90m),
                0.90m,
                1m),
            "disallowed-seller-idempotency-key");
        var run = await service.CreateRunAsync(request, CancellationToken.None);
        var changeSet = await service.CreateChangeSetAsync(run.Id, CancellationToken.None);
        return new DisallowedPricingWorkflowSeed(run.Id, changeSet.Id, request);
    }

    public new Task DisposeAsync()
    {
        Dispose();
        if (Directory.Exists(_dataRoot))
        {
            Directory.Delete(_dataRoot, true);
        }
        return Task.CompletedTask;
    }
}

public sealed record DisallowedPricingWorkflowSeed(
    Guid RunId,
    Guid ChangeSetId,
    CreatePricingRunRequest Request);
