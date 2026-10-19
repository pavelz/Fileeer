//
//  ContentView.swift
//  Fileeer
//
//  Created by Pavel Zaitsev on 2026-05-31.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var files: [RemoteFile] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var downloadingPath: String?
    @State private var lastDownloadedURL: URL?
    @State private var lastSavedURL: URL?
    @State private var fileContent: String?
    @State private var showTextViewer = false

    // Configure your server base URL here
    private let serverBaseURL = URL(string: "http://Pavels-MacBook-Pro.local:12345/")!
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
            .sheet(isPresented: $showTextViewer) {
                if let content = fileContent {
                    TextViewerSheet(content: content, url: lastDownloadedURL)
                }
            }
        } detail: {
            VStack(spacing: 16) {
                if let savedURL = lastSavedURL {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                        Text("Saved for later review")
                            .font(.headline)
                        Text(savedURL.lastPathComponent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let url = lastDownloadedURL {
                    Text("Saved to: \(url.path())")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
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

            // Persist to Documents/Downloads for later review.
            // .atomic overwrites in place if the file already exists.
            if let data = try? Data(contentsOf: savedURL) {
                let documentsURL = FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)[0]
                let downloadsDir = documentsURL.appendingPathComponent("Downloads", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: downloadsDir,
                    withIntermediateDirectories: true
                )
                let persistentURL = downloadsDir.appendingPathComponent(file.path)
                print ("Saving: \(persistentURL.path)")
                try data.write(to: persistentURL, options: .atomic)
                lastSavedURL = persistentURL
            }

            // Read the file so we can display it in the text viewer sheet
            if let data = try? Data(contentsOf: savedURL),
               let text = String(data: data, encoding: .utf8) {
                fileContent = text
                showTextViewer = true
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Text Viewer Sheet

struct TextViewerSheet: View {
    let content: String
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(url?.lastPathComponent ?? "File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let url {
                        ShareLink(item: url)
                    }
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(2))
            dismiss()
        }
    }
}

#Preview {
    ContentView()
}
