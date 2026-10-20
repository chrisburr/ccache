SUITE_gcc_modules_PROBE() {
    if ! $COMPILER_TYPE_GCC; then
        echo "GCC modules not supported by compiler"
        return
    fi
    echo 'export module probe;' >probe.cpp
    echo 'probe probe.gcm' >probe.map
    if ! $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=probe.map \
            -MD -fdeps-format=p1689r5 -c probe.cpp -o probe.o 2>/dev/null; then
        echo "compiler does not support C++ modules with -fdeps-format"
    fi
}

SUITE_gcc_modules_SETUP() {
    unset CCACHE_NODIRECT
    export CCACHE_DEPEND=1

    cat <<'EOF' >geom.cpp
export module geom;
export inline int geom_value() { return 1; }
EOF
    cat <<'EOF' >main.cpp
import geom;
int main() { return geom_value(); }
EOF
    cat <<'EOF' >plain.cpp
int plain() { return 1; }
EOF
    printf 'geom cmi/geom.gcm\n' >geom.map
    printf 'geom cmi/geom.gcm\n' >main.map
    printf '\n' >plain.map
    mkdir cmi
    backdate geom.map main.map plain.map
}

compile_geom() {
    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -c geom.cpp -o geom.o
}

compile_main() {
    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=main.map -MD \
        -fdeps-format=p1689r5 -c main.cpp -o main.o
}

# Write the modules c, b (which imports and re-exports c) and a (which imports
# b) and their module mappers in the current directory, with CMIs in cmi/
# relative to `$1`.
write_module_chain() {
    local root=$(native_path "$1")
    mkdir -p cmi
    cat <<'EOF' >c.cpp
export module c;
export inline int c_value() { return 1; }
EOF
    cat <<'EOF' >b.cpp
export module b;
export import c;
export inline int b_value() { return c_value() + 1; }
EOF
    cat <<'EOF' >a.cpp
import b;
int main() { return b_value() + c_value(); }
EOF
    printf '$root %s\nc cmi/c.gcm\n' "$root" >c.map
    printf '$root %s\nb cmi/b.gcm\nc cmi/c.gcm\n' "$root" >b.map
    printf '$root %s\nb cmi/b.gcm\nc cmi/c.gcm\n' "$root" >a.map
    backdate c.cpp b.cpp a.cpp c.map b.map a.map
}

compile_module_chain() {
    for unit in c b a; do
        $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=$unit.map -MD \
            -fdeps-format=p1689r5 -c $unit.cpp -o $unit.o
        if [ -f cmi/$unit.gcm ]; then
            backdate cmi/$unit.gcm
        fi
    done
}

SUITE_gcc_modules() {
    # -------------------------------------------------------------------------
    TEST "Module interface unit is cached and its CMI is restored"

    compile_geom
    expect_stat direct_cache_hit 0
    expect_stat cache_miss 1
    expect_exists cmi/geom.gcm
    mv cmi/geom.gcm geom.gcm.reference
    rm geom.o

    compile_geom
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 1
    expect_equal_content cmi/geom.gcm geom.gcm.reference

    # -------------------------------------------------------------------------
    TEST "CMI is restored in hard link mode"

    export CCACHE_HARDLINK=1
    compile_geom
    expect_stat cache_miss 1
    mv cmi/geom.gcm geom.gcm.reference
    rm geom.o

    compile_geom
    expect_stat direct_cache_hit 1
    expect_equal_content cmi/geom.gcm geom.gcm.reference

    # -------------------------------------------------------------------------
    TEST "CMI is restored in file clone mode"

    export CCACHE_FILECLONE=1
    compile_geom
    expect_stat cache_miss 1
    mv cmi/geom.gcm geom.gcm.reference
    rm geom.o

    compile_geom
    expect_stat direct_cache_hit 1
    expect_equal_content cmi/geom.gcm geom.gcm.reference

    # -------------------------------------------------------------------------
    TEST "CMI is restored from remote storage"

    export CCACHE_REMOTE_STORAGE=$(file_storage_url "$PWD/remote")
    compile_geom
    expect_stat cache_miss 1
    mv cmi/geom.gcm geom.gcm.reference
    rm geom.o
    remove_cache

    compile_geom
    expect_stat direct_cache_hit 1
    expect_stat remote_storage_hit 1
    expect_equal_content cmi/geom.gcm geom.gcm.reference

    # -------------------------------------------------------------------------
    TEST "Module mapper with a root directory"

    printf '$root out\ngeom cmi/geom.gcm\n' >geom.map
    backdate geom.map
    mkdir -p out/cmi
    compile_geom
    expect_stat cache_miss 1
    expect_exists out/cmi/geom.gcm
    rm out/cmi/geom.gcm

    compile_geom
    expect_stat direct_cache_hit 1
    expect_exists out/cmi/geom.gcm

    # Windows drops trailing spaces from file names.
    if ! $HOST_OS_WINDOWS; then
        # ---------------------------------------------------------------------
        TEST "CMI path ending with a space"

        # GCC takes the rest of the line as the CMI path.
        printf 'geom cmi/geom.gcm \n' >geom.map
        backdate geom.map
        compile_geom
        expect_stat cache_miss 1
        expect_exists "cmi/geom.gcm "
        rm "cmi/geom.gcm "

        compile_geom
        expect_stat direct_cache_hit 1
        expect_exists "cmi/geom.gcm "
    fi

    # -------------------------------------------------------------------------
    TEST "Module interface unit including a changed header"

    echo 'inline int header_value() { return 1; }' >header.h
    cat <<'EOF' >geom.c++m
module;
#include "header.h"
export module geom;
export inline int geom_value() { return header_value(); }
EOF
    backdate header.h geom.c++m

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -x c++ -c geom.c++m -o geom.o
    expect_stat cache_miss 1
    cp cmi/geom.gcm geom.gcm.v1

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -x c++ -c geom.c++m -o geom.o
    expect_stat direct_cache_hit 1

    echo 'inline int header_value() { return 2; }' >header.h
    backdate header.h
    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -x c++ -c geom.c++m -o geom.o
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 2
    if cmp -s cmi/geom.gcm geom.gcm.v1; then
        test_failed "Expected a new CMI"
    fi

    # -------------------------------------------------------------------------
    TEST "Importing unit is recompiled when the imported CMI changes"

    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map \
        -c geom.cpp -o geom.o
    backdate cmi/geom.gcm

    compile_main
    expect_stat direct_cache_hit 0
    expect_stat cache_miss 1

    compile_main
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 1

    sed_in_place 's/return 1;/return 2;/' geom.cpp
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map \
        -c geom.cpp -o geom.o
    backdate cmi/geom.gcm

    compile_main
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 2

    # MinGW GCC writes CMIs that differ between compilations of the same unit
    # in more than the README.
    if ! $HOST_OS_WINDOWS; then
        # ---------------------------------------------------------------------
        TEST "Importing unit is not recompiled when only the CMI README changes"

        $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map \
            -c geom.cpp -o geom.o
        backdate cmi/geom.gcm

        compile_main
        expect_stat direct_cache_hit 0
        expect_stat cache_miss 1

        # The README section records the working directory and source path.
        mkdir -p other/cmi
        cp geom.cpp geom.map other
        (cd other && $COMPILER -std=c++20 -fmodules-ts \
            -fmodule-mapper=geom.map -c geom.cpp -o geom.o)
        if cmp -s cmi/geom.gcm other/cmi/geom.gcm; then
            test_failed "Expected CMIs built in other directories to differ"
        fi
        cp other/cmi/geom.gcm cmi/geom.gcm
        backdate cmi/geom.gcm

        compile_main
        expect_stat direct_cache_hit 1
        expect_stat cache_miss 1

        # ---------------------------------------------------------------------
        TEST "Importing unit is not recompiled when only the README of an indirectly imported CMI changes"

        # Like with CMake, the module mapper of the importing unit only lists
        # the directly imported module, and the CMI of the indirectly imported
        # module is named like CMake's CMIs of modules of imported targets.
        cat <<'EOF' >shape.cpp
export module shape;
export import geom;
EOF
        cat <<'EOF' >uses_shape.cpp
import shape;
int main() { return geom_value(); }
EOF
        printf 'geom cmi/geom.bmi\n' >geom_bmi.map
        printf 'shape cmi/shape.gcm\ngeom cmi/geom.bmi\n' >shape.map
        printf 'shape cmi/shape.gcm\n' >uses_shape.map
        backdate shape.cpp uses_shape.cpp geom_bmi.map shape.map uses_shape.map
        $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom_bmi.map \
            -c geom.cpp -o geom.o
        $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=shape.map \
            -c shape.cpp -o shape.o
        backdate cmi/geom.bmi cmi/shape.gcm

        $CCACHE_COMPILE -std=c++20 -fmodules-ts \
            -fmodule-mapper=uses_shape.map -MD -fdeps-format=p1689r5 \
            -c uses_shape.cpp -o uses_shape.o
        expect_stat cache_miss 1
        expect_contains uses_shape.d cmi/geom.bmi

        mkdir -p other/cmi
        cp geom.cpp geom_bmi.map other
        (cd other && $COMPILER -std=c++20 -fmodules-ts \
            -fmodule-mapper=geom_bmi.map -c geom.cpp -o geom.o)
        if cmp -s cmi/geom.bmi other/cmi/geom.bmi; then
            test_failed "Expected CMIs built in other directories to differ"
        fi
        cp other/cmi/geom.bmi cmi/geom.bmi
        backdate cmi/geom.bmi

        $CCACHE_COMPILE -std=c++20 -fmodules-ts \
            -fmodule-mapper=uses_shape.map -MD -fdeps-format=p1689r5 \
            -c uses_shape.cpp -o uses_shape.o
        expect_stat direct_cache_hit 1
        expect_stat cache_miss 1
    fi

    # -------------------------------------------------------------------------
    TEST "Module implementation unit"

    cat <<'EOF' >geom_impl.cpp
module geom;
int geom_impl() { return geom_value(); }
EOF
    backdate geom_impl.cpp
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map \
        -c geom.cpp -o geom.o
    backdate cmi/geom.gcm
    cp cmi/geom.gcm geom.gcm.reference

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -c geom_impl.cpp -o geom_impl.o
    expect_stat cache_miss 1

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -c geom_impl.cpp -o geom_impl.o
    expect_stat direct_cache_hit 1
    expect_equal_content cmi/geom.gcm geom.gcm.reference

    sed_in_place 's/return 1;/return 2;/' geom.cpp
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map \
        -c geom.cpp -o geom.o
    backdate cmi/geom.gcm

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -c geom_impl.cpp -o geom_impl.o
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 2

    # -------------------------------------------------------------------------
    TEST "Chain of imported and re-exported modules"

    write_module_chain .
    compile_module_chain
    expect_stat cache_miss 3
    # The linker may warn, e.g. about duplicate -rpath options.
    $COMPILER c.o b.o a.o -o a 2>/dev/null
    ./a
    expect_equal_content <(echo $?) <(echo 3)

    rm -f cmi/*.gcm *.o a
    compile_module_chain
    expect_stat direct_cache_hit 3
    expect_stat cache_miss 3
    expect_exists cmi/c.gcm
    expect_exists cmi/b.gcm

    # Changing c changes the CMIs of c and b, so all units are recompiled.
    sed_in_place 's/return 1;/return 2;/' c.cpp
    backdate c.cpp
    compile_module_chain
    expect_stat direct_cache_hit 3
    expect_stat cache_miss 6
    # The linker may warn, e.g. about duplicate -rpath options.
    $COMPILER c.o b.o a.o -o a 2>/dev/null
    ./a
    expect_equal_content <(echo $?) <(echo 5)

    # -------------------------------------------------------------------------
    TEST "Module partition"

    cat <<'EOF' >part.cpp
export module geom:part;
export inline int part_value() { return 3; }
EOF
    printf 'geom:part cmi/geom-part.gcm\n' >part.map
    backdate part.cpp part.map

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=part.map -MD \
        -fdeps-format=p1689r5 -c part.cpp -o part.o
    expect_stat cache_miss 1
    expect_exists cmi/geom-part.gcm
    rm part.o cmi/geom-part.gcm

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=part.map -MD \
        -fdeps-format=p1689r5 -c part.cpp -o part.o
    expect_stat direct_cache_hit 1
    expect_exists cmi/geom-part.gcm

    # -------------------------------------------------------------------------
    TEST "Importing a header unit"

    echo 'inline int header_value() { return 4; }' >header.h
    printf './header.h cmi/header.gcm\n' >header.map
    cat <<'EOF' >header_user.cpp
import "header.h";
int main() { return header_value(); }
EOF
    backdate header.map header_user.cpp
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=header.map \
        -fmodule-header -x c++-header -c header.h
    backdate cmi/header.gcm

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=header.map -MD \
        -fdeps-format=p1689r5 -c header_user.cpp -o header_user.o
    expect_stat cache_miss 1

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=header.map -MD \
        -fdeps-format=p1689r5 -c header_user.cpp -o header_user.o
    expect_stat direct_cache_hit 1

    echo 'inline int header_value() { return 5; }' >header.h
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=header.map \
        -fmodule-header -x c++-header -c header.h
    backdate cmi/header.gcm

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=header.map -MD \
        -fdeps-format=p1689r5 -c header_user.cpp -o header_user.o
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 2

    # -------------------------------------------------------------------------
    TEST "Compilation options used by CMake"

    mkdir -p CMakeFiles/geom.dir CMakeFiles/main.dir
    printf '$root .\ngeom CMakeFiles/geom.dir/geom.gcm\n' >geom.o.modmap
    cp geom.o.modmap main.o.modmap
    backdate geom.o.modmap main.o.modmap
    cmake_compile() {
        $CCACHE_COMPILE -std=c++20 -x c++ -MD -MT $1.o -MF $1.o.d \
            -fmodules-ts -fmodule-mapper=$1.o.modmap -fdeps-format=p1689r5 \
            -c $PWD/$1.cpp -o $1.o
    }

    cmake_compile geom
    expect_stat cache_miss 1
    expect_exists geom.ddi
    backdate CMakeFiles/geom.dir/geom.gcm
    cmake_compile main
    expect_stat cache_miss 2
    mv CMakeFiles/geom.dir/geom.gcm geom.gcm.reference
    mv geom.ddi geom.ddi.reference
    mv main.ddi main.ddi.reference
    rm geom.o main.o

    cmake_compile geom
    expect_stat direct_cache_hit 1
    expect_equal_content CMakeFiles/geom.dir/geom.gcm geom.gcm.reference
    expect_equal_content geom.ddi geom.ddi.reference
    backdate CMakeFiles/geom.dir/geom.gcm
    cmake_compile main
    expect_stat direct_cache_hit 2
    expect_equal_content main.ddi main.ddi.reference

    # The importing unit is recompiled when the imported module changes.
    sed_in_place 's/return 1;/return 2;/' geom.cpp
    backdate geom.cpp
    cmake_compile geom
    backdate CMakeFiles/geom.dir/geom.gcm
    cmake_compile main
    expect_stat direct_cache_hit 2
    expect_stat cache_miss 4

    # -------------------------------------------------------------------------
    TEST "Include translated to a header unit import"

    echo 'inline int header_value() { return 4; }' >header.h
    cat <<'EOF' >impl.cpp
module;
#include "header.h"
module geom;
int impl_value() { return geom_value() + header_value(); }
EOF
    printf 'geom cmi/geom.gcm\n./header.h cmi/header.gcm\n' >impl.map
    backdate header.h impl.map
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=impl.map \
        -fmodule-header -x c++-header -c header.h
    compile_geom
    backdate cmi/geom.gcm cmi/header.gcm

    compile_impl() {
        $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=impl.map -MD \
            -fdeps-format=p1689r5 -c impl.cpp -o impl.o
    }
    compile_impl
    expect_stat cache_miss 2
    expect_contains impl.ddi '"logical-name": "./header.h"'
    compile_impl
    expect_stat direct_cache_hit 1

    # The header unit is used instead of the header.
    echo 'inline int header_value() { return 5; }' >header.h
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=impl.map \
        -fmodule-header -x c++-header -c header.h
    backdate header.h cmi/header.gcm
    compile_impl
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 3

    # -------------------------------------------------------------------------
    TEST "Imported CMI not listed in the dependency file"

    compile_geom
    backdate cmi/geom.gcm
    cat <<EOF >compiler.sh
#!/bin/sh
$COMPILER "\$@" && sed 's|cmi/geom.gcm||' main.d >main.d.tmp \\
    && mv main.d.tmp main.d
EOF
    chmod +x compiler.sh
    backdate compiler.sh

    $CCACHE ./compiler.sh -std=c++20 -fmodules-ts -fmodule-mapper=main.map -MD \
        -fdeps-format=p1689r5 -c main.cpp -o main.o
    expect_stat could_not_use_modules 1

    # -------------------------------------------------------------------------
    TEST "Imported CMI in ignore_headers_in_manifest"

    compile_geom
    backdate cmi/geom.gcm
    export CCACHE_IGNOREHEADERS=cmi
    compile_main
    expect_stat could_not_use_modules 1

    # -------------------------------------------------------------------------
    TEST "P1689 file given by -fdeps-file"

    compile_geom_ddi() {
        $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
            -fdeps-format=p1689r5 \
            -fdeps-file=out/geom.json -c geom.cpp -o geom.o
    }
    mkdir out
    compile_geom_ddi
    expect_stat cache_miss 1
    expect_exists out/geom.json
    mv out/geom.json geom.json.reference
    rm geom.o cmi/geom.gcm

    compile_geom_ddi
    expect_stat direct_cache_hit 1
    expect_equal_content out/geom.json geom.json.reference
    expect_exists cmi/geom.gcm

    # -------------------------------------------------------------------------
    TEST "Cache shared between build directories with relative CMI paths"

    export CCACHE_BASEDIR=$PWD
    for dir in dir1 dir2; do
        mkdir $dir
        (cd $dir && write_module_chain .)
    done

    cd dir1
    compile_module_chain
    expect_stat cache_miss 3

    cd ../dir2
    compile_module_chain
    expect_stat direct_cache_hit 3
    expect_stat cache_miss 3
    cd ..

    # The restored CMIs must not refer to the other build directory.
    rm -rf dir1
    cd dir2
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=a.map -c a.cpp -o a2.o
    cd ..

    # -------------------------------------------------------------------------
    TEST "Cache shared between build directories with an absolute root"

    # GCC records the CMI paths of imported modules without the root in a
    # written CMI.
    export CCACHE_BASEDIR=$PWD
    for dir in dir1 dir2; do
        mkdir $dir
        root=$PWD/$dir
        (cd $dir && write_module_chain $root)
    done

    cd dir1
    compile_module_chain
    expect_stat cache_miss 3

    cd ../dir2
    compile_module_chain
    expect_stat direct_cache_hit 3
    expect_stat cache_miss 3
    cd ..

    rm -rf dir1
    cd dir2
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=a.map -c a.cpp -o a2.o
    cd ..

    # -------------------------------------------------------------------------
    TEST "Cache not shared between build directories with absolute CMI paths"

    export CCACHE_BASEDIR=$PWD
    for dir in dir1 dir2; do
        mkdir $dir
        cmi_dir=$(native_path "$PWD/$dir/cmi")
        (cd $dir && write_module_chain . \
            && sed_in_place "s|cmi/|$cmi_dir/|" c.map b.map a.map \
            && backdate c.map b.map a.map)
    done

    cd dir1
    compile_module_chain
    expect_stat cache_miss 3

    cd ../dir2
    compile_module_chain
    expect_stat direct_cache_hit 0
    expect_stat cache_miss 6
    cd ..

    # -------------------------------------------------------------------------
    TEST "Dependency and P1689 files are restored as written by the compiler"

    for unit in geom main; do
        for options in "" "-MT $unit.target"; do
            $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=$unit.map \
                -MD -fdeps-format=p1689r5 $options -c $unit.cpp -o $unit.o
            backdate cmi/geom.gcm
            mv $unit.d $unit.d.reference
            mv $unit.ddi $unit.ddi.reference
            rm $unit.o

            $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=$unit.map \
                -MD -fdeps-format=p1689r5 $options -c $unit.cpp -o $unit.o
            expect_equal_content $unit.d $unit.d.reference
            expect_equal_content $unit.ddi $unit.ddi.reference
        done
    done
    expect_stat direct_cache_hit 4
    expect_stat cache_miss 4

    # -------------------------------------------------------------------------
    TEST "Dependency file restored in another build directory"

    export CCACHE_BASEDIR=$PWD
    for dir in dir1 dir2; do
        mkdir $dir
        root=$PWD/$dir
        (cd $dir && write_module_chain $root)
    done

    cd dir1
    compile_module_chain
    expect_stat cache_miss 3

    cd ../dir2
    compile_module_chain
    expect_stat direct_cache_hit 3
    for unit in c b a; do
        mv $unit.d $unit.d.hit
    done
    CCACHE_RECACHE=1 compile_module_chain
    for unit in c b a; do
        expect_equal_content $unit.d $unit.d.hit
    done
    if grep -q dir1 c.d.hit b.d.hit a.d.hit; then
        test_failed "Restored dependency file refers to dir1"
    fi
    cd ..

    # -------------------------------------------------------------------------
    TEST "CMI restored to a directory that does not exist"

    compile_geom
    expect_stat cache_miss 1
    rm -r cmi geom.o

    compile_geom
    expect_stat direct_cache_hit 1
    expect_exists cmi/geom.gcm

    # -------------------------------------------------------------------------
    TEST "Inode cache"

    export CCACHE_INODECACHE=1 CCACHE_DISABLE_INODE_CACHE_MIN_AGE=1
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map \
        -c geom.cpp -o geom.o
    backdate cmi/geom.gcm

    compile_main
    expect_stat cache_miss 1
    compile_main
    expect_stat direct_cache_hit 1

    mkdir -p other/cmi
    cp geom.cpp geom.map other
    (cd other && $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map \
        -c geom.cpp -o geom.o)
    cp other/cmi/geom.gcm cmi/geom.gcm
    backdate cmi/geom.gcm
    compile_main
    expect_stat direct_cache_hit 2

    sed_in_place 's/return 1;/return 2;/' geom.cpp
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map \
        -c geom.cpp -o geom.o
    backdate cmi/geom.gcm
    compile_main
    expect_stat direct_cache_hit 2
    expect_stat cache_miss 2

    # -------------------------------------------------------------------------
    TEST "file_stat_matches with a CMI of another size"

    export CCACHE_SLOPPINESS="$CCACHE_SLOPPINESS,file_stat_matches"
    export CCACHE_SLOPPINESS="$CCACHE_SLOPPINESS,file_stat_matches_ctime"
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map \
        -c geom.cpp -o geom.o
    backdate cmi/geom.gcm
    compile_main
    expect_stat cache_miss 1

    echo 'export inline int geom_value_2() { return 2; }' >>geom.cpp
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map \
        -c geom.cpp -o geom.o
    backdate cmi/geom.gcm
    compile_main
    expect_stat direct_cache_hit 0
    expect_stat cache_miss 2

    # -------------------------------------------------------------------------
    TEST "CMI written by another process"

    # Write the geom CMI while compiling a unit that does not provide geom.
    cat <<EOF >compiler.sh
#!/bin/sh
$COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -c geom.cpp -o geom.o
exec $COMPILER "\$@"
EOF
    chmod +x compiler.sh
    backdate compiler.sh

    $CCACHE ./compiler.sh -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -c plain.cpp -o plain.o
    expect_stat cache_miss 1
    rm cmi/geom.gcm

    $CCACHE ./compiler.sh -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -c plain.cpp -o plain.o
    expect_stat direct_cache_hit 1
    expect_missing cmi/geom.gcm

    # -------------------------------------------------------------------------
    TEST "CMI of provided module not written"

    cat <<EOF >compiler.sh
#!/bin/sh
$COMPILER "\$@" && rm cmi/geom.gcm
EOF
    chmod +x compiler.sh
    backdate compiler.sh

    $CCACHE ./compiler.sh -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -c geom.cpp -o geom.o
    expect_stat could_not_use_modules 1

    # -------------------------------------------------------------------------
    TEST "CMI of provided module left by an earlier compilation"

    # GCC does not write the CMI if the root directory does not exist but the
    # compilation still succeeds.
    $COMPILER -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -c geom.cpp
    printf '$root %s/missing\ngeom cmi/geom.gcm\n' "$(native_path "$PWD")" \
        >missing.map
    cat <<EOF >compiler.sh
#!/bin/sh
exec $COMPILER "\$@" -fmodule-mapper=missing.map
EOF
    chmod +x compiler.sh
    backdate compiler.sh

    $CCACHE ./compiler.sh -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -c geom.cpp -o geom.o
    expect_stat could_not_use_modules 1

    # -------------------------------------------------------------------------
    TEST "-fsyntax-only with a module interface unit"

    compile_geom
    backdate cmi/geom.gcm
    cp cmi/geom.gcm geom.gcm.reference
    echo 'export inline int geom_value_2() { return 2; }' >>geom.cpp
    backdate geom.cpp

    # GCC does not write the CMI with -fsyntax-only.
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
            -fdeps-format=p1689r5 -fsyntax-only geom.cpp
        expect_equal_content cmi/geom.gcm geom.gcm.reference
    done
    expect_stat cache_miss 2
    expect_stat direct_cache_hit 1

    # -------------------------------------------------------------------------
    TEST "Only the CMI with -fmodule-only"

    # Like CMake's command for a module of an imported target, e.g. the C++
    # standard library's.
    printf 'geom geom.bmi\n' >bmi.map
    backdate bmi.map
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=bmi.map -MD \
            -fdeps-format=p1689r5 -fmodule-only -c geom.cpp -o geom.bmi
        expect_exists geom.bmi
        expect_exists geom.d
        expect_exists geom.ddi
        mv geom.bmi geom.bmi.$i
    done
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 1
    expect_equal_content geom.bmi.1 geom.bmi.2

    # The object file is not written for an object file path other than the
    # CMI path either.
    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 -fmodule-only -c geom.cpp -o geom.o
    expect_exists cmi/geom.gcm
    expect_missing geom.o

    # -------------------------------------------------------------------------
    TEST "Unit that does not use modules"

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=plain.map -MD \
        -fdeps-format=p1689r5 -c plain.cpp -o plain.o
    expect_stat cache_miss 1

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=plain.map -MD \
        -fdeps-format=p1689r5 -c plain.cpp -o plain.o
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "Module mapper without entries"

    # Like CMake's module mapper for a unit without imports or exports.
    printf '$root .\n' >root.map
    backdate root.map

    # Units that don't use modules are cached in any mode.
    unset CCACHE_DEPEND
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=root.map -MD \
            -fdeps-format=p1689r5 -c plain.cpp -o plain.o
    done
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 1

    export CCACHE_NODIRECT=1
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=root.map \
            -c plain.cpp -o plain.o
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 2

    # GCC fails to compile units that use modules.
    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=root.map \
        -c geom.cpp -o geom.o 2>/dev/null
    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=root.map \
        -c main.cpp -o main.o 2>/dev/null
    expect_stat compile_failed 2

    # GCC still translates an include into an import of a header unit whose CMI
    # is in the module mapper's root directory, which is not hashed.
    unset CCACHE_NODIRECT
    echo 'inline int header_value() { return 4; }' >header.h
    printf '#include "header.h"\nint value() { return header_value(); }\n' \
        >translated.cpp
    printf '$root gcm.cache\n' >gcm.map
    backdate header.h translated.cpp gcm.map
    $COMPILER -std=c++20 -fmodules-ts -fmodule-header -x c++-header -c header.h
    expect_exists gcm.cache/,/header.h.gcm
    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=gcm.map \
        -c translated.cpp -o translated.o
    expect_stat could_not_use_modules 1

    # -------------------------------------------------------------------------
    TEST "Changed module mapper"

    compile_geom
    expect_stat cache_miss 1

    printf 'geom cmi/geom2.gcm\n' >geom.map
    backdate geom.map
    compile_geom
    expect_stat direct_cache_hit 0
    expect_stat cache_miss 2
    expect_exists cmi/geom2.gcm

    # -------------------------------------------------------------------------
    TEST "-fmodules spelling"

    if $COMPILER -std=c++20 -fmodules -fmodule-mapper=plain.map \
            -c plain.cpp -o plain.o 2>/dev/null; then
        $CCACHE_COMPILE -std=c++20 -fmodules -fmodule-mapper=geom.map -MD \
            -fdeps-format=p1689r5 -c geom.cpp -o geom.o
        expect_stat cache_miss 1
        rm geom.o cmi/geom.gcm

        $CCACHE_COMPILE -std=c++20 -fmodules -fmodule-mapper=geom.map -MD \
            -fdeps-format=p1689r5 -c geom.cpp -o geom.o
        expect_stat direct_cache_hit 1
        expect_exists cmi/geom.gcm
    fi

    # -------------------------------------------------------------------------
    TEST "-fmodules without a module mapper"

    # GCC writes the CMI to gcm.cache, which is not stored in the cache.
    if $COMPILER -std=c++20 -fmodules -c plain.cpp -o plain.o 2>/dev/null; then
        CCACHE_DEPEND=1 CCACHE_SLOPPINESS="$DEFAULT_SLOPPINESS modules" \
            $CCACHE_COMPILE -std=c++20 -fmodules -MD -c geom.cpp -o geom.o
        expect_stat could_not_use_modules 1
    fi

    # -------------------------------------------------------------------------
    TEST "-fmodules with a compiler of unknown type"

    # On Windows, the compiler used by the test suite is a script that can't
    # be run through a symlink.
    if ! $HOST_OS_WINDOWS \
            && $COMPILER -std=c++20 -fmodules -fmodule-mapper=plain.map \
                -c plain.cpp -o plain.o 2>/dev/null; then
        ln -s "$(command -v $COMPILER)" mycompiler
        $CCACHE ./mycompiler -std=c++20 -fmodules -fmodule-mapper=geom.map -MD \
            -fdeps-format=p1689r5 -c geom.cpp -o geom.o
        expect_stat cache_miss 1
        rm geom.o cmi/geom.gcm

        $CCACHE ./mycompiler -std=c++20 -fmodules -fmodule-mapper=geom.map -MD \
            -fdeps-format=p1689r5 -c geom.cpp -o geom.o
        expect_stat direct_cache_hit 1
        expect_exists cmi/geom.gcm
    fi

    # -------------------------------------------------------------------------
    TEST "-fno-modules-ts"

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fno-modules-ts -MD \
        -c plain.cpp -o plain.o
    expect_stat cache_miss 1
    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fno-modules-ts -MD \
        -c plain.cpp -o plain.o
    expect_stat direct_cache_hit 1

    SUITE_gcc_modules_unsupported
}

SUITE_gcc_modules_unsupported() {
    # -------------------------------------------------------------------------
    TEST "Unsupported without depend mode"

    unset CCACHE_DEPEND
    compile_geom
    expect_stat could_not_use_modules 1

    # -------------------------------------------------------------------------
    TEST "Unsupported without direct mode"

    export CCACHE_NODIRECT=1
    compile_geom
    expect_stat could_not_use_modules 1

    # -------------------------------------------------------------------------
    TEST "Unsupported without -fdeps-format"

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -c geom.cpp -o geom.o
    expect_stat could_not_use_modules 1

    # -------------------------------------------------------------------------
    TEST "Unsupported without module mapper file"

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -MD -fdeps-format=p1689r5 -c \
        geom.cpp -o geom.o
    expect_stat could_not_use_modules 1

    # A section of a module mapper file.
    $CCACHE_COMPILE -std=c++20 -fmodules-ts '-fmodule-mapper=plain.map?ident' \
        -MD -c plain.cpp -o plain.o
    expect_stat could_not_use_modules 2

    # -------------------------------------------------------------------------
    TEST "Module options passed to the preprocessor"

    $CCACHE_COMPILE -std=c++20 -Wp,-fmodules-ts -fmodule-mapper=geom.map \
        -c geom.cpp -o geom.o
    expect_stat could_not_use_modules 1

    $CCACHE_COMPILE -std=c++20 -Xpreprocessor -fmodules-ts \
        -fmodule-mapper=geom.map -c geom.cpp -o geom.o
    expect_stat could_not_use_modules 2

    # -------------------------------------------------------------------------
    TEST "Unsupported options"

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=geom.map -MD \
        -fdeps-format=p1689r5 --compile-std-module -c geom.cpp -o geom.o \
        2>/dev/null
    expect_stat unsupported_compiler_option 1

    # GCC writes an object file for C with -fmodule-only.
    echo 'int c;' >test.c
    $CCACHE_COMPILE -fmodule-only -c test.c 2>/dev/null
    expect_stat unsupported_compiler_option 2

    # -------------------------------------------------------------------------
    TEST "Compiling a header unit is unsupported"

    export CCACHE_SLOPPINESS="$CCACHE_SLOPPINESS pch_defines,time_macros"
    echo 'inline int header_value() { return 4; }' >header.h
    printf '$root .\n./header.h cmi/header.gcm\n' >header.map
    backdate header.h header.map

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=header.map -MD \
        -fdeps-format=p1689r5 -x c++-header -c header.h
    expect_stat could_not_use_modules 1

    $CCACHE_COMPILE -std=c++20 -fmodules-ts -fmodule-mapper=header.map -MD \
        -fdeps-format=p1689r5 -x c++-header -c header.h -o header.gch
    expect_stat could_not_use_modules 2
}
