# Automate dynamic image builds

# Set defaults for version, edition, tag and source:
ORACLE_VERSION=${1:-19.19}
ORACLE_EDITION=${2:-EE}
TAG=${3:-8-slim}
SOURCE=${4:-oraclelinux}
DB_REPO=${5:-oraclesean/db}
MOS_SECRET=${6:-$PWD/config/.netrc}

. ./functions.sh

getEdition() {
  # Set variables based on edition. 
  case $ORACLE_EDITION in
       EE)  ORACLE_EDITION_ARG="EE" ;;
       SE*) ORACLE_EDITION_ARG="SE" ;;
       XE)  ORACLE_EDITION_ARG="XE"
            INSTALL_RESPONSE_ARG="oracle-${ORACLE_VERSION}-${ORACLE_EDITION}.conf"
            ORACLE_BASE_CONFIG_ARG="###"
            ORACLE_BASE_CONFIG_ENV="###"
            ORACLE_BASE_HOME_ARG="###"
            ORACLE_BASE_HOME_ENV="###"
            ORACLE_READ_ONLY_HOME_ARG="###"
            ORACLE_ROH_ENV="###"
            # Perform conditional setup by version.
            case $ORACLE_VERSION in
                 11.2.0.2) ORACLE_HOME_ARG="11.2.0/xe" ;;
                 18.4)     MIN_SPACE_GB_ARG=13
                           ORACLE_HOME_ARG="18c/dbhomeXE"
                           ORACLE_PDB_ARG="ARG ORACLE_PDB=XEPDB"
                           ORACLE_RPM_ARG="ARG ORACLE_RPM=\"https://download.oracle.com/otn-pub/otn_software/db-express/oracle-database-xe-18c-1.0-1.x86_64.rpm\""
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
       11*)     ORACLE_BASE_VERSION="$ORACLE_VERSION"
                DOCKER_RUN_LABEL=""
                ORACLE_BASE_CONFIG_ARG="###"
                ORACLE_BASE_CONFIG_ENV="###"
                ORACLE_BASE_HOME_ARG="###"
                ORACLE_BASE_HOME_ENV="###"
                ORACLE_PDB_ARG="###"
                ORACLE_PDB_ENV="###"
                ORACLE_READ_ONLY_HOME_ARG="###"
                ORACLE_SID_ARG=ORCL
                PDB_COUNT_ARG="###"
                PDB_COUNT_ENV="###"
                PCB_COUNT_LABEL="###"
                PREINSTALL_TAG="11g"
                ;;
       12*)     ORACLE_BASE_VERSION="$ORACLE_VERSION"
                ORACLE_BASE_CONFIG_ARG="###"
                ORACLE_BASE_CONFIG_ENV="###"
                ORACLE_BASE_HOME_ARG="###"
                ORACLE_BASE_HOME_ENV="###"
                ORACLE_READ_ONLY_HOME_ARG="###"
                PREINSTALL_TAG="$ORACLE_VERSION"
                ;;
       18*)     ORACLE_BASE_VERSION="$ORACLE_VERSION"
                PREINSTALL_TAG="${ORACLE_BASE_VERSION}c"
                ORACLE_HOME_ARG="${PREINSTALL_TAG}/dbhome_1"
                ;;
       19*|21*) ORACLE_BASE_VERSION=${ORACLE_VERSION:0:2}
                INSTALL_RESPONSE_ARG="$ORACLE_BASE_VERSION"
                PREINSTALL_TAG="${ORACLE_BASE_VERSION}c" 
                ORACLE_HOME_ARG="${PREINSTALL_TAG}/dbhome_1"
                ;;
       *)       error "Invalid version ($ORACLE_VERSION) provided" ;;
  esac

    if [ -n "$SYSTEMD" ]
  then local __tag="${TAG}-sysd"
       DB_REPO="${DB_REPO}-sysd"
       systemd="--build-arg SYSTEMD=Y"
       SYSTEMD_VOLUME="VOLUME [ \"/sys/fs/cgroup\" ]"
  else local __tag="$TAG"
  fi
  OEL_IMAGE="${SOURCE}:${__tag}-${PREINSTALL_TAG}"
}

getImage() {
  docker images --filter=reference="${OEL_IMAGE}" --format "{{.Repository}}:{{.Tag}}"
}

setBuildKit() {
  # Check whether Docker Build Kit is available; version must be 18.09 or greater.
  version=$(docker --version | awk '{print $3}')
  major_version=$((10#$(echo $version | cut -d. -f1)))
  minor_version=$((10#$(echo $version | cut -d. -f2)))

    if [ "$major_version" -gt 18 ] || [ "$major_version" -eq 18 -a "$minor_version" -gt 9 ]
  then BUILDKIT=1
         if [ -f "$MOS_SECRET" ]
       then MOS_SECRET="--mount=type=secret,id=netrc,mode=0600,uid=54321,gid=54321,dst=/home/oracle/.netrc"
            secrets="--secret id=netrc,src=./config/.netrc"
       else MOS_SECRET=""
       fi
  else BUILDKIT=0
       MOS_SECRET=""
  fi
}

createDockerfiles() {
  dockerfile=$(mktemp ./Dockerfile.$1.$(date '+%Y%m%d%H%M').XXXX)
  dockerignore=${dockerfile}.dockerignore

  chmod 664 $dockerfile
  # If FROM_BASE is set it means there was no existing oraclelinux image tagged
  # with the DB version. Create a full Dockerfile to build the OS, otherwise use
  # the existing image to save time.
  cat ./templates/$1.dockerfile > $dockerfile
  cat ./templates/$1.dockerignore > $dockerignore
}

addException() {
  case $2 in
       database) local __path="database" ;;
       patch)    local __path="database/patches" ;;
       asset)    local __path="config" ;;
  esac
       printf '!/%s/%s\n' $__path $1 >> $dockerignore
}

processManifest() {
    if [ -f ./config/manifest ]
  then
       # Get the correct architecture.
       # Use `uname -m | sed -e 's/_/\./g' -e 's/-/\./g'` replaces underscores (_) and dashes (-)
       # with the wildcard and matches both "x86_64" and "x86-64".
       grep -i $(uname -m | sed -e 's/_/\./g' -e 's/-/\./g') ./config/manifest | grep -ve "^#" | awk '{print $1,$2,$3,$4,$5}' | while IFS=" " read -r checksum filename filetype version extra
          do
               if [ "$filetype" == "database" ] && [ "$version" == "$ORACLE_BASE_VERSION" ] && [ -f ./database/"$filename" ] && [ -z "$edition" ]
             then case $1 in
                  ignore) addException $filename database ;;
                  label)  sed -i '' -e "s/^###SOFTWARE_LABEL###/&\nLABEL database.software.${version}=\"Edition=${extra}, Version=${version}, File=${filename}, md5sum=${checksum}\"\n/" $dockerfile ;;
                  esac
             elif [ "$filetype" == "database" ] && [ "$version" == "$ORACLE_BASE_VERSION" ] && [ -f ./database/"$filename" ] && [[ $edition =~ $ORACLE_EDITION ]]
             then case $1 in
                  ignore) addException $filename database ;;
                  label)  sed -i '' -e "s/^###SOFTWARE_LABEL###/&\nLABEL database.software.${version}=\"Edition=${extra}, Version=${version}, File=${filename}, md5sum=${checksum}\"\n/" $dockerfile ;;
                  esac
             elif [ "$filetype" == "opatch" -o "$filetype" == "patch" ] && [ "$version" == "$ORACLE_BASE_VERSION" -o "$version" == "$ORACLE_VERSION" ] && [ -f ./database/patches/"$filename" ]
             then case $1 in
                  ignore) addException $filename patch ;;
                  label)  sed -i '' -e "s/^###SOFTWARE_LABEL###/&\nLABEL database.patch.${extra}=\"Patch ID=${extra}, Version=${version}, File=${filename}, md5sum=${checksum}\"\n/" $dockerfile ;;
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
              MIN_SPACE_GB_ARG \
              MOS_SECRET \
              OEL_IMAGE \
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
  sed -i '' -e '/###$/d' $1
}

getVersion
getEdition
setBuildKit

# Set build options
options="--force-rm=true --no-cache=true"
#options="--force-rm=true --no-cache=true --progress=plain"

# Set build arguments
arguments=""
  if [ -n "$RPM_LIST" ]
then rpm_list="--build-arg RPM_LIST=$RPM_LIST"
fi

## Set systemd options
#  if [ -n "$SYSTEMD" ]
#then systemd="--build-arg SYSTEMD=Y"
#fi

  if [ -z "$(getImage)" ]
then # There is no base image
     # Create a base image:
     FROM_BASE="FROM ${SOURCE}:${TAG} as base"
     FROM_OEL_BASE="base"
     createDockerfiles oraclelinux || error "There was a problem creating the Dockerfiles"
     processDockerfile $dockerfile

     # Run the build
     DOCKER_BUILDKIT=$BUILDKIT docker build $options $arguments $rpm_list $systemd \
                              --build-arg BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
                              -t $OEL_IMAGE \
                              -f $dockerfile . && rm $dockerfile $dockerignore
fi

FROM_OEL_BASE="$(getImage)"
echo $FROM_OEL_BASE
createDockerfiles db || error "There was a problem creating the Dockerfiles"
processDockerfile $dockerfile

# Add exceptions to the ignore file
  if [ "$ORACLE_BASE_VERSION" != "$ORACLE_VERSION" ]
then addException "*.${ORACLE_BASE_VERSION}.rsp" asset
     addException "*.${ORACLE_BASE_VERSION}" asset
else addException "*.${ORACLE_VERSION}.rsp" asset
     addException "*.${ORACLE_VERSION}" asset
fi
processManifest ignore 

DOCKER_BUILDKIT=$BUILDKIT docker build $options $arguments $secrets \
                         --build-arg BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
                         --build-arg FORCE_PATCH=opatch \
                         -t ${DB_REPO}:${ORACLE_VERSION}-${ORACLE_EDITION} \
                         -f $dockerfile . && rm $dockerfile $dockerignore
