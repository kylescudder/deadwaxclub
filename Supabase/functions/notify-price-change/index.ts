// Supabase Edge Function: notify-price-change
//
// Triggered by a Database Webhook on `price_entries` (INSERT). When the
// inserted row's `is_new_low` is true, fan out an APNs push to every
// device token belonging to the record's owner + every list member
// of any list containing that record.
//
// Required Edge Function secrets (Settings -> Edge Functions -> Secrets):
//   SUPABASE_SERVICE_ROLE_KEY    Supabase service-role key (already injected)
//   SUPABASE_URL                 Project URL (already injected)
//   APNS_TEAM_ID                 Apple Developer team ID
//   APNS_KEY_ID                  Key ID of the APNs auth key
//   APNS_PRIVATE_KEY             Contents of the AuthKey_XXXX.p8 file
//   APNS_BUNDLE_ID               e.g. com.trackd.app
//
// Configure the webhook in Supabase Studio:
//   Database -> Webhooks -> Create
//     Table:    price_entries
//     Events:   Insert
//     URL:      https://<project>.supabase.co/functions/v1/notify-price-change
//     Method:   POST
//     Header:   Authorization: Bearer <SUPABASE_ANON_KEY>

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { create as createJWT, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

interface PriceEntryPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  record: {
    id: string;
    record_id: string;
    owner_id: string;
    price_cents: number;
    currency: string;
    shop_name: string | null;
    is_new_low: boolean;
    previous_min_cents: number | null;
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
  cachedJWT = { token, expires: Date.now() + 50 * 60 * 1000 }; // 50 min
  return token;
}

interface DeviceToken {
  apns_token: string;
  environment: "sandbox" | "production";
}

async function audienceUserIds(recordID: string): Promise<string[]> {
  const { data, error } = await supabase.rpc("notification_audience_for_record", { rid: recordID });
  if (error) throw error;
  return (data ?? []).map((r: { user_id: string }) => r.user_id);
}

async function deviceTokensForUsers(userIDs: string[]): Promise<DeviceToken[]> {
  if (userIDs.length === 0) return [];
  const { data, error } = await supabase
    .from("device_tokens")
    .select("apns_token, environment")
    .in("user_id", userIDs);
  if (error) throw error;
  return data ?? [];
}

async function recordSummary(recordID: string) {
  const { data, error } = await supabase
    .from("records")
    .select("title, artist")
    .eq("id", recordID)
    .single();
  if (error) throw error;
  return data as { title: string; artist: string };
}

function priceLabel(cents: number, currency: string): string {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency }).format(cents / 100);
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
    const payload = (await req.json()) as PriceEntryPayload;
    if (payload.type !== "INSERT" || !payload.record.is_new_low) {
      return new Response("skip", { status: 200 });
    }

    const { record_id, price_cents, currency, shop_name, previous_min_cents } = payload.record;
    const [audience, summary] = await Promise.all([
      audienceUserIds(record_id),
      recordSummary(record_id),
    ]);
    const tokens = await deviceTokensForUsers(audience);
    if (tokens.length === 0) return new Response("no devices", { status: 200 });

    const wasFirst = previous_min_cents == null;
    const body = wasFirst
      ? `First price logged: ${priceLabel(price_cents, currency)}${shop_name ? ` at ${shop_name}` : ""}`
      : `New low: ${priceLabel(price_cents, currency)} (was ${priceLabel(previous_min_cents!, currency)})${shop_name ? ` at ${shop_name}` : ""}`;

    const aps = {
      aps: {
        alert: { title: `${summary.title} — ${summary.artist}`, body },
        sound: "default",
        "thread-id": record_id,
        "interruption-level": "active",
      },
      record_id,
    };

    await Promise.all(tokens.map((t) => sendOne(t, aps)));
    return new Response("sent", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response(String(e), { status: 500 });
  }
});
