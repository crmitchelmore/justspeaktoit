import Foundation

extension Data {
  mutating func appendString(_ string: String) {
    if let data = string.data(using: .utf8) {
      append(data)
    }
  }

  mutating func appendFormField(named name: String, value: String, boundary: String) {
    appendString("--\(boundary)\r\n")
    appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
    appendString("\(value)\r\n")
  }

  mutating func appendFileField(
    named name: String,
    filename: String,
    mimeType: String,
    fileData: Data,
    boundary: String
  ) {
    appendString("--\(boundary)\r\n")
    appendString(
      "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
    appendString("Content-Type: \(mimeType)\r\n\r\n")
    append(fileData)
    appendString("\r\n")
  }
}
