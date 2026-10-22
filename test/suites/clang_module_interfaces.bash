SUITE_clang_module_interfaces_PROBE() {
    if ! $COMPILER_TYPE_CLANG; then
        echo "compiler is not Clang"
    else
        echo 'export module probe;' >probe.cppm
        $COMPILER -std=c++20 -fmodule-output=probe.pcm -c probe.cppm \
            -o probe.o 2>/dev/null \
            || echo "compiler does not support C++ modules"
    fi
}

SUITE_clang_module_interfaces_SETUP() {
    cat <<'EOF' >geom.cppm
export module geom;
export int geom_value() { return 1; }
EOF
    cat <<'EOF' >main.cpp
import geom;
int main() { return geom_value(); }
EOF
    backdate geom.cppm main.cpp
}

compile_clang_geom() {
    $CCACHE_COMPILE -std=c++20 -x c++-module -fmodule-output=geom.pcm \
        -c geom.cppm -o geom.o "$@"
}

SUITE_clang_module_interfaces() {
    # -------------------------------------------------------------------------
    TEST "Module interface unit is cached and its CMI is restored"

    compile_clang_geom
    expect_stat cache_miss 1
    cp geom.pcm geom.pcm.reference
    cp geom.o geom.o.reference
    rm geom.pcm geom.o

    compile_clang_geom
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1
    expect_equal_content geom.pcm geom.pcm.reference
    expect_equal_content geom.o geom.o.reference

    # -------------------------------------------------------------------------
    TEST "Direct mode"

    unset CCACHE_NODIRECT
    compile_clang_geom
    rm geom.pcm
    compile_clang_geom
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 1
    expect_exists geom.pcm

    # -------------------------------------------------------------------------
    TEST "Depend mode"

    unset CCACHE_NODIRECT
    export CCACHE_DEPEND=1
    compile_clang_geom -MD
    rm geom.pcm
    compile_clang_geom -MD
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 1
    expect_exists geom.pcm

    # -------------------------------------------------------------------------
    TEST "CMI restored in hard link mode"

    export CCACHE_HARDLINK=1
    compile_clang_geom
    rm geom.pcm
    compile_clang_geom
    expect_stat preprocessed_cache_hit 1
    expect_exists geom.pcm
    cp geom.pcm geom.pcm.reference

    # Clang overwrites an existing CMI in place, also without ccache, which
    # must not change the cached one.
    sed_in_place 's/return 1;/return 2;/' geom.cppm
    $COMPILER -std=c++20 -x c++-module -fmodule-output=geom.pcm -c geom.cppm \
        -o other.o
    sed_in_place 's/return 2;/return 1;/' geom.cppm
    backdate geom.cppm
    compile_clang_geom
    expect_stat preprocessed_cache_hit 2
    expect_equal_content geom.pcm geom.pcm.reference

    # -------------------------------------------------------------------------
    TEST "--language"

    cp geom.cppm geom.cpp
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 --language=c++-module \
            -fmodule-output=geom.pcm -c geom.cpp -o geom.o
        expect_exists geom.pcm
        rm geom.pcm
        $CCACHE_COMPILE -std=c++20 --language c++-module \
            -fmodule-output=geom.pcm -c geom.cpp -o geom.o
        expect_exists geom.pcm
        rm geom.pcm
    done
    expect_stat preprocessed_cache_hit 3
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "Extension .cppm"

    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -fmodule-output=geom.pcm -c geom.cppm \
            -o geom.o
        expect_exists geom.pcm
        rm geom.pcm
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "-fmodule-output without path"

    # The CMI is written next to the object file.
    mkdir out
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -fmodule-output -c geom.cppm -o out/geom.o
        expect_exists out/geom.pcm
        rm out/geom.pcm
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "-fmodule-output without path or -o"

    # Clang 21 and earlier write the CMI next to the source file, later
    # versions to the current directory.
    mkdir src
    cp geom.cppm src
    $CCACHE_COMPILE -std=c++20 -fmodule-output -c src/geom.cppm
    expect_stat could_not_use_modules 1

    # -------------------------------------------------------------------------
    TEST "Different CMI path"

    # Clang may record the CMI's file name, but not its directory, in the object
    # file.
    mkdir one two
    for dir in one two; do
        compile_clang_geom -fmodule-output=$dir/geom.pcm
        expect_exists $dir/geom.pcm
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1

    compile_clang_geom -fmodule-output=other.pcm
    expect_exists other.pcm
    expect_stat cache_miss 2

    # -------------------------------------------------------------------------
    TEST "Without -fmodule-output"

    # Clang 22 and later write the CMI next to the object file anyway.
    $COMPILER -std=c++20 -x c++-module -c geom.cppm -o probe.o
    if [ -e probe.pcm ]; then
        writes_cmi=true
    else
        writes_cmi=false
    fi
    echo stale >stale.pcm
    for i in 1 2; do
        cp stale.pcm geom.pcm
        $CCACHE_COMPILE -std=c++20 -x c++-module -c geom.cppm -o geom.o
        if ! $writes_cmi; then
            expect_equal_content geom.pcm stale.pcm
        elif cmp -s geom.pcm stale.pcm; then
            test_failed "Stale CMI not replaced"
        fi
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1

    # A result stored without the CMI is not used when the CMI is written.
    compile_clang_geom
    expect_stat cache_miss 2
    expect_exists geom.pcm

    # -------------------------------------------------------------------------
    TEST "-S without -fmodule-output="

    # Clang 22 and later write the CMI to the current directory.
    $CCACHE_COMPILE -std=c++20 -x c++-module -S geom.cppm -o geom.s
    expect_stat could_not_use_modules 1

    # -------------------------------------------------------------------------
    TEST "CMI directory that does not exist"

    # Unlike GCC, Clang does not create the directory of the CMI.
    mkdir cmi
    compile_clang_geom -fmodule-output=cmi/geom.pcm
    expect_exists cmi/geom.pcm
    rm -r cmi
    if compile_clang_geom -fmodule-output=cmi/geom.pcm 2>/dev/null; then
        test_failed "Expected the compilation to fail"
    fi
    expect_missing cmi

    # -------------------------------------------------------------------------
    TEST "Options passed in a response file like CMake does"

    printf -- '-x c++-module\n-fmodule-output=geom.pcm\n' >geom.o.modmap
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 @geom.o.modmap -c geom.cppm -o geom.o
        expect_exists geom.pcm
        rm geom.pcm
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "Only the CMI with --precompile"

    # Like CMake does for modules of imported targets. Clang writes the CMI to
    # the output file and, except Clang 21 and earlier, to the -fmodule-output
    # path.
    $COMPILER -std=c++20 -x c++-module -fmodule-output=geom.pcm --precompile \
        -c geom.cppm -o geom.o 2>/dev/null
    if [ -f geom.pcm ]; then
        writes_module_output=true
    else
        writes_module_output=false
    fi
    rm -f geom.pcm geom.o

    # A CMI left by an earlier compilation is not taken as written by this one.
    echo stale >stale.pcm
    for i in 1 2; do
        cp stale.pcm geom.pcm
        compile_clang_geom --precompile 2>/dev/null
        expect_exists geom.o
        if ! $writes_module_output; then
            expect_equal_content geom.pcm stale.pcm
        elif cmp -s geom.pcm stale.pcm; then
            test_failed "Expected geom.pcm to be written"
        fi
        rm -f geom.pcm geom.o
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "No CMI for units that are not module interface units"

    # Clang ignores -fmodule-output when compiling other units.
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -x c++ -fmodule-output=geom.pcm \
            -c geom.cppm -o geom.o 2>/dev/null
        expect_missing geom.pcm
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "No CMI with -fsyntax-only"

    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -x c++-module -fmodule-output=geom.pcm \
            -fsyntax-only geom.cppm
        expect_missing geom.pcm
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "Importing unit is recompiled when the restored CMI changes"

    compile_clang_geom
    $CCACHE_COMPILE -std=c++20 -fmodule-file=geom=geom.pcm -c main.cpp
    expect_stat cache_miss 2

    sed_in_place 's/return 1;/return 2;/' geom.cppm
    backdate geom.cppm
    compile_clang_geom
    $CCACHE_COMPILE -std=c++20 -fmodule-file=geom=geom.pcm -c main.cpp
    expect_stat cache_miss 4

    # Restoring the original CMI gives hits for both units.
    sed_in_place 's/return 2;/return 1;/' geom.cppm
    backdate geom.cppm
    compile_clang_geom
    $CCACHE_COMPILE -std=c++20 -fmodule-file=geom=geom.pcm -c main.cpp
    expect_stat preprocessed_cache_hit 2
    expect_stat cache_miss 4

    # -------------------------------------------------------------------------
    TEST "Cache shared between build directories"

    export CCACHE_BASEDIR=$PWD
    for dir in dir1 dir2; do
        mkdir $dir
        cp -p geom.cppm main.cpp $dir
        cd $dir
        $CCACHE_COMPILE -std=c++20 -x c++-module -fmodule-output=geom.pcm \
            -c $PWD/geom.cppm -o geom.o
        $CCACHE_COMPILE -std=c++20 -fmodule-file=geom=geom.pcm \
            -c $PWD/main.cpp -o main.o
        $COMPILER geom.o main.o -o main 2>/dev/null
        cd ..
    done
    expect_stat preprocessed_cache_hit 2
    expect_stat cache_miss 2
    expect_equal_content dir1/geom.pcm dir2/geom.pcm
}
