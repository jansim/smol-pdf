cask "smol-pdf" do
  version "0.1"
  sha256 "263d7553bf65d0e6b771e7a32fbd3223e99b13a412af0dc0464e08173cc55317"

  url "https://github.com/jansim/smol-pdf/releases/download/v#{version}/smol-pdf-#{version}-macos-universal.zip"
  name "smol-pdf"
  desc "PDF compressor"
  homepage "https://github.com/jansim/smol-pdf"

  depends_on macos: :sonoma

  app "smol-pdf.app"
  binary "#{appdir}/smol-pdf.app/Contents/Resources/smolpdf"

  # The app is signed ad hoc, not notarized (that needs a paid Apple Developer account), so
  # Gatekeeper would refuse to open it, and the command-line tool inside it, while they are quarantined.
  # Should this fail, the app is still installed and opens with "Open Anyway" (see the README).
  postflight_steps do
    run "/usr/bin/xattr",
        args:         ["-dr", "com.apple.quarantine", "{{appdir}}/smol-pdf.app"],
        must_succeed: false
  end

  zap trash: [
    "~/Library/Preferences/io.simson.smol-pdf.plist",
    "~/Library/Saved Application State/io.simson.smol-pdf.savedState",
  ]
end
