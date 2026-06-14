-- ============================================================================
--  TicketFlow — Row-Level Security setup
--  Run this in: Supabase Dashboard → SQL Editor → New query → Run.
--  Safe to re-run (idempotent): it drops existing policies and recreates them.
--
--  WHAT IT DOES
--   • Blocks anonymous (not-logged-in) access entirely.        → stops the public leak
--   • Lets each user read only tickets in their unit / role.   → stops cross-unit reads
--   • Stops users editing role / is_frozen / is_manager.       → stops self-promotion to OWNER
--   • Owner-only actions move to safe RPCs (admin_* functions).
--
--  AFTER RUNNING: the app's owner buttons (approve role / freeze / make manager)
--  use the new RPCs — those client changes are already in index.html.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0)  See what you currently have (optional — read the output, then continue)
-- ----------------------------------------------------------------------------
-- select tablename, policyname, roles, cmd, qual
-- from pg_policies where schemaname = 'public' order by tablename, policyname;

-- ----------------------------------------------------------------------------
-- 1)  Helper functions (SECURITY DEFINER = they bypass RLS internally, so the
--     policies below can call them without infinite recursion).
-- ----------------------------------------------------------------------------
create or replace function public.app_user_id() returns uuid
  language sql security definer stable set search_path = public as $$
  select id from public.users where auth_user_id = auth.uid() limit 1;
$$;

create or replace function public.app_role() returns text
  language sql security definer stable set search_path = public as $$
  select role from public.users where auth_user_id = auth.uid() limit 1;
$$;

create or replace function public.app_units() returns text[]
  language sql security definer stable set search_path = public as $$
  select coalesce(
    case when jsonb_typeof(to_jsonb(unit)) = 'array'
         then array(select jsonb_array_elements_text(to_jsonb(unit)))
         else '{}'::text[] end, '{}'::text[])
  from public.users where auth_user_id = auth.uid() limit 1;
$$;

create or replace function public.is_owner() returns boolean
  language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.users
                where auth_user_id = auth.uid() and role = 'OWNER');
$$;

create or replace function public.is_manager_user() returns boolean
  language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.users
                where auth_user_id = auth.uid() and (is_manager = true or role = 'OWNER'));
$$;

-- Can the current user see this ticket? (used by the comments policy)
create or replace function public.can_see_ticket(tid bigint) returns boolean
  language sql security definer stable set search_path = public as $$
  select public.is_owner()
      or public.app_role() = 'HR'
      or exists (
        select 1 from public.tickets t
        where t.id = tid and (
              t.created_by_user_id = public.app_user_id()
           or t.assigned_role      = public.app_role()
           or (t.is_hamal_down and public.app_role() = any(array['HATAP','MAMRAM','APP']))
           or exists (select 1
                      from unnest(string_to_array(coalesce(t.unit,''), ',')) as u(name)
                      where trim(u.name) = any(public.app_units()))
        )
      );
$$;

-- ----------------------------------------------------------------------------
-- 2)  Owner-only admin actions (called from the app via supabase.rpc).
--     These run as the table owner, so they can change protected columns —
--     but only after checking the caller is an OWNER.
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_role(target uuid, new_role text)
  returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'not authorized'; end if;
  update public.users
     set role = new_role, role_status = 'Approved', requested_role = null
   where id = target;
end; $$;

create or replace function public.admin_set_frozen(target uuid, frozen boolean)
  returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'not authorized'; end if;
  update public.users set is_frozen = frozen where id = target;
end; $$;

create or replace function public.admin_set_manager(target uuid, mgr boolean)
  returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'not authorized'; end if;
  update public.users set is_manager = mgr, requested_manager = false where id = target;
end; $$;

revoke all on function public.admin_set_role(uuid, text)    from public, anon;
revoke all on function public.admin_set_frozen(uuid, boolean) from public, anon;
revoke all on function public.admin_set_manager(uuid, boolean) from public, anon;
grant execute on function public.admin_set_role(uuid, text)    to authenticated;
grant execute on function public.admin_set_frozen(uuid, boolean) to authenticated;
grant execute on function public.admin_set_manager(uuid, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- 3)  Wipe every existing policy on these tables (clears any open "using(true)").
-- ----------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public'
             and tablename in ('tickets','users','ticket_comments','units','counters')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 4)  Turn RLS on, and cut anonymous access at the grant level too (defense in depth).
-- ----------------------------------------------------------------------------
alter table public.tickets         enable row level security;
alter table public.users           enable row level security;
alter table public.ticket_comments enable row level security;
alter table public.units           enable row level security;
alter table public.counters        enable row level security;

revoke all on public.tickets, public.users, public.ticket_comments,
              public.units,   public.counters
  from anon;

-- ----------------------------------------------------------------------------
-- 5)  TICKETS — read scoped to unit/role/owner; create as self; edit if entitled.
-- ----------------------------------------------------------------------------
create policy tickets_select on public.tickets for select to authenticated
using (
      public.is_owner()
   or public.app_role() = 'HR'
   or created_by_user_id = public.app_user_id()
   or assigned_role      = public.app_role()
   or (is_hamal_down and public.app_role() = any(array['HATAP','MAMRAM','APP']))
   or exists (select 1
              from unnest(string_to_array(coalesce(unit,''), ',')) as u(name)
              where trim(u.name) = any(public.app_units()))
);

create policy tickets_insert on public.tickets for insert to authenticated
with check ( created_by_user_id = public.app_user_id() );

create policy tickets_update on public.tickets for update to authenticated
using (
      public.is_owner()
   or created_by_user_id = public.app_user_id()
   or assigned_role      = public.app_role()
   or (public.is_manager_user() and exists (
         select 1 from unnest(string_to_array(coalesce(unit,''), ',')) as u(name)
         where trim(u.name) = any(public.app_units())))
)
with check ( true );

create policy tickets_delete on public.tickets for delete to authenticated
using ( public.is_owner() );

-- ----------------------------------------------------------------------------
-- 6)  TICKET_COMMENTS — visible if you can see the ticket; insert as yourself.
-- ----------------------------------------------------------------------------
create policy comments_select on public.ticket_comments for select to authenticated
using ( public.can_see_ticket(ticket_id) );

create policy comments_insert on public.ticket_comments for insert to authenticated
with check ( author_user_id = public.app_user_id() and public.can_see_ticket(ticket_id) );

-- ----------------------------------------------------------------------------
-- 7)  USERS — logged-in users can read the directory and edit ONLY their own
--     safe profile fields. role / is_frozen / is_manager are NOT updatable here
--     (only via the admin_* RPCs above), which blocks self-promotion to OWNER.
-- ----------------------------------------------------------------------------
create policy users_select on public.users for select to authenticated
using ( auth.uid() is not null );

create policy users_insert on public.users for insert to authenticated
with check ( auth_user_id = auth.uid() and coalesce(role,'HAMAL') in ('HAMAL','USER') );

create policy users_update_self on public.users for update to authenticated
using ( auth_user_id = auth.uid() )
with check ( auth_user_id = auth.uid() );

-- Column-level lock: self-update is allowed only on these columns.
revoke update on public.users from authenticated;
grant  update (full_name, phone, unit, unit_id, settings,
               requested_role, requested_manager, role_status)
  on public.users to authenticated;

-- ----------------------------------------------------------------------------
-- 8)  UNITS / COUNTERS — read for logged-in users; counter writable (ticket #s).
-- ----------------------------------------------------------------------------
create policy units_select on public.units for select to authenticated
using ( auth.uid() is not null );

create policy counters_select on public.counters for select to authenticated
using ( auth.uid() is not null );
create policy counters_insert on public.counters for insert to authenticated
with check ( auth.uid() is not null );
create policy counters_update on public.counters for update to authenticated
using ( auth.uid() is not null );

-- ----------------------------------------------------------------------------
-- 9)  Verify (run separately). As anon these should now be empty / blocked.
-- ----------------------------------------------------------------------------
-- select tablename, policyname, cmd, roles from pg_policies
-- where schemaname='public' order by tablename, policyname;

-- ============================================================================
--  OPTIONAL — also hide other users' email & phone from logged-in peers.
--  (Not required to close the public leak. Needs a tiny app change too.)
--
--  create or replace view public.users_directory as
--    select id, auth_user_id, full_name, role, is_manager, requested_manager,
--           unit, unit_id, requested_role, role_status, is_frozen, settings
--    from public.users;
--  grant select on public.users_directory to authenticated;
--  -- then in index.html change the list query from
--  --   supabase.from("users").select("*")
--  -- to
--  --   supabase.from("users_directory").select("*")
--  -- and fetch the current user's own full row (with email/phone) separately.
-- ============================================================================
