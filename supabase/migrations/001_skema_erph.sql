-- eRPH SKJB — skema pangkalan data Supabase
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------- rahsia (tidak didedahkan melalui API) ----------
create table private.app_secrets (nama text primary key, nilai text not null);

-- ---------- tetapan sekolah (satu baris) ----------
create table public.settings (
  id int primary key default 1 check (id = 1),
  nama_sekolah text not null default 'SK Jalan Bintang, Miri',
  mula_minggu1 date not null default '2026-01-12',
  deadline_offset int not null default -3,
  deadline_jam text not null default '23:59',
  sekat_lewat boolean not null default false,
  ai_model text not null default 'gemini-2.5-flash',
  ingatan_aktif boolean not null default true,
  ingatan_hari int not null default 2
);
insert into public.settings (id) values (1);

-- ---------- profil guru ----------
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  nama text not null,
  email text,
  jawatan text default 'Guru',
  peranan text not null default 'guru' check (peranan in ('guru','pentadbir')),
  tukar_kata_laluan boolean not null default false,
  aktif boolean not null default true,
  dicipta timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and peranan = 'pentadbir' and aktif);
$$;

create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, nama, email, peranan)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nama', new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
          lower(new.email),
          case when exists (select 1 from public.profiles) then 'guru' else 'pentadbir' end)
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- guru tidak boleh menukar peranan/status sendiri
create or replace function private.lindung_profil() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() and auth.uid() is not null then
    new.peranan := old.peranan; new.aktif := old.aktif; new.email := old.email;
  end if;
  return new;
end $$;
create trigger lindung_profil before update on public.profiles
  for each row execute function private.lindung_profil();

-- ---------- jadual waktu ----------
create table public.slots (
  id uuid primary key default gen_random_uuid(),
  uid uuid not null default auth.uid() references public.profiles on delete cascade,
  hari int not null check (hari between 1 and 5),
  mula text not null, tamat text not null,
  subjek text not null, kelas text not null
);
create index on public.slots (uid);

-- ---------- tarikh akhir khas ----------
create table public.tarikh_akhir (
  isnin date primary key,
  tarikh_akhir timestamptz not null,
  catatan text, oleh text,
  dikemaskini timestamptz not null default now()
);

create or replace function public.deadline_for(p_isnin date) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select t.tarikh_akhir from public.tarikh_akhir t where t.isnin = p_isnin),
    ((p_isnin + s.deadline_offset) + s.deadline_jam::time) at time zone 'Asia/Kuala_Lumpur')
  from public.settings s where s.id = 1;
$$;

-- ---------- RPH ----------
create table public.rph (
  id uuid primary key default gen_random_uuid(),
  uid uuid not null default auth.uid() references public.profiles on delete cascade,
  guru_nama text,
  tarikh date not null, isnin date not null, minggu int,
  mula text, tamat text, subjek text not null, kelas text not null,
  tema text, tajuk text, sk text, sp text, objektif text, kriteria text,
  induksi text, utama text, penutup text,
  bbm text, emk text, nilai text, pak21 text, kbat text, pbd text, strategi text,
  refleksi text, hadir text, jumlah text,
  ditangguhkan boolean not null default false, sebab text,
  status text not null default 'draf' check (status in ('draf','dihantar','pembetulan','disahkan')),
  log jsonb not null default '[]'::jsonb,
  dihantar_pada timestamptz, lewat boolean not null default false,
  disahkan_oleh text, disahkan_pada timestamptz,
  dicipta timestamptz not null default now(),
  dikemaskini timestamptz not null default now()
);
create index on public.rph (uid);
create index on public.rph (isnin);
create index on public.rph (status);

create or replace function private.rph_sebelum() returns trigger
language plpgsql security definer set search_path = '' as $$
declare adm boolean := public.is_admin(); dl timestamptz; s public.settings; r text; h text; j text;
begin
  select * into s from public.settings where id = 1;
  if tg_op = 'UPDATE' and not adm then
    if old.status = 'disahkan' then
      -- selepas disahkan, guru hanya boleh isi refleksi & kehadiran
      r := new.refleksi; h := new.hadir; j := new.jumlah;
      new := old; new.refleksi := r; new.hadir := h; new.jumlah := j; new.dikemaskini := now();
      return new;
    elsif new.status not in ('draf','dihantar') then
      raise exception 'Status tidak dibenarkan';
    end if;
  end if;
  if tg_op = 'INSERT' and not adm and new.status not in ('draf','dihantar') then
    raise exception 'Status tidak dibenarkan';
  end if;
  new.isnin := new.tarikh - (extract(isodow from new.tarikh)::int - 1);
  new.minggu := ((new.isnin - (s.mula_minggu1 - (extract(isodow from s.mula_minggu1)::int - 1))) / 7) + 1;
  new.dikemaskini := now();
  if new.status = 'dihantar' and (tg_op = 'INSERT' or old.status is distinct from 'dihantar') then
    dl := public.deadline_for(new.isnin);
    new.dihantar_pada := now();
    new.lewat := now() > dl;
    if new.lewat and s.sekat_lewat and not adm then
      raise exception 'Tarikh akhir (%) telah berlalu. Hubungi pentadbir untuk lanjutan.',
        to_char(dl at time zone 'Asia/Kuala_Lumpur', 'DD/MM/YYYY HH24:MI');
    end if;
  end if;
  return new;
end $$;
create trigger rph_sebelum before insert or update on public.rph
  for each row execute function private.rph_sebelum();

-- ---------- notifikasi ----------
create table public.notifikasi (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles on delete cascade,
  kunci text not null,
  tajuk text not null, mesej text, pautan text,
  dibaca boolean not null default false,
  dicipta timestamptz not null default now(),
  unique (user_id, kunci)
);
create index on public.notifikasi (user_id, dicipta desc);

create or replace function private.maklum(p_user uuid, p_kunci text, p_tajuk text, p_mesej text, p_pautan text)
returns void language sql security definer set search_path = '' as $$
  insert into public.notifikasi (user_id, kunci, tajuk, mesej, pautan)
  values (p_user, p_kunci, p_tajuk, p_mesej, p_pautan)
  on conflict (user_id, kunci) do update
    set tajuk = excluded.tajuk, mesej = excluded.mesej, pautan = excluded.pautan, dibaca = false, dicipta = now();
$$;

create or replace function private.rph_selepas() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a record; n int; last jsonb; hari text := to_char(now() at time zone 'Asia/Kuala_Lumpur', 'YYYY-MM-DD');
  lbl text := new.subjek || ' ' || new.kelas || ' (' || to_char(new.tarikh, 'DD/MM') || ')';
begin
  if new.status = 'dihantar' and (tg_op = 'INSERT' or old.status is distinct from 'dihantar') then
    select count(*) into n from public.rph where uid = new.uid and status = 'dihantar';
    for a in select id from public.profiles where peranan = 'pentadbir' and aktif and id <> new.uid loop
      perform private.maklum(a.id, 'semak:' || new.uid || ':' || hari, 'RPH menunggu semakan',
        coalesce(new.guru_nama, 'Guru') || ' telah menghantar RPH. ' || n || ' RPH menunggu semakan.', '#/semakan/' || new.isnin);
    end loop;
  end if;
  if tg_op = 'UPDATE' then
    if new.status = 'pembetulan' and old.status <> 'pembetulan' then
      last := new.log -> -1;
      perform private.maklum(new.uid, 'rph:' || new.id, 'RPH perlu pembetulan',
        lbl || ': ' || coalesce(last->>'teks', '') || ' — ' || coalesce(last->>'nama', ''), '#/edit/' || new.id);
    elsif new.status = 'disahkan' and old.status <> 'disahkan' then
      select count(*) into n from public.rph where uid = new.uid and status = 'disahkan'
        and disahkan_pada >= (date_trunc('day', now() at time zone 'Asia/Kuala_Lumpur') at time zone 'Asia/Kuala_Lumpur');
      perform private.maklum(new.uid, 'sah:' || hari, 'RPH disahkan ✅',
        n || ' RPH anda telah disahkan hari ini oleh ' || coalesce(new.disahkan_oleh, 'pentadbir') || '.', '#/rph/' || new.isnin);
    elsif jsonb_array_length(new.log) > jsonb_array_length(old.log) and (new.log -> -1 ->> 'tindakan') = 'ulasan' then
      last := new.log -> -1;
      perform private.maklum(new.uid, 'ulasan:' || new.id || ':' || jsonb_array_length(new.log), 'Ulasan baharu pada RPH',
        lbl || ': ' || coalesce(last->>'teks', '') || ' — ' || coalesce(last->>'nama', ''), '#/lihat/' || new.id);
    end if;
  end if;
  return null;
end $$;
create trigger rph_selepas after insert or update on public.rph
  for each row execute function private.rph_selepas();

-- ---------- langganan Web Push ----------
create table public.push_subs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles on delete cascade,
  endpoint text not null unique,
  sub jsonb not null,
  dicipta timestamptz not null default now()
);
create index on public.push_subs (user_id);

-- hantar push melalui Edge Function setiap kali notifikasi dicipta/dikemas kini
create or replace function private.notif_push() returns trigger
language plpgsql security definer set search_path = '' as $$
declare u text; k text;
begin
  if new.dibaca then return null; end if;
  select nilai into u from private.app_secrets where nama = 'push_url';
  select nilai into k from private.app_secrets where nama = 'push_secret';
  if u is null or not exists (select 1 from public.push_subs where user_id = new.user_id) then return null; end if;
  perform net.http_post(url := u, body := jsonb_build_object('id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', k));
  return null;
end $$;
create trigger notif_push after insert or update of dicipta on public.notifikasi
  for each row execute function private.notif_push();

-- ---------- peringatan harian (pg_cron) ----------
create or replace function private.jana_peringatan() returns int
language plpgsql security definer set search_path = '' as $$
declare s public.settings; w date; dl timestamptz; g record; slot_n int; sent_n int; bil int := 0;
  today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; mg int;
begin
  select * into s from public.settings where id = 1;
  foreach w in array array[today - (extract(isodow from today)::int - 1), today - (extract(isodow from today)::int - 1) + 7] loop
    dl := public.deadline_for(w);
    mg := ((w - (s.mula_minggu1 - (extract(isodow from s.mula_minggu1)::int - 1))) / 7) + 1;
    continue when now() < dl - make_interval(days => s.ingatan_hari);
    continue when now() > dl + interval '5 days';
    for g in select p.id, p.nama from public.profiles p where p.aktif loop
      select count(*) into slot_n from public.slots where uid = g.id;
      continue when slot_n = 0;
      select count(*) into sent_n from public.rph where uid = g.id and isnin = w and status <> 'draf';
      continue when sent_n >= slot_n;
      perform private.maklum(g.id, 'ingat:' || w || ':' || today,
        case when now() > dl then '⚠️ RPH Minggu ' || mg || ' lewat' else '⏰ Peringatan hantar RPH Minggu ' || mg end,
        'Tarikh akhir: ' || to_char(dl at time zone 'Asia/Kuala_Lumpur', 'DD/MM/YYYY HH24:MI') ||
        '. Anda telah menghantar ' || sent_n || ' daripada ' || slot_n || ' RPH. Gunakan "Jana RPH Sehari" untuk bina dengan pantas.',
        '#/rph/' || w);
      bil := bil + 1;
    end loop;
  end loop;
  return bil;
end $$;

create or replace function private.cron_peringatan() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select ingatan_aktif from public.settings where id = 1) then perform private.jana_peringatan(); end if;
end $$;
-- 7.00 pagi dan 8.00 malam waktu Malaysia
select cron.schedule('erph-peringatan-pagi', '0 23 * * *', 'select private.cron_peringatan()');
select cron.schedule('erph-peringatan-malam', '0 12 * * *', 'select private.cron_peringatan()');

-- ---------- RPC untuk pentadbir ----------
create or replace function public.hantar_peringatan_sekarang() returns int
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Hanya pentadbir'; end if;
  return private.jana_peringatan();
end $$;

create or replace function public.hantar_hebahan(p_tajuk text, p_mesej text) returns int
language plpgsql security definer set search_path = '' as $$
declare g record; n int := 0; k text := 'hebahan:' || extract(epoch from now())::bigint;
begin
  if not public.is_admin() then raise exception 'Hanya pentadbir'; end if;
  for g in select id from public.profiles where aktif loop
    perform private.maklum(g.id, k, p_tajuk, p_mesej, '#/utama'); n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.ingatkan_guru(p_uid uuid, p_mesej text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Hanya pentadbir'; end if;
  perform private.maklum(p_uid, 'ingat-manual:' || extract(epoch from now())::bigint, '📣 Peringatan daripada pentadbir', p_mesej, '#/rph');
end $$;

create or replace function public.admin_cipta_guru(p_email text, p_nama text, p_jawatan text, p_kata_laluan text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := gen_random_uuid(); e text := lower(trim(p_email));
begin
  if not public.is_admin() then raise exception 'Hanya pentadbir'; end if;
  if length(p_kata_laluan) < 6 then raise exception 'Kata laluan sekurang-kurangnya 6 aksara'; end if;
  if exists (select 1 from auth.users where email = e) then raise exception 'E-mel % sudah didaftarkan', e; end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', e,
    extensions.crypt(p_kata_laluan, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('nama', p_nama), now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', e, 'email_verified', true), 'email', now(), now(), now());
  update public.profiles set nama = p_nama, jawatan = coalesce(nullif(p_jawatan, ''), 'Guru'), tukar_kata_laluan = true where id = uid;
  return uid;
end $$;

create or replace function public.admin_set_kata_laluan(p_uid uuid, p_kata_laluan text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Hanya pentadbir'; end if;
  if length(p_kata_laluan) < 6 then raise exception 'Kata laluan sekurang-kurangnya 6 aksara'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_kata_laluan, extensions.gen_salt('bf')), updated_at = now() where id = p_uid;
  update public.profiles set tukar_kata_laluan = true where id = p_uid;
end $$;

-- kunci AI disimpan dalam skema private
create or replace function public.tetap_kunci_ai(p_kunci text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Hanya pentadbir'; end if;
  if coalesce(trim(p_kunci), '') = '' then delete from private.app_secrets where nama = 'gemini_key';
  else insert into private.app_secrets values ('gemini_key', trim(p_kunci)) on conflict (nama) do update set nilai = excluded.nilai; end if;
end $$;

create or replace function public.status_ai() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.app_secrets where nama = 'gemini_key');
$$;

create or replace function public.rahsia_pelayan(p_nama text) returns text
language sql stable security definer set search_path = '' as $$
  select nilai from private.app_secrets where nama = p_nama;
$$;

revoke execute on function public.rahsia_pelayan(text) from public, anon, authenticated;
grant execute on function public.rahsia_pelayan(text) to service_role;
revoke execute on function public.admin_cipta_guru(text,text,text,text), public.admin_set_kata_laluan(uuid,text),
  public.tetap_kunci_ai(text), public.hantar_hebahan(text,text), public.hantar_peringatan_sekarang(),
  public.ingatkan_guru(uuid,text), public.status_ai(), public.deadline_for(date), public.is_admin() from public, anon;
grant execute on function public.admin_cipta_guru(text,text,text,text), public.admin_set_kata_laluan(uuid,text),
  public.tetap_kunci_ai(text), public.hantar_hebahan(text,text), public.hantar_peringatan_sekarang(),
  public.ingatkan_guru(uuid,text), public.status_ai(), public.deadline_for(date), public.is_admin() to authenticated;

-- ---------- Row Level Security ----------
alter table public.settings enable row level security;
alter table public.profiles enable row level security;
alter table public.slots enable row level security;
alter table public.tarikh_akhir enable row level security;
alter table public.rph enable row level security;
alter table public.notifikasi enable row level security;
alter table public.push_subs enable row level security;
alter table private.app_secrets enable row level security;

create policy settings_baca on public.settings for select to authenticated using (true);
create policy settings_admin on public.settings for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

create policy profil_baca on public.profiles for select to authenticated using (true);
create policy profil_kemas on public.profiles for update to authenticated
  using (id = (select auth.uid()) or (select public.is_admin())) with check (id = (select auth.uid()) or (select public.is_admin()));
create policy profil_padam on public.profiles for delete to authenticated using ((select public.is_admin()));

create policy slot_baca on public.slots for select to authenticated using (uid = (select auth.uid()) or (select public.is_admin()));
create policy slot_tambah on public.slots for insert to authenticated with check (uid = (select auth.uid()));
create policy slot_kemas on public.slots for update to authenticated using (uid = (select auth.uid()) or (select public.is_admin()));
create policy slot_padam on public.slots for delete to authenticated using (uid = (select auth.uid()) or (select public.is_admin()));

create policy ta_baca on public.tarikh_akhir for select to authenticated using (true);
create policy ta_tambah on public.tarikh_akhir for insert to authenticated with check ((select public.is_admin()));
create policy ta_kemas on public.tarikh_akhir for update to authenticated using ((select public.is_admin()));
create policy ta_padam on public.tarikh_akhir for delete to authenticated using ((select public.is_admin()));

create policy rph_baca on public.rph for select to authenticated using (uid = (select auth.uid()) or (select public.is_admin()));
create policy rph_tambah on public.rph for insert to authenticated with check (uid = (select auth.uid()));
create policy rph_kemas on public.rph for update to authenticated
  using (uid = (select auth.uid()) or (select public.is_admin())) with check (uid = (select auth.uid()) or (select public.is_admin()));
create policy rph_padam on public.rph for delete to authenticated
  using ((uid = (select auth.uid()) and status = 'draf') or (select public.is_admin()));

create policy notif_baca on public.notifikasi for select to authenticated using (user_id = (select auth.uid()));
create policy notif_kemas on public.notifikasi for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy notif_padam on public.notifikasi for delete to authenticated using (user_id = (select auth.uid()));

create policy push_milik on public.push_subs for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

alter publication supabase_realtime add table public.notifikasi;
