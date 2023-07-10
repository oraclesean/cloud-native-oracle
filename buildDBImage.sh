#!/usr/bin/env bash

# Automate dynamic image builds

. ./functions.sh

getEdition() {
  # Set variables based on edition. 
  case $ORACLE_EDITION in
       EE)  export ORACLE_EDITION_ARG="EE" ;;
       SE*) export ORACLE_EDITION_ARG="SE" ;;
       XE)  export ORACLE_EDITION_ARG="XE"
            export INSTALL_RESPONSE_ARG="oracle-${ORACLE_VERSION}-${ORACLE_EDITION}.conf"
            export ORACLE_BASE_CONFIG_ARG="###"
            export ORACLE_BASE_CONFIG_ENV="###"
            export ORACLE_BASE_HOME_ARG="###"
            export ORACLE_BASE_HOME_ENV="###"
            export ORACLE_READ_ONLY_HOME_ARG="###"
            export ORACLE_ROH_ENV="###"
            # Perform conditional setup by version.
            case $ORACLE_VERSION in
                 11.2.0.2) export ORACLE_HOME_ARG="11.2.0/xe" ;;
                 18.4)     export MIN_SPACE_GB_ARG=13
                           export ORACLE_HOME_ARG="18c/dbhomeXE"
                           export ORACLE_PDB_ARG="ARG ORACLE_PDB=XEPDB"
                           export ORACLE_RPM_ARG="ARG ORACLE_RPM=\"https://download.oracle.com/otn-pub/otn_software/db-express/oracle-database-xe-18c-1.0-1.x86_64.rpm\""
                           ;;
                 *)        error "Selected version ($ORACLE_VERSION) is not available for Express Edition" ;;
            esac ;;
       *)   error "Invalid edition name ($ORACLE_EDITION) provided" ;;
  esac
}

getVersion() {
  # Set defaults
  DOCKER_RUN_LABEL="-e PDB_COUNT=<PDB COUNT> -e ORACLE_PDB=<PDB PREFIX> "
  INSTALL_RESPONSE_ARG="$ORACLE_VERSION"
  MIN_SPACE_GB_ARG=12
  ORACLE_SID_ARG="ORCLCDB"
  ORACLE_HOME_ARG="${ORACLE_VERSION}/dbhome_1"
  ORACLE_BASE_CONFIG_ARG="ARG ORACLE_BASE_CONFIG=\$ORACLE_BASE/dbs"
  ORACLE_BASE_CONFIG_ENV="ORACLE_BASE_CONFIG=\$ORACLE_BASE_CONFIG \\\\"
  ORACLE_BASE_HOME_ARG="ARG ORACLE_BASE_HOME=\$ORACLE_BASE/homes"
  ORACLE_BASE_HOME_ENV="ORACLE_BASE_HOME=\$ORACLE_BASE_HOME \\\\"
  ORACLE_PDB_ARG="ARG ORACLE_PDB="
  ORACLE_PDB_ENV="ORACLE_PDB=\$ORACLE_PDB \\\\"
  ORACLE_READ_ONLY_HOME_ARG="ARG ROOH="
  ORACLE_ROH_ENV="ROOH=\$ROOH \\\\"
  ORACLE_RPM_ARG=""
  PDB_COUNT_ARG="ARG PDB_COUNT=1"
  PDB_COUNT_ENV="PDB_COUNT=\$PDB_COUNT \\\\"

    if [ "$ORACLE_VERSION" == "11.2.0.2" ] || [ "$ORACLE_VERSION" == "18.4" ]
  then ORACLE_EDITION="XE"
  fi

  case $ORACLE_VERSION in
       11*)     export ORACLE_BASE_VERSION="$ORACLE_VERSION"
                export DOCKER_RUN_LABEL=""
                export ORACLE_BASE_CONFIG_ARG="###"
                export ORACLE_BASE_CONFIG_ENV="###"
                export ORACLE_BASE_HOME_ARG="###"
                export ORACLE_BASE_HOME_ENV="###"
                export ORACLE_PDB_ARG="###"
                export ORACLE_PDB_ENV="###"
                export ORACLE_READ_ONLY_HOME_ARG="###"
                export ORACLE_SID_ARG=ORCL
                export PDB_COUNT_ARG="###"
                export PDB_COUNT_ENV="###"
                export PCB_COUNT_LABEL="###"
                export PREINSTALL_TAG="11g"
                ;;
       12*)     export ORACLE_BASE_VERSION="$ORACLE_VERSION"
                export ORACLE_BASE_CONFIG_ARG="###"
                export ORACLE_BASE_CONFIG_ENV="###"
                export ORACLE_BASE_HOME_ARG="###"
                export ORACLE_BASE_HOME_ENV="###"
                export ORACLE_READ_ONLY_HOME_ARG="###"
                export PREINSTALL_TAG="$ORACLE_VERSION"
                ;;
       18*)     export ORACLE_BASE_VERSION="$ORACLE_VERSION"
                export PREINSTALL_TAG="${ORACLE_BASE_VERSION}c"
                export ORACLE_HOME_ARG="${PREINSTALL_TAG}/dbhome_1"
                ;;
       19*|21*) export ORACLE_BASE_VERSION=${ORACLE_VERSION:0:2}
                export INSTALL_RESPONSE_ARG="$ORACLE_BASE_VERSION"
                export PREINSTALL_TAG="${ORACLE_BASE_VERSION}c" 
                export ORACLE_HOME_ARG="${PREINSTALL_TAG}/dbhome_1"
                ;;
       *)       error "Invalid version ($ORACLE_VERSION) provided" ;;
  esac

    if [ -n "$SYSTEMD" ]
  then local __tag="${S_TAG}-sysd"
       export DB_REPO="${DB_REPO}-sysd"
       export systemd="--build-arg SYSTEMD=Y"
       export SYSTEMD_VOLUME="VOLUME [ \"/sys/fs/cgroup\" ]"
  else local __tag="$S_TAG"
  fi
  LINUX_IMAGE="${SOURCE}:${__tag}-${PREINSTALL_TAG}"
}

getImage() {
  docker images --filter=reference="${LINUX_IMAGE}" --format "{{.Repository}}:{{.Tag}}"
}

setBuildKit() {
  # Check whether Docker Build Kit is available; version must be 18.09 or greater.
  version=$(docker --version | awk '{print $3}')
  major_version=$((10#$(echo "$version" | cut -d. -f1)))
  minor_version=$((10#$(echo "$version" | cut -d. -f2)))
  BUILDKIT=0
  export MOS_SECRET=""

    if [ "$major_version" -gt 18 ] || [ "$major_version" -eq 18 -a "$minor_version" -gt 9 ]
  then BUILDKIT=1
       MOS_CRED_FQ=${MOS_CRED_FN:-./config/.netrc}
       MOS_CRED_FN=$(basename "$MOS_CRED_FQ")
         if [ -f "$MOS_CRED_FQ" ]
       then export MOS_SECRET="--mount=type=secret,id=netrc,mode=0600,uid=54321,gid=54321,dst=/home/oracle/$MOS_CRED_FN"
            DB_BUILD_OPTIONS=("${DB_BUILD_OPTIONS[@]}" --secret id=netrc,src="$MOS_CRED_FQ")
            #DB_BUILD_OPTIONS="$DB_BUILD_OPTIONS --secret id=netrc,src=$MOS_CRED_FQ"
       fi
  fi
}

createDockerfiles() {
  dockerfile=$(mktemp ./Dockerfile."$1"."$(date '+%Y%m%d%H%M')".XXXX)
  dockerignore=${dockerfile}.dockerignore

  chmod 664 "$dockerfile"
  # If FROM_BASE is set it means there was no existing oraclelinux image tagged
  # with the DB version. Create a full Dockerfile to build the OS, otherwise use
  # the existing image to save time.
  cat ./templates/"$1".dockerfile > "$dockerfile"
  cat ./templates/"$1".dockerignore > "$dockerignore"
}

addException() {
  case $2 in
       database) local __path="database" ;;
       patch)    local __path="database/patches" ;;
       asset)    local __path="config" ;;
  esac
       printf '!/%s/%s\n' "$__path" "$1" >> "$dockerignore"
}

processManifest() {
    if [ -f ./config/manifest ]
  then
       # Get the correct architecture.
       # Use `uname -m | sed -e 's/_/\./g' -e 's/-/\./g'` replaces underscores (_) and dashes (-)
       # with the wildcard and matches both "x86_64" and "x86-64".
       grep -i "$(uname -m | sed -e 's/_/\./g' -e 's/-/\./g')" ./config/manifest | grep -ve "^#" | awk '{print $1,$2,$3,$4,$5}' | while IFS=" " read -r checksum filename filetype version extra
          do
               if [ "$filetype" == "database" ] && [ "$version" == "$ORACLE_BASE_VERSION" ] && [ -f ./database/"$filename" ] && [ -z "$edition" ]
             then case $1 in
                  ignore) addException "$filename" database ;;
                  label)  sed -i '' -e "s/^###SOFTWARE_LABEL###/&\nLABEL database.software.${version}=\"Edition=${extra}, Version=${version}, File=${filename}, md5sum=${checksum}\"\n/" "$dockerfile" ;;
                  esac
             elif [ "$filetype" == "database" ] && [ "$version" == "$ORACLE_BASE_VERSION" ] && [ -f ./database/"$filename" ] && [[ $edition =~ $ORACLE_EDITION ]]
             then case $1 in
                  ignore) addException "$filename" database ;;
                  label)  sed -i '' -e "s/^###SOFTWARE_LABEL###/&\nLABEL database.software.${version}=\"Edition=${extra}, Version=${version}, File=${filename}, md5sum=${checksum}\"\n/" "$dockerfile" ;;
                  esac
             elif [ "$filetype" == "opatch" -o "$filetype" == "patch" ] && [ "$version" == "$ORACLE_BASE_VERSION" -o "$version" == "$ORACLE_VERSION" ] && [ -f ./database/patches/"$filename" ]
             then case $1 in
                  ignore) addException "$filename" patch ;;
                  label)  sed -i '' -e "s/^###SOFTWARE_LABEL###/&\nLABEL database.patch.${extra}=\"Patch ID=${extra}, Version=${version}, File=${filename}, md5sum=${checksum}\"\n/" "$dockerfile" ;;
                  esac
             fi
        done
  fi
}

processDockerfile() {
   for var in DB_REPO \
              DOCKER_RUN_LABEL \
              FROM_BASE \
              FROM_OEL_BASE \
              INSTALL_RESPONSE_ARG \
              LINUX_IMAGE \
              MIN_SPACE_GB_ARG \
              MOS_SECRET \
              ORACLE_BASE_CONFIG_ARG \
              ORACLE_BASE_CONFIG_ENV \
              ORACLE_BASE_HOME_ARG \
              ORACLE_BASE_HOME_ENV \
              ORACLE_BASE_VERSION \
              ORACLE_EDITION_ARG \
              ORACLE_HOME_ARG \
              ORACLE_PDB_ARG \
              ORACLE_PDB_ENV \
              ORACLE_READ_ONLY_HOME_ARG \
              ORACLE_ROH_ENV \
              ORACLE_RPM_ARG \
              ORACLE_SID_ARG \
              ORACLE_VERSION \
              PDB_COUNT_ARG \
              PDB_COUNT_ENV \
              PREINSTALL_TAG \
              SYSTEMD_VOLUME
           do REPIFS=$IFS
              IFS=
              replaceVars "$1" "$var"
              IFS=$REPIFS
         done

  # Insert labesl for each patch in apply order.
  processManifest label

  # Remove unset lines
  sed -i '' -e '/###$/d' "$1"
}

removeDockerfile () {
    if [ -z "$RM_DOCKERFILE" ]
  then rm "$1" "$2"
  fi
}

usage () {
  echo " Usage: $0 [options]"
  echo " "
  echo " Options: "
  echo "        --build-arg stringArray     Set build-time variables "
  echo "    -d, --debug                     Turn on build debugging "
  echo "    -e, --edition string            Set the database edition "
  echo "                                        EE: Enterprise Edition (Default) "
  echo "                                        SE: Standard Edition "
  echo "                                        XE: Express Edition (Versions 11.2.0.2, 18.4, 23.1.0 only) "
  echo "        --force-patch string        Force patch download from MOS "
  echo "                                        all: Re-download all patches during install "
  echo "                                        opatch: Re-download opatch only "
  echo "                                        patch: Re-download patches but not opatch "
  echo "        --force-rm                  Force-remove build cache "
  echo "    -k, --dockerfile-keep           Keep the dynamically generated Dockerfile after build completion "
  echo "    -n, --image-name string         Repository name for the completed image (Default: oracle/db) "
  echo "        --no-cache                  Do not use cache when building the image "
  echo "        --no-sum                    Do not perform file checksums "
  echo "        --progress string           Display build progress "
  echo "                                        auto (Default) "
  echo "                                        plain: Show container output "
  echo "                                        tty: Show abbreviated output "
  echo "        --prune-cache               Prune build cache on success "
  echo "    -q, --quiet                     Suppress build output "
  echo "    -r, --force-rebuild             Force rebuild the base Linux image if it exists "
  echo "        --read-only-home            Configure a Read-Only Oracle Home "
  echo "        --remove-components string  Comma-delimited list of components to remove "
  echo "                                    Options: DBMA,HELP,ORDS,OUI,PATCH,PILOT,SQLD,SUP,UCP,TCP,ZIP "
  echo "                                    Default is all of the above "
  echo "        --rpm stringArray           Comma-delimited list of binaries/libraries to install "
  echo "                                        Default: bash-completion,git,less,strace,tree,vi,which "
  echo "        --secret string             File name containing MOS credentials for patch download "
  echo "    -S, --source-image string       Source OS image repository (Default: oraclelinux) "
  echo "    -T, --source-tag string         Source OS tag (Default: 8-slim) "
  echo "    -t, --tag string                Tag for the completed image (Default: [ORACLE_VERSION]-[ORACLE_EDITION]) "
  echo "    -v, --version string            Oracle Database version (Default: 19.19) "
  echo "                                    The version must exist in the manifest file within the ./config directory "
  echo "    -h, --help                      This menu "
  echo " "
  exit "$1"
}

  if [ -n "$*" ] && [[ $(getopt -V) =~ -- ]]
then # The system must be using GNU-getopt to process command line parameters. This is not the default on MacOS.
     error "An incompatible version of getopt is installed. Cannot process parameters."
elif [ -n "$*" ] # Only process command line parameters if options were passed.
then OPTS=de:hkn:qeS:t:T:v:
     OPTL=build-arg:,debug,dockerfile-keep,edition:,force-patch,force-rebuild,force-rm,help,image-name:,no-cache,no-sum,progress:,prune-cache,quiet,read-only-home,remove-components:,rpm:,secret:,source-image:,source-tag:,tag:,version:
     ARGS=$(getopt -a -o $OPTS -l $OPTL -- "$@") || usage 1
     eval set -- "$ARGS"
     while :
        do
           case "$1" in
                     --build-arg         ) BUILD_OPTIONS=("${BUILD_OPTIONS[@]}" --build-arg "$2"); shift 2 ;;
                -d | --debug             ) BUILD_OPTIONS=("${BUILD_OPTIONS[@]}" --build-arg DEBUG="bash -x"); shift ;;
                -e | --edition           ) case "${2^^}" in
                                                EE | SE | XE         ) ORACLE_EDITION="${2^^}" ;;
                                                *                    ) error "-e/--edition must be one of EE, SE, or XE" ;;
                                           esac
                                           shift 2 ;;
                     --force-patch       ) case "${2,,}" in
                                                all | opatch | patch ) DB_BUILD_OPTIONS=("${DB_BUILD_OPTIONS[@]}" --build-arg FORCE_PATCH="${2,,}") ;;
                                                *                    ) error "--force-patch must be one of all, opatch, or patch" ;;
                                           esac
                                           shift 2 ;;
                     --force-rm          ) BUILD_OPTIONS=("${BUILD_OPTIONS[@]}" --force-rm=true); shift ;;
                -k | --dockerfile-keep   ) RM_DOCKERFILE=1; shift ;;
                -n | --image-name        ) TARGET="$2"; shift 2 ;;
                     --no-cache          ) BUILD_OPTIONS=("${BUILD_OPTIONS[@]}" --no-cache=true); shift ;;
                     --no-sum            ) DB_BUILD_OPTIONS=("${DB_BUILD_OPTIONS[@]}" --build-arg SKIP_MD5SUM=1); shift ;;
                     --progress          ) case "${2,,}" in
                                                auto | plain | tty   ) BUILD_OPTIONS=("${BUILD_OPTIONS[@]}" --progress "$2") ;;
                                                *                    ) error "--progress must be one of auto, plain, or tty" ;;
                                           esac
                                           shift 2 ;;
                     --prune-cache       ) PRUNE_CACHE=1; shift ;;
                -q | --quiet             ) BUILD_OPTIONS=("${BUILD_OPTIONS[@]}" --quiet); shift ;;
                -r | --force-rebuild     ) FORCE_REBUILD=1; shift ;;
                     --read-only-home    ) DB_BUILD_OPTIONS=("${DB_BUILD_OPTIONS[@]}" --build-arg ROOH=ENABLE); shift ;;
                     --remove-components ) DB_BUILD_OPTIONS=("${DB_BUILD_OPTIONS[@]}" --build-arg REMOVE_COMPONENTS="$2"); shift 2 ;;
                     --rpm               ) OS_BUILD_OPTIONS=("${OS_BUILD_OPTIONS[@]}" --build-arg RPM_LIST="${2//,/ }"); shift 2 ;;
                     --secret            )   if [ -f "$2" ]
                                           then MOS_CRED_FQ="$2"
                                           else error "Credential file $2 not found"
                                           fi
                                           shift 2 ;;
                -S | --source-image      ) SOURCE="$2"; shift 2 ;;
                -T | --source-tag        ) S_TAG="$2"; shift 2 ;;
                -t | --tag               ) T_TAG="$2"; shift 2 ;;
                -v | --version           ) ORACLE_VERSION="$2"; shift 2 ;;
                -h | --help              ) usage 0 ;;
                     --                  ) shift; break ;;
                *                        ) usage 1 ;;
           esac
      done
fi

# Set defaults for version, edition, tag and source:
ORACLE_VERSION=${ORACLE_VERSION:-19.19}
ORACLE_EDITION=${ORACLE_EDITION:-EE}
SOURCE=${SOURCE:-oraclelinux}
S_TAG=${S_TAG:-8-slim}
TARGET=${TARGET:-oracle/db}
T_TAG=${T_TAG:-${ORACLE_VERSION}-${ORACLE_EDITION}}

getVersion
getEdition
setBuildKit

# Set build arguments
export SOURCE_IMAGE="$SOURCE":"$S_TAG"
export TARGET_IMAGE="$TARGET":"$T_TAG"

## Set systemd options
#  if [ -n "$SYSTEMD" ]
#then OS_BUILD_OPTIONS=("${OS_BUILD_OPTIONS[@]}" --build-arg SYSTEMD=Y)
#fi

  if [ -z "$(getImage)" ] || [ -n "$FORCE_REBUILD" ]
then # There is no base image or FORCE_BUILD is set: Create a base image.
     export FROM_BASE="FROM $SOURCE_IMAGE as base"
     FROM_OEL_BASE="base"
     createDockerfiles oraclelinux || error "There was a problem creating the Dockerfiles"
     processDockerfile "$dockerfile"
     BUILD_OPTIONS=("${BUILD_OPTIONS[@]}" --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')")

     # Run the build
     DOCKER_BUILDKIT=$BUILDKIT docker build "${OS_BUILD_OPTIONS[@]}" \
                              "${BUILD_OPTIONS[@]}" \
                              -t "$LINUX_IMAGE" \
                              -f "$dockerfile" . && removeDockerfile "$dockerfile" "$dockerignore"
fi

FROM_OEL_BASE="$(getImage)"; export FROM_OEL_BASE
createDockerfiles db || error "There was a problem creating the Dockerfiles"
processDockerfile "$dockerfile"
BUILD_OPTIONS=("${BUILD_OPTIONS[@]}" --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')")

# Add exceptions to the ignore file
  if [ "$ORACLE_BASE_VERSION" != "$ORACLE_VERSION" ]
then addException "*.${ORACLE_BASE_VERSION}.rsp" asset
     addException "*.${ORACLE_BASE_VERSION}" asset
else addException "*.${ORACLE_VERSION}.rsp" asset
     addException "*.${ORACLE_VERSION}" asset
fi
processManifest ignore

DOCKER_BUILDKIT=$BUILDKIT docker build "${DB_BUILD_OPTIONS[@]}" \
                         "${BUILD_OPTIONS[@]}" \
                         -t "$TARGET_IMAGE" \
                         -f "$dockerfile" . && removeDockerfile "$dockerfile" "$dockerignore"; docker images

  if [ -n "$PRUNE_CACHE" ]
then logger "Pruning build cache"
     logger "Space use before:"
     docker system df
     logger " "
     docker builder prune -f
     logger "Space use after:"
     docker system df
fi
