using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Klanata.Application.Pricing;
using Klanata.Domain.Entities;
using Klanata.Infrastructure.Persistence;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Klanata.Api.IntegrationTests;

public sealed class PricingApiTests : IClassFixture<KlanataApiFactory>
{
    private readonly KlanataApiFactory _factory;
    private readonly HttpClient _client;

    public PricingApiTests(KlanataApiFactory factory)
    {
        _factory = factory;
        _client = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = new Uri("http://localhost")
        });
    }

    [Fact]
    public async Task UnsafeV4Endpoint_WithoutCsrf_IsRejected()
    {
        var response = await _client.PostAsJsonAsync("/api/v4/pricing/runs", CreateRunRequest());

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Run_RequiresClientSuppliedIdempotencyKey()
    {
        await _factory.SeedPricingAsync();
        await AddCsrfSessionAsync();
        var valid = CreateRunRequest();
        var response = await _client.PostAsJsonAsync("/api/v4/pricing/runs", new
        {
            valid.SellerId,
            valid.MarketplaceId,
            valid.Initiator,
            valid.Rule,
            idempotencyKey = ""
        });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await ReadProblemCodeAsync(response)).Should().Be("IDEMPOTENCY_KEY_REQUIRED");
    }

    [Fact]
    public async Task SyncStatus_AllowsFreshPersistedSnapshotButSyncRemainsHonestlyUnavailable()
    {
        await _factory.SeedPricingAsync();
        await AddCsrfSessionAsync();

        var status = await _client.GetFromJsonAsync<PricingSyncStatus>(
            "/api/v4/pricing/sync-status?sellerId=SELLER-TEST&marketplaceId=MARKETPLACE-TEST");
        status.Should().NotBeNull();
        status!.State.Should().Be("SNAPSHOT_FRESH");
        status.CanStart.Should().BeTrue();
        status.ReportsExecutorAvailable.Should().BeFalse();
        status.ListingCount.Should().BeGreaterThan(0);

        var response = await _client.PostAsJsonAsync(
            "/api/v4/pricing/sync",
            new { sellerId = "SELLER-TEST", marketplaceId = "MARKETPLACE-TEST" });

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        (await ReadProblemCodeAsync(response)).Should().Be("REPORTS_EXECUTOR_UNAVAILABLE");
    }

    [Fact]
    public async Task Run_IsIdempotentFiltersPureFbmAndNeverModifiesBusinessPrice()
    {
        await _factory.SeedPricingAsync();
        await AddCsrfSessionAsync();
        var request = CreateRunRequest($"pricing-run-{Guid.NewGuid():N}");

        var firstResponse = await _client.PostAsJsonAsync("/api/v4/pricing/runs", request);
        var firstBody = await firstResponse.Content.ReadFromJsonAsync<PricingRunView>();
        var secondResponse = await _client.PostAsJsonAsync("/api/v4/pricing/runs", request);
        var secondBody = await secondResponse.Content.ReadFromJsonAsync<PricingRunView>();

        firstResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        secondResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        secondBody!.Id.Should().Be(firstBody!.Id);
        firstBody.Rule.BusinessPriceStrategy.Should().Be("UNCHANGED");
        firstBody.Summary.BusinessPriceModifiedCount.Should().Be(0);
        firstBody.Items.Should().ContainSingle(item => item.Eligible)
            .Which.TargetBusinessPrice.Should().Be(27.99m);
        firstBody.Items.SelectMany(item => item.ExclusionCodes).Should().Contain(
            "NOT_MFN",
            "LISTING_NOT_ACTIVE",
            "NO_SELLABLE_INVENTORY",
            "MISSING_PRICE",
            "STALE_SNAPSHOT",
            "SAME_ASIN_HAS_FBA",
            "CURRENCY_MISMATCH");

        var conflictingResponse = await _client.PostAsJsonAsync(
            "/api/v4/pricing/runs",
            request with { Rule = request.Rule with { Direction = "DECREASE" } });
        conflictingResponse.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await ReadProblemCodeAsync(conflictingResponse)).Should().Be("IDEMPOTENCY_KEY_REUSED");
    }

    [Fact]
    public async Task MissingPricingCapability_CannotStartOrCreateRun()
    {
        await _factory.SeedPricingContextWithoutCapabilityAsync();
        await AddCsrfSessionAsync();

        var status = await _client.GetFromJsonAsync<PricingSyncStatus>(
            "/api/v4/pricing/sync-status?sellerId=SELLER-TEST&marketplaceId=MARKETPLACE-NO-CAPABILITY");
        status!.State.Should().Be("SNAPSHOT_FRESH");
        status.CanStart.Should().BeFalse();

        var request = CreateRunRequest($"no-capability-{Guid.NewGuid():N}") with
        {
            MarketplaceId = "MARKETPLACE-NO-CAPABILITY"
        };
        var response = await _client.PostAsJsonAsync("/api/v4/pricing/runs", request);

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await ReadProblemCodeAsync(response)).Should().Be("PRICING_SIMULATION_CAPABILITY_REQUIRED");
    }

    [Fact]
    public async Task ReviewRecord_RequiresDifferentLabelAndFourConfirmations_ThenValidationIsBlocked()
    {
        await _factory.SeedPricingAsync();
        await AddCsrfSessionAsync();
        var runResponse = await _client.PostAsJsonAsync(
            "/api/v4/pricing/runs",
            CreateRunRequest($"approval-run-{Guid.NewGuid():N}"));
        var run = await runResponse.Content.ReadFromJsonAsync<PricingRunView>();
        var firstChangeSetResponse = await _client.PostAsync(
            $"/api/v4/pricing/runs/{run!.Id}/change-sets",
            null);
        var firstChangeSet = await firstChangeSetResponse.Content.ReadFromJsonAsync<PricingChangeSetView>();
        var repeatedChangeSetResponse = await _client.PostAsync(
            $"/api/v4/pricing/runs/{run.Id}/change-sets",
            null);
        var repeatedChangeSet = await repeatedChangeSetResponse.Content.ReadFromJsonAsync<PricingChangeSetView>();

        firstChangeSetResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        repeatedChangeSet!.Id.Should().Be(firstChangeSet!.Id);

        var selfApproval = await _client.PostAsJsonAsync(
            $"/api/v4/pricing/change-sets/{firstChangeSet.Id}/approve",
            ApprovalRequest("operator-a", allConfirmed: true));
        selfApproval.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await ReadProblemCodeAsync(selfApproval)).Should().Be("SELF_APPROVAL_FORBIDDEN");

        var incompleteApproval = await _client.PostAsJsonAsync(
            $"/api/v4/pricing/change-sets/{firstChangeSet.Id}/approve",
            ApprovalRequest("operator-b", allConfirmed: false));
        incompleteApproval.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await ReadProblemCodeAsync(incompleteApproval)).Should().Be("ALL_CONFIRMATIONS_REQUIRED");

        var approvalResponse = await _client.PostAsJsonAsync(
            $"/api/v4/pricing/change-sets/{firstChangeSet.Id}/approve",
            ApprovalRequest("operator-b", allConfirmed: true));
        var approved = await approvalResponse.Content.ReadFromJsonAsync<PricingChangeSetView>();
        approvalResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        approved!.Status.Should().Be("REVIEW_RECORDED");
        approved.Approval!.Approver.Should().Be("operator-b");
        approved.Approval.IdentityVerified.Should().BeFalse();
        approved.Approval.IdentityAssurance.Should().Be("UNVERIFIED_LOCAL_LABEL");

        var validationResponse = await _client.PostAsync(
            $"/api/v4/pricing/change-sets/{firstChangeSet.Id}/validate",
            null);
        validationResponse.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await ReadProblemCodeAsync(validationResponse)).Should().Be("LIVE_VALIDATION_UNAVAILABLE");
        using (var document = JsonDocument.Parse(await validationResponse.Content.ReadAsStringAsync()))
        {
            document.RootElement.GetProperty("amazonWriteAttempted").GetBoolean().Should().BeFalse();
            document.RootElement.GetProperty("identityVerified").GetBoolean().Should().BeFalse();
        }

        await using var scope = _factory.Services.CreateAsyncScope();
        var dbContextFactory = scope.ServiceProvider.GetRequiredService<IDbContextFactory<WorkstationDbContext>>();
        await using var dbContext = await dbContextFactory.CreateDbContextAsync();
        (await dbContext.PricingChangeSetItems
            .Where(item => item.PricingChangeSetId == firstChangeSet.Id)
            .ToListAsync()).Should().OnlyContain(item =>
                !item.BusinessPriceModified && item.TargetBusinessPrice == null);
        (await dbContext.AuditEvents
            .Where(item => item.EntityId == firstChangeSet.Id.ToString("N"))
            .Select(item => item.Action)
            .ToListAsync()).Should().Contain(
                "PRICING_CHANGE_SET_CREATED",
                "PRICING_CHANGE_SET_REVIEW_RECORDED",
                "PRICING_VALIDATION_BLOCKED");
    }

    [Fact]
    public async Task DisallowedSeller_CannotReplayOrReachPersistedWorkflowByIdentifier()
    {
        var seed = await _factory.SeedDisallowedPricingWorkflowAsync();
        await AddCsrfSessionAsync();

        var syncStatusResponse = await _client.GetAsync(
            "/api/v4/pricing/sync-status?sellerId=SELLER-OTHER&marketplaceId=MARKETPLACE-OTHER");
        syncStatusResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ReadProblemCodeAsync(syncStatusResponse)).Should().Be("PRICING_CONTEXT_NOT_FOUND");

        var replayResponse = await _client.PostAsJsonAsync("/api/v4/pricing/runs", seed.Request);
        replayResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ReadProblemCodeAsync(replayResponse)).Should().Be("PRICING_CONTEXT_NOT_FOUND");

        var runResponse = await _client.GetAsync($"/api/v4/pricing/runs/{seed.RunId}");
        runResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ReadProblemCodeAsync(runResponse)).Should().Be("PRICING_RUN_NOT_FOUND");

        var changeSetResponse = await _client.PostAsync(
            $"/api/v4/pricing/runs/{seed.RunId}/change-sets",
            null);
        changeSetResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ReadProblemCodeAsync(changeSetResponse)).Should().Be("PRICING_CONTEXT_NOT_FOUND");

        var reviewResponse = await _client.PostAsJsonAsync(
            $"/api/v4/pricing/change-sets/{seed.ChangeSetId}/approve",
            ApprovalRequest("reviewer-other", allConfirmed: true));
        reviewResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ReadProblemCodeAsync(reviewResponse)).Should().Be("PRICING_CONTEXT_NOT_FOUND");

        var validationResponse = await _client.PostAsync(
            $"/api/v4/pricing/change-sets/{seed.ChangeSetId}/validate",
            null);
        validationResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ReadProblemCodeAsync(validationResponse)).Should().Be("PRICING_CONTEXT_NOT_FOUND");

        await using var scope = _factory.Services.CreateAsyncScope();
        var dbContextFactory = scope.ServiceProvider.GetRequiredService<IDbContextFactory<WorkstationDbContext>>();
        await using var dbContext = await dbContextFactory.CreateDbContextAsync();
        (await dbContext.PricingChangeSets
            .Where(item => item.Id == seed.ChangeSetId)
            .Select(item => item.Status)
            .SingleAsync()).Should().Be(PricingChangeSetStatus.PendingReview);
        (await dbContext.PricingApprovals
            .AnyAsync(item => item.PricingChangeSetId == seed.ChangeSetId)).Should().BeFalse();
        (await dbContext.AuditEvents
            .Where(item => item.EntityId == seed.ChangeSetId.ToString("N"))
            .Select(item => item.Action)
            .ToListAsync()).Should().NotContain(
                "PRICING_CHANGE_SET_REVIEW_RECORDED",
                "PRICING_VALIDATION_BLOCKED");
    }

    [Fact]
    public async Task CrossSellerRuleReference_HidesRunAndBlocksIdempotentReplayAndChangeSet()
    {
        await _factory.SeedPricingAsync();
        await AddCsrfSessionAsync();
        var request = CreateRunRequest($"cross-rule-{Guid.NewGuid():N}");
        var createResponse = await _client.PostAsJsonAsync("/api/v4/pricing/runs", request);
        var run = await createResponse.Content.ReadFromJsonAsync<PricingRunView>();
        createResponse.StatusCode.Should().Be(HttpStatusCode.Created);

        await using (var scope = _factory.Services.CreateAsyncScope())
        {
            var dbContextFactory = scope.ServiceProvider.GetRequiredService<IDbContextFactory<WorkstationDbContext>>();
            await using var dbContext = await dbContextFactory.CreateDbContextAsync();
            await dbContext.Database.ExecuteSqlInterpolatedAsync($"""
                UPDATE "PricingRuleSets"
                SET "SellerId" = {"SELLER-OTHER"}
                WHERE "Id" = {run!.Rule.Id};
                """);
        }

        var runResponse = await _client.GetAsync($"/api/v4/pricing/runs/{run!.Id}");
        runResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);

        var replayResponse = await _client.PostAsJsonAsync("/api/v4/pricing/runs", request);
        replayResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ReadProblemCodeAsync(replayResponse)).Should().Be("PRICING_CONTEXT_NOT_FOUND");

        var changeSetResponse = await _client.PostAsync(
            $"/api/v4/pricing/runs/{run.Id}/change-sets",
            null);
        changeSetResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ReadProblemCodeAsync(changeSetResponse)).Should().Be("PRICING_CONTEXT_NOT_FOUND");
    }

    [Fact]
    public async Task CrossReferencedChangeSet_HidesRunAndBlocksAllChangeSetOperations()
    {
        await _factory.SeedPricingAsync();
        await AddCsrfSessionAsync();
        var runResponse = await _client.PostAsJsonAsync(
            "/api/v4/pricing/runs",
            CreateRunRequest($"cross-change-set-{Guid.NewGuid():N}"));
        var run = await runResponse.Content.ReadFromJsonAsync<PricingRunView>();
        var createChangeSetResponse = await _client.PostAsync(
            $"/api/v4/pricing/runs/{run!.Id}/change-sets",
            null);
        var changeSet = await createChangeSetResponse.Content.ReadFromJsonAsync<PricingChangeSetView>();
        createChangeSetResponse.StatusCode.Should().Be(HttpStatusCode.Created);

        await using (var scope = _factory.Services.CreateAsyncScope())
        {
            var dbContextFactory = scope.ServiceProvider.GetRequiredService<IDbContextFactory<WorkstationDbContext>>();
            await using var dbContext = await dbContextFactory.CreateDbContextAsync();
            var currentProfileId = await dbContext.PricingRuns
                .Where(item => item.Id == run.Id)
                .Select(item => item.AuthorizationProfileId)
                .SingleAsync();
            var alternateProfileId = await dbContext.AuthorizationProfiles
                .Where(item => item.Id != currentProfileId)
                .Select(item => item.Id)
                .FirstAsync();
            await dbContext.Database.ExecuteSqlInterpolatedAsync($"""
                UPDATE "PricingChangeSets"
                SET "MarketplaceId" = {"MARKETPLACE-OTHER"},
                    "AuthorizationProfileId" = {alternateProfileId}
                WHERE "Id" = {changeSet!.Id};
                """);
        }

        var getRunResponse = await _client.GetAsync($"/api/v4/pricing/runs/{run.Id}");
        getRunResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);

        var repeatedCreateResponse = await _client.PostAsync(
            $"/api/v4/pricing/runs/{run.Id}/change-sets",
            null);
        repeatedCreateResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ReadProblemCodeAsync(repeatedCreateResponse)).Should().Be("PRICING_CONTEXT_NOT_FOUND");

        var reviewResponse = await _client.PostAsJsonAsync(
            $"/api/v4/pricing/change-sets/{changeSet!.Id}/approve",
            ApprovalRequest("reviewer-cross-reference", allConfirmed: true));
        reviewResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ReadProblemCodeAsync(reviewResponse)).Should().Be("PRICING_CONTEXT_NOT_FOUND");

        var validationResponse = await _client.PostAsync(
            $"/api/v4/pricing/change-sets/{changeSet.Id}/validate",
            null);
        validationResponse.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ReadProblemCodeAsync(validationResponse)).Should().Be("PRICING_CONTEXT_NOT_FOUND");
    }

    private async Task AddCsrfSessionAsync()
    {
        var session = await _client.GetFromJsonAsync<LocalSessionResponse>("/api/v2/system/session");
        _client.DefaultRequestHeaders.Add("X-Klanata-Csrf", session!.CsrfToken);
    }

    private static CreatePricingRunRequest CreateRunRequest(string? idempotencyKey = null) =>
        new(
            "SELLER-TEST",
            "MARKETPLACE-TEST",
            "operator-a",
            new PricingRuleRequest(
                "Integration pricing rule",
                "INCREASE",
                100m,
                new PricingRuleBandRequest("FIXED_AMOUNT", 0.50m),
                new PricingRuleBandRequest("PERCENTAGE", 0.90m),
                0.90m,
                1m),
            idempotencyKey ?? $"test-run-{Guid.NewGuid():N}");

    private static object ApprovalRequest(string approver, bool allConfirmed) => new
    {
        approver,
        confirmations = new
        {
            sellerMarketplace = true,
            ruleVersion = true,
            anomaliesReviewed = true,
            amazonAcceptance = allConfirmed
        }
    };

    private static async Task<string> ReadProblemCodeAsync(HttpResponseMessage response)
    {
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        return document.RootElement.GetProperty("code").GetString()!;
    }
}
