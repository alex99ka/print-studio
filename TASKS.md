# מה נשאר

## עליך

(יתווספו כשהקוד מוכן: פרויקט Firebase, לקוחות OAuth, מפתח חתימה, סודות GitHub, פריסה ל-Pi.)

## אצל Claude — בנייה ראשונה (MVP)

החלטות: `CLAUDE.md` (נסגרו 25.10.2026, לא לשאול שוב). עיצוב מאושר: פלטה A,
https://claude.ai/artifact/XGArLBxz3caJm9xYcBRFaf

1. ✅ שרת: `server/app/studio.py` (העלאת גרסאות, מפתח Flag Maker, פורטל לקוח,
   הערות עם נעיצה, אישור בצעד אחד), `static/portal.html`, כללי Firestore, גיבוי
   קבצים ל-Drive, בדיקות (שרת מול אמולטור, כללים).
2. אפליקציה (Flutter): פלטה A ב-`lib/ui/theme.dart`; לשוניות עליונות כמו Word
   (בית · לקוחות · הגדרות) + רצועת כלים; בקשות (רשימה + פרטים: 2D עם נעיצות,
   גרסאות, הצעת מחיר עם מע״מ, הערות, פרסום, וואטסאפ, תצוגה בדפדפן); לקוחות
   (קישור פורטל, החלפת קישור); העלאת גרסה ידנית; Windows: פתיחה ב-Bambu,
   פתיחה ב-Flag Maker, צימוד Flag Maker. התראות מסוג `client`, ייצוא, סיור,
   ווידג'טים.
3. Flag Maker (`C:\claude projects\3d`): "שליחה ל-CRM" (3MF + PNG + מתכון +
   GLB לוח ו-GLB מורכב), טעינת מתכון מ-CRM (`--crm-version`), בדיקות קבלה
   ואריזה לפי ה-AGENTS.md שלו.
4. README, COMMANDS, CHANGELOG, סיור, אייקון.
