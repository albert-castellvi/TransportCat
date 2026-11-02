import SwiftUI
import WidgetKit

/// Entry point of the widget extension (spec S20): the "Properes arribades"
/// widget and the "Segueix en directe" Live Activity share one bundle.
@main
struct TransportCatWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ArrivalWidget()
        ArrivalLiveActivity()
    }
}
