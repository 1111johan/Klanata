using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class PricingRuleSetConfiguration : IEntityTypeConfiguration<PricingRuleSet>
{
    public void Configure(EntityTypeBuilder<PricingRuleSet> builder)
    {
        builder.ToTable("PricingRuleSets");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.SellerId).HasMaxLength(64).IsRequired();
        builder.Property(item => item.MarketplaceId).HasMaxLength(64).IsRequired();
        builder.Property(item => item.Name).HasMaxLength(160).IsRequired();
        builder.Property(item => item.Direction).HasConversion<string>().HasMaxLength(16).IsRequired();
        builder.Property(item => item.Threshold).HasPrecision(18, 4);
        builder.Property(item => item.BelowThresholdType).HasConversion<string>().HasMaxLength(24).IsRequired();
        builder.Property(item => item.BelowThresholdValue).HasPrecision(18, 4);
        builder.Property(item => item.AtOrAboveThresholdType).HasConversion<string>().HasMaxLength(24).IsRequired();
        builder.Property(item => item.AtOrAboveThresholdValue).HasPrecision(18, 4);
        builder.Property(item => item.AbsoluteChangeCap).HasPrecision(18, 4);
        builder.Property(item => item.PercentageChangeCap).HasPrecision(18, 4);
        builder.Property(item => item.CurrencyCode).HasMaxLength(8).IsRequired();
        builder.Property(item => item.BusinessPriceStrategy).HasConversion<string>().HasMaxLength(24).IsRequired();
        builder.Property(item => item.CreatedBy).HasMaxLength(128).IsRequired();
        builder.HasIndex(item => new { item.SellerId, item.MarketplaceId, item.Version }).IsUnique();
        builder.HasOne<MarketplaceParticipation>()
            .WithMany()
            .HasForeignKey(item => item.MarketplaceParticipationId)
            .OnDelete(DeleteBehavior.Restrict);
        builder.HasOne<AuthorizationProfile>()
            .WithMany()
            .HasForeignKey(item => item.AuthorizationProfileId)
            .OnDelete(DeleteBehavior.Restrict);
    }
}
