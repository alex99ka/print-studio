# מה נשאר

## עליך

לפי הסדר (README › Start a new app, שלבים 1–5). הקוד מוכן ונבדק; בלי אלה
האפליקציה לא מתחברת לשום דבר.

1. **פרויקט Firebase** (Spark, חינם): `firebase.cmd projects:create print-studio-<משהו>`.
   בקונסול: Authentication › Google; Firestore (me-west1). רושמים אפליקציית Web
   ו-Android ושולחים לי את ה-config (ציבורי, לא סוד) — אני ממלא את
   `lib/firebase_options.dart` ו-`web/firebase-messaging-sw.js`.
2. ב-Firestore יוצרים ידנית: `config/access` = `{emails: ["alex99ka@gmail.com", "alex98ka@gmail.com"], earlyUsers: ["alex99ka@gmail.com"]}`
   ו-`config/app` = `{minVersion: "0.0.0"}`. אחר כך: `firebase.cmd deploy --only firestore:rules --project <id>`.
3. **לקוחות OAuth** (Google Cloud › Credentials): מזהה ה-Web client, ולקוח
   חדש מסוג Desktop app ל-Windows.
4. **מפתח חתימה** (`keytool` ב-README שלב 4) ב-`~/.keystores/print-studio.p12`,
   **וגיבוי שלו ל-Drive מיד**.
5. **ריפו ב-GitHub** `alex99ka/print-studio` (ציבורי) + הסודות והמשתנים מ-README שלב 5.
6. **Pi**: `mkdir -p ~/docker/print-studio/data`, `.env` (GOOGLE_CLOUD_PROJECT,
   GITHUB_REPO, APP_NAME=סטודיו הדפסה, PORT=8010, טלגרם מה-.env של אפליקציה
   אחרת), מפתח שירות (Datastore User + FCM Admin) ב-`data/service-account.json`.
   החלטה: איך לפרסם ב-Funnel — 8443 תפוס ע״י וירמשולקה. אפשרות: נתיב
   (`--set-path /print-studio`) על אותו פורט.
7. אחרי שהשרת עולה: בהגדרות ה-CRM › "חיבור ה-Flag Maker", ומדביקים כתובת
   ומפתח ב-Flag Maker › Send to CRM.

## אצל Claude

1. ✅ שרת, פורטל, כללים, גיבוי קבצים, בדיקות (שרת 15, כללים 12).
2. ✅ אפליקציה: פלטה A, לשוניות + רצועה, בקשות, לקוחות, מחירים, הערות, PC
   (Bambu, Flag Maker). בדיקות 20. **לא נבדק עדיין על מסך** — צריך Firebase
   (שלב 1 אצלך). אז: הרצה ב-Windows ובטלפון, צילומי מסך, תיקונים.
3. ✅ קוד ב-Flag Maker (`3d/app/crm_link.py`, כפתור Send to CRM,
   `--crm-version`). נבדק מקצה לקצה מול שרת מקומי: ייצוא אמיתי של Bambu,
   GLB לוח + מורכב, העלאה v1/v2, מתכון חוזר, ובדפדפן: 2D/3D/על המיקרופון,
   נעיצה בתלת-ממד, אישור, אנגלית. **לא נעשה commit בריפו של 3d ולא נבנתה
   גרסה 5.6.0** — אחרי שהשרת חי: בדיקות הקבלה של ה-Flag Maker ואריזה.
4. אחרי Firebase: אייקון, גרסה ראשונה (tag) על הטלפון, עדכון שני לבדיקת
   עדכון מתוך האפליקציה, ניטור Uptime Kuma ל-`/health`, דף פרטיות.

## אחרי ה-MVP (לא נבנה, להחליט)

- צירוף תמונה להערה מהפורטל (בעיצוב היה כפתור; לא נבנה).
- כניסת לקוח עם Google (במקום קישור בלבד).
- חיפוש ברשימת הבקשות; פתיחה מחדש של בקשה מאושרת.
