-- Pembukuan Perusahaan - skema sinkronisasi (Supabase)
-- Jalankan SEKALI: Supabase > SQL Editor > New query > tempel semua > Run.
-- Aman dijalankan ulang; data yang sudah ada tidak dihapus.

-- ---------- Tabel ----------
create table if not exists public.perusahaan (
  id uuid primary key default gen_random_uuid(),
  nama text not null check (char_length(nama) between 1 and 200),
  dibuat timestamptz not null default now()
);

create table if not exists public.undangan (
  perusahaan_id uuid primary key references public.perusahaan(id) on delete cascade,
  kode text not null unique
);

create table if not exists public.anggota (
  perusahaan_id uuid not null references public.perusahaan(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null,
  peran text not null check (peran in ('pemilik', 'editor', 'pelihat')),
  bergabung timestamptz not null default now(),
  primary key (perusahaan_id, user_id)
);

create table if not exists public.dokumen (
  perusahaan_id uuid not null references public.perusahaan(id) on delete cascade,
  id text not null check (id = 'config' or id ~ '^[0-9]{4}-[0-9]{2}$'),
  data jsonb not null check (octet_length(data::text) <= 3000000),
  versi integer not null default 1,
  diubah timestamptz not null default now(),
  diubah_oleh uuid,
  primary key (perusahaan_id, id)
);

-- ---------- Fungsi bantu ----------
create or replace function public.peran_saya(p uuid)
returns text language sql stable security definer set search_path = public as $$
  select peran from public.anggota where perusahaan_id = p and user_id = auth.uid()
$$;

create or replace function public.kode_baru()
returns text language sql volatile set search_path = public as $$
  select upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))
$$;

-- versi naik otomatis tiap perubahan; klien tidak bisa menentukannya sendiri
create or replace function public.dokumen_versi()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.versi := 1;
  else
    new.versi := old.versi + 1;
    new.perusahaan_id := old.perusahaan_id;
    new.id := old.id;
  end if;
  new.diubah := now();
  new.diubah_oleh := auth.uid();
  return new;
end $$;

drop trigger if exists dokumen_versi on public.dokumen;
create trigger dokumen_versi before insert or update on public.dokumen
  for each row execute function public.dokumen_versi();

-- ---------- Fungsi yang dipanggil aplikasi ----------
create or replace function public.buat_perusahaan(p_nama text)
returns uuid language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  if auth.uid() is null then raise exception 'Anda belum masuk.'; end if;
  if coalesce(trim(p_nama), '') = '' then raise exception 'Nama perusahaan wajib diisi.'; end if;
  insert into public.perusahaan(nama) values (left(trim(p_nama), 200)) returning id into pid;
  insert into public.anggota(perusahaan_id, user_id, email, peran)
    values (pid, auth.uid(), coalesce(auth.jwt() ->> 'email', ''), 'pemilik');
  insert into public.undangan(perusahaan_id, kode) values (pid, public.kode_baru());
  return pid;
end $$;

create or replace function public.gabung_perusahaan(p_kode text)
returns uuid language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  if auth.uid() is null then raise exception 'Anda belum masuk.'; end if;
  select perusahaan_id into pid from public.undangan where kode = upper(trim(p_kode));
  if pid is null then raise exception 'Kode undangan tidak dikenal atau sudah diganti pemilik.'; end if;
  insert into public.anggota(perusahaan_id, user_id, email, peran)
    values (pid, auth.uid(), coalesce(auth.jwt() ->> 'email', ''), 'editor')
    on conflict (perusahaan_id, user_id) do nothing;
  return pid;
end $$;

create or replace function public.perusahaan_saya()
returns table(id uuid, nama text, peran text) language sql stable security definer set search_path = public as $$
  select p.id, p.nama, a.peran
  from public.perusahaan p join public.anggota a on a.perusahaan_id = p.id
  where a.user_id = auth.uid()
  order by a.bergabung
$$;

create or replace function public.kode_undangan(p uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare k text;
begin
  if public.peran_saya(p) is distinct from 'pemilik' then raise exception 'Hanya pemilik yang bisa melihat kode undangan.'; end if;
  select kode into k from public.undangan where perusahaan_id = p;
  return k;
end $$;

create or replace function public.ganti_kode(p uuid)
returns text language plpgsql security definer set search_path = public as $$
declare k text := public.kode_baru();
begin
  if public.peran_saya(p) is distinct from 'pemilik' then raise exception 'Hanya pemilik yang bisa mengganti kode undangan.'; end if;
  update public.undangan set kode = k where perusahaan_id = p;
  return k;
end $$;

create or replace function public.daftar_anggota(p uuid)
returns table(user_id uuid, email text, peran text) language plpgsql stable security definer set search_path = public as $$
begin
  if public.peran_saya(p) is null then raise exception 'Anda bukan anggota perusahaan ini.'; end if;
  return query select a.user_id, a.email, a.peran from public.anggota a where a.perusahaan_id = p order by a.bergabung;
end $$;

create or replace function public.ubah_peran(p uuid, u uuid, r text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.peran_saya(p) is distinct from 'pemilik' then raise exception 'Hanya pemilik yang bisa mengubah peran.'; end if;
  if r not in ('editor', 'pelihat') then raise exception 'Peran tidak dikenal.'; end if;
  if u = auth.uid() then raise exception 'Peran pemilik tidak bisa diubah.'; end if;
  update public.anggota set peran = r where perusahaan_id = p and user_id = u;
end $$;

create or replace function public.keluarkan(p uuid, u uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me text := public.peran_saya(p);
begin
  if me is null then raise exception 'Anda bukan anggota perusahaan ini.'; end if;
  if u = auth.uid() then
    if me = 'pemilik' then raise exception 'Pemilik tidak bisa keluar. Hapus perusahaan bila tidak dipakai lagi.'; end if;
  elsif me <> 'pemilik' then
    raise exception 'Hanya pemilik yang bisa mengeluarkan anggota.';
  end if;
  delete from public.anggota where perusahaan_id = p and user_id = u;
end $$;

create or replace function public.hapus_perusahaan(p uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.peran_saya(p) is distinct from 'pemilik' then raise exception 'Hanya pemilik yang bisa menghapus perusahaan.'; end if;
  delete from public.perusahaan where id = p;
end $$;

-- ---------- Keamanan ----------
alter table public.perusahaan enable row level security;
alter table public.undangan enable row level security;
alter table public.anggota enable row level security;
alter table public.dokumen enable row level security;

drop policy if exists dokumen_baca on public.dokumen;
drop policy if exists dokumen_tambah on public.dokumen;
drop policy if exists dokumen_ubah on public.dokumen;
create policy dokumen_baca on public.dokumen for select to authenticated
  using (public.peran_saya(perusahaan_id) is not null);
create policy dokumen_tambah on public.dokumen for insert to authenticated
  with check (public.peran_saya(perusahaan_id) in ('pemilik', 'editor'));
create policy dokumen_ubah on public.dokumen for update to authenticated
  using (public.peran_saya(perusahaan_id) in ('pemilik', 'editor'))
  with check (public.peran_saya(perusahaan_id) in ('pemilik', 'editor'));

revoke all on public.perusahaan, public.undangan, public.anggota, public.dokumen from anon, authenticated;
grant select, insert, update on public.dokumen to authenticated;

revoke all on function
  public.peran_saya(uuid), public.kode_baru(), public.buat_perusahaan(text), public.gabung_perusahaan(text),
  public.perusahaan_saya(), public.kode_undangan(uuid), public.ganti_kode(uuid), public.daftar_anggota(uuid),
  public.ubah_peran(uuid, uuid, text), public.keluarkan(uuid, uuid), public.hapus_perusahaan(uuid)
  from public, anon, authenticated;
grant execute on function
  public.peran_saya(uuid), public.buat_perusahaan(text), public.gabung_perusahaan(text),
  public.perusahaan_saya(), public.kode_undangan(uuid), public.ganti_kode(uuid), public.daftar_anggota(uuid),
  public.ubah_peran(uuid, uuid, text), public.keluarkan(uuid, uuid), public.hapus_perusahaan(uuid)
  to authenticated;
