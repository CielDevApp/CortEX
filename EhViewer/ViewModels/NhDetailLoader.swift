import Foundation
import Combine


@MainActor
class NhDetailLoader: ObservableObject {
    @Published var gallery: NhentaiClient.NhGallery?
    @Published var isLoading = false

    func load(id: Int) async {
        guard gallery == nil || gallery?.num_pages == 0 else { return }
        isLoading = true
        do {
            let full = try await NhentaiClient.fetchGallery(id: id)
            gallery = full
            LogManager.shared.log("nhentai", "detail loaded: id=\(full.id) pages=\(full.num_pages) tags=\(full.tags?.count ?? 0)")
        } catch {
            LogManager.shared.log("nhentai", "detail load failed: \(error.localizedDescription)")
        }
        isLoading = false
    }
}
