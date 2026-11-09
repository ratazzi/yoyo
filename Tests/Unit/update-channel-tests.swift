import Foundation

@main
struct UpdateChannelTests {
    static func main() {
        assert(UpdateChannel.selected(saved: nil, bundled: nil) == .stable)
        assert(UpdateChannel.selected(saved: nil, bundled: "nightly") == .nightly)
        assert(UpdateChannel.selected(saved: "stable", bundled: "nightly") == .stable)
        assert(UpdateChannel.selected(saved: "bad", bundled: "nightly") == .nightly)
        assert(UpdateChannel.stable.feedURL == "https://github.com/ratazzi/yoyo/releases/latest/download/appcast.xml")
        assert(UpdateChannel.nightly.feedURL == "https://github.com/ratazzi/yoyo/releases/download/nightly/appcast.xml")
        print("Update channels: defaults, persisted selection and GitHub feed URLs: PASS")
    }
}
