SUITE_fdeps_format_PROBE() {
    if ! $COMPILER_TYPE_GCC; then
        echo "-fdeps-format not supported by compiler"
        return
    fi
    touch probe.cpp
    if ! $COMPILER -std=c++20 -MD -fdeps-format=p1689r5 -c probe.cpp \
            2>/dev/null; then
        echo "-fdeps-format not supported by compiler"
    fi
}

SUITE_fdeps_format_SETUP() {
    echo 'int test() { return 1; }' >test.cpp
    backdate test.cpp
}

SUITE_fdeps_format() {
    # -------------------------------------------------------------------------
    TEST "P1689 file is restored"

    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 -c test.cpp
        expect_contains test.ddi '"test.o"'
        rm test.ddi
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "P1689 file given by -fdeps-file"

    mkdir out
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 \
            -fdeps-file=$PWD/out/test.json -c test.cpp
        expect_contains out/test.json '"test.o"'
        rm out/test.json
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1
    expect_missing test.ddi

    # -------------------------------------------------------------------------
    TEST "Different object file"

    for obj in one two; do
        $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 \
            -c test.cpp -o $obj.o
        expect_contains $obj.ddi "\"$obj.o\""
    done
    expect_stat preprocessed_cache_hit 0
    expect_stat cache_miss 2

    # -------------------------------------------------------------------------
    TEST "Object file without suffix .o"

    # GCC replaces the suffix of the object file with .o in the P1689 file.
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 \
            -c test.cpp -o test.obj
        expect_contains test.ddi '"test.o"'
        $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 \
            -c test.cpp -o other
        expect_contains other.ddi '"other.o"'
        $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 -S test.cpp
        expect_contains test.ddi '"test.o"'
        rm test.ddi other.ddi
    done
    expect_stat preprocessed_cache_hit 3
    expect_stat cache_miss 3

    # -------------------------------------------------------------------------
    TEST "Relative object file path with base_dir"

    export CCACHE_BASEDIR=$PWD
    for dir in dir1 dir2; do
        mkdir $dir
        cp -p test.cpp $dir
        cd $dir
        $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 \
            -c $PWD/test.cpp -o test.o
        expect_contains test.ddi '"test.o"'
        cd ..
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "Absolute object file path with base_dir"

    # The object file path written in the P1689 file is absolute like without
    # ccache, so it is not shared between directories.
    export CCACHE_BASEDIR=$PWD
    for dir in dir1 dir2; do
        mkdir $dir
        cp -p test.cpp $dir
        cd $dir
        $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 \
            -c $PWD/test.cpp -o $PWD/test.o
        expect_contains test.ddi "\"$(native_path "$PWD")/test.o\""
        cd ..
    done
    expect_stat preprocessed_cache_hit 0
    expect_stat cache_miss 2

    # -------------------------------------------------------------------------
    TEST "Assembler input"

    echo 'nop' >test.s
    for i in 1 2; do
        $CCACHE_COMPILE -MD -fdeps-format=p1689r5 -c test.s
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1
    expect_missing test.ddi

    # -------------------------------------------------------------------------
    TEST "Different object file with -fdeps-target"

    for obj in one two; do
        $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 \
            -fdeps-target=test.o -c test.cpp -o $obj.o
        expect_contains $obj.ddi '"test.o"'
    done
    expect_stat preprocessed_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "Direct mode"

    unset CCACHE_NODIRECT
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 -c test.cpp
        expect_contains test.ddi '"test.o"'
        rm test.ddi
    done
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "Depend mode"

    unset CCACHE_NODIRECT
    export CCACHE_DEPEND=1
    for i in 1 2; do
        $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 -c test.cpp
        expect_contains test.ddi '"test.o"'
        rm test.ddi
    done
    expect_stat direct_cache_hit 1
    expect_stat cache_miss 1

    # -------------------------------------------------------------------------
    TEST "Unsupported options"

    $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=p1689r5 -fdeps-file=- \
        -c test.cpp >/dev/null
    $CCACHE_COMPILE -std=c++20 -MD -fdeps-format=other -c test.cpp \
        2>/dev/null
    expect_stat unsupported_compiler_option 2
}
