using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class MarketplaceParticipationConfiguration : IEntityTypeConfiguration<MarketplaceParticipation>
{
    public void Configure(EntityTypeBuilder<MarketplaceParticipation> builder)
    {
        builder.ToTable("MarketplaceParticipations");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.MarketplaceId).HasMaxLength(64).IsRequired();
        builder.Property(item => item.Name).HasMaxLength(128).IsRequired();
        builder.Property(item => item.CountryCode).HasMaxLength(8).IsRequired();
        builder.Property(item => item.DefaultCurrencyCode).HasMaxLength(8).IsRequired();
        builder.Property(item => item.Region).HasConversion<string>().HasMaxLength(32).IsRequired();
        builder.Property(item => item.DiscoveredAtUtc).IsRequired();
        builder.Property(item => item.LastVerifiedAtUtc).IsRequired();
        builder.HasIndex(item => new { item.SellerAccountId, item.MarketplaceId }).IsUnique();
        builder.HasOne<SellerAccount>()
            .WithMany()
            .HasForeignKey(item => item.SellerAccountId)
            .OnDelete(DeleteBehavior.Restrict);
    }
}
