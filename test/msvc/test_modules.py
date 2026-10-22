import json

INTERFACE = """\
export module m;
export inline int value() { return %d; }
"""

IMPORTER = """\
import m;
int main() { return value(); }
"""


def could_not_use_modules(test):
    result = test.run([test.ccache_exe, "--print-stats", "--format", "json"])
    return json.loads(result.stdout).get("could_not_use_modules", 0)


def test_interface_unit_ifc_is_restored(ccache_test):
    (ccache_test.workdir / "m.ixx").write_text(INTERFACE % 1)
    ifc = ccache_test.workdir / "m.ifc"
    obj = ccache_test.workdir / "m.obj"
    cl_args = ["/std:c++20", "/c", "m.ixx", "/ifcOutput", "m.ifc"]

    ccache_test.compile(cl_args)
    stats_1 = ccache_test.stats()
    assert stats_1["miss"] == 1
    assert stats_1["total_hit"] == 0
    expected = ifc.read_bytes()

    ifc.unlink()
    obj.unlink()

    ccache_test.compile(cl_args)
    stats_2 = ccache_test.stats()
    assert stats_2["miss"] == 1
    assert stats_2["total_hit"] == 1
    assert obj.exists()
    assert ifc.read_bytes() == expected


def test_interface_flag_with_ifc_output(ccache_test):
    (ccache_test.workdir / "m.cppm").write_text(INTERFACE % 1)
    ifc = ccache_test.workdir / "out" / "m.ifc"
    ifc.parent.mkdir()
    cl_args = [
        "/std:c++20",
        "/interface",
        "/ifcOutput",
        str(ifc),
        "/TP",
        "/c",
        "m.cppm",
    ]

    ccache_test.compile(cl_args)
    ifc.unlink()

    ccache_test.compile(cl_args)
    stats = ccache_test.stats()
    assert stats["miss"] == 1
    assert stats["total_hit"] == 1
    assert ifc.exists()


def test_importer_depends_on_referenced_ifc(ccache_test):
    (ccache_test.workdir / "main.cpp").write_text(IMPORTER)
    # Outside the current directory, the IFC is only found through /reference.
    (ccache_test.workdir / "out").mkdir()
    interface_args = ["/std:c++20", "/c", "m.ixx", "/ifcOutput", "out/m.ifc"]
    importer_args = [
        "/std:c++20",
        "/c",
        "main.cpp",
        "/reference",
        "m=out/m.ifc",
    ]

    (ccache_test.workdir / "m.ixx").write_text(INTERFACE % 1)
    ccache_test.compile(interface_args)
    ccache_test.compile(importer_args)
    ccache_test.compile(importer_args)
    stats_1 = ccache_test.stats()
    assert stats_1["miss"] == 2
    assert stats_1["total_hit"] == 1

    (ccache_test.workdir / "m.ixx").write_text(INTERFACE % 2)
    ccache_test.compile(interface_args)
    ccache_test.compile(importer_args)
    stats_2 = ccache_test.stats()
    assert stats_2["miss"] == 4
    assert stats_2["total_hit"] == 1

    ccache_test.run(["link", "/nologo", "main.obj", "m.obj", "/out:main.exe"])
    result = ccache_test.run([str(ccache_test.workdir / "main.exe")], check=False)
    assert result.returncode == 2


def test_unsupported_module_options(ccache_test):
    (ccache_test.workdir / "m.ixx").write_text(INTERFACE % 1)
    (ccache_test.workdir / "h.h").write_text("inline int h() { return 1; }\n")

    # Without a file name, MSVC names the IFC after the module.
    ccache_test.compile(["/std:c++20", "/c", "m.ixx"])
    assert could_not_use_modules(ccache_test) == 1

    ccache_test.compile(
        ["/std:c++20", "/exportHeader", "/headerName:quote", "h.h", "/c"]
    )
    assert could_not_use_modules(ccache_test) == 2


def test_importer_depends_on_ifc_in_current_directory(ccache_test):
    (ccache_test.workdir / "main.cpp").write_text(IMPORTER)
    # Without /ifcOutput, MSVC writes m.ifc to the current directory, where an
    # import without /reference finds it.
    interface_args = ["cl", "/nologo", "/std:c++20", "/c", "m.ixx"]
    importer_args = ["/nologo", "/std:c++20", "/c", "main.cpp"]

    (ccache_test.workdir / "m.ixx").write_text(INTERFACE % 1)
    ccache_test.run(interface_args)
    ccache_test.compile(importer_args)
    ccache_test.compile(importer_args)
    stats_1 = ccache_test.stats()
    assert stats_1["miss"] == 1
    assert stats_1["total_hit"] == 1

    (ccache_test.workdir / "m.ixx").write_text(INTERFACE % 2)
    ccache_test.run(interface_args)
    ccache_test.compile(importer_args)
    stats_2 = ccache_test.stats()
    assert stats_2["miss"] == 2
    assert stats_2["total_hit"] == 1

    ccache_test.run(["link", "/nologo", "main.obj", "m.obj", "/out:main.exe"])
    result = ccache_test.run([str(ccache_test.workdir / "main.exe")], check=False)
    assert result.returncode == 2


def test_implementation_unit_depends_on_ifc_of_its_module(ccache_test):
    (ccache_test.workdir / "impl.cpp").write_text(
        "module m;\nint impl() { return value(); }\n"
    )
    interface_args = ["/std:c++20", "/c", "m.ixx", "/ifcOutput", "m.ifc"]
    # /ifcOutput writes nothing for a unit that is not an interface unit, which
    # reads the IFC of its module instead.
    impl_args = ["/std:c++20", "/c", "impl.cpp", "/ifcOutput", "m.ifc"]

    (ccache_test.workdir / "m.ixx").write_text(INTERFACE % 1)
    ccache_test.compile(interface_args)
    ccache_test.compile(impl_args)
    ccache_test.compile(impl_args)
    stats_1 = ccache_test.stats()
    assert stats_1["miss"] == 2
    assert stats_1["total_hit"] == 1

    (ccache_test.workdir / "m.ixx").write_text(INTERFACE % 2)
    ccache_test.compile(interface_args)
    ccache_test.compile(impl_args)
    stats_2 = ccache_test.stats()
    assert stats_2["miss"] == 4
    assert stats_2["total_hit"] == 1
