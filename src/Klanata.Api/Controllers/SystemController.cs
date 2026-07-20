using Klanata.Api.Security;
using Klanata.Application.Platform;
using Microsoft.AspNetCore.Mvc;

namespace Klanata.Api.Controllers;

[ApiController]
[Route("api/v2/system")]
public sealed class SystemController(
    ISystemStatusService systemStatusService,
    LocalSessionTokenService sessionTokenService) : ControllerBase
{
    [HttpGet("health")]
    [ProducesResponseType<SystemHealthSnapshot>(StatusCodes.Status200OK)]
    [ProducesResponseType<SystemHealthSnapshot>(StatusCodes.Status503ServiceUnavailable)]
    public async Task<ActionResult<SystemHealthSnapshot>> GetHealth(CancellationToken cancellationToken)
    {
        var health = await systemStatusService.GetHealthAsync(cancellationToken);
        return health.OverallStatus == "unhealthy"
            ? StatusCode(StatusCodes.Status503ServiceUnavailable, health)
            : Ok(health);
    }

    [HttpGet("version")]
    [ProducesResponseType<SystemVersionSnapshot>(StatusCodes.Status200OK)]
    public async Task<ActionResult<SystemVersionSnapshot>> GetVersion(CancellationToken cancellationToken)
    {
        return Ok(await systemStatusService.GetVersionAsync(cancellationToken));
    }

    [HttpGet("session")]
    [ProducesResponseType<LocalSessionResponse>(StatusCodes.Status200OK)]
    public ActionResult<LocalSessionResponse> CreateLocalSession()
    {
        Response.Cookies.Append(
            LocalSessionTokenService.CookieName,
            sessionTokenService.SessionCookie,
            new CookieOptions
            {
                HttpOnly = true,
                IsEssential = true,
                SameSite = SameSiteMode.Strict,
                Secure = Request.IsHttps,
                Path = "/"
            });
        return Ok(new LocalSessionResponse(sessionTokenService.CsrfToken));
    }
}

public sealed record LocalSessionResponse(string CsrfToken);
