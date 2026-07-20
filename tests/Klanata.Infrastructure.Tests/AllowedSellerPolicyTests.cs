using FluentAssertions;
using Klanata.Infrastructure.Configuration;
using Microsoft.Extensions.Options;

namespace Klanata.Infrastructure.Tests;

public sealed class AllowedSellerPolicyTests
{
    [Fact]
    public void EmptyAllowlist_FailsClosed()
    {
        var action = () => new AllowedSellerPolicy(Options.Create(new WorkstationOptions()));

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*AllowedSellerIds*");
    }

    [Fact]
    public void SellerIds_AreTrimmedDeduplicatedAndComparedExactly()
    {
        var policy = new AllowedSellerPolicy(Options.Create(new WorkstationOptions
        {
            AllowedSellerIds = [" AC7OMGZBRADKF ", "AC7OMGZBRADKF"]
        }));

        policy.SellerIds.Should().Equal("AC7OMGZBRADKF");
        policy.IsAllowed(" AC7OMGZBRADKF ").Should().BeTrue();
        policy.IsAllowed("ac7omgzbradkf").Should().BeFalse();
        policy.IsAllowed("A31XDG4RA4GIQ1").Should().BeFalse();
    }
}
