-- Log masuk Google: akaun Google baharu (tidak didaftarkan pentadbir) menunggu kelulusan
alter table public.profiles add column if not exists menunggu boolean not null default false;

create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare pertama boolean := not exists (select 1 from public.profiles);
  oauth boolean := coalesce(new.raw_app_meta_data->>'provider', 'email') <> 'email';
  nm text := coalesce(new.raw_user_meta_data->>'nama', new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(new.email,'@',1));
  a record;
begin
  insert into public.profiles (id, nama, email, peranan, aktif, menunggu)
  values (new.id, nm, lower(new.email),
          case when pertama then 'pentadbir' else 'guru' end,
          pertama or not oauth, (not pertama) and oauth)
  on conflict (id) do nothing;
  if (not pertama) and oauth then
    for a in select id from public.profiles where peranan = 'pentadbir' and aktif loop
      perform private.maklum(a.id, 'mohon:' || new.id, '🙋 Permohonan akaun baharu',
        nm || ' (' || lower(new.email) || ') log masuk dengan Google dan menunggu kelulusan.', '#/guru');
    end loop;
  end if;
  return new;
end $$;

create or replace function private.lindung_profil() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() and auth.uid() is not null then
    new.peranan := old.peranan; new.aktif := old.aktif; new.email := old.email; new.menunggu := old.menunggu;
  end if;
  return new;
end $$;
