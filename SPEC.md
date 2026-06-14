# TicketFlow · אפיון מלא ומסמך בדיקות

**גרסה:** 2.0 (Aurora) · **תאריך:** 2026‑06‑14
**קבצים פעילים:** `index.html` (הגרסה הכהה הקלאסית) · `index-aurora.html` (הגרסה הבהירה החדשה)
**Backend:** Supabase · **Push:** Cloudflare Worker
**שפה:** עברית · RTL · מותאם דסקטופ + מובייל (PWA)

---

## 1. סקירה כללית

TicketFlow היא מערכת ניהול תקלות מבצעית ליחידה צבאית. משתמשים פותחים "תקלות" (יחידה, נושא, גורם מטפל), המערכת מנתבת אותן לתפקיד המתאים (חט"פ / ממר"ם / אפליקציה / מש"א / חוזי), מאפשרת מעקב סטטוס, תגובות בזמן אמת, סגירה, וצפייה באנליטיקה. תקלות קריטיות מסומנות כ"חמ"ל מושבת" ועוברות לראש התור עם התראה.

המערכת בנויה כ‑Single Page Application בקובץ HTML יחיד (ללא build step) שמסתנכרן מול Supabase ב‑realtime, ושולחת Push Notifications דרך Cloudflare Worker.

---

## 2. בעלי תפקיד והרשאות

| תפקיד (Role) | קוד | תיאור | הרשאות עיקריות |
|---|---|---|---|
| בעלים | `OWNER` | מנהל-על של המערכת | רואה הכל, יכול לאשר/להקפיא/לדחות כל משתמש ותפקיד |
| חמ"ל / משתמש בסיסי | `HAMAL` / `USER` | יחידת קצה שפותחת תקלות | רואה רק תקלות של היחידה שלו |
| חט"פ | `HATAP` | חוליית טיפול ראשונה | מקבל תקלות מחמ"ל ומעביר לגורם רלוונטי או למש"א |
| מש"א | `HR` | משאבי אנוש / סינון | רואה את כל התקלות; מטפל בהעברות מחט"פ |
| ממר"ם | `MAMRAM` | תפעול מחשב/רשת | רואה תקלות שמשויכות לתפקידו |
| אפליקציה | `APP` | תפעול אפליקציות | רואה תקלות שמשויכות לתפקידו |
| חוזי | `KHOZI` | תפעול חוזים | רואה תקלות שמשויכות לתפקידו |

**דגלים נוספים על משתמש:**
- `is_manager` — מפקד תפקיד. רואה את כל התקלות של היחידה שלו ושל יחידות-בנות, וכן יכול לאשר בקשות תפקיד **של אותו תפקיד שהוא מפקד בו**.
- `is_frozen` — חשבון מוקפא, גישה נחסמת בעת ההתחברות.
- `role_status` — `Pending` / `Approved` / `Rejected`.
- `requested_role` — תפקיד שהמשתמש ביקש לשדרג אליו (ממתין לאישור).
- `requested_manager` — האם המשתמש ביקש להפוך למפקד.

### 2.1 מטריצת אישור תפקידים (חדש)
| המבקש (requested_role) | מאשרים אפשריים |
|---|---|
| כל תפקיד | OWNER תמיד |
| HR (מש"א) | OWNER + כל משתמש עם `role=HR, is_manager=true` |
| MAMRAM (ממר"ם) | OWNER + כל משתמש עם `role=MAMRAM, is_manager=true` |
| HATAP / APP / KHOZI | OWNER + כל משתמש עם תפקיד מקביל ו‑is_manager=true |
| בקשת `requested_manager=true` | OWNER + מפקדים שכבר באותו תפקיד |

---

## 3. ארכיטקטורה טכנית

### 3.1 Stack
- **Frontend:** HTML/CSS/Vanilla JS יחיד (~3,000 שורות, ללא bundler), Heebo font, Lucide icons via CDN.
- **Backend:** Supabase (Auth + Postgres + Realtime + Storage).
- **Push Notifications:** Cloudflare Worker בכתובת `https://ticketflow-push.galaxyskin350.workers.dev`. אימות מול ה-Worker בעזרת access_token של Supabase (לא סוד קבוע בלקוח).
- **PWA:** Service Worker (`/sw.js`) להעבדה offline בסיסית והתראות.
- **Realtime:** ערוצי Supabase `public:tickets` ו‑`public:ticket_comments`.

### 3.2 משתני קונפיגורציה (קבועים בקובץ)
```js
SUPABASE_URL       = "https://tymratzaavokyhbcycgb.supabase.co"
SUPABASE_ANON_KEY  = "<JWT anon key>"
PUSH_WORKER_BASE   = "https://ticketflow-push.galaxyskin350.workers.dev"
```

### 3.3 מבנה טבלאות (Supabase / Postgres)

#### טבלה: `users`
| עמודה | טיפוס | הערות |
|---|---|---|
| `id` | uuid (PK) | |
| `auth_user_id` | uuid | מקושר ל-`auth.users` של Supabase |
| `full_name` | text | חובה אחרי onboarding |
| `email` | text | |
| `phone` | text | חובה אחרי onboarding |
| `role` | text | אחד מ‑OWNER/HR/HATAP/MAMRAM/APP/KHOZI/HAMAL |
| `is_manager` | boolean | |
| `is_frozen` | boolean | |
| `unit` | jsonb \| text | מערך JSON של יחידות, או מחרוזת בודדת |
| `unit_id` | uuid | מצביע לטבלת `units` (אופציונלי) |
| `requested_role` | text | בקשה ממתינה |
| `requested_manager` | boolean | |
| `role_status` | text | Pending/Approved/Rejected |
| `settings` | jsonb | `{ notifyOverdue:true, overdueTime:60, ... }` |

#### טבלה: `units`
| עמודה | טיפוס | הערות |
|---|---|---|
| `id` | uuid (PK) | |
| `name` | text | שם היחידה |
| `parent_unit` | text | שם יחידת-אב (למבנה היררכי) |

#### טבלה: `tickets`
| עמודה | טיפוס | הערות |
|---|---|---|
| `id` | uuid (PK) | |
| `ticket_number` | int | מספר רץ ייחודי |
| `title` | text | |
| `description` | text | |
| `topic` | text | מחשב/רשת/אפליקציה/אמצעים/עמדה דלה/אחר |
| `unit` | text | יחידה (יכול להיות רשימה מופרדת בפסיק) |
| `status` | text | OPEN/IN_PROGRESS/RESOLVED/CLOSED |
| `assigned_role` | text | תפקיד מטפל |
| `created_by_user_id` | uuid | מצביע ל-`users.id` |
| `created_by_name` | text | snapshot |
| `forwarded_by_hatap_name` | text | אם חט"פ העביר למש"א |
| `created_at` | timestamptz | |
| `is_closed` | boolean | |
| `is_hamal_down` | boolean | תקלת חמ"ל קריטית |
| `is_bumped` | boolean | "הוקפצה" ע"י המקור |
| `bump_count` | int | |
| `attachments` | jsonb | `[{url,type,name},...]` |
| `recurring_of` | uuid | מצביע לתקלה קודמת חוזרת |

#### טבלה: `ticket_comments`
| עמודה | טיפוס |
|---|---|
| `id` | uuid (PK) |
| `ticket_id` | uuid (FK) |
| `content` | text |
| `author_user_id` | uuid |
| `author_name` | text |
| `author_role` | text |
| `created_at` | timestamptz |

#### Storage Buckets
- `attachments` — תמונות/סרטונים מצורפים לתקלה (פומבי, URL נשמר ב‑`tickets.attachments[i].url`).

### 3.4 RPC Functions
- `check_recurring_tickets(input_title, input_topic, input_user_uuid)` → מחזיר רשומה עם `occurrence_count` בודק אם המשתמש פתח תקלה דומה לאחרונה.

### 3.5 RLS (Row Level Security)
ההרשאות נאכפות מ‑Supabase בצד השרת. הצד‑לקוח גם מסנן ל‑UX אבל **כל בדיקת אבטחה אמיתית חייבת לעבור ב-RLS**. שווה לאמת בבדיקות:
- משתמש בסיסי לא רואה תקלות של יחידות אחרות גם דרך קריאה ישירה ל‑API.
- משתמש מוקפא לא יכול לבצע פעולות גם אם UI מאפשר.

---

## 4. זרימות פונקציונליות (Functional Flows)

### 4.1 הרשמה / כניסה / איפוס סיסמה
1. **הרשמה** — `/auth.signUp` → יצירת רשומה ב-`users` עם `role=HAMAL`, `role_status=Pending`.
2. **כניסה** — `/auth.signInWithPassword` → טוען `loadData()` ועובר להרכבת האפליקציה.
3. **שכחתי סיסמה** — `/auth.resetPasswordForEmail` → המשתמש מקבל אימייל עם link → `index.html?type=recovery` → `isRecoveryMode=true` → טופס עדכון סיסמה.
4. **Onboarding** — אם `full_name` או `phone` חסרים → מסך השלמת פרופיל לפני כל פעולה.
5. **חשבון מוקפא** — בעת `loadData` אם `currentUser.isFrozen=true` → ניתוק מיידי + הודעת אזהרה + reload.

### 4.2 פתיחת תקלה (אשף 3 שלבים)
**שלב 1: נושא + סימון חמ"ל**
- כפתור "חמ"ל מושבת" (toggle) — אופציונלי.
- בחירת נושא מתוך 6 chips: מחשב / רשת / אפליקציה / אמצעים / עמדה דלה / אחר.
- ולידציה: לא ניתן להמשיך בלי נושא.

**שלב 2: גורם טיפול**
- בחירת יחידה (אם למשתמש יותר מאחת — select).
- בחירת תפקיד מטפל מתוך הרשימה המותרת:
  - HAMAL/USER → רק `HATAP`.
  - HATAP → רק `HR`.
  - אחר → `HATAP`, `HR`, `MAMRAM`, `APP`, `KHOZI`.
- ולידציה: חובה לבחור יחידה + תפקיד.

**שלב 3: כותרת, תיאור, קבצים**
- ולידציה: כותרת חובה.
- העלאת קבצים → `supabase.storage.from('attachments').upload(...)` → URL חוזר ונשמר במערך attachments.
- שמירת התקלה → `tickets.insert(...)` → `ticket_number` הבא מ-`getNextNum()`.
- שדה מיוחד: אם חט"פ פותח תקלה ומעביר ל-HR → `forwarded_by_hatap_name` נשמר.
- שליחת push (`pushTicketShort`) לכל המשתמשים הרלוונטיים.
- ניווט למסך פרטי התקלה החדשה.

### 4.3 צפייה ברשימת תקלות
**"התקלות שלי" (MY_TICKETS):**
- לוגיקה: תקלות שהמשתמש פתח **או** ששייכות לתפקידו **או** ליחידתו (אם הוא מנהל/חט"פ).
- חמ"ל פעיל מוצג גם לתפקידים תפעוליים (OWNER/HATAP/HR/MAMRAM/APP).

**"כל התקלות" (ALL_TICKETS, מנהלים בלבד):**
- אם OWNER → כל התקלות.
- אם isManager אחר → רק יחידות תחת אחריותו (כולל תתי‑יחידות מ‑`getExpandedUnits`).

**פילטרים:**
- חיפוש לפי כותרת/מספר (debounced 250ms).
- select לפי נושא.
- select לפי תפקיד מטפל.
- כפתורי "פתוחות" / "ארכיון".

### 4.4 מסך פרטי תקלה
- כותרת + מספר + סטטוס + תג "חמ"ל מושבת" אם רלוונטי.
- **Stepper סטטוסים**: OPEN → IN_PROGRESS → RESOLVED → CLOSED.
- תיאור + קבצים מצורפים (תמונות בלחיצה נפתחות בטאב חדש, וידאו מתנגן בתוך הדף).
- כפתורי "עדכן סטטוס" (למטפלים / OWNER) + "סגור תקלה" (לפותח / OWNER).
- אזור תגובות בזמן אמת — `ticket_comments` עם Realtime channel.
- היסטוריה (timeline) של אירועים.
- meta-grid: סטטוס / חומרה / יחידה / נושא / פותח / מטפל.

### 4.5 אישורי תפקיד (חדש — תמיכה במנהלי תפקיד)
- מי רואה את הקישור בסיידבר: OWNER **או** `is_manager=true`.
- מי רואה אילו בקשות: OWNER → כל הבקשות. מנהל תפקיד X → רק בקשות ל‑X (`requested_role===X` או `requested_manager` של משתמש שכבר ב‑X).
- כפתור "אשר" → עדכון `role`, `is_manager`, `role_status='Approved'`, איפוס בקשות פתוחות.
- כפתור "דחה" → `role_status='Rejected'`, איפוס בקשות פתוחות.

### 4.6 ניהול משתמשים (OWNER בלבד)
- רשימת כל המשתמשים עם שם / תפקיד / יחידה / סטטוס.
- כפתור הקפאה / ביטול הקפאה.

### 4.7 פרופיל אישי
- עדכון שם מלא + טלפון.
- אימייל לקריאה בלבד.
- כפתור התנתקות.

### 4.8 אנליטיקה
- 4 כרטיסי סיכום: פתוחות, טופלו, חמ"ל, בטיפול.
- פילוח בר אופקי לפי נושא.
- פילוח בר אופקי לפי תפקיד מטפל.

### 4.9 Realtime + Notifications
- ערוץ `public:tickets` — כל שינוי טריגר ל-`loadData()` + render + toast "הנתונים התעדכנו".
- ערוץ `public:ticket_comments` — תגובות חדשות מתווספות חיות למסך הפרטים.
- Service Worker רשום ב-`/sw.js` (לא קריטי לזרימה הראשית, מאפשר התקנת PWA).
- בדיקת תקלות חורגות זמן: ב‑`startOverdueCheck()` רץ כל דקה ושולח `Notification` נטיב לדפדפן אם מנהל הגדיר `notifyOverdue` ב-settings.

---

## 5. מסכים (Screen Inventory)

| מסך | תנאי | קוד פנימי |
|---|---|---|
| Welcome animation | בטעינה ראשונה (`index.html` בלבד) | `#welcome-screen` |
| Login | ללא session | `renderLogin()` |
| Signup | מתוך login | `renderSignup()` |
| Reset password | URL כולל `type=recovery` | `renderReset()` |
| Onboarding | חסרים full_name/phone | `renderOnboarding()` |
| Dashboard (HOME) | מנהל/בעלים | `renderHome()` |
| התקלות שלי | תמיד | `renderTicketList()` עם `MY_TICKETS` |
| כל התקלות | מנהל/בעלים | `renderTicketList()` עם `ALL_TICKETS` |
| פתיחת תקלה | תמיד | `renderCreate()` |
| פרטי תקלה | מתוך רשימה | `renderDetails()` |
| פרופיל | תמיד | `renderProfile()` |
| אנליטיקה | מנהל/בעלים | `renderAnalytics()` |
| משתמשים | OWNER | `renderManageUsers()` |
| אישורי תפקיד | OWNER או is_manager | `renderRoleApproval()` |

---

## 6. תרחישי בדיקה (QA Test Plan)

### 6.1 גישות בדיקה
- **Golden path**: כל זרימה ראשית לקצה.
- **Negative cases**: ולידציה, הרשאות, מצבים ריקים.
- **Concurrency**: שני משתמשים פתוחים → realtime עובד.
- **Edge data**: שמות ארוכים, כותרות עם תווי Unicode, ערכים ריקים, יחידות עם פסיקים.
- **Mobile** (≤900px): כל ה-flows כולל bottom nav, FAB, התראות.
- **PWA**: התקנה כאפליקציה, פתיחה ללא רשת אמורה להעלות את הקליפה.

### 6.2 Authentication & onboarding
| # | תרחיש | מצב התחלתי | פעולה | תוצאה צפויה |
|---|---|---|---|---|
| AUTH-01 | הרשמה תקינה | בלי משתמש | הזנת אימייל+סיסמה (≥6 תווים) → "צור חשבון" | משתמש נוצר ב-`auth.users` ו-`users` עם `role=HAMAL`, `role_status=Pending`. מועבר ל-login. |
| AUTH-02 | סיסמאות לא תואמות | טופס signup | סיסמה+אימות שונים | modal "הסיסמאות אינן תואמות". לא נשלחת בקשה. |
| AUTH-03 | אימייל קיים | קיים משתמש | signup עם אימייל זהה | שגיאה ידידותית מ-Supabase. |
| AUTH-04 | כניסה תקינה | משתמש קיים | אימייל+סיסמה נכונים | טעינת data + מעבר לדשבורד/MY_TICKETS לפי תפקיד. |
| AUTH-05 | כניסה שגויה | משתמש קיים | סיסמה שגויה | modal "שגיאה" עם הודעת Supabase. |
| AUTH-06 | שכחתי סיסמה | טופס login | קליק "שכחתי סיסמה" + אימייל קיים | modal "הודעה נשלחה". אימייל יוצא מ-Supabase. |
| AUTH-07 | איפוס סיסמה דרך לינק | קישור מאימייל | פתיחה + הזנת סיסמה חדשה (≥6) | סיסמה מתעדכנת, alert, reload, אפשר להתחבר. |
| AUTH-08 | Onboarding | משתמש חדש בלי שם/טלפון | מילוי שם+טלפון+יחידה | `users` מתעדכן, מעבר לאפליקציה. |
| AUTH-09 | חשבון מוקפא | מנהל הקפיא | התחברות | ניתוק מיידי, alert "החשבון שלך הוקפא", reload. |
| AUTH-10 | התנתקות | בתוך האפליקציה | קליק על log-out | חזרה ל-login. |
| AUTH-11 | רענון דף עם session | מחובר | F5 | חוזר לאותו עמוד שהיה (תקלה אם בדפים URL `?ticket=`). |

### 6.3 פתיחת תקלה
| # | תרחיש | תוצאה צפויה |
|---|---|---|
| CREATE-01 | אשף מלא תקין | תקלה נוצרת עם `ticket_number` רץ, מעבר למסך פרטים. |
| CREATE-02 | בלי נושא | כפתור "המשך" מציג toast "בחר נושא". לא עוברים שלב. |
| CREATE-03 | בלי כותרת בשלב 3 | toast "הכנס כותרת". insert לא קורה. |
| CREATE-04 | סימון חמ"ל מושבת | `is_hamal_down=true`. התקלה מופיעה בבאנר חירום. push יוצא עם כותרת מיוחדת. |
| CREATE-05 | העלאת תמונה | קובץ עולה ל-bucket `attachments`, URL נשמר, תצוגה במסך פרטים. |
| CREATE-06 | העלאת וידאו | אותו דבר; וידאו מנוגן inline במסך פרטים. |
| CREATE-07 | קובץ גדול / סוג שגוי | התנהגות גרציוסית: אין crash. (לא קיים limit מוגדר — שווה לאמת באיזה גודל זה נופל.) |
| CREATE-08 | חט"פ פותח תקלה ל-HR | `forwarded_by_hatap_name=currentUser.fullName` נשמר. |
| CREATE-09 | משתמש בסיסי | רואה רק HATAP כתפקיד אפשרי. |
| CREATE-10 | יחידות מרובות | select יחידה מופיע ועובד. |
| CREATE-11 | יחידה בודדת | select לא מוצג; היחידה נבחרת אוטומטית. |
| CREATE-12 | חזרה אחורה באשף | נתונים נשמרים בין שלבים (`createData`). |
| CREATE-13 | ביטול | מעבר ל-HOME, `createData` מתאפס. |

### 6.4 רשימת תקלות
| # | תרחיש | תוצאה צפויה |
|---|---|---|
| LIST-01 | משתמש בסיסי | רואה רק תקלות יחידתו + תקלות שפתח. |
| LIST-02 | חט"פ במש"א | רואה תקלות שמשויכות אליו + של היחידה. |
| LIST-03 | OWNER ב-ALL_TICKETS | רואה את כל התקלות במערכת. |
| LIST-04 | מנהל לא-OWNER | רואה רק יחידות תחתיו (כולל תתי). |
| LIST-05 | חיפוש לפי מספר | מסנן לפי `ticket_number`. |
| LIST-06 | חיפוש לפי טקסט | case-insensitive. |
| LIST-07 | סינון נושא | רק תקלות עם topic המבוקש. |
| LIST-08 | סינון תפקיד | רק תקלות שמשויכות לתפקיד. |
| LIST-09 | כפתור ארכיון | מציג רק `is_closed=true`. |
| LIST-10 | חמ"ל מושבת | מסומן וי-ת"ש (red border + emoji 🚨) ועולה לראש. |
| LIST-11 | תקלה ישנה (>שעה) | מסומן כ-"hot" עם רקע ורוד. |
| LIST-12 | רשימה ריקה | מסך empty state עם הצעת איפוס סינון. |

### 6.5 פרטי תקלה
| # | תרחיש | תוצאה צפויה |
|---|---|---|
| DETAIL-01 | צפייה כפותח | רואה הכל, יכול לסגור, יכול לעדכן סטטוס. |
| DETAIL-02 | צפייה כמטפל | יכול לעדכן סטטוס, לא לסגור (אלא אם הוא OWNER). |
| DETAIL-03 | צפייה כצופה לא מורשה | (אם UI הציג בטעות) RLS חוסם פעולות. |
| DETAIL-04 | קריאה לקריאה (read-only) על חמ"ל | משתמש לא תפעולי לא רואה כפתורי פעולה. |
| DETAIL-05 | הוספת תגובה | מופיעה מיד אצל הכותב + מתפרסמת ל-realtime לכל מי שצופה. |
| DETAIL-06 | עדכון סטטוס | stepper מתעדכן, toast "הסטטוס עודכן". |
| DETAIL-07 | סגירת תקלה | `status=CLOSED`, `is_closed=true`. עולה ל-ארכיון. |
| DETAIL-08 | קליק על תמונה מצורפת | נפתחת בטאב חדש. |
| DETAIL-09 | URL ישיר `?ticket=1183` | פותח את התקלה אוטומטית בכניסה (אם המשתמש מורשה). |

### 6.6 אישורי תפקיד (חדש)
| # | תרחיש | תוצאה צפויה |
|---|---|---|
| ROLE-01 | OWNER פותח את העמוד | רואה את כל הבקשות הממתינות. |
| ROLE-02 | מפקד HR פותח | רואה רק בקשות `requested_role=HR` + `requested_manager` ממש"א קיימים. |
| ROLE-03 | מפקד MAMRAM | רואה רק בקשות שמיועדות לתפקידו. |
| ROLE-04 | משתמש לא-מנהל | הקישור "אישורי תפקיד" לא מופיע בסיידבר. אם ניגש ל-`activePage='ROLE_APPROVAL'` ידנית — מועבר ל-HOME. |
| ROLE-05 | אישור | `role` משתנה, `is_manager` משתנה, `role_status='Approved'`, בקשות נמחקות. |
| ROLE-06 | דחייה | `role_status='Rejected'`, בקשות נמחקות. תפקיד לא משתנה. |
| ROLE-07 | מנהל לא יכול לאשר תפקיד שאינו שלו | באמצעות מניפולציה ידנית של ה-DOM/JS — RLS חייב למנוע. |
| ROLE-08 | Badge בסיידבר | מציג מספר בקשות שהמשתמש יכול לאשר. אפס → לא מציג. |

### 6.7 ניהול משתמשים (OWNER)
| # | תרחיש | תוצאה צפויה |
|---|---|---|
| MGR-01 | רשימה מלאה | כל המשתמשים מוצגים. |
| MGR-02 | הקפאה | `is_frozen=true` נשמר. בכניסה הבאה של המשתמש — alert + ניתוק. |
| MGR-03 | ביטול הקפאה | `is_frozen=false`, המשתמש חוזר לתפקד. |

### 6.8 Realtime
| # | תרחיש | תוצאה צפויה |
|---|---|---|
| RT-01 | משתמש A פותח תקלה, B צופה ברשימה | תוך ≤1 שנייה, אצל B מופיע toast + הרשימה מתעדכנת. |
| RT-02 | A מעלה תגובה במסך פרטים שגם B פתוח עליו | תגובה מופיעה אצל B חיה ללא רענון. |
| RT-03 | A מתחיל לפתוח תקלה, B מעדכן תקלה אחרת | אצל A לא קופץ toast/refresh (`activePage='CREATE'`). |
| RT-04 | רשת לא יציבה | המערכת ממשיכה לעבוד, ערוצי realtime מתחברים מחדש אוטומטית. |

### 6.9 התראות
| # | תרחיש | תוצאה צפויה |
|---|---|---|
| NOTIF-01 | פתיחת תקלה רגילה | push יוצא לכל המשתמשים שמוגדרים כרלוונטיים. |
| NOTIF-02 | פתיחת חמ"ל מושבת | push עם כותרת מיוחדת "🚨 חמ״ל מושבת!". |
| NOTIF-03 | תקלה שעוברת SLA (settings.notifyOverdue) | התראת דפדפן מקומית למנהל. |
| NOTIF-04 | אישור Notifications לא ניתן | אין crash. |

### 6.10 PWA / Service Worker
| # | תרחיש | תוצאה צפויה |
|---|---|---|
| PWA-01 | התקנת אפליקציה | Chrome/Edge מציג כפתור התקנה. |
| PWA-02 | הפעלה בלי רשת | מסך login נטען מ-SW cache (אם הוגדר). |
| PWA-03 | רענון אחרי פריסה חדשה | SW מעודכן מבלי לשבור session. |

### 6.11 UI/UX אופקיים
| # | תרחיש | תוצאה צפויה |
|---|---|---|
| UI-01 | רוחב <900px | sidebar הופך לתחתון, FAB מופיע, padding מותאם. |
| UI-02 | מקלדת iOS | inputs ≥16px (אין auto-zoom). |
| UI-03 | RTL | כל הכיוונים נכונים. אין טקסט "חתוך" משמאל. |
| UI-04 | מצב כהה של מערכת ההפעלה | אין רגרסיות עיצוב (גרסת Aurora היא בהירה במכוון). |
| UI-05 | אנימציית כניסת עמוד | `page-animate` עובד בלי טלטולים. |
| UI-06 | Toast | נעלם אחרי 3 שניות, לא חוסם UI. |
| UI-07 | Modal | סגירה ב-click מחוץ. |
| UI-08 | Lucide icons | כל האייקונים נטענים (אם לא — fallback ריק לא שובר layout). |

### 6.12 אבטחה
| # | תרחיש | תוצאה צפויה |
|---|---|---|
| SEC-01 | XSS דרך כותרת תקלה | `<script>alert(1)</script>` בכותרת לא מתבצע (escape). |
| SEC-02 | XSS דרך תגובה | אותו דבר. |
| SEC-03 | URL attachment `javascript:` | `safeUrl()` מחזיר `#`, אין execution. |
| SEC-04 | API קריאה ישירה כמשתמש מוקפא | RLS חוסם UPDATE/INSERT. |
| SEC-05 | קריאת `tickets` של יחידה אחרת | RLS מסנן. |
| SEC-06 | טוקן Worker | Worker בודק את ה-JWT של Supabase, לא סוד קבוע. |

---

## 7. נתונים לדוגמה לבדיקות

מומלץ ליצור משתמשי בדיקה:

| שם | תפקיד | is_manager | יחידה | הערה |
|---|---|---|---|---|
| `qa-owner@test` | OWNER | true | חטיבת שומרון | רואה הכל |
| `qa-hr-mgr@test` | HR | true | חטיבת שומרון | מאשר בקשות מש"א |
| `qa-hr-user@test` | HR | false | פלוגה ב' | מטפל בלי לאשר תפקידים |
| `qa-hatap@test` | HATAP | false | פלוגה ב' | פותח תקלות לעצמו |
| `qa-mamram@test` | MAMRAM | false | מטה | מטפל בתקלות מחשב |
| `qa-hamal@test` | HAMAL | false | חמ"ל א' | משתמש קצה |
| `qa-pending@test` | HAMAL | false | פלוגה ב' | `requested_role=HR` ממתין |
| `qa-frozen@test` | HAMAL | false | פלוגה ב' | `is_frozen=true` |

נתוני תקלות מומלצים: לפחות תקלה אחת בכל סטטוס + תקלת חמ"ל פתוחה + תקלה סגורה.

---

## 8. מגבלות ידועות / Out of scope

- אין rate-limiting בצד הלקוח על פתיחת תקלות.
- אין הגבלת גודל קובץ בצד הלקוח. תלוי בהגבלות bucket.
- Welcome animation קיים רק ב-`index.html` (לא ב-`index-aurora.html`).
- Push Notifications דורש HTTPS + הרשמת Service Worker; בסביבת dev מקומית (HTTP) חלק מהפונקציונליות לא יפעל.
- חיפוש לא תומך ב-stemming עברי.
- היסטוריית טיפול בתקלה (timeline) קלילה — לא רושמת כל עדכון בנפרד אלא משחזרת מהמצב הנוכחי.

---

## 9. הוראות הרצה לבודק

### מקומי (Windows)
```powershell
cd "D:\ticket project\yanai ticketing"
npx serve -p 3344 .
# Open http://localhost:3344/index-aurora.html
```

### בענן
לפתוח ישירות את כתובת ה-deployment (Cloudflare Pages / Netlify / Supabase Hosting — לפי הסביבה הפרודקשן).

### חשבונות בדיקה
לפנות למנהל המערכת או לבעלים כדי לקבל credentials.

### Reset state
דרך לוח Supabase: `truncate tickets, ticket_comments` + מחיקת משתמשי בדיקה מ-`auth.users`.

---

## 10. דיווח באגים — תבנית

```
כותרת:
תאריך/שעה:
דפדפן + גרסה:
מכשיר (Desktop / iPhone / Android):
משתמש בדיקה (email + תפקיד):
מסך שבו אירע:
שלבים לשחזור:
  1.
  2.
תוצאה בפועל:
תוצאה צפויה:
צילום מסך / וידאו:
לוג קונסול (F12 → Console):
חומרה (Blocker / Major / Minor / Cosmetic):
```

---

*נכתב: 2026‑06‑14 · יוצר המסמך: Claude*
