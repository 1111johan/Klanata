using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Klanata.Infrastructure.Persistence.Configurations;

public sealed class AuthorizationProfileConfiguration : IEntityTypeConfiguration<AuthorizationProfile>
{
    public void Configure(EntityTypeBuilder<AuthorizationProfile> builder)
    {
        builder.ToTable("AuthorizationProfiles");
        builder.HasKey(item => item.Id);
        builder.Property(item => item.Name).HasMaxLength(128).IsRequired();
        builder.Property(item => item.Region).HasConversion<string>().HasMaxLength(32).IsRequired();
        builder.Property(item => item.EncryptedSecretReference).HasMaxLength(256).IsRequired();
        builder.Property(item => item.Status).HasConversion<string>().HasMaxLength(32).IsRequired();
        builder.Property(item => item.CreatedAtUtc).IsRequired();
        builder.HasIndex(item => item.EncryptedSecretReference).IsUnique();
        builder.HasOne<DeveloperApplication>()
            .WithMany()
            .HasForeignKey(item => item.DeveloperApplicationId)
            .OnDelete(DeleteBehavior.Restrict);
    }
}
