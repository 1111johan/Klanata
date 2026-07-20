using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Klanata.Application.Catalog;
using Microsoft.AspNetCore.Mvc.Testing;

namespace Klanata.Api.IntegrationTests;

public sealed class CatalogApiTests : IClassFixture<KlanataApiFactory>
{
    private readonly KlanataApiFactory _factory;
    private readonly HttpClient _client;

    public CatalogApiTests(KlanataApiFactory factory)
    {
        _factory = factory;
        _client = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = new Uri("http://localhost")
        });
    }

    [Fact]
    public async Task Catalog_RequiresDiscoveredContextAndReturnsReadOnlyCapabilities()
    {
        await _factory.SeedCatalogAsync();
        await _factory.SeedDisallowedCatalogAsync();

        var contextsResponse = await _client.GetAsync("/api/v3/workspace/contexts");
        var contextsBody = await contextsResponse.Content.ReadAsStringAsync();
        contextsResponse.StatusCode.Should().Be(HttpStatusCode.OK, contextsBody);
        var contexts = await contextsResponse.Content.ReadFromJsonAsync<MarketplaceContext[]>();

        contexts.Should().ContainSingle();
        var context = contexts![0];
        context.SellerId.Should().Be("SELLER-TEST");
        context.MarketplaceId.Should().Be("MARKETPLACE-TEST");
        context.AuthorizationProfileCount.Should().Be(2);
        context.Capabilities.CanReadListings.Should().BeTrue();
        context.Capabilities.CanWritePrices.Should().BeFalse();
        context.Capabilities.CanWriteMfnInventory.Should().BeFalse();

        var catalog = await _client.GetFromJsonAsync<ProductCatalogPage>(
            "/api/v3/catalog/listings?sellerId=SELLER-TEST&marketplaceId=MARKETPLACE-TEST");
        catalog.Should().NotBeNull();
        catalog!.Metrics.TotalListings.Should().Be(1);
        catalog.Items.Should().ContainSingle(item => item.Sku == "SKU-TEST-001");

        var detail = await _client.GetFromJsonAsync<ProductListingDetail>(
            "/api/v3/catalog/listings/SKU-TEST-001?sellerId=SELLER-TEST&marketplaceId=MARKETPLACE-TEST");
        detail!.SnapshotVersion.Should().Be(1);
        detail.MfnQuantity.Should().Be(12);

        var wrongContext = await _client.GetAsync(
            "/api/v3/catalog/listings?sellerId=SELLER-WRONG&marketplaceId=MARKETPLACE-TEST");
        wrongContext.StatusCode.Should().Be(HttpStatusCode.NotFound);

        var disallowedContext = await _client.GetAsync(
            "/api/v3/catalog/listings?sellerId=SELLER-OTHER&marketplaceId=MARKETPLACE-OTHER");
        disallowedContext.StatusCode.Should().Be(HttpStatusCode.NotFound);

        var disallowedDetail = await _client.GetAsync(
            "/api/v3/catalog/listings/SKU-OTHER-001?sellerId=SELLER-OTHER&marketplaceId=MARKETPLACE-OTHER");
        disallowedDetail.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }
}
