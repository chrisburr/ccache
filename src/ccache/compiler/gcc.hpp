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

#pragma once

#include <ccache/hash.hpp>

#include <tl/expected.hpp>

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace compiler {

// Decode the JSON string starting at `pos` in `text` and advance `pos` past
// it. Returns false if there is no valid string at `pos` or if it contains a
// \uXXXX escape, which GCC only writes for control characters.
bool read_json_string(std::string_view text, size_t& pos, std::string& value);

// Return `path` with the suffix of its file name replaced by `suffix` like
// GCC's driver does with "%.<suffix>" in specs: from the last period of the
// file name, even a leading one, or appended if there is none.
std::string with_spec_suffix(std::string_view path, std::string_view suffix);

// Module name to compiled module interface (CMI) path.
using ModuleMapperEntries =
  std::unordered_map<std::string, std::filesystem::path>;

struct ModuleMapper
{
  // Directory that relative CMI paths are relative to, or empty for the
  // working directory.
  std::string root;

  // Module name to CMI path as written in the module mapper file. GCC records
  // these paths, not the paths with the root directory, in a written CMI for
  // the modules it imports.
  std::unordered_map<std::string, std::string> entries;

  // Return the CMI paths with the root directory applied.
  ModuleMapperEntries cmi_paths() const;
};

// Return whether the value of -fmodule-mapper= names a module mapper file, as
// opposed to a mapper program ("|prog"), a socket ("<>", "=sock",
// "host:port") or a section of a file ("file?ident").
bool is_module_mapper_file(std::string_view mapper);

// Parse the content of a GCC module mapper file like GCC does. Each line is
// either "$root <dir>" or "<module name> <CMI path>", where the CMI path is the
// rest of the line. The first root and the first mapping of a module win. A
// last line without a newline is ignored.
tl::expected<ModuleMapper, std::string>
parse_module_mapper(std::string_view content);

struct P1689Modules
{
  // Logical names of the modules provided by the compiled unit.
  std::vector<std::string> provided;

  // Logical names of the modules and header units imported by the compiled
  // unit.
  std::vector<std::string> required;
};

// Parse a P1689 file written by GCC with -fdeps-format=p1689r5. Returns
// std::nullopt if `content` is not valid JSON in that format.
std::optional<P1689Modules> parse_p1689(std::string_view content);

// Return the digest of a GCC CMI without its README section, or std::nullopt if
// `data` is not laid out like a CMI. The README section contains the working
// directory, source path and build time, and GCC does not consider it when
// checking whether a CMI matches.
std::optional<Hash::Digest> module_cmi_digest(std::span<const uint8_t> data);

} // namespace compiler
