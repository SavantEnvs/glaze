#pragma once
#include <glaze/glaze.hpp>

// An enum whose key hash is a sized unique_index: decode_hash<JSON, ..., unique_index> reads
// it[unique_index] of the quoted enum string, which a truncated payload puts past the end of the
// buffer at the commit under test (reflect.hpp). The stock harness struct has no enum member, so
// none of the stock targets reaches that read.
namespace enum_keys
{
   enum class fuzz_case {
      aaaa,
      aaa,
      aab,
      aac,
   };

   struct container
   {
      fuzz_case enum_field{};
   };
}

template <>
struct glz::meta<enum_keys::fuzz_case>
{
   using enum enum_keys::fuzz_case;
   static constexpr auto value = glz::enumerate("aaaa", aaaa, "aaa", aaa, "aab", aab, "aac", aac);
};

static_assert(glz::hash_info<enum_keys::fuzz_case>.type == glz::hash_type::unique_index);
static_assert(glz::hash_info<enum_keys::fuzz_case>.sized_hash);
