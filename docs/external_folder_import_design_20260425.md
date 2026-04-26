# 外部フォルダ参照型インポート + Mac DL 保存先選択 設計書

**作成日時**: 2026-04-25 22:xx (本ファイル作成時刻)
**対象**: Cort:EX (EhViewer.xcodeproj)
**対象 OS**: Mac Catalyst 先行 (iPhone は後フェーズ)
**ステータス**: 設計検討中、実装未着手
**シェイクスピア定理遵守**: 本設計書は Phase 1 (URL 共有) を破壊しない。コード変更は田中の OK 後。

---

## 0. 背景と田中構想

- 田中の NAS 構想: HDD 届いたら M2 Air NAS 化、iPhone は容量を食わずに NAS HDD の作品を閲覧
- 現状の `.cortex` import (3 月実装) は **コピー型** = NAS 蓄積のメリットが消える
- 必要: NAS の HDD 容量だけを使い、Cort:EX 側ストレージは消費しない **参照型**
- 同時に Mac 側でユーザが DL 保存先 (= NAS HDD のフォルダ) を指定できる必要がある

両機能は「外部 directory への security-scoped bookmark 永続化 + 読み書き経路抽象化」という共通基盤で実装可能。

---

## 1. 要件

### 1A. 外部フォルダ参照型インポート
- ユーザが指定したフォルダパスの永続化 (security-scoped bookmark を `UserDefaults` に保存)
- フォルダ配下のサブフォルダを「作品」として認識 (1 サブフォルダ = 1 gallery)
- 画像ファイルはコピーせず、参照 URL のみ保持
- リーダー再生時にフォルダから直接ストリーミング読込
- 既存 DL (内部ストレージ) と並列共存、UI で区別可能

### 1B. Mac DL 保存先選択
- 初回 DL 時 or 設定画面から folder picker を提示し、保存先 directory を選択
- 選択先を security-scoped bookmark で永続化
- 以降の DL は選択先 directory に出力
- **Mac Catalyst のみ** (`#if targetEnvironment(macCatalyst)` で隔離、iPhone コードは無変更)

---

## 2. スコープと段階分け

### Phase E1 (今回設計対象、Mac Catalyst のみ)
- 1B (DL 保存先選択) 実装
- 1A (外部フォルダ参照型インポート) 実装
- iPhone は完全無変更 (`#if !targetEnvironment(macCatalyst)` 内に閉じ込める)

### Phase E2 (後フェーズ、本設計書のスコープ外)
- iPhone 側で SMB マウント済 Files.app provider 経由のフォルダ参照
- iOS では `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])` で取得した URL を使う
- iPhone での性能 (SMB 越し WebP 読込) 検証必要

---

## 3. UI 設計

### 3-1. 「ライブラリ」タブ (旧「保存済み」)

**タブ改名 (Mac/iPhone 両方)**:
- 既存の「保存済み」タブを **「ライブラリ」** に改名
- `ContentView.swift:313` の `.tabItem { Label("保存済み", systemImage: "arrow.down.circle.fill") }` の文字列変更
- アイコンは `arrow.down.circle.fill` → `books.vertical.fill` 等への変更も検討 (改名に合わせる、田中の確認待ち)
- iPhone も Mac も同じ「ライブラリ」名で統一 (UI 名称の対称性確保)

**機能差異 (Mac のみ拡張)**:

iPhone (現状維持、改名のみ):
```
List {
  Section "進行中" (activeList)
  Section "保存済み (N)" (completedList)
  Section "未完了" (incompleteList)
}
```
- iPhone は内部 DL の閲覧のみ、外部フォルダ機能なし
- iPhone での外部フォルダ参照は Phase E2 で別途検討

Mac Catalyst:
```
List {
  Section "進行中"
  Section "保存済み (N)"        ← 内部ストレージ DL (現状)
  Section "外部参照 (M)"        ← 新規 (Mac のみ)
  Section "未完了"
}
```
- 外部参照セルはアイコンで区別 (例: `externaldrive.fill`)
- 外部フォルダ追加・削除 UI は本タブ内 + 設定画面の両方からアクセス可

### 3-2. 設定画面 (Mac Catalyst のみ)
`EhViewer/Views/SettingsView.swift` に新セクション「ストレージ (Mac)」追加:
- 「DL 保存先」: 現在のパス表示 + 「変更...」ボタン → `.fileImporter(allowedContentTypes: [.folder])`
  - 未設定なら従来 `Documents/EhViewer/downloads`
- 「外部参照フォルダ」: 登録済リスト表示 + 「追加...」ボタン + 「削除」スワイプ
  - 各エントリ = 1 つの security-scoped bookmark + 表示用 path

### 3-3. ライブラリ統合方針 (確定 2026-04-25)
独立タブ「ライブラリ」新設も検討したが、田中の判断で **既存「保存済み」タブを「ライブラリ」に改名** する方針に確定:
- タブ数増やさない (既に 7 タブ)
- 「保存済み」より「ライブラリ」の方が、内部 DL + 外部参照の両方を含む実態を表現
- iPhone は機能差異あるが UI 名称は統一 (Phase E2 で iPhone も外部参照対応する想定)

---

## 4. フォルダ構造規約

### 案A: フラット
```
/CortexLibrary/作品名/*.webp
```
- メリット: 構造単純
- デメリット: 何百作品で同階層 = Finder/SMB 一覧パフォーマンス劣化、source (eh/nh) 区別不能

### 案B: カテゴリ分割
```
/CortexLibrary/EHentai/作品/*.webp
/CortexLibrary/nhentai/作品/*.webp
```
- メリット: 視覚的にソース区別
- デメリット: ソース判定ロジックが parent dir name に依存、堅牢性低い

### 案C: 現行 DL 構造踏襲 (★推奨)
現行 (`EhViewer/Services/DownloadManager.swift:297-345`):
```
<base>/<gid>/
  metadata.json
  cover.jpg
  page_0001.jpg
  page_0002.jpg
  ...
```
- 既存の `imageFilePath(gid:page:)` / `coverFilePath(gid:)` / `metadataURL(gid:)` がそのまま使える
- Reader 経路 (`LocalReaderView.swift:277, 566` / `ReaderViewModel+PageLoad.swift:86, 221`) も無修正
- export 形式 (`GalleryExporter.swift:550-`) との整合 = **`.cortex` ZIP を展開してコピーした結果と同一構造**
- nhentai は gid が負数なので dir 名に注意 (`-12345/`)

**推奨: 案C**。既存 DL 構造をそのまま使い、Phase 1 の export/import 形式とも互換性がある。

---

## 5. metadata.json の扱い

### 5-1. スキーマ
**現状** (`EhViewer/Services/DownloadManager.swift:21-67`、`Codable` で JSON 直接 encode):
```swift
struct DownloadedGallery: Codable, Identifiable, Sendable {
  var gid: Int
  var token: String
  var title: String
  var coverFileName: String?
  var pageCount: Int
  var downloadDate: Date
  var isComplete: Bool
  var downloadedPages: [Int]
  var source: String?              // "ehentai" / "nhentai"
  var isCancelled: Bool? = nil
  var hasAnimatedWebp: Bool? = nil
  var readerModeOverride: GalleryReaderMode? = nil
  var tags: [String]? = nil
}
```

外部フォルダの `metadata.json` も **同一スキーマ** を採用 (案C と整合)。

### 5-2. metadata.json 不在時の自動生成

外部フォルダに `metadata.json` が無い場合の fallback ロジック (新設):

```
[擬似ロジック、実装は後]
1. フォルダ名 → title (ユーザ命名前提)
2. gid → ハッシュ生成 (絶対値が衝突しない様に十分長い、e.g. SHA256 16文字 → Int64 変換)
   ※ 既存 DL gid (E-Hentai 正数 / nhentai 負数) と衝突しない範囲を予約 (例: Int.max - hash)
3. token → 空文字 or "external"
4. pageCount → 数えた画像ファイル数
5. coverFileName → 1 番目の画像 (ソート順)
6. source → "external"
7. isComplete → true
8. downloadedPages → 0..<pageCount
```

ユーザが手動で `metadata.json` を置けば優先される (現状の export 形式と同一スキーマで OK)。

### 5-3. metadata.json 自動キャッシュ (条件付き書込、確定 2026-04-25)

**判断確定**: ユーザが他のツールで管理しているフォルダに勝手に書込むのを避けるため、**`.cortex_managed` フラグファイル方式** を採用。

**書込ルール**:
- 外部フォルダ直下に **`.cortex_managed`** という空ファイル (or 任意の YAML/JSON 設定) があるフォルダのみ → Cort:EX が自動生成 metadata.json を **その場に書込み**、2 回目以降のスキャン高速化
- `.cortex_managed` が無いフォルダ → **読み取り専用扱い**、自動生成 metadata は **Cort:EX 内部キャッシュ** (`<documents>/EhViewer/external_meta_cache/<bookmark_id>.json`) に退避
- ユーザが「このフォルダは Cort:EX 管理に委ねる」と意思表示する手段として `.cortex_managed` を touch する (将来的には UI から「このフォルダを Cort:EX 管理にする」ボタンで一括設定も可能、Phase E1 内 or 後)

**bookmark_id**:
- security-scoped bookmark Data の SHA256 先頭 16 文字 (or UUID 別途付与) を使用
- フォルダのパスが SMB マウントポイント変更等で変わっても bookmark Data から逆引き可

**キャッシュ無効化**:
- 外部フォルダ内のファイル変更検知 (Phase E1 では手動 refresh) で内部キャッシュを破棄
- スキャン時に内部キャッシュの mtime と外部フォルダの mtime 比較で stale 判定

---

## 6. 実装で触るファイル一覧 (grep ベース、新規含む)

### 6-1. 既存ファイル (修正)
| ファイル | 修正内容 |
|---|---|
| `EhViewer/Services/DownloadManager.swift` | `baseDirectory` を user-selectable に変更 (Mac のみ)、bookmark 解決ロジック追加 |
| `EhViewer/Models/Gallery.swift` | (修正不要、`Gallery` は API 表現、参照型は `DownloadedGallery` 拡張で済む) |
| `EhViewer/Views/DownloadsView.swift` | Section 追加 (外部参照)、外部参照セル UI |
| `EhViewer/Views/SettingsView.swift` | 「ストレージ (Mac)」セクション + folder picker |
| `EhViewer/Services/GalleryExporter.swift` | (修正不要、現状の `.cortex` ZIP コピー型 import は温存) |

### 6-2. 新規ファイル
| ファイル | 役割 |
|---|---|
| `EhViewer/Services/ExternalFolderManager.swift` | bookmark 永続化、解決、外部フォルダリスト管理 |
| `EhViewer/Services/ExternalGalleryScanner.swift` | フォルダスキャン、metadata.json 読み or 自動生成 |
| `EhViewer/Services/SecurityScopedBookmark.swift` | bookmark 作成/解決の wrapper (再利用しやすく) |
| (任意) `EhViewer/Views/ExternalFolderRow.swift` | DownloadsView 用の 外部参照セル |

### 6-3. 既存実装の確認 (grep 結果)
- `startAccessingSecurityScopedResource` 既存使用箇所: 3 箇所のみ、いずれも **in-flight 利用** (`SettingsView.swift:839`, `GalleryExporter.swift:137`, `FavoritesBackup.swift:113`)
- `bookmarkData` / `resolvingBookmark` の **永続化使用ゼロ** (grep 0 件)
- `fileImporter` の `allowedContentTypes` で `.folder` は **未使用** (現状は `.zip` / `.archive` / `.data` / `.json` のみ)
- → 永続的 security-scoped bookmark 機構と folder picker は **新規実装必要**

---

## 7. iOS / Mac Catalyst sandbox 整合性

### 7-1. Security-Scoped Bookmark 実装パターン (Mac Catalyst)

**書込時**:
```
[擬似]
1. fileImporter で URL 取得 (ユーザ選択)
2. url.startAccessingSecurityScopedResource() で一時アクセス
3. url.bookmarkData(options: .withSecurityScope, ...) で bookmark Data 生成
4. UserDefaults / file に保存
5. url.stopAccessingSecurityScopedResource()
```

**読込時** (アプリ起動毎):
```
[擬似]
1. UserDefaults から bookmark Data 読込
2. var stale = false
3. URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
4. resolved.startAccessingSecurityScopedResource()
5. アクセス完了後 stopAccessingSecurityScopedResource()
6. stale なら再生成
```

注意:
- Mac Catalyst で `.withSecurityScope` option は使用可能 (Apple 公式 doc 確認済の前提、実装時要再確認)
- Files.app 経由 (UIDocumentPickerViewController) でも同 option で永続化可

### 7-2. ファイル変更検知

- **Mac Catalyst**: `DispatchSource.makeFileSystemObjectSource` (FSEvents wrapper) 使用可。既存に `EhViewer/Views/AnimatedImageView.swift:121,237` で `DispatchSourceTimer`, `EhViewer/Services/DownloadManager.swift:1070` で `DispatchSource.makeTimerSource` の使用例あり、同パターンで実装可
- **iOS**: FSEvents 不可。SMB マウントは更に制約強い → polling のみ
- Phase E1 では **手動リフレッシュボタン + アプリ起動時 + 設定画面再表示時に rescan** で十分。リアルタイム watcher は Phase E2 検討

### 7-3. アクセス権限切れの扱い

- bookmark 解決が `nil` or stale → ユーザに「フォルダが見つかりません、再選択してください」 alert
- SMB マウント切断 (Mac で NAS down) → スキャン時 `.contentsOfDirectory` が throw、エラーログ + UI で当該外部フォルダエントリを「⚠️ 接続不可」表示

---

## 8. リスクと未解決問題

| # | リスク | 影響 | 緩和案 |
|---|---|---|---|
| R1 | 数千作品のスキャン性能 | 起動時 Hang | バックグラウンドスキャン + プログレスバー、metadata.json キャッシュ |
| R2 | SMB 切断で UI フリーズ | 操作不能 | スキャンを `Task.detached` で main thread から外す + timeout |
| R3 | フォルダ内ファイル変更検知の難易度 | 新作追加が反映されない | Phase E1: 手動 refresh、Phase E2: FSEvents |
| R4 | gid 衝突 (自動生成 hash) | 既存 DL と被る | 専用 namespace 予約 (`Int.max - hash`) + 衝突時 hash 再生成 |
| R5 | nhentai 負数 gid と外部 gid の混在 | DL Manager の判定ロジック汚染 | `source: "external"` を `DownloadedGallery.source` で明示、`isExternal: Bool` 計算プロパティ追加 |
| R6 | bookmark 永続化が Mac Catalyst で動かない | 機能不成立 | 実装初期に最小限 PoC で検証 |
| R7 | Reader 経路の前提崩れ | 動画作品 / 補正パイプライン不動 | 既存 `imageFilePath` を返す抽象化 (DownloadManager 経由) を維持、外部参照は `imageFilePath` を override |
| R8 | コード分岐肥大化 (`#if targetEnvironment(macCatalyst)` 散在) | 保守性低下 | 共通インタフェース層で iOS/Mac 差を吸収 |

---

## 9. 実装着手順序 (Phase E1 内)

1. `SecurityScopedBookmark.swift` 新設 + 単体動作確認 (folder 選択 → bookmark 永続化 → 再起動後解決)
2. `ExternalFolderManager.swift` 新設 + UserDefaults との接続
3. `SettingsView` に「ストレージ (Mac)」セクション追加 (`#if targetEnvironment(macCatalyst)`)
4. `ExternalGalleryScanner.swift` 新設 + metadata.json 読み取り
5. metadata.json 不在時の自動生成ロジック追加 (gid namespace = `Int.max - hash`、Q-3 確定案)
6. `.cortex_managed` フラグファイル判定 + 内部キャッシュ (`<documents>/EhViewer/external_meta_cache/`) 切替 (Q-4 確定案)
7. `DownloadsView` に外部参照 Section 追加 + タブ名「保存済み」→「ライブラリ」改名 (両 OS)
8. Reader 経路の `imageFilePath` 抽象化 (外部参照 gallery でも正しい URL を返す)
9. DL 保存先変更 (`DownloadManager.baseDirectory` を bookmark 解決先に切替、Mac のみ) — **既存 DL は旧 default パスにそのまま、新規 DL のみ新パス** (Q-2 確定案 (a))。SMB 越し自動移行は実装しない。

---

## 10. 田中の判断確定 (2026-04-25)

### Q-1. UI 整合 → **「保存済み」タブを「ライブラリ」に改名 (Mac/iPhone 両方)**
- iPhone は内部 DL のみ表示 (機能差異あり、UI 名称は統一)
- Mac はライブラリ内で外部フォルダ選択可能
- タブ数を増やさず、既存タブの意味拡張で対応

### Q-2. 既存 DL の扱い → **(a) そのまま (旧 default パスに残る)**
- 新規 DL のみ新パス、SMB 越し自動移行は実装しない
- 失敗リスク回避と実装シンプル化を優先

### Q-3. gid namespace → **案 1 (`Int.max - hash`)**
- 既存コード変更最小、Reader 経路汚染リスク回避
- E-Hentai 正数 + nhentai 負数 と完全分離

### Q-4. 自動生成 metadata の書込 → **条件付き書込 (`.cortex_managed` フラグ方式)**
- フォルダ直下に `.cortex_managed` ファイルあり → そこに metadata.json 自動書込
- 無ければ → Cort:EX 内部キャッシュ (`<documents>/EhViewer/external_meta_cache/<bookmark_id>.json`)
- ユーザが「Cort:EX 管理に委ねる」と明示意思表示する手段

### Q-5. iPhone 対応 (Phase E2) → **Mac 運用検証後に着手**
- Phase E1 完成 → 田中が実運用 → 必要要件見えてから Phase E2 着手
- iOS 側の SMB 経由 Files.app provider 制約は実運用で見えてくる課題に応じて対応

### スコープ確定 - DL 自動移動 / NAS 直接 DL は E1 から **除外**
- 田中の真の構想 (iPhone → M2 Air に URL 送信 → M2 Air が DL) は **Phase 3 (LAN HTTP API)** で実現
- E1 では「Mac の DL 保存先を NAS フォルダに変更可能」までで十分
- Phase 3 設計書は本セッションのスコープ外、後日別途作成

---

## 11. 本設計書の制約

- 本設計書は **コード変更を含まない**。grep で確認した既存実装の状態のみ事実として記載、実装方針は **田中の判断 (Q-1〜Q-5 + スコープ確定) に基づく**。
- Phase 1 (cortex:// URL 共有) は触らない。AirDrop バグ (FB9878055) の回避策ではなく、**完全に独立した機能** として実装。
- 田中憲法第 1 条: 本ファイル名にタイムスタンプ `20260425` 付与済。
- シェイクスピア定理: 「動いてる物に手を加えない」遵守。`#if targetEnvironment(macCatalyst)` で外部参照機能は Mac のみ、iPhone コードは「保存済み」→「ライブラリ」のタブ名改名のみ。

---

## 12. 参考: grep 確認済の既存実装事実

| 主張 | grep 引用 |
|---|---|
| DL ベースディレクトリ = `Documents/EhViewer/downloads` | `DownloadManager.swift:293-296` (baseDirectory) |
| 1 gallery = `<base>/<gid>/` directory | `DownloadManager.swift:297-299` (galleryDirectory) |
| 画像ファイル名 = `page_NNNN.jpg` (4 桁 0 埋め) | `DownloadManager.swift:341` (imageFilePath) |
| metadata.json は同 gid directory 直下 | `DownloadManager.swift:309-310` (metadataURL) |
| `DownloadedGallery` は `Codable` で JSON encode 済 | `DownloadManager.swift:21` |
| Reader が呼ぶのは `DownloadManager.shared.imageFilePath(gid:page:)` | `LocalReaderView.swift:277,566`, `ReaderViewModel+PageLoad.swift:86,221` |
| security-scoped bookmark の永続化使用は **既存ゼロ** | grep `bookmarkData|resolvingBookmark` で 0 件 |
| `fileImporter` の `.folder` 使用は **既存ゼロ** | grep `\.folder|UTType\.folder` で 0 件 |
| `.cortex` import 経路は temp に展開 → `DownloadManager` の dir に **コピー** | `GalleryExporter.swift:585-595` (registerImportedGallery) |
| Mac Catalyst 限定コードの既存パターン | `ContentView.swift:280, 738` (`#if targetEnvironment(macCatalyst)`) |
| 検索 polling / FSEvents 既存実装ゼロ | grep `FSEvent|DispatchSourceFileSystemObject` で 0 件 |

以上。
