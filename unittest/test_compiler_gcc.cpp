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
#include <ccache/util/format.hpp>

#include <doctest/doctest.h>

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace fs = std::filesystem;

namespace {

// Create a CMI-like 32-bit little-endian ELF file with the given sections plus
// a string table.
std::vector<uint8_t>
make_cmi(const std::vector<std::pair<std::string, std::string>>& sections)
{
  std::string strtab(1, '\0');
  std::vector<uint32_t> name_offsets;
  for (const auto& [name, contents] : sections) {
    name_offsets.push_back(static_cast<uint32_t>(strtab.size()));
    strtab += name;
    strtab += '\0';
  }
  const auto strtab_name = static_cast<uint32_t>(strtab.size());
  strtab += ".strtab";
  strtab += '\0';

  std::vector<uint8_t> data(52, 0);
  const auto put = [&](size_t offset, uint32_t value, size_t size) {
    for (size_t i = 0; i < size; ++i) {
      data[offset + i] = static_cast<uint8_t>(value >> (8 * i));
    }
  };

  std::vector<std::pair<uint32_t, uint32_t>> extents; // offset, size
  extents.emplace_back(0, 0);                         // Null section
  for (const auto& [name, contents] : sections) {
    extents.emplace_back(static_cast<uint32_t>(data.size()),
                         static_cast<uint32_t>(contents.size()));
    data.insert(data.end(), contents.begin(), contents.end());
  }
  extents.emplace_back(static_cast<uint32_t>(data.size()),
                       static_cast<uint32_t>(strtab.size()));
  data.insert(data.end(), strtab.begin(), strtab.end());

  const auto shoff = static_cast<uint32_t>(data.size());
  data.resize(data.size() + extents.size() * 40, 0);
  for (size_t i = 0; i < extents.size(); ++i) {
    const size_t base = shoff + i * 40;
    if (i > 0 && i <= sections.size()) {
      put(base, name_offsets[i - 1], 4);
      put(base + 4, 1, 4); // SHT_PROGBITS
    } else if (i == extents.size() - 1) {
      put(base, strtab_name, 4);
      put(base + 4, 3, 4); // SHT_STRTAB
    }
    put(base + 16, extents[i].first, 4);
    put(base + 20, extents[i].second, 4);
  }

  data[0] = 0x7f;
  data[1] = 'E';
  data[2] = 'L';
  data[3] = 'F';
  data[4] = 1; // ELFCLASS32
  data[5] = 1; // ELFDATA2LSB
  data[6] = 1; // EV_CURRENT
  put(32, shoff, 4);
  put(40, 52, 2);
  put(46, 40, 2);
  put(48, static_cast<uint32_t>(extents.size()), 2);
  put(50, static_cast<uint32_t>(extents.size() - 1), 2);
  return data;
}

std::string
readme(std::string_view module, std::string_view source, std::string_view cwd)
{
  std::string result = "GNU C++ primary interface";
  result += '\0';
  for (const auto& line : {FMT("module: {}", module),
                           FMT("source: {}", source),
                           FMT("cwd: {}", cwd)}) {
    result += line;
    result += '\0';
  }
  return result;
}

} // namespace

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

TEST_CASE("compiler::module_cmi_digest")
{
  const auto cmi = make_cmi({
    {".gnu.c++.README", readme("geom", "geom.cpp", "/a")},
    {".gnu.c++.cfg", "config"},
  });

  SUBCASE("README section is ignored")
  {
    const auto other = make_cmi({
      {".gnu.c++.README", readme("geom", "geom.cpp", "/longer/path")},
      {".gnu.c++.cfg", "config"},
    });
    REQUIRE(compiler::module_cmi_digest(cmi));
    CHECK(compiler::module_cmi_digest(cmi)
          == compiler::module_cmi_digest(other));
  }

  SUBCASE("other sections are not ignored")
  {
    const auto other = make_cmi({
      {".gnu.c++.README", readme("geom", "geom.cpp", "/a")},
      {".gnu.c++.cfg", "CONFIG"},
    });
    CHECK(compiler::module_cmi_digest(cmi)
          != compiler::module_cmi_digest(other));
  }

  SUBCASE("malformed data")
  {
    CHECK(!compiler::module_cmi_digest({}));
    CHECK(!compiler::module_cmi_digest(
      std::span<const uint8_t>(cmi.data(), cmi.size() - 1)));

    auto bad_offset = cmi;
    bad_offset[cmi.size() - 2 * 40 + 16] = 0xff; // .gnu.c++.cfg offset
    bad_offset[cmi.size() - 2 * 40 + 19] = 0xff;
    CHECK(!compiler::module_cmi_digest(bad_offset));

    auto not_elf = cmi;
    not_elf[1] = 'X';
    CHECK(!compiler::module_cmi_digest(not_elf));

    auto elf64 = cmi;
    elf64[4] = 2;
    CHECK(!compiler::module_cmi_digest(elf64));
  }
}

TEST_CASE("compiler::parse_module_depfile")
{
  compiler::ModuleMapperEntries entries{
    {"geom",       "cmi/geom.gcm"     },
    {"geom:part",  "cmi/geom-part.gcm"},
    {"./header.h", "cmi/header.gcm"   },
  };
  const fs::path cwd = "/build";

  SUBCASE("module interface unit")
  {
    const auto depfile = compiler::parse_module_depfile(
      "geom.o cmi/geom.gcm: geom.cpp geom.map stdc-predef.h\n"
      "geom.c++-module: cmi/geom.gcm\n"
      ".PHONY: geom.c++-module\n"
      "cmi/geom.gcm:| geom.o\n",
      entries,
      cwd,
      "geom.cpp");
    REQUIRE(depfile);
    CHECK(depfile->prerequisites
          == std::vector<std::string>{"geom.cpp", "geom.map", "stdc-predef.h"});
    CHECK(depfile->provided_module == "geom");
  }

  SUBCASE("CRLF line endings")
  {
    const auto depfile = compiler::parse_module_depfile(
      "geom.o cmi/geom.gcm: geom.cpp \\\r\n a.h \\\r\n b.h\r\n"
      "geom.c++-module: cmi/geom.gcm\r\n"
      ".PHONY: geom.c++-module\r\n"
      "cmi/geom.gcm:| geom.o\r\n",
      entries,
      cwd,
      "geom.cpp");
    REQUIRE(depfile);
    CHECK(depfile->prerequisites
          == std::vector<std::string>{"geom.cpp", "a.h", "b.h"});
    CHECK(depfile->provided_module == "geom");
  }

  SUBCASE("module partition")
  {
    const auto depfile = compiler::parse_module_depfile(
      "part.o cmi/geom-part.gcm: part.cpp\n"
      "geom:part.c++-module: cmi/geom-part.gcm\n"
      ".PHONY: geom:part.c++-module\n"
      "cmi/geom-part.gcm:| part.o\n",
      entries,
      cwd,
      "part.cpp");
    REQUIRE(depfile);
    CHECK(depfile->prerequisites == std::vector<std::string>{"part.cpp"});
    CHECK(depfile->provided_module == "geom:part");
  }

  SUBCASE("source file named like a module")
  {
    const auto depfile = compiler::parse_module_depfile(
      "geom.o cmi/geom.gcm: geom.c++m hdr.h\n"
      "geom.c++-module: cmi/geom.gcm\n"
      ".PHONY: geom.c++-module\n"
      "cmi/geom.gcm:| geom.o\n",
      entries,
      cwd,
      "geom.c++m");
    REQUIRE(depfile);
    CHECK(depfile->prerequisites
          == std::vector<std::string>{"geom.c++m", "hdr.h"});
  }

  SUBCASE("source file named like a module without other prerequisites")
  {
    const auto depfile = compiler::parse_module_depfile(
      "geom.o: geom.c++m\n", entries, cwd, "geom.c++m");
    REQUIRE(depfile);
    CHECK(depfile->prerequisites == std::vector<std::string>{"geom.c++m"});
  }

  SUBCASE("importing units")
  {
    const auto depfile = compiler::parse_module_depfile(
      "main.o: main.cpp \\\n"
      " " + (cwd / "cmi/geom.gcm").string() + " cmi/geom-part.gcm"
      " cmi/header.gcm\n"
      "main.o: geom.c++-module geom:part.c++-module ./header.h.c++-module\n"
      "CXX_IMPORTS += geom.c++-module geom:part.c++-module"
      " ./header.h.c++-module\n",
      entries,
      cwd,
      "main.cpp");
    REQUIRE(depfile);
    CHECK(depfile->prerequisites
          == std::vector<std::string>{"main.cpp",
                                      (cwd / "cmi/geom.gcm").string(),
                                      "cmi/geom-part.gcm",
                                      "cmi/header.gcm"});
    CHECK(!depfile->provided_module);
  }

  SUBCASE("CMake")
  {
    const auto depfile = compiler::parse_module_depfile(
      "CMakeFiles/app.dir/main.cpp.o: \\\n"
      " /src/main.cpp \\\n"
      " CMakeFiles/app.dir/main.cpp.o.modmap /usr/include/stdc-predef.h \\\n"
      " cmi/geom.gcm\n",
      entries,
      cwd,
      "/src/main.cpp");
    REQUIRE(depfile);
    CHECK(depfile->prerequisites
          == std::vector<std::string>{"/src/main.cpp",
                                      "CMakeFiles/app.dir/main.cpp.o.modmap",
                                      "/usr/include/stdc-predef.h",
                                      "cmi/geom.gcm"});
  }

  SUBCASE("escaped spaces")
  {
    const auto depfile = compiler::parse_module_depfile(
      "main.o: main.cpp my\\ header.h\n", entries, cwd, "main.cpp");
    REQUIRE(depfile);
    CHECK(depfile->prerequisites
          == std::vector<std::string>{"main.cpp", "my header.h"});
  }

  SUBCASE("imported CMI not listed")
  {
    // Before GCC 14, imported modules are only listed by name, also in rules
    // with several targets.
    CHECK(
      !compiler::parse_module_depfile("main.o: main.cpp\n"
                                      "main.o: geom.c++m\n"
                                      "CXX_IMPORTS += geom.c++m\n",
                                      entries,
                                      cwd,
                                      "main.cpp"));
    CHECK(
      !compiler::parse_module_depfile("a.o cmi/a.gcm: a.cpp geom.c++m\n"
                                      "a.c++m: cmi/a.gcm\n",
                                      entries,
                                      cwd,
                                      "a.cpp"));
  }
}

TEST_CASE("compiler::is_module_depfile_line")
{
  CHECK(compiler::is_module_depfile_line("geom.c++-module: cmi/geom.gcm"));
  CHECK(compiler::is_module_depfile_line("geom:part.c++m: cmi/geom-part.gcm"));
  CHECK(compiler::is_module_depfile_line(".PHONY: geom:part.c++-module"));
  CHECK(compiler::is_module_depfile_line("cmi/geom.gcm:| geom.o"));
  CHECK(compiler::is_module_depfile_line("main.o: geom:part.c++-module"));
  CHECK(compiler::is_module_depfile_line("CXX_IMPORTS += geom.c++-module"));
  CHECK(!compiler::is_module_depfile_line("geom.o cmi/geom.gcm: geom.cpp"));
  CHECK(!compiler::is_module_depfile_line("main.o: main.cpp \\\n /a/b.h"));
  CHECK(!compiler::is_module_depfile_line("geom.o: geom.c++m geom.h"));
  CHECK(compiler::is_module_depfile_line(
    "./h.h.c++-module /h.h.c++-header-unit: cmi/h.gcm"));
}

TEST_CASE("compiler::rewrite_module_depfile_line")
{
  const auto rewrite = [](std::string_view line) {
    return compiler::rewrite_module_depfile_line(
      line, [](const std::string& path) { return "<" + path + ">"; });
  };

  CHECK(rewrite("geom:part.c++-module: /b/cmi/geom-part.gcm")
        == "geom:part.c++-module: </b/cmi/geom-part.gcm>");
  CHECK(rewrite("geom.c++-module: \\\n /b/cmi/my\\ geom.gcm")
        == "geom.c++-module: </b/cmi/my\\ geom.gcm>");
  CHECK(rewrite("/b/cmi/geom.gcm:| /b/geom.o")
        == "</b/cmi/geom.gcm>:| /b/geom.o");
  CHECK(rewrite(".PHONY: geom.c++-module") == ".PHONY: geom.c++-module");
  CHECK(rewrite("main.o: geom.c++-module") == "main.o: geom.c++-module");
  CHECK(rewrite("b.o /b/cmi/b.gcm: geom.c++-module")
        == "b.o </b/cmi/b.gcm>: geom.c++-module");
  CHECK(rewrite("./h.h.c++-module /h.h.c++-header-unit: /b/h.gcm")
        == "./h.h.c++-module /h.h.c++-header-unit: </b/h.gcm>");
  CHECK(rewrite("CXX_IMPORTS += geom.c++-module")
        == "CXX_IMPORTS += geom.c++-module");
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
