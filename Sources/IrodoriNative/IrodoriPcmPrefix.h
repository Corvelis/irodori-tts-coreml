#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <stdexcept>
#include <utility>
#include <vector>

// Emits only the prefix which the existing whole-wave tail trimmer cannot
// remove. Decoder windows must be supplied as a contiguous, completed prefix.
class IrodoriPcmPrefix {
 public:
  using Sink = std::function<void(const std::vector<int16_t> &)>;
  explicit IrodoriPcmPrefix(Sink sink) : sink_(std::move(sink)) {}

  void advance(const std::vector<float> &wave, size_t available) {
    if (!sink_) return;
    if (available > wave.size()) throw std::runtime_error("Invalid decoded prefix");
    while (scanned_ + block <= available) {
      double energy = 0;
      for (size_t i = scanned_; i < scanned_ + block; ++i) {
        const double v = std::isfinite(wave[i]) ? wave[i] : 0;
        energy += v * v;
      }
      const double rms = std::sqrt(energy / block);
      const size_t index = scanned_ / block;
      if (rms > 0.002) {
        if (!active_) {
          start_ = scanned_ > 5760 ? scanned_ - 5760 : 0;
          emittedEnd_ = start_;
          islandFirst_ = index;
        } else if (index - lastActive_ > 7) {
          // A previous island is no longer the final island and is kept even
          // when the whole-wave trimmer eventually rejects the new island.
          safeEnd_ = (lastActive_ + 1) * block;
          previousIslandEnd_ = safeEnd_;
          islandFirst_ = index;
          islandCount_ = 0;
          islandPeak_ = 0;
        }
        active_ = true;
        lastActive_ = index;
        ++islandCount_;
        islandPeak_ = std::max(islandPeak_, rms);
        const bool possibleTailArtifact = previousIslandEnd_ != 0 &&
          islandFirst_ * block >= previousIslandEnd_ + 28800 &&
          index - islandFirst_ + 1 <= 12 && islandCount_ <= 5 && islandPeak_ < 0.04;
        if (!possibleTailArtifact) safeEnd_ = scanned_ + block;
      }
      scanned_ += block;
    }
    // Begin with 300 ms of identical PCM, then add at least 100 ms per event.
    // This avoids starting a player with one tiny decoder window.
    const size_t minimum = emitted_.empty() ? 14400 : 4800;
    if (active_ && safeEnd_ >= emittedEnd_ + minimum) {
      std::vector<int16_t> chunk(safeEnd_ - emittedEnd_);
      for (size_t i = emittedEnd_; i < safeEnd_; ++i) {
        chunk[i - emittedEnd_] = quantize(wave[i]);
      }
      emitted_.insert(emitted_.end(), chunk.begin(), chunk.end());
      emittedEnd_ = safeEnd_;
      sink_(chunk);
    }
  }

  void finish(const std::vector<int16_t> &complete) {
    if (!sink_) return;
    // Also verify against the unchanged final postprocessor in production.
    if (complete.size() < emitted_.size() ||
        !std::equal(emitted_.begin(), emitted_.end(), complete.begin())) {
      throw std::runtime_error("Incremental PCM differs from completed audio");
    }
    if (complete.size() > emitted_.size()) {
      sink_(std::vector<int16_t>(complete.begin() + emitted_.size(), complete.end()));
    }
  }
  size_t emittedSamples() const { return emitted_.size(); }

 private:
  static int16_t quantize(float v) {
    return static_cast<int16_t>(std::lrint(std::clamp(std::isfinite(v) ? v : 0.f,
                                                    -1.f, 1.f) * 32767.f));
  }
  static constexpr size_t block = 960;
  Sink sink_;
  size_t scanned_ = 0, start_ = 0, emittedEnd_ = 0, safeEnd_ = 0;
  size_t lastActive_ = 0, islandFirst_ = 0, previousIslandEnd_ = 0, islandCount_ = 0;
  double islandPeak_ = 0;
  bool active_ = false;
  std::vector<int16_t> emitted_;
};
