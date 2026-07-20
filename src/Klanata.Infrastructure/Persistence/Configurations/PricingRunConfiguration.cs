using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class PricingRunConfiguration : IEntityTypeConfiguration<PricingRun>
{
    public void Configure(EntityTypeBuilder<PricingRun> builder)
    {
        builder.ToTable("PricingRuns");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.RunNumber).HasMaxLength(40).IsRequired();
        builder.Property(item => item.IdempotencyKey).HasMaxLength(128).IsRequired();
        builder.Property(item => item.RequestFingerprint).HasMaxLength(64).IsRequired();
        builder.Property(item => item.SellerId).HasMaxLength(64).IsRequired();
        builder.Property(item => item.MarketplaceId).HasMaxLength(64).IsRequired();
        builder.Property(item => item.InitiatedBy).HasMaxLength(128).IsRequired();
        builder.Property(item => item.Status).HasConversion<string>().HasMaxLength(24).IsRequired();
        builder.HasIndex(item => item.RunNumber).IsUnique();
        builder.HasIndex(item => item.IdempotencyKey).IsUnique();
        builder.HasIndex(item => new { item.SellerId, item.MarketplaceId, item.CreatedAtUtc });
        builder.HasOne<PricingRuleSet>()
            .WithMany()
            .HasForeignKey(item => item.PricingRuleSetId)
            .OnDelete(DeleteBehavior.Restrict);
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

public sealed class PricingRunItemConfiguration : IEntityTypeConfiguration<PricingRunItem>
{
    public void Configure(EntityTypeBuilder<PricingRunItem> builder)
    {
        builder.ToTable("PricingRunItems");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.Sku).HasMaxLength(128).IsRequired();
        builder.Property(item => item.Asin).HasMaxLength(32);
        builder.Property(item => item.Title).HasMaxLength(512);
        builder.Property(item => item.CurrencyCode).HasMaxLength(8).IsRequired();
        builder.Property(item => item.CurrentPrice).HasPrecision(18, 4);
        builder.Property(item => item.TargetPrice).HasPrecision(18, 4);
        builder.Property(item => item.PriceChange).HasPrecision(18, 4);
        builder.Property(item => item.PriceChangePercent).HasPrecision(18, 4);
        builder.Property(item => item.CurrentBusinessPrice).HasPrecision(18, 4);
        builder.Property(item => item.TargetBusinessPrice).HasPrecision(18, 4);
        builder.Property(item => item.ExclusionCodesData).HasMaxLength(512).IsRequired();
        builder.Property(item => item.ExclusionReasonsData).HasMaxLength(2048).IsRequired();
        builder.Ignore(item => item.ExclusionCodes);
        builder.Ignore(item => item.ExclusionReasons);
        builder.HasIndex(item => new { item.PricingRunId, item.Sku }).IsUnique();
        builder.HasOne<PricingRun>()
            .WithMany()
            .HasForeignKey(item => item.PricingRunId)
            .OnDelete(DeleteBehavior.Restrict);
        builder.HasOne<ProductListing>()
            .WithMany()
            .HasForeignKey(item => item.ProductListingId)
            .OnDelete(DeleteBehavior.Restrict);
    }
}
