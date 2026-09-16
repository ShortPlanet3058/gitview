import SwiftUI

struct FilesScreen: View {
    var body: some View { Page { ScreenHeader(title: "Files", subtitle: "Coming next.") } }
}
struct ActivityScreen: View {
    var body: some View { Page { ScreenHeader(title: "Activity", subtitle: "Coming next.") } }
}
struct StatisticsScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    var body: some View { Page { ScreenHeader(title: "Statistics", subtitle: "Coming next."); AdvancedModelCard() } }
}
