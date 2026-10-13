#pragma once
#include <glaze/glaze.hpp>

// Reflected structs whose key hash is one of the in-place readers of decode_hash_with_size that
// dereference key bytes without a bound at the commit under test (see reflect.hpp). The stock
// harness structs all hash with readers that already guard their reads, so none of them reaches
// the short-key over-read.
namespace hash_keys
{
   // front_hash: reads the first 4 bytes of the key
   struct front_hash_keys
   {
      int aaaa{};
      int aaab{};
      int aaba{};
      int bbbb{};
      int aabb{};
   };
   static_assert(glz::hash_info<front_hash_keys>.type == glz::hash_type::front_hash);
   static_assert(glz::hash_info<front_hash_keys>.front_hash_bytes == 4);

   // sized unique_index: reads it[2]
   struct sized_unique_keys
   {
      int xaa{};
      int xab{};
      int xabb{};
   };
   static_assert(glz::hash_info<sized_unique_keys>.type == glz::hash_type::unique_index);
   static_assert(glz::hash_info<sized_unique_keys>.sized_hash);

   // mod4: dereferences the first key byte
   struct mod4_keys
   {
      int x{};
      int yy{};
      int zzz{};
   };
   static_assert(glz::hash_info<mod4_keys>.type == glz::hash_type::mod4);

   // three_element_unique_index with unique_index 0: reads it[0]
   struct three_element_keys
   {
      int dzz{};
      int gzz{};
      int fzz{};
   };
   static_assert(glz::hash_info<three_element_keys>.type == glz::hash_type::three_element_unique_index);

   template <auto Read>
   void read_all(const std::vector<char>& input)
   {
      [[maybe_unused]] auto a = Read.template operator()<front_hash_keys>(input);
      [[maybe_unused]] auto b = Read.template operator()<sized_unique_keys>(input);
      [[maybe_unused]] auto c = Read.template operator()<mod4_keys>(input);
      [[maybe_unused]] auto d = Read.template operator()<three_element_keys>(input);
   }
}
