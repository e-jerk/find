class Find < Formula
  desc "GPU-accelerated find utility using Metal and Vulkan"
  homepage "https://github.com/e-jerk/find"
  version "0.1.1"
  license "GPL-3.0-or-later"

  on_macos do
    on_arm do
      url "https://github.com/e-jerk/find/releases/download/v#{version}/find-macos-arm64-v#{version}.tar.gz"
      sha256 "02ce8713c0b4e34da2336bde9f1065a1757971ad761d721c9ed9dd0237b1ac32" # macos-arm64
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/e-jerk/find/releases/download/v#{version}/find-linux-arm64-v#{version}.tar.gz"
      sha256 "5bb821b029292a405b4bf5ccacca480f1eed8590180f56e3f37520d12fc3323e" # linux-arm64
    end
    on_intel do
      url "https://github.com/e-jerk/find/releases/download/v#{version}/find-linux-amd64-v#{version}.tar.gz"
      sha256 "d860c750df8744dae0c226fde2be0ab8c096f2aedeead5b62e72c59691fc645a" # linux-amd64
    end
    depends_on "vulkan-loader"
  end

  depends_on "molten-vk" => :recommended if OS.mac?

  def install
    bin.install "find"
  end

  test do
    system "#{bin}/find", "--help"
  end
end
