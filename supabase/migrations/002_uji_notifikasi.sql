create or replace function public.uji_notifikasi() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sila log masuk'; end if;
  perform private.maklum(auth.uid(), 'uji:' || extract(epoch from now())::bigint, '🔔 Notifikasi ujian',
    'Tahniah! Notifikasi eRPH berfungsi pada peranti ini.', '#/utama');
end $$;
revoke execute on function public.uji_notifikasi() from public, anon;
grant execute on function public.uji_notifikasi() to authenticated;
-- Nota: rahsia (vapid_public, vapid_private, push_secret, push_url, gemini_key) disimpan
-- dalam private.app_secrets secara terus di pangkalan data dan TIDAK disimpan dalam repo.
