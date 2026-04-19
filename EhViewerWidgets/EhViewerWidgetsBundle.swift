import WidgetKit
import SwiftUI

@main
struct EhViewerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        EhViewerWidgetsLiveActivity()
        #else
        // Mac Catalyst では Live Activity 非対応、空 bundle
        EmptyWidget()
        #endif
    }
}

#if !(os(iOS) && !targetEnvironment(macCatalyst))
/// プレースホルダー: Widget プロトコル要求を満たすための最小実装
private struct EmptyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.kanayayuutou.CortEX.empty", provider: EmptyProvider()) { _ in
            Text("")
        }
    }
}

private struct EmptyEntry: TimelineEntry {
    let date: Date = Date()
}

private struct EmptyProvider: TimelineProvider {
    func placeholder(in context: Context) -> EmptyEntry { EmptyEntry() }
    func getSnapshot(in context: Context, completion: @escaping (EmptyEntry) -> Void) {
        completion(EmptyEntry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<EmptyEntry>) -> Void) {
        completion(Timeline(entries: [EmptyEntry()], policy: .never))
    }
}
#endif
