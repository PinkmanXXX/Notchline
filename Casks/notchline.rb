cask "notchline" do
  version "0.4.0"
  sha256 :no_check

  url "https://github.com/USERNAME/Notchline/releases/download/v#{version}/Notchline.dmg"
  name "Notchline"
  desc "Long-running terminal commands in the MacBook notch"
  homepage "https://github.com/USERNAME/Notchline"

  depends_on macos: ">= :sonoma"

  app "Notchline.app"

  zap trash: [
    "~/Library/Application Support/Notchline",
  ]
end
