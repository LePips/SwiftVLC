/// Orders seek evidence so a frame displayed before the native clock lands
/// cannot be misreported as post-landing decoder recovery.
struct HLSSeekLandingFrameGate: Equatable {
  private(set) var landingNativeTimeMilliseconds: Int64?
  private(set) var displayedPicturesAtLanding: UInt64?

  mutating func observe(
    nativeTimeMilliseconds: Int64,
    expectedTimeMilliseconds: Int64,
    toleranceMilliseconds: Int64,
    displayedPictures: UInt64
  ) -> Bool {
    if let displayedPicturesAtLanding {
      return displayedPictures > displayedPicturesAtLanding
    }
    guard
      abs(nativeTimeMilliseconds - expectedTimeMilliseconds)
      <= toleranceMilliseconds
    else { return false }
    landingNativeTimeMilliseconds = nativeTimeMilliseconds
    displayedPicturesAtLanding = displayedPictures
    return false
  }
}
