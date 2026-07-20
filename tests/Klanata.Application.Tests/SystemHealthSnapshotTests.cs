using FluentAssertions;
using Klanata.Application.Platform;

namespace Klanata.Application.Tests;

public sealed class SystemHealthSnapshotTests
{
    [Theory]
    [InlineData("healthy", "healthy")]
    [InlineData("degraded", "degraded")]
    [InlineData("unhealthy", "unhealthy")]
    public void Create_DerivesOverallStatusFromRequiredComponents(string databaseStatus, string expected)
    {
        var database = new ComponentHealth(databaseStatus, "database");

        var snapshot = SystemHealthSnapshot.Create(
            ComponentHealth.Healthy("service"),
            database,
            ComponentHealth.Healthy("disk"),
            ComponentHealth.Healthy("worker"),
            ComponentHealth.NotConfigured("secret store"),
            "Testing",
            "http://127.0.0.1:4318",
            "D:\\temp",
            10_000,
            DateTimeOffset.UtcNow);

        snapshot.OverallStatus.Should().Be(expected);
    }
}
