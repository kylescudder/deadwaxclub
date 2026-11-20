-- RLS continues to restrict deletion to the authenticated owner.
grant delete on public.device_tokens to authenticated;
