-- =====================================================================
-- DAILY TASK PRODUKSI · JOYBOX — database Supabase
-- Cara pakai: Supabase → SQL Editor → New query → tempel seluruh file ini → Run.
-- Aman dijalankan ulang: data yang sudah ada tidak ditimpa.
-- Semua akses dari web lewat satu fungsi public.api(); tabel tidak bisa dibaca langsung.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists dt;

create table if not exists dt.users (
  id text primary key, nama text not null, username text unique not null, role text not null default 'karyawan',
  pw_hash text not null, pw_default boolean not null default true, aktif boolean not null default true,
  created_at timestamptz not null default now());
create table if not exists dt.sessions (
  token text primary key, user_id text not null references dt.users(id) on delete cascade, expires_at timestamptz not null);
create table if not exists dt.entries (
  key text primary key, date text not null, user_id text not null, status text not null default 'draft',
  plan_at timestamptz, real_at timestamptz, items jsonb not null default '[]'::jsonb, updated_at timestamptz not null default now());
create index if not exists entries_date_idx on dt.entries(date);
create table if not exists dt.products (
  id text primary key, nama text not null, sku text not null, std text, mult int not null default 1,
  asm boolean not null default false, aktif boolean not null default true, ord int not null default 0);
create table if not exists dt.standards (
  id text primary key, nama text not null, catatan text not null default '', komponen jsonb not null default '[]'::jsonb, ord int not null default 0);
create table if not exists dt.settings (key text primary key, value jsonb not null);
create table if not exists dt.photos (
  id text primary key, user_id text, data text not null, created_at timestamptz not null default now());
create index if not exists photos_created_idx on dt.photos(created_at);

alter table dt.users enable row level security;
alter table dt.sessions enable row level security;
alter table dt.entries enable row level security;
alter table dt.products enable row level security;
alter table dt.standards enable row level security;
alter table dt.settings enable row level security;
alter table dt.photos enable row level security;

-- ---------------------------------------------------------------- helpers
create or replace function dt.err(msg text, code text) returns void language plpgsql as $$
begin raise exception using message = msg, hint = code; end $$;

create or replace function dt.pub(u dt.users) returns jsonb language sql stable as $$
  select jsonb_build_object('id', u.id, 'nama', u.nama, 'username', u.username, 'role', u.role,
    'pwDefault', u.pw_default, 'aktif', u.aktif, 'createdAt', u.created_at) $$;

create or replace function dt.entry_json(e dt.entries) returns jsonb language sql stable as $$
  select jsonb_build_object('date', e.date, 'userId', e.user_id, 'status', e.status,
    'planAt', e.plan_at, 'realAt', e.real_at, 'items', e.items) $$;

create or replace function dt.first_name(n text) returns text language sql immutable as $$
  select upper(left(f, 1)) || substr(f, 2) from (select split_part(trim(coalesce(n, '')), ' ', 1) as f) x $$;

create or replace function dt.settings_json() returns jsonb language sql stable as $$
  select '{"efektivitas":80,"istirahatMenit":60,"jamNormal":8,"pwSuffix":"1234","fotoHari":90}'::jsonb
    || coalesce((select value from dt.settings where key = 'main'), '{}'::jsonb) $$;

create or replace function dt.default_pw(nama text) returns text language sql stable as $$
  select dt.first_name(nama) || coalesce(dt.settings_json()->>'pwSuffix', '1234') $$;

create or replace function dt.hash_pw(pw text) returns text language sql volatile
  set search_path = extensions, dt, public as $$ select crypt(pw, gen_salt('bf', 8)) $$;

create or replace function dt.new_token(uid text) returns text language plpgsql volatile
  set search_path = extensions, dt, public as $$
declare t text := encode(gen_random_bytes(24), 'hex');
begin
  delete from dt.sessions where expires_at < now();
  insert into dt.sessions(token, user_id, expires_at) values (t, uid, now() + interval '12 hours');
  return t;
end $$;

create or replace function dt.is_extra(i jsonb) returns boolean language sql immutable as $$
  select coalesce((i->>'extra')::boolean, false) $$;

-- ---------------------------------------------------------------- API
create or replace function public.api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dt, extensions, public as $$
declare
  me dt.users; u dt.users; cur dt.entries; e dt.entries;
  has_cur boolean; v jsonb; v_items jsonb; v_status text; was text; k text; uid text;
  v_plan timestamptz; v_real timestamptz; t text; pw text; base text; un text; n int;
  v_msg text; v_hint text;
  rank constant jsonb := '{"draft":0,"plan":1,"done":2}';
begin
  payload := coalesce(payload, '{}'::jsonb);

  if action = 'ping' then return jsonb_build_object('ok', true, 'data', 'ok'); end if;

  if action = 'login' then
    select * into me from dt.users x where x.username = lower(trim(coalesce(payload->>'username', ''))) and x.aktif;
    if not found or me.pw_hash <> crypt(coalesce(payload->>'password', ''), me.pw_hash) then
      perform pg_sleep(0.4); perform dt.err('Username atau password salah.', 'login');
    end if;
    return jsonb_build_object('ok', true, 'data', jsonb_build_object('token', dt.new_token(me.id), 'me', dt.pub(me)));
  end if;

  select x.* into me from dt.sessions s join dt.users x on x.id = s.user_id
   where s.token = payload->>'token' and s.expires_at > now() and x.aktif;
  if not found then perform dt.err('Sesi berakhir, silakan login lagi.', 'auth'); end if;

  if action in ('addUser', 'resetPassword', 'setActive', 'saveProducts', 'saveStandards', 'saveSettings', 'unlock') and me.role <> 'spv' then
    perform dt.err('Hanya untuk supervisor.', 'forbidden');
  end if;

  if action = 'bootstrap' then
    v := jsonb_build_object(
      'me', dt.pub(me),
      'settings', dt.settings_json(),
      'standards', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'nama', s.nama, 'catatan', s.catatan, 'komponen', s.komponen) order by s.ord) from dt.standards s), '[]'::jsonb),
      'products', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nama', p.nama, 'sku', p.sku, 'std', p.std, 'mult', p.mult, 'asm', p.asm, 'aktif', p.aktif) order by p.ord) from dt.products p), '[]'::jsonb),
      'users', case when me.role = 'spv' then (select jsonb_agg(dt.pub(x) order by x.created_at, x.id) from dt.users x) else jsonb_build_array(dt.pub(me)) end,
      'sheetUrl', null);

  elsif action = 'changePassword' then
    if me.pw_hash <> crypt(coalesce(payload->>'old', ''), me.pw_hash) then perform dt.err('Password sekarang salah.', 'bad_password'); end if;
    if length(coalesce(payload->>'new', '')) < 6 then perform dt.err('Password baru minimal 6 karakter.', 'bad_password'); end if;
    update dt.users set pw_hash = dt.hash_pw(payload->>'new'), pw_default = false where id = me.id returning * into me;
    delete from dt.sessions where user_id = me.id;
    v := jsonb_build_object('token', dt.new_token(me.id), 'me', dt.pub(me));

  elsif action = 'getEntry' then
    uid := case when me.role = 'spv' and coalesce(payload->>'userId', '') <> '' then payload->>'userId' else me.id end;
    select * into e from dt.entries where key = (payload->>'date') || '_' || uid;
    v := case when found then dt.entry_json(e) else 'null'::jsonb end;

  elsif action = 'entries' then
    uid := case when me.role = 'spv' then nullif(payload->>'userId', '') else me.id end;
    v := coalesce((select jsonb_agg(dt.entry_json(x) order by x.date, x.user_id) from dt.entries x
      where x.date >= coalesce(payload->>'from', '') and x.date <= coalesce(payload->>'to', '') and (uid is null or x.user_id = uid)), '[]'::jsonb);

  elsif action = 'saveEntry' then
    v := payload->'entry';
    if v is null or coalesce(v->>'date', '') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(v->>'userId', '') = ''
       or coalesce(v->>'status', '') not in ('draft', 'plan', 'done') or jsonb_typeof(v->'items') <> 'array' then
      perform dt.err('Data tidak valid.', 'bad_request');
    end if;
    if me.role <> 'spv' and v->>'userId' <> me.id then perform dt.err('Tidak boleh mengubah data orang lain.', 'forbidden'); end if;
    k := (v->>'date') || '_' || (v->>'userId');
    v_items := v->'items'; v_status := v->>'status';
    select * into cur from dt.entries where key = k for update;
    has_cur := found;
    was := case when has_cur then cur.status else 'draft' end;
    if has_cur and me.role <> 'spv' then
      if cur.status = 'done' or (rank->>v_status)::int < (rank->>cur.status)::int then
        perform dt.err('Data ini sudah dikirim dan terkunci.', 'locked');
      end if;
      if cur.status = 'plan' then
        -- qty rencana tidak boleh berubah setelah rencana dikirim
        v_items := coalesce((
          select jsonb_agg(case when dt.is_extra(i) then i || '{"qty":0}'::jsonb
                                else i || jsonb_build_object('qty', (select c->'qty' from jsonb_array_elements(cur.items) c
                                                                     where c->>'pid' = i->>'pid' and not dt.is_extra(c) limit 1)) end
                           order by o)
          from jsonb_array_elements(v_items) with ordinality t(i, o)
          where dt.is_extra(i) or exists (select 1 from jsonb_array_elements(cur.items) c where c->>'pid' = i->>'pid' and not dt.is_extra(c))
        ), '[]'::jsonb);
        v_items := v_items || coalesce((
          select jsonb_agg(c) from jsonb_array_elements(cur.items) c
          where not dt.is_extra(c) and not exists (select 1 from jsonb_array_elements(v_items) i where i->>'pid' = c->>'pid' and not dt.is_extra(i))
        ), '[]'::jsonb);
      end if;
    end if;
    v_plan := case when v_status = 'draft' then null when was = 'draft' then now() else coalesce(cur.plan_at, now()) end;
    v_real := case when v_status = 'done' then (case when was = 'done' then coalesce(cur.real_at, now()) else now() end) else null end;
    insert into dt.entries(key, date, user_id, status, plan_at, real_at, items, updated_at)
      values (k, v->>'date', v->>'userId', v_status, v_plan, v_real, v_items, now())
      on conflict (key) do update set status = excluded.status, plan_at = excluded.plan_at, real_at = excluded.real_at,
        items = excluded.items, updated_at = now()
      returning * into e;
    v := dt.entry_json(e);

  elsif action = 'unlock' then
    if coalesce(payload->>'to', '') not in ('draft', 'plan') then perform dt.err('Status tidak valid.', 'bad_request'); end if;
    update dt.entries set status = payload->>'to', real_at = null,
      plan_at = case when payload->>'to' = 'draft' then null else plan_at end, updated_at = now()
     where key = (payload->>'date') || '_' || (payload->>'userId') returning * into e;
    if not found then perform dt.err('Data tidak ditemukan.', 'not_found'); end if;
    v := dt.entry_json(e);

  elsif action = 'uploadPhoto' then
    t := coalesce(payload->>'data', '');
    if t !~ '^data:image/(jpeg|png|webp);base64,' then perform dt.err('Format foto tidak valid.', 'bad_request'); end if;
    if length(t) > 1500000 then perform dt.err('Foto terlalu besar.', 'too_large'); end if;
    delete from dt.photos where created_at < now() - make_interval(days => greatest(7, coalesce((dt.settings_json()->>'fotoHari')::int, 90)));
    k := encode(gen_random_bytes(12), 'hex');
    insert into dt.photos(id, user_id, data) values (k, me.id, t);
    v := to_jsonb(k);

  elsif action = 'photo' then
    select to_jsonb(p.data) into v from dt.photos p where p.id = payload->>'id';
    if v is null then perform dt.err('Foto tidak ditemukan.', 'not_found'); end if;

  elsif action = 'deletePhoto' then
    delete from dt.photos p where p.id = payload->>'id' and (me.role = 'spv' or p.user_id = me.id);
    v := 'true'::jsonb;

  elsif action = 'addUser' then
    if coalesce(trim(payload->>'nama'), '') = '' then perform dt.err('Nama wajib diisi.', 'bad_request'); end if;
    base := regexp_replace(lower(coalesce(nullif(trim(payload->>'username'), ''), dt.first_name(payload->>'nama'))), '[^a-z0-9._]', '', 'g');
    if base = '' then base := 'user'; end if;
    if coalesce(trim(payload->>'username'), '') <> '' and exists (select 1 from dt.users where username = base) then
      perform dt.err('Username sudah dipakai.', 'taken');
    end if;
    un := base; n := 2;
    while exists (select 1 from dt.users where username = un) loop un := base || n; n := n + 1; end loop;
    pw := dt.default_pw(payload->>'nama');
    insert into dt.users(id, nama, username, role, pw_hash)
      values ('u_' || encode(gen_random_bytes(5), 'hex'), trim(payload->>'nama'), un,
              case when payload->>'role' = 'spv' then 'spv' else 'karyawan' end, dt.hash_pw(pw))
      returning * into u;
    v := jsonb_build_object('user', dt.pub(u), 'defaultPassword', pw);

  elsif action = 'resetPassword' then
    select * into u from dt.users where id = payload->>'id';
    if not found then perform dt.err('Akun tidak ditemukan.', 'not_found'); end if;
    pw := dt.default_pw(u.nama);
    update dt.users set pw_hash = dt.hash_pw(pw), pw_default = true where id = u.id;
    delete from dt.sessions where user_id = u.id;
    v := jsonb_build_object('defaultPassword', pw, 'token', case when u.id = me.id then to_jsonb(dt.new_token(u.id)) else 'null'::jsonb end);

  elsif action = 'setActive' then
    select * into u from dt.users where id = payload->>'id';
    if not found then perform dt.err('Akun tidak ditemukan.', 'not_found'); end if;
    if not coalesce((payload->>'aktif')::boolean, false) and u.role = 'spv'
       and (select count(*) from dt.users where role = 'spv' and aktif) <= 1 then
      perform dt.err('Minimal harus ada 1 supervisor aktif.', 'bad_request');
    end if;
    update dt.users set aktif = coalesce((payload->>'aktif')::boolean, false) where id = u.id returning * into u;
    if not u.aktif then delete from dt.sessions where user_id = u.id; end if;
    v := dt.pub(u);

  elsif action = 'saveProducts' then
    if jsonb_typeof(payload->'list') <> 'array' then perform dt.err('Data tidak valid.', 'bad_request'); end if;
    delete from dt.products where true;
    insert into dt.products(id, nama, sku, std, mult, asm, aktif, ord)
      select p->>'id', coalesce(p->>'nama', ''), coalesce(p->>'sku', ''), nullif(p->>'std', ''), greatest(1, coalesce((p->>'mult')::int, 1)),
             coalesce((p->>'asm')::boolean, false), coalesce((p->>'aktif')::boolean, true), o
      from jsonb_array_elements(payload->'list') with ordinality t(p, o);
    v := 'true'::jsonb;

  elsif action = 'saveStandards' then
    if jsonb_typeof(payload->'list') <> 'array' then perform dt.err('Data tidak valid.', 'bad_request'); end if;
    delete from dt.standards where true;
    insert into dt.standards(id, nama, catatan, komponen, ord)
      select s->>'id', coalesce(s->>'nama', ''), coalesce(s->>'catatan', ''), coalesce(s->'komponen', '[]'::jsonb), o
      from jsonb_array_elements(payload->'list') with ordinality t(s, o);
    v := 'true'::jsonb;

  elsif action = 'saveSettings' then
    if jsonb_typeof(payload->'settings') <> 'object' then perform dt.err('Data tidak valid.', 'bad_request'); end if;
    insert into dt.settings(key, value) values ('main', payload->'settings')
      on conflict (key) do update set value = excluded.value;
    v := dt.settings_json();

  else
    perform dt.err('Aksi tidak dikenal: ' || coalesce(action, ''), 'bad_request');
  end if;

  return jsonb_build_object('ok', true, 'data', v);
exception when others then
  get stacked diagnostics v_msg = message_text, v_hint = pg_exception_hint;
  return jsonb_build_object('ok', false, 'error', v_msg, 'code', coalesce(nullif(v_hint, ''), 'error'));
end $$;

-- ---------------------------------------------------------------- akses
revoke all on schema dt from public;
revoke all on all tables in schema dt from public;
revoke all on all functions in schema dt from public;
revoke all on function public.api(text, jsonb) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema dt from anon, authenticated';
    execute 'revoke all on all tables in schema dt from anon, authenticated';
    execute 'grant execute on function public.api(text, jsonb) to anon, authenticated';
  end if;
end $$;

-- ---------------------------------------------------------------- data awal
insert into dt.settings(key, value)
  values ('main', '{"efektivitas":80,"istirahatMenit":60,"jamNormal":8,"pwSuffix":"1234","fotoHari":90}')
  on conflict (key) do nothing;

insert into dt.standards(id, nama, catatan, komponen, ord)
  select s->>'id', s->>'nama', coalesce(s->>'catatan', ''), s->'komponen', o
  from jsonb_array_elements($json$[{"id":"SS","nama":"Snack Slime","catatan":"Dipakai semua slime selain JFC & Rio","komponen":[{"nama":"Printilan","detik":165},{"nama":"Slime","detik":44},{"nama":"Packing","detik":27}]},{"id":"SSW","nama":"Snack Slime (dengan wax)","catatan":"Khusus JFC Slime & Rio Slime","komponen":[{"nama":"Printilan","detik":420},{"nama":"Slime","detik":37},{"nama":"Packing","detik":29}]},{"id":"BBS","nama":"Blind Box Squishy","catatan":"Mewakili semua blind box","komponen":[{"nama":"Printilan","detik":340},{"nama":"Pembuatan box","detik":20},{"nama":"Packing","detik":30}]},{"id":"BSK","nama":"Butter Slime Kit","catatan":"Dipakai semua slime kit","komponen":[{"nama":"Printilan","detik":120},{"nama":"Slime","detik":130},{"nama":"Pembuatan box","detik":29},{"nama":"Packing","detik":60}]},{"id":"FID","nama":"Fidget","catatan":"","komponen":[{"nama":"Printilan","detik":60},{"nama":"Packing","detik":31}]},{"id":"BB","nama":"Blind Box","catatan":"Ada di dokumen, tapi default tidak dipakai (semua blind box ikut Blind Box Squishy)","komponen":[{"nama":"Printilan","detik":210},{"nama":"Slime","detik":30},{"nama":"Packing","detik":75}]}]$json$::jsonb) with ordinality t(s, o)
  on conflict (id) do nothing;

insert into dt.products(id, nama, sku, std, mult, asm, aktif, ord)
  select p->>'id', p->>'nama', p->>'sku', nullif(p->>'std', ''), (p->>'mult')::int, (p->>'asm')::boolean, (p->>'aktif')::boolean, o
  from jsonb_array_elements($json$[{"id":"P169","nama":"Set Bracelet & Necklace Crown","sku":"ACC004","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P170","nama":"Cam Nakelace Pompompuri","sku":"ACC005","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P171","nama":"Cam Nakelace Hellokitty","sku":"ACC006","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P172","nama":"Cam Nakelace Kuromi","sku":"ACC007","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P173","nama":"Cam Nakelace Cinnamon Roll","sku":"ACC008","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P174","nama":"Cam Nakelace Melody","sku":"ACC012","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P175","nama":"Doll Heart Beat","sku":"ACC018","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P176","nama":"Doll Voice Recorder","sku":"ACC019","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P191","nama":"Add on Box Boneka","sku":"ACC020","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P177","nama":"Bear and Star Hat Cream","sku":"ACC021","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P178","nama":"Green Alien Hat","sku":"ACC022","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P179","nama":"Pink Lotso Hat","sku":"ACC023","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P180","nama":"Brown Bunny Hat","sku":"ACC024","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P181","nama":"Pink Bunny Hat","sku":"ACC025","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P182","nama":"white snikers","sku":"ACC026","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P183","nama":"Green Avocado Bag","sku":"ACC030","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P184","nama":"Brown Bear Bag","sku":"ACC031","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P185","nama":"White knitted bag with pink ribbon","sku":"ACC032","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P186","nama":"Doll's Scent","sku":"ACC033","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P187","nama":"White knitted bag with pink ribbon (Big size)","sku":"ACC034","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P188","nama":"Joybox Choco or Yellow Bags","sku":"ACC035","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P189","nama":"Paper Bag","sku":"ADD001","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P190","nama":"Paper Bag Jumbo","sku":"ADD002","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P85","nama":"Bear Dolls (Brown) - 35cm","sku":"B007","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P86","nama":"Fox Dolls (Orange) - 35cm","sku":"B025","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P87","nama":"Puppy Dolls (White) - 35cm","sku":"B026","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P88","nama":"Fox Dolls Mini - 35cm","sku":"B027","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P89","nama":"Fox Dolls - 50cm","sku":"B028","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P90","nama":"Bear Doll (Brown)","sku":"B029","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P91","nama":"Bear Doll (White)","sku":"B030","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P92","nama":"Cubby Fox Doll","sku":"B043","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P93","nama":"Pink Unicorn Doll","sku":"B045","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P94","nama":"Curly Duck Doll - 40cm","sku":"B047","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P95","nama":"Dot Fox Doll","sku":"B051","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P96","nama":"Bib Fox Doll","sku":"B052","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P97","nama":"White Rabbit Doll","sku":"B053","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P98","nama":"White Cat Doll","sku":"B054","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P99","nama":"Cubby Cat Doll","sku":"B057","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P100","nama":"Brown Bear Dol","sku":"B060","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P101","nama":"Puffy Puppy Doll","sku":"B065","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P102","nama":"Panda Doll","sku":"B066","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P103","nama":"Rabbit Baby Doll (putih)","sku":"B067","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P104","nama":"Rabbit Baby Doll (Pink)","sku":"B068","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P105","nama":"Rabbit Baby Doll Big (putih)","sku":"B069","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P106","nama":"Rabbit Baby Doll Big (Pink)","sku":"B070","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P107","nama":"Rabbit Baby Doll (Grey)","sku":"B071","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P108","nama":"Sheep Doll","sku":"B079","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P109","nama":"Monkey Doll","sku":"B082","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P110","nama":"White Puppy Doll","sku":"B083","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P111","nama":"Brown Puppy Doll","sku":"B084","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P112","nama":"Joybox Cute Bunny (White)","sku":"B087","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P113","nama":"Joybox Cute Bunny (Pink)","sku":"B088","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P114","nama":"Cute Rabbit with Wings","sku":"B089","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P115","nama":"Mini Dumboo Elephant","sku":"B090","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P116","nama":"Mini Poppy Cat","sku":"B091","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P117","nama":"Pink Puffy Elephant Doll","sku":"B092","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P118","nama":"Purple Puffy Elephant Doll","sku":"B093","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P119","nama":"Blossom Bunny with dress","sku":"B094","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P120","nama":"Luna Cat Doll","sku":"B095","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P121","nama":"Choco Bear","sku":"B096","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P122","nama":"Sunny Cat","sku":"B097","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P123","nama":"Toffee Bear Doll","sku":"B098","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P124","nama":"Pink Hello Fluffy Bunny Doll","sku":"B099","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P125","nama":"Green Hello Fluffy Bunny Doll","sku":"B100","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P126","nama":"Blue Hello Fluffy Bunny Doll","sku":"B101","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P127","nama":"Pink Cotton Bunny Doll","sku":"B102","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P128","nama":"White Cotton Bunny Doll","sku":"B103","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P129","nama":"Jamal Turtle Doll","sku":"B104","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P130","nama":"Cocoa Puppy Doll","sku":"B105","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P131","nama":"Milky Puppy Doll","sku":"B106","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P132","nama":"Big Poppy Cat","sku":"B107","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P133","nama":"Bamboo Panda Doll","sku":"B108","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P134","nama":"Butter Bear Doll","sku":"B109","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P135","nama":"Mochi Puppy Doll","sku":"B110","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P136","nama":"Cloud Elephant Doll","sku":"B111","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P137","nama":"Snuggie Pig Doll","sku":"B112","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P138","nama":"Hazel Bear Doll","sku":"B113","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P139","nama":"Fairy Garden Dress","sku":"BB055","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P140","nama":"Lavender Dream Dress","sku":"BB056","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P141","nama":"Angel Dress","sku":"BB057","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P142","nama":"Rosy Blouse","sku":"BB058","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P143","nama":"Twinkle Dress","sku":"BB059","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P144","nama":"Cotton Candy Dress","sku":"BB060","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P145","nama":"Silk Princess Set","sku":"BB061","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P146","nama":"Cherry Blossom Dress","sku":"BB062","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P147","nama":"Red Blossom Dress","sku":"BB063","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P148","nama":"Little China Princess","sku":"BB064","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P149","nama":"Little Daisy Dress","sku":"BB065","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P150","nama":"Burberry Dress","sku":"BB066","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P151","nama":"Princess Wedding Dress","sku":"BB067","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P152","nama":"Mini Prince Suit","sku":"BB068","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P153","nama":"Cool Boys Denim Set","sku":"BB069","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P154","nama":"Tiny Denim set","sku":"BB070","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P155","nama":"Smart Student Set","sku":"BB071","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P156","nama":"Dream Wedding Dress","sku":"BB072","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P157","nama":"Flower Wedding Dress","sku":"BB073","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P158","nama":"Enchanted Wedding Dress","sku":"BB074","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P159","nama":"Little Groom Suit","sku":"BB075","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P160","nama":"Tiny Groom Suit","sku":"BB076","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P161","nama":"Fairy Wedding Dress","sku":"BB077","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P162","nama":"Charming Groom Suit","sku":"BB078","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P163","nama":"Little Student Outfit Girl","sku":"BB079","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P164","nama":"Little Student Outfit Boy","sku":"BB080","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P165","nama":"Butterfly Dress","sku":"BB081","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P166","nama":"Cozy Top Pink","sku":"BB082","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P167","nama":"Cozy Top Blue","sku":"BB083","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P168","nama":"Cozy Top White","sku":"BB084","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P20","nama":"Blind box Ambalabu","sku":"BBOX001","std":"BBS","mult":1,"asm":false,"aktif":true},{"id":"P21","nama":"Blind Box Anomali","sku":"BBOX002","std":"BBS","mult":1,"asm":false,"aktif":true},{"id":"P22","nama":"Blind Box Roblux","sku":"BBOX003","std":"BBS","mult":1,"asm":false,"aktif":true},{"id":"P23","nama":"Stinky Slime","sku":"BBOX004","std":"BBS","mult":1,"asm":false,"aktif":true},{"id":"P24","nama":"Advent Calendar","sku":"BBOX005","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P25","nama":"Blind Box Sanroi","sku":"BBOX006","std":"BBS","mult":1,"asm":false,"aktif":true},{"id":"P40","nama":"Bundling 6 box Ambalabu","sku":"BUND001","std":"BBS","mult":6,"asm":true,"aktif":true},{"id":"P41","nama":"Bundling 6 box Roblux","sku":"BUND002","std":"BBS","mult":6,"asm":true,"aktif":true},{"id":"P42","nama":"Bundling 6 box Anomali","sku":"BUND003","std":"BBS","mult":6,"asm":true,"aktif":true},{"id":"P44","nama":"Bundling Sanroi","sku":"BUND004","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P43","nama":"Bundling Stinky Slime","sku":"BUND005","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P45","nama":"Bundling 2 Marshmallow Jumbo","sku":"BUND013","std":"SS","mult":2,"asm":true,"aktif":true},{"id":"P46","nama":"Bundling 3 Snack Slime","sku":"BUND014","std":"SS","mult":3,"asm":true,"aktif":true},{"id":"P32","nama":"Magic White Glue","sku":"MGLU001","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P33","nama":"Magic Clear Glue","sku":"MGLU002","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P34","nama":"Magic Activator","sku":"MGLU003","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P36","nama":"Magic Foam","sku":"MGLU004","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P35","nama":"Magic Softener 250ml","sku":"MGLU005","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P37","nama":"Magic White Glue 500ml","sku":"MGLU006","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P38","nama":"Magic Clear Glue 500ml","sku":"MGLU007","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P39","nama":"Magic Activator 500ml","sku":"MGLU008","std":null,"mult":1,"asm":false,"aktif":true},{"id":"P47","nama":"Surprise Box","sku":"SBOX001","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P48","nama":"Mini Surprise Box","sku":"SBOX002","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P26","nama":"Crepes Slime","sku":"SKIT001","std":"BSK","mult":1,"asm":true,"aktif":true},{"id":"P27","nama":"Sanrio Slime Kit","sku":"SKIT003","std":"BSK","mult":1,"asm":true,"aktif":true},{"id":"P28","nama":"Slime kit Marshmallow 1000ml","sku":"SKIT004","std":"BSK","mult":1,"asm":true,"aktif":true},{"id":"P29","nama":"Slime kit Marshmallow 500ml","sku":"SKIT005","std":"BSK","mult":1,"asm":true,"aktif":true},{"id":"P30","nama":"Snack Party Slime Kit","sku":"SKIT006","std":"BSK","mult":1,"asm":true,"aktif":true},{"id":"P31","nama":"Slime Kit Butter","sku":"SKIT007","std":"BSK","mult":1,"asm":false,"aktif":true},{"id":"P1","nama":"Chipi Chapa","sku":"SLIME001","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P2","nama":"Yudi","sku":"SLIME002","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P4","nama":"Slime Mallow","sku":"SLIME004","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P5","nama":"Kinder Joybox","sku":"SLIME005","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P6","nama":"Drink Slime","sku":"SLIME006","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P8","nama":"Pudding 300ml","sku":"SLIME007","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P9","nama":"Pudding 1Lt","sku":"SLIME008","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P10","nama":"Auah 300ml","sku":"SLIME009","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P11","nama":"Auah 1Lt","sku":"SLIME010","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P3","nama":"Indomiaw","sku":"SLIME011","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P12","nama":"Birthday Kit Slime","sku":"SLIME012","std":"SS","mult":1,"asm":true,"aktif":true},{"id":"P13","nama":"Agus Slime","sku":"SLIME013","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P14","nama":"Ojan slime kit","sku":"SLIME014","std":"SS","mult":1,"asm":true,"aktif":true},{"id":"P15","nama":"Clara Pie","sku":"SLIME015","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P16","nama":"Marshmallow 1lt","sku":"SLIME016","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P17","nama":"Rio Slime","sku":"SLIME017","std":"SSW","mult":1,"asm":false,"aktif":true},{"id":"P18","nama":"JFC Slime","sku":"SLIME018","std":"SSW","mult":1,"asm":false,"aktif":true},{"id":"P19","nama":"Centil Slime","sku":"SLIME019","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P7","nama":"Ice Cream Slime","sku":"SLIME020","std":"SS","mult":1,"asm":false,"aktif":true},{"id":"P60","nama":"Roti Joy Squishy Pudding cup","sku":"STOY001","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P63","nama":"Roti Joy Squishy Big Bolu","sku":"STOY002","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P64","nama":"Roti Joy Squishy Big Star","sku":"STOY003","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P65","nama":"Roti Joy Squishy Pink Sakura","sku":"STOY004","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P67","nama":"Dumpling Squishy Gliter","sku":"STOY005","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P78","nama":"Roti Joy Squishy Birthday Cake","sku":"STOY006","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P81","nama":"Squishy Licensed Small","sku":"STOY008","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P82","nama":"Squishy Licensed Medium","sku":"STOY009","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P77","nama":"Roti Joy Squishy loaf Bread","sku":"STOY012","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P66","nama":"Roti Joy Squishy Butter","sku":"STOY013","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P72","nama":"Roti Joy Squishy Hello Kitty","sku":"STOY014","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P71","nama":"Roti Joy Squishy Roll Bread","sku":"STOY015","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P76","nama":"Roti Joy Squishy Polo Bun","sku":"STOY016","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P75","nama":"Roti Joy Squishy Baguet","sku":"STOY017","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P70","nama":"Roti Joy Squishy Croissant","sku":"STOY018","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P69","nama":"Roti Joy Squishy Double Bolu","sku":"STOY019","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P68","nama":"Dumpling Squishy","sku":"STOY020","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P74","nama":"Roti Joy Squishy Cheese Cake","sku":"STOY021","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P84","nama":"Roti Squishy New","sku":"STOY022","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P61","nama":"Roti Joy Squishy Bolu","sku":"STOY023","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P73","nama":"Roti Joy Squishy Strawberry Pao","sku":"STOY024","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P83","nama":"Squishy Licensed Large","sku":"STOY025","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P62","nama":"Roti Joy Chesee Bolu","sku":"STOY026","std":"BBS","mult":1,"asm":true,"aktif":true},{"id":"P49","nama":"Big Maltose bear","sku":"STOY029","std":"FID","mult":1,"asm":true,"aktif":true},{"id":"P50","nama":"Mini Maltose bear","sku":"STOY030","std":"FID","mult":1,"asm":true,"aktif":true},{"id":"P51","nama":"Ice Cube","sku":"STOY031","std":"FID","mult":1,"asm":true,"aktif":true},{"id":"P52","nama":"Maltose Cat","sku":"STOY032","std":"FID","mult":1,"asm":true,"aktif":true},{"id":"P53","nama":"Berry Cube","sku":"STOY033","std":"FID","mult":1,"asm":true,"aktif":true},{"id":"P54","nama":"Marble Ice Cube","sku":"STOY034","std":"FID","mult":1,"asm":true,"aktif":true},{"id":"P55","nama":"Color Change Ball","sku":"STOY035","std":"FID","mult":1,"asm":true,"aktif":true},{"id":"P56","nama":"Apple Joydoh","sku":"STOY036","std":"FID","mult":1,"asm":true,"aktif":true},{"id":"P57","nama":"Jellyfish Joydoh","sku":"STOY037","std":"FID","mult":1,"asm":true,"aktif":true},{"id":"P58","nama":"Crispy ball Joydoh","sku":"STOY038","std":"FID","mult":1,"asm":true,"aktif":true},{"id":"P59","nama":"Maltose Candy Joydoh","sku":"STOY040","std":"FID","mult":1,"asm":true,"aktif":true},{"id":"P79","nama":"Fidget Blind Bag","sku":"STOY041","std":"FID","mult":1,"asm":false,"aktif":true},{"id":"P80","nama":"Squishy Blind Box","sku":"STOY042","std":"BBS","mult":1,"asm":false,"aktif":true}]$json$::jsonb) with ordinality t(p, o)
  on conflict (id) do nothing;

insert into dt.users(id, nama, username, role, pw_hash) values
  ('u_ulis', 'Ulis', 'ulis', 'karyawan', dt.hash_pw('Ulis1234')),
  ('u_aul', 'Aul', 'aul', 'karyawan', dt.hash_pw('Aul1234')),
  ('u_hana', 'Hana', 'hana', 'karyawan', dt.hash_pw('Hana1234')),
  ('u_yuni', 'Yuni', 'yuni', 'karyawan', dt.hash_pw('Yuni1234')),
  ('u_spv', 'Supervisor', 'spv', 'spv', dt.hash_pw('Supervisor1234'))
  on conflict (id) do nothing;

notify pgrst, 'reload schema';
select 'Selesai: database Daily Task Produksi siap.' as status;
