//
//  JustSpeakToItWidgetExtensionLiveActivity.swift
//  JustSpeakToItWidgetExtension
//
//  Created by Chris Mitchelmore on 09/01/2026.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct JustSpeakToItWidgetExtensionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct JustSpeakToItWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JustSpeakToItWidgetExtensionAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension JustSpeakToItWidgetExtensionAttributes {
    fileprivate static var preview: JustSpeakToItWidgetExtensionAttributes {
        JustSpeakToItWidgetExtensionAttributes(name: "World")
    }
}

extension JustSpeakToItWidgetExtensionAttributes.ContentState {
    fileprivate static var smiley: JustSpeakToItWidgetExtensionAttributes.ContentState {
        JustSpeakToItWidgetExtensionAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: JustSpeakToItWidgetExtensionAttributes.ContentState {
         JustSpeakToItWidgetExtensionAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: JustSpeakToItWidgetExtensionAttributes.preview) {
   JustSpeakToItWidgetExtensionLiveActivity()
} contentStates: {
    JustSpeakToItWidgetExtensionAttributes.ContentState.smiley
    JustSpeakToItWidgetExtensionAttributes.ContentState.starEyes
}
