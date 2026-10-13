#pragma once
#include <glaze/glaze.hpp>

// A reflected struct whose key hash is the sized unique_index reader of decode_hash_with_size, which
// dereferences it[unique_index] without bounding it by the key length at the commit under test (see
// reflect.hpp). The stock harness structs all hash with readers that already guard their reads, so
// none of them reaches the short-key over-read. (A front_hash struct would over-read too, but it
// would also crash on every short key before this one is read, so it is left out.)
namespace hash_keys
{
   // sized unique_index: reads it[2] of a key whose length may be 1 or 2
   struct sized_unique_keys
   {
      int xaa{};
      int xab{};
      int xabb{};
   };
   static_assert(glz::hash_info<sized_unique_keys>.type == glz::hash_type::unique_index);
   static_assert(glz::hash_info<sized_unique_keys>.sized_hash);
   static_assert(glz::hash_info<sized_unique_keys>.unique_index == 2);
   static_assert(glz::hash_info<sized_unique_keys>.min_length == 3);
}
