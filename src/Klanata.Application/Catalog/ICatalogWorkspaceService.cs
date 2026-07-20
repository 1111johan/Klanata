namespace Klanata.Application.Catalog;

public interface ICatalogWorkspaceService
{
    Task<IReadOnlyList<MarketplaceContext>> GetContextsAsync(CancellationToken cancellationToken);

    Task<ProductCatalogPage> GetListingsAsync(
        ProductCatalogQuery query,
        CancellationToken cancellationToken);

    Task<ProductListingDetail?> GetListingAsync(
        string sellerId,
        string marketplaceId,
        string sku,
        CancellationToken cancellationToken);
}

public sealed class CatalogContextNotFoundException(string sellerId, string marketplaceId)
    : Exception($"Seller '{sellerId}' is not authorized for Marketplace '{marketplaceId}'.");
