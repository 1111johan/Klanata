using Klanata.Application.Abstractions;
using Klanata.Infrastructure.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

namespace Klanata.Infrastructure.Files;

public sealed class DataPathProvider : IDataPathProvider
{
    public DataPathProvider(IOptions<WorkstationOptions> options, IHostEnvironment environment)
    {
        var configuredRoot = options.Value.DataRoot;
        DataRoot = string.IsNullOrWhiteSpace(configuredRoot)
            ? ResolveDefaultRoot(environment)
            : Path.GetFullPath(Environment.ExpandEnvironmentVariables(configuredRoot));

        DatabasePath = Path.Combine(DataRoot, "data", options.Value.DatabaseFileName);
        LogsPath = Path.Combine(DataRoot, "logs");
        KeysPath = Path.Combine(DataRoot, "keys");
        BackupsPath = Path.Combine(DataRoot, "backups");
        RuntimePath = Path.Combine(DataRoot, "runtime");

        Directory.CreateDirectory(DataRoot);
        Directory.CreateDirectory(Path.GetDirectoryName(DatabasePath)!);
        Directory.CreateDirectory(LogsPath);
        Directory.CreateDirectory(KeysPath);
        Directory.CreateDirectory(BackupsPath);
        Directory.CreateDirectory(RuntimePath);
    }

    public string DataRoot { get; }

    public string DatabasePath { get; }

    public string LogsPath { get; }

    public string KeysPath { get; }

    public string BackupsPath { get; }

    public string RuntimePath { get; }

    private static string ResolveDefaultRoot(IHostEnvironment environment)
    {
        if (environment.IsDevelopment() || environment.IsEnvironment("Testing"))
        {
            return Path.GetFullPath(Path.Combine(environment.ContentRootPath, "runtime-v2"));
        }

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "Klanata Inventory Workstation");
    }
}
