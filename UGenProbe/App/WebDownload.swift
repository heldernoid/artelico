import SwiftUI
import WebKit

/// Downloads a file through a real browser view. Hailo's server for the language models only serves
/// web browsers (it shows a short check page first), so a plain download request from the app is
/// refused; a WKWebView passes the check the way Safari does and can then save the file.
struct WebDownloadView: View {
    let title: String
    let address: URL
    let destination: URL
    let finished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = WebDownloadState()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.message).font(.callout)
                    if state.downloading {
                        ProgressView(value: state.fraction)
                        Text("\(formatBytes(Int(state.received))) of \(formatBytes(Int(state.expected)))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                Divider()
                WebDownloadBrowser(address: address, destination: destination, state: state)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(state.done ? "Done" : "Cancel") {
                        state.cancel()
                        finished()
                        dismiss()
                    }
                }
            }
            .onChange(of: state.done) { _, done in
                if done { finished() }
            }
            .interactiveDismissDisabled(state.downloading)
        }
    }
}

@MainActor
final class WebDownloadState: ObservableObject {
    @Published var message = "Opening Hailo's download page…"
    @Published var downloading = false
    @Published var done = false
    @Published var received: Int64 = 0
    @Published var expected: Int64 = 1
    var download: WKDownload?
    var observation: NSKeyValueObservation?

    var fraction: Double { expected > 0 ? Double(received) / Double(expected) : 0 }

    func cancel() {
        guard downloading else { return }
        download?.cancel { _ in }
        downloading = false
    }
}

struct WebDownloadBrowser: UIViewRepresentable {
    let address: URL
    let destination: URL
    let state: WebDownloadState

    func makeCoordinator() -> Coordinator { Coordinator(destination: destination, state: state) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: address))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        let destination: URL
        let state: WebDownloadState
        /// The file is written here first and moved into place only when complete.
        private var partial: URL { destination.appendingPathExtension("download") }

        init(destination: URL, state: WebDownloadState) {
            self.destination = destination
            self.state = state
        }

        // Anything the web view cannot show as a page (the model file) becomes a download.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            let type = navigationResponse.response.mimeType ?? ""
            let attachment = (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") ?? false
            if !navigationResponse.canShowMIMEType || attachment || type == "application/octet-stream" {
                return .download
            }
            return .allow
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
            Task { @MainActor in
                state.download = download
                state.downloading = true
                state.expected = max(navigationResponse.response.expectedContentLength, 1)
                state.message = "Downloading. Keep this window open."
                state.observation = download.progress.observe(\.completedUnitCount) { [state] progress, _ in
                    Task { @MainActor in
                        state.received = progress.completedUnitCount
                        if progress.totalUnitCount > 0 { state.expected = progress.totalUnitCount }
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in if !state.downloading && !state.done { state.message = "The page did not load: \(error.localizedDescription)" } }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // Turning a navigation into a download reports "frame load interrupted" here; that is not a failure.
            let code = (error as NSError).code
            guard code != 102, code != NSURLErrorCancelled else { return }
            Task { @MainActor in if !state.downloading && !state.done { state.message = "The page did not load: \(error.localizedDescription)" } }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                if !state.downloading && !state.done {
                    state.message = "If the page below asks you to confirm you are human, do that; the download starts afterwards."
                }
            }
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
            try? FileManager.default.removeItem(at: partial)
            return partial
        }

        func downloadDidFinish(_ download: WKDownload) {
            let moved: Bool
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
                moved = true
            } catch {
                moved = false
            }
            Task { @MainActor in
                state.downloading = false
                state.done = moved
                state.message = moved ? "Saved \(destination.lastPathComponent)." : "The file was downloaded but could not be saved."
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            try? FileManager.default.removeItem(at: partial)
            Task { @MainActor in
                state.downloading = false
                state.message = "The download stopped: \(error.localizedDescription)"
            }
        }
    }
}
