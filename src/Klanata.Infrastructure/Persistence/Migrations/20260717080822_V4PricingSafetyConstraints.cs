using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Klanata.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class V4PricingSafetyConstraints : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "FK_PricingApprovals_PricingChangeSets_PricingChangeSetId",
                table: "PricingApprovals");

            migrationBuilder.DropForeignKey(
                name: "FK_PricingChangeSetItems_PricingChangeSets_PricingChangeSetId",
                table: "PricingChangeSetItems");

            migrationBuilder.DropForeignKey(
                name: "FK_PricingChangeSets_PricingRuns_PricingRunId",
                table: "PricingChangeSets");

            migrationBuilder.DropForeignKey(
                name: "FK_PricingRunItems_PricingRuns_PricingRunId",
                table: "PricingRunItems");

            migrationBuilder.AddCheckConstraint(
                name: "CK_PricingChangeSetItems_BusinessPriceUnchanged",
                table: "PricingChangeSetItems",
                sql: "TargetBusinessPrice IS NULL AND BusinessPriceModified = 0");

            migrationBuilder.AddForeignKey(
                name: "FK_PricingApprovals_PricingChangeSets_PricingChangeSetId",
                table: "PricingApprovals",
                column: "PricingChangeSetId",
                principalTable: "PricingChangeSets",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);

            migrationBuilder.AddForeignKey(
                name: "FK_PricingChangeSetItems_PricingChangeSets_PricingChangeSetId",
                table: "PricingChangeSetItems",
                column: "PricingChangeSetId",
                principalTable: "PricingChangeSets",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);

            migrationBuilder.AddForeignKey(
                name: "FK_PricingChangeSets_PricingRuns_PricingRunId",
                table: "PricingChangeSets",
                column: "PricingRunId",
                principalTable: "PricingRuns",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);

            migrationBuilder.AddForeignKey(
                name: "FK_PricingRunItems_PricingRuns_PricingRunId",
                table: "PricingRunItems",
                column: "PricingRunId",
                principalTable: "PricingRuns",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "FK_PricingApprovals_PricingChangeSets_PricingChangeSetId",
                table: "PricingApprovals");

            migrationBuilder.DropForeignKey(
                name: "FK_PricingChangeSetItems_PricingChangeSets_PricingChangeSetId",
                table: "PricingChangeSetItems");

            migrationBuilder.DropForeignKey(
                name: "FK_PricingChangeSets_PricingRuns_PricingRunId",
                table: "PricingChangeSets");

            migrationBuilder.DropForeignKey(
                name: "FK_PricingRunItems_PricingRuns_PricingRunId",
                table: "PricingRunItems");

            migrationBuilder.DropCheckConstraint(
                name: "CK_PricingChangeSetItems_BusinessPriceUnchanged",
                table: "PricingChangeSetItems");

            migrationBuilder.AddForeignKey(
                name: "FK_PricingApprovals_PricingChangeSets_PricingChangeSetId",
                table: "PricingApprovals",
                column: "PricingChangeSetId",
                principalTable: "PricingChangeSets",
                principalColumn: "Id",
                onDelete: ReferentialAction.Cascade);

            migrationBuilder.AddForeignKey(
                name: "FK_PricingChangeSetItems_PricingChangeSets_PricingChangeSetId",
                table: "PricingChangeSetItems",
                column: "PricingChangeSetId",
                principalTable: "PricingChangeSets",
                principalColumn: "Id",
                onDelete: ReferentialAction.Cascade);

            migrationBuilder.AddForeignKey(
                name: "FK_PricingChangeSets_PricingRuns_PricingRunId",
                table: "PricingChangeSets",
                column: "PricingRunId",
                principalTable: "PricingRuns",
                principalColumn: "Id",
                onDelete: ReferentialAction.Cascade);

            migrationBuilder.AddForeignKey(
                name: "FK_PricingRunItems_PricingRuns_PricingRunId",
                table: "PricingRunItems",
                column: "PricingRunId",
                principalTable: "PricingRuns",
                principalColumn: "Id",
                onDelete: ReferentialAction.Cascade);
        }
    }
}
