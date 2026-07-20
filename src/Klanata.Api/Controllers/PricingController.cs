using Klanata.Application.Pricing;
using Microsoft.AspNetCore.Mvc;

namespace Klanata.Api.Controllers;

[ApiController]
[Route("api/v4/pricing")]
public sealed class PricingController(IPricingWorkflowService pricingWorkflowService) : ControllerBase
{
    [HttpGet("sync-status")]
    [ProducesResponseType<PricingSyncStatus>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<PricingSyncStatus>> GetSyncStatus(
        [FromQuery] string? sellerId,
        [FromQuery] string? marketplaceId,
        CancellationToken cancellationToken)
    {
        try
        {
            return Ok(await pricingWorkflowService.GetSyncStatusAsync(
                sellerId ?? string.Empty,
                marketplaceId ?? string.Empty,
                cancellationToken));
        }
        catch (PricingWorkflowException exception)
        {
            return ToProblem(exception);
        }
    }

    [HttpPost("sync")]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> RequestSync(
        [FromBody] PricingSyncRequest request,
        CancellationToken cancellationToken)
    {
        try
        {
            await pricingWorkflowService.RequestSyncAsync(
                request.SellerId,
                request.MarketplaceId,
                cancellationToken);
            throw new PricingReportsUnavailableException();
        }
        catch (PricingWorkflowException exception)
        {
            return ToProblem(exception);
        }
    }

    [HttpPost("runs")]
    [ProducesResponseType<PricingRunView>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PricingRunView>> CreateRun(
        [FromBody] CreatePricingRunRequest request,
        CancellationToken cancellationToken)
    {
        try
        {
            var run = await pricingWorkflowService.CreateRunAsync(request, cancellationToken);
            return CreatedAtAction(nameof(GetRun), new { runId = run.Id }, run);
        }
        catch (PricingWorkflowException exception)
        {
            return ToProblem(exception);
        }
    }

    [HttpGet("runs/{runId:guid}")]
    [ProducesResponseType<PricingRunView>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<PricingRunView>> GetRun(
        Guid runId,
        CancellationToken cancellationToken)
    {
        var run = await pricingWorkflowService.GetRunAsync(runId, cancellationToken);
        return run is null
            ? NotFound(CreateProblem(
                StatusCodes.Status404NotFound,
                "PRICING_RUN_NOT_FOUND",
                "Pricing run not found",
                $"Pricing run '{runId}' was not found."))
            : Ok(run);
    }

    [HttpPost("runs/{runId:guid}/change-sets")]
    [ProducesResponseType<PricingChangeSetView>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PricingChangeSetView>> CreateChangeSet(
        Guid runId,
        CancellationToken cancellationToken)
    {
        try
        {
            var changeSet = await pricingWorkflowService.CreateChangeSetAsync(runId, cancellationToken);
            return StatusCode(StatusCodes.Status201Created, changeSet);
        }
        catch (PricingWorkflowException exception)
        {
            return ToProblem(exception);
        }
    }

    [HttpPost("change-sets/{changeSetId:guid}/approve")]
    [ProducesResponseType<PricingChangeSetView>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PricingChangeSetView>> ApproveChangeSet(
        Guid changeSetId,
        [FromBody] ApprovePricingChangeSetRequest request,
        CancellationToken cancellationToken)
    {
        try
        {
            return Ok(await pricingWorkflowService.ApproveChangeSetAsync(
                changeSetId,
                request,
                cancellationToken));
        }
        catch (PricingWorkflowException exception)
        {
            return ToProblem(exception);
        }
    }

    [HttpPost("change-sets/{changeSetId:guid}/validate")]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PricingValidationBlock>> ValidateChangeSet(
        Guid changeSetId,
        CancellationToken cancellationToken)
    {
        try
        {
            _ = await pricingWorkflowService.ValidateChangeSetAsync(
                changeSetId,
                cancellationToken);
            throw new PricingLiveValidationUnavailableException();
        }
        catch (PricingWorkflowException exception)
        {
            return ToProblem(exception);
        }
    }

    private ObjectResult ToProblem(PricingWorkflowException exception)
    {
        var (status, title) = exception switch
        {
            PricingRequestInvalidException =>
                (StatusCodes.Status400BadRequest, "Pricing request is invalid"),
            PricingContextNotFoundException =>
                (StatusCodes.Status404NotFound, "Pricing context was not found"),
            PricingReportsUnavailableException =>
                (StatusCodes.Status503ServiceUnavailable, "Amazon Reports synchronization is unavailable"),
            PricingLiveValidationUnavailableException =>
                (StatusCodes.Status409Conflict, "Production validation is safely blocked"),
            PricingConflictException =>
                (StatusCodes.Status409Conflict, "Pricing workflow conflict"),
            _ => (StatusCodes.Status400BadRequest, "Pricing request failed")
        };

        return StatusCode(status, CreateProblem(status, exception.Code, title, exception.Message));
    }

    private static ProblemDetails CreateProblem(
        int status,
        string code,
        string title,
        string detail)
    {
        var slug = code.ToLowerInvariant().Replace('_', '-');
        var problem = new ProblemDetails
        {
            Type = $"https://klanata.local/problems/{slug}",
            Title = title,
            Status = status,
            Detail = detail
        };
        problem.Extensions["code"] = code;
        if (code == "LIVE_VALIDATION_UNAVAILABLE")
        {
            problem.Extensions["amazonWriteAttempted"] = false;
            problem.Extensions["identityVerified"] = false;
            problem.Extensions["blockers"] = new[]
            {
                "OPERATOR_IDENTITY_UNAVAILABLE",
                "AMAZON_LIVE_PRICE_UNAVAILABLE",
                "PTD_SAFE_OFFER_MERGE_UNAVAILABLE"
            };
        }

        return problem;
    }
}

public sealed record PricingSyncRequest(string SellerId, string MarketplaceId);
