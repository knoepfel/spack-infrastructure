#!/bin/sh

#
# This script is a bit unorthodox in its control flow
# Basically, we make $SPACK_ROOT/opt/.../.spack/spec.yaml
# files as a side-effect of generating the hash value
# for a given product,version,flavor, and qualifiers
# which actually makes an entry without the hash value
# in the directory, then ask spack about it, and use
# the error message to get the hash value
# Also, we need to generate hashes for dependencies, which
# will make the database directories as we go
#

unpack(){
   set : `echo $1 | sed -e 's/[(),]/ /g'`
   var="$3"
   shift; shift; shift;
   value="$*"
   args="$var $value"
}
unpack_execute(){
   cmd=`echo $1 | sed -e 's/.*(//' -e s/,.*//`
   flags=`echo $1 | sed -e 's/[^,]*,//' -e 's/[),].*//'`
   envvar=`echo $1 | sed -e 's/[^,]*,[^,*]//' -e 's/,//' -e 's/)//'`
}

fix_ups_vars() {
   tline=`echo "$tline" | sed  \
        -e 's;\${UPS_PROD_DIR};'"$prod_dir;g" \
        -e 's;\${UPS_UPS_DIR};'"${prod_dir}/ups;g" \
        -e 's;\${UPS_SOURCE};'"source;g" \
        -e 's;\${SETUPS_DIR};'"${SETUPS_DIR};g" \
        -e 's/\#.*//'` 
}

open_file() {
    test -d $(dirname $1) || mkdir -p $(dirname $1)
    exec 3>$1
}
generate_line() {
   if $generating
   then
       echo "$*" >&3
   fi
}
generate_lines() {
   if $generating
   then
        cat >&3
   else
        cat >/dev/null
   fi
}
close_file() {
    exec 3>&-
}
theirflavor() {
    set : `echo "$1" | sed -e 's/[-+]/ /g'`
    f_os="$2"
    f_osrel="$3"
    f_libc="$4"
    f_dist="$5"
    if [ "$f_os" = "NULL" ]
    then
        # if its null flavored, we override it below because
        # spack doesn't belive in null flavors...
        f_os=''
    fi
    set : `ups flavor | sed -e 's/[-+]/ /g'`
    f_os="${f_os:-$2}"
    f_osrel="${f_osrel:-$3}"
    f_libc="${f_libc:-$4}"
    f_dist="${f_dist:-$5}"
    tf_1=`echo ${f_os}| tr '[A-Z]' '[a-z]' | sed -e 's/64bit//'`
    tf_2=`echo ${f_osrel}-${f_libc} | 
      sed \
        -e 's/13-.*/mavericks/' \
        -e 's/14-.*/yosemite/' \
        -e 's/15-.*/elcapitan/' \
        -e 's/16-.*/sierra/' \
        -e 's/17-.*/highsierra/' \
        -e 's/18-.*/mojave/'\
        -e 's/.*-2.17/scientific7/' \
        -e 's/.*-2.12/scientific6/' \
        -e's/.*-2.5/scientific5/' \
        `

    if [ "x$override_os" != "x" ]
    then
        tf_2=$override_os
    fi

    case "x$f_os" in
    x*64bit) tf_3=x86_64;;
    *) tf_3=i386;;
    esac

    echo "${tf_1}-${tf_2}-${tf_3}"
}

guess_compiler() {
   case "${1}-${2}" in
   *c2*)  echo "clang 5.0.1";;
   *e17*) echo "gcc 7.3.0";;
   *e15*) echo "gcc 6.4.0";;
   *e14*) echo "gcc 6.3.0";;
   *e10*) echo "gcc 4.9.3";;
   *e7*)  echo "gcc 4.9.2";;
   *e6*)  echo "gcc 4.9.1";;
   *e5*)  echo "gcc 4.8.2";;
   *e4*)  echo "gcc 4.8.1";;
   *2.17*) echo "gcc 4.8.5";;
   *2.12*) echo "gcc 4.4.7";;
   *)  echo "gcc 4.1.1";;
   esac
}

make_spec() {
   # make a spec file 
   # args:
   # $1-prod $2-ver $3-flav $4-qual $4-theirflav $5-compiler $6-compiler_version
   #
   # at the moment this makes a minimal spec file so that
   # spack will know the package exists, and then renames the
   # directory with a hash so spack can find it.
   # it probably is getting details wrong -- i.e not setting 
   # cflags, etc.
   #
   prod=$1
   ver=$2
   flav=$3
   qual=$4
   theirflav=$5
   compiler=$6
   cver=$7
   recipedir=${SPACK_ROOT}/var/spack/repos/builtin/packages/${prod}
   basedir=${SPACK_ROOT}/opt/spack/$theirflav/$compiler-$cver/$prod-$ver
   Prod=`echo ${prod} | sed -r -e 's/(.)/\U\1/'`

   # need a recipe
   test -d ${recipedir} || mkdir -p ${recipedir}
   test -r ${recipedir}/package.py || printf "from spack import *\n\nclass ${Prod}(AutotoolsPackage):\n   pass\n" > ${recipedir}/package.py 

   # need a directory-db spec.yaml file
   mkdir -p ${basedir}/.spack
   set : `echo $theirflav| sed -e 's/-/ /g'`
   export specfile=${basedir}/.spack/spec.yaml.new
   echo "spec:" > $specfile
   cat >> $specfile <<EOF
- $prod:
    version: $ver
    arch:
      platform: $2
      platform_os: $3
      target: $4
    compiler:
      name: $compiler
      version: $cver
    namespace: builtin
    parameters:
      cflags: []
      cppflags: []
      cxxflags: []
      fflags: []
      ldflags: []
      ldlibs: []
EOF
   if [ `ups depend $prod $ver -f $flav -q "$qual" | wc -l` != 1 ]
   then
       echo "    dependencies:" >> $specfile
   fi
   # list immediate dependencies
   export first=true
   ups depend $prod $ver -f $flav -q "$qual" |
       grep '^\|__[a-z]' |
       sed -e 's/^[|_ ]*//' |
       while read dprod dver fflag dflav qflag dquals drest
       do
           if $first
           then
               first=false
               continue
           fi
           if [ "x$qflag" != "x-q" ]
           then
               dquals=""
           fi
           dhash=`get_hash "$dprod" "$dver" "$dflav" "$dquals" $compver`
           printf "      %s:\n        hash: %s\n        type:\n          -build\n          -link\n" $dprod $dhash >> $specfile
           
           # also add to recipe...
           printf "    depends_on('%s', type=('build','run'))\n" >> ${recipedir}/package.py 
       done

   export first=true
   # add entry for all dependencies
   ups depend $prod $ver -f $flav |
       sed -e 's/^[|_ ]*//' | 
       while read dprod dver fflaog dflav qflag dquals drest
       do
           if $first
           then
               first=false
               continue
           fi
           if [ "x$qflag" != "x-q" ]
           then
               dquals=""
           fi
           hash=`get_hash "$dprod" "$dver" "$dflav" "$dquals" $compver`
           cat >> $specfile <<EOF
- $dprod:
    version: $dver
    arch:
      platform: $2
      platform_os: $3
      target: $4
    compiler:
      name: $compiler
      version: $cver
    namespace: builtin
    parameters:
      cflags: []
      cppflags: []
      cxxflags: []
      fflags: []
      ldflags: []
      ldlibs: []
    hash: $hash
EOF
       done

   mv $specfile ${basedir}/.spack/spec.yaml

    # kluge alert, get hash from error message from reindex..
    # note: real spec files have the hash in the file, but we don't
    #       seem to need it to set it up so...

    hash=`spack reindex 2>&1 | 
       grep 'No such file or directory' | 
       sed -e "s/'//g" -e 's/.*-//' `
 
    if [ "x$hash" != "x" ]
    then
        echo "$prod:$ver:$flav:$qual:$theirflav:$hash" >> $cache_file
        mv ${basedir} ${basedir}-${hash}
    fi
    
    spack reindex

    echo $hash
}

get_hash() {
    theirflav=`theirflavor "$3"`
    hash=`grep "^$1:$2:$3:$4:$theirflav" $cache_file | sed -e 's/.*://'`
    if [ "x$hash" = "x" ]
    then 
        hash=`make_spec "$1" "$2" "$3" "$4" "$theirflav" $5 $6`
    fi
    echo "$hash"
}
 
#
# main script
#
while :; do case "x$1" in
x-o) override_os="$2" ; shift; shift;;
x*)  break;;
esac; done

export cache_file=${SPACK_ROOT}/var/ups_to_spack.cache
export generating=false

# -- python conversion to here
export base=${SPACK_ROOT}/share/spack/modules 

ups list -Kproduct:version:flavor:qualifiers:@prod_dir:@table_file "$@" |
while read line
do

eval set $line
export product="$1"
export version="$2"
export flavor="$3"
export quals="$4"
export prod_dir="$5"
export table_file="$6"

theirflav=`theirflavor "$flavor"`
compver=`guess_compiler "${flavor}-${quals}"`
ver=`echo $version| sed -e 's/^[vb]//' -e 's/_/./g'`
export compver

hash=`get_hash $product $version $flavor "$quals" $compver`
shorthash=`echo $hash | sed -e 's/\(.......\).*/\1/'`
compdashver=`echo $compver | sed -e 's/ /-/'`

modulefile=${base}/${theirflav}/${product}-${version}-${compdashver}-${shorthash}

export PRODNAME_UC=`echo $product | tr '[a-z]' '[A-Z]'`

# XXX needs to get qualifers from command line and  ignore wrong qualifier sections...

echo "converting $table_file:" 

in_action=false
cat $table_file |
(

open_file $modulefile

generating=true
generate_line "#%Module1.0"
generate_line ""
generate_line "# $product modulefile"
generate_line "# generated by $0"
generate_line ""
generate_line "set version $version"
generate_line "set prefix  $prod_dir"
generate_line ""

generating=false

while read tline
do
  #generate_line "#convert-line: $tline" 
  fix_ups_vars
  case "$tline" in
  *Flavor*=*ANY|*FLAVOR*=*ANY)
     flavorok=true
     ;;
  *Flavor*=*$flavor|*FLAVOR*=$flavor)
     flavorok=true
     ;;
  *Flavor*=*|*FLAVOR*=*)
     flavorok=false
     ;;
  *Qualifiers*=*$quals|*QUALIFIERS*=*$quals)
     if $flavorok
     then
         generating=true
     else
         generating=false
     fi
     ;;
  *Qualifiers*=*|*QUALIFIERS*=*)
     generating=false
     ;;
  *common:*|*COMMON:*)
     generating=true
     ;;
  *[Aa]ction=*|*ACTION=*)
       if $in_action
       then
          generate_line "}" 
       fi
       in_action=true
       name=`echo $tline| sed -e 's/.*=//'`
       generate_line "proc $name {} {" 
       ;;
  *[Ee]xe[Aa]ction*)
       unpack "$tline"
       $in_action && generate_line "$var" 
       ;;
  *proddir\(\)*|*doDefaults*)
       $in_action && generate_line "setenv ${PRODNAME_UC}_DIR $prod_dir" 
       ;;
  *envSet\(*)
       unpack "$tline"
       $in_action && generate_line "setenv $var {$value}" 
       ;;
  *[pP]ath[Pp]repend*|*[Ee]nv[Pp]repend*)
       generate_line "#saw prepend: $tline " 
       unpack "$tline"
       $in_action && generate_line "prepend-path $var {$value}" 
       ;;
  *[Ss]etup[Rr]equired*|*[Ss]etup[Oo]ptional*)
       unpack "$tline"
       $in_action && generate_line "module load $args" 
       ;;
  *add[Aa]lias*)
       unpack "$tline"
       $in_action && generate_line "set-alias $var {$value}" 
       ;;
  *[Ee]xecute*)
       unpack_execute "$tline"
       if [ "$flag" = "UPS_ENV" ]
       then
           $in_action && generate_line "setenv UPS_PROD_NAME {$prod}" 
           $in_action && generate_line "setenv UPS_PROD_DIR {$prod_dir}" 
           $in_action && generate_line "setenv UPS_UPS_DIR {$prod_dir}/ups" 
           $in_action && generate_line "setenv VERSION {$version}/ups" 
       fi
       if [ -z "$envvar" ]
       then
           $in_action && generate_line "setenv $envvar [exec $cmd]" 
       else
           $in_action && generate_line "exec $cmd" 
       fi
       ;;
  *EndIf*)
       $in_action && generate_line "}" 
       ;;
  *Else*)
       $in_action && generate_line "} else {" 
       ;;
  *If*)
       unpack "$tline"
       $in_action && generate_line "if {![catch {exec $args} results options]} {" 
       ;;
  *[Ss]etup[Rr]equired*|*[Ss]etup[Oo]ptional*)
       unpack "$tline"
       add_dep_to_spec $args
       ;;
  *[Ee]nd*|*END*)
       if $in_action
       then
          generate_line "}" 
       fi
       in_action=false
       ;;
  esac
done

generating=true

if $in_action
then
  generate_line "}" 
fi

generate_line "setup" 

)

close_file

generating=false

done