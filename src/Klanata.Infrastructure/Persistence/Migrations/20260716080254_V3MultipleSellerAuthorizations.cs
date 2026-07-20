using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Klanata.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class V3MultipleSellerAuthorizations : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql(
                """
                CREATE TEMP TABLE "_SellerAuthorizationMigration" AS
                SELECT
                    "Id" AS "SellerAccountId",
                    "AuthorizationProfileId",
                    "LastDiscoveredAtUtc" AS "VerifiedAtUtc"
                FROM "SellerAccounts";
                """);

            migrationBuilder.DropForeignKey(
                name: "FK_SellerAccounts_AuthorizationProfiles_AuthorizationProfileId",
                table: "SellerAccounts");

            migrationBuilder.DropIndex(
                name: "IX_SellerAccounts_AuthorizationProfileId",
                table: "SellerAccounts");

            migrationBuilder.DropColumn(
                name: "AuthorizationProfileId",
                table: "SellerAccounts");

            migrationBuilder.CreateTable(
                name: "SellerAuthorizationGrants",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    SellerAccountId = table.Column<Guid>(type: "TEXT", nullable: false),
                    AuthorizationProfileId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Label = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    Priority = table.Column<int>(type: "INTEGER", nullable: false),
                    IsPrimary = table.Column<bool>(type: "INTEGER", nullable: false),
                    Status = table.Column<string>(type: "TEXT", maxLength: 24, nullable: false),
                    VerifiedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    LastUsedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SellerAuthorizationGrants", x => x.Id);
                    table.ForeignKey(
                        name: "FK_SellerAuthorizationGrants_AuthorizationProfiles_AuthorizationProfileId",
                        column: x => x.AuthorizationProfileId,
                        principalTable: "AuthorizationProfiles",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_SellerAuthorizationGrants_SellerAccounts_SellerAccountId",
                        column: x => x.SellerAccountId,
                        principalTable: "SellerAccounts",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.Sql(
                """
                INSERT INTO "SellerAuthorizationGrants" (
                    "Id",
                    "SellerAccountId",
                    "AuthorizationProfileId",
                    "Label",
                    "Priority",
                    "IsPrimary",
                    "Status",
                    "VerifiedAtUtc",
                    "LastUsedAtUtc")
                SELECT
                    "SellerAccountId",
                    "SellerAccountId",
                    "AuthorizationProfileId",
                    'Migrated primary authorization',
                    0,
                    1,
                    'Verified',
                    "VerifiedAtUtc",
                    NULL
                FROM "_SellerAuthorizationMigration";

                DROP TABLE "_SellerAuthorizationMigration";
                """);

            migrationBuilder.CreateIndex(
                name: "IX_SellerAuthorizationGrants_AuthorizationProfileId",
                table: "SellerAuthorizationGrants",
                column: "AuthorizationProfileId");

            migrationBuilder.CreateIndex(
                name: "IX_SellerAuthorizationGrants_SellerAccountId",
                table: "SellerAuthorizationGrants",
                column: "SellerAccountId",
                unique: true,
                filter: "IsPrimary = 1");

            migrationBuilder.CreateIndex(
                name: "IX_SellerAuthorizationGrants_SellerAccountId_AuthorizationProfileId",
                table: "SellerAuthorizationGrants",
                columns: new[] { "SellerAccountId", "AuthorizationProfileId" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_SellerAuthorizationGrants_SellerAccountId_Priority",
                table: "SellerAuthorizationGrants",
                columns: new[] { "SellerAccountId", "Priority" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql(
                """
                CREATE TEMP TABLE "_SellerAuthorizationRollback" AS
                SELECT
                    "SellerAccountId",
                    COALESCE(
                        MAX(CASE WHEN "IsPrimary" = 1 THEN "AuthorizationProfileId" END),
                        MIN("AuthorizationProfileId")) AS "AuthorizationProfileId"
                FROM "SellerAuthorizationGrants"
                GROUP BY "SellerAccountId";
                """);

            migrationBuilder.DropTable(
                name: "SellerAuthorizationGrants");

            migrationBuilder.AddColumn<Guid>(
                name: "AuthorizationProfileId",
                table: "SellerAccounts",
                type: "TEXT",
                nullable: false,
                defaultValue: new Guid("00000000-0000-0000-0000-000000000000"));

            migrationBuilder.CreateIndex(
                name: "IX_SellerAccounts_AuthorizationProfileId",
                table: "SellerAccounts",
                column: "AuthorizationProfileId");

            migrationBuilder.Sql(
                """
                UPDATE "SellerAccounts"
                SET "AuthorizationProfileId" = (
                    SELECT "AuthorizationProfileId"
                    FROM "_SellerAuthorizationRollback"
                    WHERE "SellerAccountId" = "SellerAccounts"."Id")
                WHERE EXISTS (
                    SELECT 1
                    FROM "_SellerAuthorizationRollback"
                    WHERE "SellerAccountId" = "SellerAccounts"."Id");

                DROP TABLE "_SellerAuthorizationRollback";
                """);

            migrationBuilder.AddForeignKey(
                name: "FK_SellerAccounts_AuthorizationProfiles_AuthorizationProfileId",
                table: "SellerAccounts",
                column: "AuthorizationProfileId",
                principalTable: "AuthorizationProfiles",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);
        }
    }
}
