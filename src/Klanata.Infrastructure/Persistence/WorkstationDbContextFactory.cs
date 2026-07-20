using Klanata.Infrastructure.Files;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

namespace Klanata.Infrastructure.Persistence;

public sealed class WorkstationDbContextFactory : IDesignTimeDbContextFactory<WorkstationDbContext>
{
    public WorkstationDbContext CreateDbContext(string[] args)
    {
        var contentRoot = Directory.GetCurrentDirectory();
        var environment = new DesignTimeHostEnvironment(contentRoot);
        var paths = new DataPathProvider(Options.Create(new Configuration.WorkstationOptions()), environment);
        var options = new DbContextOptionsBuilder<WorkstationDbContext>()
            .UseSqlite($"Data Source={paths.DatabasePath};Foreign Keys=True;Default Timeout=5")
            .Options;
        return new WorkstationDbContext(options);
    }

    private sealed class DesignTimeHostEnvironment(string contentRootPath) : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = Environments.Development;

        public string ApplicationName { get; set; } = "Klanata.Infrastructure.DesignTime";

        public string ContentRootPath { get; set; } = contentRootPath;

        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
}
