class Find < Formula
  desc "GPU-accelerated find utility using Metal and Vulkan"
  homepage "https://github.com/e-jerk/find"
  version "0.1.0"
  license "GPL-3.0-or-later"

  on_macos do
    on_arm do
      url "https://github.com/e-jerk/find/releases/download/v#{version}/find-macos-arm64-v#{version}.tar.gz"
      sha256 "b9837f0d234bae1e893f6161a3339f3c56a0a76ab63ff8fb9045ff9120118a5f" # macos-arm64
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/e-jerk/find/releases/download/v#{version}/find-linux-arm64-v#{version}.tar.gz"
      sha256 "ca3618c304ab74773759fdd55674deb3149c6b98e5986d8c4ae31a4edda85ca2" # linux-arm64
    end
    on_intel do
      url "https://github.com/e-jerk/find/releases/download/v#{version}/find-linux-amd64-v#{version}.tar.gz"
      sha256 "37334ed78a3c6599e94037460f740432d76ac349b9d34ad0e43a5c32fef88c09" # linux-amd64
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
