-- Run this once in Supabase: SQL Editor > New query > paste > Run.
create table staff(user_id uuid primary key references auth.users on delete cascade, role text not null check (role in ('admin','scorer')));
create table competitions(id text primary key, name text not null, date text, status text not null default 'running', state jsonb not null default '{}', times jsonb not null default '{}', chk jsonb not null default '{}', updated_at timestamptz default now());
create table comp_secret(comp_id text primary key references competitions on delete cascade, scrs jsonb not null default '{}');
create table registrations(id uuid primary key default gen_random_uuid(), comp_id text not null references competitions on delete cascade, name text not null, cls text, wca_id text, checked_in boolean default false, created_at timestamptz default now());

create function is_staff() returns boolean language sql security definer stable set search_path=public as $$ select exists(select 1 from staff where user_id=auth.uid()) $$;
create function is_admin() returns boolean language sql security definer stable set search_path=public as $$ select exists(select 1 from staff where user_id=auth.uid() and role='admin') $$;

alter table staff enable row level security;
alter table competitions enable row level security;
alter table comp_secret enable row level security;
alter table registrations enable row level security;

create policy "own staff row" on staff for select using (user_id=auth.uid());
-- everyone can read competitions and results
create policy "read competitions" on competitions for select using (true);
create policy "staff insert competitions" on competitions for insert with check (is_staff());
create policy "staff update competitions" on competitions for update using (is_staff());
create policy "admin delete competitions" on competitions for delete using (is_admin());
-- scrambles: staff always, everyone only once the competition is Past
create policy "read scrambles" on comp_secret for select using (is_staff() or exists(select 1 from competitions c where c.id=comp_id and c.status='past'));
create policy "staff write scrambles" on comp_secret for all using (is_staff()) with check (is_staff());
-- registration: anyone can sign up until the competition is Past; only staff can see the list
create policy "public register" on registrations for insert with check (length(trim(name)) between 1 and 60 and exists(select 1 from competitions c where c.id=comp_id and c.status<>'past'));
create policy "staff read registrations" on registrations for select using (is_staff());
create policy "staff update registrations" on registrations for update using (is_staff());
create policy "staff delete registrations" on registrations for delete using (is_staff());

-- atomic single-cell update so two scorers never overwrite each other
create function set_cell(p_comp text, p_kind text, p_round text, p_cuber text, p_idx int, p_val text) returns void language plpgsql as $$
declare col jsonb; arr jsonb;
begin
  if p_kind not in ('times','chk') then raise exception 'bad kind'; end if;
  execute format('select %I from competitions where id=$1 for update', p_kind) into col using p_comp;
  col := coalesce(col,'{}'::jsonb);
  arr := coalesce(col->p_round->p_cuber, '["","","","",""]'::jsonb);
  arr := jsonb_set(arr, array[p_idx::text], to_jsonb(p_val));
  col := jsonb_set(col, array[p_round], coalesce(col->p_round,'{}'::jsonb), true);
  col := jsonb_set(col, array[p_round,p_cuber], arr, true);
  execute format('update competitions set %I=$1 where id=$2', p_kind) using col, p_comp;
end $$;

alter publication supabase_realtime add table competitions;

-- After creating your first user in Authentication > Users, make them an admin:
-- insert into staff(user_id, role) values ('PASTE-USER-UUID-HERE', 'admin');
-- Scorers: same, with role 'scorer'.
