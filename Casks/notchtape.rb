cask "notchtape" do
  version "0.4.0"
  sha256 :no_check

  url "https://github.com/USERNAME/NotchTape/releases/download/v#{version}/NotchTape.dmg"
  name "NotchTape"
  desc "Long-running terminal commands in the MacBook notch"
  homepage "https://github.com/USERNAME/NotchTape"

  depends_on macos: ">= :sonoma"

  app "NotchTape.app"

  zap trash: [
    "~/Library/Application Support/NotchTape",
  ]
end
