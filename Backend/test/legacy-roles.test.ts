import { expect, test } from "bun:test";
import { Pool } from "pg";
import { readdir, readFile } from "node:fs/promises";
import { migrate } from "drizzle-orm/node-postgres/migrator";
import { connectDatabase } from "../src/database";
import { migrateDeployment } from "../scripts/infra-migrations";
import { migrateApplication } from "../db/application";
import { deploymentConfig } from "../scripts/config";
import { provisionRoles } from "../scripts/provision";
const integration = process.env.INFRA_TEST_DATABASE_URL ? test : test.skip;
integration(
  "an existing legacy database keeps data while generic ACLs move to scoped roles",
  async () => {
    const connection = new URL(process.env.INFRA_TEST_DATABASE_URL!);
    if (
      !["localhost", "127.0.0.1"].includes(connection.hostname) ||
      !connection.pathname.endsWith("_test")
    )
      throw new Error("Legacy fixtures require a disposable local test server");
    connection.pathname = "/postgres";
    const cfg = await deploymentConfig();
    const admin = new Pool({ connectionString: connection.href, max: 1 });
    const name = "deadwax_upgrade_" + crypto.randomUUID().replaceAll("-", "");
    for (const role of ["anon", "authenticated", "service_role"]) {
      if (
        !(await admin.query("select 1 from pg_roles where rolname=$1", [role]))
          .rowCount
      )
        await admin.query("create role " + role + " nologin");
    }
    if (
      !(
        await admin.query("select 1 from pg_roles where rolname=$1", [
          cfg.ownerRole,
        ])
      ).rowCount
    )
      await admin.query(
        "create role " +
          cfg.ownerRole +
          " nologin nosuperuser nocreatedb nocreaterole noreplication nobypassrls",
      );
    await admin.query("create database " + name + " owner " + cfg.ownerRole);
    connection.pathname = "/" + name;
    const ownerURL = new URL(connection);
    ownerURL.searchParams.set("options", "-c role=" + cfg.ownerRole);
    const { db, pool } = connectDatabase(ownerURL.href);
    const rootApp = new Pool({ connectionString: connection.href, max: 1 });
    try {
      await migrate(db, { migrationsFolder: "./drizzle" });
      const client = await pool.connect();
      try {
        await client.query("begin");
        await client.query(
          "create schema deadwax_migrations; create table deadwax_migrations.applied(name text primary key)",
        );
        const legacy = new URL("../../supabase/migrations/", import.meta.url);
        const files = [
          ["identity.sql", new URL("../db/identity.sql", import.meta.url)],
          ...(await readdir(legacy))
            .filter(
              (n) => n.endsWith(".sql") && n !== "0002_storage_covers.sql",
            )
            .sort()
            .map((n) => [n, new URL(n, legacy)]),
          ...["access.sql", "recovery.sql", "device-unregister.sql"].map(
            (n) => [n, new URL("../db/" + n, import.meta.url)],
          ),
        ] as [string, URL][];
        for (const [name, path] of files) {
          await client.query(
            (await readFile(path, "utf8")).replace(
              /^grant service_role, anon to deadwax_runtime;$/m,
              "",
            ),
          );
          await client.query(
            "insert into deadwax_migrations.applied values($1)",
            [name],
          );
        }
        await client.query(
          "insert into recovery_lease values(1,clock_timestamp(),clock_timestamp(),'legacy-fixture')",
        );
        await client.query(
          "insert into auth_user(id,name,email,email_verified) values('11111111-1111-4111-8111-111111111111','Legacy fixture','legacy@example.test',true)",
        );
        await client.query("commit");
      } finally {
        client.release();
      }
      await admin.query(
        "grant authenticated, anon, service_role to deadwax_runtime",
      );
      const operator = await rootApp.connect();
      try {
        await provisionRoles(operator, cfg);
      } finally {
        operator.release();
      }
      await migrateDeployment(db, pool, migrateApplication);
      const scoped = await rootApp.connect();
      try {
        await scoped.query("begin");
        await scoped.query("set local role deadwax_api");
        await scoped.query(
          "select set_config('deadwax.user_id','11111111-1111-4111-8111-111111111111',true)",
        );
        const row = (await scoped.query("select display_name from profiles"))
          .rows[0];
        if (row?.display_name !== "Legacy fixture")
          throw new Error("Scoped owner lost legacy data access");
        await scoped.query("rollback");
        await scoped.query("begin");
        await scoped.query("set local role authenticated");
        let refused = false;
        try {
          await scoped.query("select * from profiles");
        } catch (e) {
          refused = (e as { code: string }).code === "42501";
        }
        await scoped.query("rollback");
        if (!refused) throw new Error("Generic role still has legacy access");
        expect(row.display_name).toBe("Legacy fixture");
        expect(refused).toBe(true);
      } finally {
        scoped.release();
      }
    } finally {
      await pool.end();
      await rootApp.end();
      await admin.query("drop database " + name);
      await admin.end();
    }
  },
);
