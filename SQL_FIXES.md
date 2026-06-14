# Supabase · תיקוני DB דרושים

הקובץ הזה מכיל SQL להריץ ב-Supabase Studio (SQL Editor) כדי להשלים את התיקונים שעשיתי בצד הלקוח.

⚠️ **לפני הריצה:** עשה backup ל-DB (Supabase Studio → Database → Backups).

---

## 1. BUG-001 · ייחודיות `ticket_number`

הצד-לקוח כבר יודע לעשות retry אם יש unique conflict. אבל בלי הconstraint, אין conflict — אז זה חובה.

**זהיר:** אם יש לך כבר תקלות עם אותו `ticket_number` (אומת — 1197 מופיע פעמיים), צריך לתקן אותן קודם.

```sql
-- ① בדוק אם יש כפילויות:
SELECT ticket_number, COUNT(*) c
FROM tickets
GROUP BY ticket_number
HAVING COUNT(*) > 1;

-- ② אם יש — תקן ע"י החלפה של הכפילות במספרים חדשים גבוהים:
WITH max_num AS (SELECT MAX(ticket_number) m FROM tickets),
     dupes AS (
       SELECT id, ticket_number,
              ROW_NUMBER() OVER (PARTITION BY ticket_number ORDER BY created_at) AS rn
       FROM tickets
     )
UPDATE tickets t
SET ticket_number = (SELECT m FROM max_num) + d.rn
FROM dupes d
WHERE t.id = d.id AND d.rn > 1;

-- ③ הוסף UNIQUE constraint:
ALTER TABLE tickets
  ADD CONSTRAINT tickets_ticket_number_unique UNIQUE (ticket_number);
```

מעכשיו, אם שני clients מנסים לשמור עם אותו `ticket_number`, אחד יקבל error code 23505, וה‑`insertTicketSafe` שהוספתי יעשה retry עם +1.

### גרסה אטומית יותר (אופציונלי, מומלץ לטווח הארוך)

אפשר להחליף את הספירה ב-PostgreSQL SEQUENCE:

```sql
-- ① צור sequence שמתחיל מהמקסימום הנוכחי
CREATE SEQUENCE IF NOT EXISTS tickets_number_seq
  START WITH 2000   -- ערך גבוה מהקיים
  INCREMENT BY 1
  OWNED BY tickets.ticket_number;

-- ② סנכרן ל-MAX הנוכחי:
SELECT setval('tickets_number_seq', (SELECT COALESCE(MAX(ticket_number),1000) FROM tickets));

-- ③ הפוך לברירת מחדל:
ALTER TABLE tickets
  ALTER COLUMN ticket_number SET DEFAULT nextval('tickets_number_seq');
```

ואז בקוד הלקוח אפשר פשוט להשמיט את `ticket_number` ב-INSERT — Postgres יקצה אטומית. ב-`insertTicketSafe`:

```js
// אם משתמשים ב-sequence, מוחקים את ה-ticket_number מה-payload
delete payload.ticket_number;
```

---

## 2. BUG-003 · CHECK constraint על כותרת ותיאור

```sql
-- כותרת חובה, בין 1 ל-200 תווים אחרי trim
ALTER TABLE tickets
  ADD CONSTRAINT title_length CHECK (char_length(trim(title)) BETWEEN 1 AND 200);

-- תיאור עד 5000 תווים (אופציונלי, יכול להיות null)
ALTER TABLE tickets
  ADD CONSTRAINT description_length CHECK (description IS NULL OR char_length(description) <= 5000);
```

הצד-לקוח כבר עושה `trim` + cap ל-200/5000, אז זה כפילות אבל חשובה (Defense in depth).

---

## 3. BUG-005 · RLS על `users` SELECT

זה הקריטי מבחינת PII. כרגע כל מחובר רואה את כל המשתמשים.

### צעד 1 — וודא ש-RLS מופעל:
```sql
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
```

### צעד 2 — מחק policies קיימים שמתירים SELECT חופשי:
ב-Supabase Studio → Authentication → Policies → users → מצא policy על SELECT שמתיר הכל ומחק אותו.

### צעד 3 — צור helper functions (SECURITY DEFINER) למניעת recursion

⚠️ אסור ש-policy על `users` תשאיל את `users` ישירות — זה גורם ל-`infinite recursion detected in policy for relation "users"`. הדרך הנכונה: פונקציה SECURITY DEFINER שעוקפת RLS פנימית.

```sql
-- helper function שבודקת את התפקיד של המשתמש המחובר בלי לטריגר RLS
CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT role FROM users WHERE auth_user_id = auth.uid() LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.current_user_is_manager()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT COALESCE(is_manager, false) FROM users WHERE auth_user_id = auth.uid() LIMIT 1;
$$;

-- תן הרשאת ביצוע ל-authenticated
GRANT EXECUTE ON FUNCTION public.current_user_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_is_manager() TO authenticated;
```

### צעד 4 — צור policy מדורג שמשתמש בפונקציות

```sql
-- מחק policies קיימים על SELECT (אם יש) לפני יצירה מחדש
DROP POLICY IF EXISTS users_owner_read           ON users;
DROP POLICY IF EXISTS users_self_read            ON users;
DROP POLICY IF EXISTS users_manager_read_same_role ON users;

-- בעלים רואה הכל
CREATE POLICY users_owner_read ON users
  FOR SELECT
  USING (public.current_user_role() = 'OWNER');

-- כל משתמש רואה את עצמו
CREATE POLICY users_self_read ON users
  FOR SELECT
  USING (auth_user_id = auth.uid());

-- מפקד רואה משתמשים שהוא יכול לאשר (אותו תפקיד או שמבקשים תפקידו)
CREATE POLICY users_manager_read_same_role ON users
  FOR SELECT
  USING (
    public.current_user_is_manager()
    AND (
      role = public.current_user_role()
      OR requested_role = public.current_user_role()
    )
  );
```

**הערה:** ב-Supabase, כל הסעיפים `OR` בין policies מאוחדים אוטומטית — אז משתמש יראה רשומה אם **לפחות אחד** מה-policies מאשר. זאת ההתנהגות הרצויה כאן.

### צעד 5 — בדיקה

```sql
-- כ-OWNER, אמור להחזיר את כל המשתמשים
SELECT COUNT(*) FROM users;

-- כ-HAMAL רגיל, אמור להחזיר 1 (את עצמו בלבד)
-- כדי לבדוק זאת בלי להתחבר מחדש, אפשר להריץ דרך JS בקונסול של הלקוח:
-- await supabase.from('users').select('id,email,role')
```

### צעד 4 — אם צריך להציג שם של פותח תקלה:
התקלות כבר שומרות `created_by_name` כ-snapshot, אז אין צורך לקרוא ל-`users` לזה. אם בעתיד תרצה לשלוף "כל התקלות של משתמש X" — תעשה זאת דרך RPC מצומצם.

---

## 4. BUG-004 · ניקוי משתמשים תקועים (אופציונלי)

הצד-לקוח כבר מסנן אותם מ-`pendingApprovableBy`, ומציג ל-OWNER סקציה למחיקה ידנית. אם אתה רוצה ניקוי אוטומטי:

```sql
-- מחק חשבונות שנרשמו לפני יותר משבועיים ולא השלימו פרופיל
DELETE FROM users
WHERE full_name IS NULL
  AND created_at < now() - interval '14 days';
```

אפשר לתזמן את זה כ-pg_cron job בSupabase או להריץ ידני מדי פעם.

---

## 5. בונוס · אינדקסים לביצועים

המערכת תאט אם יש 10K+ תקלות. הוסף עכשיו:

```sql
CREATE INDEX IF NOT EXISTS idx_tickets_created_at ON tickets(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tickets_assigned_role ON tickets(assigned_role);
CREATE INDEX IF NOT EXISTS idx_tickets_unit ON tickets(unit);
CREATE INDEX IF NOT EXISTS idx_tickets_is_closed ON tickets(is_closed) WHERE is_closed = false;
CREATE INDEX IF NOT EXISTS idx_tickets_is_hamal ON tickets(is_hamal_down) WHERE is_hamal_down = true;
CREATE INDEX IF NOT EXISTS idx_ticket_comments_ticket ON ticket_comments(ticket_id, created_at);
```

---

## סדר הרצה מומלץ

1. **גיבוי** — Database → Backups → New backup.
2. הרץ סעיף **1** (UNIQUE על ticket_number). אם יש כפילויות — הרץ את ה-UPDATE קודם.
3. הרץ סעיף **2** (CHECK על אורך כותרת).
4. הרץ סעיף **3** (RLS על users). תבדוק שאתה עדיין יכול להתחבר כ-OWNER ולראות את כל המשתמשים.
5. הרץ סעיף **5** (אינדקסים).
6. סעיף **4** רק אם רוצים cleanup אוטומטי.

### בדיקה אחרי:
- היכנס כ-OWNER → ודא שכל הדפים עובדים.
- היכנס כ-HAMAL → ודא ש‑`supabase.from('users').select('*')` מחזיר רק אותו (1 רשומה).
- פתח 2 חלונות עם משתמשים שונים, ופתח תקלה בו זמנית → ודא ש‑`ticket_number` שונים.

---

## מה שלא מתוקן ב-SQL

הבאגים האלה תוקנו רק בלקוח (`index-aurora.html`):
- **BUG-002** · guards לדפי אדמין → הוספתי ב-`renderPage()`.
- **BUG-003 (חלק לקוח)** · trim + slice לכותרת/תיאור.
- **BUG-004 (חלק לקוח)** · סינון לא-מושלמי-onboarding, סקציה למחיקה.
- **BUG-001 (חלק לקוח)** · `insertTicketSafe` עם retry.

הקובץ המקורי `index.html` **לא תוקן** — אם המערכת בייצור עובדת ממנו, צריך להעתיק את התיקונים שם גם.
