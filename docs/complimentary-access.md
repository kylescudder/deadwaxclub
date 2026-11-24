# Complimentary access

An administrator can grant friends and family unlimited creation without an
Apple subscription. Use the account's original UUID and a protected database
administrator connection; there is no client-facing toggle or write API.

```sql
-- Grant (set false to revoke).
update public.profiles set is_premium_account = true
where id = 'ACCOUNT-UUID';
```

The profile syncs to the signed-in account. Online quota checks and database
insert enforcement honor the flag immediately; offline access uses the last
synced profile. Revocation reaches an offline device when it syncs again.
Lifetime creations continue to count, and revoking complimentary access does
not reset the allowance or cancel an independently paid Apple subscription.
Sign-out clears in-memory access; returning to the same account restores its
cached profile. Do not change IAP verification rows to grant complimentary access.

Deploy the backend migration and sync configuration before distributing the
client. The flag defaults to false for existing and new accounts. Existing
clients cannot use the new offline grant until they update.
