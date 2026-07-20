using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class MarketplaceCapabilityConfiguration : IEntityTypeConfiguration<MarketplaceCapability>
{
    public void Configure(EntityTypeBuilder<MarketplaceCapability> builder)
    {
        builder.ToTable("MarketplaceCapabilities");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.VerifiedAtUtc).IsRequired();
        builder.Property(item => item.WriteBlockReason).HasMaxLength(512).IsRequired();
        builder.HasIndex(item => item.MarketplaceParticipationId).IsUnique();
        builder.HasOne<MarketplaceParticipation>()
            .WithOne()
            .HasForeignKey<MarketplaceCapability>(item => item.MarketplaceParticipationId)
            .OnDelete(DeleteBehavior.Cascade);
    }
}
