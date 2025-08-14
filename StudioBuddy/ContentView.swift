import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    @State private var showingFilePicker = false
    @State private var showingReferencePicker = false
    @State private var isMastering = false
    @State private var masteringProgress: Double = 0
    @State private var showingExportAlert = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Source Audio")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        showingFilePicker = true
                    }) {
                        HStack {
                            Image(systemName: audioManager.sourceURL != nil ? "checkmark.circle.fill" : "music.note.list")
                                .foregroundColor(audioManager.sourceURL != nil ? .green : .blue)
                            Text(audioManager.sourceFileName ?? "Select Audio File")
                                .foregroundColor(audioManager.sourceURL != nil ? .primary : .blue)
                            Spacer()
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                    
                    if audioManager.sourceURL != nil {
                        AudioPlayerView(
                            url: audioManager.sourceURL!,
                            title: "Source",
                            audioManager: audioManager,
                            isSource: true
                        )
                    }
                }
                .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 15) {
                    Text("Reference Track")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        showingReferencePicker = true
                    }) {
                        HStack {
                            Image(systemName: audioManager.referenceURL != nil ? "checkmark.circle.fill" : "music.note")
                                .foregroundColor(audioManager.referenceURL != nil ? .green : .blue)
                            Text(audioManager.referenceFileName ?? "Select Reference Track")
                                .foregroundColor(audioManager.referenceURL != nil ? .primary : .blue)
                            Spacer()
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                    
                    if audioManager.referenceURL != nil {
                        AudioPlayerView(
                            url: audioManager.referenceURL!,
                            title: "Reference",
                            audioManager: audioManager,
                            isSource: false
                        )
                    }
                }
                .padding(.horizontal)
                
                if audioManager.sourceURL != nil && audioManager.referenceURL != nil {
                    VStack(spacing: 15) {
                        Button(action: {
                            startMastering()
                        }) {
                            HStack {
                                if isMastering {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                }
                                Text(isMastering ? "Mastering..." : "Start AI Mastering")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isMastering ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(isMastering)
                        
                        if isMastering {
                            ProgressView(value: masteringProgress)
                                .progressViewStyle(LinearProgressViewStyle())
                                .padding(.horizontal)
                        }
                    }
                    .padding(.horizontal)
                }
                
                if audioManager.masteredURL != nil {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Mastered Audio")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                        
                        AudioPlayerView(
                            url: audioManager.masteredURL!,
                            title: "Mastered",
                            audioManager: audioManager,
                            isSource: false,
                            showExport: true,
                            onExport: {
                                exportMasteredAudio()
                            }
                        )
                        .padding(.horizontal)
                    }
                }
                
                Spacer()
            }
            .navigationTitle("StudioBuddy")
            .sheet(isPresented: $showingFilePicker) {
                DocumentPicker(audioManager: audioManager, isSource: true)
            }
            .sheet(isPresented: $showingReferencePicker) {
                DocumentPicker(audioManager: audioManager, isSource: false)
            }
            .alert("Export Complete", isPresented: $showingExportAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your mastered audio has been exported successfully.")
            }
        }
    }
    
    func startMastering() {
        isMastering = true
        masteringProgress = 0
        
        Task {
            await audioManager.startMastering { progress in
                DispatchQueue.main.async {
                    masteringProgress = progress
                }
            }
            
            DispatchQueue.main.async {
                isMastering = false
                masteringProgress = 0
            }
        }
    }
    
    func exportMasteredAudio() {
        audioManager.exportMasteredAudio { success in
            if success {
                showingExportAlert = true
            }
        }
    }
}

struct AudioPlayerView: View {
    let url: URL
    let title: String
    @ObservedObject var audioManager: AudioManager
    let isSource: Bool
    var showExport: Bool = false
    var onExport: (() -> Void)? = nil
    
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    
    private var isPlaying: Bool {
        audioManager.currentlyPlayingURL == url && audioManager.isPlaying
    }
    
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                }
                
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ProgressView(value: currentTime, total: duration)
                        .progressViewStyle(LinearProgressViewStyle())
                    
                    HStack {
                        Text(formatTime(currentTime))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatTime(duration))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                if showExport, let onExport = onExport {
                    Button(action: onExport) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 24))
                            .foregroundColor(.blue)
                    }
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(10)
        }
        .onAppear {
            setupPlayer()
        }
    }
    
    func togglePlayback() {
        audioManager.togglePlayback(url: url)
    }
    
    func setupPlayer() {
        let asset = AVAsset(url: url)
        Task {
            do {
                let duration = try await asset.load(.duration)
                self.duration = CMTimeGetSeconds(duration)
            } catch {
                print("Failed to load duration: \(error)")
            }
        }
    }
    
    func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    @ObservedObject var audioManager: AudioManager
    let isSource: Bool
    @Environment(\.presentationMode) var presentationMode
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.audio])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            
            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                print("Failed to access security-scoped resource")
                return
            }
            
            // Copy the file to app's documents directory
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileName = url.lastPathComponent
            let destinationURL = documentsPath.appendingPathComponent(fileName)
            
            do {
                // Remove existing file if it exists
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                
                // Copy the file
                try FileManager.default.copyItem(at: url, to: destinationURL)
                
                // Load the copied file
                if parent.isSource {
                    parent.audioManager.loadSourceAudio(url: destinationURL)
                } else {
                    parent.audioManager.loadReferenceAudio(url: destinationURL)
                }
            } catch {
                print("Error copying file: \(error)")
            }
            
            // Stop accessing security-scoped resource
            url.stopAccessingSecurityScopedResource()
            
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

#Preview {
    ContentView()
}