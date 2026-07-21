import SwiftUI

/// 動画 WebP を含むギャラリーを横開きモードで開こうとした時のモード選択ダイアログ。
///
/// 横開きは PagedReaderView 経由で UIImageView 静的描画のため WebP アニメが再生できない。
/// 縦スクロールは AnimatedImageView / GalleryAnimatedWebPView 経路で再生できる。
/// ユーザーが選択したモードは gallery 単位で `readerModeOverride` に保存される。
struct AnimationModeDialog: ViewModifier {
    @Binding var isPresented: Bool
    /// ユーザーが選んだモードを親に通知 (@AppStorage 経由で「次回から聞かない」が OFF の場合は保存しない)
    let onChoose: (GalleryReaderMode, _ dontAskAgain: Bool) -> Void

    @AppStorage(UDKey.animationDialogDontAskDefault) private var dontAskAgainDefault = true
    @State private var dontAskAgain: Bool = true

    func body(content: Content) -> some View {
        // 2026-07-21 リーダー無限ループ事件の恒久対策: .sheet 提示をやめ、リーダー内
        // ZStack オーバーレイで描く。詳細画面は B3 zoom 遷移 (navigationTransition) の
        // 遷移先で、そこからの fullScreenCover の上にさらに sheet を重ねる 3 層ネスト
        // 提示になると cover が sheet 提示に巻き込まれて剥がれ、item が残っているため
        // 再提示→再 resolve→再 sheet の自己ループになる (SE2 実測: ルート直下 cover では
        // 同一ダイアログが正常動作 = 提示コンテキスト依存を計測で確定)。
        // オーバーレイなら UIKit の presentation 機構を一切使わないため、この事故の
        // クラスごと成立しなくなる。
        content
            .overlay {
                if isPresented {
                    ZStack {
                        Color.black.opacity(0.55)
                            .ignoresSafeArea()
                        dialog
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .padding(.horizontal, 24)
                    }
                    .transition(.opacity)
                    // 診断 2026-07-21: リーダー提示フラッピングの因果特定用 (第21条計測器)
                    .onAppear { LogManager.shared.log("Anim", "DIALOG overlay appear") }
                    .onDisappear { LogManager.shared.log("Anim", "DIALOG overlay disappear") }
                }
            }
            .onChange(of: isPresented) { oldValue, newValue in
                LogManager.shared.log("Anim", "DIALOG isPresented \(oldValue)→\(newValue)")
                if newValue { dontAskAgain = dontAskAgainDefault }
            }
    }

    private var dialog: some View {
        VStack(spacing: 20) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
                .padding(.top, 32)

            Text("動画を含むギャラリー")
                .font(.title2).bold()

            Text("横開きモードでは動画は再生されません。\n縦スクロール表示に切り替えますか？")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Toggle("次回から聞かない", isOn: $dontAskAgain)
                .padding(.horizontal, 32)
                .padding(.top, 8)

            VStack(spacing: 12) {
                Button {
                    dontAskAgainDefault = dontAskAgain
                    onChoose(.vertical, dontAskAgain)
                    isPresented = false
                } label: {
                    Text("縦スクロール")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    dontAskAgainDefault = dontAskAgain
                    onChoose(.horizontal, dontAskAgain)
                    isPresented = false
                } label: {
                    Text("横開きで開く")
                        .font(.body)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.gray.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }
}

extension View {
    func animationModeDialog(
        isPresented: Binding<Bool>,
        onChoose: @escaping (GalleryReaderMode, Bool) -> Void
    ) -> some View {
        modifier(AnimationModeDialog(isPresented: isPresented, onChoose: onChoose))
    }
}
