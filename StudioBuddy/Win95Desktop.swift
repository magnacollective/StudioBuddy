import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Windows 95 Color System
struct Win95 {
    struct Colors {
        static let desktop = Color(red: 0/255, green: 128/255, blue: 128/255)
        static let windowGray = Color(red: 192/255, green: 192/255, blue: 192/255)
        static let buttonFace = Color(red: 192/255, green: 192/255, blue: 192/255)
        static let buttonHighlight = Color(red: 255/255, green: 255/255, blue: 255/255)
        static let buttonShadow = Color(red: 128/255, green: 128/255, blue: 128/255)
        static let buttonDarkShadow = Color(red: 0/255, green: 0/255, blue: 0/255)
        static let buttonLight = Color(red: 223/255, green: 223/255, blue: 223/255)
        static let activeTitle = Color(red: 0/255, green: 0/255, blue: 128/255)
        static let inactiveTitle = Color(red: 128/255, green: 128/255, blue: 128/255)
        static let windowFrame = Color(red: 0/255, green: 0/255, blue: 0/255)
        static let menuBar = Color(red: 192/255, green: 192/255, blue: 192/255)
        static let windowText = Color(red: 0/255, green: 0/255, blue: 0/255)
        static let highlightedText = Color(red: 255/255, green: 255/255, blue: 255/255)
        static let selection = Color(red: 0/255, green: 0/255, blue: 128/255)
    }
    
    struct Metrics {
        static let titleBarHeight: CGFloat = 18
        static let menuBarHeight: CGFloat = 20
        static let borderWidth: CGFloat = 2
        static let buttonSize: CGFloat = 16
        static let iconSize: CGFloat = 32
        static let desktopIconSize: CGFloat = 48
    }
}

// MARK: - Main Desktop View
struct Win95Desktop: View {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var windowManager = WindowManager()
    @State private var selectedIcon: String? = nil
    
    var body: some View {
        GeometryReader { fullGeometry in
            ZStack {
                // Matrix Background
                MatrixBackground()
                    .ignoresSafeArea()
            
            // Desktop Icons
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 20) {
                        DesktopIcon(
                            title: "Studio Buddy",
                            iconType: .musicNote,
                            isSelected: selectedIcon == "studio",
                            onTap: {
                                selectedIcon = "studio"
                                windowManager.openWindow(.studioBuddy)
                            }
                        )
                        
                        DesktopIcon(
                            title: "Key/BPM Analyzer",
                            iconType: .analyzer,
                            isSelected: selectedIcon == "analyzer",
                            onTap: {
                                selectedIcon = "analyzer"
                                windowManager.openWindow(.audioAnalyzer)
                            }
                        )
                        
                        DesktopIcon(
                            title: "Settings",
                            iconType: .settings,
                            isSelected: selectedIcon == "settings",
                            onTap: {
                                selectedIcon = "settings"
                                windowManager.openWindow(.settings)
                            }
                        )
                        
                        Spacer()
                    }
                    .padding(.leading, 20)
                    .padding(.top, 20)
                    
                    Spacer()
                }
                
                Spacer()
            }
            
            // Windows
            GeometryReader { geometry in
                ForEach(windowManager.windows) { window in
                    Win95Window(
                        window: window,
                        audioManager: audioManager,
                        windowManager: windowManager,
                        maxSize: CGSize(
                            width: min(window.size.width, geometry.size.width - 40),
                            height: min(window.size.height, geometry.size.height - 80)
                        )
                    )
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2 - 14 // Account for taskbar
                    )
                }
            }
            
            // Taskbar
            VStack {
                Spacer()
                Win95Taskbar(windowManager: windowManager)
            }
            }
            .onTapGesture {
                selectedIcon = nil
            }
        }
    }
}

// MARK: - Desktop Icon
struct DesktopIcon: View {
    let title: String
    let iconType: IconType
    let isSelected: Bool
    let onTap: () -> Void
    
    enum IconType {
        case musicNote, analyzer, settings, folder, document
        
        var systemName: String {
            switch self {
            case .musicNote: return "music.note"
            case .analyzer: return "waveform.and.mic"
            case .settings: return "gearshape.fill"
            case .folder: return "folder.fill"
            case .document: return "doc.fill"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Icon background (transparent with dotted border when selected)
                if isSelected {
                    Rectangle()
                        .fill(Win95.Colors.selection.opacity(0.3))
                        .overlay(
                            Rectangle()
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                .foregroundColor(Win95.Colors.selection)
                        )
                }
                
                // Icon
                Image(systemName: iconType.systemName)
                    .font(.system(size: Win95.Metrics.desktopIconSize))
                    .foregroundColor(isSelected ? .white : Win95.Colors.buttonHighlight)
            }
            .frame(width: Win95.Metrics.desktopIconSize + 8, height: Win95.Metrics.desktopIconSize + 8)
            
            // Label
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? Win95.Colors.highlightedText : .white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(isSelected ? Win95.Colors.selection : Color.clear)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)
        }
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Window Manager
class WindowManager: ObservableObject {
    @Published var windows: [WindowState] = []
    @Published var activeWindowId: UUID? = nil
    
    func openWindow(_ type: WindowType) {
        // Check if window already exists
        if let existingWindow = windows.first(where: { $0.type == type }) {
            activeWindowId = existingWindow.id
            return
        }
        
        let newWindow = WindowState(type: type)
        windows.append(newWindow)
        activeWindowId = newWindow.id
    }
    
    func closeWindow(_ id: UUID) {
        windows.removeAll { $0.id == id }
        if activeWindowId == id {
            activeWindowId = windows.last?.id
        }
    }
    
    func minimizeWindow(_ id: UUID) {
        if let index = windows.firstIndex(where: { $0.id == id }) {
            windows[index].isMinimized = true
        }
    }
    
    func restoreWindow(_ id: UUID) {
        if let index = windows.firstIndex(where: { $0.id == id }) {
            windows[index].isMinimized = false
            activeWindowId = id
        }
    }
    
    func setActiveWindow(_ id: UUID) {
        activeWindowId = id
    }
    
    func closeAllWindows() {
        windows.removeAll()
        activeWindowId = nil
    }
}

// MARK: - Window State
struct WindowState: Identifiable {
    let id = UUID()
    let type: WindowType
    var position = CGPoint(x: 0, y: 0) // Will be centered programmatically
    var size = CGSize(width: 600, height: 500)
    var isMinimized = false
}

enum WindowType: Equatable {
    case studioBuddy
    case audioAnalyzer
    case settings
    
    var title: String {
        switch self {
        case .studioBuddy: return "Studio Buddy - Audio Mastering Professional"
        case .audioAnalyzer: return "Key/BPM Analyzer Professional"
        case .settings: return "System Settings"
        }
    }
}

// MARK: - Windows 95 Window Chrome
struct Win95Window: View {
    let window: WindowState
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var windowManager: WindowManager
    let maxSize: CGSize
    
    var isActive: Bool {
        windowManager.activeWindowId == window.id
    }
    
    var constrainedSize: CGSize {
        CGSize(
            width: min(window.size.width, maxSize.width),
            height: min(window.size.height, maxSize.height)
        )
    }
    
    var body: some View {
        if !window.isMinimized {
            VStack(spacing: 0) {
                // Title Bar
                Win95TitleBar(
                    title: window.type.title,
                    isActive: isActive,
                    onClose: { windowManager.closeWindow(window.id) },
                    onMinimize: { windowManager.minimizeWindow(window.id) },
                    onMaximize: { }
                )
                
                // Window Content
                Group {
                    switch window.type {
                    case .studioBuddy:
                        StudioBuddyWindow(audioManager: audioManager)
                    case .audioAnalyzer:
                        AudioAnalyzerWindow(audioManager: audioManager)
                    case .settings:
                        SettingsWindow(audioManager: audioManager)
                    }
                }
                .frame(width: constrainedSize.width, height: constrainedSize.height - Win95.Metrics.titleBarHeight)
                .background(Win95.Colors.windowGray)
                .border(Win95.Colors.windowFrame, width: Win95.Metrics.borderWidth)
            }
            .frame(width: constrainedSize.width, height: constrainedSize.height)
            .background(Win95.Colors.windowGray)
            .win95Border(inset: false)
            .onTapGesture {
                windowManager.setActiveWindow(window.id)
            }
        }
    }
}

// MARK: - Title Bar
struct Win95TitleBar: View {
    let title: String
    let isActive: Bool
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onMaximize: () -> Void
    
    var body: some View {
        HStack(spacing: 2) {
            // Icon
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 12))
                .foregroundColor(isActive ? .white : Win95.Colors.buttonLight)
            
            // Title
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(isActive ? .white : Win95.Colors.buttonLight)
                .lineLimit(1)
            
            Spacer()
            
            // Window Controls
            HStack(spacing: 2) {
                TitleBarButton(symbol: "_", action: onMinimize)
                TitleBarButton(symbol: "□", action: onMaximize)
                TitleBarButton(symbol: "×", action: onClose)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: Win95.Metrics.titleBarHeight)
        .background(
            LinearGradient(
                gradient: Gradient(colors: isActive ? 
                    [Win95.Colors.activeTitle, Win95.Colors.activeTitle.opacity(0.8)] :
                    [Win95.Colors.inactiveTitle, Win95.Colors.inactiveTitle]),
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}

// MARK: - Title Bar Button
struct TitleBarButton: View {
    let symbol: String
    let action: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            Text(symbol)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Win95.Colors.windowText)
                .frame(width: Win95.Metrics.buttonSize, height: Win95.Metrics.buttonSize - 2)
                .background(Win95.Colors.buttonFace)
                .win95Border(inset: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
    }
}

// MARK: - Taskbar
struct Win95Taskbar: View {
    @ObservedObject var windowManager: WindowManager
    @State private var currentTime = Date()
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 2) {
            // Home Button
            HomeButton {
                windowManager.closeAllWindows()
            }
            
            // Quick Launch Bar
            Rectangle()
                .fill(Win95.Colors.buttonShadow)
                .frame(width: 1, height: 22)
            
            // Task buttons
            ForEach(windowManager.windows) { window in
                TaskButton(
                    title: shortTitle(for: window.type),
                    isActive: windowManager.activeWindowId == window.id,
                    isMinimized: window.isMinimized
                ) {
                    if window.isMinimized {
                        windowManager.restoreWindow(window.id)
                    } else {
                        windowManager.setActiveWindow(window.id)
                    }
                }
            }
            
            Spacer()
            
            // System Tray
            SystemTray(currentTime: currentTime)
                .onReceive(timer) { _ in
                    currentTime = Date()
                }
        }
        .padding(.horizontal, 2)
        .frame(height: 28)
        .background(Win95.Colors.buttonFace)
        .win95Border(inset: false)
    }
    
    func shortTitle(for type: WindowType) -> String {
        switch type {
        case .studioBuddy: return "Studio Buddy"
        case .audioAnalyzer: return "Key/BPM Analyzer"
        case .settings: return "Settings"
        }
    }
}

// MARK: - Home Button
struct HomeButton: View {
    let action: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "house.fill")
                    .font(.system(size: 12))
                Text("Home")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(Win95.Colors.windowText)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Win95.Colors.buttonFace)
            .win95Border(inset: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
    }
}

// MARK: - Task Button
struct TaskButton: View {
    let title: String
    let isActive: Bool
    let isMinimized: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Win95.Colors.windowText)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minWidth: 120, maxWidth: 160, maxHeight: 22)
                .background(Win95.Colors.buttonFace)
                .win95Border(inset: isActive && !isMinimized)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - System Tray
struct SystemTray: View {
    let currentTime: Date
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12))
            
            Text(currentTime, style: .time)
                .font(.system(size: 11))
        }
        .foregroundColor(Win95.Colors.windowText)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Win95.Colors.buttonFace)
        .win95Border(inset: true)
    }
}

// MARK: - 3D Border Modifier
struct Win95Border: ViewModifier {
    let inset: Bool
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    Path { path in
                        let rect = CGRect(origin: .zero, size: geometry.size)
                        
                        // Top edge
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                        
                        // Left edge
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    }
                    .stroke(inset ? Win95.Colors.buttonShadow : Win95.Colors.buttonHighlight, lineWidth: 1)
                    
                    Path { path in
                        let rect = CGRect(origin: .zero, size: geometry.size)
                        
                        // Bottom edge
                        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                        
                        // Right edge
                        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    }
                    .stroke(inset ? Win95.Colors.buttonHighlight : Win95.Colors.buttonShadow, lineWidth: 1)
                    
                    // Inner border
                    Path { path in
                        let rect = CGRect(origin: CGPoint(x: 1, y: 1), 
                                        size: CGSize(width: geometry.size.width - 2, 
                                                   height: geometry.size.height - 2))
                        
                        // Top edge
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                        
                        // Left edge
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    }
                    .stroke(inset ? Win95.Colors.buttonDarkShadow : Win95.Colors.buttonLight, lineWidth: 1)
                    
                    Path { path in
                        let rect = CGRect(origin: CGPoint(x: 1, y: 1), 
                                        size: CGSize(width: geometry.size.width - 2, 
                                                   height: geometry.size.height - 2))
                        
                        // Bottom edge
                        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                        
                        // Right edge
                        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    }
                    .stroke(inset ? Win95.Colors.buttonLight : Win95.Colors.buttonDarkShadow, lineWidth: 1)
                }
            )
    }
}

extension View {
    func win95Border(inset: Bool) -> some View {
        modifier(Win95Border(inset: inset))
    }
}

// MARK: - Matrix Background
struct MatrixBackground: View {
    @State private var columns: [MatrixColumn] = []
    @State private var screenSize: CGSize = .zero
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                
                ForEach(columns) { column in
                    MatrixColumnView(column: column)
                }
            }
            .onAppear {
                screenSize = geometry.size
                setupColumns()
                startAnimation()
            }
            .onChange(of: geometry.size) { newSize in
                screenSize = newSize
                setupColumns()
            }
        }
    }
    
    private func setupColumns() {
        let columnWidth: CGFloat = 20
        let columnCount = Int(screenSize.width / columnWidth)
        
        columns = (0..<columnCount).map { index in
            MatrixColumn(
                id: index,
                x: CGFloat(index) * columnWidth,
                characters: generateRandomCharacters(),
                speed: Double.random(in: 0.5...2.0),
                yOffset: Double.random(in: -500...0)
            )
        }
    }
    
    private func generateRandomCharacters() -> [String] {
        let matrixChars = ["0", "1", "ア", "カ", "サ", "タ", "ナ", "ハ", "マ", "ヤ", "ラ", "ワ", "Z", "Ψ", "Ω", "α", "β", "γ", "δ", "ε", "λ", "μ", "π", "σ", "φ", "χ", "ψ", "ω"]
        return (0..<Int.random(in: 15...25)).map { _ in matrixChars.randomElement() ?? "0" }
    }
    
    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            for index in columns.indices {
                columns[index].yOffset += columns[index].speed * 10
                
                if columns[index].yOffset > Double(screenSize.height + 200) {
                    columns[index].yOffset = -500
                    columns[index].characters = generateRandomCharacters()
                    columns[index].speed = Double.random(in: 0.5...2.0)
                }
            }
        }
    }
}

struct MatrixColumn: Identifiable {
    let id: Int
    let x: CGFloat
    var characters: [String]
    var speed: Double
    var yOffset: Double
}

struct MatrixColumnView: View {
    let column: MatrixColumn
    
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<column.characters.count, id: \.self) { index in
                Text(column.characters[index])
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(matrixGreen(for: index))
            }
        }
        .position(x: column.x, y: CGFloat(column.yOffset))
    }
    
    private func matrixGreen(for index: Int) -> Color {
        let intensity = 1.0 - (Double(index) / Double(column.characters.count))
        return Color.green.opacity(intensity * 0.8 + 0.2)
    }
}

#Preview {
    Win95Desktop()
}