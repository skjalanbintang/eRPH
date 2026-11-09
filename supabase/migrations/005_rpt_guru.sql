-- RPT guru (Rancangan Pengajaran Tahunan) + catatan penangguhan selepas disahkan
create table if not exists public.rpt (
  id uuid primary key default gen_random_uuid(),
  uid uuid not null default auth.uid() references public.profiles on delete cascade,
  subjek text not null,
  tahun text not null,
  nama_fail text,
  baris jsonb not null default '[]'::jsonb,   -- [{minggu, tema, tajuk, sk, sp}]
  dicipta timestamptz not null default now(),
  dikemaskini timestamptz not null default now()
);
create index if not exists rpt_uid_idx on public.rpt (uid);
alter table public.rpt enable row level security;
create policy rpt_baca on public.rpt for select to authenticated using (uid = (select auth.uid()) or (select public.is_admin()));
create policy rpt_tambah on public.rpt for insert to authenticated with check (uid = (select auth.uid()));
create policy rpt_kemas on public.rpt for update to authenticated using (uid = (select auth.uid())) with check (uid = (select auth.uid()));
create policy rpt_padam on public.rpt for delete to authenticated using (uid = (select auth.uid()) or (select public.is_admin()));
-- private.rph_sebelum dikemas kini: selepas disahkan guru boleh ubah refleksi, hadir, jumlah, ditangguhkan, sebab.
-- Model AI lalai: gemini-3.8-flash
alter table public.settings alter column ai_model set default 'gemini-3.8-flash';
