using Klanata.Domain.Entities;
using Microsoft.EntityFrameworkCore;

namespace Klanata.Infrastructure.Persistence;

public sealed class WorkstationDbContext(DbContextOptions<WorkstationDbContext> options) : DbContext(options)
{
    public DbSet<AppMetadata> AppMetadata => Set<AppMetadata>();

    public DbSet<AuditEvent> AuditEvents => Set<AuditEvent>();

    public DbSet<WorkerLease> WorkerLeases => Set<WorkerLease>();

    public DbSet<DeveloperApplication> DeveloperApplications => Set<DeveloperApplication>();

    public DbSet<AuthorizationProfile> AuthorizationProfiles => Set<AuthorizationProfile>();

    public DbSet<SellerAccount> SellerAccounts => Set<SellerAccount>();

    public DbSet<SellerAuthorizationGrant> SellerAuthorizationGrants => Set<SellerAuthorizationGrant>();

    public DbSet<MarketplaceParticipation> MarketplaceParticipations => Set<MarketplaceParticipation>();

    public DbSet<MarketplaceCapability> MarketplaceCapabilities => Set<MarketplaceCapability>();

    public DbSet<ProductListing> ProductListings => Set<ProductListing>();

    public DbSet<PricingRuleSet> PricingRuleSets => Set<PricingRuleSet>();

    public DbSet<PricingRun> PricingRuns => Set<PricingRun>();

    public DbSet<PricingRunItem> PricingRunItems => Set<PricingRunItem>();

    public DbSet<PricingChangeSet> PricingChangeSets => Set<PricingChangeSet>();

    public DbSet<PricingChangeSetItem> PricingChangeSetItems => Set<PricingChangeSetItem>();

    public DbSet<PricingApproval> PricingApprovals => Set<PricingApproval>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(WorkstationDbContext).Assembly);
    }
}
