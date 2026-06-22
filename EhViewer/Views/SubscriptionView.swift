import SwiftUI

/// 新作通知機能 (Phase 3): 購読リスト画面。タグ/投稿者/キーワードを登録すると、
/// 新作がアップされた時に通知が届く (検知・送信は Mac 側ポーラー = ReCap 相乗り)。
struct SubscriptionView: View {
    @StateObject private var store = SubscriptionStore.shared
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView {
                        Label("購読リストは空です", systemImage: "bell.slash")
                    } description: {
                        Text("好きなタグ・投稿者・キーワードを登録すると、\n新作がアップされた時に通知が届きます。")
                    } actions: {
                        Button {
                            showingAdd = true
                        } label: {
                            Label("購読を追加", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(store.items) { item in
                                HStack(spacing: 12) {
                                    Image(systemName: item.kind.icon)
                                        .foregroundStyle(.blue)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.displayLabel)
                                            .font(.body)
                                            .lineLimit(1)
                                        Text(item.kind.displayName + (item.label.isEmpty ? "" : " · \(item.value)"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        store.remove(id: item.id)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        store.remove(id: item.id)
                                    } label: {
                                        Label("購読を削除", systemImage: "trash")
                                    }
                                }
                            }
                            .onDelete { store.remove(at: $0) }
                        } footer: {
                            Text("新作チェックは1時間おき。通知はオンにしておいてください。")
                        }
                    }
                }
            }
            .navigationTitle("購読リスト")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                #if os(iOS)
                if !store.items.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }
                #endif
            }
            .sheet(isPresented: $showingAdd) {
                SubscriptionAddSheet()
            }
        }
    }
}

/// 購読追加シート: 種類(タグ/投稿者/キーワード) + 値 + 任意の表示名。
private struct SubscriptionAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SubscriptionStore.SubscriptionItem.Kind = .tag
    @State private var value = ""
    @State private var label = ""
    @State private var duplicateWarning = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("種類", selection: $kind) {
                        ForEach(SubscriptionStore.SubscriptionItem.Kind.allCases, id: \.self) { k in
                            Label(k.displayName, systemImage: k.icon).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("購読の種類")
                }

                Section {
                    TextField(valuePlaceholder, text: $value)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("表示名 (任意)", text: $label)
                } footer: {
                    Text(valueHint)
                }
            }
            .navigationTitle("購読を追加")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        let ok = SubscriptionStore.shared.add(kind: kind, value: value, label: label)
                        if ok { dismiss() } else { duplicateWarning = true }
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .alert("追加できませんでした", isPresented: $duplicateWarning) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("同じ購読が既に登録されています。")
            }
        }
    }

    private var valuePlaceholder: String {
        switch kind {
        case .tag: return "例: female:sole female"
        case .uploader: return "例: 投稿者名"
        case .keyword: return "例: 検索キーワード"
        }
    }

    private var valueHint: String {
        switch kind {
        case .tag: return "E-Hentai のタグを入力 (namespace 付き推奨: female:〜, parody:〜, artist:〜)。"
        case .uploader: return "この投稿者がアップした新作を通知します。"
        case .keyword: return "このキーワードを含む新作を通知します (E-Hentai 検索構文が使えます)。"
        }
    }
}
