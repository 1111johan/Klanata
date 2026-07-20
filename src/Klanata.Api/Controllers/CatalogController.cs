using Klanata.Application.Catalog;
using Microsoft.AspNetCore.Mvc;

namespace Klanata.Api.Controllers;

[ApiController]
[Route("api/v3/catalog")]
public sealed class CatalogController(ICatalogWorkspaceService catalogWorkspaceService) : ControllerBase
{
    [HttpGet("listings")]
    [ProducesResponseType<ProductCatalogPage>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ProductCatalogPage>> GetListings(
        [FromQuery] string? sellerId,
        [FromQuery] string? marketplaceId,
        [FromQuery] string? search,
        [FromQuery] string? status,
        [FromQuery] string? fulfillment,
        [FromQuery] string? freshness,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 50,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(sellerId) || string.IsNullOrWhiteSpace(marketplaceId))
        {
            return Problem(
                statusCode: StatusCodes.Status400BadRequest,
                title: "Seller and Marketplace are required",
                detail: "Select an Amazon-discovered Seller and Marketplace context before reading listings.");
        }

        if (page < 1 || pageSize is < 1 or > 100)
        {
            return Problem(
                statusCode: StatusCodes.Status400BadRequest,
                title: "Invalid pagination",
                detail: "Page must be at least 1 and pageSize must be between 1 and 100.");
        }

        try
        {
            return Ok(await catalogWorkspaceService.GetListingsAsync(
                new ProductCatalogQuery(
                    sellerId,
                    marketplaceId,
                    search,
                    status,
                    fulfillment,
                    freshness,
                    page,
                    pageSize),
                cancellationToken));
        }
        catch (CatalogContextNotFoundException exception)
        {
            return Problem(
                statusCode: StatusCodes.Status404NotFound,
                title: "Production context not found",
                detail: exception.Message);
        }
    }

    [HttpGet("listings/{sku}")]
    [ProducesResponseType<ProductListingDetail>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ProductListingDetail>> GetListing(
        string sku,
        [FromQuery] string sellerId,
        [FromQuery] string marketplaceId,
        CancellationToken cancellationToken)
    {
        try
        {
            var listing = await catalogWorkspaceService.GetListingAsync(
                sellerId,
                marketplaceId,
                sku,
                cancellationToken);
            return listing is null
                ? Problem(
                    statusCode: StatusCodes.Status404NotFound,
                    title: "Listing not found",
                    detail: $"SKU '{sku}' is not present in the selected production context.")
                : Ok(listing);
        }
        catch (CatalogContextNotFoundException exception)
        {
            return Problem(
                statusCode: StatusCodes.Status404NotFound,
                title: "Production context not found",
                detail: exception.Message);
        }
    }
}
