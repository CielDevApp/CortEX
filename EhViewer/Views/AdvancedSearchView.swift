import SwiftUI

/// 田中要望 2026-04-30: 既存の `.searchable` (日本語有利 baseQuery 込み) を撤回し、
/// 検索ボタン → 専用画面で全カテゴリ + 言語を任意指定する新検索 UX。
///
/// `Mode` で E-Hentai / nhentai を切り替え。
///   - .ehentai: f_search + f_cats を使う既存仕様 (categoryFilter Int? + baseQuery String? を返す)
///   - .nhentai: タグ namespace を直接 query に含めて 1 本にする (categoryFilter / baseQuery は nil で
///     searchText 1 本のみ親に渡す)
struct AdvancedSearchView: View {
    enum Mode {
        case ehentai(GalleryHost)
        case nhentai

        var prompt: String {
            switch self {
            case .ehentai(let host):
                return host == .exhentai
                    ? String(localized: "ExHentai を検索")
                    : String(localized: "E-Hentai を検索")
            case .nhentai:
                return String(localized: "nhentai を検索")
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var historyStore = SearchHistoryStore.shared
    let mode: Mode
    /// overlay 表示の場合 dismiss() が効かないので外部から閉じる手段を渡す。
    /// nil の場合は @Environment(\.dismiss) を使う (sheet/fullScreenCover 用)。
    let onClose: (() -> Void)?
    let onApply: (_ searchText: String,
                  _ categoryFilter: Int?,
                  _ baseQuery: String?,
                  _ categories: Set<GalleryCategory>,
                  _ languages: Set<String>) -> Void

    @State private var searchText: String
    @State private var selectedCategories: Set<GalleryCategory>
    @State private var selectedLanguages: Set<String>

    /// 履歴 store key (host ごとに分離)
    private var hostKey: String {
        switch mode {
        case .ehentai(let h): return h == .exhentai ? "exhentai" : "ehentai"
        case .nhentai: return "nhentai"
        }
    }

    init(
        mode: Mode,
        initialText: String = "",
        initialCategories: Set<GalleryCategory> = [],
        initialLanguages: Set<String> = [],
        onClose: (() -> Void)? = nil,
        onApply: @escaping (_ searchText: String,
                            _ categoryFilter: Int?,
                            _ baseQuery: String?,
                            _ categories: Set<GalleryCategory>,
                            _ languages: Set<String>) -> Void
    ) {
        self.mode = mode
        self.onClose = onClose
        self.onApply = onApply
        self._searchText = State(initialValue: initialText)
        self._selectedCategories = State(initialValue: initialCategories)
        self._selectedLanguages = State(initialValue: initialLanguages)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// 言語コードと表示名のリスト (E-Hentai のタグ namespace `language:`)
    /// `translated` は「翻訳フラグ」で言語ではない (英訳作品は `language:english + translated`)。
    /// ここに含めると除外戦略で翻訳作品全般が弾かれるので除外。
    static let allLanguages: [(code: String, label: String)] = [
        ("japanese", "日本語"),
        ("english", "英語"),
        ("chinese", "中国語"),
        ("korean", "韓国語"),
        ("french", "フランス語"),
        ("german", "ドイツ語"),
        ("italian", "イタリア語"),
        ("portuguese", "ポルトガル語"),
        ("russian", "ロシア語"),
        ("spanish", "スペイン語"),
    ]

    /// nhentai の主要言語 (実際にタグが多く付いている 3 言語に絞る)
    static let nhentaiLanguages: [(code: String, label: String)] = [
        ("japanese", "日本語"),
        ("english", "英語"),
        ("chinese", "中国語"),
    ]

    /// nhentai 実在カテゴリ 6 種 (NClientV2/V3 の DatabaseHelper::insertCategoryTags を根拠)。
    /// imageset/gamecg/cosplay/asianporn は nhentai 公式に存在しないため除外。
    static let nhentaiSupportedCategories: [GalleryCategory] = [
        .doujinshi, .manga, .artistCG, .western, .nonH, .misc
    ]

    private var languageList: [(code: String, label: String)] {
        switch mode {
        case .ehentai: return Self.allLanguages
        case .nhentai: return Self.nhentaiLanguages
        }
    }

    private var categoryList: [GalleryCategory] {
        switch mode {
        case .ehentai: return GalleryCategory.allCases
        case .nhentai: return Self.nhentaiSupportedCategories
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(mode.prompt, text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { applyAndDismiss() }
                } header: {
                    Text("検索ワード")
                }

                Section {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(categoryList, id: \.self) { cat in
                            CategoryChip(
                                category: cat,
                                selected: selectedCategories.contains(cat)
                            ) { toggle(cat) }
                        }
                    }
                    .padding(.vertical, 4)
                    HStack {
                        Button("全選択") { selectedCategories = Set(categoryList) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("クリア") { selectedCategories.removeAll() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Spacer()
                    }
                } header: {
                    Text(categoryHeader)
                } footer: {
                    if case .nhentai = mode {
                        Text("nhentai は OR 検索不可。複数選択時は AND 扱いとなり結果が出にくいため、単一選択を推奨。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(languageList, id: \.code) { entry in
                        // entry.label は "日本語" 等の動的 String なので LocalizedStringKey 経由で localize。
                        Toggle(LocalizedStringKey(entry.label), isOn: Binding(
                            get: { selectedLanguages.contains(entry.code) },
                            set: { on in
                                if on { selectedLanguages.insert(entry.code) }
                                else { selectedLanguages.remove(entry.code) }
                            }
                        ))
                    }
                    if !selectedLanguages.isEmpty {
                        Button("クリア") { selectedLanguages.removeAll() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } header: {
                    Text("言語 (空 = 全言語)")
                } footer: {
                    Text(languageFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                let history = historyStore.entries(forHostKey: hostKey)
                if !history.isEmpty {
                    Section {
                        // 田中報告 2026-05-16: 「履歴タップが反応しない場合が多い」(再発)。
                        // 実測 (21:04 ビルドA): row appeared 10 vs tap 0 vs 反応 0 → .swipeActions 否定
                        // 実測 (21:08 ビルドB): 反応 0 → .buttonStyle(.plain) 否定
                        // 診断ビルド C: .contentShape(Rectangle()) を Button 外側に移動。
                        // .frame(maxWidth: .infinity) は label 内維持。
                        // 他 (.swipeActions 撤去 / onAppear ログ / .buttonStyle なし) も維持。
                        // 変数1つずつ原則: 今回動かすのは .contentShape の位置だけ。
                        ForEach(history) { entry in
                            Button {
                                applyHistory(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayLabel)
                                        .font(.body)
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(2)
                                    Text(entry.savedAt, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // 診断 C: .contentShape(Rectangle()) を label 内から Button 外側に移動
                                .onAppear {
                                    LogManager.shared.log("AdvSearch", "row appeared: '\(entry.displayLabel)' id=\(entry.id.uuidString.prefix(8))")
                                }
                            }
                            .contentShape(Rectangle())
                            // 診断 B 継続: .buttonStyle(.plain) 撤去のまま
                            // .buttonStyle(.plain)
                            // 診断 A 継続: .swipeActions 撤去のまま
                            // .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            //     Button(role: .destructive) {
                            //         historyStore.remove(entry)
                            //     } label: {
                            //         Label("削除", systemImage: "trash")
                            //     }
                            // }
                        }
                        Button(role: .destructive) {
                            historyStore.clear(hostKey: hostKey)
                        } label: {
                            Label("履歴をすべて消去", systemImage: "trash")
                        }
                        .font(.footnote)
                    } header: {
                        Text("過去の検索")
                    }
                }
            }
            .modifier(LiquidGlassFormBackground())
            .navigationTitle("検索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("検索") { applyAndDismiss() }
                        .bold()
                }
            }
        }
    }

    private var categoryHeader: String {
        switch mode {
        case .ehentai: return String(localized: "カテゴリ (空 = 全部)")
        case .nhentai: return String(localized: "カテゴリ (空 = 全部、単一選択推奨)")
        }
    }

    private var languageFooter: String {
        switch mode {
        case .ehentai:
            return String(localized: "単一選択 (日本語以外) は `language:X$` で厳密一致。日本語単独や複数選択は他言語を除外する仕様 (E-Hentai は OR 不可)。")
        case .nhentai:
            return String(localized: "nhentai は OR 検索不可。複数選択は AND 扱いとなり結果ゼロになりがち。単一選択を推奨。")
        }
    }

    private func toggle(_ c: GalleryCategory) {
        if selectedCategories.contains(c) {
            selectedCategories.remove(c)
        } else {
            selectedCategories.insert(c)
        }
    }

    /// nhentai の `category:` namespace で使う slug (英小文字 + spaceless)
    private static func nhentaiCategorySlug(_ c: GalleryCategory) -> String {
        switch c {
        case .doujinshi: return "doujinshi"
        case .manga: return "manga"
        case .artistCG: return "artistcg"
        case .gameCG: return "gamecg"
        case .western: return "western"
        case .nonH: return "non-h"
        case .imageSet: return "imageset"
        case .cosplay: return "cosplay"
        case .asianPorn: return "asianporn"
        case .misc: return "misc"
        }
    }

    /// 履歴 entry をタップしたら state を復元 → 即検索実行。
    private func applyHistory(_ entry: SearchHistoryEntry) {
        // 田中報告 2026-05-16: 一部 entry がタップ無反応の切り分け診断ログ。
        LogManager.shared.log("AdvSearch", "applyHistory tap: '\(entry.displayLabel)' id=\(entry.id.uuidString.prefix(8)) host=\(entry.hostKey)")
        searchText = entry.text
        let categoryRawValues = Set(entry.categories)
        selectedCategories = Set(categoryList.filter { categoryRawValues.contains($0.rawValue) })
        selectedLanguages = Set(entry.languages)
        applyAndDismiss()
    }

    private func recordHistory() {
        let trimmedText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cats = selectedCategories.map { $0.rawValue }.sorted()
        let langs = selectedLanguages.sorted()
        historyStore.record(
            hostKey: hostKey,
            text: trimmedText,
            categories: cats,
            languages: langs
        )
    }

    private func applyAndDismiss() {
        recordHistory()
        let trimmedText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .ehentai:
            let categoryFilter: Int? = {
                guard !selectedCategories.isEmpty else { return nil }
                if selectedCategories.count == GalleryCategory.allCases.count { return nil }
                return GalleryCategory.excludeAllExcept(Array(selectedCategories))
            }()
            let baseQuery: String? = {
                guard !selectedLanguages.isEmpty else { return nil }
                // 日本語原文作品は `language:japanese` タグが付かない (タグなし=日本語デフォルト)。
                // よって日本語選択は除外戦略、それ以外単独選択は include 戦略。f_search は OR 不可。
                if selectedLanguages.contains("japanese") || selectedLanguages.count >= 2 {
                    let definedCodes = Set(Self.allLanguages.map { $0.code })
                    let toExclude = definedCodes.subtracting(selectedLanguages)
                    return toExclude.map { "-language:\($0)" }.sorted().joined(separator: " ")
                }
                if let only = selectedLanguages.first {
                    return "language:\(only)$"
                }
                return nil
            }()
            onApply(trimmedText, categoryFilter, baseQuery, selectedCategories, selectedLanguages)

        case .nhentai:
            // nhentai は単一 query 文字列で検索。タグ namespace を直接埋め込む。
            // OR 不可なので複数選択は AND 扱い → 単一選択を促す UI 表示済み。
            // 全選択は「指定なし」扱い。
            var parts: [String] = []
            if !trimmedText.isEmpty { parts.append(trimmedText) }
            // 全選択は「指定なし」扱い (nhentai はサポートカテゴリのみで判定)
            if !selectedCategories.isEmpty,
               selectedCategories.count != Self.nhentaiSupportedCategories.count {
                for cat in selectedCategories.sorted(by: { $0.rawValue < $1.rawValue }) {
                    parts.append("category:\(Self.nhentaiCategorySlug(cat))")
                }
            }
            for lang in selectedLanguages.sorted() {
                parts.append("language:\(lang)")
            }
            let nhQuery = parts.joined(separator: " ")
            onApply(nhQuery, nil, nil, selectedCategories, selectedLanguages)
        }
        close()
    }
}

/// iOS 26+ の Liquid Glass エフェクト (実機で対応している場合のみ Form の標準背景を消す)。
/// 旧 OS は Form のデフォルト不透明背景のまま (chip 色が問題なく出る既存挙動を維持)。
private struct LiquidGlassFormBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
        }
    }
}

private struct CategoryChip: View {
    let category: GalleryCategory
    let selected: Bool
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            Text(category.rawValue.uppercased())
                .font(.caption.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(selected ? Color(hex: category.color) : Color.gray.opacity(0.18))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        selected ? Color.clear : Color.gray.opacity(0.3),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }
}
