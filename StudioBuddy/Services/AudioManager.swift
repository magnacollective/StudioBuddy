import Foundation
import AVFoundation
import AVFAudio
import Accelerate
import Combine

class AudioManager: ObservableObject {
    @Published var sourceURL: URL?
    @Published var referenceURL: URL?
    @Published var masteredURL: URL?
    @Published var sourceFileName: String?
    @Published var referenceFileName: String?
    @Published var currentlyPlayingURL: URL?
    @Published var isPlaying: Bool = false
    @Published var lastDetectedGenre: String?
    var lastSourceFeatures: AudioFeatures?
    
    // A/B compare state
    @Published var abIsPlaying: Bool = false
    @Published var abActiveIsMaster: Bool = false // false = Original (A), true = Master (B)
    @Published var abCurrentTime: TimeInterval = 0
    @Published var abDuration: TimeInterval = 0
    
    private var audioPlayer: AVAudioPlayer?
    private var originalPlayer: AVAudioPlayer?
    private var masterPlayer: AVAudioPlayer?
    private var abTimer: Timer?
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    
    // Graphic EQ: 10 bands + pre/post filters (HPF/LPF)
    // Centers roughly ISO 10-band: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k
    private let eqCenterFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    private let eqQValues: [Float] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.9]
    private let eqBandEdges: [Float] = [20, 45, 90, 180, 360, 700, 1400, 2800, 5600, 11200, 18000]
    
    init() {
        setupAudioEngine()
    }
    
    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: nil)
        
        do {
            let session = AVAudioSession.sharedInstance()
            // Use playback category without Bluetooth options (not valid for .playback) and avoid overriding output port
            try session.setCategory(.playback, mode: .default, options: [])
            // Set preferred hardware values before activating
            try? session.setPreferredSampleRate(48000.0)
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            
            if hasExternalOutput(session: session) {
                print("🎧 External audio route detected")
            } else {
                print("🔊 Using built-in speaker route")
            }
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    func loadSourceAudio(url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.sourceURL = url
            self.sourceFileName = url.lastPathComponent
        }
    }
    
    func loadReferenceAudio(url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.referenceURL = url
            self.referenceFileName = url.lastPathComponent
        }
    }
    
    func startPlayback(url: URL) {
        do {
            // Stop any current playback
            audioPlayer?.stop()
            
            // Ensure session is active (no output port override for .playback)
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(true)
            
            // Create and configure new player with proper format handling
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.volume = 1.0 // Full volume
            
            // Enable meteringEnabled for proper audio handling
            audioPlayer?.isMeteringEnabled = true
            
            // Set audio player properties to prevent distortion
            if let player = audioPlayer {
                player.prepareToPlay()
                print("Audio format - Sample Rate: \(player.format.sampleRate), Channels: \(player.format.channelCount)")
            }
            
            audioPlayer?.play()
            
            // Update state on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.currentlyPlayingURL = url
                self.isPlaying = true
            }
            
            print("Started playback of: \(url.lastPathComponent)")
        } catch {
            print("Failed to play audio: \(error)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.currentlyPlayingURL = nil
                self.isPlaying = false
            }
        }
    }
    
    func pausePlayback() {
        audioPlayer?.pause()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isPlaying = false
        }
        print("Paused playback")
    }
    
    func stopPlayback() {
        audioPlayer?.stop()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentlyPlayingURL = nil
            self.isPlaying = false
        }
        print("Stopped playback")
    }
    
    // MARK: - A/B Compare Controls
    func setupABPlayers() {
        guard let src = sourceURL, let master = masteredURL else { return }
        do {
            originalPlayer = try AVAudioPlayer(contentsOf: src)
            masterPlayer = try AVAudioPlayer(contentsOf: master)
            
            // Configure both players for optimal playback
            originalPlayer?.isMeteringEnabled = true
            masterPlayer?.isMeteringEnabled = true
            
            originalPlayer?.prepareToPlay()
            masterPlayer?.prepareToPlay()
            originalPlayer?.volume = 1.0 // Full volume
            masterPlayer?.volume = 1.0   // Full volume
            abDuration = min(originalPlayer?.duration ?? 0, masterPlayer?.duration ?? 0)
        } catch {
            print("Failed to setup A/B players: \(error)")
        }
    }
    
    func startAB() {
        setupABPlayers()
        guard let originalPlayer, let masterPlayer else { return }
        originalPlayer.currentTime = abCurrentTime
        masterPlayer.currentTime = abCurrentTime
        if abActiveIsMaster {
            masterPlayer.play()
            originalPlayer.pause()
        } else {
            originalPlayer.play()
            masterPlayer.pause()
        }
        abIsPlaying = true
        startABTimer()
    }
    
    func pauseAB() {
        originalPlayer?.pause()
        masterPlayer?.pause()
        abIsPlaying = false
        abTimer?.invalidate()
    }
    
    func stopAB() {
        originalPlayer?.stop()
        masterPlayer?.stop()
        abIsPlaying = false
        abTimer?.invalidate()
        abCurrentTime = 0
    }
    
    func toggleABPlayPause() {
        abIsPlaying ? pauseAB() : startAB()
    }
    
    func switchAB(activeIsMaster: Bool) {
        guard originalPlayer != nil || masterPlayer != nil else { return }
        abActiveIsMaster = activeIsMaster
        if abIsPlaying {
            if activeIsMaster {
                originalPlayer?.pause()
                masterPlayer?.currentTime = abCurrentTime
                masterPlayer?.play()
            } else {
                masterPlayer?.pause()
                originalPlayer?.currentTime = abCurrentTime
                originalPlayer?.play()
            }
        }
    }
    
    func seekAB(to time: TimeInterval) {
        abCurrentTime = max(0, min(time, abDuration))
        originalPlayer?.currentTime = abCurrentTime
        masterPlayer?.currentTime = abCurrentTime
    }
    
    private func startABTimer() {
        abTimer?.invalidate()
        abTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.abActiveIsMaster {
                self.abCurrentTime = self.masterPlayer?.currentTime ?? self.abCurrentTime
            } else {
                self.abCurrentTime = self.originalPlayer?.currentTime ?? self.abCurrentTime
            }
            if self.abCurrentTime >= self.abDuration {
                self.pauseAB()
            }
        }
    }
    
    func togglePlayback(url: URL) {
        if currentlyPlayingURL == url && isPlaying {
            pausePlayback()
        } else {
            startPlayback(url: url)
        }
    }
    
    func startMastering(progressHandler: @escaping (Double) -> Void) async {
        print("Starting mastering process...")
        guard let sourceURL = sourceURL,
              let referenceURL = referenceURL else {
            print("Error: Source or Reference URL is nil")
            print("Source URL: \(String(describing: self.sourceURL))")
            print("Reference URL: \(String(describing: self.referenceURL))")
            return
        }
        
        print("URLs validated. Source: \(sourceURL.lastPathComponent), Reference: \(referenceURL.lastPathComponent)")
        
        progressHandler(0.1)
        print("Progress: 10%")
        
        // Remote mastering via backend (Railway + Matchering)
        let backendBaseURL = URL(string: "https://studiobuddy-production.up.railway.app")!
        print("Warming backend...")
        do {
            if try await warmUpBackend(serverBaseURL: backendBaseURL) {
                print("Backend is warm. Uploading tracks to backend for mastering...")
            } else {
                print("Backend warm-up failed or timed out. Proceeding anyway...")
            }
        } catch {
            print("Backend warm-up error: \(error). Proceeding anyway...")
        }
        
        print("Uploading tracks to backend for mastering...")
        let masteredAudio = await masterViaBackend(serverBaseURL: backendBaseURL, targetURL: sourceURL, referenceURL: referenceURL, progressHandler: progressHandler)
        
        if let masteredAudio {
            await MainActor.run {
                self.masteredURL = masteredAudio
                print("Mastered URL set: \(masteredAudio.lastPathComponent)")
            }
            progressHandler(1.0)
            print("Mastering complete!")
            return
        }

        // Fallback to on-device mastering if backend fails or is unreachable
        print("Backend mastering failed or unreachable. Falling back to on-device mastering...")
        progressHandler(0.2)
        let sourceFeatures = await extractAudioFeatures(from: sourceURL)
        progressHandler(0.4)
        let referenceFeatures = await extractAudioFeatures(from: referenceURL)
        progressHandler(0.6)
        let localMaster = await applyMastering(
            source: sourceURL,
            sourceFeatures: sourceFeatures,
            referenceFeatures: referenceFeatures,
            progressHandler: progressHandler
        )
        await MainActor.run {
            self.masteredURL = localMaster
            if let localMaster { print("Mastered URL set (local): \(localMaster.lastPathComponent)") }
        }
        progressHandler(1.0)
        print("Mastering complete (local fallback)!")
    }
    
    // Note: Python/Matchering integration reverted; not feasible on iOS due to sandboxing and no native Python runtime. Use Swift implementation or explore Python embedding for advanced setups.
    
    private func extractAudioFeatures(from url: URL) async -> AudioFeatures {
        print("Extracting features from: \(url.lastPathComponent)")
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = UInt32(file.length)
            
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                print("Error: Failed to create audio buffer")
                return AudioFeatures()
            }
            
            try file.read(into: buffer)
            
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(frameCount)))
            
            // Basic audio features
            let rms = calculateRMS(samples: samples)
            let peak = samples.map { abs($0) }.max() ?? 0
            let spectralCentroid = calculateSpectralCentroid(samples: samples, sampleRate: Float(format.sampleRate))
            let (bass, mid, treble) = calculateFrequencyBands(samples: samples, sampleRate: Float(format.sampleRate))
            
            // SIMPLIFIED FEATURE EXTRACTION (No AI/ML - Faster)
            print("🚀 Fast feature extraction - no AI/ML analysis")
            
            var features = AudioFeatures()
            features.rms = rms
            features.peak = peak
            features.spectralCentroid = spectralCentroid
            features.bassEnergy = bass
            features.midEnergy = mid
            features.trebleEnergy = treble
            features.dynamicRange = peak - rms
            features.genre = "Unknown" // Not needed for fast Matchering
            features.energy = rms // Simple energy estimate
            features.tempo = 120.0 // Default tempo
            
            print("🚀 Fast analysis complete - no AI overhead")
            
            return features
        } catch {
            print("Error extracting features: \(error)")
            return AudioFeatures()
        }
    }
    
    fileprivate func calculateRMS(samples: [Float]) -> Float {
        let squaredSum = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(squaredSum / Float(samples.count))
    }
    
    fileprivate func calculateSpectralCentroid(samples: [Float], sampleRate: Float) -> Float {
        let fftSize = 2048
        guard samples.count >= fftSize else { return 0 }
        
        let windowedSamples = Array(samples.prefix(fftSize))
        let fft = performFFT(samples: windowedSamples)
        
        var weightedSum: Float = 0
        var magnitudeSum: Float = 0
        
        for (index, magnitude) in fft.enumerated() {
            let frequency = Float(index) * sampleRate / Float(fftSize)
            weightedSum += frequency * magnitude
            magnitudeSum += magnitude
        }
        
        return magnitudeSum > 0 ? weightedSum / magnitudeSum : 0
    }
    
    fileprivate func performFFT(samples: [Float]) -> [Float] {
        let log2n = vDSP_Length(log2(Float(samples.count)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }
        
        var realPart = samples
        var imagPart = [Float](repeating: 0, count: samples.count)
        
        let magnitudes: [Float] = realPart.withUnsafeMutableBufferPointer { realPtr in
            imagPart.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                
                vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                
                var mags = [Float](repeating: 0, count: samples.count / 2)
                vDSP_zvmags(&splitComplex, 1, &mags, 1, vDSP_Length(samples.count / 2))
                return mags
            }
        }
        
        return magnitudes
    }
    
    fileprivate func calculateFrequencyBands(samples: [Float], sampleRate: Float) -> (bass: Float, mid: Float, treble: Float) {
        let fft = performFFT(samples: Array(samples.prefix(2048)))
        
        let bassEnd = Int(200 * Float(fft.count) / (sampleRate / 2))
        let midEnd = Int(2000 * Float(fft.count) / (sampleRate / 2))
        
        let bass = fft[0..<min(bassEnd, fft.count)].reduce(0, +) / Float(bassEnd)
        let mid = fft[bassEnd..<min(midEnd, fft.count)].reduce(0, +) / Float(midEnd - bassEnd)
        let treble = fft[midEnd..<fft.count].reduce(0, +) / Float(fft.count - midEnd)
        
        return (bass, mid, treble)
    }
    
    private func applyMastering(source: URL, sourceFeatures: AudioFeatures, referenceFeatures: AudioFeatures, progressHandler: @escaping (Double) -> Void) async -> URL? {
        print("Applying mastering...")
        do {
            let sourceFile = try AVAudioFile(forReading: source)
            guard let referenceURL = self.referenceURL else { return nil }
            let referenceFile = try AVAudioFile(forReading: referenceURL)
            
            // Derive EQ gains from short analysis windows of both files
            print("Computing EQ gains from reference vs source...")
            let eqGainsDb = computeReferenceEQGainsFromFiles(sourceFile: sourceFile, referenceFile: referenceFile)
            print("EQ gains (dB): \(eqGainsDb)")
            progressHandler(0.6)
            
            // Use computed EQ gains directly (no AI prediction needed)
            let finalEqGainsDb = eqGainsDb
            print("Using computed EQ gains (no AI prediction)")
            
            // Render offline by scheduling the source file (streamed)
            print("Starting offline render...")
            if let renderedURL = try renderOfflineWithEQAndDynamics(inputFile: sourceFile, eqGainsDb: finalEqGainsDb) {
                // Aggressive post-processing (make-up gain, compression, soft clip)
                if let hotURL = aggressivePostProcess(inputURL: renderedURL, sourceFeatures: sourceFeatures, referenceFeatures: referenceFeatures) {
                    progressHandler(0.95)
                    return hotURL
                }
                progressHandler(0.95)
                return renderedURL
            } else {
                return nil
            }
        } catch {
            print("Error applying mastering: \(error)")
            return nil
        }
    }

    // Warm up backend by pinging lightweight endpoints to wake cold container
    private func warmUpBackend(serverBaseURL: URL) async throws -> Bool {
        var ok = false
        let endpoints = ["/", "/health"]
        for ep in endpoints {
            var req = URLRequest(url: serverBaseURL.appendingPathComponent(ep))
            req.httpMethod = "GET"
            req.timeoutInterval = 3
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 { ok = true }
            } catch {
                continue
            }
        }
        return ok
    }

    // MARK: - Remote Mastering (Railway Backend)
    private func masterViaBackend(serverBaseURL: URL, targetURL: URL, referenceURL: URL, progressHandler: @escaping (Double) -> Void) async -> URL? {
        // Helper to add query items (scoped here to avoid polluting global scope)
        func url(_ base: URL, with items: [URLQueryItem]) -> URL {
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
            comps.queryItems = items
            return comps.url ?? base
        }
        
        // Helper to warm the backend (hit / and /health with short timeouts)
        func warmUpBackend(serverBaseURL: URL) async throws -> Bool {
            var ok = false
            let endpoints = ["/", "/health"]
            for ep in endpoints {
                var req = URLRequest(url: serverBaseURL.appendingPathComponent(ep))
                req.httpMethod = "GET"
                req.timeoutInterval = 3
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode == 200 { ok = true }
                } catch { continue }
            }
            return ok
        }
        // Start async job
        let startEndpoint = serverBaseURL.appendingPathComponent("master/start")
        var request = URLRequest(url: startEndpoint)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        func fileData(_ url: URL) -> Data? {
            return try? Data(contentsOf: url)
        }
        func makePart(name: String, filename: String, mime: String, data: Data) -> Data {
            var d = Data()
            d.append("--\(boundary)\r\n".data(using: .utf8)!)
            d.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            d.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            d.append(data)
            d.append("\r\n".data(using: .utf8)!)
            return d
        }

        guard let targetData = fileData(targetURL), let referenceData = fileData(referenceURL) else {
            print("Failed to read files for upload")
            return nil
        }

        var body = Data()
        body.append(makePart(name: "target", filename: targetURL.lastPathComponent, mime: "audio/wav", data: targetData))
        body.append(makePart(name: "reference", filename: referenceURL.lastPathComponent, mime: "audio/wav", data: referenceData))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        progressHandler(0.3)
        print("Progress: 30% - Uploading to backend")

        do {
            // Kick off job
            var startReq = request
            startReq.url = startEndpoint
            // Explicit short timeouts for start call
            startReq.timeoutInterval = 60
            let (startData, startResp) = try await URLSession.shared.data(for: startReq)
            guard let startHTTP = startResp as? HTTPURLResponse, startHTTP.statusCode == 200,
                  let job = try? JSONSerialization.jsonObject(with: startData) as? [String: Any],
                  let jobId = job["job_id"] as? String else {
                let msg = String(data: startData, encoding: .utf8) ?? "Unknown error"
                print("Backend start error: \(msg)")
                return nil
            }

            // Poll status
            let statusURL = url(serverBaseURL.appendingPathComponent("master/status"), with: [URLQueryItem(name: "id", value: jobId)])
            let resultURL = url(serverBaseURL.appendingPathComponent("master/result"), with: [URLQueryItem(name: "id", value: jobId)])

            var attempts = 0
            while attempts < 600 { // up to ~10 minutes (1s * 600)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                attempts += 1
                var sReq = URLRequest(url: statusURL)
                sReq.timeoutInterval = 3
                let (sData, sResp) = try await URLSession.shared.data(for: sReq)
                guard let sHTTP = sResp as? HTTPURLResponse, sHTTP.statusCode == 200,
                      let sObj = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
                      let status = sObj["status"] as? String else { continue }
                let hasOutput = (sObj["has_output"] as? Bool) ?? false
                if status == "done" && hasOutput { break }
                if status == "error" {
                    let msg = (sObj["message"] as? String) ?? "unknown"
                    print("Backend job error: \(msg)")
                    return nil
                }
                // Nudge progress while waiting
                let waitProgress = min(0.85, 0.6 + (Double(attempts) / 600.0) * 0.25)
                progressHandler(waitProgress)
            }

            // Fetch result
            var rReq = URLRequest(url: resultURL)
            rReq.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: rReq)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("Backend result not ready")
                return nil
            }
            progressHandler(0.9)
            print("Progress: 90% - Downloaded mastered file")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mastered-\(UUID().uuidString).wav")
            try data.write(to: tmp)
            return tmp
        } catch {
            print("Backend mastering request failed: \(error)")
            return nil
        }
    }
    
    private func processAudioWithAI(buffer: AVAudioPCMBuffer, sourceFeatures: AudioFeatures, referenceFeatures: AudioFeatures) -> AVAudioPCMBuffer? {
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        
        outputBuffer.frameLength = buffer.frameLength
        
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        
        let targetGain = referenceFeatures.rms / max(sourceFeatures.rms, 0.001)
        let bassAdjustment = referenceFeatures.bassEnergy / max(sourceFeatures.bassEnergy, 0.001)
        let trebleAdjustment = referenceFeatures.trebleEnergy / max(sourceFeatures.trebleEnergy, 0.001)
        
        for channel in 0..<channelCount {
            guard let inputSamples = buffer.floatChannelData?[channel],
                  let outputSamples = outputBuffer.floatChannelData?[channel] else {
                continue
            }
            
            for i in 0..<frameLength {
                var sample = inputSamples[i]
                
                sample *= targetGain
                
                sample = applySoftClipping(sample: sample)
                
                sample = applyEQ(
                    sample: sample,
                    index: i,
                    bassGain: bassAdjustment,
                    trebleGain: trebleAdjustment,
                    sampleRate: Float(buffer.format.sampleRate)
                )
                
                sample = applyCompression(sample: sample, threshold: 0.7, ratio: 4.0)
                
                sample = max(-1.0, min(1.0, sample * 0.95))
                
                outputSamples[i] = sample
            }
        }
        
        return outputBuffer
    }
    
    private func applySoftClipping(sample: Float) -> Float {
        let threshold: Float = 0.7
        if abs(sample) > threshold {
            let sign = sample > 0 ? Float(1.0) : Float(-1.0)
            return sign * (threshold + (1.0 - threshold) * tanh((abs(sample) - threshold) / (1.0 - threshold)))
        }
        return sample
    }
    
    private func applyEQ(sample: Float, index: Int, bassGain: Float, trebleGain: Float, sampleRate: Float) -> Float {
        let bassBoost = 1.0 + (bassGain - 1.0) * 0.3
        let trebleBoost = 1.0 + (trebleGain - 1.0) * 0.2
        
        return sample * ((bassBoost + trebleBoost) / 2.0)
    }
    
    private func applyCompression(sample: Float, threshold: Float, ratio: Float) -> Float {
        let absSample = abs(sample)
        if absSample > threshold {
            let excess = absSample - threshold
            let compressedExcess = excess / ratio
            let compressedMagnitude = threshold + compressedExcess
            return sample > 0 ? compressedMagnitude : -compressedMagnitude
        }
        return sample
    }
    
    func exportMasteredAudio(completion: @escaping (Bool) -> Void) {
        guard let masteredURL = masteredURL else {
            completion(false)
            return
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let ext = masteredURL.pathExtension.isEmpty ? "wav" : masteredURL.pathExtension
        let exportURL = documentsPath.appendingPathComponent("Mastered_\(Date().timeIntervalSince1970).\(ext)")
        
        do {
            try FileManager.default.copyItem(at: masteredURL, to: exportURL)
            completion(true)
        } catch {
            print("Export failed: \(error)")
            completion(false)
        }
    }
    
    // Export that returns the destination URL for sharing
    func exportMasteredAudioURL(completion: @escaping (URL?) -> Void) {
        guard let masteredURL = masteredURL else {
            completion(nil)
            return
        }
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let ext = masteredURL.pathExtension.isEmpty ? "wav" : masteredURL.pathExtension
        let baseName = sourceFileName?.replacingOccurrences(of: ".\(sourceURL?.pathExtension ?? "wav")", with: "") ?? "Mastered"
        let exportURL = documentsPath.appendingPathComponent("\(baseName)_Mastered.\(ext)")
        do {
            if FileManager.default.fileExists(atPath: exportURL.path) {
                try FileManager.default.removeItem(at: exportURL)
            }
            try FileManager.default.copyItem(at: masteredURL, to: exportURL)
            completion(exportURL)
        } catch {
            print("Export failed: \(error)")
            completion(nil)
        }
    }
    
    // Reset session to start a new song
    func resetSession() {
        stopPlayback()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.sourceURL = nil
            self.referenceURL = nil
            self.masteredURL = nil
            self.sourceFileName = nil
            self.referenceFileName = nil
            self.currentlyPlayingURL = nil
            self.isPlaying = false
        }
    }
    
    // MARK: - ML Feedback (Stub - No longer using ML)
    func recordUserFeedback(features: AudioFeatures, predictedGenre: String, actualGenre: String, confidence: Float) {
        // Stub method - ML functionality removed for fast Matchering
        print("📚 User feedback recorded (stub): predicted=\(predictedGenre), actual=\(actualGenre)")
        // No actual learning happening since ML was removed for performance
    }
    
    // MARK: - REMOVED ML Audio Intelligence Engine (Not needed for fast Matchering)
    
    private func extractChromaVector(samples: [Float], sampleRate: Float) -> [Float] {
        let windowSize = 1024  // Reduced for speed (was 4096)
        let hopSize = windowSize / 2  // Reduced for speed (was windowSize / 4)
        var chromaVector = [Float](repeating: 0, count: 12)
        var validWindows = 0
        
        // Process only first 10 seconds for speed (was entire track)
        let maxSamples = min(samples.count, Int(sampleRate * 10))
        for i in stride(from: 0, to: maxSamples - windowSize, by: hopSize) {
            let window = Array(samples[i..<i+windowSize])
            
            // Apply Hamming window
            let hammingWindow = window.enumerated().map { index, sample in
                return sample * Float(0.54 - 0.46 * cos(2 * Float.pi * Float(index) / Float(windowSize - 1)))
            }
            
            let spectrum = performFFT(samples: hammingWindow)
            
            // Skip silent sections
            let energy = spectrum.reduce(0, +)
            if energy > 0.001 {
                // Map frequencies to pitch classes with better accuracy
                for (binIndex, magnitude) in spectrum.enumerated() {
                    let frequency = Float(binIndex) * sampleRate / Float(windowSize)
                    
                    // Focus on musical range (80Hz to 2kHz)
                    if frequency > 80 && frequency < 2000 && magnitude > 0.001 {
                        // Convert frequency to MIDI note number
                        let midiNote = 12 * log2f(frequency / 440.0) + 69
                        
                        // Map to pitch class (0=C, 1=C#, etc.)
                        let pitchClass = Int(midiNote.rounded()) % 12
                        if pitchClass >= 0 && pitchClass < 12 {
                            // Weight by magnitude and harmonic content
                            chromaVector[pitchClass] += magnitude * (1.0 / (1.0 + abs(midiNote - midiNote.rounded())))
                        }
                    }
                }
                validWindows += 1
            }
        }
        
        // Normalize chroma vector
        let sum = chromaVector.reduce(0, +)
        if sum > 0 {
            chromaVector = chromaVector.map { $0 / sum }
        } else {
            // Fallback: create a simple harmonic profile based on spectral analysis
            let spectrum = performFFT(samples: Array(samples.prefix(4096)))
            let fundamentalBin = spectrum.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
            let fundamentalFreq = Float(fundamentalBin) * sampleRate / Float(4096)
            
            if fundamentalFreq > 80 {
                let fundamentalPitch = Int(round(12 * log2f(fundamentalFreq / 440.0) + 69)) % 12
                chromaVector[fundamentalPitch] = 0.6  // Strong fundamental
                chromaVector[(fundamentalPitch + 4) % 12] = 0.3  // Major third
                chromaVector[(fundamentalPitch + 7) % 12] = 0.1  // Perfect fifth
            }
        }
        
        print("🔍 Chroma extraction complete: [\(chromaVector.prefix(6).map { String(format: "%.3f", $0) }.joined(separator: ", "))]")
        
        return chromaVector
    }
    
    private func classifyGenre(mfcc: [Float], chroma: [Float]) -> String {
        // Enhanced AI-powered genre classification
        guard mfcc.count >= 13 && chroma.count >= 12 else { return "Alternative" }
        
        // Normalize MFCC features to prevent extreme values
        let normalizedMFCC = mfcc.map { max(-10, min(10, $0)) }
        let normalizedChroma = chroma.map { max(0, min(1, $0)) }
        
        // Calculate advanced musical features
        let spectralCentroid = normalizedMFCC[1...5].reduce(0, +) / 5.0  // Mid-frequency energy
        let spectralBandwidth = normalizedMFCC[6...10].reduce(0, +) / 5.0 // High-frequency spread
        let rhythmicEnergy = abs(normalizedMFCC[0]) // Low-frequency energy
        let harmonicStability = normalizedChroma.reduce(0, +) / 12.0 // Overall harmonic content
        
        // Calculate tonal complexity (chord changes and harmonic movement)
        var tonalComplexity: Float = 0
        for i in 0..<12 {
            let next = (i + 1) % 12
            tonalComplexity += abs(normalizedChroma[i] - normalizedChroma[next])
        }
        tonalComplexity /= 12.0
        
        // Genre classification using multiple feature dimensions
        print("🔍 Genre Analysis - Spectral: \(String(format: "%.3f", spectralCentroid)), Rhythmic: \(String(format: "%.3f", rhythmicEnergy)), Tonal: \(String(format: "%.3f", tonalComplexity)), Harmonic: \(String(format: "%.3f", harmonicStability)), Bandwidth: \(String(format: "%.3f", spectralBandwidth))")
        
        // Hip Hop/Rap: PRIORITIZE - Strong rhythmic energy, bass-heavy, simple harmonics
        if rhythmicEnergy > 3.0 && spectralCentroid < 5.0 && tonalComplexity < 0.1 {
            print("🎤 Detected Hip Hop characteristics: heavy bass + strong rhythm")
            return "Hip Hop"
        }
        
        // Hip Hop/Rap: BACKUP detection for edge cases
        if rhythmicEnergy > 2.0 && harmonicStability < 0.15 && tonalComplexity < 0.08 {
            print("🎤 Detected Hip Hop (backup): simple harmonics + strong rhythm")
            return "Hip Hop"
        }
        
        // Rock/Metal: High spectral bandwidth, bright spectrum, complex harmonics, guitar-heavy
        if spectralBandwidth > 0.5 && spectralCentroid > 0.5 && tonalComplexity > 0.4 {
            print("🎸 Detected Rock characteristics: bright + complex harmonics")
            return "Rock"
        }
        
        // Classical: High tonal complexity, low rhythmic energy, stable harmonics
        if tonalComplexity > 0.6 && rhythmicEnergy < 0.3 && harmonicStability > 0.5 {
            print("🎼 Detected Classical characteristics: complex + stable harmonics")
            return "Classical"
        }
        
        // Jazz: Complex harmonics, moderate energy, sophisticated tonal structure
        if tonalComplexity > 0.5 && harmonicStability > 0.6 && rhythmicEnergy > 0.2 && rhythmicEnergy < 0.6 {
            print("🎷 Detected Jazz characteristics: sophisticated harmonics")
            return "Jazz"
        }
        
        // Electronic: High spectral bandwidth, synthetic harmonics, strong rhythmic patterns
        if spectralBandwidth > 0.6 && (tonalComplexity < 0.2 || tonalComplexity > 0.8) && rhythmicEnergy > 0.3 {
            return "Electronic"
        }
        
        // Pop: Balanced features, moderate complexity, vocal-friendly harmonics
        if spectralCentroid > 0.2 && spectralCentroid < 0.6 && tonalComplexity > 0.2 && tonalComplexity < 0.5 {
            return "Pop"
        }
        
        // R&B/Soul: Rich harmonics, moderate energy, smooth spectral characteristics
        if harmonicStability > 0.6 && rhythmicEnergy > 0.3 && rhythmicEnergy < 0.7 && spectralBandwidth < 0.5 {
            return "R&B"
        }
        
        // Default to Alternative for edge cases
        return "Alternative"
    }
    
    private func calculateEnergy(samples: [Float]) -> Float {
        let rmsEnergy = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        return min(1.0, rmsEnergy * 10) // Normalize to 0-1
    }
    
    private func calculateDanceability(tempo: Float, energy: Float) -> Float {
        // Calculate danceability based on tempo and energy
        let idealDanceTempo: Float = 120
        let tempoScore = 1.0 - abs(tempo - idealDanceTempo) / 60.0
        return min(1.0, max(0.0, (tempoScore * 0.6 + energy * 0.4)))
    }
    
    private func calculateValence(chroma: [Float], energy: Float) -> Float {
        // Calculate musical valence (positivity) from harmonic content
        let majorChords = [0, 4, 7] // C major chord indices
        let majorStrength = majorChords.map { chroma[$0] }.reduce(0, +) / 3.0
        return min(1.0, (majorStrength * 0.7 + energy * 0.3))
    }
    
    private func detectMLTempo(samples: [Float], sampleRate: Float) -> Float {
        // AI-enhanced tempo detection
        let onsetStrength = computeOnsetStrength(samples: samples, sampleRate: sampleRate)
        let autocorr = computeAutocorrelation(onsetStrength)
        
        var maxCorr: Float = 0
        var bestTempo: Float = 120
        
        for bpm in 60...200 {
            let lag = Int(sampleRate * 60.0 / Float(bpm) / 512) // 512 = hop size
            if lag < autocorr.count {
                if autocorr[lag] > maxCorr {
                    maxCorr = autocorr[lag]
                    bestTempo = Float(bpm)
                }
            }
        }
        
        return bestTempo
    }
    
    private func computeOnsetStrength(samples: [Float], sampleRate: Float) -> [Float] {
        let hopSize = 512
        let windowSize = 2048
        var onsetStrength: [Float] = []
        var previousSpectrum = [Float](repeating: 0, count: windowSize/2)
        
        for i in stride(from: 0, to: samples.count - windowSize, by: hopSize) {
            let window = Array(samples[i..<i+windowSize])
            let spectrum = performFFT(samples: window)
            
            // Spectral flux
            var flux: Float = 0
            for j in 0..<spectrum.count {
                let diff = spectrum[j] - previousSpectrum[j]
                if diff > 0 { flux += diff }
            }
            
            onsetStrength.append(flux)
            previousSpectrum = spectrum
        }
        
        return onsetStrength
    }
    
    private func computeAutocorrelation(_ signal: [Float]) -> [Float] {
        let n = signal.count
        var autocorr = [Float](repeating: 0, count: n)
        
        for lag in 0..<n/2 {
            for i in 0..<(n-lag) {
                autocorr[lag] += signal[i] * signal[i + lag]
            }
        }
        
        return autocorr
    }
    
    private func calculateSpectralRolloff(samples: [Float], sampleRate: Float) -> Float {
        let spectrum = performFFT(samples: samples)
        let totalEnergy = spectrum.reduce(0, +)
        let threshold = totalEnergy * 0.85 // 85% rolloff point
        
        var cumulativeEnergy: Float = 0
        for (index, magnitude) in spectrum.enumerated() {
            cumulativeEnergy += magnitude
            if cumulativeEnergy >= threshold {
                return Float(index) * sampleRate / Float(spectrum.count * 2)
            }
        }
        
        return sampleRate / 2 // Nyquist frequency
    }
    
    private func applyMelFilterBank(spectrum: [Float], sampleRate: Float) -> [Float] {
        let numFilters = 26
        var melSpectrum = [Float](repeating: 0, count: numFilters)
        
        // Mel scale conversion and filter bank application
        for i in 0..<numFilters {
            let centerFreq = melToHz(Float(i + 1) * 2595.0 / Float(numFilters + 1))
            let binIndex = Int(centerFreq * Float(spectrum.count) / (sampleRate / 2))
            
            if binIndex < spectrum.count {
                melSpectrum[i] = spectrum[binIndex]
            }
        }
        
        return melSpectrum
    }
    
    private func melToHz(_ mel: Float) -> Float {
        return 700 * (powf(10, mel / 2595.0) - 1)
    }
    
    private func computeDCT(melSpectrum: [Float]) -> [Float] {
        let n = melSpectrum.count
        var dctCoeffs = [Float](repeating: 0, count: 13)
        
        for k in 0..<13 {
            var sum: Float = 0
            for i in 0..<n {
                sum += melSpectrum[i] * cos(Float.pi * Float(k) * (Float(i) + 0.5) / Float(n))
            }
            dctCoeffs[k] = sum
        }
        
        return dctCoeffs
    }
    
    // MARK: - Genre-Specific Mastering Models
    struct GenreMasteringSettings {
        let bassBoost: Float
        let midClarity: Float
        let highdBoost: Float
        let compressionRatio: Float
        let limitThreshold: Float
        let stereoWidth: Float
        let harmonicEnhancement: Float
        let transientShaping: Float
    }
    
    private func getGenreSpecificSettings(genre: String) -> GenreMasteringSettings {
        switch genre.lowercased() {
        case "electronic", "edm", "house", "techno":
            return GenreMasteringSettings(
                bassBoost: 3.5,        // Strong sub-bass presence
                midClarity: 1.5,       // Clean mids for clarity
                highdBoost: 1.1,       // Gentle highs without harshness
                compressionRatio: 4.0, // Punchy dynamics
                limitThreshold: -1.0,  // Loud but controlled
                stereoWidth: 1.4,      // Wide stereo image
                harmonicEnhancement: 0.3,
                transientShaping: 0.8  // Sharp transients
            )
        case "hip hop", "rap", "trap":
            return GenreMasteringSettings(
                bassBoost: 2.8,        // FAT AND DEEP BASS: Strong low-end for modern hip hop
                midClarity: 2.4,       // CRYSTAL CLEAR VOCALS: Strong vocal presence and intelligibility
                highdBoost: 1.2,       // SMOOTH HIGHS: Clean air without scratching
                compressionRatio: 2.8, // Professional tightness for vocals and drums
                limitThreshold: -0.5,  // Very competitive loudness with Hyrax limiting
                stereoWidth: 1.12,     // Enhanced stereo width for immersive sound
                harmonicEnhancement: 0.3, // Rich harmonic content for warmth
                transientShaping: 0.7  // Punchy drums and vocal transients
            )
        case "rock", "metal", "alternative":
            return GenreMasteringSettings(
                bassBoost: 2.5,        // Tight bass
                midClarity: 3.2,       // Aggressive mids
                highdBoost: 1.3,       // Smooth guitars without harshness
                compressionRatio: 3.5, // Dynamic but controlled
                limitThreshold: -2.0,  // Room for dynamics
                stereoWidth: 1.3,      // Wide guitars
                harmonicEnhancement: 0.4,
                transientShaping: 0.7  // Natural transients
            )
        case "pop", "r&b", "soul":
            return GenreMasteringSettings(
                bassBoost: 2.8,        // Warm bass
                midClarity: 2.5,       // Vocal presence
                highdBoost: 1.2,       // Truly silky highs
                compressionRatio: 4.5, // Radio-ready
                limitThreshold: -1.2,  // Competitive loudness
                stereoWidth: 1.2,      // Balanced width
                harmonicEnhancement: 0.5,
                transientShaping: 0.5  // Smooth
            )
        case "jazz", "blues", "acoustic":
            return GenreMasteringSettings(
                bassBoost: 1.8,        // Natural bass
                midClarity: 2.8,       // Instrument clarity
                highdBoost: 1.1,       // Smooth natural highs
                compressionRatio: 2.5, // Preserve dynamics
                limitThreshold: -3.0,  // Dynamic range
                stereoWidth: 1.0,      // Natural stereo
                harmonicEnhancement: 0.6,
                transientShaping: 0.3  // Natural dynamics
            )
        case "classical", "orchestral":
            return GenreMasteringSettings(
                bassBoost: 1.2,        // Subtle bass
                midClarity: 2.0,       // Instrument balance
                highdBoost: 1.1,       // Gentle natural air
                compressionRatio: 1.8, // Minimal compression
                limitThreshold: -6.0,  // Full dynamic range
                stereoWidth: 0.9,      // Natural staging
                harmonicEnhancement: 0.8,
                transientShaping: 0.2  // Preserve dynamics
            )
        default: // "Alternative", "Indie", etc.
            return GenreMasteringSettings(
                bassBoost: 2.2,
                midClarity: 2.3,
                highdBoost: 1.2,
                compressionRatio: 3.8,
                limitThreshold: -1.8,
                stereoWidth: 1.2,
                harmonicEnhancement: 0.4,
                transientShaping: 0.6
            )
        }
    }
    
    // MARK: - Audio routing helpers
    // REMOVED: ML prediction functions (not needed for fast Matchering)
    private func hasExternalOutput(session: AVAudioSession) -> Bool {
        return session.currentRoute.outputs.contains { output in
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay, .carAudio:
                return true
            default:
                return false
            }
        }
    }
    
    /// Set preferred I/O buffer size in frames based on current session sample rate.
    func setIOBufferFrames(frames: Int) {
        let session = AVAudioSession.sharedInstance()
        let sampleRate = session.sampleRate > 0 ? session.sampleRate : audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return }
        let duration = Double(frames) / sampleRate
        do {
            try session.setPreferredIOBufferDuration(duration)
            print("Set preferred IO buffer frames=\(frames) (duration=\(duration)s at \(sampleRate) Hz)")
        } catch {
            print("Failed to set IO buffer duration: \(error)")
        }
    }
    
    // MARK: - Reference-based EQ and Offline Rendering Helpers
    /// Compute per-band EQ gains in dB by comparing reference vs source band energies.
    /// Returns five gains mapped to [low-shelf, peak@250, peak@1k, peak@3.5k, high-shelf]
    private func computeReferenceEQGains(sourceBuffer: AVAudioPCMBuffer, referenceURL: URL) -> [Float] {
        let bandEdges: [Float] = eqBandEdges
        let sourceEnergies = calculateBandEnergies(from: sourceBuffer, bandEdges: bandEdges)
        
        var referenceEnergies: [Float] = Array(repeating: 1, count: bandEdges.count - 1)
        do {
            let refFile = try AVAudioFile(forReading: referenceURL)
            let refFormat = refFile.processingFormat
            let refFrameCount = AVAudioFrameCount(refFile.length)
            if let refBuffer = AVAudioPCMBuffer(pcmFormat: refFormat, frameCapacity: refFrameCount) {
                try refFile.read(into: refBuffer)
                referenceEnergies = calculateBandEnergies(from: refBuffer, bandEdges: bandEdges)
            }
        } catch {
            print("Failed to read reference for EQ analysis: \(error)")
        }
        
        let epsilon: Float = 1e-6
        var gainsDb: [Float] = []
        for i in 0..<referenceEnergies.count {
            let ratio = referenceEnergies[i] / max(sourceEnergies[i], epsilon)
            // Using power ratio -> 10*log10
            var db = 10.0 * log10f(max(ratio, epsilon))
            // More aggressive EQ matching
            db = min(10.0, max(-10.0, db))
            gainsDb.append(db)
        }
        
        // Map 5 bands from 5 energy regions
        // If energies count differs, fallback to zeros
        if gainsDb.count >= 5 {
            return Array(gainsDb.prefix(eqCenterFrequencies.count))
        } else {
            return Array(repeating: 0, count: eqCenterFrequencies.count)
        }
    }
    
    /// Calculate band energies using a single-window FFT snapshot of the first channel
    fileprivate func calculateBandEnergies(from buffer: AVAudioPCMBuffer, bandEdges: [Float]) -> [Float] {
        guard let channelData = buffer.floatChannelData?.pointee else {
            return Array(repeating: 1, count: bandEdges.count - 1)
        }
        
        let sampleRate = Float(buffer.format.sampleRate)
        let fftSize = 8192
        let available = Int(buffer.frameLength)
        let windowedCount = min(fftSize, available)
        if windowedCount < 1024 {
            return Array(repeating: 1, count: bandEdges.count - 1)
        }
        var samples = Array(UnsafeBufferPointer(start: channelData, count: windowedCount))
        // Hann window to reduce spectral leakage
        var window = [Float](repeating: 0, count: windowedCount)
        vDSP_hann_window(&window, vDSP_Length(windowedCount), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(windowedCount))
        
        let magnitudes = performFFT(samples: samples)
        if magnitudes.isEmpty { return Array(repeating: 1, count: bandEdges.count - 1) }
        
        // Frequency per bin
        let binFreq = sampleRate / Float(fftSize)
        
        var energies: [Float] = []
        for i in 0..<(bandEdges.count - 1) {
            let fStart = bandEdges[i]
            let fEnd = bandEdges[i + 1]
            let startIdx = max(0, Int(floor(fStart / binFreq)))
            let endIdx = min(magnitudes.count - 1, Int(ceil(fEnd / binFreq)))
            if endIdx > startIdx {
                let sum = magnitudes[startIdx...endIdx].reduce(0, +)
                energies.append(sum / Float(endIdx - startIdx + 1))
            } else {
                energies.append(1)
            }
        }
        return energies
    }
    
    /// Build and render an offline AVAudioEngine chain with EQ.
    private func renderOfflineWithEQAndDynamics(inputBuffer: AVAudioPCMBuffer, eqGainsDb: [Float], outputSampleRate: Double, channels: Int) throws -> URL? {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: eqCenterFrequencies.count)
        
        engine.attach(player)
        engine.attach(eq)
        
        // Configure EQ bands
        for (index, band) in eq.bands.enumerated() {
            let freq = index < eqCenterFrequencies.count ? eqCenterFrequencies[index] : 1000
            let q = index < eqQValues.count ? eqQValues[index] : 1.0
            let gain = index < eqGainsDb.count ? eqGainsDb[index] : 0
            
            if index == 0 {
                band.filterType = .lowShelf
            } else if index == eq.bands.count - 1 {
                band.filterType = .highShelf
            } else {
                band.filterType = .parametric
            }
            band.frequency = freq
            band.bandwidth = q
            band.gain = gain
            band.bypass = false
        }
        
        // Connect: player -> eq -> mainMixer
        engine.connect(player, to: eq, format: inputBuffer.format)
        engine.connect(eq, to: engine.mainMixerNode, format: inputBuffer.format)
        
        // Prepare offline rendering
        let renderFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maxFrames)
        engine.prepare()
        try engine.start()
        
        // Schedule the input buffer AFTER starting engine
        player.scheduleBuffer(inputBuffer, at: nil, options: []) {
            player.stop()
        }
        player.play()
        
        // Output file (WAV, 32-bit float)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("mastered_\(UUID().uuidString).wav")
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: renderFormat.sampleRate,
            AVNumberOfChannelsKey: renderFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outFile = try AVAudioFile(forWriting: outputURL, settings: fileSettings)
        
        // Render loop with progress guard
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames)!
        var lastSampleTime = engine.manualRenderingSampleTime
        var noProgressIterations = 0
        while true {
            let framesToRender = min(buffer.frameCapacity, engine.manualRenderingMaximumFrameCount)
            let status = try engine.renderOffline(framesToRender, to: buffer)
            switch status {
            case .success:
                try outFile.write(from: buffer)
            case .error:
                throw NSError(domain: "RenderingError", code: -1)
            default:
                // .insufficientDataFromInput and .cannotDoInCurrentContext fall back here
                break
            }
            
            if engine.manualRenderingSampleTime >= AVAudioFramePosition(inputBuffer.frameLength) {
                break
            }
            
            // Guard: if the engine isn't advancing, break to avoid infinite loop
            if engine.manualRenderingSampleTime == lastSampleTime {
                noProgressIterations += 1
                if noProgressIterations > 1000 { break }
            } else {
                lastSampleTime = engine.manualRenderingSampleTime
                noProgressIterations = 0
            }
        }
        
        engine.stop()
        return outputURL
    }
    
    /// Compute EQ gains using small sample windows from files (faster than full read)
    private func computeReferenceEQGainsFromFiles(sourceFile: AVAudioFile, referenceFile: AVAudioFile) -> [Float] {
        func sampleBuffer(from file: AVAudioFile, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? {
            let format = file.processingFormat
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
            do {
                try file.read(into: buf, frameCount: frameCount)
                return buf
            } catch {
                print("Sample read failed: \(error)")
                return nil
            }
        }
        
        let frames: AVAudioFrameCount = 16384
        guard let srcBuf = sampleBuffer(from: sourceFile, frameCount: min(frames, AVAudioFrameCount(sourceFile.length))),
              let refBuf = sampleBuffer(from: referenceFile, frameCount: min(frames, AVAudioFrameCount(referenceFile.length))) else {
            return Array(repeating: 0, count: 5)
        }
        
        let bandEdges: [Float] = eqBandEdges
        let srcE = calculateBandEnergies(from: srcBuf, bandEdges: bandEdges)
        let refE = calculateBandEnergies(from: refBuf, bandEdges: bandEdges)
        
        let epsilon: Float = 1e-6
        var gainsDb: [Float] = []
        for i in 0..<min(srcE.count, refE.count) {
            let ratio = refE[i] / max(srcE[i], epsilon)
            var db = 10.0 * log10f(max(ratio, epsilon))
            
            // Much more conservative EQ adjustments
            if i >= 1 && i <= 3 { // Mud range (250-500Hz area)
                db = min(2.0, max(-3.0, db)) // Allow more cutting in mud range
            } else {
                db = min(2.0, max(-2.0, db)) // Conservative elsewhere
            }
            
            // Apply smoothing factor to prevent drastic changes
            db *= 0.6 // Reduce all adjustments by 40%
            gainsDb.append(db)
        }
        while gainsDb.count < eqCenterFrequencies.count { gainsDb.append(0) }
        return Array(gainsDb.prefix(eqCenterFrequencies.count))
    }
    
    /// Offline render by scheduling a file instead of loading entire buffer
    private func renderOfflineWithEQAndDynamics(inputFile: AVAudioFile, eqGainsDb: [Float]) throws -> URL? {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: eqCenterFrequencies.count)
        
        engine.attach(player)
        engine.attach(eq)
        
        for (index, band) in eq.bands.enumerated() {
            let freq = index < eqCenterFrequencies.count ? eqCenterFrequencies[index] : 1000
            let q = index < eqQValues.count ? eqQValues[index] : 1.0
            let gain = index < eqGainsDb.count ? eqGainsDb[index] : 0
            band.filterType = (index == 0) ? .lowShelf : ((index == eq.bands.count - 1) ? .highShelf : .parametric)
            band.frequency = freq
            band.bandwidth = q
            band.gain = gain
            band.bypass = false
        }
        
        engine.connect(player, to: eq, format: inputFile.processingFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: inputFile.processingFormat)
        
        let renderFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maxFrames)
        engine.prepare()
        try engine.start()
        
        var finished = false
        player.scheduleFile(inputFile, at: nil) {
            finished = true
        }
        player.play()
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("mastered_\(UUID().uuidString).wav")
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: renderFormat.sampleRate,
            AVNumberOfChannelsKey: renderFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outFile = try AVAudioFile(forWriting: outputURL, settings: fileSettings)
        
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames)!
        let totalFrames = AVAudioFramePosition(inputFile.length)
        var lastSampleTime = engine.manualRenderingSampleTime
        var noProgressIterations = 0
        while !finished {
            let framesToRender = min(buffer.frameCapacity, engine.manualRenderingMaximumFrameCount)
            let status = try engine.renderOffline(framesToRender, to: buffer)
            switch status {
            case .success:
                try outFile.write(from: buffer)
            case .error:
                throw NSError(domain: "RenderingError", code: -1)
            default:
                break
            }
            
            if engine.manualRenderingSampleTime >= totalFrames {
                print("Reached total frames: \(totalFrames)")
                break
            }
            if engine.manualRenderingSampleTime == lastSampleTime {
                noProgressIterations += 1
                if noProgressIterations > 2000 { break }
            } else {
                lastSampleTime = engine.manualRenderingSampleTime
                noProgressIterations = 0
            }
        }
        
        engine.stop()
        return outputURL
    }
    
    // Professional dynamic mastering with parallel processing and transient preservation
    private func aggressivePostProcess(inputURL: URL, sourceFeatures: AudioFeatures, referenceFeatures: AudioFeatures) -> URL? {
        do {
            let file = try AVAudioFile(forReading: inputURL)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
            try file.read(into: buffer)
            
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            
            // 🔥 HEAVY MASTERING: Full processing optimized for 2-3 minutes
            print("🔥 HEAVY MASTERING MODE: Full professional processing - optimized for speed")
            
            let sampleRate = Float(buffer.format.sampleRate)
            let optimalGain: Float = 0.8 // Preserve headroom for processing
            
            // OPTIMIZED HEAVY PROCESSING CHAIN
            for c in 0..<channelCount {
                guard let samples = buffer.floatChannelData?[c] else { continue }
                
                print("🔥 Processing channel \(c) with heavy mastering chain...")
                
                // 1. Input staging with transient preservation
                for i in 0..<frameLength {
                    samples[i] *= optimalGain
                }
                
                // 2. Multi-band frequency shaping (optimized)
                applyOptimizedMultiBandEQ(samples: samples, frameLength: frameLength, sampleRate: sampleRate)
                
                // 3. Professional dynamics processing
                applyHeavyDynamicsProcessing(samples: samples, frameLength: frameLength, sampleRate: sampleRate)
                
                // 4. Harmonic enhancement for warmth
                applyHarmonicEnhancement(samples: samples, frameLength: frameLength, sampleRate: sampleRate)
                
                // 5. Transient shaping for punch
                applyTransientShaping(samples: samples, frameLength: frameLength, sampleRate: sampleRate)
                
                /* COMMENTED OUT FOR SPEED - COMPLEX PROCESSING
                 for i in 0..<frameLength {
                 let x = samples[i] * inputGain
                 drySignal[i] = x // Preserve original dynamics
                 
                 // Stage 1: Transient Detection and Enhancement
                 let transientInfo = detectTransient(sample: x,
                 envelope: &envelopeFollower,
                 memory: &transientMemory,
                 sampleRate: sampleRate)
                 
                 // Stage 2: Parallel Processing Chains
                 
                 // Chain A: Transient enhancement (preserves punch)
                 transientChain[i] = processTransientChain(sample: x,
                 transientLevel: transientInfo.level,
                 attack: transientInfo.isAttack)
                 
                 // Chain B: Sustain processing (body and warmth)
                 sustainChain[i] = processSustainChain(sample: x,
                 transientLevel: transientInfo.level)
                 
                 // Chain C: Harmonic enhancement (richness)
                 harmonicChain[i] = processHarmonicChain(sample: x,
                 order: 3) // 3rd order harmonics
                 
                 // Stage 3: Smart Crossover with Dynamic Response
                 subLPF = subAlpha * subLPF + (1 - subAlpha) * x
                 lowLPF = lowAlpha * lowLPF + (1 - lowAlpha) * x
                 lowMidLPF = lowMidAlpha * lowMidLPF + (1 - lowMidAlpha) * x
                 midLPF = midAlpha * midLPF + (1 - midAlpha) * x
                 highMidLPF = highMidAlpha * highMidLPF + (1 - highMidAlpha) * x
                 
                 let sub = subLPF
                 let low = lowLPF - subLPF
                 let lowMid = lowMidLPF - lowLPF
                 let mid = midLPF - lowMidLPF
                 let highMid = highMidLPF - midLPF
                 let high = x - highMidLPF
                 
                 // Stage 4: Dynamic EQ Processing
                 let processedBands = applyDynamicEQ(
                 sub: sub, low: low, lowMid: lowMid,
                 mid: mid, highMid: highMid, high: high,
                 states: &dynamicEQStates,
                 transientLevel: transientInfo.level
                 )
                 
                 // Stage 5: Intelligent Recombination
                 let parallelMix = mixParallelChains(
                 dry: drySignal[i],
                 transient: transientChain[i],
                 sustain: sustainChain[i],
                 harmonic: harmonicChain[i],
                 transientLevel: transientInfo.level
                 )
                 
                 let bandSum = processedBands.sub + processedBands.low +
                 processedBands.lowMid + processedBands.mid +
                 processedBands.highMid + processedBands.high
                 
                 // Mix parallel with frequency processing (70% freq, 30% parallel)
                 let mixed = bandSum * 0.7 + parallelMix * 0.3
                 
                 // Stage 6: Adaptive Limiting with Lookahead
                 let limited = applyAdaptiveLimiting(sample: mixed,
                 threshold: 0.95,
                 transientLevel: transientInfo.level)
                 
                 samples[i] = limited
                 }
                 END COMPLEX PROCESSING COMMENT */
            }
            
            // 6. Stereo enhancement for width and cohesion
            if channelCount >= 2,
               let left = buffer.floatChannelData?[0],
               let right = buffer.floatChannelData?[1] {
                print("🔥 Applying heavy stereo enhancement...")
                applyHeavyStereoProcessing(left: left, right: right, frameLength: frameLength, sampleRate: sampleRate)
            }
            
            // TRUE MATCHERING APPROACH: Reference matching is the PRIMARY mastering method
            if let referenceAnalysis = analyzeReferenceTrack() {
                print("🎯 MATCHERING PRIMARY MASTERING: Reference-based processing")
                
                // TRUE MATCHERING: Iterative correction approach (like the real algorithm)
                applyIterativeMatchering(buffer: buffer, referenceAnalysis: referenceAnalysis, frameLength: frameLength, channelCount: channelCount)
                
                // STEP 5: Final Matchering-style brickwall limiting
                print("🔥 STARTING FINAL BRICKWALL LIMITING on \(channelCount) channels")
                for c in 0..<channelCount {
                    guard let samples = buffer.floatChannelData?[c] else {
                        print("⚠️ Channel \(c) samples is nil for brickwall limiting")
                        continue
                    }
                    print("🔥 Applying brickwall limiter to channel \(c)")
                    applyMatcheringBrickwallLimiter(samples: samples, frameCount: frameLength)
                }
                
                print("✅ MATCHERING COMPLETE: True reference matching applied with brickwall limiting")
                print("🎧 FINAL OUTPUT: Clean mastering without additional gain boost for smooth high-end")
            } else {
                // Fallback: Apply aggressive loudness normalization
                let targetLUFS: Float = -10.0 // Very loud for competitive output
                normalizeToLUFS(buffer: buffer, targetLUFS: targetLUFS)
                print("⚠️ No reference - using aggressive loudness mastering")
            }
            
            let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("mastered_hot_\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
            let outFile = try AVAudioFile(forWriting: outURL, settings: settings)
            try outFile.write(from: buffer)
            return outURL
        } catch {
            print("Aggressive post-process failed: \(error)")
            return nil
        }
    }
    
    private func applyBandCompressor(sample: Float, threshold: Float, ratio: Float) -> Float {
        let absS = abs(sample)
        if absS <= threshold { return sample }
        let excess = absS - threshold
        let comp = threshold + excess / ratio
        return sample >= 0 ? comp : -comp
    }
    
    private func waveshapeSaturate(sample: Float, drive: Float) -> Float {
        let x = max(-1.0, min(1.0, sample * drive))
        return tanh(x)
    }
    
    // MARK: - New Professional Mastering Helper Functions
    
    private func calculateBufferRMS(buffer: AVAudioPCMBuffer) -> Float {
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var totalRMS: Float = 0
        
        for c in 0..<channelCount {
            guard let samples = buffer.floatChannelData?[c] else { continue }
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += samples[i] * samples[i]
            }
            totalRMS += sqrt(sum / Float(frameLength))
        }
        return totalRMS / Float(channelCount)
    }
    
    private func applyGentleCompressor(sample: Float, threshold: Float, ratio: Float) -> Float {
        let absS = abs(sample)
        if absS <= threshold { return sample }
        let excess = absS - threshold
        let comp = threshold + excess / ratio
        return sample >= 0 ? comp : -comp
    }
    
    private func applySubtleSaturation(sample: Float, drive: Float) -> Float {
        let x = max(-1.0, min(1.0, sample * drive))
        // Softer saturation curve
        return x * (1.0 - abs(x) * 0.1)
    }
    
    private func applyGentleLimiter(sample: Float, threshold: Float) -> Float {
        let absS = abs(sample)
        if absS <= threshold { return sample }
        // Soft knee limiting
        let excess = absS - threshold
        let ratio = 1.0 - excess / (excess + 0.1)
        let limited = threshold + excess * ratio
        return sample >= 0 ? limited : -limited
    }
    
    private func normalizeToLUFS(buffer: AVAudioPCMBuffer, targetLUFS: Float) {
        // Simplified LUFS approximation using RMS with frequency weighting
        let currentRMS = calculateBufferRMS(buffer: buffer)
        let currentLUFS = 20.0 * log10f(currentRMS) - 0.691 // Rough LUFS approximation
        let gainAdjustment = targetLUFS - currentLUFS
        let linearGain = powf(10.0, gainAdjustment / 20.0)
        
        // Apply gain with safety limiting
        let safeGain = min(linearGain, 1.5) // Max 3.5dB boost only
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        
        for c in 0..<channelCount {
            if let samples = buffer.floatChannelData?[c] {
                vDSP_vsmul(samples, 1, [safeGain], samples, 1, vDSP_Length(frameLength))
                
                // MATCHERING VOLUME CONTROL: Let reference matching handle final level
                // No makeup gain needed - reference matching provides proper volume
                for i in 0..<frameLength {
                    samples[i] = max(-0.99, min(0.99, samples[i])) // Safety clip only
                }
            }
        }
    }
    
    // MARK: - Buttery Smooth Mastering Helper Functions
    
    private func applyDeepBassProcessor(sample: Float, threshold: Float) -> Float {
        // Very gentle bass control with smooth limiting
        let absS = abs(sample)
        if absS <= threshold { return sample }
        
        let excess = absS - threshold
        let compressed = threshold + excess * 0.6 // Much gentler ratio
        let sign = sample >= 0 ? Float(1.0) : Float(-1.0)
        
        // Very soft knee for smooth transition
        return sign * compressed
    }
    
    private func applyWarmthProcessor(sample: Float, gain: Float) -> Float {
        // Very gentle warm analog-style processing
        let boosted = sample * gain
        
        // Much subtler tube-style saturation
        if abs(boosted) > 0.6 { // Higher threshold
            let sign = boosted >= 0 ? Float(1.0) : Float(-1.0)
            let compressed = 0.6 + (abs(boosted) - 0.6) * 0.8 // Gentler ratio
            return sign * compressed * 0.98 // Less volume compensation
        }
        return boosted
    }
    
    private func applyClarityProcessor(sample: Float, reduction: Float) -> Float {
        // Clarity processing with mud reduction
        return sample * reduction
    }
    
    private func applyPresenceBoost(sample: Float, boost: Float) -> Float {
        // Vocal presence boost with saturation protection
        let boosted = sample * boost
        
        // Prevent harshness with soft clipping
        if abs(boosted) > 0.6 {
            let sign = boosted >= 0 ? Float(1.0) : Float(-1.0)
            return sign * (0.6 + (abs(boosted) - 0.6) * 0.2)
        }
        return boosted
    }
    
    private func applyCrispProcessor(sample: Float, enhancement: Float) -> Float {
        // Crisp high-mid enhancement without harshness
        let enhanced = sample * enhancement
        
        // Air enhancement with smoothing
        let smoothed = enhanced * 0.9 + sample * 0.1
        
        // Gentle limiting
        return max(-0.8, min(0.8, smoothed))
    }
    
    private func applySilkyHighs(sample: Float, enhancement: Float) -> Float {
        // Silky smooth high-frequency enhancement
        let enhanced = sample * enhancement
        
        // Silk smoothing algorithm
        let silk = tanh(enhanced * 0.8) * 1.25
        
        // Blend for natural sound
        return enhanced * 0.7 + silk * 0.3
    }
    
    // MARK: - Vocal-Friendly Processing Functions
    
    private func applyVocalFriendlyMids(sample: Float, enhancement: Float) -> Float {
        // Vocal presence enhancement without compression pumping
        let enhanced = sample * enhancement
        
        // Very gentle saturation for warmth without pumping
        if abs(enhanced) > 0.8 {
            let sign = enhanced >= 0 ? Float(1.0) : Float(-1.0)
            let softened = 0.8 + (abs(enhanced) - 0.8) * 0.1 // Very gentle
            return sign * softened
        }
        return enhanced
    }
    
    private func applyVocalFriendlyHighMids(sample: Float, enhancement: Float) -> Float {
        // Crisp vocal enhancement without harshness or pumping
        let enhanced = sample * enhancement
        
        // Smooth high-mid processing for vocal clarity
        let smoothed = enhanced * 0.95 + sample * 0.05 // Very subtle smoothing
        
        // Gentle limiting to prevent harshness
        return max(-0.9, min(0.9, smoothed))
    }
    
    private func applyTransparentLimiter(sample: Float, threshold: Float) -> Float {
        // Ultra-transparent limiting that doesn't pump on vocals
        let absS = abs(sample)
        if absS <= threshold { return sample }
        
        let excess = absS - threshold
        let knee: Float = 0.05 // Very soft knee
        
        if excess <= knee {
            // Ultra-soft knee region - almost no compression
            let ratio: Float = 1.0 - (excess / knee) * 0.1 // Very gentle slope
            let limited = threshold + excess * ratio
            return sample >= 0 ? limited : -limited
        } else {
            // Gentle limiting region
            let hardExcess = excess - knee
            let limited = threshold + knee * 0.9 + hardExcess * 0.05 // Very gentle final limiting
            return sample >= 0 ? limited : -limited
        }
    }
    
    private func applyButterLimiter(sample: Float, threshold: Float) -> Float {
        // Buttery smooth transparent limiting
        let absS = abs(sample)
        if absS <= threshold { return sample }
        
        let excess = absS - threshold
        let knee: Float = 0.1 // Soft knee
        
        if excess <= knee {
            // Soft knee region
            let ratio: Float = 1.0 - (excess / knee) * 0.5
            let limited = threshold + excess * ratio
            return sample >= 0 ? limited : -limited
        } else {
            // Hard limiting region with smooth curve
            let hardExcess = excess - knee
            let limited = threshold + knee * 0.5 + hardExcess * 0.1
            return sample >= 0 ? limited : -limited
        }
    }
    
    private func applyStereoEnhancement(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameLength: Int, sampleRate: Float) {
        let invSqrt2: Float = 0.70710678
        var midLPF: Float = 0
        var sideHPF: Float = 0
        
        // Frequency-dependent stereo widening
        let lowMidAlpha = expf(-2.0 * Float.pi * 300.0 / sampleRate)  // Keep mono below 300Hz
        let sideHPAlpha = expf(-2.0 * Float.pi * 200.0 / sampleRate)  // HPF for side channel
        let airLPAlpha = expf(-2.0 * Float.pi * 12000.0 / sampleRate) // Air band processing
        
        var airL: Float = 0
        var airR: Float = 0
        
        for i in 0..<frameLength {
            let l = left[i]
            let r = right[i]
            
            // M/S processing
            let mid = (l + r) * invSqrt2
            let side = (l - r) * invSqrt2
            
            // Keep low frequencies mono for focus
            midLPF = lowMidAlpha * midLPF + (1 - lowMidAlpha) * mid
            let lowMid = midLPF
            let highMid = mid - lowMid
            
            // Process side channel for width
            let sideHPOut = side - sideHPF
            sideHPF = sideHPAlpha * sideHPF + (1 - sideHPAlpha) * side
            let enhancedSide = sideHPOut * 1.3 // Widen the stereo image
            
            // Recombine with controlled width
            let finalMid = lowMid + highMid * 0.9 // Slight mono reduction in highs
            let finalSide = enhancedSide * 0.8 // Control width to prevent extreme separation
            
            // Convert back to L/R
            var newL = (finalMid + finalSide) * invSqrt2
            var newR = (finalMid - finalSide) * invSqrt2
            
            // Add subtle air enhancement
            airL = airLPAlpha * airL + (1 - airLPAlpha) * newL
            airR = airLPAlpha * airR + (1 - airLPAlpha) * newR
            
            let airEnhanceL = newL - airL
            let airEnhanceR = newR - airR
            
            newL += airEnhanceL * 0.2 // Subtle air
            newR += airEnhanceR * 0.2
            
            // Final stereo coherence and imaging
            let coherence: Float = 0.05 // Small amount of channel bleed for cohesion
            let finalL = newL * (1 - coherence) + newR * coherence
            let finalR = newR * (1 - coherence) + newL * coherence
            
            // NO LIMITING - Just safety clipping
            left[i] = max(-0.99, min(0.99, finalL))
            right[i] = max(-0.99, min(0.99, finalR))
        }
    }
    
    // MARK: - Professional Dynamic Mastering Functions
    
    private struct DynamicInfo {
        let rms: Float
        let peak: Float
        let crestFactor: Float
        let transientRatio: Float
    }
    
    private struct DynamicEQStates {
        var bassEnvelope: Float = 0
        var midEnvelope: Float = 0
        var highEnvelope: Float = 0
        var spectralBalance: Float = 0
    }
    
    private struct TransientInfo {
        let level: Float
        let isAttack: Bool
    }
    
    private func analyzeDynamics(buffer: AVAudioPCMBuffer) -> DynamicInfo {
        let rms = calculateBufferRMS(buffer: buffer)
        var peak: Float = 0
        var transientEnergy: Float = 0
        
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        
        for c in 0..<channelCount {
            if let samples = buffer.floatChannelData?[c] {
                for i in 0..<frameLength {
                    peak = max(peak, abs(samples[i]))
                    if i > 0 {
                        let diff = abs(samples[i] - samples[i-1])
                        transientEnergy += diff
                    }
                }
            }
        }
        
        let crestFactor = 20 * log10f(peak / max(rms, 0.001))
        let transientRatio = transientEnergy / Float(frameLength * channelCount)
        
        return DynamicInfo(rms: rms, peak: peak, crestFactor: crestFactor, transientRatio: transientRatio)
    }
    
    private func calculateOptimalGain(currentRMS: Float, peak: Float, crestFactor: Float) -> Float {
        // Dynamic gain based on content
        let targetRMS: Float
        if crestFactor > 20 {
            // Very dynamic content - preserve headroom
            targetRMS = 0.08 // -22dBFS
        } else if crestFactor > 12 {
            // Moderately dynamic
            targetRMS = 0.1 // -20dBFS
        } else {
            // Less dynamic - can push harder
            targetRMS = 0.125 // -18dBFS
        }
        
        let gain = targetRMS / max(currentRMS, 0.001)
        let peakLimitedGain = 0.9 / max(peak, 0.001)
        
        return min(gain, peakLimitedGain, 2.0) // Max 6dB boost
    }
    
    private func detectTransient(sample: Float, envelope: inout Float, memory: inout Float, sampleRate: Float) -> TransientInfo {
        let attackTime: Float = 0.001 // 1ms
        let releaseTime: Float = 0.05 // 50ms
        
        let attackAlpha = expf(-1.0 / (attackTime * sampleRate))
        let releaseAlpha = expf(-1.0 / (releaseTime * sampleRate))
        
        let rectified = abs(sample)
        
        if rectified > envelope {
            envelope = attackAlpha * envelope + (1 - attackAlpha) * rectified
        } else {
            envelope = releaseAlpha * envelope + (1 - releaseAlpha) * rectified
        }
        
        let transientLevel = max(0, rectified - envelope)
        let isAttack = rectified > memory * 1.5
        memory = rectified
        
        return TransientInfo(level: transientLevel, isAttack: isAttack)
    }
    
    private func processTransientChain(sample: Float, transientLevel: Float, attack: Bool) -> Float {
        if attack {
            // Enhance attack transients for punch
            return sample * (1.0 + transientLevel * 2.0)
        } else {
            // Preserve sustain
            return sample * (1.0 + transientLevel * 0.5)
        }
    }
    
    private func processSustainChain(sample: Float, transientLevel: Float) -> Float {
        // Inverse of transient - enhance sustain when transient is low
        let sustainLevel = 1.0 - transientLevel
        
        // Warm compression for body
        let threshold: Float = 0.5
        if abs(sample) > threshold {
            let ratio: Float = 2.0
            let excess = abs(sample) - threshold
            let compressed = threshold + excess / ratio
            let sign = sample >= 0 ? Float(1) : Float(-1)
            return sign * compressed * sustainLevel
        }
        return sample * sustainLevel
    }
    
    private func processHarmonicChain(sample: Float, order: Int) -> Float {
        // Generate musical harmonics
        var harmonic = sample
        
        // 2nd harmonic (octave) - warmth
        let second = sample * sample * (sample >= 0 ? 1 : -1) * 0.05
        
        // 3rd harmonic (fifth) - richness
        let third = sample * sample * sample * 0.02
        
        // 5th harmonic - presence
        let fifth = powf(sample, 5) * 0.01
        
        harmonic = sample + second + third + fifth
        
        // Soft saturation
        return tanh(harmonic * 0.8) * 1.25
    }
    
    private func applyDynamicEQ(sub: Float, low: Float, lowMid: Float, mid: Float, highMid: Float, high: Float,
                                states: inout DynamicEQStates, transientLevel: Float) ->
    (sub: Float, low: Float, lowMid: Float, mid: Float, highMid: Float, high: Float) {
        
        // Update envelopes
        let envAlpha: Float = 0.99
        states.bassEnvelope = envAlpha * states.bassEnvelope + (1 - envAlpha) * abs(sub + low)
        states.midEnvelope = envAlpha * states.midEnvelope + (1 - envAlpha) * abs(mid)
        states.highEnvelope = envAlpha * states.highEnvelope + (1 - envAlpha) * abs(highMid + high)
        
        // Calculate spectral balance
        let totalEnergy = states.bassEnvelope + states.midEnvelope + states.highEnvelope
        states.spectralBalance = totalEnergy > 0 ? states.midEnvelope / totalEnergy : 0.33
        
        // Dynamic adjustments based on content
        var processedSub = sub
        var processedLow = low
        var processedLowMid = lowMid
        var processedMid = mid
        var processedHighMid = highMid
        var processedHigh = high
        
        // If bass-heavy, reduce slightly
        if states.bassEnvelope > states.midEnvelope * 2 {
            processedSub *= 0.9
            processedLow *= 0.95
        } else {
            // Otherwise enhance for fullness
            processedSub *= 1.1
            processedLow *= 1.05
        }
        
        // Always reduce mud
        processedLowMid *= 0.7 - (transientLevel * 0.2) // Less reduction on transients
        
        // Preserve mids (vocals)
        processedMid *= 1.0 + (states.spectralBalance * 0.1) // Gentle adaptive boost
        
        // Enhance highs based on content
        if states.highEnvelope < states.midEnvelope * 0.5 {
            // Needs more highs
            processedHighMid *= 1.15
            processedHigh *= 1.2
        } else {
            // Already bright enough
            processedHighMid *= 1.05
            processedHigh *= 1.1
        }
        
        return (processedSub, processedLow, processedLowMid, processedMid, processedHighMid, processedHigh)
    }
    
    private func mixParallelChains(dry: Float, transient: Float, sustain: Float, harmonic: Float, transientLevel: Float) -> Float {
        // Adaptive mixing based on content
        let transientMix: Float = transientLevel > 0.1 ? 0.3 : 0.1
        let sustainMix: Float = 1.0 - transientMix - 0.1
        let harmonicMix: Float = 0.1
        
        // Break down the complex expression into simpler parts
        let dryComponent = dry * Float(0.5)
        let transientComponent = transient * transientMix
        let sustainComponent = sustain * sustainMix * Float(0.3)
        let harmonicComponent = harmonic * harmonicMix
        
        return dryComponent + transientComponent + sustainComponent + harmonicComponent
    }
    
    private func applyAdaptiveLimiting(sample: Float, threshold: Float, transientLevel: Float) -> Float {
        // Allow more headroom for transients
        let adaptiveThreshold = threshold + (transientLevel * 0.05)
        
        let absS = abs(sample)
        if absS <= adaptiveThreshold { return sample }
        
        // Very soft limiting for transparency
        let excess = absS - adaptiveThreshold
        let ratio = 1.0 - excess / (excess + 0.2)
        let limited = adaptiveThreshold + excess * ratio * 0.5
        
        return sample >= 0 ? limited : -limited
    }
    
    private func applyPsychoacousticEnhancement(samples: UnsafeMutablePointer<Float>, frameLength: Int, sampleRate: Float) {
        // Apply subtle Haas effect for width
        let delaysamples = Int(0.00002 * sampleRate) // 20 microseconds
        
        for i in (delaysamples..<frameLength).reversed() {
            // Blend with slightly delayed version for depth
            samples[i] = samples[i] * 0.95 + samples[i - delaysamples] * 0.05
        }
        
        // Apply dithering for transparency
        for i in 0..<frameLength {
            let dither = (Float.random(in: -1...1) + Float.random(in: -1...1)) * 0.00001
            samples[i] += dither
        }
    }
    
    // MARK: - HYPER ENHANCEMENT ALGORITHMS
    
    private func applyProfessionalClarity(samples: UnsafeMutablePointer<Float>, frameCount: Int, settings: GenreMasteringSettings) {
        // 🎯 PROFESSIONAL CLARITY: Studio-grade high-frequency enhancement
        let sampleRate: Float = 44100
        
        // Stage 1: Gentle High-Shelf (10kHz+)
        var hfState: Float = 0
        let hfAlpha = expf(-2.0 * Float.pi * 10000.0 / sampleRate)
        
        // Stage 2: Subtle presence enhancement
        var presenceState: Float = 0
        let presenceAlpha = expf(-2.0 * Float.pi * 3000.0 / sampleRate)
        
        for i in 0..<frameCount {
            let input = samples[i]
            
            // VOCAL CLARITY: Multi-band high-frequency processing
            // Air band (10kHz+) for vocal shimmer and clarity
            hfState = hfAlpha * hfState + (1 - hfAlpha) * input
            let hfComponent = input - hfState
            let vocalAir = hfComponent * settings.highdBoost * 0.8 // Strong air enhancement
            
            // Vocal presence (2-5kHz) for intelligibility and cut
            presenceState = presenceAlpha * presenceState + (1 - presenceAlpha) * input
            let presenceComponent = input - presenceState
            let vocalPresence = presenceComponent * settings.midClarity * 0.6 // Strong presence boost
            
            // Vocal brightness (5-8kHz) for modern clarity
            let brightnessAlpha = expf(-2.0 * Float.pi * 6500.0 / sampleRate)
            var brightnessState: Float = 0
            brightnessState = brightnessAlpha * brightnessState + (1 - brightnessAlpha) * input
            let brightnessComponent = input - brightnessState
            let vocalBrightness = brightnessComponent * settings.highdBoost * 0.4
            
            // CRYSTAL CLEAR VOCAL COMBINATION
            samples[i] = input + vocalAir + vocalPresence + vocalBrightness
            
            // Professional soft limiting for competitive level
            if abs(samples[i]) > 0.95 {
                samples[i] = tanh(samples[i] * 0.9) * 0.9
            }
        }
    }
    
    private func applyStudioRichness(samples: UnsafeMutablePointer<Float>, frameCount: Int, settings: GenreMasteringSettings) {
        // 🎨 STUDIO RICHNESS: Professional harmonic enhancement for depth
        
        // Stage 1: Professional tube-style saturation
        let saturationDrive = 1.0 + settings.harmonicEnhancement * 1.5 // Controlled saturation
        
        // Stage 2: Strong midrange enhancement
        var midState: Float = 0
        let midAlpha = expf(-2.0 * Float.pi * 1000.0 / 44100)
        
        for i in 0..<frameCount {
            let input = samples[i]
            
            // Controlled tube saturation for warmth and character
            let driven = input * saturationDrive
            let saturated = driven / (1.0 + abs(driven) * 0.5) // Balanced saturation
            
            // Professional midrange warmth
            midState = midAlpha * midState + (1 - midAlpha) * input
            let midBoost = midState * settings.midClarity * 0.25 // Controlled boost
            
            // Balanced 2nd harmonic for warmth
            let harmonic2 = input * input * settings.harmonicEnhancement * 0.08 // Controlled harmonic
            
            // Professional studio combination
            samples[i] = saturated + midBoost + harmonic2
            
            // Professional saturation limiting for competitive level
            if abs(samples[i]) > 0.95 {
                samples[i] = tanh(samples[i] * 0.9) * 0.9
            }
        }
    }
    
    private func applyProfessionalLowEnd(samples: UnsafeMutablePointer<Float>, frameCount: Int, settings: GenreMasteringSettings) {
        // 💪 PROFESSIONAL LOW-END: Studio-grade bass enhancement with punch
        
        // FAT AND DEEP BASS: Multi-stage low-end processing
        
        // Stage 1: Deep sub-bass (20-60Hz) for foundation
        var deepSubState: Float = 0
        let deepSubAlpha = expf(-2.0 * Float.pi * 40.0 / 44100)
        
        // Stage 2: Sub-bass punch (60-120Hz) for kick drums
        var subPunchState: Float = 0
        let subPunchAlpha = expf(-2.0 * Float.pi * 80.0 / 44100)
        
        // Stage 3: Low-mid body (120-250Hz) for warmth and fullness
        var lowMidState: Float = 0
        let lowMidAlpha = expf(-2.0 * Float.pi * 180.0 / 44100)
        
        // Stage 4: Bass harmonics enhancement for richness
        var bassHarmonicState: Float = 0
        let bassHarmonicAlpha = expf(-2.0 * Float.pi * 240.0 / 44100)
        
        for i in 0..<frameCount {
            let input = samples[i]
            
            // DEEP SUB-BASS: Foundational low-end (20-60Hz)
            deepSubState = deepSubAlpha * deepSubState + (1 - deepSubAlpha) * input
            let deepSubBoost = deepSubState * settings.bassBoost * 0.8 // Strong foundation
            
            // SUB PUNCH: Kick drum presence (60-120Hz)
            subPunchState = subPunchAlpha * subPunchState + (1 - subPunchAlpha) * input
            let subPunch = subPunchState * settings.bassBoost * 0.7 // Strong punch
            
            // LOW-MID BODY: Warmth and fullness (120-250Hz)
            lowMidState = lowMidAlpha * lowMidState + (1 - lowMidAlpha) * input
            let lowMidBody = lowMidState * settings.bassBoost * 0.5 // Rich body
            
            // BASS HARMONICS: Added richness and definition
            bassHarmonicState = bassHarmonicAlpha * bassHarmonicState + (1 - bassHarmonicAlpha) * input
            let bassHarmonics = bassHarmonicState * settings.harmonicEnhancement * 0.3 // Harmonic richness
            
            // FAT AND DEEP BASS COMBINATION
            samples[i] = input + deepSubBoost + subPunch + lowMidBody + bassHarmonics
            
            // Professional bass limiting for competitive level
            if abs(samples[i]) > 0.95 {
                samples[i] = tanh(samples[i] * 0.9) * 0.9
            }
        }
    }
    
    private func applyProfessionalLimiter(samples: UnsafeMutablePointer<Float>, frameCount: Int, threshold: Float) {
        // 🎯 HYRAX-STYLE BRICKWALL LIMITER: Matchering-inspired transparent limiting
        
        let targetThreshold = powf(10, threshold / 20) // Convert dB to linear
        
        // Hyrax-style multi-stage limiting with lookahead
        var attackEnvelope: Float = 0
        var holdEnvelope: Float = 0
        var releaseEnvelope: Float = 0
        var gainReduction: Float = 1.0
        
        // Matchering-style timing constants (tight and transparent)
        let attackTime: Float = 0.0001 * 44100    // 0.1ms ultra-fast attack
        let holdTime: Float = 0.002 * 44100       // 2ms hold time
        let releaseTime: Float = 0.05 * 44100     // 50ms smooth release
        
        let attackCoeff = expf(-1.0 / attackTime)
        let holdCoeff = expf(-1.0 / holdTime)
        let releaseCoeff = expf(-1.0 / releaseTime)
        
        // Lookahead buffer for transparent limiting (Hyrax feature)
        let lookaheadSamples = Int(0.005 * 44100) // 5ms lookahead
        var lookaheadBuffer = [Float](repeating: 0, count: max(1, lookaheadSamples))
        var bufferIndex = 0
        
        for i in 0..<frameCount {
            let input = abs(samples[i])
            
            // Store current sample in lookahead buffer
            if lookaheadBuffer.count > 0 {
                lookaheadBuffer[bufferIndex] = samples[i]
                bufferIndex = (bufferIndex + 1) % lookaheadBuffer.count
            }
            
            // Find peak in lookahead window (Matchering sliding window approach)
            let lookaheadPeak = lookaheadBuffer.map { abs($0) }.max() ?? input
            
            // Multi-stage envelope following (Hyrax approach)
            
            // Stage 1: Attack - instant peak detection
            if lookaheadPeak > attackEnvelope {
                attackEnvelope = lookaheadPeak // Instant attack for brickwall limiting
            } else {
                attackEnvelope = attackCoeff * attackEnvelope + (1 - attackCoeff) * lookaheadPeak
            }
            
            // Stage 2: Hold - maintain gain reduction
            if attackEnvelope > holdEnvelope {
                holdEnvelope = attackEnvelope
            } else {
                holdEnvelope = holdCoeff * holdEnvelope + (1 - holdCoeff) * attackEnvelope
            }
            
            // Stage 3: Release - smooth recovery
            if holdEnvelope > releaseEnvelope {
                releaseEnvelope = holdEnvelope
            } else {
                releaseEnvelope = releaseCoeff * releaseEnvelope + (1 - releaseCoeff) * holdEnvelope
            }
            
            // Brickwall gain calculation (Matchering hard limiting approach)
            if releaseEnvelope > targetThreshold {
                let hardLimitRatio = targetThreshold / max(releaseEnvelope, 0.001)
                gainReduction = hardLimitRatio // Brickwall limiting
            } else {
                gainReduction = min(gainReduction * 1.001, 1.0) // Smooth release to unity
            }
            
            // Apply Hyrax-style transparent limiting
            samples[i] = samples[i] * gainReduction
            
            // Final safety brickwall (Matchering style)
            if abs(samples[i]) > 0.99 {
                samples[i] = tanh(samples[i] * 0.98) * 0.98 // Transparent soft clip
            }
        }
        
        print("🧱 HYRAX BRICKWALL LIMITER: Threshold \(String(format: "%.1f", threshold))dB")
    }
    
    // MARK: - MATCHERING-STYLE REFERENCE ANALYSIS
    
    struct ReferenceAnalysis {
        let rmsLevel: Float
        let peakAmplitude: Float
        let stereoWidth: Float
        let frequencySpectrum: [Float] // Frequency response curve
    }
    
    private func analyzeReferenceTrack() -> ReferenceAnalysis? {
        guard let referenceURL = referenceURL else {
            print("⚠️ No reference track available for Matchering analysis")
            return nil
        }
        
        do {
            let file = try AVAudioFile(forReading: referenceURL)
            let format = file.processingFormat
            let frameCount = UInt32(file.length)
            
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return nil
            }
            
            try file.read(into: buffer)
            
            let channelCount = Int(format.channelCount)
            let frameLength = Int(buffer.frameLength)
            
            guard let samples = buffer.floatChannelData?[0] else { return nil }
            
            // Calculate TRUE RMS level (no artificial boosting - pure reference matching)
            let rmsLevel = calculateTrueRMSLevel(samples: samples, frameCount: frameLength)
            
            // Calculate peak amplitude
            let peakAmplitude = calculatePeakAmplitude(samples: samples, frameCount: frameLength)
            
            // Calculate stereo width (if stereo)
            var stereoWidth: Float = 1.0
            if channelCount >= 2,
               let leftSamples = buffer.floatChannelData?[0],
               let rightSamples = buffer.floatChannelData?[1] {
                stereoWidth = calculateStereoWidth(left: leftSamples, right: rightSamples, frameLength: frameLength)
            }
            
            // Calculate frequency spectrum
            let frequencySpectrum = calculateFrequencySpectrum(samples: samples, frameCount: frameLength, sampleRate: Float(format.sampleRate))
            
            print("🎯 REFERENCE ANALYSIS:")
            print("   RMS Level: \(String(format: "%.3f", rmsLevel))")
            print("   Peak Amplitude: \(String(format: "%.3f", peakAmplitude))")
            print("   Stereo Width: \(String(format: "%.3f", stereoWidth))")
            print("   Spectrum Points: \(frequencySpectrum.count)")
            
            return ReferenceAnalysis(
                rmsLevel: rmsLevel,
                peakAmplitude: peakAmplitude,
                stereoWidth: stereoWidth,
                frequencySpectrum: frequencySpectrum
            )
            
        } catch {
            print("❌ Error analyzing reference track: \(error)")
            return nil
        }
    }
    
    private func calculateRMSLevel(samples: UnsafeMutablePointer<Float>, frameCount: Int) -> Float {
        var sum: Float = 0
        for i in 0..<frameCount {
            sum += samples[i] * samples[i]
        }
        return sqrtf(sum / Float(frameCount))
    }
    
    private func calculatePeakAmplitude(samples: UnsafeMutablePointer<Float>, frameCount: Int) -> Float {
        var peak: Float = 0
        for i in 0..<frameCount {
            peak = max(peak, abs(samples[i]))
        }
        return peak
    }
    
    private func calculateStereoWidth(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameLength: Int) -> Float {
        var correlation: Float = 0
        var leftPower: Float = 0
        var rightPower: Float = 0
        
        for i in 0..<frameLength {
            correlation += left[i] * right[i]
            leftPower += left[i] * left[i]
            rightPower += right[i] * right[i]
        }
        
        let denominator = sqrtf(leftPower * rightPower)
        if denominator > 0 {
            correlation /= denominator
        }
        
        // Convert correlation to width: -1 (mono) to 1 (wide stereo)
        return 1.0 - correlation
    }
    
    private func calculateFrequencySpectrum(samples: UnsafeMutablePointer<Float>, frameCount: Int, sampleRate: Float) -> [Float] {
        // Use FFT to get frequency response - simplified for speed
        let windowSize = min(1024, frameCount)  // Reduced for speed (was 4096)
        let halfWindow = windowSize / 2
        
        var spectrum = [Float](repeating: 0, count: halfWindow)
        let hopSize = max(1, frameCount / 10) // Analyze ~10 windows
        
        for windowStart in stride(from: 0, to: frameCount - windowSize, by: hopSize) {
            let windowSamples = Array(UnsafeBufferPointer(start: samples + windowStart, count: windowSize))
            let windowSpectrum = performFFT(samples: windowSamples)
            
            // Accumulate spectrum
            for i in 0..<min(spectrum.count, windowSpectrum.count) {
                spectrum[i] += windowSpectrum[i]
            }
        }
        
        // Normalize spectrum
        let maxMagnitude = spectrum.max() ?? 1.0
        if maxMagnitude > 0 {
            for i in 0..<spectrum.count {
                spectrum[i] /= maxMagnitude
            }
        }
        
        return spectrum
    }
    
    // MARK: - MATCHERING-STYLE MATCHING FUNCTIONS
    
    private func matchRMSLevel(buffer: AVAudioPCMBuffer, targetRMS: Float) {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        
        for c in 0..<channelCount {
            guard let samples = buffer.floatChannelData?[c] else { continue }
            
            let currentRMS = calculateTrueRMSLevel(samples: samples, frameCount: frameLength)
            if currentRMS > 0 {
                let rmsRatio = targetRMS / currentRMS
                let matchingRatio = min(rmsRatio, 3.0) // Conservative limit to prevent clipping
                
                for i in 0..<frameLength {
                    let boosted = samples[i] * matchingRatio
                    
                    // Apply soft limiting during RMS matching to prevent clipping
                    if abs(boosted) > 0.9 {
                        let sign = boosted > 0 ? Float(1.0) : Float(-1.0)
                        let excess = abs(boosted) - 0.9
                        let limitedExcess = tanh(excess * 5.0) * 0.09
                        samples[i] = sign * (0.9 + limitedExcess)
                    } else {
                        samples[i] = boosted
                    }
                }
            }
        }
        
        print("🎚️ RMS MATCHED: Target \(String(format: "%.3f", targetRMS))")
    }
    
    private func matchFrequencyResponse(buffer: AVAudioPCMBuffer, targetSpectrum: [Float], frameLength: Int, channelCount: Int) {
        // Simplified frequency matching using multi-band EQ approach
        let sampleRate = Float(buffer.format.sampleRate)
        
        for c in 0..<channelCount {
            guard let samples = buffer.floatChannelData?[c] else { continue }
            
            // Apply spectral matching using multiple frequency bands
            applySpectralMatching(samples: samples, frameLength: frameLength, targetSpectrum: targetSpectrum, sampleRate: sampleRate)
        }
        
        print("🎵 FREQUENCY RESPONSE MATCHED: \(targetSpectrum.count) bands")
    }
    
    private func applySpectralMatching(samples: UnsafeMutablePointer<Float>, frameLength: Int, targetSpectrum: [Float], sampleRate: Float) {
        // Simplified approach: Apply EQ bands based on target spectrum
        let numBands = min(10, targetSpectrum.count / 200) // Reduce to manageable bands
        
        for band in 0..<numBands {
            let freqIndex = (band * targetSpectrum.count) / numBands
            guard freqIndex < targetSpectrum.count else { continue }
            
            let centerFreq = (Float(freqIndex) / Float(targetSpectrum.count)) * (sampleRate / 2.0)
            let targetGain = targetSpectrum[freqIndex]
            
            // Apply simple IIR filter for this frequency band with high-frequency protection
            if centerFreq > 50 && centerFreq < 20000 {
                // Limit high-frequency boosts to prevent scratching
                let frequencyLimitedGain = if centerFreq > 3000 {
                    // Above 3kHz: much gentler matching to prevent harshness
                    min(targetGain, 1.05) // Max 5% boost in highs
                } else if centerFreq > 1000 {
                    // 1-3kHz: moderate limiting  
                    min(targetGain, 1.1) // Max 10% boost in upper mids
                } else {
                    targetGain // Full matching for low/mid frequencies
                }
                
                applyBandEQ(samples: samples, frameLength: frameLength, centerFreq: centerFreq, gain: frequencyLimitedGain, sampleRate: sampleRate)
            }
        }
    }
    
    private func applyBandEQ(samples: UnsafeMutablePointer<Float>, frameLength: Int, centerFreq: Float, gain: Float, sampleRate: Float) {
        // Simple one-pole filter for frequency band adjustment
        let alpha = expf(-2.0 * Float.pi * centerFreq / sampleRate)
        var state: Float = 0
        // Ultra-conservative gain to prevent high-frequency harshness
        let adjustedGain = 1.0 + (gain - 0.5) * 0.1 // Much gentler frequency matching
        
        for i in 0..<frameLength {
            let input = samples[i]
            state = alpha * state + (1 - alpha) * input
            let filtered = input - state
            samples[i] = input + filtered * (adjustedGain - 1.0)
        }
    }
    
    private func matchStereoWidth(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameLength: Int, targetWidth: Float) {
        let currentWidth = calculateStereoWidth(left: left, right: right, frameLength: frameLength)
        let widthAdjustment = targetWidth - currentWidth
        
        // Apply stereo width adjustment
        for i in 0..<frameLength {
            let mid = (left[i] + right[i]) * 0.5
            let side = (left[i] - right[i]) * 0.5
            
            let adjustedSide = side * (1.0 + widthAdjustment * 0.5)
            
            left[i] = mid + adjustedSide
            right[i] = mid - adjustedSide
        }
        
        print("🎧 STEREO WIDTH MATCHED: Target \(String(format: "%.3f", targetWidth))")
    }
    
    private func matchPeakAmplitude(buffer: AVAudioPCMBuffer, targetPeak: Float) {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let safeTargetPeak = min(targetPeak * 1.02, 0.99) // Match reference peak more aggressively
        
        print("🔍 PEAK MATCHING START: frameLength=\(frameLength), channels=\(channelCount), target=\(safeTargetPeak)")
        
        var globalPeak: Float = 0
        
        // Find current global peak
        for c in 0..<channelCount {
            guard let samples = buffer.floatChannelData?[c] else {
                print("⚠️ Channel \(c) samples is nil")
                continue
            }
            let channelPeak = calculatePeakAmplitude(samples: samples, frameCount: frameLength)
            globalPeak = max(globalPeak, channelPeak)
            print("🔍 Channel \(c) peak: \(channelPeak)")
        }
        
        print("🔍 Global peak found: \(globalPeak)")
        
        if globalPeak > 0 {
            let peakRatio = safeTargetPeak / globalPeak
            let conservativeRatio = min(peakRatio, 2.5) // Conservative limit to prevent clipping
            print("🔍 Peak ratio: \(conservativeRatio) (limited from \(peakRatio))")
            
            // Apply conservative peak matching with soft limiting
            for c in 0..<channelCount {
                guard let samples = buffer.floatChannelData?[c] else { continue }
                
                for i in 0..<frameLength {
                    let boosted = samples[i] * conservativeRatio
                    
                    // Apply soft limiting during peak matching
                    if abs(boosted) > 0.92 {
                        let sign = boosted > 0 ? Float(1.0) : Float(-1.0)
                        let excess = abs(boosted) - 0.92
                        let limitedExcess = tanh(excess * 3.0) * 0.07
                        samples[i] = sign * (0.92 + limitedExcess)
                    } else {
                        samples[i] = boosted
                    }
                }
            }
            print("🔍 Peak matching applied successfully")
        } else {
            print("⚠️ Global peak is 0, skipping peak matching")
        }
        
        print("📈 PEAK MATCHED: Target \(String(format: "%.3f", safeTargetPeak)) - CONTINUING TO BRICKWALL LIMITER")
    }
    
    // MARK: - TRUE MATCHERING ALGORITHM (Iterative Correction)
    
    private func applyIterativeMatchering(buffer: AVAudioPCMBuffer, referenceAnalysis: ReferenceAnalysis, frameLength: Int, channelCount: Int) {
        print("🎯 TRUE MATCHERING: Starting iterative correction process")
        
        // Step 1: Initial gentle RMS matching (like Matchering's level matching)
        let targetRMS = referenceAnalysis.rmsLevel
        let currentRMS = calculateBufferRMS(buffer: buffer)
        
        if currentRMS > 0 {
            let initialGain = min(targetRMS / currentRMS, 2.0) // Conservative initial gain
            
            for c in 0..<channelCount {
                guard let samples = buffer.floatChannelData?[c] else { continue }
                for i in 0..<frameLength {
                    samples[i] *= initialGain
                }
            }
            print("🎚️ MATCHERING STEP 1: Initial RMS correction applied, gain=\(String(format: "%.2f", initialGain))")
        }
        
        // Step 2: Iterative correction (multiple gentle passes like real Matchering)
        for iteration in 1...3 {
            print("🔄 MATCHERING ITERATION \(iteration): Refining match")
            
            let newRMS = calculateBufferRMS(buffer: buffer)
            if newRMS > 0 {
                let correctionRatio = targetRMS / newRMS
                let gentleCorrection = 1.0 + (correctionRatio - 1.0) * 0.3 // 30% of needed correction per iteration
                
                for c in 0..<channelCount {
                    guard let samples = buffer.floatChannelData?[c] else { continue }
                    for i in 0..<frameLength {
                        // Apply gentle correction with soft limiting
                        let corrected = samples[i] * gentleCorrection
                        samples[i] = tanh(corrected * 0.9) * 1.1 // Soft saturation like real mastering
                    }
                }
                
                print("🎚️ MATCHERING ITERATION \(iteration): Applied \(String(format: "%.3f", gentleCorrection)) correction")
            }
        }
        
        // Step 3: Final peak matching (gentle, like Matchering's final stage)
        let currentPeak = calculateBufferPeak(buffer: buffer)
        let targetPeak = min(referenceAnalysis.peakAmplitude, 0.95) // Conservative target
        
        if currentPeak > 0 {
            let peakRatio = min(targetPeak / currentPeak, 1.5) // Conservative peak matching
            
            for c in 0..<channelCount {
                guard let samples = buffer.floatChannelData?[c] else { continue }
                for i in 0..<frameLength {
                    samples[i] *= peakRatio
                }
            }
            
            print("📈 MATCHERING FINAL: Peak matching applied, ratio=\(String(format: "%.3f", peakRatio))")
        }
        
        print("✅ TRUE MATCHERING COMPLETE: Smooth iterative processing finished")
    }
    
    private func calculateBufferPeak(buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var peak: Float = 0
        
        for c in 0..<channelCount {
            guard let samples = buffer.floatChannelData?[c] else { continue }
            for i in 0..<frameLength {
                peak = max(peak, abs(samples[i]))
            }
        }
        
        return peak
    }
    
    // MARK: - IMPROVED MATCHERING FUNCTIONS
    
    private func calculateTrueRMSLevel(samples: UnsafeMutablePointer<Float>, frameCount: Int) -> Float {
            // More accurate RMS calculation with windowing (like Matchering)
            let windowSize = min(4096, frameCount)
            let hopSize = windowSize / 2
            var totalRMS: Float = 0
            var windowCount = 0
            
            for windowStart in stride(from: 0, to: frameCount - windowSize, by: hopSize) {
                var windowSum: Float = 0
                for i in 0..<windowSize {
                    let sample = samples[windowStart + i]
                    windowSum += sample * sample
                }
                totalRMS += sqrtf(windowSum / Float(windowSize))
                windowCount += 1
            }
            
            return windowCount > 0 ? totalRMS / Float(windowCount) : 0
        }
        
    private func applyMatcheringBrickwallLimiter(samples: UnsafeMutablePointer<Float>, frameCount: Int) {
            print("🚀 PROFESSIONAL BRICKWALL LIMITER: frameCount=\(frameCount)")
            
            // Ultra-gentle limiting to eliminate harshness
            let ceiling: Float = 0.92 // Very conservative ceiling for smooth sound
            let softThreshold: Float = 0.82 // Start very gentle limiting early
            var peakCount = 0
            
            // Soft brickwall limiting with smooth compression curve
            for i in 0..<frameCount {
                let absLevel = abs(samples[i])
                let sign = samples[i] > 0 ? Float(1.0) : Float(-1.0)
                
                if absLevel > ceiling {
                    // Hard limit above ceiling
                    samples[i] = sign * ceiling
                    peakCount += 1
                } else if absLevel > softThreshold {
                    // Soft limiting zone with smooth curve
                    let excess = absLevel - softThreshold
                    let maxExcess = ceiling - softThreshold
                    let ratio = excess / maxExcess
                    
                    // Ultra-smooth tanh curve for musical limiting without harshness
                    let compressedExcess = tanh(ratio * 1.5) * maxExcess * 0.7
                    samples[i] = sign * (softThreshold + compressedExcess)
                }
                // Below soft threshold: no processing needed
            }
            
            print("🚀 FAST BRICKWALL COMPLETE: Ceiling \(String(format: "%.2f", ceiling)), Peaks limited: \(peakCount)")
        }
        
        // MARK: - HEAVY MASTERING FUNCTIONS (Optimized for 2-3 Minutes)
        
    private func applyOptimizedMultiBandEQ(samples: UnsafeMutablePointer<Float>, frameLength: Int, sampleRate: Float) {
            // 5-band EQ optimized for speed but professional quality
            
            // Sub-bass management (20-60Hz)
            applyOptimizedBandEQ(samples: samples, frameLength: frameLength, centerFreq: 40, gain: 0.9, q: 0.7, sampleRate: sampleRate)
            
            // Low-mid cleanup (200-400Hz) - critical for clarity
            applyOptimizedBandEQ(samples: samples, frameLength: frameLength, centerFreq: 300, gain: 0.8, q: 1.0, sampleRate: sampleRate)
            
            // Mid presence (1-2kHz) - vocal intelligibility
            applyOptimizedBandEQ(samples: samples, frameLength: frameLength, centerFreq: 1500, gain: 1.05, q: 0.8, sampleRate: sampleRate)
            
            // High presence (3-6kHz) - gentle clarity without harshness
            applyOptimizedBandEQ(samples: samples, frameLength: frameLength, centerFreq: 4500, gain: 1.03, q: 0.7, sampleRate: sampleRate)
            
            // Air band (10-16kHz) - subtle sparkle without scratching
            applyOptimizedBandEQ(samples: samples, frameLength: frameLength, centerFreq: 12000, gain: 1.02, q: 0.5, sampleRate: sampleRate)
        }
        
    private func applyHeavyDynamicsProcessing(samples: UnsafeMutablePointer<Float>, frameLength: Int, sampleRate: Float) {
            // Multi-stage dynamics: gentle compression + aggressive limiting
            
            // Stage 1: Musical compression (slow, transparent)
            applyMusicalCompression(samples: samples, frameLength: frameLength, threshold: 0.8, ratio: 2.5, attack: 0.999, release: 0.9995)
            
            // Stage 2: Peak control (fast, transparent)
            applyPeakCompression(samples: samples, frameLength: frameLength, threshold: 0.9, ratio: 8.0, attack: 0.99, release: 0.999)
        }
        
    private func applyHarmonicEnhancement(samples: UnsafeMutablePointer<Float>, frameLength: Int, sampleRate: Float) {
            // Ultra-subtle harmonic saturation to prevent high-frequency artifacts
            let drive: Float = 1.1 // Very gentle saturation
            let mix: Float = 0.08   // 8% wet signal
            
            for i in 0..<frameLength {
                let dry = samples[i]
                let wet = tanhf(dry * drive) // Soft saturation
                samples[i] = dry * (1.0 - mix) + wet * mix
            }
        }
        
    private func applyTransientShaping(samples: UnsafeMutablePointer<Float>, frameLength: Int, sampleRate: Float) {
            // Enhance transients for punch while preserving dynamics
            var envelope: Float = 0
            var prevSample: Float = 0
            let transientGain: Float = 1.2
            let sustainGain: Float = 0.95
            
            for i in 0..<frameLength {
                let current = abs(samples[i])
                
                // Simple envelope follower
                if current > envelope {
                    envelope = current * 0.1 + envelope * 0.9 // Fast attack
                } else {
                    envelope = current * 0.001 + envelope * 0.999 // Slow release
                }
                
                // Detect transients (rapid level increase)
                let transientDetect = current - abs(prevSample)
                
                if transientDetect > 0.01 && envelope > 0.1 {
                    // Enhance transients
                    samples[i] *= transientGain
                } else {
                    // Gentle sustain processing
                    samples[i] *= sustainGain
                }
                
                prevSample = samples[i]
            }
        }
        
    private func applyHeavyStereoProcessing(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameLength: Int, sampleRate: Float) {
            // Professional stereo enhancement with M/S processing
            let widthFactor: Float = 1.3 // Controlled width enhancement
            let bassMonoFreq: Float = 120.0 // Keep bass centered
            let bassMonoAlpha = expf(-2.0 * Float.pi * bassMonoFreq / sampleRate)
            
            var bassL: Float = 0, bassR: Float = 0
            
            for i in 0..<frameLength {
                // M/S processing
                let mid = (left[i] + right[i]) * 0.5
                let side = (left[i] - right[i]) * 0.5 * widthFactor
                
                // Bass mono processing
                bassL = left[i] * (1.0 - bassMonoAlpha) + bassL * bassMonoAlpha
                bassR = right[i] * (1.0 - bassMonoAlpha) + bassR * bassMonoAlpha
                let bassMono = (bassL + bassR) * 0.5
                
                // Reconstruct with enhanced width but mono bass
                left[i] = mid + side
                right[i] = mid - side
                
                // Apply bass mono below cutoff
                let highFreqL = left[i] - bassL
                let highFreqR = right[i] - bassR
                
                left[i] = bassMono + highFreqL
                right[i] = bassMono + highFreqR
            }
        }
        
    private func applySinglePoleHighpass(samples: UnsafeMutablePointer<Float>, frameLength: Int, cutoff: Float, sampleRate: Float) {
            let rc = 1.0 / (2.0 * Float.pi * cutoff)
            let dt = 1.0 / sampleRate
            let alpha = dt / (rc + dt)
            
            var previousOutput: Float = 0
            var previousInput: Float = 0
            
            for i in 0..<frameLength {
                let output = alpha * (previousOutput + samples[i] - previousInput)
                previousOutput = output
                previousInput = samples[i]
                samples[i] = output
            }
        }
        
    private func applyOptimizedBandEQ(samples: UnsafeMutablePointer<Float>, frameLength: Int, centerFreq: Float, gain: Float, q: Float, sampleRate: Float) {
            // Optimized biquad peak filter with adjustable Q
            let omega = 2.0 * Float.pi * centerFreq / sampleRate
            let cosOmega = cos(omega)
            let sinOmega = sin(omega)
            let alpha = sinOmega / (2.0 * q)
            let a = gain
            
            let b0 = 1.0 + alpha * a
            let b1 = -2.0 * cosOmega
            let b2 = 1.0 - alpha * a
            let a0 = 1.0 + alpha / a
            let a1 = -2.0 * cosOmega
            let a2 = 1.0 - alpha / a
            
            var x1: Float = 0, x2: Float = 0
            var y1: Float = 0, y2: Float = 0
            
            for i in 0..<frameLength {
                let input = samples[i]
                let output = (b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
                
                x2 = x1
                x1 = input
                y2 = y1
                y1 = output
                
                samples[i] = output
            }
        }
        
    private func applyMusicalCompression(samples: UnsafeMutablePointer<Float>, frameLength: Int, threshold: Float, ratio: Float, attack: Float, release: Float) {
            // Musical compressor with smooth envelope
            var envelope: Float = 0
            
            for i in 0..<frameLength {
                let inputLevel = abs(samples[i])
                
                // Smooth envelope follower
                if inputLevel > envelope {
                    envelope = envelope * attack + inputLevel * (1.0 - attack)
                } else {
                    envelope = envelope * release + inputLevel * (1.0 - release)
                }
                
                // Compression with knee
                if envelope > threshold {
                    let excess = envelope - threshold
                    let compressedExcess = excess / ratio
                    let gainReduction = (threshold + compressedExcess) / envelope
                    samples[i] *= gainReduction
                }
            }
        }
        
    private func applyPeakCompression(samples: UnsafeMutablePointer<Float>, frameLength: Int, threshold: Float, ratio: Float, attack: Float, release: Float) {
            // Fast peak compressor for transient control
            var envelope: Float = 0
            
            for i in 0..<frameLength {
                let inputLevel = abs(samples[i])
                
                // Fast envelope for peaks
                if inputLevel > envelope {
                    envelope = envelope * attack + inputLevel * (1.0 - attack)
                } else {
                    envelope = envelope * release + inputLevel * (1.0 - release)
                }
                
                // Aggressive compression for peaks
                if envelope > threshold {
                    let excess = envelope - threshold
                    let compressedExcess = excess / ratio
                    let gainReduction = (threshold + compressedExcess) / envelope
                    samples[i] *= gainReduction
                }
            }
        }
    }


struct AudioFeatures {
    var rms: Float = 0
    var peak: Float = 0
    var spectralCentroid: Float = 0
    var bassEnergy: Float = 0
    var midEnergy: Float = 0
    var trebleEnergy: Float = 0
    var dynamicRange: Float = 0
    // ML-enhanced features
    var genre: String = "unknown"
    var energy: Float = 0
    var danceability: Float = 0
    var valence: Float = 0
    var tempo: Float = 0
    var mfcc: [Float] = Array(repeating: 0, count: 13)
    var chroma: [Float] = Array(repeating: 0, count: 12)
    var spectralRolloff: Float = 0
}
    
    

