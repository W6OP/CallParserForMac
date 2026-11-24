import Foundation

struct CtyDownloader {
    let fileURL = URL(string: "https://country-files.com")!

    /// Checks if a newer file exists on the server and downloads it if necessary.
    func downloadIfNewer(than localFileURL: URL) async throws {
        // 1. Create a HEAD request to check metadata without downloading the full body
        var request = URLRequest(url: fileURL)
        request.httpMethod = "HEAD"

        // Swift 6 uses async/await for network calls
        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            print("Server returned an error or unexpected status code.")
            return
        }

        // 2. Parse the Last-Modified header date
        if let lastModifiedString = httpResponse.value(forHTTPHeaderField: "Last-Modified") {
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = "E, dd MMM yyyy HH:mm:ss z"
            dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

            if let remoteDate = dateFormatter.date(from: lastModifiedString) {
                // 3. Get local file modification date
                let fileAttributes = try? FileManager.default.attributesOfItem(atPath: localFileURL.path)
                let localDate = fileAttributes?[.modificationDate] as? Date

                // 4. Download if the server file is newer or if the local file doesn't exist
                if localDate == nil || remoteDate > localDate! {
                    print("New version found. Downloading...")

                    // Swift 6 download method to a temporary location
                    let (tempURL, _) = try await URLSession.shared.download(for: URLRequest(url: fileURL))

                    // Replace the old file safely
                    if FileManager.default.fileExists(atPath: localFileURL.path) {
                        _ = try FileManager.default.replaceItemAt(localFileURL, withItemAt: tempURL)
                    } else {
                        try FileManager.default.moveItem(at: tempURL, to: localFileURL)
                    }
                    print("Download complete and file updated.")
                } else {
                    print("Local file is already up to date.")
                }
            }
        }
    }
}
