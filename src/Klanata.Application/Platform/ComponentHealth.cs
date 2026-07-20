namespace Klanata.Application.Platform;

public sealed record ComponentHealth(string Status, string Detail)
{
    public static ComponentHealth Healthy(string detail) => new("healthy", detail);

    public static ComponentHealth Degraded(string detail) => new("degraded", detail);

    public static ComponentHealth Unhealthy(string detail) => new("unhealthy", detail);

    public static ComponentHealth NotConfigured(string detail) => new("not-configured", detail);
}
