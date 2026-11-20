import type { PoolClient } from "pg";
const roles: Record<string, string> = {
  authenticated: "deadwax_api",
  anon: "deadwax_anon",
  service_role: "deadwax_service",
};
// Rewrite SQL identifiers, never strings, comments, policy names or function bodies.
export function scopeLegacySQL(sql: string): string {
  return sql.replace(
    /--[^\n]*|\/\*[\s\S]*?\*\/|'(?:''|[^'])*'|"(?:""|[^"])*"|(\$[a-zA-Z0-9_]*\$)[\s\S]*?\1|\b(authenticated|anon|service_role)\b/g,
    (token, _dollar: string, role: string) =>
      role
        ? roles[role]
        : token.startsWith('"') && roles[token.slice(1, -1)]
          ? '"' + roles[token.slice(1, -1)] + '"'
          : token,
  );
}
export async function upgradeLegacyPrivileges(client: PoolClient) {
  for (const [oldRole, newRole] of Object.entries(roles)) {
    const role = (
      await client.query("select oid from pg_roles where rolname=$1", [oldRole])
    ).rows[0];
    if (!role) continue;
    const oid = role.oid;
    // Only this database's public/auth objects are inspected or changed.
    const owned = await client.query(
      "select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','auth') and c.relowner=$1 union all select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','auth') and p.proowner=$1 union all select 1 from pg_namespace n where n.nspname in ('public','auth') and n.nspowner=$1 limit 1",
      [oid],
    );
    if (owned.rowCount)
      throw new Error(
        "Legacy generic role owns application objects; operator recovery required",
      );
    const tables = await client.query(
      "select n.nspname,c.relname,c.relkind,a.privilege_type,a.is_grantable from pg_class c join pg_namespace n on n.oid=c.relnamespace cross join lateral aclexplode(c.relacl) a where n.nspname in ('public','auth') and a.grantee=$1",
      [oid],
    );
    for (const row of tables.rows) {
      const target =
        '"' +
        row.nspname.replaceAll('"', '""') +
        '"."' +
        row.relname.replaceAll('"', '""') +
        '"';
      const kind = row.relkind === "S" ? "sequence" : "table";
      await client.query(
        `grant ${row.privilege_type} on ${kind} ${target} to ${newRole}${row.is_grantable ? " with grant option" : ""}`,
      );
    }
    const columns = await client.query(
      "select n.nspname,c.relname,col.attname,a.privilege_type,a.is_grantable from pg_attribute col join pg_class c on c.oid=col.attrelid join pg_namespace n on n.oid=c.relnamespace cross join lateral aclexplode(col.attacl) a where n.nspname in ('public','auth') and a.grantee=$1",
      [oid],
    );
    for (const row of columns.rows) {
      const quote = (s: string) => '"' + s.replaceAll('"', '""') + '"';
      await client.query(
        `grant ${row.privilege_type} (${quote(row.attname)}) on table ${quote(row.nspname)}.${quote(row.relname)} to ${newRole}${row.is_grantable ? " with grant option" : ""}`,
      );
      await client.query(
        `revoke ${row.privilege_type} (${quote(row.attname)}) on table ${quote(row.nspname)}.${quote(row.relname)} from ${oldRole}`,
      );
    }
    const functions = await client.query(
      "select p.oid::regprocedure::text as name,a.privilege_type,a.is_grantable from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join lateral aclexplode(p.proacl) a where n.nspname in ('public','auth') and a.grantee=$1",
      [oid],
    );
    for (const row of functions.rows)
      await client.query(
        `grant execute on function ${row.name} to ${newRole}${row.is_grantable ? " with grant option" : ""}`,
      );
    const schemas = await client.query(
      "select n.nspname,a.privilege_type,a.is_grantable from pg_namespace n cross join lateral aclexplode(n.nspacl) a where n.nspname in ('public','auth') and a.grantee=$1",
      [oid],
    );
    for (const row of schemas.rows)
      await client.query(
        `grant ${row.privilege_type} on schema ${row.nspname} to ${newRole}${row.is_grantable ? " with grant option" : ""}`,
      );
    const policies = await client.query(
      "select schemaname,tablename,policyname,roles::text[] as roles from pg_policies where schemaname in ('public','auth') and $1 = any(roles)",
      [oldRole],
    );
    const quote = (s: string) => '"' + s.replaceAll('"', '""') + '"';
    for (const row of policies.rows) {
      const targets = row.roles
        .map((role: string) => roles[role] ?? role)
        .map(quote)
        .join(",");
      await client.query(
        `alter policy ${quote(row.policyname)} on ${quote(row.schemaname)}.${quote(row.tablename)} to ${targets}`,
      );
    }
    await client.query(
      `revoke all privileges on all tables in schema public, auth from ${oldRole}`,
    );
    await client.query(
      `revoke all privileges on all sequences in schema public, auth from ${oldRole}`,
    );
    await client.query(
      `revoke all privileges on all functions in schema public, auth from ${oldRole}`,
    );
    await client.query(
      `revoke all privileges on schema public, auth from ${oldRole}`,
    );
  }
}
