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

#include "gcc.hpp"

#include <ccache/util/format.hpp>

#include <algorithm>
#include <functional>

namespace fs = std::filesystem;

namespace compiler {

namespace {

const std::string_view k_readme_section = ".gnu.c++.README";

// Call `visitor` with the name, type and contents of each section of a GCC CMI.
// Returns false if `data` is not laid out like a CMI.
bool
for_each_cmi_section(
  std::span<const uint8_t> data,
  const std::function<void(std::string_view name,
                           uint32_t type,
                           std::span<const uint8_t> contents)>& visitor)
{
  // GCC writes CMIs as 32-bit ELF in host byte order (see class elf in
  // gcc/cp/module.cc).
  constexpr uint64_t header_size = 52;
  constexpr uint64_t section_size = 40;
  constexpr uint64_t shn_xindex = 0xffff;

  if (data.size() < header_size || data[0] != 0x7f || data[1] != 'E'
      || data[2] != 'L' || data[3] != 'F' || data[4] != 1 /* ELFCLASS32 */
      || (data[5] != 1 && data[5] != 2)) {
    return false;
  }
  const bool little_endian = data[5] == 1;
  const auto read_uint = [&](uint64_t offset, size_t size) -> uint64_t {
    uint64_t value = 0;
    for (size_t i = 0; i < size; ++i) {
      const uint64_t byte = data[offset + (little_endian ? size - 1 - i : i)];
      value = (value << 8) | byte;
    }
    return value;
  };

  const uint64_t shoff = read_uint(32, 4);
  const uint64_t shentsize = read_uint(46, 2);
  uint64_t shnum = read_uint(48, 2);
  uint64_t shstrndx = read_uint(50, 2);
  if (shentsize != section_size || shoff + section_size > data.size()) {
    return false;
  }
  const auto section_field = [&](uint64_t index, uint64_t field) {
    return read_uint(shoff + index * section_size + field, 4);
  };
  if (shnum == shn_xindex) {
    shnum = section_field(0, 20);
  }
  if (shstrndx == shn_xindex) {
    shstrndx = section_field(0, 24);
  }
  if (shnum == 0 || shstrndx >= shnum
      || shoff + shnum * section_size > data.size()) {
    return false;
  }

  const auto contents =
    [&](uint64_t index) -> std::optional<std::span<const uint8_t>> {
    const uint64_t offset = section_field(index, 16);
    const uint64_t size = section_field(index, 20);
    if (offset > data.size() || size > data.size() - offset) {
      return std::nullopt;
    }
    return data.subspan(offset, size);
  };

  const auto strtab = contents(shstrndx);
  if (!strtab) {
    return false;
  }
  const auto names = util::to_string_view(*strtab);

  std::vector<std::tuple<std::string_view, uint32_t, std::span<const uint8_t>>>
    sections;
  for (uint64_t i = 0; i < shnum; ++i) {
    const uint64_t name_offset = section_field(i, 0);
    const auto section = contents(i);
    if (!section || name_offset >= names.size()) {
      return false;
    }
    const auto name_end = names.find('\0', name_offset);
    if (name_end == std::string_view::npos) {
      return false;
    }
    sections.emplace_back(names.substr(name_offset, name_end - name_offset),
                          static_cast<uint32_t>(section_field(i, 4)),
                          *section);
  }

  for (const auto& [name, type, section] : sections) {
    visitor(name, type, section);
  }
  return true;
}

} // namespace

bool
read_json_string(std::string_view text, size_t& pos, std::string& value)
{
  if (pos >= text.size() || text[pos] != '"') {
    return false;
  }
  size_t i = pos + 1;
  value.clear();
  while (i < text.size() && text[i] != '"') {
    char c = text[i++];
    if (c == '\\') {
      if (i >= text.size()) {
        return false;
      }
      c = text[i++];
      switch (c) {
      case '"':
      case '\\':
      case '/':
        break;
      case 'b':
        c = '\b';
        break;
      case 'f':
        c = '\f';
        break;
      case 'n':
        c = '\n';
        break;
      case 'r':
        c = '\r';
        break;
      case 't':
        c = '\t';
        break;
      default:
        return false;
      }
    }
    value += c;
  }
  if (i >= text.size()) {
    return false;
  }
  pos = i + 1;
  return true;
}

std::string
with_spec_suffix(std::string_view path, std::string_view suffix)
{
  // Like give_switch in gcc/gcc.cc.
#ifdef _WIN32
  const size_t name_pos = path.find_last_of("/\\");
#else
  const size_t name_pos = path.rfind('/');
#endif
  const size_t dot_pos = path.rfind('.');
  std::string result(
    dot_pos != std::string_view::npos
        && (name_pos == std::string_view::npos || dot_pos > name_pos)
      ? path.substr(0, dot_pos)
      : path);
  result += suffix;
  return result;
}

bool
is_module_mapper_file(std::string_view mapper)
{
  // See module_client::open_module_client in gcc/cp/mapper-client.cc.
  if (mapper.empty() || mapper.find('?') != std::string_view::npos
      || mapper[0] == '<' || mapper[0] == '=' || mapper[0] == '|') {
    return false;
  }
  const auto colon = mapper.rfind(':');
  if (colon != std::string_view::npos) {
    const auto port = mapper.substr(colon + 1);
    if (!port.empty()
        && std::all_of(
          port.begin(), port.end(), [](char c) { return c >= '0' && c <= '9'; })
        && port.find_first_not_of('0') != std::string_view::npos) {
      return false;
    }
  }
  return true;
}

ModuleMapperEntries
ModuleMapper::cmi_paths() const
{
  ModuleMapperEntries result;
  for (const auto& [name, cmi] : entries) {
    const fs::path path(cmi);
    // Like maybe_add_cmi_prefix in gcc/cp/module.cc.
    result.emplace(
      name, root.empty() || path.is_absolute() ? path : fs::path(root) / path);
  }
  return result;
}

tl::expected<ModuleMapper, std::string>
parse_module_mapper(std::string_view content)
{
  // See module_resolver::read_tuple_file in c++tools/resolver.cc.
  const auto is_blank = [](char c) { return c == ' ' || c == '\t'; };

  ModuleMapper mapper;
  std::string_view rest = content;
  for (size_t eol = rest.find('\n'); eol != std::string_view::npos;
       eol = rest.find('\n')) {
    const auto line = rest.substr(0, eol);
    rest.remove_prefix(eol + 1);

    size_t begin = 0;
    while (begin < line.size() && is_blank(line[begin])) {
      ++begin;
    }
    size_t end = begin;
    while (end < line.size() && !is_blank(line[end])) {
      ++end;
    }
    if (begin == end) {
      continue;
    }
    const std::string module(line.substr(begin, end - begin));
    while (end < line.size() && is_blank(line[end])) {
      ++end;
    }
    const std::string file(line.substr(end));

    if (module == "$root") {
      if (mapper.root.empty()) {
        mapper.root = file;
      }
    } else if (module[0] == '$') {
      return tl::unexpected(FMT("unsupported directive: {}", module));
    } else if (file.empty()) {
      // GCC derives the CMI name from the module name.
      return tl::unexpected(FMT("no CMI path for module {}", module));
    } else {
      mapper.entries.emplace(module, file);
    }
  }
  return mapper;
}

namespace {

// A minimal JSON reader for P1689 files.
class JsonReader
{
public:
  explicit JsonReader(std::string_view text)
    : m_text(text)
  {
  }

  // Call `on_member` for each member of an object, which must consume the
  // member value. Returns false on a syntax error.
  bool
  read_object(const std::function<bool(const std::string& key)>& on_member)
  {
    if (!consume('{')) {
      return false;
    }
    if (consume('}')) {
      return true;
    }
    do {
      std::string key;
      if (!read_string(key) || !consume(':') || !on_member(key)) {
        return false;
      }
    } while (consume(','));
    return consume('}');
  }

  // Call `on_element` for each element of an array, which must consume the
  // element. Returns false on a syntax error.
  bool
  read_array(const std::function<bool()>& on_element)
  {
    if (!consume('[')) {
      return false;
    }
    if (consume(']')) {
      return true;
    }
    do {
      if (!on_element()) {
        return false;
      }
    } while (consume(','));
    return consume(']');
  }

  bool
  read_string(std::string& value)
  {
    skip_whitespace();
    return read_json_string(m_text, m_pos, value);
  }

  bool
  skip_value()
  {
    skip_whitespace();
    if (m_pos >= m_text.size()) {
      return false;
    }
    switch (m_text[m_pos]) {
    case '{':
      return read_object([&](const std::string&) { return skip_value(); });
    case '[':
      return read_array([&] { return skip_value(); });
    case '"': {
      std::string ignored;
      return read_string(ignored);
    }
    default: {
      // Number, true, false or null.
      const size_t begin = m_pos;
      while (m_pos < m_text.size()
             && std::string_view("+-.0123456789Eaeflnrstu").find(m_text[m_pos])
                  != std::string_view::npos) {
        ++m_pos;
      }
      return m_pos > begin;
    }
    }
  }

  bool
  at_end()
  {
    skip_whitespace();
    return m_pos == m_text.size();
  }

private:
  std::string_view m_text;
  size_t m_pos = 0;

  void
  skip_whitespace()
  {
    while (m_pos < m_text.size()
           && std::string_view(" \t\r\n").find(m_text[m_pos])
                != std::string_view::npos) {
      ++m_pos;
    }
  }

  bool
  consume(char c)
  {
    skip_whitespace();
    if (m_pos < m_text.size() && m_text[m_pos] == c) {
      ++m_pos;
      return true;
    }
    return false;
  }
};

} // namespace

std::optional<P1689Modules>
parse_p1689(std::string_view content)
{
  P1689Modules modules;
  JsonReader reader(content);
  const bool ok = reader.read_object([&](const std::string& key) {
    if (key != "rules") {
      return reader.skip_value();
    }
    return reader.read_array([&] {
      return reader.read_object([&](const std::string& rule_key) {
        std::vector<std::string>* names = nullptr;
        if (rule_key == "provides") {
          names = &modules.provided;
        } else if (rule_key == "requires") {
          names = &modules.required;
        } else {
          return reader.skip_value();
        }
        return reader.read_array([&] {
          return reader.read_object([&](const std::string& module_key) {
            if (module_key != "logical-name") {
              return reader.skip_value();
            }
            std::string name;
            if (!reader.read_string(name)) {
              return false;
            }
            names->push_back(std::move(name));
            return true;
          });
        });
      });
    });
  });
  if (!ok || !reader.at_end()) {
    return std::nullopt;
  }
  return modules;
}

std::optional<Hash::Digest>
module_cmi_digest(std::span<const uint8_t> data)
{
  Hash hash;
  const bool ok = for_each_cmi_section(
    data, [&](std::string_view name, uint32_t type, auto contents) {
      hash.hash_delimiter("section");
      hash.hash(name);
      hash.hash(static_cast<int64_t>(type));
      if (name != k_readme_section) {
        hash.hash(contents);
      }
    });
  if (!ok) {
    return std::nullopt;
  }
  return hash.digest();
}

} // namespace compiler
