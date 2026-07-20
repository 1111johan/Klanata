using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class PricingChangeSetConfiguration : IEntityTypeConfiguration<PricingChangeSet>
{
    public void Configure(EntityTypeBuilder<PricingChangeSet> builder)
    {
        builder.ToTable("PricingChangeSets");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.SellerId).HasMaxLength(64).IsRequired();
        builder.Property(item => item.MarketplaceId).HasMaxLength(64).IsRequired();
        builder.Property(item => item.InitiatedBy).HasMaxLength(128).IsRequired();
        builder.Property(item => item.Status).HasConversion<string>().HasMaxLength(24).IsRequired();
        builder.HasIndex(item => item.PricingRunId).IsUnique();
        builder.HasOne<PricingRun>()
            .WithMany()
            .HasForeignKey(item => item.PricingRunId)
            .OnDelete(DeleteBehavior.Restrict);
        builder.HasOne<PricingRuleSet>()
            .WithMany()
            .HasForeignKey(item => item.PricingRuleSetId)
            .OnDelete(DeleteBehavior.Restrict);
        builder.HasOne<AuthorizationProfile>()
            .WithMany()
            .HasForeignKey(item => item.AuthorizationProfileId)
            .OnDelete(DeleteBehavior.Restrict);
    }
}

public sealed class PricingChangeSetItemConfiguration : IEntityTypeConfiguration<PricingChangeSetItem>
{
    public void Configure(EntityTypeBuilder<PricingChangeSetItem> builder)
    {
        builder.ToTable(
            "PricingChangeSetItems",
            table => table.HasCheckConstraint(
                "CK_PricingChangeSetItems_BusinessPriceUnchanged",
                "TargetBusinessPrice IS NULL AND BusinessPriceModified = 0"));
        builder.HasKey(item => item.Id);
        builder.Property(item => item.Sku).HasMaxLength(128).IsRequired();
        builder.Property(item => item.CurrentPrice).HasPrecision(18, 4);
        builder.Property(item => item.TargetPrice).HasPrecision(18, 4);
        builder.Property(item => item.CurrentBusinessPrice).HasPrecision(18, 4);
        builder.Property(item => item.TargetBusinessPrice).HasPrecision(18, 4);
        builder.Property(item => item.IdempotencyKey).HasMaxLength(64).IsRequired();
        builder.HasIndex(item => new { item.PricingChangeSetId, item.PricingRunItemId }).IsUnique();
        builder.HasIndex(item => item.IdempotencyKey).IsUnique();
        builder.HasOne<PricingChangeSet>()
            .WithMany()
            .HasForeignKey(item => item.PricingChangeSetId)
            .OnDelete(DeleteBehavior.Restrict);
        builder.HasOne<PricingRunItem>()
            .WithMany()
            .HasForeignKey(item => item.PricingRunItemId)
            .OnDelete(DeleteBehavior.Restrict);
    }
}

public sealed class PricingApprovalConfiguration : IEntityTypeConfiguration<PricingApproval>
{
    public void Configure(EntityTypeBuilder<PricingApproval> builder)
    {
        builder.ToTable("PricingApprovals");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.Approver).HasMaxLength(128).IsRequired();
        builder.HasIndex(item => item.PricingChangeSetId).IsUnique();
        builder.HasOne<PricingChangeSet>()
            .WithMany()
            .HasForeignKey(item => item.PricingChangeSetId)
            .OnDelete(DeleteBehavior.Restrict);
    }
}
