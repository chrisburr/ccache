// Copyright (C) 2026 Joel Rosdahl and other contributors
//
// See doc/authors.adoc for a complete list of contributors.
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 3 of the License, or (at your option)
// any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along with
// this program; if not, write to the Free Software Foundation, Inc., 51
// Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

#include <ccache/compiler/gcc.hpp>

#include <doctest/doctest.h>

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace fs = std::filesystem;

TEST_SUITE_BEGIN("compiler::gcc");

TEST_CASE("compiler::read_json_string")
{
  std::string value;
  size_t pos = 2;
  REQUIRE(compiler::read_json_string(R"(x "a\"b\\c\/\t" y)", pos, value));
  CHECK(value == "a\"b\\c/\t");
  CHECK(pos == 15);

  pos = 0;
  CHECK(!compiler::read_json_string(R"("abc)", pos, value));
  CHECK(!compiler::read_json_string(R"(abc")", pos, value));
  CHECK(!compiler::read_json_string(R"("\u0001")", pos, value));
  CHECK(!compiler::read_json_string("", pos, value));
  CHECK(pos == 0);
}

TEST_CASE("compiler::with_spec_suffix")
{
  CHECK(compiler::with_spec_suffix("foo.obj", ".o") == "foo.o");
  CHECK(compiler::with_spec_suffix("foo", ".o") == "foo.o");
  CHECK(compiler::with_spec_suffix("foo.o.tmp", ".o") == "foo.o.o");
  CHECK(compiler::with_spec_suffix(".o", ".ddi") == ".ddi");
  CHECK(compiler::with_spec_suffix("dir.x/foo", ".o") == "dir.x/foo.o");
  CHECK(compiler::with_spec_suffix("dir/.hidden", ".o") == "dir/.o");
  CHECK(compiler::with_spec_suffix("/abs/dir/foo.obj", ".ddi")
        == "/abs/dir/foo.ddi");
#ifdef _WIN32
  CHECK(compiler::with_spec_suffix("dir.x\\foo", ".o") == "dir.x\\foo.o");
  CHECK(compiler::with_spec_suffix("dir\\foo.obj", ".o") == "dir\\foo.o");
#endif
}

TEST_CASE("compiler::is_module_mapper_file")
{
  CHECK(compiler::is_module_mapper_file("foo.map"));
  CHECK(compiler::is_module_mapper_file("/abs/foo.o.modmap"));
  CHECK(compiler::is_module_mapper_file("C:/foo.map"));
  CHECK(compiler::is_module_mapper_file("host:0"));
  CHECK(!compiler::is_module_mapper_file(""));
  CHECK(!compiler::is_module_mapper_file("|mapper-program"));
  CHECK(!compiler::is_module_mapper_file("<>"));
  CHECK(!compiler::is_module_mapper_file("<in>out"));
  CHECK(!compiler::is_module_mapper_file("=socket"));
  CHECK(!compiler::is_module_mapper_file("host:1234"));
  CHECK(!compiler::is_module_mapper_file("foo.map?ident"));
}

TEST_CASE("compiler::parse_module_mapper")
{
  SUBCASE("no root")
  {
    const auto mapper = compiler::parse_module_mapper("foo cmi/foo.gcm\n");
    REQUIRE(mapper);
    const auto entries = mapper->cmi_paths();
    CHECK(entries.size() == 1);
    CHECK(entries.at("foo") == fs::path("cmi/foo.gcm"));
  }

  SUBCASE("root, partitions and header units")
  {
    const auto mapper = compiler::parse_module_mapper(
      "$root /build\n"
      "\n"
      "  foo CMakeFiles/foo.dir/foo.gcm\n"
      "foo:part\t\tCMakeFiles/foo.dir/foo-part.gcm\n"
      "./bar.h /abs/bar.gcm\n");
    REQUIRE(mapper);
    const auto entries = mapper->cmi_paths();
    CHECK(entries.size() == 3);
    CHECK(entries.at("foo") == fs::path("/build/CMakeFiles/foo.dir/foo.gcm"));
    CHECK(entries.at("foo:part")
          == fs::path("/build/CMakeFiles/foo.dir/foo-part.gcm"));
    CHECK(entries.at("./bar.h") == fs::path("/abs/bar.gcm"));
    CHECK(mapper->root == "/build");
    CHECK(mapper->entries.at("foo") == "CMakeFiles/foo.dir/foo.gcm");
  }

  SUBCASE("the CMI path is the rest of the line")
  {
    const auto mapper =
      compiler::parse_module_mapper("foo a b.gcm \nbar \"c.gcm\"\n");
    REQUIRE(mapper);
    const auto entries = mapper->cmi_paths();
    CHECK(entries.at("foo") == fs::path("a b.gcm "));
    CHECK(entries.at("bar") == fs::path("\"c.gcm\""));
  }

  SUBCASE("first root and first mapping win")
  {
    const auto mapper = compiler::parse_module_mapper(
      "$root first\n$root second\nfoo a.gcm\nfoo b.gcm\n");
    REQUIRE(mapper);
    const auto entries = mapper->cmi_paths();
    CHECK(entries.at("foo") == fs::path("first/a.gcm"));
  }

  SUBCASE("last line without newline is ignored")
  {
    const auto mapper = compiler::parse_module_mapper("foo a.gcm\nbar b.gcm");
    REQUIRE(mapper);
    const auto entries = mapper->cmi_paths();
    CHECK(entries.size() == 1);
    CHECK(entries.contains("foo"));
  }

  SUBCASE("errors")
  {
    CHECK(!compiler::parse_module_mapper("foo\n"));
    CHECK(!compiler::parse_module_mapper("$other dir\n"));
  }
}

TEST_CASE("compiler::parse_p1689")
{
  SUBCASE("written by GCC")
  {
    const auto modules = compiler::parse_p1689(R"({
"rules": [
{
"primary-output": "out/geom.cpp.o",
"provides": [
{
"logical-name": "geom:part",
"is-interface": true
}
],
"requires": [
{
"logical-name": "other"
},
{
"logical-name": "./header.h"
}
]
}
],
"version": 0,
"revision": 0
}
)");
    REQUIRE(modules);
    CHECK(modules->provided == std::vector<std::string>{"geom:part"});
    CHECK(modules->required == std::vector<std::string>{"other", "./header.h"});
  }

  SUBCASE("nothing provided")
  {
    const auto modules = compiler::parse_p1689(
      R"({"rules": [{"primary-output": "a.o", "requires": []}],)"
      R"( "version": 0, "revision": 0})");
    REQUIRE(modules);
    CHECK(modules->provided.empty());
    CHECK(modules->required.empty());
  }

  SUBCASE("escapes and other values")
  {
    const auto modules = compiler::parse_p1689(
      R"({"x": [null, -1.5e3, false, {"y": "\"\\\/"}],)"
      R"( "rules": [{"provides": [{"logical-name": "a\"b"}]}]})");
    REQUIRE(modules);
    CHECK(modules->provided == std::vector<std::string>{"a\"b"});
  }

  SUBCASE("invalid")
  {
    CHECK(!compiler::parse_p1689(""));
    CHECK(!compiler::parse_p1689("{"));
    CHECK(!compiler::parse_p1689(R"({"rules": [})"));
    CHECK(!compiler::parse_p1689(R"({"rules": []} trailing)"));
    CHECK(!compiler::parse_p1689(
      R"({"rules": [{"provides": [{"logical-name": 1}]}]})"));
  }
}

TEST_SUITE_END();
