using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Klanata.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class V3CommerceContextReadModel : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "DeveloperApplications",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    Name = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    ClientIdFingerprint = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    IsActive = table.Column<bool>(type: "INTEGER", nullable: false),
                    CreatedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    LastValidatedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_DeveloperApplications", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "AuthorizationProfiles",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    DeveloperApplicationId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Name = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    Region = table.Column<string>(type: "TEXT", maxLength: 32, nullable: false),
                    EncryptedSecretReference = table.Column<string>(type: "TEXT", maxLength: 256, nullable: false),
                    Status = table.Column<string>(type: "TEXT", maxLength: 32, nullable: false),
                    CreatedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    LastVerifiedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AuthorizationProfiles", x => x.Id);
                    table.ForeignKey(
                        name: "FK_AuthorizationProfiles_DeveloperApplications_DeveloperApplicationId",
                        column: x => x.DeveloperApplicationId,
                        principalTable: "DeveloperApplications",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "SellerAccounts",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    AuthorizationProfileId = table.Column<Guid>(type: "TEXT", nullable: false),
                    SellerId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    DisplayName = table.Column<string>(type: "TEXT", maxLength: 256, nullable: false),
                    IsActive = table.Column<bool>(type: "INTEGER", nullable: false),
                    DiscoveredAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    LastDiscoveredAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SellerAccounts", x => x.Id);
                    table.ForeignKey(
                        name: "FK_SellerAccounts_AuthorizationProfiles_AuthorizationProfileId",
                        column: x => x.AuthorizationProfileId,
                        principalTable: "AuthorizationProfiles",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "MarketplaceParticipations",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    SellerAccountId = table.Column<Guid>(type: "TEXT", nullable: false),
                    MarketplaceId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    Name = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    CountryCode = table.Column<string>(type: "TEXT", maxLength: 8, nullable: false),
                    DefaultCurrencyCode = table.Column<string>(type: "TEXT", maxLength: 8, nullable: false),
                    Region = table.Column<string>(type: "TEXT", maxLength: 32, nullable: false),
                    IsParticipating = table.Column<bool>(type: "INTEGER", nullable: false),
                    HasSuspendedListings = table.Column<bool>(type: "INTEGER", nullable: false),
                    DiscoveredAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    LastVerifiedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MarketplaceParticipations", x => x.Id);
                    table.ForeignKey(
                        name: "FK_MarketplaceParticipations_SellerAccounts_SellerAccountId",
                        column: x => x.SellerAccountId,
                        principalTable: "SellerAccounts",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "MarketplaceCapabilities",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    MarketplaceParticipationId = table.Column<Guid>(type: "TEXT", nullable: false),
                    CanReadListings = table.Column<bool>(type: "INTEGER", nullable: false),
                    CanReadCatalog = table.Column<bool>(type: "INTEGER", nullable: false),
                    CanReadPricing = table.Column<bool>(type: "INTEGER", nullable: false),
                    CanCreateDraftChangeSets = table.Column<bool>(type: "INTEGER", nullable: false),
                    CanSimulatePricing = table.Column<bool>(type: "INTEGER", nullable: false),
                    CanWritePrices = table.Column<bool>(type: "INTEGER", nullable: false),
                    CanWriteMfnInventory = table.Column<bool>(type: "INTEGER", nullable: false),
                    VerifiedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    WriteBlockReason = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MarketplaceCapabilities", x => x.Id);
                    table.ForeignKey(
                        name: "FK_MarketplaceCapabilities_MarketplaceParticipations_MarketplaceParticipationId",
                        column: x => x.MarketplaceParticipationId,
                        principalTable: "MarketplaceParticipations",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "ProductListings",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    MarketplaceParticipationId = table.Column<Guid>(type: "TEXT", nullable: false),
                    SellerId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    MarketplaceId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    Sku = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    Asin = table.Column<string>(type: "TEXT", maxLength: 32, nullable: true),
                    Title = table.Column<string>(type: "TEXT", maxLength: 512, nullable: true),
                    FulfillmentChannel = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    Status = table.Column<string>(type: "TEXT", maxLength: 24, nullable: false),
                    CurrencyCode = table.Column<string>(type: "TEXT", maxLength: 8, nullable: false),
                    Price = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    BusinessPrice = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    MfnQuantity = table.Column<int>(type: "INTEGER", nullable: true),
                    SynchronizedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    SynchronizedUnixTimeSeconds = table.Column<long>(type: "INTEGER", nullable: false),
                    AmazonUpdatedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: true),
                    SourceReference = table.Column<string>(type: "TEXT", maxLength: 256, nullable: true),
                    SnapshotVersion = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ProductListings", x => x.Id);
                    table.ForeignKey(
                        name: "FK_ProductListings_MarketplaceParticipations_MarketplaceParticipationId",
                        column: x => x.MarketplaceParticipationId,
                        principalTable: "MarketplaceParticipations",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateIndex(
                name: "IX_AuthorizationProfiles_DeveloperApplicationId",
                table: "AuthorizationProfiles",
                column: "DeveloperApplicationId");

            migrationBuilder.CreateIndex(
                name: "IX_AuthorizationProfiles_EncryptedSecretReference",
                table: "AuthorizationProfiles",
                column: "EncryptedSecretReference",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_DeveloperApplications_ClientIdFingerprint",
                table: "DeveloperApplications",
                column: "ClientIdFingerprint",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_MarketplaceCapabilities_MarketplaceParticipationId",
                table: "MarketplaceCapabilities",
                column: "MarketplaceParticipationId",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_MarketplaceParticipations_SellerAccountId_MarketplaceId",
                table: "MarketplaceParticipations",
                columns: new[] { "SellerAccountId", "MarketplaceId" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_ProductListings_MarketplaceParticipationId",
                table: "ProductListings",
                column: "MarketplaceParticipationId");

            migrationBuilder.CreateIndex(
                name: "IX_ProductListings_SellerId_MarketplaceId_Sku",
                table: "ProductListings",
                columns: new[] { "SellerId", "MarketplaceId", "Sku" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_ProductListings_SellerId_MarketplaceId_Status",
                table: "ProductListings",
                columns: new[] { "SellerId", "MarketplaceId", "Status" });

            migrationBuilder.CreateIndex(
                name: "IX_ProductListings_SellerId_MarketplaceId_SynchronizedUnixTimeSeconds",
                table: "ProductListings",
                columns: new[] { "SellerId", "MarketplaceId", "SynchronizedUnixTimeSeconds" });

            migrationBuilder.CreateIndex(
                name: "IX_SellerAccounts_AuthorizationProfileId",
                table: "SellerAccounts",
                column: "AuthorizationProfileId");

            migrationBuilder.CreateIndex(
                name: "IX_SellerAccounts_SellerId",
                table: "SellerAccounts",
                column: "SellerId",
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "MarketplaceCapabilities");

            migrationBuilder.DropTable(
                name: "ProductListings");

            migrationBuilder.DropTable(
                name: "MarketplaceParticipations");

            migrationBuilder.DropTable(
                name: "SellerAccounts");

            migrationBuilder.DropTable(
                name: "AuthorizationProfiles");

            migrationBuilder.DropTable(
                name: "DeveloperApplications");
        }
    }
}
