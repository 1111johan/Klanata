using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class SellerAuthorizationGrantConfiguration : IEntityTypeConfiguration<SellerAuthorizationGrant>
{
    public void Configure(EntityTypeBuilder<SellerAuthorizationGrant> builder)
    {
        builder.ToTable("SellerAuthorizationGrants");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.Label).HasMaxLength(128).IsRequired();
        builder.Property(item => item.Status).HasConversion<string>().HasMaxLength(24).IsRequired();
        builder.Property(item => item.VerifiedAtUtc).IsRequired();
        builder.HasIndex(item => new { item.SellerAccountId, item.AuthorizationProfileId }).IsUnique();
        builder.HasIndex(item => new { item.SellerAccountId, item.Priority });
        builder.HasIndex(item => item.SellerAccountId)
            .IsUnique()
            .HasFilter("IsPrimary = 1");
        builder.HasOne<SellerAccount>()
            .WithMany()
            .HasForeignKey(item => item.SellerAccountId)
            .OnDelete(DeleteBehavior.Cascade);
        builder.HasOne<AuthorizationProfile>()
            .WithMany()
            .HasForeignKey(item => item.AuthorizationProfileId)
            .OnDelete(DeleteBehavior.Restrict);
    }
}
