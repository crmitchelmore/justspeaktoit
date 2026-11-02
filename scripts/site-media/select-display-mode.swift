import CoreGraphics
import Foundation

// Prefer a HiDPI mode on the hosted runner so website captures are sharp; keep the
// current mode when the virtual display offers none. Prints the mode list as evidence.
let display = CGMainDisplayID()
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
for mode in modes {
    print("mode \(mode.width)x\(mode.height) pixels \(mode.pixelWidth)x\(mode.pixelHeight)")
}
let hiDPI = modes.filter { $0.pixelWidth >= $0.width * 2 && $0.width >= 1024 && $0.width <= 1600 }
guard let best = hiDPI.max(by: { $0.width < $1.width }) else {
    print("No HiDPI mode; keeping \(CGDisplayPixelsWide(display))x\(CGDisplayPixelsHigh(display))")
    exit(0)
}
var config: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&config)
CGConfigureDisplayWithDisplayMode(config, display, best, nil)
let result = CGCompleteDisplayConfiguration(config, .permanently)
print("Selected \(best.width)x\(best.height) at \(best.pixelWidth)x\(best.pixelHeight): \(result.rawValue)")
