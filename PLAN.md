# پلن ساخت فایل منیجر شخصی برای macOS

> نکته: اسم ریپو «iOS File Manager» است، ولی هدف جایگزینی Finder روی مک‌بوک است، پس اپ **فقط برای macOS** ساخته می‌شود (نسخه‌ی iPhone/iPad در برنامه نیست).

## هدف اصلی
مشکل اصلی با Finder: **کپی، کات و پیست سخت و پردردسر است** و کار با فایل‌ها روان نیست.
پس اولویت شماره‌ی یک این اپ:
- **Cut واقعی**: `⌘X` روی فایل، بعد `⌘V` در مقصد → فایل منتقل می‌شود (بدون ترفند `⌘⌥V` در Finder).
- **کپی/پیست ساده و قابل پیش‌بینی**: هم با کیبورد، هم با راست‌کلیک، هم با دکمه‌ی تولبار.
- **نشانگر کلیپبورد**: همیشه ببینی چه فایل‌هایی کپی/کات شده‌اند و بتوانی لغوش کنی.
- **دو پنل کنار هم**: فایل را از یک پنل به پنل دیگر بکشی یا با یک کلید (`F5` کپی، `F6` انتقال) جابه‌جا کنی.
- **مدیریت تداخل نام واضح**: جایگزین کن / هر دو را نگه دار / رد کن — برای همه یکجا.

---

## ۱. تکنولوژی پیشنهادی

| بخش | انتخاب | دلیل |
|---|---|---|
| زبان | **Swift 6** | زبان بومی اپل، سریع، دسترسی کامل به APIهای سیستم |
| رابط کاربری | **SwiftUI + AppKit** | SwiftUI برای پنجره‌ها، سایدبار و تنظیمات؛ `NSTableView`/`NSOutlineView` (AppKit) برای لیست فایل‌ها چون با پوشه‌های ده‌هزار فایلی خیلی سریع‌تر از SwiftUI است |
| حداقل نسخه | **macOS 14 (Sonoma)** (قابل تغییر بر اساس نسخه‌ی مک‌بوک تو) | APIهای جدید SwiftUI و `@Observable` |
| فایل‌سیستم | `FileManager`، `URL resourceValues`، `FSEvents` | خواندن متادیتا و تشخیص تغییرات زنده |
| پیش‌نمایش | `QuickLookThumbnailing` و `QLPreviewPanel` | thumbnail و Quick Look مثل Finder |
| جستجو | `NSMetadataQuery` (Spotlight) + جستجوی مستقیم | جستجوی سریع در کل دیسک |
| ساخت پروژه | Xcode + **Swift Package** برای ماژول Core | تست‌پذیری و جداسازی منطق از UI |
| CI | GitHub Actions (runner مک) | build و تست خودکار روی هر push |

> **Sandbox:** چون اپ شخصی است و در App Store منتشر نمی‌شود، App Sandbox را **خاموش** می‌کنیم تا به همه‌ی فایل‌ها دسترسی کامل داشته باشیم. فقط لازم است یک بار در System Settings → Privacy & Security → **Full Disk Access** به اپ اجازه بدهیم.

---

## ۲. معماری

```
FileManagerApp (macOS App target)
├── UI/                 ← SwiftUI views + AppKit wrappers
│   ├── Sidebar         (Favorites، دیسک‌ها، تگ‌ها)
│   ├── Browser         (List / Icon / Column view)
│   ├── Toolbar & PathBar
│   ├── Inspector       (اطلاعات فایل، preview)
│   └── Settings
└── ViewModels/         ← وضعیت هر تب/پنجره

FileCore (Swift Package — بدون وابستگی به UI)
├── FileSystemService   (list, copy, move, rename, trash, delete)
├── DirectoryWatcher    (FSEvents)
├── FileOperationQueue  (کارهای طولانی با progress و cancel و undo)
├── SearchService
├── ThumbnailService    (cache)
└── Models              (FileItem, Volume, Tag, ...)
```

اصول:
- **هیچ عملیات فایل روی main thread اجرا نمی‌شود** (async/await + actors).
- همه‌ی عملیات‌های مخرب از **Undo** پشتیبانی می‌کنند و «حذف» پیش‌فرض یعنی انتقال به Trash.
- FileCore تست واحد (unit test) کامل دارد، روی پوشه‌های موقت.

---

## ۳. فازهای پروژه

### فاز ۰ — راه‌اندازی (۱–۲ روز)
- [ ] ساخت پروژه‌ی Xcode (macOS App) + Swift Package به اسم `FileCore`
- [ ] `.gitignore`، README، SwiftLint/SwiftFormat
- [ ] GitHub Actions برای build و تست
- [ ] خاموش کردن Sandbox و تست Full Disk Access

### فاز ۱ — MVP: مرور فایل‌ها + کپی/کات/پیست (۲–۳ هفته)
- [ ] پنجره با **سایدبار** (Home، Desktop، Downloads، Documents، Applications، دیسک‌های متصل)
- [ ] **List view** با ستون‌های Name / Size / Kind / Date Modified، مرتب‌سازی با کلیک روی ستون
- [ ] ناوبری: دابل‌کلیک، Back/Forward، Enclosing folder (`⌘↑`)، **Path bar**
- [ ] باز کردن فایل با اپ پیش‌فرض (`NSWorkspace`)
- [ ] نمایش/مخفی کردن فایل‌های hidden (`⌘⇧.`)
- [ ] به‌روزرسانی زنده با FSEvents
- [ ] **Copy / Cut / Paste** (`⌘C` / `⌘X` / `⌘V`) با Cut واقعی — مهم‌ترین قابلیت
- [ ] نشانگر کلیپبورد در پایین پنجره (چه چیزی کپی/کات شده + دکمه‌ی لغو)
- [ ] فایل‌های کات‌شده کم‌رنگ نمایش داده شوند تا معلوم باشد منتقل خواهند شد
- [ ] پنجره‌ی تداخل نام (Replace / Keep Both / Skip، با گزینه‌ی «برای همه»)
- [ ] Undo برای پیست و انتقال (`⌘Z`)

**خروجی فاز ۱:** اپی که بتوانی هر روز به جای Finder باز کنی و جابه‌جا کردن فایل‌ها در آن راحت باشد.

### فاز ۲ — عملیات روی فایل‌ها (۱–۲ هفته)
- [ ] New Folder، Rename (inline)، Duplicate
- [ ] Move to Trash، Delete Immediately (با تأیید)
- [ ] Drag & Drop داخل اپ و با اپ‌های دیگر
- [ ] صف عملیات با **progress bar**، توقف، و ادامه
- [ ] Redo و تاریخچه‌ی کامل Undo
- [ ] منوی راست‌کلیک (Context menu)، Open With، Show in Terminal، Copy Path

### فاز ۳ — بهتر از Finder (۲–۳ هفته)
این‌ها همان دلایلی هستند که از Finder راضی نیستی — اولویتشان را خودت مشخص کن:
- [ ] **حالت دو پنله (Dual Pane)** با `F5`/`F6` برای کپی/انتقال بین پنل‌ها — اولویت اول این فاز
- [ ] **Tabs**
- [ ] **Icon view** و **Column view**
- [ ] **Quick Look** با Space و پنل Inspector
- [ ] **محاسبه‌ی سایز پوشه‌ها** در List view
- [ ] **جستجوی سریع** (فیلتر لحظه‌ای داخل پوشه + جستجوی Spotlight)
- [ ] **Command Palette** (`⌘K`) برای همه‌ی دستورها
- [ ] **Batch rename** (با الگو، شماره‌گذاری، regex)
- [ ] میانبرهای کیبورد قابل تنظیم، ناوبری کامل با کیبورد (حتی Vim-style)
- [ ] ترمینال جاسازی‌شده یا «Open Terminal Here»
- [ ] نمایش فضای آزاد دیسک در status bar

### فاز ۴ — قابلیت‌های پیشرفته (اختیاری)
- [ ] فشرده‌سازی/باز کردن zip و غیره
- [ ] Tags و رنگ‌ها (سازگار با تگ‌های Finder)
- [ ] اتصال به سرور: SFTP / SMB / S3
- [ ] مقایسه و همگام‌سازی پوشه‌ها
- [ ] پیدا کردن فایل‌های تکراری و تحلیل فضای دیسک
- [ ] Git status کنار فایل‌ها در پوشه‌های پروژه
- [ ] تم‌ها، Dark mode، و پشتیبانی از نام‌های فارسی/راست‌چین

### فاز ۵ — پایداری و توزیع
- [ ] تست روی پوشه‌های بزرگ (۱۰۰ هزار فایل)، پروفایل با Instruments
- [ ] Code signing با Apple ID (یا اجرای محلی بدون امضا)
- [ ] ساخت `.app`/`.dmg` در GitHub Releases
- [ ] (اختیاری) آپدیت خودکار با Sparkle
- [ ] (اختیاری) تنظیم به‌عنوان فایل منیجر پیش‌فرض برای «Reveal in Finder» تا جای ممکن

---

## ۴. پیش‌نیازها برای تو
1. یک مک با **Xcode** نصب‌شده (از App Store) — build و اجرای اپ macOS فقط روی مک ممکن است.
2. Apple ID رایگان برای امضای محلی کافی است؛ عضویت پولی Developer Program فقط برای notarization و توزیع عمومی لازم است.
3. کد را من در این ریپو می‌نویسم و push می‌کنم؛ تو روی مک `git pull` می‌کنی، در Xcode باز می‌کنی و `⌘R` می‌زنی. CI هم روی GitHub مطمئن می‌شود که build سالم است.

---

## ۵. سؤال‌هایی که باید جواب بدهی
1. ~~چه چیزی در Finder بیشتر از همه اذیتت می‌کند؟~~ ✅ کپی/کات/پیست سخت و پردردسر است → اولویت اول.
2. ظاهر: شبیه Finder (بومی macOS) یا سبک Total Commander/Commander One (کیبوردمحور، دو پنله)؟
3. نسخه‌ی macOS مک‌بوکت چیست؟ (برای تعیین حداقل نسخه)
4. ~~نسخه‌ی iPhone/iPad هم می‌خواهی؟~~ ✅ نه، فقط مک‌بوک.

بعد از جواب این سؤال‌ها، فاز ۰ و ۱ را شروع می‌کنیم.
