cask "unifai" do
  version "0.9.5"
  sha256 "de1d6dc1c9415d95de1059e4a6cf02d0310d722cf22349581ee6148cff9036c9"

  url "https://github.com/kennykankush/unifAI/releases/download/v#{version}/Unifai-#{version}.zip"
  name "Unifai"
  desc "Local hub for AI wallets, spend, renewals and releases, with a read-only MCP server"
  homepage "https://github.com/kennykankush/unifAI"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Unifai.app"
  binary "#{appdir}/Unifai.app/Contents/MacOS/unifai-mcp"

  uninstall quit: "dev.unifai.app"

  zap trash: [
    "~/Library/Application Support/Unifai",
    "~/Library/Preferences/dev.unifai.app.plist",
    "~/Library/Group Containers/483LU3J5WJ.dev.unifai",
  ]
end
