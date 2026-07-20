using FluentAssertions;
using Klanata.Domain.Entities;

namespace Klanata.Domain.Tests;

public sealed class AuditEventTests
{
    [Fact]
    public void Create_NormalizesTimestampAndTrimsIdentityFields()
    {
        var timestamp = new DateTimeOffset(2026, 7, 15, 10, 0, 0, TimeSpan.FromHours(8));

        var auditEvent = AuditEvent.Create(
            timestamp,
            " SYSTEM ",
            " PLATFORM_STARTED ",
            " Platform ",
            " workstation ",
            " correlation-id ",
            " machine ",
            " 2.0.0-phase1 ");

        auditEvent.TimestampUtc.Should().Be(timestamp.ToUniversalTime());
        auditEvent.Actor.Should().Be("SYSTEM");
        auditEvent.Action.Should().Be("PLATFORM_STARTED");
        auditEvent.AppVersion.Should().Be("2.0.0-phase1");
        auditEvent.Id.Should().NotBeEmpty();
    }

    [Fact]
    public void Create_RejectsBlankActor()
    {
        var action = () => AuditEvent.Create(
            DateTimeOffset.UtcNow,
            " ",
            "ACTION",
            "ENTITY",
            "ID",
            "CORRELATION",
            "MACHINE",
            "VERSION");

        action.Should().Throw<ArgumentException>();
    }
}
