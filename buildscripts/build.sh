#!/usr/bin/env bash

set -e
set -u

function usage() {
    echo 1>&2 "build.sh"
    echo 1>&2 "[--git_branch=$git_branch] [--git_tag=$git_tag]"
    echo 1>&2 "[--tokudb=$tokudb] [--svn_revision=$svn_revision]"
    echo 1>&2 "[--cc=$cc --cxx=$cxx] [--ftcc=$ftcc --ftcxx=$ftcxx]"
    echo 1>&2 "[--debugbuild=$debugbuild]"
    return 1
}

function retry() {
    set +e
    local cmd
    local retries
    local exitcode
    cmd=$*
    let retries=0
    while [ $retries -le 10 ] ; do
        echo `date` $cmd
        bash -c "$cmd"
        exitcode=$?
        echo `date` $cmd $exitcode $retries
        let retries=retries+1
        if [ $exitcode -eq 0 ] ; then break; fi
        sleep 10
    done
    set -e
    test $exitcode = 0
}

function get_ncpus() {
    if [ -f /proc/cpuinfo ]; then
        grep bogomips /proc/cpuinfo | wc -l
    else
        sysctl -n hw.ncpu
    fi
}

# check out the fractal tree source from subversion, build it, and make the fractal tree tarballs
function build_fractal_tree() {
    if [ ! -d $tokufractaltreedir ] ; then
        mkdir $tokufractaltreedir

        retry svn export -q -r $svn_revision $svnserver/toku/$tokudb
        retry svn export -q -r $svn_revision $svnserver/$jemalloc
        retry svn export -q -r $svn_revision $svnserver/$xz

        pushd $tokudb
            echo `date` make $tokudb $ftcc $($ftcc --version)
            cmake_env="CC=$ftcc CXX=$ftcxx"
            local build_type=""
            local use_valgrind=""
            local debug_paranoid=""
            if [[ $debugbuild = 1 ]]; then
                build_type="Debug"
                use_valgrind="ON"
                debug_paranoid="ON"
            else
                build_type="Release"
                use_valgrind="OFF"
                debug_paranoid="OFF"
            fi
            mkdir -p build
            cd build
            eval $cmake_env cmake \
                -D LIBTOKUDB=$tokufractaltree \
                -D LIBTOKUPORTABILITY=$tokuportability \
                -D CMAKE_TOKUDB_REVISION=$svn_revision \
                -D CMAKE_BUILD_TYPE=$build_type \
                -D TOKU_SVNROOT=$rootdir \
                -D CMAKE_INSTALL_PREFIX=$rootdir/$tokufractaltreedir \
                -D BUILD_TESTING=OFF \
                -D USE_GTAGS=OFF \
                -D USE_CTAGS=OFF \
                -D USE_ETAGS=OFF \
                -D USE_CSCOPE=OFF \
                -D USE_VALGRIND=$use_valgrind \
                -D TOKU_DEBUG_PARANOID=$debug_paranoid \
                ..
            make install -j$makejobs
        popd

        pushd $tokufractaltreedir/examples
            # test the examples
            sed -ie "s/LIBTOKUDB = tokudb/LIBTOKUDB = $tokufractaltree/" Makefile 
            sed -ie "s/LIBTOKUPORTABILITY = tokuportability/LIBTOKUPORTABILITY = $tokuportability/" Makefile
            if [ x"$(uname)" = x"Darwin" ] ; then
                set +u
                DYLD_LIBRARY_PATH=$PWD/../lib:$DYLD_LIBRARY_PATH make check CC=$ftcc
                set -u
                exitcode=$?
            else
                make check CC=$ftcc
                exitcode=$?
            fi
            echo `date` make check examples $tokufractaltree $exitcode
            make clean
        popd

        # make tarballs
        tar --create \
            --gzip \
            --file $tokufractaltreedir.tar.gz \
            $tokufractaltreedir
        md5sum $tokufractaltreedir.tar.gz >$tokufractaltreedir.tar.gz.md5
        md5sum --check $tokufractaltreedir.tar.gz.md5
    fi
}

# checkout the mongodb source from git, generate a build script, and make the mongodb source tarball
function build_mongodb_src() {
    mongodbsrc=mongodb-$mongodb_version-tokutek-$git_commit-$tokudb-${svn_revision}${suffix}-src
    if [ ! -d $mongodbsrc ] ; then
        # clone mongo
        if [ -d mongo-git ] ; then
            pushd mongo-git
                retry git pull
            popd
        else
            retry git clone \
                --depth 1 \
                $gitserver mongo-git
        fi

        # export the right branch or tag
        pushd mongo-git
            git archive \
                --format=tar \
                --prefix=$mongodbsrc/ \
                --output=$mongodbsrc.tar \
                $treeish
            force_git_version=$(git get-tar-commit-id < $mongodbsrc.tar)
            tar --extract \
                --directory .. \
                --file $mongodbsrc.tar
            rm $mongodbsrc.tar
        popd

        # install the fractal tree
        mkdir $mongodbsrc/src/third_party/tokudb
        tar --extract \
            --gzip \
            --directory $mongodbsrc/src/third_party/tokudb \
            --strip-components 1 \
            --file $tokufractaltreedir.tar.gz

        # make the mongodb src tarball
        tar --create \
            --gzip \
            --file $mongodbsrc.tar.gz \
            $mongodbsrc
        md5sum $mongodbsrc.tar.gz >$mongodbsrc.tar.gz.md5
        md5sum --check $mongodbsrc.tar.gz.md5

        # build mongodb
        pushd $mongodbsrc
            local buildtypeoption=""
            if [[ $debugbuild = 1 ]]; then
                buildtypeoption="--dd"
            else
                buildtypeoption="--release"
            fi
            systemallocatoroption=""
            if [ $(uname -s) = Darwin ] ; then
                systemallocatoroption="--allocator=system"
            fi
            scons $buildtypeoption $systemallocatoroption \
                --force-git-version=$force_git_version \
                -j$makejobs --mute \
                --cc=$cc --cxx=$cxx \
                dist
        popd

        mongodbdir=mongodb-$mongodb_version-tokutek-$git_commit-$tokudb-${svn_revision}${suffix}-$system-$arch

        # copy the release tarball
        mkdir $mongodbdir
        tar --extract \
            --gzip \
            --directory $mongodbdir \
            --strip-components 1 \
            --file $mongodbsrc/mongodb*.tgz
        tar --create \
            --gzip \
            --file $mongodbdir.tar.gz \
            $mongodbdir
        md5sum $mongodbdir.tar.gz >$mongodbdir.tar.gz.md5
        md5sum --check $mongodbdir.tar.gz.md5
    fi
}

PATH=$HOME/bin:$PATH

suffix=''
mongodb_version=2.2.0
git_branch=master
git_tag=''
svn_revision=0
tokudb=tokudb
cc=gcc44
cxx=g++44
ftcc=gcc47
ftcxx=g++47
system=`uname -s | tr '[:upper:]' '[:lower:]'`
arch=`uname -m | tr '[:upper:]' '[:lower:]'`
gitserver=git@github.com:Tokutek/mongo.git
svnserver=https://svn.tokutek.com/tokudb
jemalloc=jemalloc-3.3.0
xz=xz-4.999.9beta
makejobs=$(get_ncpus)
debugbuild=0
staticft=1

if [ $(uname -s) = Darwin ] ; then
    cc=cc
    cxx=c++
    ftcc=cc
    ftcxx=c++
fi

if ! command -v $cc &>/dev/null ; then
    cc=cc
    cxx=c++
fi
if ! command -v $ftcc &>/dev/null ; then
    ftcc=cc
    ftcxx=c++
fi

while [ $# -gt 0 ] ; do
    arg=$1; shift
    if [ $arg = "--gcc44" ] ; then
        cc=gcc44; cxx=g++44
    elif [[ $arg =~ --(.*)=(.*) ]] ; then
        eval ${BASH_REMATCH[1]}=${BASH_REMATCH[2]}
    else
        usage; exit 1;
    fi
done

# Check for scons, the interpreter mongo uses for builds
set +e
command -v scons &>/dev/null
if [ $? != 0 ] ; then
    echo "Need scons to build MongoDB!"
    exit 1;
fi
set -e

if [ "$git_tag"x = ""x ] ; then
    git_commit=$(git ls-remote $gitserver $git_branch | cut -c-7)
    treeish=$git_branch
else
    test $git_branch = master
    git_commit=$git_tag
    treeish=$git_tag
fi

if [[ $debugbuild != 0 && ( -z $suffix ) ]] ; then suffix=-debug; fi

builddir=build-$tokudb-${svn_revision}${suffix}
if [ ! -d $builddir ] ; then mkdir $builddir; fi
pushd $builddir

rootdir=$PWD

# build the fractal tree tarball
tokufractaltree=tokufractaltreeindex-${svn_revision}${suffix}
tokuportability=tokuportability-${svn_revision}${suffix}
tokufractaltreedir=$tokufractaltree-$system-$arch
build_fractal_tree

LIBTOKUDB_NAME=${tokufractaltree}_static
LIBTOKUPORTABILITY_NAME=${tokuportability}_static
export LIBTOKUDB_NAME LIBTOKUPORTABILITY_NAME

# build the mongodb source tarball
build_mongodb_src

popd

exit 0