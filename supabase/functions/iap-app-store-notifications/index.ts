// Supabase Edge Function: iap-app-store-notifications
//
// Endpoint for App Store Server Notifications V2. It decodes the notification
// payload and mirrors the subscription state into public.iap_entitlements.
// StoreKit on-device remains the immediate unlock authority in v1.
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

interface NotificationRequest {
  signedPayload: string;
}

interface AppleNotificationPayload {
  notificationType?: string;
  subtype?: string;
  data?: {
    signedTransactionInfo?: string;
  };
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

function statusFor(notificationType: string | undefined, expiresAt: string | null, revokedAt: string | null): "active" | "expired" | "revoked" | "unknown" {
  if (revokedAt || notificationType === "REFUND" || notificationType === "REVOKE") return "revoked";
  if (notificationType === "EXPIRED") return "expired";
  if (expiresAt && new Date(expiresAt).getTime() <= Date.now()) return "expired";
  if (notificationType == null) return "unknown";
  return "active";
}

async function updateByOriginalTransactionID(tx: AppleTransaction, status: string, expiresAt: string | null, revokedAt: string | null) {
  if (!tx.originalTransactionId) return;
  const { error } = await supabase
    .from("iap_entitlements")
    .update({
      product_id: tx.productId ?? PRODUCT_ID,
      status,
      expires_at: expiresAt,
      revoked_at: revokedAt,
      environment: tx.environment ?? null,
      updated_at: new Date().toISOString(),
    })
    .eq("original_transaction_id", tx.originalTransactionId);
  if (error) throw error;
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const body = (await req.json()) as NotificationRequest;
    const notification = decodeJWS<AppleNotificationPayload>(body.signedPayload);
    const signedTransactionInfo = notification.data?.signedTransactionInfo;
    if (!signedTransactionInfo) return new Response("no transaction", { status: 200 });

    const tx = decodeJWS<AppleTransaction>(signedTransactionInfo);
    if (tx.productId !== PRODUCT_ID) return new Response("ignored product", { status: 200 });

    const expiresAt = dateFromMillis(tx.expiresDate);
    const revokedAt = dateFromMillis(tx.revocationDate);
    const status = statusFor(notification.notificationType, expiresAt, revokedAt);

    if (tx.appAccountToken) {
      const { error } = await supabase.from("iap_entitlements").upsert({
        user_id: tx.appAccountToken.toLowerCase(),
        product_id: tx.productId,
        original_transaction_id: tx.originalTransactionId ?? null,
        status,
        expires_at: expiresAt,
        revoked_at: revokedAt,
        environment: tx.environment ?? null,
        updated_at: new Date().toISOString(),
      }, { onConflict: "user_id" });
      if (error) throw error;
    } else {
      await updateByOriginalTransactionID(tx, status, expiresAt, revokedAt);
    }

    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response(String(e), { status: 500 });
  }
});
