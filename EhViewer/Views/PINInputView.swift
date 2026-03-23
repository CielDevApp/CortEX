import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 4桁PIN入力画面
struct PINInputView: View {
    let title: LocalizedStringKey
    let onComplete: (String) -> Void

    @State private var pin = ""
    @State private var shake = false
    @State private var dotColor: Color = .primary

    var body: some View {
        VStack(spacing: 32) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)

            // ドットインジケーター
            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < pin.count ? dotColor : Color.clear)
                        .overlay(Circle().stroke(dotColor, lineWidth: 2))
                        .frame(width: 16, height: 16)
                }
            }
            .offset(x: shake ? -10 : 0)

            // 数字キーパッド
            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 20) {
                        ForEach(1...3, id: \.self) { col in
                            let num = row * 3 + col
                            numButton("\(num)")
                        }
                    }
                }
                HStack(spacing: 20) {
                    Color.clear.frame(width: 72, height: 72)
                    numButton("0")
                    deleteButton
                }
            }
        }
        .padding()
    }

    private func numButton(_ num: String) -> some View {
        Button {
            guard pin.count < 4 else { return }
            pin += num
            haptic(.light)

            if pin.count == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    onComplete(pin)
                }
            }
        } label: {
            Text(num)
                .font(.title)
                .fontWeight(.medium)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.gray.opacity(0.15)))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private var deleteButton: some View {
        Button {
            if !pin.isEmpty {
                pin.removeLast()
                haptic(.light)
            }
        } label: {
            Image(systemName: "delete.left")
                .font(.title2)
                .frame(width: 72, height: 72)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    /// 間違い時の震えアニメーション
    func showError() {
        dotColor = .red
        withAnimation(.default.speed(4).repeatCount(4, autoreverses: true)) {
            shake = true
        }
        haptic(.error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            shake = false
            dotColor = .primary
            pin = ""
        }
    }

    private func haptic(_ type: HapticType) {
        #if canImport(UIKit)
        switch type {
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        #endif
    }

    private enum HapticType { case light, error }
}

/// PIN設定フロー（初回設定 or 変更）
struct PINSetupView: View {
    let isChange: Bool
    let onDone: () -> Void

    @ObservedObject private var pinManager = PINManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var phase: SetupPhase = .enterCurrent
    @State private var firstPIN = ""
    @State private var errorMessage = ""
    @State private var pinInputID = UUID()

    private enum SetupPhase {
        case enterCurrent, enterNew, confirm
    }

    var body: some View {
        NavigationStack {
            VStack {
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top)
                }

                Spacer()

                switch phase {
                case .enterCurrent:
                    PINInputView(title: "現在のPINを入力") { pin in
                        if pinManager.verifyCurrentPIN(pin) {
                            errorMessage = ""
                            phase = .enterNew
                            pinInputID = UUID()
                        } else {
                            errorMessage = "PINが違います"
                            pinInputID = UUID()
                        }
                    }
                    .id(pinInputID)

                case .enterNew:
                    PINInputView(title: isChange ? "新しいPINを入力" : "PINを設定") { pin in
                        firstPIN = pin
                        errorMessage = ""
                        phase = .confirm
                        pinInputID = UUID()
                    }
                    .id(pinInputID)

                case .confirm:
                    PINInputView(title: "確認のため再入力") { pin in
                        if pin == firstPIN {
                            if pinManager.setPIN(pin) {
                                onDone()
                                dismiss()
                            } else {
                                errorMessage = "保存に失敗しました"
                                phase = .enterNew
                                pinInputID = UUID()
                            }
                        } else {
                            errorMessage = "PINが一致しません"
                            phase = .enterNew
                            firstPIN = ""
                            pinInputID = UUID()
                        }
                    }
                    .id(pinInputID)
                }

                Spacer()
            }
            .navigationTitle(isChange ? "PIN変更" : "PIN設定")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .onAppear {
                if !isChange {
                    phase = .enterNew
                }
            }
        }
    }
}
