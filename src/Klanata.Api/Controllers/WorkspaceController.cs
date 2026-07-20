using Klanata.Application.Catalog;
using Microsoft.AspNetCore.Mvc;

namespace Klanata.Api.Controllers;

[ApiController]
[Route("api/v3/workspace")]
public sealed class WorkspaceController(ICatalogWorkspaceService catalogWorkspaceService) : ControllerBase
{
    [HttpGet("contexts")]
    [ProducesResponseType<IReadOnlyList<MarketplaceContext>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<MarketplaceContext>>> GetContexts(
        CancellationToken cancellationToken)
    {
        return Ok(await catalogWorkspaceService.GetContextsAsync(cancellationToken));
    }
}
