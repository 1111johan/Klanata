using Klanata.Api.Health;
using Klanata.Api.Hosting;
using Klanata.Api.Middleware;
using Klanata.Api.Security;
using Klanata.Application.Abstractions;
using Klanata.Infrastructure;
using Klanata.Infrastructure.Configuration;
using Klanata.Workers;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Serilog;

var builder = WebApplication.CreateBuilder(args);
var logRoot = ResolveLogRoot(builder);

Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Information()
    .MinimumLevel.Override("Microsoft.AspNetCore", Serilog.Events.LogEventLevel.Warning)
    .Enrich.FromLogContext()
    .Enrich.WithProperty("AppVersion", "4.0.0-p0")
    .WriteTo.Console()
    .WriteTo.File(
        Path.Combine(logRoot, "klanata-.log"),
        rollingInterval: RollingInterval.Day,
        retainedFileCountLimit: 30,
        shared: true)
    .CreateLogger();

builder.Host.UseSerilog();
builder.Services.AddWindowsService(options => options.ServiceName = "KlanataInventoryWorkstation");
builder.Services.AddProblemDetails();
builder.Services.AddControllers();
builder.Services.AddKlanataInfrastructure(builder.Configuration);
builder.Services.AddKlanataWorkers();
builder.Services.AddSingleton<LocalSessionTokenService>();
builder.Services.AddSingleton<SingleInstanceLifetime>();
builder.Services.AddHostedService(serviceProvider => serviceProvider.GetRequiredService<SingleInstanceLifetime>());
builder.Services.AddHealthChecks()
    .AddCheck<PlatformReadinessHealthCheck>("platform");

var app = builder.Build();

app.UseExceptionHandler();
app.UseMiddleware<SecurityHeadersMiddleware>();
app.UseMiddleware<LocalRequestGuardMiddleware>();
app.UseDefaultFiles();
app.UseStaticFiles();

app.MapControllers();
app.MapHealthChecks("/health/live", new HealthCheckOptions
{
    Predicate = _ => false
});
app.MapHealthChecks("/health/ready", new HealthCheckOptions
{
    Predicate = registration => registration.Name == "platform"
});
app.MapFallbackToFile("index.html");

await using (var scope = app.Services.CreateAsyncScope())
{
    var initializer = scope.ServiceProvider.GetRequiredService<IDatabaseInitializer>();
    await initializer.InitializeAsync(app.Lifetime.ApplicationStopping);
}

try
{
    await app.RunAsync();
}
finally
{
    await Log.CloseAndFlushAsync();
}

static string ResolveLogRoot(WebApplicationBuilder builder)
{
    var configuredRoot = builder.Configuration[$"{WorkstationOptions.SectionName}:DataRoot"];
    string dataRoot;
    if (!string.IsNullOrWhiteSpace(configuredRoot))
    {
        dataRoot = Path.GetFullPath(Environment.ExpandEnvironmentVariables(configuredRoot));
    }
    else if (builder.Environment.IsDevelopment() || builder.Environment.IsEnvironment("Testing"))
    {
        dataRoot = Path.Combine(builder.Environment.ContentRootPath, "runtime-v2");
    }
    else
    {
        dataRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "Klanata Inventory Workstation");
    }

    var logsPath = Path.Combine(dataRoot, "logs");
    Directory.CreateDirectory(logsPath);
    return logsPath;
}

public partial class Program;
