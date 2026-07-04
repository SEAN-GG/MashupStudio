# איך מעלים את סטודיו מיקס ל-TestFlight — מדריך צעד-אחר-צעד

הקוד וה-CI כבר מוכנים. מה שנשאר הוא החלק שרק בעל חשבון Apple יכול לעשות.
סה"כ ~30–40 דקות עבודה + המתנה לאישור של Apple.

## שלב 1: הרשמה ל-Apple Developer Program (חד-פעמי, 99$ לשנה)

1. היכנס ל-https://developer.apple.com/programs/enroll עם ה-Apple ID שלך
   (אותו אחד של האייפון).
2. בחר הרשמה כ-**Individual** (יחיד).
3. שלם 99$ לשנה. **האישור לוקח בדרך כלל מכמה שעות עד 48 שעות** — תקבל מייל.

בלי זה אי אפשר להעלות ל-TestFlight, אין דרך לעקוף.

## שלב 2: יצירת מפתח API של App Store Connect

אחרי שההרשמה אושרה:

1. היכנס ל-https://appstoreconnect.apple.com
2. לך ל-**Users and Access** → לשונית **Integrations** → **App Store Connect API**.
3. אם זו הפעם הראשונה — לחץ **Request Access** ואשר.
4. תחת **Team Keys** לחץ **+** (Generate API Key):
   - Name: `github-actions`
   - Access: **App Manager**
5. לחץ **Download API Key** — יורד קובץ `AuthKey_XXXXXXXXXX.p8`.
   **אפשר להוריד אותו רק פעם אחת — שמור אותו!**
6. רשום לעצמך מהדף הזה:
   - **Key ID** (למשל `A1B2C3D4E5`)
   - **Issuer ID** (מחרוזת ארוכה עם מקפים, מופיעה למעלה)

## שלב 3: מציאת ה-Team ID

1. היכנס ל-https://developer.apple.com/account
2. גלול ל-**Membership details** — שם מופיע **Team ID** (10 תווים, למשל `ABCDE12345`).

## שלב 4: יצירת האפליקציה ב-App Store Connect

1. ב-https://appstoreconnect.apple.com לך ל-**My Apps** → **+** → **New App**.
2. מלא:
   - Platform: **iOS**
   - Name: `סטודיו מיקס` (או כל שם — חייב להיות ייחודי בחנות; אם תפוס נסה
     למשל `סטודיו מיקס של שון`)
   - Primary Language: Hebrew
   - Bundle ID: בחר **`com.seanyehezkel.mashupstudio`**
     - אם הוא לא מופיע ברשימה: היכנס ל-
       https://developer.apple.com/account/resources/identifiers/list →
       **+** → App IDs → App → Description: `Mashup Studio`,
       Bundle ID (Explicit): `com.seanyehezkel.mashupstudio` → Register.
       ואז חזור ל-App Store Connect ובחר אותו.
   - SKU: `mashupstudio1` (כל מחרוזת)
   - User Access: Full Access
3. Create. (לא צריך למלא שום דבר נוסף בדף האפליקציה בשביל TestFlight פנימי.)

## שלב 5: הוספת הסודות ל-GitHub

יש שתי דרכים — הקלה ביותר: תגיד לי (ל-Claude) שהשלמת את השלבים, תשים את
קובץ ה-`.p8` בתיקייה מוכרת, ואני אריץ את הפקודות בשבילך. או ידנית:

היכנס לריפו ב-GitHub → **Settings** → **Secrets and variables** → **Actions**
→ **New repository secret**, וצור 4 סודות:

| שם הסוד | ערך |
|---|---|
| `ASC_KEY_ID` | ה-Key ID משלב 2 |
| `ASC_ISSUER_ID` | ה-Issuer ID משלב 2 |
| `ASC_KEY_P8` | כל התוכן של קובץ ה-p8 (פתח בפנקס רשימות, העתק הכול כולל השורות BEGIN/END) |
| `APPLE_TEAM_ID` | ה-Team ID משלב 3 |

או מהטרמינל עם gh (מהתיקייה של הפרויקט):

```
gh secret set ASC_KEY_ID --body "A1B2C3D4E5"
gh secret set ASC_ISSUER_ID --body "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
gh secret set APPLE_TEAM_ID --body "ABCDE12345"
gh secret set ASC_KEY_P8 < "C:\path\to\AuthKey_XXXXXXXXXX.p8"
```

## שלב 6: הרצת ההעלאה

1. בריפו ב-GitHub → לשונית **Actions** → workflow בשם **TestFlight** →
   **Run workflow** → Run.
   (או מהטרמינל: `gh workflow run testflight.yml`)
2. ההרצה לוקחת ~15–25 דקות. בסופה הבילד עולה ל-App Store Connect.
3. Apple מעבדת את הבילד עוד ~5–30 דקות (תקבל מייל "has completed processing").

## שלב 7: התקנה על האייפון

1. ב-App Store Connect → האפליקציה → לשונית **TestFlight**.
2. אם מופיעה שאלה על Export Compliance — כבר מוגדר בקוד שאין הצפנה, אבל אם
   נשאל: ענה **None of the algorithms mentioned above** / No.
3. תחת **Internal Testing** לחץ **+** ליד Testers וצור קבוצה (למשל `me`),
   והוסף את עצמך (ה-Apple ID שלך).
4. באייפון: הורד את אפליקציית **TestFlight** מה-App Store.
5. תקבל מייל הזמנה → פתח אותו באייפון → Accept → Install.

זהו! מעכשיו כל פעם שמריצים את ה-workflow עולה גרסה חדשה, ו-TestFlight
באייפון יציע לעדכן.

## בעיות נפוצות

- **"No profiles / provisioning" בשלב Archive** — ודא שה-API Key בהרשאת
  **App Manager** ושה-`APPLE_TEAM_ID` נכון.
- **"The provided entity includes an attribute with a value that has already
  been used" בהעלאה** — כנראה כבר יש בילד עם אותו מספר; פשוט הרץ שוב את
  ה-workflow (המספר עולה אוטומטית).
- **הבילד לא מופיע ב-TestFlight** — חכה למייל העיבוד; לפעמים לוקח חצי שעה.
