// json_jmespath_slice: glz::read_jmespath with a runtime JMESPath expression read into ARRAY types.
//
// Upstream's fuzzing/json_jmespath.cpp reads into a struct (Person), and glaze's slice handling
// (detail::handle_slice) only runs when the destination is an array, so that harness never reaches
// the slice code ([start:end:step], negative indices and steps). This one keeps the same input
// layout and drives the same public entry point, read_jmespath(expression, value, buffer), with
// std::vector destinations, as a caller extracting a sub-array from untrusted JSON would.
//
// Input: byte 0 selects null_terminated; bytes 1-2 are the expression length (little endian);
// then the expression, then the JSON document.
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <glaze/glaze.hpp>
#include <glaze/json/jmespath.hpp>
#include <string>
#include <string_view>
#include <vector>

namespace
{
   template <bool null_terminated, class T>
   void read_into(std::string_view path_in, std::string_view buffer_in)
   {
      // Separate, exactly sized allocations so ASan catches reads past either buffer.
      std::vector<char> path(path_in.size() + +null_terminated);
      std::copy(path_in.begin(), path_in.end(), path.begin());
      std::vector<char> buffer(buffer_in.size() + +null_terminated);
      std::copy(buffer_in.begin(), buffer_in.end(), buffer.begin());

      T value{};
      static constexpr glz::opts options{.null_terminated = null_terminated};
      glz::jmespath_expression expression{std::string_view(path.data(), path.size() - +null_terminated)};
      [[maybe_unused]] auto result = glz::read_jmespath<options>(
         expression, value, std::string_view(buffer.data(), buffer.size() - +null_terminated));
   }

   template <bool null_terminated>
   void impl(std::string_view path, std::string_view buffer)
   {
      read_into<null_terminated, std::vector<int>>(path, buffer);
      read_into<null_terminated, std::vector<std::string>>(path, buffer);
   }
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* Data, size_t Size)
{
   constexpr size_t bytes_used_for_nullterm = 1;
   constexpr size_t bytes_used_for_size = 2;
   if (Size < bytes_used_for_size + bytes_used_for_nullterm) return -1;

   const bool null_terminated = Data[0];
   Data += bytes_used_for_nullterm;
   Size -= bytes_used_for_nullterm;

   const size_t pathsize = std::min(Size - bytes_used_for_size, size_t{Data[0]} + (size_t{Data[1]} << 8));
   Data += bytes_used_for_size;
   Size -= bytes_used_for_size;

   const std::string_view path{(const char*)Data, pathsize};
   const std::string_view buffer{(const char*)Data + pathsize, Size - pathsize};

   if (null_terminated) {
      impl<true>(path, buffer);
   }
   else {
      impl<false>(path, buffer);
   }
   return 0;
}
