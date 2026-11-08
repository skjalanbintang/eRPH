alter table public.profiles add column if not exists nama_asc text;
alter table public.settings add column if not exists peta_subjek jsonb not null default '{}'::jsonb;
alter table public.slots add column if not exists sumber text not null default 'manual';

create or replace function public.admin_ganti_slot(p_uid uuid, p_slots jsonb, p_nama_asc text) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not public.is_admin() then raise exception 'Hanya pentadbir'; end if;
  delete from public.slots where uid = p_uid;
  insert into public.slots (uid, hari, mula, tamat, subjek, kelas, sumber)
  select p_uid, x.hari, x.mula, x.tamat, x.subjek, x.kelas, 'asc'
  from jsonb_to_recordset(p_slots) as x(hari int, mula text, tamat text, subjek text, kelas text)
  where x.hari between 1 and 5;
  get diagnostics n = row_count;
  update public.profiles set nama_asc = p_nama_asc where id = p_uid;
  return n;
end $$;
revoke execute on function public.admin_ganti_slot(uuid, jsonb, text) from public, anon;
grant execute on function public.admin_ganti_slot(uuid, jsonb, text) to authenticated;
