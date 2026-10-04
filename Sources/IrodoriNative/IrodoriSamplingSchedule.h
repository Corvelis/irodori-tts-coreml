#pragma once

#include <stdexcept>
#include <vector>

struct IrodoriSamplingStep {
  float time;
  float delta;
};

enum class IrodoriSamplingGrid { linear, frontLoaded };

// MeanFlow is conditioned on both the start time and interval length. Always
// use the same interval for conditioning and for the latent update.
inline std::vector<IrodoriSamplingStep> IrodoriSamplingSchedule(
    int count, IrodoriSamplingGrid grid) {
  if (count <= 0 || (grid != IrodoriSamplingGrid::linear && count != 4)) {
    throw std::invalid_argument("Invalid Irodori sampling schedule");
  }
  if (grid == IrodoriSamplingGrid::frontLoaded) {
    return {{1.f, .125f}, {.875f, .125f}, {.75f, .25f}, {.5f, .5f}};
  }
  std::vector<IrodoriSamplingStep> result;
  const float delta = 1.f / count;
  for (int index = 0; index < count; ++index) {
    result.push_back({1.f - index * delta, delta});
  }
  return result;
}
