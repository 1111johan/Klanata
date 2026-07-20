FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

RUN groupadd --system --gid 10001 klanata \
    && useradd --system --uid 10001 --gid 10001 --home-dir /app --shell /usr/sbin/nologin klanata

WORKDIR /app
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/cache \
    XDG_CONFIG_HOME=/tmp/config \
    XDG_DATA_HOME=/tmp/data
COPY server.ps1 /app/server.ps1
COPY pricing.ps1 /app/pricing.ps1
COPY public /app/public
RUN mkdir -p /app/runtime /data /run/secrets \
    && chown -R 10001:10001 /app/runtime /data \
    && chmod 0755 /run/secrets \
    && chmod -R a-w /app/server.ps1 /app/pricing.ps1 /app/public

USER 10001:10001
ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-File", "/app/server.ps1"]
CMD ["-Port", "4319", "-TemplatePath", "/data/PriceAndQuantity-us.txt"]
