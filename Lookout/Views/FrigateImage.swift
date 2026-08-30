import Foundation
import UIKit

/// Shared thumbnail/image cache (NSCache + in-flight dedupe).
actor ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        cache.countLimit = 400
    }

    func image(api: FrigateAPI, url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url.absoluteString as NSString) { return hit }
        if let task = inFlight[url] { return await task.value }

        let task = Task<UIImage?, Never> {
            guard let data = try? await api.session.imageData(url) else { return nil }
            let img = UIImage(data: data)
            if let img { cache.setObject(img, forKey: url.absoluteString as NSString) }
            return img
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }

    func invalidate() { cache.removeAllObjects() }
}

/// Async image view bound to Frigate endpoints.
import SwiftUI

struct FrigateImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false
    private weak var model: AppModel?

    init(_ url: URL, model: AppModel?) {
        self.url = url
        self.model = model
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if failed {
                Theme.card.overlay(Image(systemName: "wifi.slash").foregroundStyle(.secondary))
            } else {
                Theme.card.overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) {
            guard let api = model?.api else { return }
            let img = await ImageCache.shared.image(api: api, url: url)
            if let img { image = img } else { failed = true }
        }
    }
}
