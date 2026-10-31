# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Homebrew formula. This repo doubles as its own tap:
#
#   brew tap sameehj/kai https://github.com/sameehj/kai
#   brew install kai            # latest release
#   brew install --HEAD kai     # current master
#
# After tagging a release, run scripts/update-formula.sh <tag> to fill in
# url + sha256 below.
class Kai < Formula
  desc "Local security layer for AI coding agents"
  homepage "https://github.com/sameehj/kai"
  license "GPL-3.0-only"
  head "https://github.com/sameehj/kai.git", branch: "master"

  uses_from_macos "curl"

  def install
    system "make", "kai"
    bin.install "kai"
    pkgshare.install "policy/default.policy"
  end

  def caveats
    <<~EOS
      Write a default policy, then turn Kai on for your agents:
        kai init
        kai install claude    # Claude Code
        kai install cursor    # Cursor
    EOS
  end

  test do
    assert_match version.to_s.sub(/^HEAD-.*/, ""), shell_output("#{bin}/kai version")
    ENV["KAI_HOME"] = testpath/".kai"
    fake = "AKIA" + "IOSFODNN7EXAMPLE"
    assert_match "REDACTED", pipe_output("#{bin}/kai redact", "key #{fake}")
  end
end
