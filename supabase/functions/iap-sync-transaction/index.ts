// Supabase Edge Function: iap-sync-transaction
//
// Mirrors only Apple-verified transaction data. The database creation-limit
// trigger trusts this mirror, so accepting a decoded-but-unverified JWS here
// would let a client forge unlimited record creation.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  AppleVerificationError,
  dateFromMillis,
  entitlementStatus,
  verifyAppleTransaction,
} from "../_shared/apple-transaction-verification.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);

interface SyncRequest {
  signedTransactionInfo?: unknown;
}

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function authenticatedUserID(req: Request): Promise<string> {
  const authorization = req.headers.get("Authorization") ?? "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token) throw new AppleVerificationError("Missing Authorization bearer token");

  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) throw new AppleVerificationError("Invalid user token");
  return data.user.id.toLowerCase();
}

serve(async (req) => {
  try {
    if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

    const userID = await authenticatedUserID(req);
    const body = await req.json() as SyncRequest;
    const transaction = await verifyAppleTransaction(body.signedTransactionInfo);
    if (transaction.appAccountToken !== userID) {
      return json({ error: "app_account_token_mismatch" }, 403);
    }

    const expiresAt = dateFromMillis(transaction.expiresDate);
    const revokedAt = dateFromMillis(transaction.revocationDate);
    const status = entitlementStatus(expiresAt, revokedAt);
    const { error } = await supabase.from("iap_entitlements").upsert({
      user_id: userID,
      product_id: transaction.productId,
      original_transaction_id: transaction.originalTransactionId,
      status,
      expires_at: expiresAt,
      revoked_at: revokedAt,
      environment: transaction.environment,
      updated_at: new Date().toISOString(),
    }, { onConflict: "user_id" });
    if (error) throw error;

    return json({ status, active: status === "active" });
  } catch (error) {
    if (error instanceof AppleVerificationError) {
      console.error("Rejected entitlement mirror request", error.message);
      return json({ error: "transaction_verification_failed" }, 400);
    }
    console.error("Unable to mirror verified entitlement", error);
    return json({ error: "entitlement_mirror_unavailable" }, 500);
  }
});
