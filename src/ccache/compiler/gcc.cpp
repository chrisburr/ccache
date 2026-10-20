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

namespace compiler {

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

} // namespace compiler
