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
                return host == .exhentai ? "ExHentai を検索" : "E-Hentai を検索"
            case .nhentai:
                return "nhentai を検索"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var historyStore = SearchHistoryStore.shared
    let mode: Mode
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
        onApply: @escaping (_ searchText: String,
                            _ categoryFilter: Int?,
                            _ baseQuery: String?,
                            _ categories: Set<GalleryCategory>,
                            _ languages: Set<String>) -> Void
    ) {
        self.mode = mode
        self.onApply = onApply
        self._searchText = State(initialValue: initialText)
        self._selectedCategories = State(initialValue: initialCategories)
        self._selectedLanguages = State(initialValue: initialLanguages)
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

    /// nhentai で実際に運用されているカテゴリのみ (田中要望 2026-04-30: ArtistCG/Cosplay 等は実体ほぼ無し)
    static let nhentaiSupportedCategories: [GalleryCategory] = [
        .doujinshi, .manga, .western, .nonH, .imageSet
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
                        Toggle(entry.label, isOn: Binding(
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
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    historyStore.remove(entry)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
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
            .navigationTitle("検索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
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
        case .ehentai: return "カテゴリ (空 = 全部)"
        case .nhentai: return "カテゴリ (空 = 全部、単一選択推奨)"
        }
    }

    private var languageFooter: String {
        switch mode {
        case .ehentai:
            return "単一選択 (日本語以外) は `language:X$` で厳密一致。日本語単独や複数選択は他言語を除外する仕様 (E-Hentai は OR 不可)。"
        case .nhentai:
            return "nhentai は OR 検索不可。複数選択は AND 扱いとなり結果ゼロになりがち。単一選択を推奨。"
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
        dismiss()
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
