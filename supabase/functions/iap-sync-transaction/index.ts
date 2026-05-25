// Supabase Edge Function: iap-sync-transaction
//
// Called by the iOS app after StoreKit purchase, restore, or entitlement
// refresh. StoreKit remains the device authority for unlocks; this function
// mirrors signed transaction facts to Supabase so account/backend state can
// stay in sync.
//
// Required Edge Function secrets:
//   SUPABASE_SERVICE_ROLE_KEY
//   SUPABASE_URL

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PRODUCT_ID = "club.deadwax.supporter.monthly";

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);

interface SyncRequest {
  signedTransactionInfo: string;
  source?: string;
}

interface AppleTransaction {
  appAccountToken?: string;
  productId?: string;
  originalTransactionId?: string;
  expiresDate?: number | string;
  revocationDate?: number | string;
  environment?: string;
}

function decodeJWS<T>(jws: string): T {
  const [, payload] = jws.split(".");
  if (!payload) throw new Error("Invalid JWS");
  const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(padded), (c) => c.charCodeAt(0))));
}

function dateFromMillis(value?: number | string): string | null {
  if (value == null) return null;
  const numeric = typeof value === "string" ? Number(value) : value;
  if (!Number.isFinite(numeric)) return null;
  return new Date(numeric).toISOString();
}

function statusFor(expiresAt: string | null, revokedAt: string | null): "active" | "expired" | "revoked" {
  if (revokedAt) return "revoked";
  if (expiresAt && new Date(expiresAt).getTime() <= Date.now()) return "expired";
  return "active";
}

async function authenticatedUserID(req: Request): Promise<string> {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "");
  if (!token) throw new Error("Missing Authorization bearer token");

  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) throw error ?? new Error("Invalid user token");
  return data.user.id;
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const userID = await authenticatedUserID(req);
    const body = (await req.json()) as SyncRequest;
    const tx = decodeJWS<AppleTransaction>(body.signedTransactionInfo);

    if (tx.productId !== PRODUCT_ID) {
      return new Response("Ignored product", { status: 200 });
    }
    if (tx.appAccountToken && tx.appAccountToken.toLowerCase() !== userID.toLowerCase()) {
      return new Response("Transaction account mismatch", { status: 403 });
    }

    const expiresAt = dateFromMillis(tx.expiresDate);
    const revokedAt = dateFromMillis(tx.revocationDate);
    const status = statusFor(expiresAt, revokedAt);

    const { error } = await supabase.from("iap_entitlements").upsert({
      user_id: userID,
      product_id: tx.productId,
      original_transaction_id: tx.originalTransactionId ?? null,
      status,
      expires_at: expiresAt,
      revoked_at: revokedAt,
      environment: tx.environment ?? null,
      updated_at: new Date().toISOString(),
    }, { onConflict: "user_id" });
    if (error) throw error;

    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response(String(e), { status: 500 });
  }
});
