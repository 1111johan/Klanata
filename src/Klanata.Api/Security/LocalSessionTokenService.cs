using System.Security.Cryptography;

namespace Klanata.Api.Security;

public sealed class LocalSessionTokenService
{
    public const string CookieName = "Klanata.Session";

    public LocalSessionTokenService()
    {
        SessionCookie = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
        CsrfToken = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
    }

    public string SessionCookie { get; }

    public string CsrfToken { get; }

    public bool IsValid(string? sessionCookie, string? csrfToken)
    {
        return FixedTimeEquals(SessionCookie, sessionCookie) && FixedTimeEquals(CsrfToken, csrfToken);
    }

    private static bool FixedTimeEquals(string expected, string? actual)
    {
        if (string.IsNullOrEmpty(actual))
        {
            return false;
        }

        var expectedBytes = Convert.FromBase64String(expected);
        byte[] actualBytes;
        try
        {
            actualBytes = Convert.FromBase64String(actual);
        }
        catch (FormatException)
        {
            return false;
        }

        return expectedBytes.Length == actualBytes.Length &&
               CryptographicOperations.FixedTimeEquals(expectedBytes, actualBytes);
    }
}
