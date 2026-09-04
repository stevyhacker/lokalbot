import Foundation

/// Welcome choices are staged. Back/Continue and reopening the wizard do not
/// change capture settings; applying updates only the fields this wizard owns.
struct CaptureSetupDraft: Equatable {
    var meetingMode: AppSettings.AutoRecordMode
    var dayMemory: Bool
    var contextMode: AppSettings.ScreenContextCaptureMode

    init(settings: AppSettings) {
        meetingMode = settings.autoRecordMode
        dayMemory = settings.trackingEnabled
        contextMode = settings.effectiveScreenContextCaptureMode
    }

    func applying(to settings: AppSettings) -> AppSettings {
        var result = settings
        result.autoRecordMode = meetingMode
        result.trackingEnabled = dayMemory
        result.screenContextCaptureMode = dayMemory ? contextMode : .activityOnly
        result.screenshotsEnabled = result.screenContextCaptureMode.capturesPixels
        return result
    }
}
