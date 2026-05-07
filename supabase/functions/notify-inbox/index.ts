// Supabase Edge Function: notify-inbox
//
// Triggered by a Database Webhook on `notifications` (INSERT). For each row,
// looks up the user's APNs device tokens and fans the push.
//
// This is the single APNs sender for the app — anything that wants to notify
// a user just inserts a row into `public.notifications`. Today the producers
// are `notify-price-change` (kind=price_alert) and `invite_to_collection`
// (kind=collection_invite), but new event kinds drop in for free.
//
// Required Edge Function secrets:
//   SUPABASE_SERVICE_ROLE_KEY    Supabase service-role key (already injected)
//   SUPABASE_URL                 Project URL (already injected)
//   APNS_TEAM_ID                 Apple Developer team ID
//   APNS_KEY_ID                  Key ID of the APNs auth key
//   APNS_PRIVATE_KEY             Contents of the AuthKey_XXXX.p8 file
//   APNS_BUNDLE_ID               e.g. com.deadwaxclub.app
//
// Configure the webhook in Supabase Studio:
//   Database -> Webhooks -> Create
//     Table:    notifications
//     Events:   Insert
//     URL:      https://<project>.supabase.co/functions/v1/notify-inbox
//     Method:   POST
//     Header:   Authorization: Bearer <SUPABASE_ANON_KEY>

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { create as createJWT, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

interface NotificationPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  record: {
    id: string;
    user_id: string;
    kind: "price_alert" | "collection_invite";
    title: string;
    body: string;
    payload: Record<string, unknown>;
    created_at: string;
  };
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID")!;
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID")!;
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY")!;
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);

let cachedJWT: { token: string; expires: number } | null = null;

async function apnsAuthToken(): Promise<string> {
  if (cachedJWT && cachedJWT.expires > Date.now() + 60_000) return cachedJWT.token;

  const pem = APNS_PRIVATE_KEY.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const token = await createJWT(
    { alg: "ES256", kid: APNS_KEY_ID },
    { iss: APNS_TEAM_ID, iat: getNumericDate(0) },
    key,
  );
  cachedJWT = { token, expires: Date.now() + 50 * 60 * 1000 };
  return token;
}

interface DeviceToken {
  apns_token: string;
  environment: "sandbox" | "production";
}

async function deviceTokensForUser(userID: string): Promise<DeviceToken[]> {
  const { data, error } = await supabase
    .from("device_tokens")
    .select("apns_token, environment")
    .eq("user_id", userID);
  if (error) throw error;
  return data ?? [];
}

function threadIdFor(record: NotificationPayload["record"]): string {
  if (record.kind === "price_alert") {
    const rid = record.payload?.["record_id"];
    if (typeof rid === "string") return rid;
  }
  if (record.kind === "collection_invite") {
    const cid = record.payload?.["collection_id"];
    if (typeof cid === "string") return `collection:${cid}`;
  }
  return record.id;
}

async function sendOne(token: DeviceToken, payload: unknown) {
  const host = token.environment === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
  const jwt = await apnsAuthToken();
  const res = await fetch(`${host}/3/device/${token.apns_token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    console.error("APNs send failed", token.apns_token, res.status, await res.text());
  }
}

serve(async (req) => {
  try {
    const payload = (await req.json()) as NotificationPayload;
    if (payload.type !== "INSERT") {
      return new Response("skip", { status: 200 });
    }
    const row = payload.record;

    const tokens = await deviceTokensForUser(row.user_id);
    if (tokens.length === 0) return new Response("no devices", { status: 200 });

    const aps = {
      aps: {
        alert: { title: row.title, body: row.body },
        sound: "default",
        "thread-id": threadIdFor(row),
        "interruption-level": "active",
      },
      notification_id: row.id,
      kind: row.kind,
      ...row.payload,
    };

    await Promise.all(tokens.map((t) => sendOne(t, aps)));
    return new Response("sent", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response(String(e), { status: 500 });
  }
});
