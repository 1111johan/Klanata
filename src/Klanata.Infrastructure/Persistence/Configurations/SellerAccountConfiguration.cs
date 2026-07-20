using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class SellerAccountConfiguration : IEntityTypeConfiguration<SellerAccount>
{
    public void Configure(EntityTypeBuilder<SellerAccount> builder)
    {
        builder.ToTable("SellerAccounts");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.SellerId).HasMaxLength(64).IsRequired();
        builder.Property(item => item.DisplayName).HasMaxLength(256).IsRequired();
        builder.Property(item => item.DiscoveredAtUtc).IsRequired();
        builder.Property(item => item.LastDiscoveredAtUtc).IsRequired();
        builder.HasIndex(item => item.SellerId).IsUnique();
    }
}
