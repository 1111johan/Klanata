using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class AppMetadataConfiguration : IEntityTypeConfiguration<AppMetadata>
{
    public void Configure(EntityTypeBuilder<AppMetadata> builder)
    {
        builder.ToTable("AppMetadata");
        builder.HasKey(item => item.Key);
        builder.Property(item => item.Key).HasMaxLength(128);
        builder.Property(item => item.Value).HasMaxLength(2048).IsRequired();
        builder.Property(item => item.UpdatedAtUtc).IsRequired();
    }
}
