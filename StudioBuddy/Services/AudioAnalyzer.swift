import Foundation
import AVFoundation
import Accelerate

class AudioAnalyzer {
    
    static let hopSize = 512
    
    // MARK: - BPM Detection
    
    static func detectBPM(from url: URL) -> Float? {
        guard let result = analyzeRemote(url: url) else { return nil }
        return result.bpm
    }
    
    private static func computeNoveltyCurve(samples: [Float], sampleRate: Float) -> [Float] {
        let windowSize = 2048
        let hopSize = Self.hopSize // Smaller hop for better resolution
        var novelty: [Float] = []
        
        var previousMagnitudes = [Float](repeating: 0, count: windowSize / 2)
        
        for i in stride(from: 0, to: samples.count - windowSize, by: hopSize) {
            let window = Array(samples[i..<i+windowSize])
            let magnitudes = performFFT(samples: window)
            
            // Half-wave rectified spectral flux
            var flux: Float = 0
            for j in 0..<magnitudes.count {
                let diff = magnitudes[j] - previousMagnitudes[j]
                flux += max(diff, 0)
            }
            novelty.append(flux)
            
            previousMagnitudes = magnitudes
        }
        
        // Normalize novelty curve
        var maxNovelty: Float = 0
        vDSP_maxv(novelty, 1, &maxNovelty, vDSP_Length(novelty.count))
        if maxNovelty > 0 {
            vDSP_vsdiv(novelty, 1, &maxNovelty, &novelty, 1, vDSP_Length(novelty.count))
        } else {
            print("Debug: Novelty curve max is 0 - possible silent file")
        }
        
        return novelty
    }
    
    private static func estimateTempoFromNovelty(novelty: [Float], sampleRate: Float) -> Float {
        if novelty.isEmpty {
            print("Debug: Empty novelty curve")
            return 120
        }
        
        // Compute autocorrelation of novelty curve
        let maxLag = Int(sampleRate * 4 / 60) // Max 4 seconds (for 15 BPM min)
        let n = novelty.count
        var autocorrelation = [Float](repeating: 0, count: maxLag)
        
        for lag in 1..<maxLag {
            var sum: Float = 0
            for i in 0..<(n - lag) {
                sum += novelty[i] * novelty[i + lag]
            }
            autocorrelation[lag] = sum / Float(n - lag)
        }
        
        // Apply wider tempo preference window (Gaussian around 120, but broader sigma for 155)
        let preferredBPM: Float = 120
        let sigma: Float = 50 // Increased from 30 to allow higher tempos like 155
        for lag in 1..<maxLag {
            let periodTime = Float(lag) * (Float(Self.hopSize) / sampleRate)
            let bpm = 60 / periodTime
            let weight = exp(-pow(bpm - preferredBPM, 2) / (2 * pow(sigma, 2)))
            autocorrelation[lag] *= weight
        }
        
        // Find peaks in autocorrelation
        var peaks: [Int] = []
        for i in 1..<autocorrelation.count - 1 {
            if autocorrelation[i] > autocorrelation[i-1] && autocorrelation[i] > autocorrelation[i+1] && autocorrelation[i] > 0.1 {
                peaks.append(i)
            }
        }
        
        print("Debug: Found \(peaks.count) autocorrelation peaks")
        if peaks.isEmpty {
            return 120
        }
        
        // Refine peak picking: Use a lower threshold and require prominence
        var refinedPeaks: [Int] = []
        for i in 1..<autocorrelation.count - 1 {
            let prominence = autocorrelation[i] - max(autocorrelation[i-1], autocorrelation[i+1])
            if prominence > 0.05 && autocorrelation[i] > 0.05 { // Lowered thresholds
                refinedPeaks.append(i)
            }
        }
        print("Debug: Refined to \(refinedPeaks.count) prominent peaks")
        
        guard !refinedPeaks.isEmpty else { return 120 }
        
        // Find the most prominent period
        var bestPeriod = refinedPeaks[0]
        var bestStrength = autocorrelation[bestPeriod]
        for peak in refinedPeaks {
            if autocorrelation[peak] > bestStrength {
                bestStrength = autocorrelation[peak]
                bestPeriod = peak
            }
        }
        
        // Convert period (in hops) to BPM
        let hopTime = Float(Self.hopSize) / sampleRate
        let periodTime = Float(bestPeriod) * hopTime
        let bpm = 60.0 / periodTime
        
        // Expanded candidate scoring
        let candidateBPMs = [bpm / 4, bpm / 3, bpm / 2, bpm, bpm * 2, bpm * 3, bpm * 4].filter { $0 >= 60 && $0 <= 200 }
        
        // Score candidates with more multiples
        var bestScore: Float = 0
        var bestBPM: Float = 120
        for cand in candidateBPMs {
            let candPeriod = 60.0 / cand / hopTime
            let score = autocorrelationValue(at: Int(candPeriod), autocorr: autocorrelation) +
                        autocorrelationValue(at: Int(candPeriod * 2), autocorr: autocorrelation) +
                        autocorrelationValue(at: Int(candPeriod * 3), autocorr: autocorrelation) +
                        autocorrelationValue(at: Int(candPeriod / 2), autocorr: autocorrelation) +
                        autocorrelationValue(at: Int(candPeriod / 3), autocorr: autocorrelation)
            print("Debug: Candidate \(cand) BPM score: \(score)")
            if score > bestScore {
                bestScore = score
                bestBPM = cand
            }
        }
        
        return round(bestBPM)
    }
    
    private static func autocorrelationValue(at lag: Int, autocorr: [Float]) -> Float {
        if lag < autocorr.count {
            return autocorr[lag]
        }
        return 0
    }
    
    // MARK: - Key Detection
    
    static func detectKey(from url: URL) -> (key: String?, chroma: [Float]?) {
        guard let result = analyzeRemote(url: url) else { return (nil, nil) }
        return (result.key, nil)
    }

    private struct RemoteAnalysis: Decodable { let bpm: Float; let key: String }
    private static func analyzeRemote(url: URL) -> RemoteAnalysis? {
        // Use Song-Key BPM Finder production API endpoint for file analysis
        let server = URL(string: "https://song-key-bpm-finder-app-production.up.railway.app/api/analyze")!
        var req = URLRequest(url: server)
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let data = try? Data(contentsOf: url) else {
            print("AudioAnalyzer: failed to read file data at \(url)")
            return nil
        }
        print("AudioAnalyzer: preparing upload to \(server) name=\(url.lastPathComponent) size=\(data.count) bytes")
        var body = Data()
        func part(name: String, filename: String, mime: String, data: Data) -> Data {
            var d = Data()
            d.append("--\(boundary)\r\n".data(using: .utf8)!)
            d.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            d.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            d.append(data)
            d.append("\r\n".data(using: .utf8)!)
            return d
        }
        let ext = url.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "wav", "wave": mime = "audio/wav"
        case "mp3": mime = "audio/mpeg"
        case "m4a", "aac": mime = "audio/aac"
        case "flac": mime = "audio/flac"
        default: mime = "application/octet-stream"
        }
        body.append(part(name: "audio", filename: url.lastPathComponent, mime: mime, data: data))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let sem = DispatchSemaphore(value: 0)
        var out: RemoteAnalysis?
        func decodeResponse(_ data: Data?, _ resp: URLResponse?, _ err: Error?) -> Bool {
            if let err = err { print("AudioAnalyzer: request error - \(err)"); return false }
            guard let http = resp as? HTTPURLResponse else { print("AudioAnalyzer: no HTTP response"); return false }
            print("AudioAnalyzer: response status = \(http.statusCode)")
            guard http.statusCode == 200, let data = data else {
                if let data = data, let s = String(data: data, encoding: .utf8) { print("AudioAnalyzer: error body = \(s)") }
                return false
            }
            do {
                out = try JSONDecoder().decode(RemoteAnalysis.self, from: data)
                print("AudioAnalyzer: decoded = bpm=\(out?.bpm ?? 0), key=\(out?.key ?? "-")")
                return true
            } catch {
                print("AudioAnalyzer: decode error - \(error)")
                return false
            }
        }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if decodeResponse(data, resp, err) { return }
            // Fallback: StudioBuddy analyzer
            let fallback = URL(string: "https://studiobuddy-production.up.railway.app/analyze/bpm-key")!
            var fbReq = URLRequest(url: fallback)
            fbReq.httpMethod = "POST"
            fbReq.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            fbReq.setValue("application/json", forHTTPHeaderField: "Accept")
            fbReq.httpBody = body
            print("AudioAnalyzer: falling back to \(fallback)")
            let sem2 = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: fbReq) { d2, r2, e2 in
                _ = decodeResponse(d2, r2, e2)
                sem2.signal()
            }.resume()
            _ = sem2.wait(timeout: .now() + 30)
        }.resume()
        _ = sem.wait(timeout: .now() + 30)
        return out
    }
    
    private static func calculateChromaVector(samples: [Float], sampleRate: Float) -> [Float] {
        let windowSize = 4096
        let hopSize = windowSize / 2
        var chromaVector = [Float](repeating: 0, count: 12)
        var windowCount = 0
        
        for i in stride(from: 0, to: samples.count - windowSize, by: hopSize) {
            let window = Array(samples[i..<i+windowSize])
            let magnitudes = performFFT(samples: window)
            
            // Map frequency bins to pitch classes
            for (index, magnitude) in magnitudes.enumerated() {
                let frequency = Float(index) * sampleRate / Float(windowSize)
                if frequency > 80 && frequency < 2000 { // Focus on musical range
                    let pitch = frequencyToPitch(frequency: frequency)
                    let pitchClass = Int(pitch.rounded()) % 12
                    chromaVector[pitchClass] += magnitude
                }
            }
            windowCount += 1
        }
        
        // Normalize
        let sum = chromaVector.reduce(0, +)
        if sum > 0 {
            chromaVector = chromaVector.map { $0 / sum }
        }
        
        return chromaVector
    }
    
    private static func frequencyToPitch(frequency: Float) -> Float {
        // MIDI pitch = 69 + 12 * log2(f/440)
        return 69.0 + 12.0 * log2f(frequency / 440.0)
    }
    
    private static func matchToKey(chroma: [Float]) -> String {
        // Krumhansl-Schmuckler key profiles
        let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        
        let keys = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        var bestKey = "C Major"
        var bestCorrelation: Float = -1
        
        for i in 0..<12 {
            // Rotate profiles
            let rotatedMajor = Array(majorProfile[i...] + majorProfile[..<i])
            let rotatedMinor = Array(minorProfile[i...] + minorProfile[..<i])
            
            // Calculate correlation
            let majorCorr = correlation(chroma, rotatedMajor)
            let minorCorr = correlation(chroma, rotatedMinor)
            
            if majorCorr > bestCorrelation {
                bestCorrelation = majorCorr
                bestKey = "\(keys[i]) Major"
            }
            
            if minorCorr > bestCorrelation {
                bestCorrelation = minorCorr
                bestKey = "\(keys[i]) Minor"
            }
        }
        
        return bestKey
    }
    
    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        
        let n = Float(a.count)
        let sumA = a.reduce(0, +)
        let sumB = b.reduce(0, +)
        let sumAB = zip(a, b).map(*).reduce(0, +)
        let sumA2 = a.map { $0 * $0 }.reduce(0, +)
        let sumB2 = b.map { $0 * $0 }.reduce(0, +)
        
        let numerator = n * sumAB - sumA * sumB
        let denominator = sqrt((n * sumA2 - sumA * sumA) * (n * sumB2 - sumB * sumB))
        
        return denominator != 0 ? numerator / denominator : 0
    }
    
    // MARK: - FFT Helper
    
    private static func performFFT(samples: [Float]) -> [Float] {
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
}

// MARK: - Remote Finder integration helpers
extension AudioAnalyzer {
	/// Fetch BPM and musical key from the deployed Finder app using a Spotify track ID.
	/// Returns (bpm, keyNameString), where keyNameString is like "C Major" or "A Minor".
	static func fetchBpmAndKeyFromFinder(spotifyTrackId: String, completion: @escaping (Float?, String?) -> Void) {
		SongKeyBpmAPI.shared.getTrackData(spotifyTrackId: spotifyTrackId) { result in
			switch result {
			case .success(let features):
				let keyName = SongKeyBpmAPI.shared.keyName(from: features.key, mode: features.mode)
				DispatchQueue.main.async { completion(features.tempo, keyName) }
			case .failure:
				DispatchQueue.main.async { completion(nil, nil) }
			}
		}
	}

	/// Search by title on the Finder app and return the first candidate's BPM/key if available.
	/// Useful when you don't have a Spotify track ID.
	static func searchBpmAndKeyFromFinder(title: String, completion: @escaping (Float?, String?) -> Void) {
		SongKeyBpmAPI.shared.findBpm(title: title) { result in
			switch result {
			case .success(let items):
				guard let first = items.first else { DispatchQueue.main.async { completion(nil, nil) }; return }
				let keyName = SongKeyBpmAPI.shared.keyName(from: first.key, mode: first.mode)
				DispatchQueue.main.async { completion(first.tempo, keyName) }
			case .failure:
				DispatchQueue.main.async { completion(nil, nil) }
			}
		}
	}
}