namespace Klanata.Application.Pricing;

public interface IPricingWorkflowService
{
    Task<PricingSyncStatus> GetSyncStatusAsync(
        string sellerId,
        string marketplaceId,
        CancellationToken cancellationToken);

    Task RequestSyncAsync(
        string sellerId,
        string marketplaceId,
        CancellationToken cancellationToken);

    Task<PricingRunView> CreateRunAsync(
        CreatePricingRunRequest request,
        CancellationToken cancellationToken);

    Task<PricingRunView?> GetRunAsync(Guid runId, CancellationToken cancellationToken);

    Task<PricingChangeSetView> CreateChangeSetAsync(
        Guid runId,
        CancellationToken cancellationToken);

    Task<PricingChangeSetView> ApproveChangeSetAsync(
        Guid changeSetId,
        ApprovePricingChangeSetRequest request,
        CancellationToken cancellationToken);

    Task<PricingValidationBlock> ValidateChangeSetAsync(
        Guid changeSetId,
        CancellationToken cancellationToken);
}

public class PricingWorkflowException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

public sealed class PricingContextNotFoundException(string message)
    : PricingWorkflowException("PRICING_CONTEXT_NOT_FOUND", message);

public sealed class PricingRequestInvalidException(string code, string message)
    : PricingWorkflowException(code, message);

public sealed class PricingConflictException(string code, string message)
    : PricingWorkflowException(code, message);

public sealed class PricingReportsUnavailableException()
    : PricingWorkflowException(
        "REPORTS_EXECUTOR_UNAVAILABLE",
        "Amazon Reports 同步执行器尚未接入；本次请求未伪造同步结果，也未调用 Amazon 写接口。");

public sealed class PricingLiveValidationUnavailableException()
    : PricingWorkflowException(
        "LIVE_VALIDATION_UNAVAILABLE",
        "发起人与复核人目前仅为未认证的本地标签；同时尚未实现提交前 Amazon 实时回读、PTD 校验和 purchasable_offer 安全合并，因此生产验证被安全阻断。");
