# پلن ساخت فایل منیجر شخصی برای macOS

> نکته: اسم ریپو «iOS File Manager» است، ولی هدف جایگزینی Finder روی مک‌بوک است، پس اپ **macOS** می‌سازیم. اگر بعداً نسخه‌ی iPhone/iPad هم خواستیم، لایه‌ی Core (منطق فایل‌ها) را طوری می‌نویسیم که قابل اشتراک باشد.

---

## ۱. تکنولوژی پیشنهادی

| بخش | انتخاب | دلیل |
|---|---|---|
| زبان | **Swift 6** | زبان بومی اپل، سریع، دسترسی کامل به APIهای سیستم |
| رابط کاربری | **SwiftUI + AppKit** | SwiftUI برای پنجره‌ها، سایدبار و تنظیمات؛ `NSTableView`/`NSOutlineView` (AppKit) برای لیست فایل‌ها چون با پوشه‌های ده‌هزار فایلی خیلی سریع‌تر از SwiftUI است |
| حداقل نسخه | **macOS 14 (Sonoma)** | APIهای جدید SwiftUI و `@Observable` |
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

### فاز ۱ — MVP: مرور فایل‌ها (۱–۲ هفته)
- [ ] پنجره با **سایدبار** (Home، Desktop، Downloads، Documents، Applications، دیسک‌های متصل)
- [ ] **List view** با ستون‌های Name / Size / Kind / Date Modified، مرتب‌سازی با کلیک روی ستون
- [ ] ناوبری: دابل‌کلیک، Back/Forward، Enclosing folder (`⌘↑`)، **Path bar**
- [ ] باز کردن فایل با اپ پیش‌فرض (`NSWorkspace`)
- [ ] نمایش/مخفی کردن فایل‌های hidden (`⌘⇧.`)
- [ ] به‌روزرسانی زنده با FSEvents

**خروجی فاز ۱:** اپی که بتوانی هر روز برای مرور فایل‌ها به جای Finder باز کنی.

### فاز ۲ — عملیات روی فایل‌ها (۱–۲ هفته)
- [ ] New Folder، Rename (inline)، Duplicate
- [ ] Copy / Cut / Paste (`⌘C` / `⌘X` / `⌘V`) — بله، **Cut واقعی** که Finder ندارد
- [ ] Move to Trash، Delete Immediately (با تأیید)
- [ ] Drag & Drop داخل اپ و با اپ‌های دیگر
- [ ] صف عملیات با **progress bar**، توقف، و ادامه
- [ ] Undo / Redo
- [ ] منوی راست‌کلیک (Context menu)، Open With، Show in Terminal، Copy Path

### فاز ۳ — بهتر از Finder (۲–۳ هفته)
این‌ها همان دلایلی هستند که از Finder راضی نیستی — اولویتشان را خودت مشخص کن:
- [ ] **Tabs** و **حالت دو پنله (Dual Pane)** مثل Total Commander
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
1. **چه چیزی در Finder بیشتر از همه اذیتت می‌کند؟** (مثلاً نبودن Cut، نبودن dual-pane، کند بودن، سایز پوشه‌ها، ...) — این اولویت فاز ۳ را مشخص می‌کند.
2. ظاهر: شبیه Finder (بومی macOS) یا سبک Total Commander/Commander One (کیبوردمحور، دو پنله)؟
3. نسخه‌ی macOS مک‌بوکت چیست؟ (برای تعیین حداقل نسخه)
4. نسخه‌ی iPhone/iPad هم در آینده می‌خواهی یا فقط مک؟

بعد از جواب این سؤال‌ها، فاز ۰ و ۱ را شروع می‌کنیم.
