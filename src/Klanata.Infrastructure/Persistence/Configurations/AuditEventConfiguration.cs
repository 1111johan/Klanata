using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class AuditEventConfiguration : IEntityTypeConfiguration<AuditEvent>
{
    public void Configure(EntityTypeBuilder<AuditEvent> builder)
    {
        builder.ToTable("AuditEvents");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.TimestampUtc).IsRequired();
        builder.Property(item => item.Actor).HasMaxLength(128).IsRequired();
        builder.Property(item => item.Action).HasMaxLength(128).IsRequired();
        builder.Property(item => item.EntityType).HasMaxLength(128).IsRequired();
        builder.Property(item => item.EntityId).HasMaxLength(256).IsRequired();
        builder.Property(item => item.SellerId).HasMaxLength(64);
        builder.Property(item => item.MarketplaceId).HasMaxLength(64);
        builder.Property(item => item.Reason).HasMaxLength(1024);
        builder.Property(item => item.CorrelationId).HasMaxLength(128).IsRequired();
        builder.Property(item => item.MachineName).HasMaxLength(256).IsRequired();
        builder.Property(item => item.AppVersion).HasMaxLength(64).IsRequired();
        builder.HasIndex(item => item.TimestampUtc);
        builder.HasIndex(item => new { item.EntityType, item.EntityId });
        builder.HasIndex(item => new { item.SellerId, item.MarketplaceId });
    }
}
