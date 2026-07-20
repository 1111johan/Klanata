using FluentAssertions;
using Klanata.Domain.Entities;

namespace Klanata.Domain.Tests;

public sealed class WorkerLeaseTests
{
    [Fact]
    public void TryAcquire_BlocksAnotherOwnerUntilTheLeaseExpires()
    {
        var now = DateTimeOffset.Parse("2026-07-15T00:00:00Z");
        var lease = new WorkerLease("feed-monitor");

        lease.TryAcquire("instance-a", now, TimeSpan.FromSeconds(30)).Should().BeTrue();
        lease.TryAcquire("instance-b", now.AddSeconds(10), TimeSpan.FromSeconds(30)).Should().BeFalse();
        lease.TryAcquire("instance-b", now.AddSeconds(31), TimeSpan.FromSeconds(30)).Should().BeTrue();

        lease.OwnerInstanceId.Should().Be("instance-b");
        lease.Version.Should().Be(2);
    }

    [Fact]
    public void Release_RequiresTheCurrentOwner()
    {
        var lease = new WorkerLease("report-monitor");
        lease.TryAcquire("instance-a", DateTimeOffset.UtcNow, TimeSpan.FromSeconds(30));

        var action = () => lease.Release("instance-b", DateTimeOffset.UtcNow);

        action.Should().Throw<InvalidOperationException>();
    }
}
