using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class DeveloperApplicationConfiguration : IEntityTypeConfiguration<DeveloperApplication>
{
    public void Configure(EntityTypeBuilder<DeveloperApplication> builder)
    {
        builder.ToTable("DeveloperApplications");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.Name).HasMaxLength(128).IsRequired();
        builder.Property(item => item.ClientIdFingerprint).HasMaxLength(128).IsRequired();
        builder.Property(item => item.CreatedAtUtc).IsRequired();
        builder.HasIndex(item => item.ClientIdFingerprint).IsUnique();
    }
}
