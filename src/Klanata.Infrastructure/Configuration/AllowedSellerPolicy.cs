using Microsoft.Extensions.Options;

namespace Klanata.Infrastructure.Configuration;

public interface IAllowedSellerPolicy
{
    IReadOnlyList<string> SellerIds { get; }

    bool IsAllowed(string? sellerId);
}

public sealed class AllowedSellerPolicy : IAllowedSellerPolicy
{
    private readonly HashSet<string> sellerIds;

    public AllowedSellerPolicy(IOptions<WorkstationOptions> options)
    {
        ArgumentNullException.ThrowIfNull(options);
        SellerIds = (options.Value.AllowedSellerIds ?? [])
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Select(item => item.Trim())
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        if (SellerIds.Count == 0)
        {
            throw new InvalidOperationException(
                "Workstation:AllowedSellerIds must contain at least one Amazon Seller ID.");
        }

        sellerIds = SellerIds.ToHashSet(StringComparer.Ordinal);
    }

    public IReadOnlyList<string> SellerIds { get; }

    public bool IsAllowed(string? sellerId) =>
        !string.IsNullOrWhiteSpace(sellerId) && sellerIds.Contains(sellerId.Trim());
}
