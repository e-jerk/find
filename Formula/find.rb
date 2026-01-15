class Find < Formula
  desc "GPU-accelerated find utility using Metal and Vulkan"
  homepage "https://github.com/e-jerk/find"
  version "0.2.0"
  license "GPL-3.0-or-later"

  on_macos do
    on_arm do
      url "https://github.com/e-jerk/find/releases/download/v#{version}/find-macos-arm64-v#{version}.tar.gz"
      sha256 "ff1dab758c38fc47fa5d7c7461babe4703429aadc44ada1c160ae8236c414dae" # macos-arm64
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/e-jerk/find/releases/download/v#{version}/find-linux-arm64-v#{version}.tar.gz"
      sha256 "88efee88b55bd4b3053377ea224c117ec94874c138a0df396f67a32be93db714" # linux-arm64
    end
    on_intel do
      url "https://github.com/e-jerk/find/releases/download/v#{version}/find-linux-amd64-v#{version}.tar.gz"
      sha256 "b5d32bf8d561437eb3e78d5b923b8b0e149732fa2163acc6168c613351eb92fe" # linux-amd64
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
