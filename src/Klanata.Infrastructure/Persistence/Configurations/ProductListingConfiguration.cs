using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class ProductListingConfiguration : IEntityTypeConfiguration<ProductListing>
{
    public void Configure(EntityTypeBuilder<ProductListing> builder)
    {
        builder.ToTable("ProductListings");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.SellerId).HasMaxLength(64).IsRequired();
        builder.Property(item => item.MarketplaceId).HasMaxLength(64).IsRequired();
        builder.Property(item => item.Sku).HasMaxLength(128).IsRequired();
        builder.Property(item => item.Asin).HasMaxLength(32);
        builder.Property(item => item.Title).HasMaxLength(512);
        builder.Property(item => item.FulfillmentChannel).HasConversion<string>().HasMaxLength(16).IsRequired();
        builder.Property(item => item.Status).HasConversion<string>().HasMaxLength(24).IsRequired();
        builder.Property(item => item.CurrencyCode).HasMaxLength(8).IsRequired();
        builder.Property(item => item.Price).HasPrecision(18, 4);
        builder.Property(item => item.BusinessPrice).HasPrecision(18, 4);
        builder.Property(item => item.SourceReference).HasMaxLength(256);
        builder.Property(item => item.SnapshotVersion).IsConcurrencyToken();
        builder.HasIndex(item => new { item.SellerId, item.MarketplaceId, item.Sku }).IsUnique();
        builder.HasIndex(item => new { item.SellerId, item.MarketplaceId, item.Status });
        builder.HasIndex(item => new { item.SellerId, item.MarketplaceId, item.SynchronizedUnixTimeSeconds });
        builder.HasOne<MarketplaceParticipation>()
            .WithMany()
            .HasForeignKey(item => item.MarketplaceParticipationId)
            .OnDelete(DeleteBehavior.Restrict);
    }
}
