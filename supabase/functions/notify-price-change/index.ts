// Supabase Edge Function: notify-price-change
//
// Triggered by a Database Webhook on `price_entries` (INSERT). When the
// inserted row's `is_new_low` is true, look up the audience for the record
// (every member of the record's collection + every member of any list
// containing it) and INSERT one row per user into `public.notifications`.
//
// The `notify-inbox` function then picks up those inserts via its own webhook
// and fans the actual APNs pushes — keeping push delivery and inbox writes
// in lock-step from a single source of truth.
//
// Required Edge Function secrets:
//   SUPABASE_SERVICE_ROLE_KEY    Supabase service-role key (already injected)
//   SUPABASE_URL                 Project URL (already injected)
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

interface PriceEntryPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  record: {
    id: string;
    record_id: string;
    price_cents: number;
    currency: string;
    shop_name: string | null;
    is_new_low: boolean;
    previous_min_cents: number | null;
  };
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);

async function audienceUserIds(recordID: string): Promise<string[]> {
  const { data, error } = await supabase.rpc("notification_audience_for_record", { rid: recordID });
  if (error) throw error;
  return (data ?? []).map((r: { user_id: string }) => r.user_id);
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
    if (audience.length === 0) return new Response("no audience", { status: 200 });

    const wasFirst = previous_min_cents == null;
    const body = wasFirst
      ? `First price logged: ${priceLabel(price_cents, currency)}${shop_name ? ` at ${shop_name}` : ""}`
      : `New low: ${priceLabel(price_cents, currency)} (was ${priceLabel(previous_min_cents!, currency)})${shop_name ? ` at ${shop_name}` : ""}`;
    const title = `${summary.title} — ${summary.artist}`;

    const rows = audience.map((user_id) => ({
      user_id,
      kind: "price_alert",
      title,
      body,
      payload: {
        record_id,
        price_cents,
        currency,
        shop_name,
        previous_min_cents,
      },
    }));

    const { error } = await supabase.from("notifications").insert(rows);
    if (error) throw error;

    return new Response(`enqueued ${rows.length}`, { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response(String(e), { status: 500 });
  }
});
