# Entitlement security checks

Run these checks after deploying both IAP Edge Functions with valid Apple
verification secrets. They intentionally never use a real production
transaction.

1. Send a malformed or forged compact JWS to `iap-sync-transaction` with a
   valid Supabase access token. It must return `400` with
   `transaction_verification_failed`, and the user's `iap_entitlements` row
   must not change.

   ```sh
   curl -i "$SUPABASE_URL/functions/v1/iap-sync-transaction" \
     -H "Authorization: Bearer $USER_ACCESS_TOKEN" \
     -H "apikey: $SUPABASE_ANON_KEY" \
     -H "Content-Type: application/json" \
     --data '{"signedTransactionInfo":"forged.payload.signature"}'
   ```

2. Use a StoreKit sandbox transaction that was purchased with account A's
   `appAccountToken`, then submit its verified JWS while authenticated as
   account B. The function must return `403 app_account_token_mismatch` and
   must not create/update account B's entitlement.

3. POST a malformed `signedPayload` to `iap-app-store-notifications`. It must
   return `400 notification_verification_failed` and no entitlement row may
   change.

4. On two signed-in devices at four free records, create a record on both
   while both devices are online. One device creates record five; the other
   receives `DW001`, removes its optimistic local record, presents the
   paywall, and then successfully syncs a later unrelated edit. Inspect
   PowerSync diagnostics to confirm the rejected entry was acknowledged and
   the later entry left the CRUD queue.
