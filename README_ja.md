# Cort:EX ver.02a f10

> ## ⚠️ Security Fix — Immediate Update Required
>
> v0.2a〜v0.2a-f6 にはハードコードされた DEBUG credentials が含まれていました。
> 該当 credentials は既に revoke 済みです。直ちに v0.2a-f7 以降へアップデートしてください。
>
> **v0.2a〜v0.2a-f6 を Mac / iOS にインストール済みの方へ:**
> アップデート後も旧 credentials が Keychain に残る可能性があります。v0.2a-f7 以降は起動時に自動検出して削除します (SHA256 hash 照合、平文保存なし)。手動で実行する場合は **設定 → キャッシュ管理 → 全データリセット（工場出荷状態）**。
>
> **新 Mac への移行 / 他人に譲渡する前に:**
> リポジトリから `./scripts/cleanup-cortex-data.sh` を実行、またはアプリ内リセットボタンを使用してください。

**E-Hentai / EXhentai / nhentai 統合ビューア for iOS / iPadOS**

[English](README.md) | [中文](README_zh.md) | [日本語](README_ja.md)

---

## デモ

https://github.com/CielDevApp/CortEX/raw/main/assets/demo.mp4

> *プライバシー保護のためコンテンツにブラーを適用*

---

## 機能

### マルチサイト統合
- **E-Hentai / EXhentai** — ログイン状態に応じて自動切替。未ログインでもE-Hentai閲覧可能
- **nhentai** — API完全統合、Cloudflare自動突破（WKWebView cf_clearance）、WebP対応
- **削除作品 四段構え復活** — nhentai（アプリ内検索）→ nyahentai.one → hitomi.la → タイトルコピー

### リーダー
- **4モード** — 縦スクロール / 横ページめくり / iPad見開き / ピンチズーム
- **iPad見開き** — 横画面自動検知、2ページ合成描画（隙間ゼロ）、横長画像は単独表示
- **右綴じ / 左綴じ** — 端タップによるページ送り対応
- **ダブルタップズーム** — Live Text（テキスト選択）対応

### 画像処理エンジン（3基搭載）
- **CIFilter** — トーンカーブ、シャープネス、ノイズ除去
- **Metal Compute Shader** — GPU直叩きパイプライン
- **CoreML Real-ESRGAN** — Neural Engine 4倍超解像（タイリング処理）
- **4段階画質** — 低画質 → 低画質+超解像 → 標準 → 標準+フィルタ
- **HDR補正** — 暗部ディテール引き出し + 彩度 + コントラスト強調

### ダウンロード
- **双方向DL（エクストリーム挟撃）** — 前方+後方の同時ダウンロード
- **セカンドパス** — 失敗ページの自動リトライ（指数バックオフ）
- **Live Activity** — ロック画面 + Dynamic Island で進捗表示
- **閲覧/DL分離** — 閉じる時に「残りをダウンロードしますか？」確認

### お気に入り
- **デュアルキャッシュ** — E-Hentai / nhentai 独立キャッシュ（ディスク永続化）
- **nhentai同期** — WKWebView SPA描画 → JavaScript ID抽出 → API解決
- **検索 / ソート** — 追加日（新しい/古い）/ タイトル順

### nhentai詳細画面
- タイトル / カバー / 情報（言語、ページ数、サークル、作家、パロディ）
- **タグタップ検索** — artist:名前、group:名前 等でワンタップ検索
- サムネグリッド → タップでページジャンプ
- フィルタパイプライン（ノイズ除去 / 画像補正 / HDR）

### セキュリティ
- **Face ID / Touch ID** — 起動時・復帰時の認証
- **4桁PINコード** — 生体認証のフォールバック
- **App Switcherブラー** — タスク切替画面で内容隠蔽
- **Keychain暗号化** — Cookie・認証情報の安全保管

### バックアップ
- **PHOENIX MODE** — E-Hentai + nhentai お気に入り統合JSONバックアップ
- **エクストリーム安全装置** — バックアップ未実施ではEXTREME MODE起動不可
- **.cortexエクスポート** — ギャラリーZIPパッケージ

### パフォーマンス
- **ECOモード** — NPU/GPU無効化、30Hz、iOS低電力モード連動
- **EXTREME MODE** — 全リミッター解除（20並列、ディレイゼロ）
- **CDNフォールバック** — i/i1/i2/i3 自動切替 + 拡張子フォールバック（webp→jpg→png）

### 翻訳
- **Vision OCR** → Apple Translation API → 画像焼き込み
- 5言語対応（日/英/中/韓/Auto）

### AI（iOS 26+）
- **Foundation Models** — ジャンル自動分類、タグ推奨

### UI/UX
- **TipKit（11種）** — 全機能の操作ヒント、設定から再表示可能
- **8言語ローカライズ** — 日/英/中簡/中繁/韓/独/仏/西
- **動的タブ** — ログイン状態でE-Hentai ↔ EXhentai自動切替
- **ベンチマーク** — CIFilter vs Metal 速度計測 + デバイスモデル表示
- **ロック画面壁紙** — お気に入りのカバー画像がロック画面の背景に自動反映
- **タブバー自動非表示** — 下スクロールでタブバーが隠れ、表示領域が拡大

---

## アーキテクチャ

iPhone / iPad / Mac ユニバーサル対応の単一コードベース。Apple 純正 20 フレームワーク上に構築、外部依存ライブラリゼロ。

**9 レイヤー構成:**

| # | レイヤー | 主な構成 |
|---|---|---|
| 01 | PRESENTATION | 4モードリーダー (縦スクロール / 横ページめくり / iPad見開き / ピンチズーム) |
| 02 | MODES | SAFETY (default) / EXTREME / ECO / SPARE の4段階動作モード |
| 03 | INGESTION | E-Hentai / EXhentai 動的切替、nhentai v2 API + Cloudflare Turnstile 突破 |
| 04 | TRANSPORT | BackgroundDownloadManager、URLSession 背景DL、BAN封じ込め6経路、2ndpass並列5 |
| 05 | COMPUTE | 画像処理エンジン3基 (CIFilter / Metal Compute / CoreML Real-ESRGAN) |
| 06 | MEDIA | 動画 WebP / HEVC 変換、HDR補正、VideoToolbox HW エンコード |
| 07 | SILICON | CPU / GPU (Metal) / NPU (CoreML) / Media Engine 全活用、iPhone A17 Pro / iPad A17 Pro / Mac M1–M4 対応 |
| 08 | TRUST | Face ID / Touch ID / PIN / Keychain / App Switcher ブラー |
| 09 | PLATFORM | iOS 18+ / iPadOS 18+ / macOS 14+ Mac Catalyst、8言語ローカライズ |

**SAFETY MODE 主要機能:**
- BAN検知 6経路で完全封じ込め
- 50画面 / 60秒 の自動 cooldown
- 2ndpass 並列5 で失敗ページを自動救済
- 並列度維持 · 速度犠牲なし
- disk prefix skip · reconcileGallery

**構成ファクト:**
- 77 Swift ファイル / 約 20,000 行
- 外部依存ライブラリ: 0
- Apple 純正フレームワーク: 20
- 対応: iOS 18+ / iPadOS 18+ / macOS 14+

---

## 動作環境
- iOS 18.0+ / iPadOS 18.0+（iOS 26 / iPadOS 26 テスト済み）
- macOS 14.0+（Mac Catalyst、Apple Silicon / Intel 両対応）
- iPhone / iPad（iPad見開きモード対応）/ Mac

## インストール

### iOS / iPadOS — ソースからビルド
1. クローン：`git clone https://github.com/CielDevApp/CortEX.git`
2. Xcode 16+ で `EhViewer.xcodeproj` を開く
3. Signing & Capabilities で自分のTeamを選択
4. Bundle Identifierを変更（例：`com.yourname.cortex`）
5. 実機を接続して Run

### iOS / iPadOS — サイドロード（Macなし）
1. [Releases](https://github.com/CielDevApp/CortEX/releases/latest) から `EhViewer-<version>.ipa` をダウンロード
2. AltStore、Sideloadly、TrollStore でインストール
   - AltStore / Sideloadly はインポート時にユーザーの Personal Team で再署名するため、配布 IPA の署名は剥がされる（最新版の IPA であれば内容は何でも OK）
   - TrollStore は再署名なしでそのまま使える

> 注意：無料Apple Developer アカウントはサイドロード署名に7日間の制限があります。AltStoreで自動更新をお勧めします。

### Mac（Catalyst版） — ビルド済み .app を使う
1. [Releases](https://github.com/CielDevApp/CortEX/releases/latest) から `EhViewer-macOS-<version>.zip` をダウンロード（Developer ID 署名 + Apple 公証済み）
2. 解凍して `EhViewer.app` を `/Applications` にドロップ
3. ダブルクリックで起動 — Gatekeeper 警告は出ません、`xattr` 等の迂回操作も不要

### Mac（Catalyst版） — ソースからビルド
1. クローン：`git clone https://github.com/CielDevApp/CortEX.git`
2. Xcode 16+ で `EhViewer.xcodeproj` を開く
3. Scheme = `EhViewer`、Destination = `My Mac (Mac Catalyst)`
4. Signing & Capabilities で自分のTeamを選択、Bundle Identifier を変更
5. Product → Run で起動、または Product → Archive で `.app` を書き出し `/Applications` に配置
   - コマンドライン派は `xcodebuild -project EhViewer.xcodeproj -scheme EhViewer -destination 'platform=macOS,variant=Mac Catalyst' build`
6. Mac 版は上部に独自 7 タブバー（ギャラリー / お気に入り / ガチャ / 保存済み / 履歴 / お気に入りキャラクター管理 / 設定）を常時横並び表示

## 開発
- Swift / SwiftUI
- 92 Swift ファイル / 約 20,000 行
- Metal / CoreML / Vision / WebKit / ActivityKit / TipKit

## 更新履歴

### ver.02a f10 (2026-04-28)
- **WKWebView E-Hentai / EXhentai ブラウザログイン** — 既存ログイン画面に「ブラウザでログイン」ボタンを追加 (全プラットフォーム共通)。Safari 風 toolbar + WKWebView モーダルで 3 つの cookie (`ipb_member_id` / `ipb_pass_hash` / `igneous`) を自動抽出して認証情報フィールドに自動入力。E-Hentai セッション伝播タイムラグ対策として、forums.e-hentai.org 到達時にモーダル全体を dismiss → 0.5 秒待機 → sheet 再 present で「閉じて再起動」を物理シミュレート、2 回目に確実に igneous を発行させる。`…` メニューに「e-hentai/exhentai cookie をクリア」debug 機能 (nhentai 側は無傷)。Cort:EX 黒/橙カラースキーム + SF Symbols 統一。

### ver.02a f9 (2026-04-27)
- **ライブラリソート Menu (全プラットフォーム)** — 「保存済み」section に追加日 / 名前昇降のソート Menu を追加。@AppStorage で永続化、外部参照 (Mac Catalyst) とは独立操作。
- **`.cortex` 追加日修正** — metadata.json を含まない `.cortex` ZIP が scan のたびに `Date()` で「今」スタンプされ、UnrealBeauty Yaoguang / UnityNay 等が常に追加日順の最上位に出る問題を修正。ZIP file の `creationDate` (fallback `mtime`) を使う方式に変更、サブフォルダ形式と挙動統一。

### ver.02a f8 (2026-04-27)
- **画廊一覧グリッド表示** (iPad / iPhone / Mac Catalyst) + List/Grid 切替 — iPhone 3 列固定、iPad 4 列固定、Mac Catalyst adaptive(180+)。EH/EXH 全タブ + nhentai 全ソートに適用。
- **画廊検索 race fix** — Enter 連打 / 連続検索の cancellation 処理修正。
- **nhentai 人気順復活** — v2 search endpoint に切替。
- **グリッド fullscreen 空白対策** — 統合 dummy slot 機構。
- **DL 後 SSD → NAS 転送ダイアログ + 進捗バー**。
- **ガチャ 10 連演出**のサムネ重複削減。
- **ライブラリ詳細 sheet → タグ検索結果 → 作品タップ**の遷移修正。
- **静画ジャンプ freeze 解消**、sandbox-off path-override、ImageCache race 修正。
- **Removed:** iPhone 共有ボタン → Mac Cort:EX へ DL 依頼 (cortex://download/queue) を撤去 (実装未達 + 必要性消失)。保存済みエクスポート (.cortex zip 共有) は変更なし。

### ver.02a f6 (2026-04-23)
- **Mac Catalyst 完全対応** — macOS 14+ Apple Silicon / Intel 両対応のユニバーサルビルド。Developer ID 署名 + Apple 公証済み `.app` を GitHub Releases で配布、`/Applications` にドロップしてダブルクリックで起動可能。上部タブバーは TabView の overflow menu 回避のため独自 HStack で再実装、全 7 タブを常時横並び + セル全域ヒット判定 + 矢印キーでのページ送り対応
- **EXTREME MODE → SAFETY MODE 再設計** — BAN 耐性を最優先する構成へ再編。BAN 検知 6 経路で完全封じ込め、50 画面 / 60 秒 自動 cooldown、並列度を維持したまま速度を犠牲にしない class-change。509 gif URL パターン検出、Cloudflare `cf-mitigated` ヘッダ検出、HTML fallback 検知、home.php 誤リダイレクト検出を transport 層に統合
- **動画 WebP リーダー強化** — 手動再生モード統一 (▶ アイコン押下で変換開始)、HDR 補正を既存画像設定と統合、長押しメニューで直接モード切替。検出を VP8X マジックで統一、生バイトをメモリからディスク URL 経由に退避してメモリ圧軽減
- **アニメ WebP ハング対策** — LocalReader / GalleryReader で自動再生によるメモリ爆発と UI hang を修正。現在ページのみ AVPlayer 昇格、init 時キャッシュ昇格、PlayerContainerView のスクロール吸収問題、キャッシュ蘇生時の再構築ループを全て解消
- **nhentai ログイン復活 (Mac Catalyst)** — Keychain `-34018 errSecMissingEntitlement` を file-based fallback (`~/Documents/EhViewer/creds/`) で回避、Cloudflare 通過経路も修正して Catalyst でも認証永続化
- **iPad タブバー追従** — GeometryReader + PreferenceKey 経路で下スクロール時のタブバー自動非表示を iPad でも確実に動作するよう修正
- **DL 済みカバーのローカル流用拡張** — 詳細画面だけでなく履歴 / ガチャ / 設定画面でもローカルカバー画像を優先使用、CDN 往復削減
- **リリース自動化** — `scripts/release-mac.sh` (Archive → Developer ID 署名 → notarize → staple → zip) と `scripts/release-ios.sh` (Archive → Development IPA export) を追加、タグ名引数 1 つで Mac zip + iOS IPA を生成

### ver.02a f5 (2026-04-20)
- **自前 ZIP streaming writer** — Apple の NSFileCoordinator.forUploading（大作品で 59 秒 main ブロック + Code=512 失敗）を自前ストリーミング stored+ZIP64 writer に置換。6 倍速 + リアルタイム進捗バー + 3GB 超作品も正常 export
- **ゾンビ DL 撲滅** — 削除 / キャンセル後も URL 解決 / stream 消費 / 2ndpass リトライループが走り続ける問題を修正。クリーンアップ時のメタデータ蘇生も防止
- **スクロール位置整合** — LocalReaderView のページ表記が表示ページと一致しない問題を根絶。LazyVStack `.onAppear` の last-wins 競合 + `.scrollPosition` / `scrollTo` API 衝突が原因で「1/47 なのに 13 ページ目を表示中」的なズレが出ていた
- **保存済み作品のプレビュー** — 長押しで全ページのサムネグリッド表示、タップで該当ページから読み始め。縦長固定セルで統一、アニメ WebP は紫枠 + ▶ アイコンで識別
- **0B キャッシュ誤認防止** — `isFullyConverted` にサイズ検査（10KB 以上）を追加、race condition で壊れた 0B キャッシュ mp4 による AVPlayer "item failed" 連鎖を阻止
- **DL リトライ戦略** — Cloudflare `cf-mitigated: challenge` ヘッダ検出、509 gif URL パターン検出、SpeedTracker によるバイト進捗 watchdog、別ミラー再試行中 UI フェーズ
- **並行 DL** — URL 解決完了時点で semaphore 解放、複数作品の並行ダウンロード対応
- **一時ファイル自動整理** — 共有シート完了時（AirDrop / Save to Files / キャンセル）に `.cortex` を即削除、起動時の残骸整理と併用

### ver.02a f3 (2026-04-12)
- **GPUスプライトパイプライン** — スプライトのデコード・クロップ・リサイズをMetal CIContextで1パスGPU処理
- **専用画像処理キュー** — 全スプライト処理を専用DispatchQueueに隔離、協調スレッドプール飢餓を解消
- **ディスクキャッシュ廃止** — スプライト/クロップ済みサムネのJPEG再エンコードを完全削除（メモリキャッシュのみ）
- **起動時プリフェッチ最適化** — お気に入り全件（2400+）→ 表示分30件に制限

### ver.02a f2 (2026-04-07)
- **お気に入りトグル信頼性向上** — 429エラーページリトライ+バックオフ、disabledボタン検知、Cookie二重化修正
- **Cookie管理改善** — サーバー設定属性（HttpOnly, Secure）を保持する補完注入方式に変更
- **レートリミット強化** — `fetch()`に429リトライ（3秒/6秒指数バックオフ、最大3回）追加

### ver.02a f1 (2026-04-05)
- **nhentai API v2移行** — v1からv2 APIへ全面移行、WKWebView経由のCloudflare TLSフィンガープリント突破
- **nhentaiお気に入りトグル** — SPA内 `#favorite` ボタンクリックによるサーバー側追加/削除（SvelteKit hydrationポーリング対応）
- **お気に入り同期最適化** — キャッシュ済みギャラリーをスキップしてAPIコール大幅削減、429リトライ+指数バックオフ
- **v2認証対応** — `isLoggedIn()` が `access_token`（v2）も認識するよう拡張
- **サムネ / カバー v2対応** — v2 APIの `thumbnailPath` / `path` 使用、CDNフォールバック（i/i1/i2/i3）
- **削除作品復活** — リーダー表示前に `fetchGallery` で詳細取得
- **nhentai詳細画面** — タグタップ検索、サムネグリッド、ダウンロード、フィルタパイプライン
- **ロック画面壁紙** — お気に入りカバー画像をブラー付きロック画面背景に自動反映
- **タブバー自動非表示** — 下スクロールでタブバーが隠れ、表示領域拡大

### ver.02a（初回リリース）
- E-Hentai / EXhentai / nhentai 統合ビューア
- 4モードリーダー（iPad見開き対応）
- 3基画像処理エンジン（CIFilter / Metal / CoreML Real-ESRGAN）
- 双方向ダウンロード + Live Activity
- Face ID / Touch ID / PINセキュリティ
- PHOENIX MODE バックアップ、ECO / EXTREME パフォーマンスモード
- Vision OCR翻訳、TipKitヒント、8言語ローカライズ

## ライセンス
GPL-3.0 ライセンス — 詳細は[LICENSE](LICENSE)ファイルを参照。

## サポート
[Patreon](https://www.patreon.com/c/Cielchan)で開発を支援できます。
