namespace Klanata.Domain.Entities;

public sealed class AuditEvent
{
    private AuditEvent()
    {
    }

    private AuditEvent(
        Guid id,
        DateTimeOffset timestampUtc,
        string actor,
        string action,
        string entityType,
        string entityId,
        string correlationId,
        string machineName,
        string appVersion,
        string? sellerId,
        string? marketplaceId,
        string? beforeJson,
        string? afterJson,
        string? reason)
    {
        Id = id;
        TimestampUtc = timestampUtc;
        Actor = actor;
        Action = action;
        EntityType = entityType;
        EntityId = entityId;
        CorrelationId = correlationId;
        MachineName = machineName;
        AppVersion = appVersion;
        SellerId = sellerId;
        MarketplaceId = marketplaceId;
        BeforeJson = beforeJson;
        AfterJson = afterJson;
        Reason = reason;
    }

    public Guid Id { get; private set; }

    public DateTimeOffset TimestampUtc { get; private set; }

    public string Actor { get; private set; } = string.Empty;

    public string Action { get; private set; } = string.Empty;

    public string EntityType { get; private set; } = string.Empty;

    public string EntityId { get; private set; } = string.Empty;

    public string? SellerId { get; private set; }

    public string? MarketplaceId { get; private set; }

    public string? BeforeJson { get; private set; }

    public string? AfterJson { get; private set; }

    public string? Reason { get; private set; }

    public string CorrelationId { get; private set; } = string.Empty;

    public string MachineName { get; private set; } = string.Empty;

    public string AppVersion { get; private set; } = string.Empty;

    public static AuditEvent Create(
        DateTimeOffset timestamp,
        string actor,
        string action,
        string entityType,
        string entityId,
        string correlationId,
        string machineName,
        string appVersion,
        string? sellerId = null,
        string? marketplaceId = null,
        string? beforeJson = null,
        string? afterJson = null,
        string? reason = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(actor);
        ArgumentException.ThrowIfNullOrWhiteSpace(action);
        ArgumentException.ThrowIfNullOrWhiteSpace(entityType);
        ArgumentException.ThrowIfNullOrWhiteSpace(entityId);
        ArgumentException.ThrowIfNullOrWhiteSpace(correlationId);
        ArgumentException.ThrowIfNullOrWhiteSpace(machineName);
        ArgumentException.ThrowIfNullOrWhiteSpace(appVersion);

        return new AuditEvent(
            Guid.NewGuid(),
            timestamp.ToUniversalTime(),
            actor.Trim(),
            action.Trim(),
            entityType.Trim(),
            entityId.Trim(),
            correlationId.Trim(),
            machineName.Trim(),
            appVersion.Trim(),
            sellerId?.Trim(),
            marketplaceId?.Trim(),
            beforeJson,
            afterJson,
            reason?.Trim());
    }
}
