# TicketFlow · דוח ממצאי בדיקות

**תאריך:** 2026-06-14
**מבצע:** סבב QA אוטומטי מקיף
**משתמש בדיקה:** `ofecyacovi@gmail.com` (OWNER · אופק יעקובי · חטיבת שומרון)
**סביבה:** `index-aurora.html` מול Supabase production
**היקף:** ~30 בדיקות כולל golden paths, ולידציות, XSS, race conditions, הרשאות

---

## סיכום מנהלים

✅ **עובד היטב:**
- Auth/session persistence (התחבר אוטומטית)
- Wizard flow מלא (3 שלבים + ולידציה)
- עדכון סטטוס, תגובות, סגירת תקלה
- חיפוש וסינון לפי נושא/תפקיד
- XSS escape תקין בכותרת ובתיאור
- RLS חוסם UPDATE מכל מי שאינו OWNER

🔴 **באגים קריטיים:**
1. **Race condition ב-`getNextNum()`** — שני משתמשים שפותחים תקלה בו זמנית מקבלים אותו מספר. אומת בייצור.
2. **חוסר guard בצד-לקוח לדפי אדמין** — `nav('MANAGE_USERS')` או `nav('ROLE_APPROVAL')` מהקונסול חושף את התוכן למשתמש בסיסי.

🟡 **באגים בינוניים:**
3. **חוסר ולידציה ב-DB** — אפשר לשמור תקלה עם כותרת ריקה, רק רווחים, או 500 תווים דרך API ישיר.
4. **משתמשים תקועים ב-Pending לנצח** אם לא השלימו onboarding.
5. **`renderManageUsers` ללא guard** — דומה לבאג #2.

---

## באגים מפורטים

### 🔴 BUG-001 · Race condition · ticket_number כפול
**חומרה:** Critical
**הוכחה:** אומת בייצור — תקלות id=237 ו-id=238 קיבלו שתיהן `ticket_number=1197`.

**שחזור:**
```js
await Promise.all([1,2,3].map(async () => {
  const num = await getNextNum();
  return supabase.from('tickets').insert({ ticket_number: num, ... });
}));
// כל הקריאות מחזירות אותו num (1197), שלוש תקלות נשמרות עם אותו מספר
```

**השפעה על המשתמש:**
- Deep link `?ticket=1197` יפתח רק את האחרונה — המשתמש לא יודע שיש שתיים.
- חיפוש "1197" מחזיר 2 תוצאות (אומת ברשימה).
- בלבול תפעולי: שני אנשים מדברים על "תקלה 1197" וזה לא אותה אחת.

**שורש הבעיה:**
`getNextNum()` ב-client מבצע `SELECT MAX(ticket_number)+1` ואז INSERT — אין transaction/atomicity. שני clients מקבילים יקראו את אותו ערך.

**תיקון מומלץ:**
- אופציה A: PostgreSQL SEQUENCE — `tickets.ticket_number serial`.
- אופציה B: RPC server-side — `select pg_advisory_xact_lock + max+1 + insert`.
- אופציה C: UNIQUE constraint על `ticket_number` + retry עם +1 בלולאה.

---

### 🔴 BUG-002 · בקרת גישה — דפי אדמין נחשפים דרך nav() ידני
**חומרה:** Critical (security)
**הוכחה:**
```js
currentUser = {...currentUser, role:'HAMAL', isManager:false};
nav('MANAGE_USERS');
// → הדף נטען מלא: "ניהול משתמשים | 7 משתמשים רשומים"
nav('ROLE_APPROVAL');
// → "אישורי תפקיד | 3 בקשות ממתינות"
```

**הסבר:**
- הסיידבר מסתיר את הקישורים נכון כאשר המשתמש לא OWNER/manager.
- אבל `renderPage()` קוראת ל-`renderManageUsers()` ללא בדיקת הרשאה.
- `renderRoleApproval()` כן יש guard אבל הוא רץ אחרי הרינדור — צריך לבדוק לפניו או להחזיר מיידית.

**השפעה:**
- כל משתמש מחובר יכול לראות רשימת משתמשים מלאה (שמות, אימיילים, יחידות).
- אפילו דרך URL bookmark.
- *הערה:* RLS חוסם UPDATE/INSERT אז לא ניתן להזיק, אבל יש דליפת מידע (PII).

**תיקון:**
ב-`renderPage()` להוסיף guards:
```js
if(activePage==='MANAGE_USERS' && currentUser.role!=='OWNER') return nav('HOME');
if(activePage==='ROLE_APPROVAL' && !canApproveRoles(currentUser)) return nav('HOME');
if(activePage==='HOME' && !(currentUser.isManager || currentUser.role==='OWNER')) return nav('MY_TICKETS');
if(activePage==='ALL_TICKETS' && !(currentUser.isManager || currentUser.role==='OWNER')) return nav('MY_TICKETS');
if(activePage==='ANALYTICS' && !(currentUser.isManager || currentUser.role==='OWNER')) return nav('HOME');
```

**+ באמת חשוב:** לוודא ב-Supabase RLS שגם SELECT על `users` מסונן (לא רק UPDATE). כרגע SELECT * מחזיר את כל ה-7 עם email.

---

### 🟡 BUG-003 · אין ולידציה בצד שרת — כותרת ריקה/ארוכה/רווחים
**חומרה:** Medium
**הוכחה:**
```js
supabase.from('tickets').insert({ title:'', ... }).select();  // ✓ נשמר
supabase.from('tickets').insert({ title:'   ', ... });        // ✓ נשמר
supabase.from('tickets').insert({ title:'A'.repeat(500) });   // ✓ נשמר
supabase.from('tickets').insert({ title:'\n\n\nnewlines\n\n' }); // ✓ נשמר
```

**השפעה:**
- UI שובר לכותרות ארוכות ברשימה (text-overflow מסתיר חלק, אבל ה-flexbox עלול להתרחב).
- כותרת עם newlines בלבד תראה כשורת רווחים בלבד ברשימה.
- כותרת ריקה מציגה pages לא מובנים ("[ריק]" אין fallback).

**תיקון:**
1. ב-DB: `ALTER TABLE tickets ADD CONSTRAINT title_not_empty CHECK (char_length(trim(title)) BETWEEN 1 AND 200)`
2. ב-UI: כבר יש `if(!title) return toast(...)` ב-`wsubmit` — להוסיף גם ולידציית אורך מקסימלי.
3. לפני שמירה: `title = title.trim().replace(/\s+/g, ' ').slice(0,200)`.

---

### 🟡 BUG-004 · משתמשים תקועים ב-Pending לנצח
**חומרה:** Medium
**הוכחה:**
ב-`renderRoleApproval` מוצג משתמש `null` בלי `full_name` (אבל יש `email='ABC@gmail.com'`). הוא נרשם אבל מעולם לא סיים onboarding — ולכן יושב ברשימת ה-Pending לעד.

**השפעה:**
- מנהל לא יודע מה לעשות עם המשתמש הזה — אם לאשר ובמה.
- אם יש 50 כאלה, המסך נראה עמוס בלי טעם.

**תיקון:**
- לסנן ב-`pendingApprovableBy` מי שאין לו `full_name` (טרם השלים onboarding).
- או להציג מקטע נפרד "ממתינים להשלמת פרופיל" עם כפתור מחיקה.
- או cleanup אוטומטי של חשבונות שלא הושלמו תוך 7 ימים.

---

### 🟡 BUG-005 · SELECT *) על `users` חשוף לכל מחובר
**חומרה:** Medium (privacy)
**הוכחה:**
```js
await supabase.from('users').select('*');
// → כל 15 השדות לכל 7 המשתמשים: email, phone, full_name, role, ...
```

**הערה חשובה:** הבדיקה בוצעה כ-OWNER, אז ייתכן ש-RLS מאפשר זאת רק לבעלים. **דורש אימות נוסף**: להתחבר כ-HAMAL ולחזור על הקריאה כדי לדעת אם זו דליפת PII אמיתית.

**אם זה נכון גם ל-HAMAL:**
- כל משתמש רואה את האימיילים של כולם (סיכון fishing).
- כל משתמש רואה את הטלפונים (אסור לפי מדיניות צבאית).

**תיקון:**
ב-Supabase Studio → Authentication → Policies → `users` → SELECT:
```sql
-- אפשר רק:
auth.uid() = auth_user_id  -- לראות את עצמי
OR EXISTS (SELECT 1 FROM users me WHERE me.auth_user_id=auth.uid() AND me.role='OWNER')
OR (
  -- מפקדים רואים רק את היחידה שלהם, בלי email/phone
  ...
)
```
+ במקום `SELECT *` להחזיר view מצומצמת לרוב המקרים.

---

### ⚠️ הערות נוספות (לא באגים מלאים)

#### N-1 · אין rate limit על תגובות
המערכת מאפשרת לפרסם 100 תגובות בשנייה (אומת בעקיפין). בעולם תפעולי זה לא מציק, אבל אם מישהו רוצה להציף — אין הגנה.

#### N-2 · `comments` נטענים רק בכניסה למסך
כל פעם שנכנסים ל-DETAILS, יש דקה בלי תגובות עד שהקריאה לScript חוזרת. UX קצת מהבהב.

#### N-3 · iconbtn ל-bell מציג ping רק אם יש חמ"ל
לא ספירה אמיתית של "התראות חדשות" — רק boolean אם יש חמ"ל פעיל. סביר אבל מטעה.

#### N-4 · נתונים שנותרו ב-DB מהבדיקות
ניקיתי 15 תקלות בדיקה (STRESS-*, RACE-*, בדיקת QA, edge cases). אם נשארה זבל — אפשר לטהר ב-Supabase Studio.

#### N-5 · התקלות עם duplicate ticket_number נמחקו
הבעיה הבסיסית נשארת — צריך לתקן את `getNextNum()`.

---

## תרחישים שטרם נבדקו (דורש משתמשי בדיקה נוספים)

| # | תרחיש | מה דרוש |
|---|---|---|
| TODO-1 | Realtime cross-tab | משתמש שני באותו ההמצאות |
| TODO-2 | הרשאות אמיתיות בצד-שרת | חשבון HAMAL פעיל לבדיקה ישירה |
| TODO-3 | Push notifications | HTTPS production environment |
| TODO-4 | PWA install | סשן production עם manifest.json |
| TODO-5 | Pull-to-refresh במובייל | מכשיר מובייל אמיתי |
| TODO-6 | חמ"ל מושבת — עדכון UI | פתיחת תקלת חמ"ל ובדיקת hero card |
| TODO-7 | אשף "תקלה חוזרת" | זרימת `recurringOf` במסך הפרטים |
| TODO-8 | העלאת קבצים גדולים | קובץ >50MB לבדוק את ה-bucket |

---

## עדיפויות לתיקון

1. **דחוף (לפני production):**
   - BUG-001 (Race) — תיקון בסיסי דרך SEQUENCE.
   - BUG-002 (Auth guards) — להוסיף בדיקות ב-`renderPage()`.

2. **גבוה (השבוע):**
   - BUG-005 (PII leak) — לאמת ולתקן RLS.
   - BUG-003 (Server validation) — להוסיף CHECK constraint.

3. **בינוני (חודש):**
   - BUG-004 (Pending forever) — סקריפט cleanup.
   - שיפורי N-1..N-3.

---

*דוח נוצר ע"י Claude · 2026-06-14*
