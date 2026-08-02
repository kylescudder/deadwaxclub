// Supabase Edge Function: iap-app-store-notifications
//
// App Store Server Notifications V2 are accepted only after Apple signature,
// certificate-chain, bundle, environment, and product verification.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  AppleVerificationError,
  dateFromMillis,
  entitlementStatus,
  verifyAppleNotification,
} from "../_shared/apple-transaction-verification.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);

interface NotificationRequest {
  signedPayload?: unknown;
}

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }

    const body = await req.json() as NotificationRequest;
    const verified = await verifyAppleNotification(body.signedPayload);
    const { transaction } = verified;
    const expiresAt = dateFromMillis(transaction.expiresDate);
    const revokedAt = dateFromMillis(transaction.revocationDate);
    const status = entitlementStatus(
      expiresAt,
      revokedAt,
      verified.notificationType,
    );
    // A notification has no authenticated Supabase user, so the verified
    // app-account token is the only allowed account mapping. Tokenless or
    // malformed notifications are rejected by the shared verifier.
    const { error } = await supabase.rpc("apply_verified_iap_entitlement", {
      p_user_id: transaction.appAccountToken,
      p_bundle_id: transaction.bundleId,
      p_product_id: transaction.productId,
      p_transaction_id: transaction.transactionId,
      p_original_transaction_id: transaction.originalTransactionId,
      p_status: status,
      p_expires_at: expiresAt,
      p_revoked_at: revokedAt,
      p_environment: transaction.environment,
      p_signed_at: dateFromMillis(transaction.signedAt),
      p_verified_at: new Date().toISOString(),
      p_verification_source: "app_store_server_notification",
    });
    if (error) throw error;

    return json({ status: "ok" });
  } catch (error) {
    if (error instanceof AppleVerificationError) {
      console.error("Rejected App Store notification", error.message);
      return json({ error: "notification_verification_failed" }, 400);
    }
    console.error("Unable to mirror verified App Store notification", error);
    return json({ error: "entitlement_mirror_unavailable" }, 500);
  }
});
