using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Klanata.Application.Abstractions;
using Klanata.Application.Pricing;
using Klanata.Domain.Entities;
using Klanata.Domain.Pricing;
using Klanata.Infrastructure.Configuration;
using Klanata.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Klanata.Infrastructure.Pricing;

public sealed class PricingWorkflowService(
    IDbContextFactory<WorkstationDbContext> dbContextFactory,
    IClock clock,
    IAllowedSellerPolicy allowedSellerPolicy) : IPricingWorkflowService
{
    private static readonly TimeSpan MaximumSnapshotAge = TimeSpan.FromHours(12);
    private static readonly SemaphoreSlim RunCreationGate = new(1, 1);

    public async Task<PricingSyncStatus> GetSyncStatusAsync(
        string sellerId,
        string marketplaceId,
        CancellationToken cancellationToken)
    {
        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        var context = await ResolveContextAsync(dbContext, sellerId, marketplaceId, cancellationToken);
        var snapshot = await dbContext.ProductListings
            .AsNoTracking()
            .Where(item =>
                item.MarketplaceParticipationId == context.MarketplaceParticipationId &&
                item.SellerId == context.SellerId &&
                item.MarketplaceId == context.MarketplaceId)
            .GroupBy(_ => 1)
            .Select(group => new
            {
                Count = group.Count(),
                LastSynchronizedUnixTimeSeconds = group.Max(item => (long?)item.SynchronizedUnixTimeSeconds)
            })
            .SingleOrDefaultAsync(cancellationToken);
        var lastSynchronized = snapshot?.LastSynchronizedUnixTimeSeconds is long lastSynchronizedUnixTimeSeconds
            ? DateTimeOffset.FromUnixTimeSeconds(lastSynchronizedUnixTimeSeconds)
            : (DateTimeOffset?)null;
        var snapshotAge = lastSynchronized is null
            ? (long?)null
            : Math.Max(0, (long)(clock.UtcNow - lastSynchronized.Value).TotalSeconds);
        var isFresh = snapshotAge is not null && snapshotAge <= (long)MaximumSnapshotAge.TotalSeconds;
        var canStart = snapshot is not null &&
                       snapshot.Count > 0 &&
                       isFresh &&
                       context.CanReadPricing is true &&
                       context.CanSimulatePricing is true;
        var state = snapshot is null || snapshot.Count == 0
            ? "SNAPSHOT_EMPTY"
            : isFresh
                ? "SNAPSHOT_FRESH"
                : "SNAPSHOT_STALE";

        return new PricingSyncStatus(
            context.SellerId,
            context.MarketplaceId,
            state,
            ReportsExecutorAvailable: false,
            CanStart: canStart,
            snapshot?.Count ?? 0,
            lastSynchronized,
            snapshotAge,
            snapshot is null || snapshot.Count == 0
                ? "尚无 Amazon 商品快照，Reports 同步执行器也尚未接入。"
                : canStart
                    ? "现有 Amazon 商品快照在 12 小时新鲜门槛内，可以用于安全模拟；当前不能主动刷新。"
                    : "现有快照已过期或价格读取能力不可用，必须在 Reports 同步执行器接入后刷新。");
    }

    public async Task RequestSyncAsync(
        string sellerId,
        string marketplaceId,
        CancellationToken cancellationToken)
    {
        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        _ = await ResolveContextAsync(dbContext, sellerId, marketplaceId, cancellationToken);
        throw new PricingReportsUnavailableException();
    }

    public async Task<PricingRunView> CreateRunAsync(
        CreatePricingRunRequest request,
        CancellationToken cancellationToken)
    {
        await RunCreationGate.WaitAsync(cancellationToken);
        try
        {
            return await CreateRunCoreAsync(request, cancellationToken);
        }
        finally
        {
            RunCreationGate.Release();
        }
    }

    private async Task<PricingRunView> CreateRunCoreAsync(
        CreatePricingRunRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!string.IsNullOrWhiteSpace(request.SellerId))
        {
            EnsureSellerAllowed(request.SellerId);
        }

        var input = ValidateAndNormalize(request);
        EnsureSellerAllowed(input.SellerId);
        var requestFingerprint = ComputeRequestFingerprint(input);
        var idempotencyKey = NormalizeIdempotencyKey(request.IdempotencyKey);

        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        var existingRun = await dbContext.PricingRuns
            .AsNoTracking()
            .SingleOrDefaultAsync(
                item => item.IdempotencyKey == idempotencyKey && item.SellerId == input.SellerId,
                cancellationToken);
        if (existingRun is not null)
        {
            if (!string.Equals(existingRun.RequestFingerprint, requestFingerprint, StringComparison.Ordinal))
            {
                throw new PricingConflictException(
                    "IDEMPOTENCY_KEY_REUSED",
                    "同一幂等键不能用于不同的调价参数。");
            }

            return await LoadRunViewAsync(dbContext, existingRun.Id, cancellationToken)
                ?? throw new PricingContextNotFoundException(
                    $"Pricing run '{existingRun.Id}' was not found.");
        }

        var context = await ResolveContextAsync(
            dbContext,
            input.SellerId,
            input.MarketplaceId,
            cancellationToken);
        if (context.CanReadPricing is not true || context.CanSimulatePricing is not true)
        {
            throw new PricingConflictException(
                "PRICING_SIMULATION_CAPABILITY_REQUIRED",
                "所选 Marketplace 尚未显式开启 V4 调价模拟能力，不能创建调价任务。");
        }

        var listings = await dbContext.ProductListings
            .AsNoTracking()
            .Where(item =>
                item.MarketplaceParticipationId == context.MarketplaceParticipationId &&
                item.SellerId == context.SellerId &&
                item.MarketplaceId == context.MarketplaceId)
            .OrderBy(item => item.Sku)
            .ToListAsync(cancellationToken);
        if (listings.Count == 0)
        {
            throw new PricingConflictException(
                "PRODUCT_SNAPSHOT_REQUIRED",
                "所选店铺和站点没有 Amazon 商品快照，不能创建调价任务。");
        }

        var now = clock.UtcNow;
        var version = (await dbContext.PricingRuleSets
            .Where(item =>
                item.SellerId == context.SellerId &&
                item.MarketplaceId == context.MarketplaceId)
            .MaxAsync(item => (int?)item.Version, cancellationToken) ?? 0) + 1;
        var currencyPrecision = GetCurrencyPrecision(context.CurrencyCode);
        var ruleSet = new PricingRuleSet(
            context.MarketplaceParticipationId,
            context.AuthorizationProfileId,
            context.SellerId,
            context.MarketplaceId,
            input.RuleName,
            version,
            input.Direction,
            input.Threshold,
            input.BelowThresholdType,
            input.BelowThresholdValue,
            input.AtOrAboveThresholdType,
            input.AtOrAboveThresholdValue,
            input.AbsoluteChangeCap,
            input.PercentageChangeCap,
            context.CurrencyCode,
            currencyPrecision,
            BusinessPriceStrategy.Unchanged,
            input.Initiator,
            now);
        var run = new PricingRun(
            ruleSet.Id,
            context.MarketplaceParticipationId,
            context.AuthorizationProfileId,
            CreateRunNumber(now),
            idempotencyKey,
            requestFingerprint,
            context.SellerId,
            context.MarketplaceId,
            input.Initiator,
            now);
        var fbaAsins = listings
            .Where(item =>
                item.FulfillmentChannel == FulfillmentChannel.Fba &&
                !string.IsNullOrWhiteSpace(item.Asin))
            .Select(item => item.Asin!)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        var runItems = new List<PricingRunItem>(listings.Count);
        foreach (var listing in listings)
        {
            var decision = PureFbmEligibilityEvaluator.Evaluate(
                listing,
                fbaAsins,
                now,
                MaximumSnapshotAge);
            if (!string.Equals(
                    listing.CurrencyCode,
                    context.CurrencyCode,
                    StringComparison.OrdinalIgnoreCase))
            {
                decision = new PricingEligibilityDecision(
                    false,
                    [.. decision.Codes, "CURRENCY_MISMATCH"],
                    [.. decision.Reasons, "商品币种与 Marketplace 默认币种不一致"]);
            }

            PricingCalculation? calculation = null;
            if (decision.IsEligible)
            {
                try
                {
                    calculation = PricingRuleCalculator.Calculate(
                        ruleSet,
                        listing.Price!.Value,
                        listing.BusinessPrice);
                }
                catch (InvalidOperationException)
                {
                    decision = new PricingEligibilityDecision(
                        false,
                        ["TARGET_PRICE_INVALID"],
                        ["调价规则会产生无效的目标价格"]);
                }
            }

            runItems.Add(new PricingRunItem(
                run.Id,
                listing.Id,
                listing.Sku,
                listing.Asin,
                listing.Title,
                listing.CurrencyCode,
                listing.Price,
                calculation?.TargetPrice,
                calculation?.ChangeAmount,
                calculation?.ChangePercentage,
                listing.BusinessPrice,
                calculation?.TargetBusinessPrice,
                decision.IsEligible,
                decision.Codes,
                decision.Reasons,
                listing.SnapshotVersion,
                listing.SynchronizedAtUtc));
        }

        await using var transaction = await dbContext.Database.BeginTransactionAsync(cancellationToken);
        dbContext.PricingRuleSets.Add(ruleSet);
        dbContext.PricingRuns.Add(run);
        dbContext.PricingRunItems.AddRange(runItems);
        dbContext.AuditEvents.Add(AuditEvent.Create(
            now,
            run.InitiatedBy,
            "PRICING_RUN_CREATED",
            nameof(PricingRun),
            run.Id.ToString("N"),
            run.Id.ToString("N"),
            Environment.MachineName,
            "4.0.0-p0",
            run.SellerId,
            run.MarketplaceId,
            reason: $"Rule version {ruleSet.Version}; eligible {runItems.Count(item => item.IsEligible)} of {runItems.Count}."));
        try
        {
            await dbContext.SaveChangesAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);
        }
        catch (DbUpdateException) when (!string.IsNullOrWhiteSpace(request.IdempotencyKey))
        {
            await transaction.RollbackAsync(cancellationToken);
            dbContext.ChangeTracker.Clear();
            var concurrentRun = await dbContext.PricingRuns
                .AsNoTracking()
                .SingleOrDefaultAsync(
                    item => item.IdempotencyKey == idempotencyKey && item.SellerId == input.SellerId,
                    cancellationToken);
            if (concurrentRun is null)
            {
                throw;
            }

            if (!string.Equals(concurrentRun.RequestFingerprint, requestFingerprint, StringComparison.Ordinal))
            {
                throw new PricingConflictException(
                    "IDEMPOTENCY_KEY_REUSED",
                    "同一幂等键不能用于不同的调价参数。");
            }

            return await LoadRunViewAsync(dbContext, concurrentRun.Id, cancellationToken)
                ?? throw new PricingContextNotFoundException(
                    $"Pricing run '{concurrentRun.Id}' was not found.");
        }

        return await LoadRunViewAsync(dbContext, run.Id, cancellationToken)
            ?? throw new PricingContextNotFoundException($"Pricing run '{run.Id}' was not found.");
    }

    public async Task<PricingRunView?> GetRunAsync(Guid runId, CancellationToken cancellationToken)
    {
        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        return await LoadRunViewAsync(dbContext, runId, cancellationToken);
    }

    public async Task<PricingChangeSetView> CreateChangeSetAsync(
        Guid runId,
        CancellationToken cancellationToken)
    {
        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        var allowedSellerIds = allowedSellerPolicy.SellerIds;
        var run = await dbContext.PricingRuns
            .SingleOrDefaultAsync(
                item => item.Id == runId && allowedSellerIds.Contains(item.SellerId),
                cancellationToken)
            ?? throw new PricingContextNotFoundException($"Pricing run '{runId}' was not found.");
        var ruleSet = await LoadConsistentRuleSetAsync(dbContext, run, cancellationToken)
            ?? throw new PricingContextNotFoundException($"Pricing run '{runId}' was not found.");
        var existing = await dbContext.PricingChangeSets
            .AsNoTracking()
            .SingleOrDefaultAsync(item => item.PricingRunId == runId, cancellationToken);
        if (existing is not null)
        {
            EnsureChangeSetMatchesRun(existing, run);
            return await LoadChangeSetViewAsync(dbContext, existing, cancellationToken);
        }

        var canCreateDraftChangeSet = await dbContext.MarketplaceCapabilities
            .AsNoTracking()
            .Where(item => item.MarketplaceParticipationId == run.MarketplaceParticipationId)
            .Select(item => (bool?)item.CanCreateDraftChangeSets)
            .SingleOrDefaultAsync(cancellationToken);
        if (canCreateDraftChangeSet is not true)
        {
            throw new PricingConflictException(
                "PRICING_CHANGE_SET_CAPABILITY_REQUIRED",
                "所选 Marketplace 尚未显式开启 V4 草稿变更集能力。");
        }

        var eligibleItems = await dbContext.PricingRunItems
            .AsNoTracking()
            .Where(item => item.PricingRunId == runId && item.IsEligible)
            .OrderBy(item => item.Sku)
            .ToListAsync(cancellationToken);
        if (eligibleItems.Count == 0)
        {
            throw new PricingConflictException(
                "NO_ELIGIBLE_ITEMS",
                "任务中没有通过纯 FBM 筛选的 SKU，不能创建变更集。");
        }

        var changeSet = new PricingChangeSet(
            run.Id,
            run.PricingRuleSetId,
            run.AuthorizationProfileId,
            run.SellerId,
            run.MarketplaceId,
            run.InitiatedBy,
            clock.UtcNow);
        var changeSetItems = eligibleItems.Select(item => new PricingChangeSetItem(
            changeSet.Id,
            item.Id,
            item.Sku,
            item.CurrentPrice!.Value,
            item.TargetPrice!.Value,
            item.CurrentBusinessPrice,
            targetBusinessPrice: null,
            item.SnapshotVersion,
            ComputeChangeSetItemKey(run, ruleSet, item))).ToArray();

        await using var transaction = await dbContext.Database.BeginTransactionAsync(cancellationToken);
        run.MarkPendingReview();
        dbContext.PricingChangeSets.Add(changeSet);
        dbContext.PricingChangeSetItems.AddRange(changeSetItems);
        dbContext.AuditEvents.Add(AuditEvent.Create(
            clock.UtcNow,
            run.InitiatedBy,
            "PRICING_CHANGE_SET_CREATED",
            nameof(PricingChangeSet),
            changeSet.Id.ToString("N"),
            run.Id.ToString("N"),
            Environment.MachineName,
            "4.0.0-p0",
            run.SellerId,
            run.MarketplaceId,
            reason: $"Created {changeSetItems.Length} immutable price changes; B2B changes: 0."));
        try
        {
            await dbContext.SaveChangesAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);
        }
        catch (DbUpdateException)
        {
            await transaction.RollbackAsync(cancellationToken);
            dbContext.ChangeTracker.Clear();
            var concurrentChangeSet = await dbContext.PricingChangeSets
                .AsNoTracking()
                .SingleOrDefaultAsync(item => item.PricingRunId == runId, cancellationToken);
            if (concurrentChangeSet is null)
            {
                throw;
            }

            EnsureChangeSetMatchesRun(concurrentChangeSet, run);
            return await LoadChangeSetViewAsync(dbContext, concurrentChangeSet, cancellationToken);
        }

        return await LoadChangeSetViewAsync(dbContext, changeSet, cancellationToken);
    }

    public async Task<PricingChangeSetView> ApproveChangeSetAsync(
        Guid changeSetId,
        ApprovePricingChangeSetRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        var allowedSellerIds = allowedSellerPolicy.SellerIds;
        var changeSet = await dbContext.PricingChangeSets
            .SingleOrDefaultAsync(
                item => item.Id == changeSetId && allowedSellerIds.Contains(item.SellerId),
                cancellationToken)
            ?? throw new PricingContextNotFoundException($"Pricing change set '{changeSetId}' was not found.");
        var run = await dbContext.PricingRuns
            .SingleOrDefaultAsync(
                item =>
                    item.Id == changeSet.PricingRunId &&
                    allowedSellerIds.Contains(item.SellerId),
                cancellationToken)
            ?? throw new PricingContextNotFoundException($"Pricing change set '{changeSetId}' was not found.");
        EnsureChangeSetMatchesRun(changeSet, run);
        if (string.IsNullOrWhiteSpace(request.Approver))
        {
            throw new PricingRequestInvalidException("REVIEWER_LABEL_REQUIRED", "复核人标签不能为空。");
        }

        if (request.Confirmations is null ||
            !request.Confirmations.SellerMarketplace ||
            !request.Confirmations.RuleVersion ||
            !request.Confirmations.AnomaliesReviewed ||
            !request.Confirmations.AmazonAcceptance)
        {
            throw new PricingRequestInvalidException(
                "ALL_CONFIRMATIONS_REQUIRED",
                "店铺站点、规则版本、异常 SKU 和 Amazon 接受语义四项确认缺一不可。");
        }

        var approver = request.Approver.Trim();
        var existingApproval = await dbContext.PricingApprovals
            .AsNoTracking()
            .SingleOrDefaultAsync(item => item.PricingChangeSetId == changeSetId, cancellationToken);
        if (existingApproval is not null)
        {
            if (string.Equals(existingApproval.Approver, approver, StringComparison.OrdinalIgnoreCase))
            {
                return await LoadChangeSetViewAsync(dbContext, changeSet, cancellationToken);
            }

            throw new PricingConflictException("CHANGE_SET_REVIEW_ALREADY_RECORDED", "该变更集已经记录了其他复核人标签。");
        }

        if (string.Equals(changeSet.InitiatedBy, approver, StringComparison.OrdinalIgnoreCase))
        {
            throw new PricingConflictException(
                "SELF_APPROVAL_FORBIDDEN",
                "调价任务发起人标签不能复核自己的变更集。");
        }

        var now = clock.UtcNow;
        var approval = new PricingApproval(
            changeSet.Id,
            approver,
            request.Confirmations.SellerMarketplace,
            request.Confirmations.RuleVersion,
            request.Confirmations.AnomaliesReviewed,
            request.Confirmations.AmazonAcceptance,
            now);

        await using var transaction = await dbContext.Database.BeginTransactionAsync(cancellationToken);
        changeSet.RecordReview(approver, now);
        run.MarkReviewRecorded();
        dbContext.PricingApprovals.Add(approval);
        dbContext.AuditEvents.Add(AuditEvent.Create(
            now,
            approver,
            "PRICING_CHANGE_SET_REVIEW_RECORDED",
            nameof(PricingChangeSet),
            changeSet.Id.ToString("N"),
            run.Id.ToString("N"),
            Environment.MachineName,
            "4.0.0-p0",
            changeSet.SellerId,
            changeSet.MarketplaceId,
            reason: "A different unverified operator label completed all four review confirmations; IdentityVerified=false."));
        try
        {
            await dbContext.SaveChangesAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);
        }
        catch (DbUpdateException)
        {
            await transaction.RollbackAsync(cancellationToken);
            dbContext.ChangeTracker.Clear();
            var concurrentApproval = await dbContext.PricingApprovals
                .AsNoTracking()
                .SingleOrDefaultAsync(item => item.PricingChangeSetId == changeSetId, cancellationToken);
            if (concurrentApproval is null)
            {
                throw;
            }

            var persistedChangeSet = await dbContext.PricingChangeSets
                .AsNoTracking()
                .SingleAsync(
                    item => item.Id == changeSetId && allowedSellerIds.Contains(item.SellerId),
                    cancellationToken);
            if (!string.Equals(concurrentApproval.Approver, approver, StringComparison.OrdinalIgnoreCase))
            {
                throw new PricingConflictException(
                    "CHANGE_SET_ALREADY_APPROVED",
                    "该变更集已经记录了其他复核人标签。");
            }

            return await LoadChangeSetViewAsync(dbContext, persistedChangeSet, cancellationToken);
        }

        return await LoadChangeSetViewAsync(dbContext, changeSet, cancellationToken);
    }

    public async Task<PricingValidationBlock> ValidateChangeSetAsync(
        Guid changeSetId,
        CancellationToken cancellationToken)
    {
        await using var dbContext = await dbContextFactory.CreateDbContextAsync(cancellationToken);
        var allowedSellerIds = allowedSellerPolicy.SellerIds;
        var changeSet = await dbContext.PricingChangeSets
            .AsNoTracking()
            .SingleOrDefaultAsync(
                item => item.Id == changeSetId && allowedSellerIds.Contains(item.SellerId),
                cancellationToken)
            ?? throw new PricingContextNotFoundException($"Pricing change set '{changeSetId}' was not found.");
        var run = await dbContext.PricingRuns
            .AsNoTracking()
            .SingleOrDefaultAsync(
                item =>
                    item.Id == changeSet.PricingRunId &&
                    allowedSellerIds.Contains(item.SellerId),
                cancellationToken)
            ?? throw new PricingContextNotFoundException($"Pricing change set '{changeSetId}' was not found.");
        EnsureChangeSetMatchesRun(changeSet, run);
        if (changeSet.Status != PricingChangeSetStatus.ReviewRecorded)
        {
            throw new PricingConflictException(
                "CHANGE_SET_NOT_APPROVED",
                "变更集必须先记录异人标签的四项复核，才能进入生产预校验。");
        }

        var approvalActor = await dbContext.PricingApprovals
            .AsNoTracking()
            .Where(item => item.PricingChangeSetId == changeSetId)
            .Select(item => item.Approver)
            .SingleOrDefaultAsync(cancellationToken) ?? "SYSTEM";
        dbContext.AuditEvents.Add(AuditEvent.Create(
            clock.UtcNow,
            approvalActor,
            "PRICING_VALIDATION_BLOCKED",
            nameof(PricingChangeSet),
            changeSet.Id.ToString("N"),
            changeSet.PricingRunId.ToString("N"),
            Environment.MachineName,
            "4.0.0-p0",
            changeSet.SellerId,
            changeSet.MarketplaceId,
            reason: "LIVE_VALIDATION_UNAVAILABLE; AmazonWriteAttempted=false."));
        await dbContext.SaveChangesAsync(cancellationToken);

        throw new PricingLiveValidationUnavailableException();
    }

    private void EnsureSellerAllowed(string sellerId)
    {
        if (!allowedSellerPolicy.IsAllowed(sellerId))
        {
            throw new PricingContextNotFoundException(
                $"Seller '{sellerId.Trim()}' is not available in this workstation.");
        }
    }

    private async Task<ResolvedPricingContext> ResolveContextAsync(
        WorkstationDbContext dbContext,
        string sellerId,
        string marketplaceId,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(sellerId) || string.IsNullOrWhiteSpace(marketplaceId))
        {
            throw new PricingRequestInvalidException(
                "SELLER_MARKETPLACE_REQUIRED",
                "必须选择 Amazon 已授权的店铺和 Marketplace。");
        }

        var normalizedSellerId = sellerId.Trim();
        var normalizedMarketplaceId = marketplaceId.Trim();
        EnsureSellerAllowed(normalizedSellerId);
        var allowedSellerIds = allowedSellerPolicy.SellerIds;
        var marketplace = await (
                from participation in dbContext.MarketplaceParticipations.AsNoTracking()
                join seller in dbContext.SellerAccounts.AsNoTracking()
                    on participation.SellerAccountId equals seller.Id
                where seller.IsActive &&
                      participation.IsParticipating &&
                      allowedSellerIds.Contains(seller.SellerId) &&
                      seller.SellerId == normalizedSellerId &&
                      participation.MarketplaceId == normalizedMarketplaceId
                select new
                {
                    participation.Id,
                    participation.SellerAccountId,
                    seller.SellerId,
                    participation.MarketplaceId,
                    participation.DefaultCurrencyCode,
                    participation.Region
                })
            .SingleOrDefaultAsync(cancellationToken);
        if (marketplace is null)
        {
            throw new PricingContextNotFoundException(
                $"Seller '{normalizedSellerId}' is not authorized for Marketplace '{normalizedMarketplaceId}'.");
        }

        var capability = await dbContext.MarketplaceCapabilities
            .AsNoTracking()
            .Where(item => item.MarketplaceParticipationId == marketplace.Id)
            .Select(item => new
            {
                item.CanReadPricing,
                item.CanSimulatePricing
            })
            .SingleOrDefaultAsync(cancellationToken);

        var authorizationProfileId = await (
                from grant in dbContext.SellerAuthorizationGrants.AsNoTracking()
                join profile in dbContext.AuthorizationProfiles.AsNoTracking()
                    on grant.AuthorizationProfileId equals profile.Id
                join application in dbContext.DeveloperApplications.AsNoTracking()
                    on profile.DeveloperApplicationId equals application.Id
                where grant.SellerAccountId == marketplace.SellerAccountId &&
                      grant.Status == SellerAuthorizationGrantStatus.Verified &&
                      profile.Status == AuthorizationProfileStatus.Verified &&
                      profile.Region == marketplace.Region &&
                      application.IsActive
                orderby grant.IsPrimary descending, grant.Priority, grant.Id
                select (Guid?)profile.Id)
            .FirstOrDefaultAsync(cancellationToken);
        if (authorizationProfileId is null)
        {
            throw new PricingContextNotFoundException(
                $"Seller '{normalizedSellerId}' has no verified Amazon authorization.");
        }

        return new ResolvedPricingContext(
            marketplace.Id,
            authorizationProfileId.Value,
            marketplace.SellerId,
            marketplace.MarketplaceId,
            marketplace.DefaultCurrencyCode,
            capability?.CanReadPricing,
            capability?.CanSimulatePricing);
    }

    private static NormalizedRunInput ValidateAndNormalize(CreatePricingRunRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.SellerId) ||
            string.IsNullOrWhiteSpace(request.MarketplaceId) ||
            string.IsNullOrWhiteSpace(request.Initiator))
        {
            throw new PricingRequestInvalidException(
                "RUN_CONTEXT_REQUIRED",
                "店铺、Marketplace 和任务发起人不能为空。");
        }

        if (request.Rule is null ||
            request.Rule.BelowThreshold is null ||
            request.Rule.AtOrAboveThreshold is null ||
            string.IsNullOrWhiteSpace(request.Rule.Name))
        {
            throw new PricingRequestInvalidException("RULE_REQUIRED", "必须提供完整的版本化调价规则。");
        }

        var direction = ParseDirection(request.Rule.Direction);
        var belowType = ParseAdjustmentType(request.Rule.BelowThreshold.Type);
        var upperType = ParseAdjustmentType(request.Rule.AtOrAboveThreshold.Type);
        if (request.Rule.Threshold <= 0 ||
            request.Rule.BelowThreshold.Value <= 0 ||
            request.Rule.AtOrAboveThreshold.Value <= 0 ||
            request.Rule.AbsoluteChangeCap is <= 0 ||
            request.Rule.PercentageChangeCap is <= 0)
        {
            throw new PricingRequestInvalidException(
                "RULE_VALUE_INVALID",
                "阈值和调整值必须大于 0，上限也必须大于 0。");
        }

        var businessPriceStrategy = NormalizeEnumValue(request.Rule.BusinessPriceStrategy);
        if (businessPriceStrategy.Length > 0 &&
            !string.Equals(businessPriceStrategy, "UNCHANGED", StringComparison.Ordinal))
        {
            throw new PricingRequestInvalidException(
                "BUSINESS_PRICE_STRATEGY_UNSUPPORTED",
                "V4 P0 仅允许 UNCHANGED，系统不会创建或修改企业价。");
        }

        return new NormalizedRunInput(
            request.SellerId.Trim(),
            request.MarketplaceId.Trim(),
            request.Initiator.Trim(),
            request.Rule.Name.Trim(),
            direction,
            request.Rule.Threshold,
            belowType,
            request.Rule.BelowThreshold.Value,
            upperType,
            request.Rule.AtOrAboveThreshold.Value,
            request.Rule.AbsoluteChangeCap,
            request.Rule.PercentageChangeCap);
    }

    private static PricingDirection ParseDirection(string value) =>
        NormalizeEnumValue(value) switch
        {
            "INCREASE" => PricingDirection.Increase,
            "DECREASE" => PricingDirection.Decrease,
            _ => throw new PricingRequestInvalidException(
                "DIRECTION_INVALID",
                "调价方向只允许 INCREASE 或 DECREASE。")
        };

    private static PricingAdjustmentType ParseAdjustmentType(string value) =>
        NormalizeEnumValue(value) switch
        {
            "FIXEDAMOUNT" => PricingAdjustmentType.FixedAmount,
            "PERCENTAGE" => PricingAdjustmentType.Percentage,
            _ => throw new PricingRequestInvalidException(
                "ADJUSTMENT_TYPE_INVALID",
                "调整类型只允许 FIXED_AMOUNT 或 PERCENTAGE。")
        };

    private static string NormalizeEnumValue(string? value) =>
        string.IsNullOrWhiteSpace(value)
            ? string.Empty
            : value.Trim().Replace("_", string.Empty, StringComparison.Ordinal)
                .Replace("-", string.Empty, StringComparison.Ordinal)
                .ToUpperInvariant();

    private static int GetCurrencyPrecision(string currencyCode) =>
        currencyCode.ToUpperInvariant() switch
        {
            "JPY" or "KRW" or "VND" => 0,
            "BHD" or "JOD" or "KWD" or "OMR" or "TND" => 3,
            _ => 2
        };

    private static string NormalizeIdempotencyKey(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new PricingRequestInvalidException(
                "IDEMPOTENCY_KEY_REQUIRED",
                "创建调价任务必须提供稳定的幂等键。");
        }

        var normalized = value.Trim();
        return normalized.Length <= 128 ? normalized : ComputeHash(normalized);
    }

    private static string ComputeRequestFingerprint(NormalizedRunInput input) =>
        ComputeHash(string.Join('|',
            input.SellerId,
            input.MarketplaceId,
            input.Initiator,
            input.RuleName,
            input.Direction,
            input.Threshold.ToString(CultureInfo.InvariantCulture),
            input.BelowThresholdType,
            input.BelowThresholdValue.ToString(CultureInfo.InvariantCulture),
            input.AtOrAboveThresholdType,
            input.AtOrAboveThresholdValue.ToString(CultureInfo.InvariantCulture),
            input.AbsoluteChangeCap?.ToString(CultureInfo.InvariantCulture) ?? string.Empty,
            input.PercentageChangeCap?.ToString(CultureInfo.InvariantCulture) ?? string.Empty,
            BusinessPriceStrategy.Unchanged));

    private static string ComputeChangeSetItemKey(
        PricingRun run,
        PricingRuleSet ruleSet,
        PricingRunItem item) =>
        ComputeHash(string.Join('|',
            run.AuthorizationProfileId.ToString("N"),
            run.MarketplaceId,
            item.Sku,
            item.TargetPrice!.Value.ToString(CultureInfo.InvariantCulture),
            "B2B_UNCHANGED",
            ruleSet.Version.ToString(CultureInfo.InvariantCulture),
            item.SnapshotVersion.ToString(CultureInfo.InvariantCulture)));

    private static string ComputeHash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    private static string CreateRunNumber(DateTimeOffset now) =>
        $"PR-{now:yyyyMMddHHmmss}-{Guid.NewGuid():N}"[..29].ToUpperInvariant();

    private static Task<PricingRuleSet?> LoadConsistentRuleSetAsync(
        WorkstationDbContext dbContext,
        PricingRun run,
        CancellationToken cancellationToken) =>
        dbContext.PricingRuleSets
            .AsNoTracking()
            .SingleOrDefaultAsync(
                item =>
                    item.Id == run.PricingRuleSetId &&
                    item.SellerId == run.SellerId &&
                    item.MarketplaceId == run.MarketplaceId &&
                    item.MarketplaceParticipationId == run.MarketplaceParticipationId &&
                    item.AuthorizationProfileId == run.AuthorizationProfileId,
                cancellationToken);

    private static bool ChangeSetMatchesRun(PricingChangeSet changeSet, PricingRun run) =>
        changeSet.PricingRunId == run.Id &&
        changeSet.PricingRuleSetId == run.PricingRuleSetId &&
        changeSet.AuthorizationProfileId == run.AuthorizationProfileId &&
        string.Equals(changeSet.SellerId, run.SellerId, StringComparison.Ordinal) &&
        string.Equals(changeSet.MarketplaceId, run.MarketplaceId, StringComparison.Ordinal) &&
        string.Equals(changeSet.InitiatedBy, run.InitiatedBy, StringComparison.Ordinal);

    private static void EnsureChangeSetMatchesRun(PricingChangeSet changeSet, PricingRun run)
    {
        if (!ChangeSetMatchesRun(changeSet, run))
        {
            throw new PricingContextNotFoundException(
                $"Pricing change set '{changeSet.Id}' was not found.");
        }
    }

    private async Task<PricingRunView?> LoadRunViewAsync(
        WorkstationDbContext dbContext,
        Guid runId,
        CancellationToken cancellationToken)
    {
        var allowedSellerIds = allowedSellerPolicy.SellerIds;
        var run = await dbContext.PricingRuns
            .AsNoTracking()
            .SingleOrDefaultAsync(
                item => item.Id == runId && allowedSellerIds.Contains(item.SellerId),
                cancellationToken);
        if (run is null)
        {
            return null;
        }

        var rule = await LoadConsistentRuleSetAsync(dbContext, run, cancellationToken);
        if (rule is null)
        {
            return null;
        }

        var items = await dbContext.PricingRunItems
            .AsNoTracking()
            .Where(item => item.PricingRunId == runId)
            .OrderByDescending(item => item.IsEligible)
            .ThenBy(item => item.Sku)
            .ToListAsync(cancellationToken);
        var changeSet = await dbContext.PricingChangeSets
            .AsNoTracking()
            .SingleOrDefaultAsync(item => item.PricingRunId == runId, cancellationToken);
        if (changeSet is not null && !ChangeSetMatchesRun(changeSet, run))
        {
            return null;
        }

        var eligible = items.Count(item => item.IsEligible);
        return new PricingRunView(
            run.Id,
            run.RunNumber,
            run.SellerId,
            run.MarketplaceId,
            ToApiValue(run.Status),
            run.InitiatedBy,
            run.CreatedAtUtc,
            new PricingRuleView(
                rule.Id,
                rule.Version,
                rule.Name,
                ToApiValue(rule.Direction),
                rule.Threshold,
                new PricingRuleBandView(ToApiValue(rule.BelowThresholdType), rule.BelowThresholdValue),
                new PricingRuleBandView(ToApiValue(rule.AtOrAboveThresholdType), rule.AtOrAboveThresholdValue),
                rule.AbsoluteChangeCap,
                rule.PercentageChangeCap,
                rule.CurrencyCode,
                rule.CurrencyPrecision,
                "UNCHANGED"),
            new PricingRunSummary(items.Count, eligible, items.Count - eligible, BusinessPriceModifiedCount: 0),
            items.Select(item => new PricingRunItemView(
                item.Id,
                item.Sku,
                item.Asin,
                item.Title,
                item.IsEligible,
                item.ExclusionCodes.ToArray(),
                item.ExclusionReasons.ToArray(),
                item.CurrentPrice,
                item.TargetPrice,
                item.PriceChange,
                item.PriceChangePercent,
                item.CurrentBusinessPrice,
                item.TargetBusinessPrice,
                item.CurrencyCode,
                item.SnapshotVersion,
                item.SynchronizedAtUtc)).ToArray(),
            changeSet is null
                ? null
                : await LoadChangeSetViewAsync(dbContext, changeSet, cancellationToken));
    }

    private async Task<PricingChangeSetView> LoadChangeSetViewAsync(
        WorkstationDbContext dbContext,
        PricingChangeSet changeSet,
        CancellationToken cancellationToken)
    {
        EnsureSellerAllowed(changeSet.SellerId);
        var allowedSellerIds = allowedSellerPolicy.SellerIds;
        var run = await dbContext.PricingRuns
            .AsNoTracking()
            .SingleOrDefaultAsync(
                item =>
                    item.Id == changeSet.PricingRunId &&
                    allowedSellerIds.Contains(item.SellerId),
                cancellationToken)
            ?? throw new PricingContextNotFoundException(
                $"Pricing change set '{changeSet.Id}' was not found.");
        EnsureChangeSetMatchesRun(changeSet, run);
        var itemCount = await dbContext.PricingChangeSetItems
            .AsNoTracking()
            .CountAsync(item => item.PricingChangeSetId == changeSet.Id, cancellationToken);
        var approval = await dbContext.PricingApprovals
            .AsNoTracking()
            .SingleOrDefaultAsync(item => item.PricingChangeSetId == changeSet.Id, cancellationToken);
        return new PricingChangeSetView(
            changeSet.Id,
            changeSet.PricingRunId,
            changeSet.SellerId,
            changeSet.MarketplaceId,
            approval is null ? ToApiValue(changeSet.Status) : "REVIEW_RECORDED",
            changeSet.InitiatedBy,
            itemCount,
            changeSet.CreatedAtUtc,
            changeSet.ApprovedAtUtc,
            approval is null
                ? null
                : new PricingApprovalView(
                    approval.Id,
                    approval.Approver,
                    IdentityVerified: false,
                    IdentityAssurance: "UNVERIFIED_LOCAL_LABEL",
                    approval.SellerMarketplaceConfirmed,
                    approval.RuleVersionConfirmed,
                    approval.AnomaliesReviewed,
                    approval.AmazonAcceptanceConfirmed,
                    approval.ApprovedAtUtc));
    }

    private static string ToApiValue(Enum value)
    {
        var name = value.ToString();
        var builder = new StringBuilder(name.Length + 4);
        for (var index = 0; index < name.Length; index++)
        {
            if (index > 0 && char.IsUpper(name[index]) && char.IsLower(name[index - 1]))
            {
                builder.Append('_');
            }

            builder.Append(char.ToUpperInvariant(name[index]));
        }

        return builder.ToString();
    }

    private sealed record ResolvedPricingContext(
        Guid MarketplaceParticipationId,
        Guid AuthorizationProfileId,
        string SellerId,
        string MarketplaceId,
        string CurrencyCode,
        bool? CanReadPricing,
        bool? CanSimulatePricing);

    private sealed record NormalizedRunInput(
        string SellerId,
        string MarketplaceId,
        string Initiator,
        string RuleName,
        PricingDirection Direction,
        decimal Threshold,
        PricingAdjustmentType BelowThresholdType,
        decimal BelowThresholdValue,
        PricingAdjustmentType AtOrAboveThresholdType,
        decimal AtOrAboveThresholdValue,
        decimal? AbsoluteChangeCap,
        decimal? PercentageChangeCap);
}
