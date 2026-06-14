# 🔐 TicketFlow — Security Findings & Fixes

_Last reviewed: 2026-06-10_

This document lists the security issues found in the TicketFlow app (`index.html`) and the
Cloudflare push worker (`ticketflow-worker-push/src/index.js`), and exactly how to fix each one.

Items marked **✅ FIXED IN CODE** were already patched in this pass. Items marked
**⚠️ ACTION REQUIRED** cannot be fixed from the static client — they must be applied in your
**Supabase dashboard** (SQL) or **Cloudflare** (env vars), because a browser-only app cannot
enforce its own security. Anyone can open DevTools and call the database directly.

---

## Severity summary

| # | Severity | Area | Issue | Where to fix |
|---|----------|------|-------|--------------|
| 1 | 🔴 Critical | Database | No Row-Level Security — any logged-in user can read every ticket + every user's email/phone | Supabase SQL |
| 2 | 🔴 Critical | Database | Privilege escalation — a user can make themselves `OWNER` from the console | Supabase SQL |
| 3 | 🟠 High | Push worker | The push secret was hard-coded in the client → replaced with Supabase token auth | ✅ FIXED IN CODE — needs env + redeploy |
| 4 | 🟡 Medium | Client | DOM-XSS via attachment URLs / unescaped quotes | ✅ FIXED IN CODE |
| 5 | 🟢 Low | Push worker | Public `/debug` endpoints leaked subscription info → now gated | ✅ FIXED IN CODE |

---

## 1. 🔴 No Row-Level Security (RLS) — data exposure

**What happens today:** `loadData()` runs `supabase.from("tickets").select("*")` and
`supabase.from("users").select("*")`. All filtering (by unit, by role) happens **in the
browser**. With RLS disabled, the filters are cosmetic — any authenticated user can open
the console and run:

```js
(await supabase.from('tickets').select('*')).data        // every ticket in the system
(await supabase.from('users').select('email,phone')).data // everyone's email + phone
```

**Fix — enable RLS in Supabase (SQL editor):**

```sql
alter table public.tickets         enable row level security;
alter table public.users           enable row level security;
alter table public.ticket_comments enable row level security;
alter table public.units           enable row level security;
alter table public.counters        enable row level security;

-- Helper: is the current auth user an OWNER?
create or replace function public.is_owner()
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.users
    where auth_user_id = auth.uid() and role = 'OWNER'
  );
$$;
```

**Tickets** — visibility mirrors the app's logic (own ticket, your unit, your handling role,
or owner). Because `unit` is stored as a comma-joined string, this uses a text match:

```sql
-- Read: owner sees all; everyone else sees their own tickets, tickets for their role,
-- or tickets whose unit list intersects their units.
create policy tickets_select on public.tickets for select
using (
  public.is_owner()
  or created_by_user_id = (select id from public.users where auth_user_id = auth.uid())
  or assigned_role      = (select role from public.users where auth_user_id = auth.uid())
  or exists (
    select 1 from public.users u
    where u.auth_user_id = auth.uid()
      and to_jsonb(u.unit) ?| string_to_array(replace(public.tickets.unit, ' ', ''), ',')
  )
);

-- Insert: any logged-in user may create a ticket, but only as themselves.
create policy tickets_insert on public.tickets for insert
with check (created_by_user_id = (select id from public.users where auth_user_id = auth.uid()));

-- Update: owner, the assigned handling role, or the creator.
create policy tickets_update on public.tickets for update
using (
  public.is_owner()
  or created_by_user_id = (select id from public.users where auth_user_id = auth.uid())
  or assigned_role      = (select role from public.users where auth_user_id = auth.uid())
);
```

> Note: if your `unit` column is a real array (not a comma string), drop the `replace/string_to_array`
> and use `to_jsonb(u.unit) ?| public.tickets.unit`. Test with a non-owner account before relying on it.

**Comments / units / counters:**

```sql
create policy comments_select on public.ticket_comments for select using (auth.uid() is not null);
create policy comments_insert on public.ticket_comments for insert
  with check (author_user_id = (select id from public.users where auth_user_id = auth.uid()));

create policy units_read    on public.units    for select using (auth.uid() is not null);
create policy counters_read  on public.counters for select using (auth.uid() is not null);
create policy counters_write on public.counters for update using (auth.uid() is not null);
```

**Protecting email/phone:** the app only needs *other* users' name, role, unit and settings (for
notification routing) — never their email/phone. Expose a safe directory view and read from it:

```sql
create or replace view public.users_directory as
  select id, auth_user_id, full_name, role, is_manager, requested_manager,
         unit, unit_id, requested_role, role_status, is_frozen, settings
  from public.users;
grant select on public.users_directory to authenticated;
```

Then in `index.html`, change the list query in `loadData()` from
`supabase.from("users").select("*")` to `supabase.from("users_directory").select("*")`, and fetch
the current user's own full row (with email/phone) separately by `auth_user_id`.

---

## 2. 🔴 Privilege escalation on the `users` table

**What happens today:** there is no policy stopping a user from running, in the console:

```js
await supabase.from('users').update({ role: 'OWNER', is_frozen: false })
              .eq('auth_user_id', (await supabase.auth.getUser()).data.user.id)
```

That makes them an OWNER. Sign-up also lets the client choose its own `role`.

**Fix:** users may edit only their *own* safe profile fields; role / freeze / manager flags
become OWNER-only and move behind `security definer` RPCs.

```sql
-- 1) Self can read/update only their own row...
create policy users_select_self on public.users for select using (auth_user_id = auth.uid());
create policy users_update_self on public.users for update
  using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

-- 2) ...but block direct writes to sensitive columns. Only grant the safe ones.
revoke update on public.users from authenticated;
grant  update (full_name, phone, unit, unit_id, settings, requested_role, requested_manager)
  on public.users to authenticated;

-- 3) Owner-only admin actions via SECURITY DEFINER functions:
create or replace function public.admin_set_role(target uuid, new_role text)
returns void language plpgsql security definer as $$
begin
  if not public.is_owner() then raise exception 'not authorized'; end if;
  update public.users set role = new_role, role_status = 'Approved', requested_role = null where id = target;
end; $$;

create or replace function public.admin_set_frozen(target uuid, frozen boolean)
returns void language plpgsql security definer as $$
begin
  if not public.is_owner() then raise exception 'not authorized'; end if;
  update public.users set is_frozen = frozen where id = target;
end; $$;

create or replace function public.admin_set_manager(target uuid, mgr boolean)
returns void language plpgsql security definer as $$
begin
  if not public.is_owner() then raise exception 'not authorized'; end if;
  update public.users set is_manager = mgr, requested_manager = false where id = target;
end; $$;
```

Then update the client admin handlers to call the RPCs instead of `.update(...)`:

```js
// approveRole:   await supabase.rpc('admin_set_role',    { target: uid, new_role: role });
// toggleFreeze:  await supabase.rpc('admin_set_frozen',  { target: uid, frozen: state });
// toggleManager: await supabase.rpc('admin_set_manager', { target: uid, mgr: state });
```

> Run the SQL **before** changing the client, or the owner's user-management screen will stop
> working until the functions exist.

---

## 3. 🟠 Push secret was hard-coded in the client — ✅ FIXED IN CODE (action needed to activate)

The client used to ship `const PUSH_SECRET = "TF-2026-..."`. Because the file is downloaded by every
browser, the secret was public — anyone could read it in "View Source" and call the worker directly
(with `curl`, bypassing CORS) to spam notifications or unsubscribe people.

**What changed in code:**
- The client no longer contains a push secret. It now sends the logged-in user's **Supabase access
  token** as `Authorization: Bearer <token>` on every worker call (`getAccessToken()` helper).
- The worker (`src/index.js`) now **verifies that token** (HS256) before doing anything on the
  protected endpoints, via the new `verifySupabaseToken()` function.

**To activate it (required, or push notifications will stop working):**
1. In Supabase → **Project Settings → API → JWT Settings**, copy the **JWT Secret**.
2. In Cloudflare → your worker → **Settings → Variables and Secrets**, add an **encrypted** variable
   `SUPABASE_JWT_SECRET` with that value. (You can also delete the now-unused `APP_SECRET`.)
3. Redeploy the worker (`npx wrangler deploy` from `ticketflow-worker-push/`).

If `SUPABASE_JWT_SECRET` is not set, the worker rejects all protected calls with `401` by design
(fail-closed) — so set it before relying on notifications.

---

## 4. 🟡 DOM-XSS hardening — ✅ FIXED IN CODE

- `escapeHtml()` now also escapes `'` and `` ` ``, closing attribute-context breakouts.
- Attachment images/videos now run through a new `safeUrl()` helper that only allows
  `http(s)` URLs (blocks `javascript:`/`data:` URIs), and the click handler reads the URL from a
  `data-` attribute instead of interpolating it into an inline `onclick` string.

No action needed — these are live in `index.html`.

---

## 5. 🟢 Push worker — debug endpoints — ✅ FIXED IN CODE

`/debug` and `/debugSubs` exposed build info and per-user subscription counts. They are now **off by
default** — they only respond when the env var `ENABLE_DEBUG="1"` is set in Cloudflare. Leave it
unset in production; set it temporarily only while troubleshooting.

> Remaining (optional): `access-control-allow-origin: "*"` still allows any site to call the worker
> from a browser. Now that calls require a valid token this is low-risk, but you can tighten it by
> echoing an allow-listed origin if you wish.

---

## 6. 🧹 Remove leftover test data

The earlier STP audit created test users and a XSS test ticket. Clean them up in the Supabase SQL editor:

```sql
-- Test ticket used for the XSS check
delete from public.tickets where ticket_number = 9999;

-- Test accounts (also delete them from Auth → Users in the dashboard)
delete from public.users where email in (
  'hr.ticketflow@mailinator.com',
  'mamram.ticketflow@mailinator.com',
  'user.ticketflow@mailinator.com',
  'hatap2.ticketflow@mailinator.com'
);
```

---

## ✅ Do this first (highest impact, lowest effort)

1. Run the **Issue 2** SQL (privilege-escalation lockdown) — stops users from making themselves owner.
2. Run the **Issue 1** SQL (enable RLS + ticket/user policies) — stops cross-unit data leakage.
3. Rotate the push secret and plan the token-auth migration (**Issue 3**).
4. Re-test with a *non-owner* account in the console to confirm `select('*')` now returns only
   permitted rows.
