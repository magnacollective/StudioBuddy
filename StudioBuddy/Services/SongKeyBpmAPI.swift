import Foundation

struct SKBFTrackFeatures: Decodable {
	let tempo: Float?
	let key: Int?
	let mode: Int?
}

struct SKBFTrackItem: Decodable {
	let id: String?
	let name: String?
	let tempo: Float?
	let key: Int?
	let mode: Int?
}

enum SKBFAPIError: Error {
	case invalidURL
	case badResponse
	case decoding
}

final class SongKeyBpmAPI {
	static let shared = SongKeyBpmAPI()
	private init() {}

	private let baseURL = URL(string: "https://song-key-bpm-finder-app-production.up.railway.app")!

	func getTrackData(spotifyTrackId: String, completion: @escaping (Result<SKBFTrackFeatures, Error>) -> Void) {
		guard var components = URLComponents(url: baseURL.appendingPathComponent("/api/getTrackData"), resolvingAgainstBaseURL: false) else {
			completion(.failure(SKBFAPIError.invalidURL))
			return
		}
		components.queryItems = [URLQueryItem(name: "id", value: spotifyTrackId)]
		guard let url = components.url else {
			completion(.failure(SKBFAPIError.invalidURL))
			return
		}
		URLSession.shared.dataTask(with: url) { data, resp, err in
			if let err = err { completion(.failure(err)); return }
			guard let data, let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
				completion(.failure(SKBFAPIError.badResponse)); return
			}
			do {
				let features = try JSONDecoder().decode(SKBFTrackFeatures.self, from: data)
				completion(.success(features))
			} catch {
				completion(.failure(SKBFAPIError.decoding))
			}
		}.resume()
	}

	func findBpm(title: String, completion: @escaping (Result<[SKBFTrackItem], Error>) -> Void) {
		guard var components = URLComponents(url: baseURL.appendingPathComponent("/api/findBpm"), resolvingAgainstBaseURL: false) else {
			completion(.failure(SKBFAPIError.invalidURL))
			return
		}
		components.queryItems = [URLQueryItem(name: "title", value: title)]
		guard let url = components.url else {
			completion(.failure(SKBFAPIError.invalidURL))
			return
		}
		URLSession.shared.dataTask(with: url) { data, resp, err in
			if let err = err { completion(.failure(err)); return }
			guard let data, let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
				completion(.failure(SKBFAPIError.badResponse)); return
			}
			do {
				let items = try JSONDecoder().decode([SKBFTrackItem].self, from: data)
				completion(.success(items))
			} catch {
				completion(.failure(SKBFAPIError.decoding))
			}
		}.resume()
	}

	// MARK: - Helpers

	func keyName(from key: Int?, mode: Int?) -> String {
		guard let key = key, key >= 0 && key <= 11 else { return "Unknown" }
		let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
		let quality = (mode == 1) ? "Major" : "Minor"
		return "\(names[key]) \(quality)"
	}
}


