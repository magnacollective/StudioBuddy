import SwiftUI
import AVFoundation

// MARK: - Studio Buddy Main Window
struct StudioBuddyWindow: View {
    @ObservedObject var audioManager: AudioManager
    @State private var isMastering = false
    @State private var masteringProgress: Double = 0
    @State private var showSourcePicker = false
    @State private var showReferencePicker = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Menu Bar
            Win95MenuBar()
            
            // Main Content
            ScrollView {
                VStack(spacing: 12) {
                    // Source Section
                    Win95GroupBox(title: "Source Audio File") {
                        VStack(spacing: 8) {
                            if let sourceURL = audioManager.sourceURL {
                                Win95AudioPlayer(
                                    url: sourceURL,
                                    filename: audioManager.sourceFileName ?? "SOURCE.WAV",
                                    audioManager: audioManager
                                )
                            } else {
                                Win95Button(
                                    title: "Browse...",
                                    iconName: "folder.fill",
                                    width: 100,
                                    action: { showSourcePicker = true }
                                )
                            }
                        }
                    }
                    
                    // Reference Section
                    Win95GroupBox(title: "Reference Audio File") {
                        VStack(spacing: 8) {
                            if let referenceURL = audioManager.referenceURL {
                                Win95AudioPlayer(
                                    url: referenceURL,
                                    filename: audioManager.referenceFileName ?? "REFERENCE.WAV",
                                    audioManager: audioManager
                                )
                            } else {
                                Win95Button(
                                    title: "Browse...",
                                    iconName: "folder.fill",
                                    width: 100,
                                    action: { showReferencePicker = true }
                                )
                            }
                        }
                    }
                    
                    // Mastering Controls
                    if audioManager.sourceURL != nil && audioManager.referenceURL != nil {
                        Win95GroupBox(title: "AI Mastering Engine") {
                            VStack(spacing: 12) {
                                if isMastering {
                                    Win95ProgressBar(value: masteringProgress, label: "Processing...")
                                }
                                
                                Win95Button(
                                    title: isMastering ? "Processing..." : "Start Mastering",
                                    iconName: "wand.and.stars",
                                    width: 150,
                                    action: startMastering,
                                    disabled: isMastering
                                )
                            }
                        }
                    }
                    
                    // Output Section + New Song box
                    if let masteredURL = audioManager.masteredURL {
                        Win95GroupBox(title: "Mastered Output") {
                            VStack(spacing: 8) {
                                Win95AudioPlayer(
                                    url: masteredURL,
                                    filename: "MASTERED.WAV",
                                    audioManager: audioManager,
                                    showExport: true,
                                    onExport: exportMasteredAudio
                                )
                                 
                                 // Browse to replace source after upload
                                 HStack(spacing: 8) {
                                     Win95Button(title: "Browse...", iconName: "folder.fill", width: 100) {
                                         showSourcePicker = true
                                     }
                                     Text("Select another source to compare or re-master")
                                         .font(.system(size: 10))
                                         .foregroundColor(Win95.Colors.buttonShadow)
                                     Spacer()
                                 }
                                
                                // ML FEEDBACK SYSTEM
                                MLFeedbackPanel(audioManager: audioManager)
                                
                                HStack(spacing: 12) {
                                    Win95Button(title: "New Song", iconName: "doc.badge.plus", width: 120) {
                                        audioManager.resetSession()
                                    }
                                    Win95Button(title: "Export...", iconName: "square.and.arrow.up", width: 120) {
                                        exportMasteredAudio()
                                    }
                                }
                            }

                    // A/B Compare Section
                    if audioManager.sourceURL != nil && audioManager.masteredURL != nil {
                        Win95GroupBox(title: "Compare: Original vs Master") {
                            VStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    Win95Button(title: audioManager.abIsPlaying ? "Pause" : "Play", iconName: audioManager.abIsPlaying ? "pause.fill" : "play.fill", width: 80) {
                                        audioManager.toggleABPlayPause()
                                    }
                                    Win95Button(title: "A: Original", width: 90) {
                                        audioManager.switchAB(activeIsMaster: false)
                                    }
                                    Win95Button(title: "B: Master", width: 90) {
                                        audioManager.switchAB(activeIsMaster: true)
                                    }
                                    Spacer()
                                }
                                
                                // Position/Seek
                                VStack(alignment: .leading, spacing: 6) {
                                    Slider(value: Binding(
                                        get: { audioManager.abCurrentTime },
                                        set: { audioManager.seekAB(to: $0) }
                                    ), in: 0...(audioManager.abDuration > 0 ? audioManager.abDuration : 1))
                                    HStack {
                                        Text(formatABTime(audioManager.abCurrentTime))
                                            .font(.system(size: 10))
                                            .foregroundColor(Win95.Colors.windowText)
                                        Spacer()
                                        Text(formatABTime(audioManager.abDuration))
                                            .font(.system(size: 10))
                                            .foregroundColor(Win95.Colors.windowText)
                                    }
                                }
                            }
                        }
                    }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Win95.Colors.windowGray)
            }
            .background(Win95.Colors.windowGray)
            
            // Status Bar
            Win95StatusBar(message: getStatusMessage())
        }
        .background(Win95.Colors.windowGray)
        .sheet(isPresented: $showSourcePicker) {
            DocumentPicker(audioManager: audioManager, isSource: true)
        }
        .sheet(isPresented: $showReferencePicker) {
            DocumentPicker(audioManager: audioManager, isSource: false)
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
        audioManager.exportMasteredAudioURL { url in
            if let url = url {
                // Present share sheet
                let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first {
                    window.rootViewController?.present(av, animated: true)
                }
            } else {
                print("Export failed")
            }
        }
    }
    
    func getStatusMessage() -> String {
        if isMastering {
            return "Processing audio mastering..."
        } else if audioManager.isPlaying {
            return "Playing audio..."
        } else {
            return "Ready"
        }
    }

    private func formatABTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Audio Analyzer Window (Combined BPM and Key)
struct AudioAnalyzerWindow: View {
    @ObservedObject var audioManager: AudioManager
    @State private var detectedBPM: Float? = nil
    @State private var detectedKey: String? = nil
    @State private var isAnalyzing = false
    @State private var analysisProgress: Double = 0
    @State private var showFilePicker = false
    @State private var selectedFile: URL? = nil
    @State private var chromaVector: [Float] = Array(repeating: 0, count: 12)
    // Local file-only analysis (no online search)
    
    let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    
    var body: some View {
        VStack(spacing: 0) {
            Win95MenuBar()
            
            ScrollView {
                VStack(spacing: 12) {
                    // File Selection
                    Win95GroupBox(title: "Audio File") {
                        VStack(spacing: 8) {
                            if let file = selectedFile {
                                HStack {
                                    Image(systemName: "music.note")
                                        .foregroundColor(Win95.Colors.windowText)
                                    Text(file.lastPathComponent)
                                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                                        .foregroundColor(Win95.Colors.windowText)
                                    Spacer()
                                }
                                .padding(8)
                                .background(Color.white)
                                .win95Border(inset: true)
                            }
                            
                            Win95Button(
                                title: "Browse...",
                                iconName: "folder.fill",
                                width: 100,
                                action: { showFilePicker = true }
                            )
                        }
                    }
                    
                    // Analysis Controls
                    Win95GroupBox(title: "Analysis Controls") {
                        VStack(spacing: 12) {
                            if isAnalyzing {
                                Win95ProgressBar(value: analysisProgress, label: "Analyzing audio...")
                            }
                            
                            EmptyView()

                            HStack(spacing: 12) {
                                Win95Button(
                                    title: "Analyze BPM",
                                    iconName: "timer",
                                    width: 120,
                                    action: analyzeBPM,
                                    disabled: selectedFile == nil || isAnalyzing
                                )
                                
                                Win95Button(
                                    title: "Analyze Key",
                                    iconName: "pianokeys",
                                    width: 120,
                                    action: analyzeKey,
                                    disabled: selectedFile == nil || isAnalyzing
                                )
                                
                                Win95Button(
                                    title: "Analyze Both",
                                    iconName: "waveform.and.mic",
                                    width: 120,
                                    action: analyzeBoth,
                                    disabled: selectedFile == nil || isAnalyzing
                                )
                            }
                        }
                    }
                    
                    // Results Section
                    HStack(alignment: .top, spacing: 12) {
                        // BPM Results
                        Win95GroupBox(title: "BPM Analysis") {
                            VStack(spacing: 12) {
                                if let bpm = detectedBPM {
                                    VStack(spacing: 8) {
                                        Text("Detected BPM:")
                                            .font(.system(size: 12))
                                            .foregroundColor(Win95.Colors.windowText)
                                        
                                        Text("\(String(format: "%.1f", bpm))")
                                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                                            .foregroundColor(Win95.Colors.windowText)
                                            .padding(12)
                                            .background(Color.white)
                                            .win95Border(inset: true)
                                        
                                        // Visual Metronome
                                        MetronomeVisualizer(bpm: bpm)
                                    }
                                } else {
                                    Text("No BPM detected")
                                        .font(.system(size: 12))
                                        .foregroundColor(Win95.Colors.buttonShadow)
                                        .padding(20)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        
                        // Key Results
                        Win95GroupBox(title: "Key Analysis") {
                            VStack(spacing: 12) {
                                if let key = detectedKey {
                                    VStack(spacing: 8) {
                                        Text("Detected Key:")
                                            .font(.system(size: 12))
                                            .foregroundColor(Win95.Colors.windowText)
                                        
                                        Text(key)
                                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                                            .foregroundColor(Win95.Colors.windowText)
                                            .padding(12)
                                            .background(Color.white)
                                            .win95Border(inset: true)
                                    }
                                } else {
                                    Text("No key detected")
                                        .font(.system(size: 12))
                                        .foregroundColor(Win95.Colors.buttonShadow)
                                        .padding(20)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    
                    // Chroma Visualization
                    if chromaVector.contains(where: { $0 > 0 }) {
                        Win95GroupBox(title: "Pitch Class Profile") {
                            ChromaVisualizer(chromaVector: chromaVector, noteNames: noteNames)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Win95.Colors.windowGray)
            }
            .background(Win95.Colors.windowGray)
            
            Win95StatusBar(message: getStatusMessage())
        }
        .background(Win95.Colors.windowGray)
        .sheet(isPresented: $showFilePicker) {
            AnalysisDocumentPicker { url in
                selectedFile = url
                detectedBPM = nil
                detectedKey = nil
                chromaVector = Array(repeating: 0, count: 12)
            }
        }
    }
    
    func analyzeBPM() {
        // Local analysis only

        guard let file = selectedFile else { return }

        isAnalyzing = true
        analysisProgress = 0
        detectedBPM = nil
        
        Task {
            // Simulate analysis progress
            for i in 1...10 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                DispatchQueue.main.async {
                    analysisProgress = Double(i) / 10.0
                }
            }
            
            let bpm = AudioAnalyzer.detectBPM(from: file) ?? 120
            
            DispatchQueue.main.async {
                detectedBPM = bpm
                isAnalyzing = false
                analysisProgress = 0
            }
        }
    }
    
    func analyzeKey() {
        // Local analysis only

        guard let file = selectedFile else { return }
        
        isAnalyzing = true
        analysisProgress = 0
        detectedKey = nil
        
        Task {
            // Simulate analysis progress
            for i in 1...10 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                DispatchQueue.main.async {
                    analysisProgress = Double(i) / 10.0
                }
            }
            
            let result = AudioAnalyzer.detectKey(from: file)
            
            DispatchQueue.main.async {
                detectedKey = result.key
                chromaVector = result.chroma ?? Array(repeating: 0, count: 12)
                isAnalyzing = false
                analysisProgress = 0
            }
        }
    }
    
    func analyzeBoth() {
        // Local analysis only

        guard let file = selectedFile else { return }
        
        isAnalyzing = true
        analysisProgress = 0
        detectedBPM = nil
        detectedKey = nil
        
        Task {
            // Simulate analysis progress
            for i in 1...20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                DispatchQueue.main.async {
                    analysisProgress = Double(i) / 20.0
                }
            }
            
            let bpm = AudioAnalyzer.detectBPM(from: file) ?? 120
            let result = AudioAnalyzer.detectKey(from: file)
            
            DispatchQueue.main.async {
                detectedBPM = bpm
                detectedKey = result.key
                chromaVector = result.chroma ?? Array(repeating: 0, count: 12)
                isAnalyzing = false
                analysisProgress = 0
            }
        }
    }
    
    func getStatusMessage() -> String {
        if isAnalyzing {
            return "Analyzing audio..."
        } else if detectedBPM != nil || detectedKey != nil {
            return "Analysis complete"
        } else {
            return "Ready"
        }
    }
}

// MARK: - Settings Window
struct SettingsWindow: View {
    @ObservedObject var audioManager: AudioManager
    @State private var audioQuality = "High"
    @State private var enableProcessing = true
    @State private var outputFormat = "WAV"
    @State private var bufferSize = "2048"
    
    let qualityOptions = ["Low", "Medium", "High", "Ultra"]
    let formatOptions = ["WAV", "AIFF", "M4A"]
    let bufferOptions = ["256", "512", "1024", "2048"]
    
    var body: some View {
        VStack(spacing: 0) {
            Win95MenuBar()
            
            ScrollView {
                VStack(spacing: 12) {
                    // Audio Settings
                    Win95GroupBox(title: "Audio Settings") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Quality:")
                                    .font(.system(size: 11))
                                    .frame(width: 80, alignment: .leading)
                                Win95Dropdown(selection: $audioQuality, options: qualityOptions)
                                Spacer()
                            }
                            
                            HStack {
                                Text("Output Format:")
                                    .font(.system(size: 11))
                                    .frame(width: 80, alignment: .leading)
                                Win95Dropdown(selection: $outputFormat, options: formatOptions)
                                Spacer()
                            }
                            
                            HStack {
                                Text("Buffer Size:")
                                    .font(.system(size: 11))
                                    .frame(width: 80, alignment: .leading)
                                Win95Dropdown(selection: $bufferSize, options: bufferOptions)
                                Spacer()
                            }
                        }
                    }
                    
                    // Processing Settings
                    Win95GroupBox(title: "Processing Options") {
                        VStack(alignment: .leading, spacing: 8) {
                            Win95Checkbox(isChecked: $enableProcessing, label: "Enable AI Processing")
                            Win95Checkbox(isChecked: .constant(true), label: "Real-time Monitoring")
                            Win95Checkbox(isChecked: .constant(false), label: "Noise Reduction")
                            Win95Checkbox(isChecked: .constant(true), label: "Auto-Gain Control")
                        }
                    }
                    
                    // System Info
                    Win95GroupBox(title: "System Information") {
                        VStack(alignment: .leading, spacing: 8) {
                            SystemInfoRow(label: "Version:", value: "1.0.0")
                            SystemInfoRow(label: "Build:", value: "95.11.08")
                            SystemInfoRow(label: "Memory:", value: "16 MB")
                            SystemInfoRow(label: "Disk Space:", value: "2.1 GB Free")
                        }
                    }
                    
                    // About
                    Win95GroupBox(title: "About Studio Buddy 95") {
                        VStack(spacing: 8) {
                            Text("Studio Buddy Professional Edition")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Win95.Colors.windowText)
                            
                            Text("AI-Powered Audio Mastering Suite")
                                .font(.system(size: 11))
                                .foregroundColor(Win95.Colors.windowText)
                            
                            Text("Copyright © 1995 Audio Systems Inc.")
                                .font(.system(size: 10))
                                .foregroundColor(Win95.Colors.buttonShadow)
                                .padding(.top, 8)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .onChange(of: bufferSize) { newValue in
                    if let frames = Int(newValue) {
                        audioManager.setIOBufferFrames(frames: frames)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Win95.Colors.windowGray)
            }
            .background(Win95.Colors.windowGray)
            
            Win95StatusBar(message: "Settings ready")
        }
        .background(Win95.Colors.windowGray)
    }
}

// MARK: - Settings UI Components
struct Win95Dropdown: View {
    @Binding var selection: String
    let options: [String]
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Text(selection)
                        .font(.system(size: 11))
                        .foregroundColor(Win95.Colors.windowText)
                    Spacer()
                    Text(isExpanded ? "▲" : "▼")
                        .font(.system(size: 8))
                        .foregroundColor(Win95.Colors.windowText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: 120)
                .background(Color.white)
                .win95Border(inset: true)
            }
            .buttonStyle(PlainButtonStyle())
            
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        Button(action: {
                            selection = option
                            isExpanded = false
                        }) {
                            HStack {
                                Text(option)
                                    .font(.system(size: 11))
                                    .foregroundColor(Win95.Colors.windowText)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .frame(width: 120)
                            .background(selection == option ? Win95.Colors.selection : Color.white)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .background(Color.white)
                .win95Border(inset: true)
                .zIndex(1)
            }
        }
    }
}

struct Win95Checkbox: View {
    @Binding var isChecked: Bool
    let label: String
    
    var body: some View {
        Button(action: { isChecked.toggle() }) {
            HStack(spacing: 8) {
                ZStack {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .win95Border(inset: true)
                    
                    if isChecked {
                        Text("✓")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Win95.Colors.windowText)
                    }
                }
                
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(Win95.Colors.windowText)
                
                Spacer()
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SystemInfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Win95.Colors.windowText)
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Win95.Colors.windowText)
            
            Spacer()
        }
    }
}

// MARK: - Windows 95 UI Components

struct Win95MenuBar: View {
    var body: some View {
        HStack(spacing: 16) {
            ForEach(["File", "Edit", "View", "Tools", "Help"], id: \.self) { menu in
                Text(menu)
                    .font(.system(size: 11))
                    .foregroundColor(Win95.Colors.windowText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            Spacer()
        }
        .background(Win95.Colors.menuBar)
        .frame(height: Win95.Metrics.menuBarHeight)
    }
}

struct Win95GroupBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Win95.Colors.windowText)
                .padding(.horizontal, 8)
                .background(Win95.Colors.windowGray)
                .offset(y: 6)
                .zIndex(1)
            
            VStack {
                content()
            }
            .padding(12)
            .background(Win95.Colors.windowGray)
            .win95Border(inset: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Win95Button: View {
    let title: String
    let iconName: String?
    let width: CGFloat?
    let action: () -> Void
    var disabled: Bool = false
    
    @State private var isPressed = false
    
    init(title: String, iconName: String? = nil, width: CGFloat? = nil, action: @escaping () -> Void, disabled: Bool = false) {
        self.title = title
        self.iconName = iconName
        self.width = width
        self.action = action
        self.disabled = disabled
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let iconName = iconName {
                    Image(systemName: iconName)
                        .font(.system(size: 12))
                        .foregroundColor(disabled ? Win95.Colors.buttonShadow : Win95.Colors.windowText)
                }
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(disabled ? Win95.Colors.buttonShadow : Win95.Colors.windowText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(width: width)
            .background(Win95.Colors.buttonFace)
            .win95Border(inset: isPressed)
        }
        .disabled(disabled)
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            isPressed = pressing && !disabled
        }, perform: {})
    }
}

struct Win95AudioPlayer: View {
    let url: URL
    let filename: String
    @ObservedObject var audioManager: AudioManager
    var showExport: Bool = false
    var onExport: (() -> Void)? = nil
    
    private var isPlaying: Bool {
        audioManager.currentlyPlayingURL == url && audioManager.isPlaying
    }
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "doc.richtext")
                    .foregroundColor(Win95.Colors.windowText)
                Text(filename)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(Win95.Colors.windowText)
                Spacer()
                if showExport, let onExport = onExport {
                    Win95Button(title: "Export...", iconName: "square.and.arrow.up", action: onExport)
                }
            }
            
            HStack(spacing: 8) {
                // Transport Controls
                Win95MediaButton(symbol: "Play", isActive: isPlaying) {
                    if isPlaying {
                        audioManager.pausePlayback()
                    } else {
                        audioManager.startPlayback(url: url)
                    }
                }
                
                Win95MediaButton(symbol: "Stop", isActive: false) {
                    audioManager.stopPlayback()
                }
                
                // VU Meter
                VUMeter(isPlaying: isPlaying)
                
                Spacer()
            }
        }
        .padding(8)
        .background(Color.white)
        .win95Border(inset: true)
    }
}

struct Win95MediaButton: View {
    let symbol: String
    let isActive: Bool
    let action: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            Text(symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isActive ? Win95.Colors.highlightedText : Win95.Colors.windowText)
                .frame(width: 40, height: 24)
                .background(isActive ? Win95.Colors.activeTitle : Win95.Colors.buttonFace)
                .win95Border(inset: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
    }
}

struct Win95ProgressBar: View {
    let value: Double
    let label: String?
    
    init(value: Double, label: String? = nil) {
        self.value = value
        self.label = label
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = label {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(Win95.Colors.windowText)
            }
            
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(0..<Int(geometry.size.width / 8), id: \.self) { index in
                        Rectangle()
                            .fill(Double(index) / Double(Int(geometry.size.width / 8)) <= value ? 
                                  Win95.Colors.activeTitle : Win95.Colors.buttonFace)
                            .frame(width: 6, height: 16)
                    }
                }
            }
            .frame(height: 16)
            .win95Border(inset: true)
        }
    }
}

struct Win95StatusBar: View {
    let message: String
    
    var body: some View {
        HStack {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Win95.Colors.windowText)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Win95.Colors.buttonFace)
        .win95Border(inset: true)
    }
}

// MARK: - Visualizers

struct VUMeter: View {
    let isPlaying: Bool
    @State private var levels: [Float] = Array(repeating: 0, count: 20)
    
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<levels.count, id: \.self) { index in
                Rectangle()
                    .fill(getLevelColor(for: index, level: levels[index]))
                    .frame(width: 3, height: 16)
            }
        }
        .padding(4)
        .background(Color.black)
        .win95Border(inset: true)
        .onReceive(timer) { _ in
            if isPlaying {
                levels = levels.map { _ in Float.random(in: 0...1) }
            } else {
                levels = Array(repeating: 0, count: 20)
            }
        }
    }
    
    func getLevelColor(for index: Int, level: Float) -> Color {
        let threshold = Float(index) / Float(levels.count)
        if level > threshold {
            if index < 14 {
                return .green
            } else if index < 18 {
                return .yellow
            } else {
                return .red
            }
        }
        return Win95.Colors.buttonShadow
    }
}

struct MetronomeVisualizer: View {
    let bpm: Float
    @State private var isBeating = false
    
    var body: some View {
        HStack(spacing: 20) {
            Circle()
                .fill(isBeating ? Win95.Colors.activeTitle : Win95.Colors.buttonShadow)
                .frame(width: 20, height: 20)
                .scaleEffect(isBeating ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isBeating)
            
            Text("\(String(format: "%.1f", bpm)) BPM")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Win95.Colors.windowText)
        }
        .padding(20)
        .onAppear {
            startMetronome()
        }
    }
    
    func startMetronome() {
        let interval = 60.0 / Double(bpm)
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            withAnimation {
                isBeating = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    isBeating = false
                }
            }
        }
    }
}

struct ChromaVisualizer: View {
    let chromaVector: [Float]
    let noteNames: [String]
    
    var body: some View {
        VStack(spacing: 8) {
            // Circular chroma wheel
            ZStack {
                Circle()
                    .stroke(Win95.Colors.buttonShadow, lineWidth: 2)
                    .frame(width: 200, height: 200)
                
                ForEach(0..<12, id: \.self) { index in
                    let angle = Double(index) * 30.0 - 90.0
                    let radius = 80.0
                    let intensity = chromaVector[index]
                    
                    VStack(spacing: 2) {
                        Circle()
                            .fill(Color.blue.opacity(Double(intensity)))
                            .frame(width: 12, height: 12)
                        Text(noteNames[index])
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Win95.Colors.windowText)
                    }
                    .offset(
                        x: cos(angle * .pi / 180) * radius,
                        y: sin(angle * .pi / 180) * radius
                    )
                }
            }
            .frame(width: 220, height: 220)
            
            // Bar chart
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { index in
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(Win95.Colors.activeTitle)
                            .frame(width: 15, height: CGFloat(chromaVector[index] * 60))
                        Text(noteNames[index])
                            .font(.system(size: 9))
                            .foregroundColor(Win95.Colors.windowText)
                    }
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Custom Document Picker for Analysis Windows
struct AnalysisDocumentPicker: UIViewControllerRepresentable {
    let onFileSelected: (URL) -> Void
    @Environment(\.presentationMode) var presentationMode
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: AnalysisDocumentPicker
        
        init(_ parent: AnalysisDocumentPicker) {
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
                
                // Notify the parent
                parent.onFileSelected(destinationURL)
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

// MARK: - ML FEEDBACK PANEL
struct MLFeedbackPanel: View {
    @ObservedObject var audioManager: AudioManager
    @State private var selectedGenre = "Hip Hop"
    @State private var showFeedback = false
    
    let genres = ["Hip Hop", "Rock", "Pop", "Electronic", "Jazz", "Classical", "R&B", "Alternative"]
    
    var body: some View {
        Win95GroupBox(title: "🤖 AI Learning System") {
            VStack(spacing: 8) {
                if let lastGenre = audioManager.lastDetectedGenre {
                    HStack {
                        Text("AI Detected:")
                            .font(.system(size: 11))
                            .foregroundColor(Win95.Colors.windowText)
                        
                        Text(lastGenre)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Win95.Colors.activeTitle)
                        
                        Spacer()
                        
                        Win95Button(title: "Correct?", iconName: "questionmark.circle", width: 80) {
                            showFeedback.toggle()
                        }
                    }
                    
                    if showFeedback {
                        VStack(spacing: 6) {
                            Text("What genre is this actually?")
                                .font(.system(size: 10))
                                .foregroundColor(Win95.Colors.windowText)
                            
                            HStack(spacing: 4) {
                                ForEach(genres.prefix(4), id: \.self) { genre in
                                    Win95Button(title: genre, width: 60) {
                                        submitFeedback(correctGenre: genre)
                                    }
                                }
                            }
                            
                            HStack(spacing: 4) {
                                ForEach(genres.dropFirst(4), id: \.self) { genre in
                                    Win95Button(title: genre, width: 60) {
                                        submitFeedback(correctGenre: genre)
                                    }
                                }
                            }
                            
                            Win95Button(title: "✓ AI was correct", iconName: "checkmark.circle", width: 120) {
                                submitFeedback(correctGenre: lastGenre)
                            }
                        }
                        .padding(6)
                        .background(Color.white)
                        .win95Border(inset: true)
                    }
                }
            }
        }
    }
    
    private func submitFeedback(correctGenre: String) {
         guard let features = audioManager.lastSourceFeatures,
               let detectedGenre = audioManager.lastDetectedGenre else { return }
        
        // Record the user's feedback for ML learning
         audioManager.recordUserFeedback(
             features: features,
             predictedGenre: detectedGenre,
             actualGenre: correctGenre,
             confidence: 0.9
         )
        
        showFeedback = false
        
        // Show success message
        print("📚 Thank you! Learning from your feedback: \(correctGenre)")
    }
}
