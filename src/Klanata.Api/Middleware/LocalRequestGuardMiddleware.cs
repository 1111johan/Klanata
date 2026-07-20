using Klanata.Api.Security;

namespace Klanata.Api.Middleware;

public sealed class LocalRequestGuardMiddleware(RequestDelegate next)
{
    private static readonly HashSet<string> LocalHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "127.0.0.1",
        "localhost",
        "::1"
    };

    public async Task InvokeAsync(HttpContext context, LocalSessionTokenService tokenService)
    {
        if (!LocalHosts.Contains(context.Request.Host.Host))
        {
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            await context.Response.WriteAsJsonAsync(new
            {
                type = "https://klanata.local/problems/invalid-host",
                title = "Invalid local host",
                status = StatusCodes.Status400BadRequest,
                detail = "The workstation only accepts localhost requests."
            });
            return;
        }

        if ((context.Request.Path.StartsWithSegments("/api/v2") ||
             context.Request.Path.StartsWithSegments("/api/v3") ||
             context.Request.Path.StartsWithSegments("/api/v4")) &&
            IsUnsafeMethod(context.Request.Method))
        {
            if (!HasValidOrigin(context.Request) ||
                !tokenService.IsValid(
                    context.Request.Cookies[LocalSessionTokenService.CookieName],
                    context.Request.Headers["X-Klanata-Csrf"].FirstOrDefault()))
            {
                context.Response.StatusCode = StatusCodes.Status403Forbidden;
                await context.Response.WriteAsJsonAsync(new
                {
                    type = "https://klanata.local/problems/local-session-required",
                    title = "Local session validation failed",
                    status = StatusCodes.Status403Forbidden,
                    detail = "Refresh the workstation and retry the operation."
                });
                return;
            }
        }

        await next(context);
    }

    private static bool IsUnsafeMethod(string method) =>
        !HttpMethods.IsGet(method) &&
        !HttpMethods.IsHead(method) &&
        !HttpMethods.IsOptions(method);

    private static bool HasValidOrigin(HttpRequest request)
    {
        var origin = request.Headers.Origin.FirstOrDefault();
        if (string.IsNullOrWhiteSpace(origin))
        {
            return true;
        }

        return Uri.TryCreate(origin, UriKind.Absolute, out var originUri) &&
               LocalHosts.Contains(originUri.Host) &&
               originUri.Port == request.Host.Port;
    }
}
