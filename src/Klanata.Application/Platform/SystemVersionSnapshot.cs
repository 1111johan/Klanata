namespace Klanata.Application.Platform;

public sealed record SystemVersionSnapshot(
    string Version,
    string Phase,
    string Framework,
    string DatabaseProvider,
    string RuntimeIdentifier,
    string DatabaseSchema,
    DateTimeOffset StartedAtUtc);
