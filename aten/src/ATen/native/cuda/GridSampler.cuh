#include <ATen/ATen.h>
#include <ATen/NativeFunctions.h>
#include <ATen/native/cuda/KernelUtils.cuh>

namespace at { namespace native {

namespace detail {

  enum class GridSamplerInterpolation {Bilinear, Nearest, Bicubic};
  enum class GridSamplerPadding {Zeros, Border, Reflection};

}  // namespace detail

using detail::GridSamplerInterpolation;
using detail::GridSamplerPadding;

// Unnormalizes a coordinate from the -1 to +1 scale to its pixel index value,
// where we view each pixel as an area between (idx - 0.5) and (idx + 0.5).
// if align_corners: -1 and +1 get sent to the centers of the corner pixels
//     -1 --> 0
//     +1 --> (size - 1)
//     scale_factor = (size - 1) / 2
// if not align_corners: -1 and +1 get sent to the image edges
//     -1 --> -0.5
//     +1 --> (size - 1) + 0.5 == size - 0.5
//     scale_factor = size / 2
template <typename scalar_t>
static __forceinline__ __device__
scalar_t grid_sampler_unnormalize(scalar_t coord, int size, bool align_corners) {
  if (align_corners) {
    // unnormalize coord from [-1, 1] to [0, size - 1]
    return ((coord + 1.f) / 2) * (size - 1);
  } else {
    // unnormalize coord from [-1, 1] to [-0.5, size - 0.5]
    return ((coord + 1.f) * size - 1) / 2;
  }
}

// grid_sampler_unnormalize_set_grad works the same as grid_sampler_unnormalize
// except that it also returns the `d output / d input` via pointer argument
// `grad_in`.
// This is useful in the backward pass of grid_sampler.
template <typename scalar_t>
static __forceinline__ __device__
scalar_t grid_sampler_unnormalize_set_grad(scalar_t coord, int size,
                                           bool align_corners, scalar_t *grad_in) {
  if (align_corners) {
    // unnormalize coord from [-1, 1] to [0, size - 1]
    *grad_in = static_cast<scalar_t>(size - 1) / 2;
    return ((coord + 1.f) / 2) * (size - 1);
  } else {
    // unnormalize coord from [-1, 1] to [-0.5, size - 0.5]
    *grad_in = static_cast<scalar_t>(size) / 2;
    return ((coord + 1.f) * size - 1) / 2;
  }
}

// Clips coordinates to between 0 and clip_limit - 1
template <typename scalar_t>
static __forceinline__ __device__
scalar_t clip_coordinates(scalar_t in, int clip_limit) {
  return ::min(static_cast<scalar_t>(clip_limit - 1), ::max(in, static_cast<scalar_t>(0)));
}

// clip_coordinates_set_grad works similarly to clip_coordinates except that
// it also returns the `d output / d input` via pointer argument `grad_in`.
// This is useful in the backward pass of grid_sampler.
template <typename scalar_t>
static __forceinline__ __device__
scalar_t clip_coordinates_set_grad(scalar_t in, int clip_limit, scalar_t *grad_in) {
  // Note that it is important for the gradient calculation that borders
  // are considered out of bounds.
  if (in <= static_cast<scalar_t>(0)) {
    *grad_in = static_cast<scalar_t>(0);
    return static_cast<scalar_t>(0);
  } else {
    scalar_t max = static_cast<scalar_t>(clip_limit - 1);
    if (in >= max) {
      *grad_in = static_cast<scalar_t>(0);
      return max;
    } else {
      *grad_in = static_cast<scalar_t>(1);
      return in;
    }
  }
}

// Reflects coordinates until they fall between low and high (inclusive).
// The bounds are passed as twice their value so that half-integer values
// can be represented as ints.
template <typename scalar_t>
static __forceinline__ __device__
scalar_t reflect_coordinates(scalar_t in, int twice_low, int twice_high) {
  if (twice_low == twice_high) {
    return static_cast<scalar_t>(0);
  }
  scalar_t min = static_cast<scalar_t>(twice_low) / 2;
  scalar_t span = static_cast<scalar_t>(twice_high - twice_low) / 2;
  in = ::fabs(in - min);
  // `fmod` returns same sign as `in`, which is positive after the `fabs` above.
  scalar_t extra = ::fmod(in, span);
  int flips = static_cast<int>(::floor(in / span));
  if (flips % 2 == 0) {
    return extra + min;
  } else {
    return span - extra + min;
  }
}

// reflect_coordinates_set_grad works similarly to reflect_coordinates except
// that it also returns the `d output / d input` via pointer argument
// `grad_in`.
// This is useful in the backward pass of grid_sampler.
template <typename scalar_t>
static __forceinline__ __device__
scalar_t reflect_coordinates_set_grad(scalar_t in, int twice_low, int twice_high,
                                      scalar_t *grad_in) {
  if (twice_low == twice_high) {
    *grad_in = static_cast<scalar_t>(0);
    return static_cast<scalar_t>(0);
  }
  int grad_in_mult_;
  scalar_t min = static_cast<scalar_t>(twice_low) / 2;
  scalar_t span = static_cast<scalar_t>(twice_high - twice_low) / 2;
  in = in - min;
  if (in < static_cast<scalar_t>(0)) {
    grad_in_mult_ = -1;
    in = -in;
  } else {
    grad_in_mult_ = 1;
  }
  // `fmod` returns same sign as `in`, which is positive after the `if` above.
  scalar_t extra = ::fmod(in, span);
  int flips = static_cast<int>(::floor(in / span));
  if (flips % 2 == 0) {
    *grad_in = static_cast<scalar_t>(grad_in_mult_);
    return extra + min;
  } else {
    *grad_in = static_cast<scalar_t>(-grad_in_mult_);
    return span - extra + min;
  }
}

template<typename scalar_t>
static __forceinline__ __device__
scalar_t safe_downgrade_to_int_range(scalar_t x){
  // -100.0 does not have special meaning. This is just to make sure
  // it's not within_bounds_2d or within_bounds_3d, and does not cause
  // undefined behavior. See #35506.
  if (x > INT_MAX-1 || x < INT_MIN || !::isfinite(static_cast<double>(x)))
    return static_cast<scalar_t>(-100.0);
  return x;
}

template<typename scalar_t>
static __forceinline__ __device__
scalar_t compute_coordinates(scalar_t coord, int size,
                             GridSamplerPadding padding_mode,
                             bool align_corners) {
  if (padding_mode == GridSamplerPadding::Border) {
    // clip coordinates to image borders
    coord = clip_coordinates(coord, size);
  } else if (padding_mode == GridSamplerPadding::Reflection) {
    // reflect coordinates by image borders
    if (align_corners) {
      coord = reflect_coordinates(coord, 0, 2*(size - 1));
    } else {
      coord = reflect_coordinates(coord, -1, 2*size - 1);
    }
    // clip coordinates to image borders
    coord = clip_coordinates(coord, size);
  }

  coord = safe_downgrade_to_int_range(coord);
  return coord;
}

// Computes the pixel source index value for a grid coordinate
template <typename scalar_t>
static __forceinline__ __device__
scalar_t grid_sampler_compute_source_index(
    scalar_t coord,
    int size,
    GridSamplerPadding padding_mode,
    bool align_corners) {
  coord = grid_sampler_unnormalize(coord, size, align_corners);
  coord = compute_coordinates(coord, size, padding_mode, align_corners);
  return coord;
}

// grid_sampler_compute_source_index_set_grad works similarly to
// grid_sampler_compute_source_index except that it also returns the
// `d output / d input` via pointer argument `grad_in`.
// This is useful in the backward pass of grid_sampler.
template <typename scalar_t>
static __forceinline__ __device__
scalar_t grid_sampler_compute_source_index_set_grad(
    scalar_t coord,
    int size,
    GridSamplerPadding padding_mode,
    bool align_corners,
    scalar_t *grad_in) {
  scalar_t grad_clip, grad_refl;
  coord = grid_sampler_unnormalize_set_grad(coord, size, align_corners, grad_in);
  if (padding_mode == GridSamplerPadding::Border) {
    // clip coordinates to image borders
    coord = clip_coordinates_set_grad(coord, size, &grad_clip);
    *grad_in = (*grad_in) * grad_clip;
  } else if (padding_mode == GridSamplerPadding::Reflection) {
    // reflect coordinates by image borders
    if (align_corners) {
      coord = reflect_coordinates_set_grad(coord, 0, 2*(size - 1), &grad_refl);
    } else {
      coord = reflect_coordinates_set_grad(coord, -1, 2*size - 1, &grad_refl);
    }
    // clip coordinates to image borders
    coord = clip_coordinates_set_grad(coord, size, &grad_clip);
    *grad_in = (*grad_in) * grad_refl * grad_clip;
  }

  coord = safe_downgrade_to_int_range(coord);
  return coord;
}

static __forceinline__ __device__
bool within_bounds_2d(int h, int w, int H, int W) {
  return h >= 0 && h < H && w >= 0 && w < W;
}

static __forceinline__ __device__
bool within_bounds_3d(int d, int h, int w, int D, int H, int W) {
  return d >= 0 && d < D && h >= 0 && h < H && w >= 0 && w < W;
}

template<typename scalar_t>
static __forceinline__ __device__
scalar_t get_value_bounded(
    scalar_t *data, scalar_t x, scalar_t y, int W, int H, int sW, int sH,
    GridSamplerPadding padding_mode,
    bool align_corners) {

  x = compute_coordinates(x, W, padding_mode, align_corners);
  y = compute_coordinates(y, H, padding_mode, align_corners);

  int ix = static_cast<int>(x);
  int iy = static_cast<int>(y);

  if (within_bounds_2d(iy, ix, H, W)) {
    return data[iy * sH + ix * sW];
  }
  return static_cast<scalar_t>(0);
}

template<typename scalar_t, typename index_t>
static __forceinline__ __device__
void safe_add_2d(scalar_t *data, int h, int w,
                 int sH, int sW, int H, int W,
                 scalar_t delta,
                 const index_t NC_offset,
                 const index_t memory_span) {
  if (within_bounds_2d(h, w, H, W)) {
    fastAtomicAdd(data,
                  NC_offset + h * sH + w * sW,
                  memory_span,
                  delta,
                  true);
  }
}

template<typename scalar_t, typename index_t>
static __forceinline__ __device__
void safe_add_3d(scalar_t *data, int d, int h, int w,
                 int sD, int sH, int sW, int D, int H, int W,
                 scalar_t delta,
                 const index_t NC_offset,
                 const index_t memory_span) {
  if (within_bounds_3d(d, h, w, D, H, W)) {
    fastAtomicAdd(data,
                  NC_offset + d * sD + h * sH + w * sW,
                  memory_span,
                  delta,
                  true);
  }
}

template<typename scalar_t, typename index_t>
static __forceinline__ __device__
void add_value_bounded(
    scalar_t* data, scalar_t x, scalar_t y, int W, int H, int sW, int sH,
    scalar_t delta,
    GridSamplerPadding padding_mode,
    bool align_corners,
    const index_t NC_offset,
    const index_t memory_span) {

  x = compute_coordinates(x, W, padding_mode, align_corners);
  y = compute_coordinates(y, H, padding_mode, align_corners);

  int ix = static_cast<int>(x);
  int iy = static_cast<int>(y);

  safe_add_2d(data, iy, ix, sH, sW, H, W, delta, NC_offset, memory_span);
}

// Calculate the differential of the cubic convolution, i.e. `d coeff / d x`
template<typename scalar_t>
static __forceinline__ __device__
void get_cubic_coefficients_grad(
    scalar_t coeffs[4],
    scalar_t t) {

  // Must be the same as forward calculation in
  // aten/src/ATen/native/cuda/UpSample.cuh:get_cubic_upsample_coefficients
  scalar_t A = -0.75;

  scalar_t x;
  x = -1 - t;  // 1 < x = |-1 - tx| < 2
  coeffs[0] = (-3 * A * x - 10 * A ) * x - 8 * A;
  x = -t;     // x = |0 - tx| <= 1
  coeffs[1] = (-3 * (A + 2) * x - 2 * (A + 3)) * x;
  x = 1 - t;  // x = |1 - tx| <= 1
  coeffs[2] = (3 * (A + 2) * x - 2 * (A + 3)) * x;
  x = 2 - t;  // 1 < x = |2 - tx| < 2
  coeffs[3] = (3 * A * x - 10 * A) * x + 8 * A;
}


}}  // namespace at::native
