// glaze/mayhem/glaze_kat.cpp — a self-contained known-answer test for glaze's JSON and BEVE codecs.
//
// glaze's own test suite pulls the openalgz/ut framework and ASIO over the network (CMake
// FetchContent) and is far too large for the hermetic commit build, so this is a curated,
// network-free oracle instead. It round-trips real values through glaze and asserts the EXACT
// recovered values + a few fixed golden encodings. A no-op / exit(0) patch (or any codec regression
// that changes parsing/serialization) FAILS this — it is a genuine functional oracle, not an
// "exits 0" check. test.sh only RUNS this binary; build.sh compiles it with normal flags.
//
// Output protocol: one "PASS <name>" / "FAIL <name> ..." line per case; a final
//   "SUMMARY passed=<P> failed=<F>" line that test.sh parses; exit code = (failed == 0) ? 0 : 1.

#include <array>
#include <cstdint>
#include <iostream>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include <glaze/glaze.hpp>

static int g_passed = 0;
static int g_failed = 0;

static void check(const char* name, bool ok, const std::string& detail = "")
{
   if (ok) {
      std::cout << "PASS " << name << "\n";
      ++g_passed;
   }
   else {
      std::cout << "FAIL " << name << (detail.empty() ? "" : (" - " + detail)) << "\n";
      ++g_failed;
   }
}

struct my_struct
{
   int i = 287;
   double d = 3.14;
   std::string hello = "Hello World";
   std::array<uint64_t, 3> arr = {1, 2, 3};
};

struct nested
{
   int n = 0;
   std::string label{};
   std::vector<double> data{};
};

struct outer
{
   std::string name{};
   std::optional<int> maybe{};
   std::map<std::string, int> dict{};
   std::vector<nested> kids{};
};

int main()
{
   // 1. JSON: known input parses to known field values.
   {
      my_struct obj{};
      // start from non-defaults to prove the parse actually overwrote them
      obj.i = 0;
      obj.d = 0.0;
      obj.hello = "";
      obj.arr = {0, 0, 0};
      const std::string in = R"({"i":287,"d":3.14,"hello":"Hello World","arr":[1,2,3]})";
      auto ec = glz::read_json(obj, in);
      bool ok = !ec && obj.i == 287 && obj.d == 3.14 && obj.hello == "Hello World" &&
                obj.arr[0] == 1 && obj.arr[1] == 2 && obj.arr[2] == 3;
      check("json_read_known_values", ok);
   }

   // 2. JSON: write produces the exact golden string.
   {
      my_struct obj{}; // defaults
      std::string out{};
      auto ec = glz::write_json(obj, out);
      const std::string golden = R"({"i":287,"d":3.14,"hello":"Hello World","arr":[1,2,3]})";
      check("json_write_golden", !ec && out == golden, "got=" + out);
   }

   // 3. JSON round-trip of a nested/optional/map structure preserves all values.
   {
      outer o{};
      o.name = "root";
      o.maybe = 42;
      o.dict = {{"one", 1}, {"two", 2}};
      o.kids = {nested{7, "a", {1.5, 2.5}}, nested{8, "b", {}}};

      std::string buffer{};
      auto wec = glz::write_json(o, buffer);

      outer back{};
      auto rec = glz::read_json(back, buffer);
      bool ok = !wec && !rec && back.name == "root" && back.maybe.has_value() &&
                back.maybe.value() == 42 && back.dict.size() == 2 && back.dict.at("one") == 1 &&
                back.dict.at("two") == 2 && back.kids.size() == 2 && back.kids[0].n == 7 &&
                back.kids[0].label == "a" && back.kids[0].data.size() == 2 &&
                back.kids[0].data[1] == 2.5 && back.kids[1].n == 8;
      check("json_roundtrip_nested", ok);
   }

   // 4. JSON: malformed input is rejected (returns an error, does not silently "succeed").
   {
      my_struct obj{};
      auto ec = glz::read_json(obj, std::string("{not valid json"));
      check("json_reject_malformed", bool(ec));
   }

   // 5. BEVE: binary round-trip recovers exact values.
   {
      my_struct obj{};
      obj.i = -12345;
      obj.d = 2.718281828;
      obj.hello = "binary\tdata\n\"quoted\"";
      obj.arr = {100, 200, 300};

      std::string beve{};
      auto wec = glz::write_beve(obj, beve);

      my_struct back{};
      auto rec = glz::read_beve(back, beve);
      bool ok = !wec && !rec && back.i == -12345 && back.d == obj.d && back.hello == obj.hello &&
                back.arr[0] == 100 && back.arr[1] == 200 && back.arr[2] == 300;
      check("beve_roundtrip_values", ok);
   }

   // 6. BEVE -> JSON conversion of a freshly-written BEVE blob yields the expected JSON.
   {
      my_struct obj{}; // defaults
      std::string beve{};
      auto wec = glz::write_beve(obj, beve);
      std::string json_out{};
      auto cec = glz::beve_to_json(beve, json_out);
      const std::string golden = R"({"i":287,"d":3.14,"hello":"Hello World","arr":[1,2,3]})";
      check("beve_to_json_golden", !wec && !cec && json_out == golden, "got=" + json_out);
   }

   // 7. BEVE: truncated/garbage input is rejected (no crash, returns error).
   {
      my_struct back{};
      std::string garbage = "\x01\x02\x03\xff\xfe";
      auto rec = glz::read_beve(back, garbage);
      check("beve_reject_garbage", bool(rec));
   }

   std::cout << "SUMMARY passed=" << g_passed << " failed=" << g_failed << "\n";
   return g_failed == 0 ? 0 : 1;
}
