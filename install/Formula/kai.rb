class Kai < Formula
  desc "See exactly what your AI agent did"
  homepage "https://github.com/kai-ai/kai"
  url "https://github.com/kai-ai/kai/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "CHANGE_ME"
  license "MIT"

  depends_on "go" => :build

  def install
    system "go", "build", *std_go_args(ldflags: "-s -w"), "./cmd/kai"
  end

  test do
    assert_match "KAI", shell_output("#{bin}/kai --help")
  end
end
