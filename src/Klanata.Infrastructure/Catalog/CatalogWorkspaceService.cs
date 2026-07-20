using Klanata.Application.Abstractions;
using Klanata.Application.Catalog;
using Klanata.Domain.Entities;
using Klanata.Infrastructure.Configuration;
using Klanata.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Klanata.Infrastructure.Catalog;

public sealed class CatalogWorkspaceService(
    IDbContextFactory<WorkstationDbContext> dbContextFactory,
    IClock clock,
    IAllowedSellerPolicy allowedSellerPolicy) : ICatalogWorkspaceService
{
    private static readonly TimeSpan FreshWindow = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan StaleWindow = TimeSpan.FromHours(24);

    public async Task<IReadOnlyList<MarketplaceContext>> GetContextsAsync(
        CancellationToken cancellationToken)
    {
        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        var contexts = await BuildContextQuery(dbContext)
            .OrderBy(item => item.SellerName)
            .ThenBy(item => item.MarketplaceName)
            .ToListAsync(cancellationToken);

        return contexts.Select(MapContext).ToArray();
    }

    public async Task<ProductCatalogPage> GetListingsAsync(
        ProductCatalogQuery query,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(query.SellerId);
        ArgumentException.ThrowIfNullOrWhiteSpace(query.MarketplaceId);

        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        var context = await ResolveContextAsync(
            dbContext,
            query.SellerId,
            query.MarketplaceId,
            cancellationToken);
        var now = clock.UtcNow;
        var staleCutoff = now.Subtract(StaleWindow).ToUnixTimeSeconds();

        var contextListings = dbContext.ProductListings
            .AsNoTracking()
            .Where(item =>
                item.MarketplaceParticipationId == context.MarketplaceParticipationId &&
                item.SellerId == context.SellerId &&
                item.MarketplaceId == context.MarketplaceId);

        var metrics = await contextListings
            .GroupBy(_ => 1)
            .Select(group => new CatalogMetricsProjection(
                group.Count(),
                group.Count(item => item.Status == ListingStatus.Active),
                group.Count(item => item.FulfillmentChannel == FulfillmentChannel.Mfn),
                group.Count(item => item.SynchronizedUnixTimeSeconds < staleCutoff),
                group.Max(item => (long?)item.SynchronizedUnixTimeSeconds)))
            .SingleOrDefaultAsync(cancellationToken);

        var filtered = ApplyFilters(contextListings, query, now);
        var totalItems = await filtered.CountAsync(cancellationToken);
        var page = Math.Max(1, query.Page);
        var pageSize = Math.Clamp(query.PageSize, 1, 100);
        var projections = await filtered
            .OrderByDescending(item => item.SynchronizedUnixTimeSeconds)
            .ThenBy(item => item.Sku)
            .Skip((page - 1) * pageSize)
            .Take(pageSize)
            .Select(item => new ListingProjection(
                item.SellerId,
                item.MarketplaceId,
                item.Sku,
                item.Asin,
                item.Title,
                item.FulfillmentChannel,
                item.Status,
                item.CurrencyCode,
                item.Price,
                item.BusinessPrice,
                item.MfnQuantity,
                item.SynchronizedAtUtc,
                item.SynchronizedUnixTimeSeconds,
                item.AmazonUpdatedAtUtc,
                item.SourceReference,
                item.SnapshotVersion))
            .ToListAsync(cancellationToken);

        return new ProductCatalogPage(
            MapContext(context),
            new CatalogMetrics(
                metrics?.TotalListings ?? 0,
                metrics?.ActiveListings ?? 0,
                metrics?.MfnListings ?? 0,
                metrics?.StaleListings ?? 0,
                metrics?.LastSynchronizedUnixTimeSeconds is long lastSync
                    ? DateTimeOffset.FromUnixTimeSeconds(lastSync)
                    : null),
            projections.Select(item => MapSummary(item, now)).ToArray(),
            page,
            pageSize,
            totalItems,
            totalItems == 0 ? 0 : (int)Math.Ceiling(totalItems / (double)pageSize),
            now);
    }

    public async Task<ProductListingDetail?> GetListingAsync(
        string sellerId,
        string marketplaceId,
        string sku,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sellerId);
        ArgumentException.ThrowIfNullOrWhiteSpace(marketplaceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(sku);

        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        var context = await ResolveContextAsync(dbContext, sellerId, marketplaceId, cancellationToken);
        var projection = await dbContext.ProductListings
            .AsNoTracking()
            .Where(item =>
                item.MarketplaceParticipationId == context.MarketplaceParticipationId &&
                item.SellerId == context.SellerId &&
                item.MarketplaceId == context.MarketplaceId &&
                item.Sku == sku.Trim())
            .Select(item => new ListingProjection(
                item.SellerId,
                item.MarketplaceId,
                item.Sku,
                item.Asin,
                item.Title,
                item.FulfillmentChannel,
                item.Status,
                item.CurrencyCode,
                item.Price,
                item.BusinessPrice,
                item.MfnQuantity,
                item.SynchronizedAtUtc,
                item.SynchronizedUnixTimeSeconds,
                item.AmazonUpdatedAtUtc,
                item.SourceReference,
                item.SnapshotVersion))
            .SingleOrDefaultAsync(cancellationToken);

        return projection is null ? null : MapDetail(projection, clock.UtcNow);
    }

    private static IQueryable<ProductListing> ApplyFilters(
        IQueryable<ProductListing> listings,
        ProductCatalogQuery query,
        DateTimeOffset now)
    {
        if (!string.IsNullOrWhiteSpace(query.Search))
        {
            var search = query.Search.Trim();
            listings = listings.Where(item =>
                item.Sku.Contains(search) ||
                (item.Asin != null && item.Asin.Contains(search)) ||
                (item.Title != null && item.Title.Contains(search)));
        }

        if (Enum.TryParse<ListingStatus>(query.Status, true, out var status))
        {
            listings = listings.Where(item => item.Status == status);
        }

        if (Enum.TryParse<FulfillmentChannel>(query.Fulfillment, true, out var fulfillment))
        {
            listings = listings.Where(item => item.FulfillmentChannel == fulfillment);
        }

        var freshCutoff = now.Subtract(FreshWindow).ToUnixTimeSeconds();
        var staleCutoff = now.Subtract(StaleWindow).ToUnixTimeSeconds();
        listings = query.Freshness?.Trim().ToLowerInvariant() switch
        {
            "fresh" => listings.Where(item => item.SynchronizedUnixTimeSeconds >= freshCutoff),
            "aging" => listings.Where(item =>
                item.SynchronizedUnixTimeSeconds < freshCutoff &&
                item.SynchronizedUnixTimeSeconds >= staleCutoff),
            "stale" => listings.Where(item => item.SynchronizedUnixTimeSeconds < staleCutoff),
            _ => listings
        };

        return listings;
    }

    private IQueryable<ContextProjection> BuildContextQuery(WorkstationDbContext dbContext)
    {
        var allowedSellerIds = allowedSellerPolicy.SellerIds;
        return
            from participation in dbContext.MarketplaceParticipations.AsNoTracking()
            join seller in dbContext.SellerAccounts.AsNoTracking()
                on participation.SellerAccountId equals seller.Id
            join capabilityItem in dbContext.MarketplaceCapabilities.AsNoTracking()
                on participation.Id equals capabilityItem.MarketplaceParticipationId into capabilities
            from capability in capabilities.DefaultIfEmpty()
            where allowedSellerIds.Contains(seller.SellerId) &&
                  seller.IsActive &&
                  participation.IsParticipating &&
                  dbContext.SellerAuthorizationGrants.Any(grant =>
                      grant.SellerAccountId == seller.Id &&
                      grant.Status == SellerAuthorizationGrantStatus.Verified &&
                      dbContext.AuthorizationProfiles.Any(profile =>
                          profile.Id == grant.AuthorizationProfileId &&
                          profile.Status == AuthorizationProfileStatus.Verified &&
                          dbContext.DeveloperApplications.Any(application =>
                              application.Id == profile.DeveloperApplicationId && application.IsActive)))
            select new ContextProjection
            {
                MarketplaceParticipationId = participation.Id,
                SellerId = seller.SellerId,
                SellerName = seller.DisplayName,
                MarketplaceId = participation.MarketplaceId,
                MarketplaceName = participation.Name,
                CountryCode = participation.CountryCode,
                CurrencyCode = participation.DefaultCurrencyCode,
                Region = participation.Region,
                LastVerifiedAtUtc = participation.LastVerifiedAtUtc,
                AuthorizationProfileCount = dbContext.SellerAuthorizationGrants.Count(grant =>
                    grant.SellerAccountId == seller.Id &&
                    grant.Status == SellerAuthorizationGrantStatus.Verified &&
                    dbContext.AuthorizationProfiles.Any(profile =>
                        profile.Id == grant.AuthorizationProfileId &&
                        profile.Status == AuthorizationProfileStatus.Verified &&
                        dbContext.DeveloperApplications.Any(application =>
                            application.Id == profile.DeveloperApplicationId && application.IsActive))),
                CanReadListings = capability != null && capability.CanReadListings,
                CanReadCatalog = capability != null && capability.CanReadCatalog,
                CanReadPricing = capability != null && capability.CanReadPricing,
                CanCreateDraftChangeSets = capability != null && capability.CanCreateDraftChangeSets,
                CanSimulatePricing = capability != null && capability.CanSimulatePricing,
                CanWritePrices = capability != null && capability.CanWritePrices,
                CanWriteMfnInventory = capability != null && capability.CanWriteMfnInventory,
                WriteBlockReason = capability == null
                    ? "Amazon capability validation has not completed."
                    : capability.WriteBlockReason,
                CapabilitiesVerifiedAtUtc = capability == null ? null : capability.VerifiedAtUtc
            };
    }

    private async Task<ContextProjection> ResolveContextAsync(
        WorkstationDbContext dbContext,
        string sellerId,
        string marketplaceId,
        CancellationToken cancellationToken)
    {
        var normalizedSellerId = sellerId.Trim();
        var normalizedMarketplaceId = marketplaceId.Trim();
        return await BuildContextQuery(dbContext)
            .SingleOrDefaultAsync(
                item =>
                    item.SellerId == normalizedSellerId &&
                    item.MarketplaceId == normalizedMarketplaceId,
                cancellationToken)
            ?? throw new CatalogContextNotFoundException(normalizedSellerId, normalizedMarketplaceId);
    }

    private static MarketplaceContext MapContext(ContextProjection item) =>
        new(
            item.SellerId,
            item.SellerName,
            item.MarketplaceId,
            item.MarketplaceName,
            item.CountryCode,
            item.CurrencyCode,
            item.Region.ToString(),
            item.LastVerifiedAtUtc,
            item.AuthorizationProfileCount,
            new MarketplaceCapabilities(
                item.CanReadListings,
                item.CanReadCatalog,
                item.CanReadPricing,
                item.CanCreateDraftChangeSets,
                item.CanSimulatePricing,
                item.CanWritePrices,
                item.CanWriteMfnInventory,
                item.WriteBlockReason,
                item.CapabilitiesVerifiedAtUtc));

    private static ProductListingSummary MapSummary(ListingProjection item, DateTimeOffset now) =>
        new(
            item.Sku,
            item.Asin,
            item.Title,
            item.FulfillmentChannel.ToString().ToUpperInvariant(),
            item.Status.ToString(),
            item.CurrencyCode,
            item.Price,
            item.BusinessPrice,
            item.MfnQuantity,
            GetFreshness(item.SynchronizedUnixTimeSeconds, now),
            item.SynchronizedAtUtc,
            item.SnapshotVersion);

    private static ProductListingDetail MapDetail(ListingProjection item, DateTimeOffset now) =>
        new(
            item.SellerId,
            item.MarketplaceId,
            item.Sku,
            item.Asin,
            item.Title,
            item.FulfillmentChannel.ToString().ToUpperInvariant(),
            item.Status.ToString(),
            item.CurrencyCode,
            item.Price,
            item.BusinessPrice,
            item.MfnQuantity,
            GetFreshness(item.SynchronizedUnixTimeSeconds, now),
            item.SynchronizedAtUtc,
            item.AmazonUpdatedAtUtc,
            item.SourceReference,
            item.SnapshotVersion);

    private static string GetFreshness(long synchronizedUnixTimeSeconds, DateTimeOffset now)
    {
        var age = now - DateTimeOffset.FromUnixTimeSeconds(synchronizedUnixTimeSeconds);
        if (age <= FreshWindow)
        {
            return "fresh";
        }

        return age <= StaleWindow ? "aging" : "stale";
    }

    private sealed class ContextProjection
    {
        public Guid MarketplaceParticipationId { get; init; }

        public string SellerId { get; init; } = string.Empty;
        public string SellerName { get; init; } = string.Empty;
        public string MarketplaceId { get; init; } = string.Empty;
        public string MarketplaceName { get; init; } = string.Empty;
        public string CountryCode { get; init; } = string.Empty;
        public string CurrencyCode { get; init; } = string.Empty;
        public AmazonApiRegion Region { get; init; }
        public DateTimeOffset LastVerifiedAtUtc { get; init; }
        public int AuthorizationProfileCount { get; init; }
        public bool CanReadListings { get; init; }
        public bool CanReadCatalog { get; init; }
        public bool CanReadPricing { get; init; }
        public bool CanCreateDraftChangeSets { get; init; }
        public bool CanSimulatePricing { get; init; }
        public bool CanWritePrices { get; init; }
        public bool CanWriteMfnInventory { get; init; }
        public string WriteBlockReason { get; init; } = string.Empty;
        public DateTimeOffset? CapabilitiesVerifiedAtUtc { get; init; }
    }

    private sealed record CatalogMetricsProjection(
        int TotalListings,
        int ActiveListings,
        int MfnListings,
        int StaleListings,
        long? LastSynchronizedUnixTimeSeconds);

    private sealed record ListingProjection(
        string SellerId,
        string MarketplaceId,
        string Sku,
        string? Asin,
        string? Title,
        FulfillmentChannel FulfillmentChannel,
        ListingStatus Status,
        string CurrencyCode,
        decimal? Price,
        decimal? BusinessPrice,
        int? MfnQuantity,
        DateTimeOffset SynchronizedAtUtc,
        long SynchronizedUnixTimeSeconds,
        DateTimeOffset? AmazonUpdatedAtUtc,
        string? SourceReference,
        long SnapshotVersion);
}
