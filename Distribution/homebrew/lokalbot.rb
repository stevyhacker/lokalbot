cask "lokalbot" do
  version "0.6.2"
  sha256 "17817f2cae9beb5c14a43aedad98bd6d51c9985261414791e73c1b30df173842"

  url "https://github.com/stevyhacker/lokalbot/releases/download/v#{version}/LokalBot.dmg",
      verified: "github.com/stevyhacker/lokalbot/"
  name "LokalBot"
  desc "Local LLM workhorse that keeps a private memory of your workday"
  homepage "https://www.lokalbot.com/"

  livecheck do
    url :url
    strategy :github_releases
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sequoia

  # ~/Library/Application Support/me.dotenv.LokalBot IS the user's meeting
  # library (transcripts, summaries) — privacy-sensitive data, not cache.
  # It is listed here so an explicit `brew zap --cask lokalbot` removes it,
  # and zap always moves files to the Trash rather than deleting them.
  # A plain `brew uninstall --cask lokalbot` never touches this folder.
  zap trash: [
    "~/Library/Application Support/me.dotenv.LokalBot",
    "~/Library/Preferences/me.dotenv.LokalBot.plist",
  ]
end
