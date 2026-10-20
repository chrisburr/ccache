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

TEST_SUITE_BEGIN("compiler::gcc");

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

TEST_SUITE_END();
