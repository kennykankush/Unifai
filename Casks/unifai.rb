cask "unifai" do
  version "0.9.7"
  sha256 "2a207034d9b41e2d805853ff3d255631f901c23f0e7a6e2c084cf62097cac86d"

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
