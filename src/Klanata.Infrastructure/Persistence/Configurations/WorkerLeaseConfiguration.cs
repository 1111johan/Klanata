using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class WorkerLeaseConfiguration : IEntityTypeConfiguration<WorkerLease>
{
    public void Configure(EntityTypeBuilder<WorkerLease> builder)
    {
        builder.ToTable("WorkerLeases");
        builder.HasKey(item => item.LeaseKey);
        builder.Property(item => item.LeaseKey).HasMaxLength(128);
        builder.Property(item => item.OwnerInstanceId).HasMaxLength(128);
        builder.Property(item => item.Version).IsConcurrencyToken();
        builder.HasIndex(item => item.ExpiresAtUtc);
    }
}
