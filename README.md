# TOCFL Writer 漢字練習

A local-first Flutter app for **practicing Hanzi writing** based on the TOCFL vocabulary list (華語八千詞表). Dark theme, orange accent, landscape-first layout, smooth canvas stroke engine — no internet required.

---

## Features

- **Local SQLite database** — all 7 776 TOCFL entries, offline
- **Search** by character or pinyin with debounce
- **Filter** by level (準備級 → 流利級) and topic/context
- **Random word** button for free practice
- **Handwriting canvas** with 米-grid, dashed diagonals, ink-glow strokes
- **Undo / Redo / Clear** per stroke
- **Landscape-first** layout (search+list left, practice right)
- **Portrait** layout with tab switcher
- **Favorites** and **Recent practiced** words stored locally
- Clean dark theme: `#080705` background, `#FF4A00` orange accent

---

## Project Structure

```
tocfl_writer/
├── lib/
│   ├── main.dart        # Entry point, providers, orientation
│   ├── app.dart         # All UI widgets, theme, layout, canvas widget
│   └── logic.dart       # Models, DB service, AppState, CanvasState, Painter
├── assets/
│   └── db/
│       └── tocfl_vocab_clean.db   # ← place your SQLite database here
├── .github/
│   └── workflows/
│       └── ios_unsigned_ipa.yml
├── pubspec.yaml
└── README.md
```

---

## Getting Started

### 1. Prerequisites

- Flutter SDK ≥ 3.22 (stable)
- Dart ≥ 3.0
- Android Studio / Xcode for device builds

### 2. Place the database

Copy your SQLite database file to:

```
assets/db/tocfl_vocab_clean.db
```

The app will automatically copy it to the device's documents directory on first launch.

### 3. Install dependencies

```bash
flutter pub get
```

### 4. Run on device / simulator

```bash
# Android
flutter run --release

# iOS simulator
flutter run --release -d "iPhone 15 Pro"
```

### 5. Build Android APK

```bash
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

### 6. Build iOS (requires macOS + Xcode)

```bash
flutter build ios --release
# Then open ios/Runner.xcworkspace in Xcode to archive & export
```

---

## Database Schema

Table: `vocab_clean`

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER PK | Auto-increment |
| source_id | INTEGER | Original row ID |
| sheet_name | TEXT | Excel sheet name (e.g. 入門級) |
| level_code | TEXT | Normalized level (e.g. Level 1) |
| context | TEXT | Topic/domain (e.g. 個人資料) |
| vocabulary | TEXT | The Hanzi character/word |
| pinyin | TEXT | Tone-marked pinyin |
| part_of_speech | TEXT | POS code (N, V, …) |
| bopomofo | TEXT | Zhuyin if present |
| variant_group | TEXT | Slash-separated variant group |

---

## GitHub Actions — Build Unsigned IPA

The workflow at `.github/workflows/ios_unsigned_ipa.yml` builds an **unsigned IPA** on every push to `main`.

### How it works

1. Checks out code on a `macos-latest` runner
2. Sets up Flutter stable
3. Runs `flutter pub get`
4. Creates `ios/` platform if missing (`flutter create --platforms=ios .`)
5. Runs `pod install`
6. Builds: `flutter build ios --release --no-codesign`
7. Packages: `Payload/Runner.app` → zipped → `TocflWriter-unsigned.ipa`
8. Uploads as a **GitHub Actions artifact** (retained 30 days)

### Download the IPA

1. Go to your repository on GitHub
2. Click **Actions** tab
3. Open the latest **"Build iOS Unsigned IPA"** workflow run
4. Scroll to **Artifacts** section at the bottom
5. Download **TocflWriter-unsigned-ipa.zip**
6. Unzip to get `TocflWriter-unsigned.ipa`

### Install via eSign (no Apple Developer account needed)

1. Download `TocflWriter-unsigned.ipa` to your computer
2. Open **eSign** app on your iPhone (available via web install from esign.yyyue.xyz or similar sources)
3. In eSign → **Import** → select the `.ipa` file (via Files app, AirDrop, or eSign's built-in browser)
4. Tap the imported app → **Sign** → choose a certificate (eSign provides free self-sign certificates)
5. Tap **Install** → trust the certificate in **Settings → General → VPN & Device Management**
6. Launch **TOCFL Writer** 

> **Note**: Self-signed apps via eSign may require re-signing every 7 days with a free certificate, or less frequently with a paid one. This is a limitation of iOS, not the app.

---

## License

MIT — free to use, modify, and distribute.
