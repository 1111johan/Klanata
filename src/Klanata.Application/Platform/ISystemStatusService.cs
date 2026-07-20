namespace Klanata.Application.Platform;

public interface ISystemStatusService
{
    Task<SystemHealthSnapshot> GetHealthAsync(CancellationToken cancellationToken);

    Task<SystemVersionSnapshot> GetVersionAsync(CancellationToken cancellationToken);
}
