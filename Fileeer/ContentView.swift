//
//  ContentView.swift
//  Fileeer
//
//  Created by Pavel Zaitsev on 2026-05-31.
//

import SwiftUI

struct ContentView: View {
    @State private var files: [RemoteFile] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var downloadingPath: String?
    @State private var lastDownloadedURL: URL?

    // Configure your server base URL here
    private let serverBaseURL = URL(string: "http://localhost:12345/")!
    private var serverHost: String { serverBaseURL.host ?? "localhost" }
    private var serverPort: UInt16 {
        if let explicit = serverBaseURL.port { return UInt16(explicit) }
        // Default ports by scheme
        switch serverBaseURL.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return 0
        }
    }
    
    var body: some View {
        NavigationSplitView {
            Group {
                if isLoading {
                    ProgressView("Loading files…")
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                        Button("Retry") { Task { await loadFiles() } }
                    }
                } else if files.isEmpty {
                    VStack(spacing: 12) {
                        Text("No files available")
                        Button("Reload") { Task { await loadFiles() } }
                    }
                } else {
                    List(files) { file in
                        Button {
                            Task { await download(file: file) }
                        } label: {
                            HStack {
                                Image(systemName: "doc")
                                Text(file.path)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                if downloadingPath == file.path {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(downloadingPath != nil)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Server Files")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await loadFiles(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task { await loadFiles() }
            .alert("Download complete", isPresented: Binding(get: { lastDownloadedURL != nil }, set: { if !$0 { lastDownloadedURL = nil } })) {
                Button("OK", role: .cancel) { lastDownloadedURL = nil }
                Button("Open in Files") { openInFiles() }
            } message: {
                if let url = lastDownloadedURL { Text(url.lastPathComponent) }
            }
        } detail: {
            VStack(spacing: 16) {
                if let url = lastDownloadedURL {
                    Text("Saved to: \(url.path())")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    Text("Select a file to download")
                }
            }
            .padding()
        }
    }

    private func loadFiles(force: Bool = false) async {
        if isLoading && !force { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let service = FileService(host: serverHost, port: serverPort)
        do {
            files = try await service.fetchFileList()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func download(file: RemoteFile) async {
        downloadingPath = file.path
        defer { downloadingPath = nil }
        let service = FileService(host: serverHost, port: serverPort)
        do {
            let savedURL = try await service.downloadFile(atPath: file.path)
            lastDownloadedURL = savedURL
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func openInFiles() {
        guard let url = lastDownloadedURL else { return }
        #if canImport(UIKit)
        let controller = UIDocumentInteractionController(url: url)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.keyWindow?.rootViewController {
            controller.presentPreview(animated: true)
        }
        #endif
    }
}

#if canImport(UIKit)
extension UIWindowScene {
    var keyWindow: UIWindow? { self.windows.first { $0.isKeyWindow } }
}
#endif

#Preview {
    ContentView()
}
