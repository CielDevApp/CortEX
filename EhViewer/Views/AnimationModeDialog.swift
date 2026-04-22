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

    @AppStorage("animationDialogDontAskDefault") private var dontAskAgainDefault = true
    @State private var dontAskAgain: Bool = true

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                dialog
                    .interactiveDismissDisabled()
            }
            .onChange(of: isPresented) { _, newValue in
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
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.hidden)
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
