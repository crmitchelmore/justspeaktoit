//
//  JustSpeakToItWidgetExtensionBundle.swift
//  JustSpeakToItWidgetExtension
//
//  Created by Chris Mitchelmore on 09/01/2026.
//

import WidgetKit
import SwiftUI

@main
struct JustSpeakToItWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        TranscribeWidget()
        // Continuity for Home Screens that still hold the retired template
        // widget's kind; see `LegacyTemplateTranscribeWidget`.
        LegacyTemplateTranscribeWidget()
        if #available(iOS 18.0, *) {
            JustSpeakToItWidgetExtensionControl()
        }
        JustSpeakToItWidgetExtensionLiveActivity()
        OpenClawLiveActivity()
    }
}
