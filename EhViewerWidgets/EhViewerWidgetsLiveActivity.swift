import WidgetKit
import SwiftUI
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit

struct EhViewerWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            // ロック画面 / スタンバイ表示
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展開表示（長押し）
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.currentPage)/\(context.attributes.totalPages)")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.galleryTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressView(value: context.state.progress)
                            .tint(.blue)

                        if context.state.isComplete {
                            Label("完了", systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else if context.state.isFailed {
                            Label("失敗", systemImage: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        } else {
                            Text("\(Int(context.state.progress * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                // コンパクト（左）
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                // コンパクト（右）
                Text("\(context.state.currentPage)/\(context.attributes.totalPages)")
                    .font(.caption)
                    .monospacedDigit()
            } minimal: {
                // ミニマル
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<DownloadActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: context.state.isComplete ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(context.state.isComplete ? .green : .blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.galleryTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                ProgressView(value: context.state.progress)
                    .tint(context.state.isComplete ? .green : .blue)

                HStack {
                    Text("\(context.state.currentPage)/\(context.attributes.totalPages)ページ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if context.state.isComplete {
                        Text("完了")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else if context.state.isFailed {
                        Text("失敗")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else {
                        Text("\(Int(context.state.progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }
}
#endif
