using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Klanata.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class V4PricingFoundation : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql(
                """
                UPDATE MarketplaceCapabilities
                SET CanCreateDraftChangeSets = 1,
                    CanSimulatePricing = 1,
                    CanWritePrices = 0,
                    WriteBlockReason = 'V4 pricing drafts are enabled; Amazon price writes remain blocked by production validation.'
                WHERE CanReadListings = 1 AND CanReadPricing = 1;
                """);

            migrationBuilder.CreateTable(
                name: "PricingRuleSets",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    MarketplaceParticipationId = table.Column<Guid>(type: "TEXT", nullable: false),
                    AuthorizationProfileId = table.Column<Guid>(type: "TEXT", nullable: false),
                    SellerId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    MarketplaceId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    Name = table.Column<string>(type: "TEXT", maxLength: 160, nullable: false),
                    Version = table.Column<int>(type: "INTEGER", nullable: false),
                    Direction = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    Threshold = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: false),
                    BelowThresholdType = table.Column<string>(type: "TEXT", maxLength: 24, nullable: false),
                    BelowThresholdValue = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: false),
                    AtOrAboveThresholdType = table.Column<string>(type: "TEXT", maxLength: 24, nullable: false),
                    AtOrAboveThresholdValue = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: false),
                    AbsoluteChangeCap = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    PercentageChangeCap = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    CurrencyCode = table.Column<string>(type: "TEXT", maxLength: 8, nullable: false),
                    CurrencyPrecision = table.Column<int>(type: "INTEGER", nullable: false),
                    BusinessPriceStrategy = table.Column<string>(type: "TEXT", maxLength: 24, nullable: false),
                    CreatedBy = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    CreatedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PricingRuleSets", x => x.Id);
                    table.ForeignKey(
                        name: "FK_PricingRuleSets_AuthorizationProfiles_AuthorizationProfileId",
                        column: x => x.AuthorizationProfileId,
                        principalTable: "AuthorizationProfiles",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_PricingRuleSets_MarketplaceParticipations_MarketplaceParticipationId",
                        column: x => x.MarketplaceParticipationId,
                        principalTable: "MarketplaceParticipations",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "PricingRuns",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    PricingRuleSetId = table.Column<Guid>(type: "TEXT", nullable: false),
                    MarketplaceParticipationId = table.Column<Guid>(type: "TEXT", nullable: false),
                    AuthorizationProfileId = table.Column<Guid>(type: "TEXT", nullable: false),
                    RunNumber = table.Column<string>(type: "TEXT", maxLength: 40, nullable: false),
                    IdempotencyKey = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    RequestFingerprint = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    SellerId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    MarketplaceId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    InitiatedBy = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    Status = table.Column<string>(type: "TEXT", maxLength: 24, nullable: false),
                    CreatedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PricingRuns", x => x.Id);
                    table.ForeignKey(
                        name: "FK_PricingRuns_AuthorizationProfiles_AuthorizationProfileId",
                        column: x => x.AuthorizationProfileId,
                        principalTable: "AuthorizationProfiles",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_PricingRuns_MarketplaceParticipations_MarketplaceParticipationId",
                        column: x => x.MarketplaceParticipationId,
                        principalTable: "MarketplaceParticipations",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_PricingRuns_PricingRuleSets_PricingRuleSetId",
                        column: x => x.PricingRuleSetId,
                        principalTable: "PricingRuleSets",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "PricingChangeSets",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    PricingRunId = table.Column<Guid>(type: "TEXT", nullable: false),
                    PricingRuleSetId = table.Column<Guid>(type: "TEXT", nullable: false),
                    AuthorizationProfileId = table.Column<Guid>(type: "TEXT", nullable: false),
                    SellerId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    MarketplaceId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    InitiatedBy = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    Status = table.Column<string>(type: "TEXT", maxLength: 24, nullable: false),
                    CreatedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    ApprovedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PricingChangeSets", x => x.Id);
                    table.ForeignKey(
                        name: "FK_PricingChangeSets_AuthorizationProfiles_AuthorizationProfileId",
                        column: x => x.AuthorizationProfileId,
                        principalTable: "AuthorizationProfiles",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_PricingChangeSets_PricingRuleSets_PricingRuleSetId",
                        column: x => x.PricingRuleSetId,
                        principalTable: "PricingRuleSets",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_PricingChangeSets_PricingRuns_PricingRunId",
                        column: x => x.PricingRunId,
                        principalTable: "PricingRuns",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "PricingRunItems",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    PricingRunId = table.Column<Guid>(type: "TEXT", nullable: false),
                    ProductListingId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Sku = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    Asin = table.Column<string>(type: "TEXT", maxLength: 32, nullable: true),
                    Title = table.Column<string>(type: "TEXT", maxLength: 512, nullable: true),
                    CurrencyCode = table.Column<string>(type: "TEXT", maxLength: 8, nullable: false),
                    CurrentPrice = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    TargetPrice = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    PriceChange = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    PriceChangePercent = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    CurrentBusinessPrice = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    TargetBusinessPrice = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    IsEligible = table.Column<bool>(type: "INTEGER", nullable: false),
                    ExclusionCodesData = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false),
                    ExclusionReasonsData = table.Column<string>(type: "TEXT", maxLength: 2048, nullable: false),
                    SnapshotVersion = table.Column<long>(type: "INTEGER", nullable: false),
                    SynchronizedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PricingRunItems", x => x.Id);
                    table.ForeignKey(
                        name: "FK_PricingRunItems_PricingRuns_PricingRunId",
                        column: x => x.PricingRunId,
                        principalTable: "PricingRuns",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_PricingRunItems_ProductListings_ProductListingId",
                        column: x => x.ProductListingId,
                        principalTable: "ProductListings",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "PricingApprovals",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    PricingChangeSetId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Approver = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    SellerMarketplaceConfirmed = table.Column<bool>(type: "INTEGER", nullable: false),
                    RuleVersionConfirmed = table.Column<bool>(type: "INTEGER", nullable: false),
                    AnomaliesReviewed = table.Column<bool>(type: "INTEGER", nullable: false),
                    AmazonAcceptanceConfirmed = table.Column<bool>(type: "INTEGER", nullable: false),
                    ApprovedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PricingApprovals", x => x.Id);
                    table.ForeignKey(
                        name: "FK_PricingApprovals_PricingChangeSets_PricingChangeSetId",
                        column: x => x.PricingChangeSetId,
                        principalTable: "PricingChangeSets",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "PricingChangeSetItems",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    PricingChangeSetId = table.Column<Guid>(type: "TEXT", nullable: false),
                    PricingRunItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Sku = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    CurrentPrice = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: false),
                    TargetPrice = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: false),
                    CurrentBusinessPrice = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    TargetBusinessPrice = table.Column<decimal>(type: "TEXT", precision: 18, scale: 4, nullable: true),
                    BusinessPriceModified = table.Column<bool>(type: "INTEGER", nullable: false),
                    SnapshotVersion = table.Column<long>(type: "INTEGER", nullable: false),
                    IdempotencyKey = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PricingChangeSetItems", x => x.Id);
                    table.ForeignKey(
                        name: "FK_PricingChangeSetItems_PricingChangeSets_PricingChangeSetId",
                        column: x => x.PricingChangeSetId,
                        principalTable: "PricingChangeSets",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_PricingChangeSetItems_PricingRunItems_PricingRunItemId",
                        column: x => x.PricingRunItemId,
                        principalTable: "PricingRunItems",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateIndex(
                name: "IX_PricingApprovals_PricingChangeSetId",
                table: "PricingApprovals",
                column: "PricingChangeSetId",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_PricingChangeSetItems_IdempotencyKey",
                table: "PricingChangeSetItems",
                column: "IdempotencyKey",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_PricingChangeSetItems_PricingChangeSetId_PricingRunItemId",
                table: "PricingChangeSetItems",
                columns: new[] { "PricingChangeSetId", "PricingRunItemId" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_PricingChangeSetItems_PricingRunItemId",
                table: "PricingChangeSetItems",
                column: "PricingRunItemId");

            migrationBuilder.CreateIndex(
                name: "IX_PricingChangeSets_AuthorizationProfileId",
                table: "PricingChangeSets",
                column: "AuthorizationProfileId");

            migrationBuilder.CreateIndex(
                name: "IX_PricingChangeSets_PricingRuleSetId",
                table: "PricingChangeSets",
                column: "PricingRuleSetId");

            migrationBuilder.CreateIndex(
                name: "IX_PricingChangeSets_PricingRunId",
                table: "PricingChangeSets",
                column: "PricingRunId",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_PricingRuleSets_AuthorizationProfileId",
                table: "PricingRuleSets",
                column: "AuthorizationProfileId");

            migrationBuilder.CreateIndex(
                name: "IX_PricingRuleSets_MarketplaceParticipationId",
                table: "PricingRuleSets",
                column: "MarketplaceParticipationId");

            migrationBuilder.CreateIndex(
                name: "IX_PricingRuleSets_SellerId_MarketplaceId_Version",
                table: "PricingRuleSets",
                columns: new[] { "SellerId", "MarketplaceId", "Version" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_PricingRunItems_PricingRunId_Sku",
                table: "PricingRunItems",
                columns: new[] { "PricingRunId", "Sku" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_PricingRunItems_ProductListingId",
                table: "PricingRunItems",
                column: "ProductListingId");

            migrationBuilder.CreateIndex(
                name: "IX_PricingRuns_AuthorizationProfileId",
                table: "PricingRuns",
                column: "AuthorizationProfileId");

            migrationBuilder.CreateIndex(
                name: "IX_PricingRuns_IdempotencyKey",
                table: "PricingRuns",
                column: "IdempotencyKey",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_PricingRuns_MarketplaceParticipationId",
                table: "PricingRuns",
                column: "MarketplaceParticipationId");

            migrationBuilder.CreateIndex(
                name: "IX_PricingRuns_PricingRuleSetId",
                table: "PricingRuns",
                column: "PricingRuleSetId");

            migrationBuilder.CreateIndex(
                name: "IX_PricingRuns_RunNumber",
                table: "PricingRuns",
                column: "RunNumber",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_PricingRuns_SellerId_MarketplaceId_CreatedAtUtc",
                table: "PricingRuns",
                columns: new[] { "SellerId", "MarketplaceId", "CreatedAtUtc" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql(
                """
                UPDATE MarketplaceCapabilities
                SET CanCreateDraftChangeSets = 0,
                    CanSimulatePricing = 0,
                    CanWritePrices = 0,
                    WriteBlockReason = 'V4 pricing draft workflow is not enabled.';
                """);

            migrationBuilder.DropTable(
                name: "PricingApprovals");

            migrationBuilder.DropTable(
                name: "PricingChangeSetItems");

            migrationBuilder.DropTable(
                name: "PricingChangeSets");

            migrationBuilder.DropTable(
                name: "PricingRunItems");

            migrationBuilder.DropTable(
                name: "PricingRuns");

            migrationBuilder.DropTable(
                name: "PricingRuleSets");
        }
    }
}
