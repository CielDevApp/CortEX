import SwiftUI

struct LoginView: View {
    @ObservedObject var authVM: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showHelp = false
    @State private var showWebLogin = false
    /// 田中要望 2026-04-27: 1 回目フォーラム到達後の「閉じて再起動」シミュレート用。
    /// hasRelaunchedWebLogin: 次回 sheet 提示時 isRelaunched で渡す値 (= 「2 回目モーダル」を意味)
    /// isRelaunchPending: onDismiss が「閉じて再起動」由来か「手動 ×」由来か区別するフラグ
    @State private var hasRelaunchedWebLogin = false
    @State private var isRelaunchPending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("E-Hentaiアカウントでログインします。")
                            .font(.subheadline.bold())
                        Text("ログインなしでもE-Hentaiは閲覧可能です。\nログインするとEXhentai（全作品）が利用できます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cookieの取得方法:")
                            .font(.caption.bold())
                        Text("1. Safariでe-hentai.orgにログイン\n2. 開発者ツールからCookieを確認\n3. ipb_member_id と ipb_pass_hash をコピー\n4. igneous はEXhentai用（任意）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("認証情報") {
                    TextField("ipb_member_id", text: $authVM.memberID)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("ipb_pass_hash", text: $authVM.passHash)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onChange(of: authVM.passHash) { _, newValue in
                            if newValue.count > 32 {
                                authVM.passHash = String(newValue.prefix(32))
                            }
                        }
                    TextField("igneous", text: $authVM.igneous)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    Text("EXhentaiに必要。なくてもE-Hentaiは使えます")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let error = authVM.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("ログイン") {
                        authVM.login()
                    }
                    .frame(maxWidth: .infinity)
                    .bold()

                    Button("ログインせずに使う") {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.secondary)

                    #if canImport(UIKit)
                    Button {
                        showWebLogin = true
                    } label: {
                        Label("ブラウザでログイン", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(.orange)
                    #endif
                }
            }
            .navigationTitle("ログイン")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showHelp = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showHelp) {
                LoginHelpView()
            }
            #if canImport(UIKit)
            .sheet(isPresented: $showWebLogin, onDismiss: {
                if isRelaunchPending {
                    // 「閉じて再起動」由来の dismiss → 0.5 秒後に sheet 再提示 (= 新規 WKWebView)
                    isRelaunchPending = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showWebLogin = true
                    }
                } else {
                    // ユーザー手動 × 閉じる → 次回はまた初回扱い
                    hasRelaunchedWebLogin = false
                }
            }) {
                EhExHentaiLoginView(
                    authVM: authVM,
                    isRelaunched: hasRelaunchedWebLogin,
                    onRequestRelaunch: { _, _ in
                        // 1 回目フォーラム到達 → WKWebView インスタンス物理破棄 + モーダル dismiss
                        hasRelaunchedWebLogin = true
                        isRelaunchPending = true
                        showWebLogin = false
                    }
                )
            }
            #endif
        }
    }
}

// MARK: - ログインヘルプ

struct LoginHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Cookie取得手順", systemImage: "list.number")
                                .font(.headline)

                            stepRow(1, "Safariで e-hentai.org にアクセスしてログイン")
                            stepRow(2, "exhentai.org にアクセス（Sad Pandaが出なければOK）")
                            stepRow(3, "ブラウザの開発者ツールまたはショートカットAppでCookieを取得")
                            stepRow(4, "以下の値をコピーして入力:")

                            VStack(alignment: .leading, spacing: 4) {
                                cookieItem("ipb_member_id", "数字（ユーザーID）")
                                cookieItem("ipb_pass_hash", "英数字の長い文字列")
                                cookieItem("igneous", "EXhentaiに必要。なくてもE-Hentaiは使えます")
                            }
                            .padding(.leading, 28)
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("簡単な取得方法", systemImage: "star.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)

                            Text("iPhoneのSafariでexhentaiにログイン済みの場合:")
                                .font(.subheadline)

                            Text("1. ショートカットAppで新規ショートカット作成\n2. 「Webページでjavascriptを実行」アクションを追加\n3. スクリプト: document.cookie\n4. Safariでexhentaiを開いた状態でショートカットを実行\n5. 表示されたCookieから値をコピー")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("E-Hentai と EXhentai の違い", systemImage: "info.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.blue)

                            bulletItem("E-Hentai: ログイン不要。一部タグの作品が除外される")
                            bulletItem("EXhentai: ログイン必須。全コンテンツ閲覧可能")
                            bulletItem("それ以外のR18コンテンツはどちらでも閲覧可能")
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("注意事項", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.red)

                            bulletItem("igneous は EXhentai 専用です。E-Hentaiのみ使う場合は不要")
                            bulletItem("Cookieは定期的に無効化される場合があります")
                            bulletItem("VPN使用時はログイン時と同じ国のIPを使用してください")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("ログイン方法")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    private func stepRow(_ num: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(num).")
                .font(.subheadline.bold())
                .foregroundStyle(.blue)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
        }
    }

    private func cookieItem(_ name: String, _ desc: String) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption.monospaced().bold())
                .foregroundStyle(.blue)
            Text("— \(desc)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func bulletItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.subheadline)
            Text(text).font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}
