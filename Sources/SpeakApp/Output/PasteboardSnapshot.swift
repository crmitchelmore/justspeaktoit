import AppKit

/// Byte-for-byte copy of everything on a pasteboard — every item and every
/// type — so a temporary paste can put the user's clipboard back exactly as it
/// was, whether it held plain text, rich text, an image, files or several
/// items at once (issue #673).
struct PasteboardSnapshot: Equatable {
  let items: [[NSPasteboard.PasteboardType: Data]]

  init(items: [[NSPasteboard.PasteboardType: Data]]) {
    self.items = items
  }

  /// Reads every item and type currently on `pasteboard`. Promised data is
  /// resolved now, because the source app may be gone by the time we restore.
  init(reading pasteboard: NSPasteboard) {
    let pasteboardItems = pasteboard.pasteboardItems ?? []
    self.items = pasteboardItems.compactMap { item in
      var contents: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) {
          contents[type] = data
        }
      }
      return contents.isEmpty ? nil : contents
    }
  }

  var isEmpty: Bool { items.isEmpty }

  /// Replaces the pasteboard's contents with the snapshot. An empty snapshot
  /// leaves the pasteboard cleared, which is what the user had.
  func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    guard !items.isEmpty else { return }
    let objects = items.map { contents -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in contents {
        item.setData(data, forType: type)
      }
      return item
    }
    pasteboard.writeObjects(objects)
  }
}
