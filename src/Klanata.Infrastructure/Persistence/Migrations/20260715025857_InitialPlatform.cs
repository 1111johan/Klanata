using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Klanata.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class InitialPlatform : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "AppMetadata",
                columns: table => new
                {
                    Key = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    Value = table.Column<string>(type: "TEXT", maxLength: 2048, nullable: false),
                    UpdatedAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AppMetadata", x => x.Key);
                });

            migrationBuilder.CreateTable(
                name: "AuditEvents",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    TimestampUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    Actor = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    Action = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    EntityType = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    EntityId = table.Column<string>(type: "TEXT", maxLength: 256, nullable: false),
                    SellerId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                    MarketplaceId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                    BeforeJson = table.Column<string>(type: "TEXT", nullable: true),
                    AfterJson = table.Column<string>(type: "TEXT", nullable: true),
                    Reason = table.Column<string>(type: "TEXT", maxLength: 1024, nullable: true),
                    CorrelationId = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    MachineName = table.Column<string>(type: "TEXT", maxLength: 256, nullable: false),
                    AppVersion = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AuditEvents", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "WorkerLeases",
                columns: table => new
                {
                    LeaseKey = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    OwnerInstanceId = table.Column<string>(type: "TEXT", maxLength: 128, nullable: true),
                    AcquiredAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: true),
                    ExpiresAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: true),
                    HeartbeatAtUtc = table.Column<DateTimeOffset>(type: "TEXT", nullable: true),
                    Version = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_WorkerLeases", x => x.LeaseKey);
                });

            migrationBuilder.CreateIndex(
                name: "IX_AuditEvents_EntityType_EntityId",
                table: "AuditEvents",
                columns: new[] { "EntityType", "EntityId" });

            migrationBuilder.CreateIndex(
                name: "IX_AuditEvents_SellerId_MarketplaceId",
                table: "AuditEvents",
                columns: new[] { "SellerId", "MarketplaceId" });

            migrationBuilder.CreateIndex(
                name: "IX_AuditEvents_TimestampUtc",
                table: "AuditEvents",
                column: "TimestampUtc");

            migrationBuilder.CreateIndex(
                name: "IX_WorkerLeases_ExpiresAtUtc",
                table: "WorkerLeases",
                column: "ExpiresAtUtc");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "AppMetadata");

            migrationBuilder.DropTable(
                name: "AuditEvents");

            migrationBuilder.DropTable(
                name: "WorkerLeases");
        }
    }
}
