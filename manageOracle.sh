#!/bin/bash
#---------------------------------------------------------------------#
#                                                                     #
#                     Oracle Container Management                     #
#                                                                     #
# This script is used to perform all management functions for Oracle  #
# database containers. The default action starts a database, running  #
# DBCA if none exists. Other options include:                         #
#                                                                     #
#    -e: Configure the environment (deprecated)                       #
#    -h: Perform the Docker health check                              #
#    -O: Install Oracle database software                             #
#    -p: List patches installed in the database                       #
#    -P: Change privileged passwords                                  #
#    -R: Perform post-software installation root actions              #
#    -U: Install an addition home for upgrade images                  #
#---------------------------------------------------------------------#
ORACLE_CHARACTERSET=${ORACLE_CHARACTERSET:-AL32UTF8}
ORACLE_NLS_CHARACTERSET=${ORACLE_NLS_CHARACTERSET:-AL16UTF16}

logger() {
  local __format="$1"
  shift 1

  __line="# ----------------------------------------------------------------------------------------------- #"

    if [[ $__format =~ B ]]
  then printf "\n${__line}\n"
  elif [[ $__format =~ b ]]
  then printf "\n"
  fi

    if [[ $__format =~ D ]]
  then dt="at $(date -R)"
  elif [[ $__format =~ d ]]
  then dt="at $(date '+%F %T')"
  else dt=""
  fi

  printf "%s %s\n" "  $@" "$dt"

    if [[ $__format =~ A ]]
  then printf "${__line}\n"
  elif [[ $__format =~ a ]]
  then printf "\n"
  fi
}

warn() {
  printf "WARNING: %s\n" "$@"
}

error() {
  printf "ERROR: %s\nExiting...\n" "$@"
  return 1
}

debug() {
  __s1=
  __s2=
    if [ "$debug" ]
  then __s1="DEBUG: $1"
       __s2="${2//\n/}"
       printf "%-40s: %s\n" "$__s1" "$__s2" | tee -a "$3"
  fi
}

fixcase() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

FIXCASE() {
  echo "$1" | tr '[:lower:]' '[:upper:]'
}

_sigint() {
  logger BA "${FUNCNAME[0]}: SIGINT recieved: stopping database"
  stopDB
}

_sigterm() {
  logger BA "${FUNCNAME[0]}: SIGTERM received: stopping database"
  stopDB
}

_sigkill() {
  logger BA "${FUNCNAME[0]}: SIGKILL received: Stopping database"
  stopDB
}

replaceVars() {
  local __file="$1"
  local __var="$2"
    if [ -z "$3" ]
  then local __val="$(eval echo \$$(echo $__var))"
  else local __val="$3"
  fi
  sed -i -e "s|###${__var}###|${__val}|g" "$__file"
}

checkDirectory() {
    if [ ! -d "$1" ]
  then error "Directory $1 does not exist"
  elif [ ! -w "$1" ]
  then error "Directory $1 is not writable"
  fi
}

getPreinstall() {
  # Set the default RPM by version:
  case $1 in
       11*)   pre="oracle-rdbms-server-11gR2-preinstall unzip" ;;
       12.1*) pre="oracle-rdbms-server-12cR1-preinstall tar" ;;
       12.2*) pre="oracle-database-server-12cR2-preinstall" ;;
       18*)   pre="oracle-database-preinstall-18c" ;;
       19*)   pre="oracle-database-preinstall-19c" ;;
       21*)   pre="oracle-database-preinstall-21c" ;;
       23*)   curl -L -o oracle-database-preinstall-23c-1.0-0.5.el8.x86_64.rpm https://yum.oracle.com/repo/OracleLinux/OL8/developer/x86_64/getPackage/oracle-database-preinstall-23c-1.0-0.5.el8.x86_64.rpm
              dnf -y localinstall oracle-database-preinstall-23c-1.0-0.5.el8.x86_64.rpm ;;
       *)     pre="oracle-database-preinstall-19c" ;;
  esac

  # Set the EPEL release:
  release=$(cat /etc/os-release | grep -e "^PLATFORM_ID" | sed -e 's/^.*://g' -e 's/"//g')

  export RPM_LIST="openssl oracle-epel-release-$release $pre $RPM_LIST" 
}

getYum() {
  # Get the correct package installer: yum, dnf, or microdnf:
  YUM=$(command -v yum || command -v dnf || command -v microdnf)
}

configENV() {
  set -e

  local __min_space_gb=${MIN_SPACE_GB:-12}
  local __target_home=${TARGET_HOME:-$ORACLE_HOME}

    if [ ! "$(df -PB 1G / | tail -n 1 | awk '{print $4}')" -ge "$__min_space_gb" ]
  then error "The build requires at least $__min_space_gb GB free space."
  fi

  getPreinstall "$ORACLE_VERSION"
  getYum

  $YUM -y update
  $YUM -y install $RPM_LIST
  sync

    if [ -n "$RPM_SUPPLEMENT" ]
  then $YUM -y install $RPM_SUPPLEMENT
  fi

  # Add option to add systemd support to the image (for AHF/TFA)
    if [ -n "$SYSTEMD" ]
  then $YUM -y install systemd
       cd /lib/systemd/system/sysinit.target.wants
        for i in *
         do [ $i == systemd-tmpfiles-setup.service ] || rm -f $i
       done
       rm -f /etc/systemd/system/{getty,graphical,local-fs,remote-fs,sockets,sysinit,system-update,systemd-remount}.target.wants/*
       rm -f /lib/systemd/system/{anaconda,basic,local-fs,multi-user}.target.wants/*
       rm -f /lib/systemd/system/sockets.target.wants/{*initctl*,*udev*}
       rm -rf /var/cache/yum
       sync
       systemctl set-default multi-user.target
  fi

  $YUM clean all

  mkdir -p {"$INSTALL_DIR","$SCRIPTS_DIR"} || error "Failure creating directories."
}

configDBENV() {
  set -e

  local __target_home=${TARGET_HOME:-$ORACLE_HOME}

  mkdir -p {"$ORACLE_INV","$ORACLE_HOME","$__target_home","$ORADATA"/{dbconfig,fast_recovery_area},"$ORACLE_BASE"/{admin,scripts/{setup,startup}}} || error "Failure creating directories."
   case $ORACLE_VERSION in
        18.*|19.*|2*) if [ "${ROOH^^}" = "ENABLE" ]; then mkdir -p "$ORACLE_BASE"/{dbs,homes} || error "Failure creating directories."; fi
                      ;;
   esac
  chown -R oracle:oinstall "$INSTALL_DIR" "$SCRIPTS_DIR" "$ORACLE_INV" "$ORACLE_BASE" "$ORADATA" "$__target_home" || error "Failure changing directory ownership."
  ln -s "$ORACLE_BASE"/scripts /docker-entrypoint-initdb.d || error "Failure setting Docker entrypoint."
  echo oracle:oracle | chpasswd || error "Failure setting the oracle user password."
}

checkSum() {
  # $1 is the file name
  # $2 is the md5sum
    if [ -z "$FILE_MD5SUM" ] && [ "$(type md5sum 2>/dev/null)" ] && [ ! "$(md5sum "$1" | awk '{print $1}')" == "$2" ]
  then error "Checksum for $1 did not match"
  fi
}

setBase() {
  case $ORACLE_VERSION in
       18*|19*|2*) export ORACLE_BASE_CONFIG="$($ORACLE_HOME/bin/orabaseconfig)/dbs"
                   export ORACLE_BASE_HOME="$($ORACLE_HOME/bin/orabasehome)" ;;
                *) export ORACLE_BASE_CONFIG="$ORACLE_HOME/dbs"
                   export ORACLE_BASE_HOME="$ORACLE_HOME" ;;
  esac
  export TNS_ADMIN=$ORACLE_BASE_HOME/network/admin
}

mkPass() {
  # Generate a random 16-character password; first character always alphanum, including one guaranteed special character:
#  echo "$(tr -dc '[:alnum:]' </dev/urandom | head -c 16)"
  echo "$(</dev/urandom tr -dc '[[:alnum:]]' | head -c 2; (</dev/urandom tr -dc '0-9' | head -c 2; </dev/urandom tr -dc '#_\-' | head -c 2; </dev/urandom tr -dc 'A-Za-z0-9#_\-' | head -c 8) | fold -w1 | shuf | tr -d '\n')"
}

copyTemplate() {
  # Copy template files (for TNS, listener, etc) to their destination and replace variables from the environment.
  # $1 is the source template file
  # $2 is the destination file
  # $3 is append/replace file contents
  case $3 in
       r*|R*) option=">" ;;
       *)     option=">>" ;;
  esac

    if [ -f "$1" ]
  then eval "cat << EOF "$option" "$2"
$(<"$1")
EOF
"
  else error "Template $1 not found"
  fi
}

setSudo() {
    if [ "$1" == "allow" ]
  then # Fix a problem that prevents root from su - oracle:
       sed -i -e "s|\(^session\s*include\s*system-auth\)|\#\1|" /etc/pam.d/su
  else # Revert the change:
       sed -i -e "s|^\(\#\)\(session\s*include\s*system-auth\)|\2|" /etc/pam.d/su
  fi
}

downloadPatch() {
  local __patch_id=$1
  local __patch_dir=$2
  local __patch_file=$3
  local __platform_id=${4:-226P}
  local __cookie="/home/oracle/.cookie"
  local __patch_list="/home/oracle/.mos"
  local __netrc="/home/oracle/.netrc"
  local __curl_flags="-sS --netrc-file $__netrc --cookie-jar $__cookie --connect-timeout 3 --retry 5"

    if [ ! -f "$__netrc" ]
  then error "The MOS credential file doesn't exist"
  fi
  # Install curl if it isn't present.
  command -v curl >/dev/null 2>&1 || getYum; $YUM install -y curl

  # Log in to MOS if there isn't already a cookie file.
    if [ ! -f "$__cookie" ]
  then sudo su - oracle -c "curl $__curl_flags \"https://updates.oracle.com/Orion/Services/download\" >/dev/null" || error "MOS login failed"
  fi
  # Set ownership of the patch directory.
    if [ "$(stat -c "%G" $__patch_dir)" != "$(id -gn oracle)" ]
  then chown oracle:$(id -gn oracle) "$__patch_dir" || error "Error changing ownership of $__patch_dir"
  fi
  # Get the list of available patches.
  sudo su - oracle -c "curl $__curl_flags -L --location-trusted \"https://updates.oracle.com/Orion/SimpleSearch/process_form?search_type=patch&patch_number=${__patch_id}&plat_lang=${__platform_id}\" -o $__patch_list" || error "Error downloading the patch list"
  # Loop over the list of patches that resolve to a URL containing the patch file and get the link.
   for link in $(grep -e "https.*$__patch_file" "$__patch_list" | sed -e "s/^.*\href[^\"]*\"//g;s/\".*$//g")
    do 
         if [ "$link" ]
       then # Download newer/updated versions only
              if [ -f "$__patch_dir/$__patch_file" ]
            then local __curl_flags="$__curl_flags -z $__patch_dir/$__patch_file"
            fi
            # Download the patch via curl
            local __patch_bytes=$(sudo su - oracle -c "curl -Rk $__curl_flags -L --location-trusted \"$link\" -o $__patch_dir/$__patch_file -w '%{size_download}\n'") || error "Error downloading patch $__patch_id"
              if [ "$__patch_bytes" -eq 0 ]
            then echo "Server timestamp is not newer - patch $__patch_id was not downloaded"
            fi
       else warn "No download available for patch $__patch_id using $link"
       fi
  done
}

installPatch() {
  # $1 is the patch type (patch, opatch)
  # $2 is the version
  local __minor_version=$2
  local __major_version=${2%%.*}
    if [ -d "$INSTALL_DIR/patches" ]
  then
         if [ -f "$manifest" ]
       then manifest="$(find $INSTALL_DIR -maxdepth 1 -name "manifest*" 2>/dev/null)"
            # Allow manifest to hold version-specific (version = xx.yy) and generic patches (version = xx) and apply them in order.
            grep -e "^[[:alnum:]].*\b.*\.zip[[:blank:]]*\b${1}\b[[:blank:]]*\(${__major_version}[[:blank:]]\|${__minor_version}[[:blank:]]\)" $manifest \
                 | grep -i $(uname -m | sed -e 's/_/\./g' -e 's/-/\./g' -e 's/aarch64/arm64/g') \
                 | awk '{print $5,$2,$1}' | while read patchid install_file checksum
               do
                  # If there's a credential file and either:
                  # ...the patch file isn't present
                  # ...or the FORCE_PATCH flag matches the patch type (all, opatch, patch) or the patch ID
                  # ...the checksum in the patch manifest doesn't match the file
                  local __checksum_result=$(checkSum "$INSTALL_DIR/patches/$install_file" "$checksum" 2>/dev/null)
                    
                    if [[ -f "/home/oracle/.netrc" && ( ! -f "$INSTALL_DIR/patches/$install_file" || "$(echo $FORCE_PATCH | grep -ci -e "\b$1\b" -e "\b$patchid\b" -e "\ball\b")" -eq 1 ) || "$__checksum_result" -ne 0 ]]
                  then downloadPatch $patchid $INSTALL_DIR/patches $install_file
                  fi
                    if [ -f "$INSTALL_DIR/patches/$install_file" ]
                  then case $1 in
                       opatch) sudo su - oracle -c "unzip -oq -d $ORACLE_HOME $INSTALL_DIR/patches/$install_file" || error "An incorrect version of OPatch was found (version, architecture or bit mismatch)" ;;
                       patch)  sudo su - oracle -c "unzip -oq -d $INSTALL_DIR $INSTALL_DIR/patches/$install_file" || error "There was a problem unzipping $install_file"
                               # Get the apply command from the README
                               opatch_apply=$(grep -E "opatch .apply.*" "$INSTALL_DIR"/"$patchid"/README.* | sort | head -1 | awk '{print $2}')
                               opatch_apply=${opatch_apply:-apply}
                               sudo su - oracle -c "$ORACLE_HOME/OPatch/opatch $opatch_apply -silent $INSTALL_DIR/$patchid" || error "OPatch $opatch_apply for $patchid failed"
                               ;;
                       esac
                  else error "Patch $patchid identified in manifest not found"
                  fi
             done
       else error "The manifest file was not found"
       fi
  else warn "The patch directory was not found" #error "The patch directory was not found"
  fi
}

getPatches() {
  # Print a patch summary
  sudo su - oracle -c "$ORACLE_HOME/OPatch/opatch lspatches" || logger BA "There was a problem running opatch lspatches"
}

installOracle() {
  set -e

  # Default the version and home, use local values to allow multi-home installations
  local __version=${1:-$ORACLE_VERSION}
  local __major_version=$(echo $__version | cut -d. -f1)
  local __oracle_home=${2:-$ORACLE_HOME}

    if [ -z "$ORACLE_EDITION" ]
  then error "A database edition is required"
  elif [ "$ORACLE_EDITION" != "EE" ]  && [ "$ORACLE_EDITION" != "SE" ] && [ "$ORACLE_EDITION" != "SE2" ] && [ "$ORACLE_EDITION" != "XE" ]
  then error "Database edition must be one of EE, SE, SE2, or XE"
  elif [ "$__version" == "11.2.0.4" ] && [ "$ORACLE_EDITION" != "EE" ] && [ "$ORACLE_EDITION" != "SE" ]
  then error "Database edition must be EE or SE for version 11.2.0.4"
  elif [ "$__version" == "11.2.0.2" ] && [ "$ORACLE_EDITION" != "XE" ]
  then error "Database edition must be XE for version 11.2.0.2"
  elif [ "$ORACLE_EDITION" == "SE" ]
  then error "Database edition SE is only available for version 11.2.0.4"
  fi

  configDBENV

  checkDirectory "$ORACLE_BASE"
  checkDirectory "$__oracle_home"

    if ! [[ $__oracle_home == $ORACLE_BASE/* ]]
  then error "The ORACLE_HOME directory $__oracle_home must be a subdirectory of the ORACLE_BASE."
  fi

   for var in ORACLE_EDITION \
              ORACLE_INV \
              ORACLE_BASE \
              ORADATA
    do
       replaceVars "$INSTALL_DIR"/"$INSTALL_RESPONSE" "$var"
  done
       replaceVars "$INSTALL_DIR"/"$INSTALL_RESPONSE" "ORACLE_HOME" "$__oracle_home"

  # Allow root to su - oracle:
  setSudo allow
  # Install Oracle binaries
    if [ -f "$(find "$INSTALL_DIR"/ -type f -iregex '.*oracle.*\.rpm.*')" ] || [ -n "$ORACLE_RPM" ]
  then # Install Oracle from RPM
       # The ORACLE_DOCKER_INSTALL environment variable is required for RPM installation to succeed
       export ORACLE_DOCKER_INSTALL=true
         if [ -z "$ORACLE_RPM" ]
       then ORACLE_RPM=$(find "$INSTALL_DIR"/ -type f -iregex '.*oracle.*\.rpm.*')
              if [[ $ORACLE_RPM =~ .*\.zip$ ]]
            then unzip -q "$ORACLE_RPM"
                 ORACLE_RPM=${ORACLE_RPM%.zip}
            fi
       fi

       getYum; $YUM -y localinstall $ORACLE_RPM

       # Determine the name of the init file used for RPM installation
#         if [ "$__version" == "11.2.0.2" ] && [ "$ORACLE_EDITION" != "XE" ]
#       then INIT_FILE="oracle-xe"
#       elif [ "$__version" == "18.4" ]     && [ "$ORACLE_EDITION" != "XE" ]
#       then INIT_FILE="oracle-xe-18c"
#       else INIT_FILE="oracledb_ORCLCDB-${__major_version}c"
#       fi

         if [ -z "$INIT_FILE" ]
       then INIT_FILE=$(find /etc/init.d/* -maxdepth 1 -type f -regex '.*/oracle[db_|-xe].*')
       else INIT_FILE=/etc/init.d/"$INIT_FILE"
       fi

       # If different directories are passed to the build, move the directories and recompile.
       OLD_HOME=$(grep -E "^export ORACLE_HOME" "$INIT_FILE" | cut -d= -f2 | tr -d '[:space:]'); export OLD_HOME
       OLD_BASE=$(echo "$OLD_HOME" | sed -e "s|/product.*$||g"); export OLD_BASE
       OLD_INV=$(grep -E "^inventory_loc" "$OLD_HOME"/oraInst.loc | cut -d= -f2); export OLD_INV

         if ! [[ $OLD_BASE -ef $ORACLE_BASE ]] || ! [[ $OLD_HOME -ef $__oracle_home ]] || ! [[ $OLD_INV -ef $ORACLE_INV ]]
       then 
            # Directories cannot be changed in XE. It does not have the ability to relink.
              if [ "$ORACLE_EDITION" == "XE" ] # TODO: clone.pl is deprecated in 19c: -o "$(echo $__version | cut -c 1-2)" == "19"  ]
            then export ORACLE_HOME="$OLD_HOME"
                 export ORACLE_BASE="$OLD_BASE"
                 export ORACLE_INV="$OLD_INV"
            fi

            # Move directories to new locations
              if ! [[ $OLD_INV -ef $ORACLE_INV ]]
            then mv "$OLD_INV"/* "$ORACLE_INV"/ || error "Failed to move Oracle Inventory from $OLD_INV to $ORACLE_INV"
                 find / -name oraInst.loc -exec sed -i -e "s|^inventory_loc=.*$|inventory_loc=$ORACLE_INV|g" {} \;
                 rm -fr $OLD_INV || error "Failed to remove Oracle Inventory from $OLD_INV"
            fi

              if ! [[ $OLD_HOME -ef $__oracle_home ]]
            then mv "$OLD_HOME"/* "$__oracle_home"/ || error "Failed to move ORACLE_HOME from $OLD_HOME to $__oracle_home"
                 chown -R oracle:oinstall "$__oracle_home"
                 rm -fr "$OLD_BASE"/product || error "Failed to remove $OLD_HOME after moving to $__oracle_home"
                 sudo su - oracle -c "$__oracle_home/perl/bin/perl $__oracle_home/clone/bin/clone.pl ORACLE_HOME=$__oracle_home ORACLE_BASE=$ORACLE_BASE -defaultHomeName -invPtrLoc $__oracle_home/oraInst.loc" || error "ORACLE_HOME cloning failed for $__oracle_home"
            fi

              if ! [[ $OLD_BASE -ef $ORACLE_BASE ]]
            then rsync -a "$OLD_BASE"/ "$ORACLE_BASE" || error "Failed to move ORACLE_BASE from $OLD_BASE to $ORACLE_BASE"
                 rm -rf $OLD_BASE || error "Failed to remove $OLD_BASE after moving to $ORACLE_BASE"
            fi
  	 fi

  else # Install Oracle from archive

       manifest="$(find $INSTALL_DIR -maxdepth 1 -name "manifest*" 2>/dev/null)"
       # Some versions have multiple files that must be unzipped to the correct location prior to installation.
       # Loop over the manifest, retrieve the file and checksum values, unzip the installation files.
       set +e
       grep -e "^[[:alnum:]].*\b.*\.zip[[:blank:]]*\bdatabase\b.*${ORACLE_EDITION::2}" $manifest \
            | grep -i $(uname -m | sed -e 's/_/\./g' -e 's/-/\./g' -e 's/aarch64/arm64/g') \
            | awk '{print $1,$2}' | while read checksum install_file
          do checkSum "$INSTALL_DIR/$install_file" "$checksum"
             case $ORACLE_VERSION in
                  18.*|19.*|2*) sudo su - oracle -c "unzip -oq -d $ORACLE_HOME $INSTALL_DIR/$install_file" ;;
                             *) sudo su - oracle -c "unzip -oq -d $INSTALL_DIR $INSTALL_DIR/$install_file" ;;
             esac
       done
       # Run the installation
       case $ORACLE_VERSION in
            18.*|19.*|2*) sudo su - oracle -c "$__oracle_home/runInstaller -silent -force -waitforcompletion -responsefile $INSTALL_DIR/$INSTALL_RESPONSE -ignorePrereqFailure" ;;
                       *) sudo su - oracle -c "$INSTALL_DIR/database/runInstaller -silent -force -waitforcompletion -responsefile $INSTALL_DIR/$INSTALL_RESPONSE -ignoresysprereqs -ignoreprereq" ;;
       esac
       set -e

         if [ ! "$("$__oracle_home"/perl/bin/perl -v)" ]
       then mv "$__oracle_home"/perl "$__oracle_home"/perl.old
            curl -o "$INSTALL_DIR"/perl.tar.gz http://www.cpan.org/src/5.0/perl-5.14.1.tar.gz
            tar -xzf "$INSTALL_DIR"/perl.tar.gz
            cd "$INSTALL_DIR"/perl-*
            sudo su - oracle -c "./Configure -des -Dprefix=$__oracle_home/perl -Doptimize=-O3 -Dusethreads -Duseithreads -Duserelocatableinc"
            sudo su - oracle -c "make clean"
            sudo su - oracle -c "make"
            sudo su - oracle -c "make install"

            # Copy old binaries into new Perl directory
            rm -fr "${__oracle_home:?}"/{lib,man}
            cp -r "$__oracle_home"/perl.old/lib/            "$__oracle_home"/perl/
            cp -r "$__oracle_home"/perl.old/man/            "$__oracle_home"/perl/
            cp    "$__oracle_home"/perl.old/bin/dbilogstrip "$__oracle_home"/perl/bin/
            cp    "$__oracle_home"/perl.old/bin/dbiprof     "$__oracle_home"/perl/bin/
            cp    "$__oracle_home"/perl.old/bin/dbiproxy    "$__oracle_home"/perl/bin/
            cp    "$__oracle_home"/perl.old/bin/ora_explain "$__oracle_home"/perl/bin/
            rm -fr "$__oracle_home"/perl.old
            cd "$__oracle_home"/lib
            ln -sf ../javavm/jdk/jdk7/lib/libjavavm12.a
            chown -R oracle:oinstall "$__oracle_home"

            # Relink
            cd "$__oracle_home"/bin
            sudo su - oracle -c "relink all" || logger "$(cat $__oracle_home/install/relink.log)"; error "Relink failed"
       fi

echo "End of binary installation"

  fi # End of software binary installation

  # Check for OPatch
#  installPatch opatch "${ORACLE_VERSION::2}"
  installPatch opatch "${ORACLE_VERSION}"
  # Check for patches
  installPatch patch "${ORACLE_VERSION}"
  # Print a patch summary
    if [ -n "$DEBUG" ]
  then getPatches
  fi

  # Minimize the installation
    if [ -n "$REMOVE_COMPONENTS" ]
  then local __rc=${REMOVE_COMPONENTS^^}

       OLDIFS=$IFS
       IFS=,
        for rc in $__rc
         do
            case $rc in
                 APEX)  # APEX
                        rm -fr "$__oracle_home"/apex 2>/dev/null ;;
                 DBMA)  # Database migration assistant
                        rm -fr "$__oracle_home"/dmu 2>/dev/null ;;
                 DBUA)  # DBUA
                        rm -fr "$__oracle_home"/assistants/dbua 2>/dev/null ;;
                 HELP)  # Help files
                        rm -fr "$__oracle_home"/network/tools/help 2>/dev/null ;;
                 ORDS)  # ORDS
                        rm -fr "$__oracle_home"/ords 2>/dev/null ;;
                 OUI)   # OUI inventory backups
                        rm -fr "$__oracle_home"/inventory/backup/* 2>/dev/null ;;
                 PATCH) # Patch storage
                        rm -fr "$__oracle_home"/.patch_storage 2>/dev/null ;;
                 PILOT) # Pilot workflow
                        rm -fr "$__oracle_home"/install/pilot 2>/dev/null ;;
                 SQLD)  # SQL Developer
                        rm -fr "$__oracle_home"/sqldeveloper 2>/dev/null ;;
                 SUP)   # Support tools
                        rm -fr "$__oracle_home"/suptools 2>/dev/null ;;
                 TNS)   # TNS samples
                        rm -fr "$__oracle_home"/network/admin/samples 2>/dev/null ;;
                 UCP)   # UCP
                        rm -fr "$__oracle_home"/ucp 2>/dev/null ;;
                 ZIP)   # Installation files
                        rm -fr "$__oracle_home"/lib/*.zip 2>/dev/null ;;
            esac
       done
       IFS=$OLDIFS
  fi

  # Enable read-only Oracle Home:
  case $ORACLE_VERSION in
       18.*|19.*|2*) if [ "${ROOH^^}" = "ENABLE" ]; then sudo su - oracle -c "$__oracle_home/bin/roohctl -enable"; unset ROOH; fi ;;
  esac

  # Revert pam.d sudo changes:
  setSudo revert
}

runsql() {
  unset spool
    if [ -n "$2" ]
  then spool="spool $2 append"
  fi

  NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'
  "$ORACLE_HOME"/bin/sqlplus -S / as sysdba << EOF
set head off termout on verify off lines 300 pages 9999 trimspool on feed off serverout on
whenever sqlerror exit warning
$1
EOF

    if [ "$?" -ne 0 ]
  then error "${FUNCNAME[0]} failed calling SQL: $1"
       return 1
  fi
}

startListener() {
    if [ "$(ps -ef | grep tnslsnr | grep $ORACLE_HOME | grep -v grep | wc -l)" -eq 0 ]
  then
       $ORACLE_HOME/bin/lsnrctl start 2>/dev/null
  fi
}

stopListener() {
   for __oh in $(egrep -v "^#|^$" /etc/oratab | cut -d: -f2)
    do $_oh/bin/lsnrctl stop 2>/dev/null 
  done
}

startDB() {
    if [ -n "$ORACLE_HOME" ] && [ -n "$ORACLE_SID" ]
  then startListener
         if [ -z "$OPEN_MODE" ] || [ "$OPEN_MODE" = "OPEN" ]
       then runsql "startup;"
       else runsql "startup mount;"
            if [ "$OPEN_MODE" != "MOUNT" ]; then runsql "alter database open read only;"; fi
            if [ "$OPEN_MODE"  = "APPLY" ]; then runsql "alter database recover managed standby database disconnect from session;"; fi
       fi
  else error "${FUNCNAME[0]} failed to start the database: ORACLE_HOME and ORACLE_SID must be set."
       return 1
  fi
}

stopDB() {
  # Copy the oratab before shutdown to capture any changes:
  local __dbconfig="$ORADATA"/dbconfig/"$ORACLE_SID"
    if [ -f /etc/oratab ]
  then cp /etc/oratab "$__dbconfig"/ 2>/dev/null
  fi
  runsql "shutdown immediate;"
  stopListener
}

runDBCA() {
  local __version=$(echo "$ORACLE_VERSION" | cut -d. -f1)
  # Default init parameters
#  local INIT_PARAMS=${INIT_PARAMS:-db_create_file_dest=${ORADATA},db_create_online_log_dest_1=${ORADATA},db_recovery_file_dest=${ORADATA}/fast_recovery_area,audit_trail=none,audit_sys_operations=false}
  local INIT_PARAMS=${INIT_PARAMS:-db_recovery_file_dest=${ORADATA}/fast_recovery_area,audit_trail=none,audit_sys_operations=false}
    if ! [[ $INIT_PARAMS =~ = ]]
  then error "Invalid value provided for INIT_PARAMS: $INIT_PARAMS"
  fi

  # 21c database check - PDB is mandatory and Read-Only Home is the default
    if [ "$__version" == "21" ] || [ "$__version" == "23" ]
  then # Version 21; check PDB_LIST and ORACLE_PDB and assign a default if not set:
         if [ -z "$PDB_LIST" ] && [ -z "$ORACLE_PDB" ]
       then ORACLE_PDB=${ORACLE_PDB:-ORCLPDB}
       fi
       # Set PDB_COUNT to 1 if undefined:
       PDB_COUNT=${PDB_COUNT:-1}
  fi

  SID_LIST=${SID_LIST:-$ORACLE_SID}
  OLDIFS=$IFS
  IFS=,
  SID_NUM=1
   for ORACLE_SID in $SID_LIST
    do
       IFS=$OLDIFS
       local __dbcaresponse="$ORACLE_BASE"/dbca."$ORACLE_SID".rsp
       local __pdb_count=${PDB_COUNT:-0}  
       # Detect custom DBCA response files:
       cp "$INSTALL_DIR"/dbca.*.rsp "$__dbcaresponse" 2>/dev/null || cp "$ORADATA"/dbca."$ORACLE_SID".rsp "$__dbcaresponse" 2>/dev/null || cp "$ORADATA"/dbca.rsp "$__dbcaresponse" 2>/dev/null

       # Allow DB unique names:
         if [ -n "$DB_UNQNAME" ] && [ "$DB_UNQNAME" != "$ORACLE_SID" ]
       then __db_msg="$ORACLE_SID with unique name $DB_UNQNAME"
            INIT_PARAMS="${INIT_PARAMS},db_unique_name=$DB_UNQNAME"
       else DB_UNQNAME=$ORACLE_SID
            __db_msg="$ORACLE_SID"
       fi

       logger BAd "${FUNCNAME[0]}: Running DBCA for database $__db_msg"

       # Additional messages for Data Guard:
         if [ -n "$CONTAINER_NAME" ]; then logger x "${FUNCNAME[0]}:        Container name is: $CONTAINER_NAME"; fi
         if [ -n "$ROLE" ];           then logger x "${FUNCNAME[0]}:        Container role is: $ROLE";           fi
         if [ -n "$DG_TARGET" ];      then logger x "${FUNCNAME[0]}:   Container DG Target is: $DG_TARGET";      fi

         if [ "$SID_NUM" -eq 1 ]
       then # Start the listener in this home
            startListener
            unset __pdb_only
            SIDENV="export ORACLE_SID=$ORACLE_SID"
       fi
       addTNSEntry "$ORACLE_SID"
       SID_NUM=$((SID_NUM+1))
       IFS=,

         if [ "$__version" != "11" ] && [ -n "$PDB_LIST" ]
       then # Not an 11g database, PDB list is defined:
            OLDIFS=$IFS
            IFS=,
            PDB_NUM=1
            PDB_ADMIN=PDBADMIN
             for ORACLE_PDB in $PDB_LIST
              do
                 IFS=$OLDIFS
                   if [ "$PDB_NUM" -eq 1 ]
                 then # Create the database and the first PDB
                      logger BAd "${FUNCNAME[0]}: Creating container database $__db_msg and pluggable database $ORACLE_PDB"
                      createDatabase "$__dbcaresponse" "$INIT_PARAMS" TRUE 1 "$ORACLE_PDB" "$PDB_ADMIN"
                      printf "\nexport ORACLE_PDB=$ORACLE_PDB\n" >> $HOME/.bashrc
                 else # Create additional PDB
                      logger BAd "${FUNCNAME[0]}: Creating pluggable database $ORACLE_PDB"
                      createDatabase NONE NONE TRUE 1 "$ORACLE_PDB" "$PDB_ADMIN"
                 fi
                 addTNSEntry "$ORACLE_PDB"
                 PDB_NUM=$((PDB_NUM+1))
                 IFS=,
            done
            IFS=$OLDIFS
            alterPluggableDB
       elif [ "$__version" != "11" ] && [ "$__pdb_count" -gt 0 ]
       then # Not an 11g database; PDB_COUNT > 0:
            PDB_ADMIN=PDBADMIN
            ORACLE_PDB=${ORACLE_PDB:-ORCLPDB}
            logger BAd "${FUNCNAME[0]}: Creating container database $__db_msg and $__pdb_count pluggable database(s) with name $ORACLE_PDB"
            createDatabase "$__dbcaresponse" "$INIT_PARAMS" TRUE "$__pdb_count" "$ORACLE_PDB" "$PDB_ADMIN"
              if [ "$__pdb_count" -eq 1 ]
            then printf "\nexport ORACLE_PDB=$ORACLE_PDB\n" >> $HOME/.bashrc
                 addTNSEntry "$ORACLE_PDB"
            else printf "\nexport ORACLE_PDB=${ORACLE_PDB}1\n" >> $HOME/.bashrc
                  for ((PDB_NUM=1; PDB_NUM<=__pdb_count; PDB_NUM++))
                   do addTNSEntry "${ORACLE_PDB}""${PDB_NUM}"
                 done
            fi
            alterPluggableDB
       else # 11g database OR PDB_COUNT is not set; create a non-container database:
            logger BAd "${FUNCNAME[0]}: Creating database $__db_msg"
            createDatabase "$__dbcaresponse" "$INIT_PARAMS" FALSE
            printf "\nunset ORACLE_PDB\n" >> $HOME/.bashrc
       fi

  done
  IFS=$OLDIFS

  logger BAd "${FUNCNAME[0]}: DBCA complete"
}

createDatabase() {
  local RESPONSEFILE=$1
  local INIT_PARAMS=$2
  local CREATE_CONTAINER=${3:-TRUE}
  local PDBS=${4:-1}
  local PDB_NAME=${5:-ORCLPDB}
  local PDB_ADMIN=${6:-PDBADMIN}
  local dbcaLogDir=$ORACLE_BASE/cfgtoollogs/dbca

    if [ "$RESPONSEFILE" != "NONE" ]
  then
        for var in ORACLE_BASE \
                   ORACLE_SID \
                   ORACLE_PWD \
                   ORACLE_CHARACTERSET \
                   ORACLE_NLS_CHARACTERSET \
                   CREATE_CONTAINER \
                   ORADATA \
                   PDBS \
                   PDB_NAME \
                   PDB_ADMIN \
                   INIT_PARAMS
         do REPIFS=$IFS
            IFS=
            replaceVars "$RESPONSEFILE" "$var"
       done
       IFS=$REPIFS

       # If there are more than 8 CPUs default back to dbca memory calculations to pick 40%
       # of available memory. The minimum of 2G is for small environments and guarantees
       # Oracle has enough memory. Larger environments should use the available memory.
         if [ "$(nproc)" -gt 8 ]
       then sed -i -e 's|TOTALMEMORY = "2048"||g' "$RESPONSEFILE"
       fi
       "$ORACLE_HOME"/bin/dbca -silent -createDatabase -responseFile "$RESPONSEFILE" || cat "$dbcaLogDir"/"$DB_UNQNAME"/"$DB_UNQNAME".log || cat "$dbcaLogDir"/"$DB_UNQNAME".log || cat "$dbcaLogDir"/"$DB_UNQNAME"/"$PDB_NAME"/"$DB_UNQNAME".log
  else "$ORACLE_HOME"/bin/dbca -silent -createPluggableDatabase -pdbName "$PDB_NAME" -sourceDB "$ORACLE_SID" -createAsClone true -createPDBFrom DEFAULT -pdbAdminUserName "$PDB_ADMIN" -pdbAdminPassword "$ORACLE_PWD" || cat "$dbcaLogDir"/"$DB_UNQNAME"/"$DB_UNQNAME".log || cat "$dbcaLogDir"/"$DB_UNQNAME".log || cat "$dbcaLogDir"/"$DB_UNQNAME"/"$PDB_NAME"/"$DB_UNQNAME".log
  fi
}

createAudit() {
    if [ ! -d "$ORACLE_BASE/admin/$1/adump" ]
  then mkdir -p $ORACLE_BASE/admin/$1/adump || error "Could not create the audit directory for $1"
  fi
}

moveFiles() {
    if [ ! -d "$ORADATA/dbconfig/$ORACLE_SID" ]
  then mkdir -p "$ORADATA"/dbconfig/"$ORACLE_SID"
  fi

  # Begin upgrade additions
  # The ORACLE_HOME in the configuration directory oratab is the source of truth
  # for existing databases, particularly after an upgrade.
    if [ -f "$ORADATA/dbconfig/$ORACLE_SID/oratab" ]
  then export ORACLE_HOME="$(egrep "^${ORACLE_SID}:" "$ORADATA/dbconfig/$ORACLE_SID/oratab" | egrep -v "^$|^#" | cut -d: -f2 | head -1)"
  fi

    if [ -f "$ORADATA/dbconfig/$ORACLE_SID/spfile${ORACLE_SID}.ora" ]
  then __version="$(strings "$ORADATA/dbconfig/$ORACLE_SID/spfile${ORACLE_SID}.ora" | grep -e "[*.c|c]ompatible" | grep -v "#" | sed -e "s/[A-Za-z '=.*]//g" | head -c 2)"
  elif [ -f "$ORADATA/dbconfig/$ORACLE_SID/init${ORACLE_SID}.ora" ]
  then __version="$(grep -e "[*.c|c]ompatible" "$ORADATA/dbconfig/$ORACLE_SID/init${ORACLE_SID}.ora" | grep -v "#" | sed -e "s/[A-Za-z '=.*]//g" | head -c 2)"
  fi
  # End upgrade additions

  setBase

  local __dbconfig="$ORADATA"/dbconfig/"$ORACLE_SID"

   for filename in "$ORACLE_BASE_CONFIG"/init"$ORACLE_SID".ora \
                   "$ORACLE_BASE_CONFIG"/spfile"$ORACLE_SID".ora \
                   "$ORACLE_BASE_CONFIG"/orapw"$ORACLE_SID" \
                   "$ORACLE_BASE_HOME"/network/admin/listener.ora \
                   "$ORACLE_BASE_HOME"/network/admin/tnsnames.ora \
                   "$ORACLE_BASE_HOME"/network/admin/sqlnet.ora
    do
       file=$(basename "$filename")
         if [ -f "$filename" ] && [ ! -f "$__dbconfig/$file" ]
       then mv "$filename" "$__dbconfig"/ 2>/dev/null
       fi
         if [ -f "$__dbconfig/$file" ] && [ ! -L "$filename" ]
       then ln -s "$__dbconfig"/"$file" "$filename" 2>/dev/null
       fi
  done

    if [ -f /etc/oratab ] && [ ! -f "$__dbconfig/oratab" ]
  then cp /etc/oratab "$__dbconfig"/ 2>/dev/null
  fi
  cp "$__dbconfig"/oratab /etc/oratab 2>/dev/null

  # Find wallet subdirectories in dbconfig and relink them:
    if [ -f "$__dbconfig/sqlnet.ora" ]
  then
        for dirname in $(find $__dbconfig -mindepth 1 -type d)
         do dir=$(basename $dirname)
            # Search the sqlnet.ora for an exactly matching subdirectory
            location=$(grep -e "^[^#].*\/$dir\/" $__dbconfig/sqlnet.ora | sed -e "s|^[^/]*/|/|g" -e "s|[^/]*$||")
              if [ -n "$location" ] && [ ! -d "$location" ]
            then # Create the location if it doesn't exist
                 mkdir -p "$location"
            fi
              if [ -d "$location" ] && [ -f "$dirname/*" ]
            then # Move files from the location into the dbconfig directory
                 mv "$location"/* "$dirname"/ 2>/dev/null
            fi
              if [ ! -L "$location" ]
            then # Link files from the dbconfig directory to the location
                 ln -s "$dirname" "$location" 2>/dev/null
            fi
       done
  fi
}

addTNSEntry() {
  ALIAS=$1
  setBase
  copyTemplate "$INSTALL_DIR"/tnsnames.ora.tmpl "$ORACLE_BASE_HOME"/network/admin/tnsnames.ora append
}

alterPluggableDB() {
  "$ORACLE_HOME"/bin/sqlplus -S / as sysdba << EOF
alter pluggable database all open;
alter pluggable database all save state;
EOF
}

HealthCheck() {
  local __open_mode="'READ WRITE'"
  local __tabname="v\$database"
  local __pdb_count=${PDB_COUNT:-0}

  source oraenv <<< "$(grep -E "^${ORACLE_SID}\:" /etc/oratab | cut -d: -f1 | head -1)" 1>/dev/null
  rc="$?"

    if [ "$rc" -ne 0 ]
  then error "Failed to get the Oracle environment from oraenv"
  elif [ -z "$ORACLE_SID" ]
  then error "ORACLE_SID is not set"
  elif [ -z "$ORACLE_HOME" ]
  then error "ORACLE_HOME is not set"
  elif [ ! -f "$ORACLE_HOME/bin/sqlplus" ]
  then error "Cannot locate $ORACLE_HOME/bin/sqlplus"
  elif [ "$__pdb_count" -gt 0 ] || [ -n "$PDB_LIST" ]
  then __tabname="v\$pdbs"
  fi

  health=$("$ORACLE_HOME"/bin/sqlplus -S / as sysdba << EOF
set head off pages 0 trimspool on feed off serverout on
whenever sqlerror exit warning
--select count(*) from $__tabname where open_mode=$__open_mode;
  select case
         when database_role     = 'PRIMARY'
          and open_mode         = 'READ WRITE'
         then 1
         when database_role  like '%STANDBY'
          and (open_mode     like 'READ ONLY%'
           or  open_mode        = 'MOUNTED')
         then 1
         when database_role     = 'FAR SYNC'
          and open_mode         = 'MOUNTED'
         then 1
         else 0
          end
    from v\$database;
--    from $__tabname;
EOF
)

    if [ "$?" -ne 0 ]
  then return 2
  elif [ "$health" -gt 0 ]
  then return 0
  else return 1
  fi
}

postInstallRoot() {
  # Run root scripts in final build stage
  logger BA "Running root scripts"
    if [ -n "$ORACLE_INV" ] && [ -d "$ORACLE_INV" ] && [ -f "$ORACLE_INV/orainstRoot.sh" ]
  then logger b "Running orainstRoot.sh script in $ORACLE_INV"
       $ORACLE_INV/orainstRoot.sh || error "There was a problem running $ORACLE_INV/orainstRoot.sh"
  fi
    if [ -n "$ORACLE_HOME" ] && [ -d "$ORACLE_HOME" ] && [ -f "$ORACLE_HOME/root.sh" ]
  then logger b "Running root.sh script in $ORACLE_HOME"
       $ORACLE_HOME/root.sh || error "There was a problem running $ORACLE_HOME/root.sh"
  fi

  # If this is an upgrade image, run the target root script and attach the new home.
    if [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] && [ -f "$TARGET_HOME/root.sh" ]
  then 
       logger BA "Running root script in $TARGET_HOME"
       "$TARGET_HOME"/root.sh
       logger BA "Attaching home for upgrade"
       setSudo allow
       sudo su - oracle -c "$TARGET_HOME/oui/bin/attachHome.sh"
       setSudo revert
  fi
  # Additional steps to be performed as root

  # VOLUME_GROUP permits non-oracle/oinstall ownership of bind-mounted volumes. VOLUME_GROUP is passed as GID:GROUP_NAME
    if [ -n "$VOLUME_GROUP" ]
  then local __gid=$(echo "$VOLUME_GROUP" | cut -d: -f1)
       local __grp=$(echo "$VOLUME_GROUP" | cut -d: -f2)
       groupadd -g "$__gid" "$__grp"
       usermod oracle -aG "$__grp"
       chown -R :"$__grp" "$ORADATA"
       chmod -R 775 "$ORADATA"
       chmod -R g+s "$ORADATA"
  fi
}

runUserScripts() {
  local SCRIPTS_ROOT="$1";

    if [ -z "$SCRIPTS_ROOT" ]
  then warn "No script path provided"
       exit 1
  elif [ -d "$SCRIPTS_ROOT" ] && [ -n "$(ls -A "$SCRIPTS_ROOT")" ]
  then # Check that directory exists and it contains files
       logger B "${FUNCNAME[0]}: Running user scripts"
#        for f in "$SCRIPTS_ROOT"/*
       while IFS= read -r f
          do
             case "$f" in
                  *.sh)     logger ba "${FUNCNAME[0]}: Script: $f"; . "$f" ;;
                  *.sql)    logger ba "${FUNCNAME[0]}: Script: $f"; echo "exit" | "$ORACLE_HOME"/bin/sqlplus -s "/ as sysdba" @"$f" ;;
                  *)        logger ba "${FUNCNAME[0]}: Ignored file $f" ;;
             esac
#        done
        done < <(find $SCRIPTS_ROOT/*.{sql,sh} 2>/dev/null | sort)

       logger A "${FUNCNAME[0]}: User scripts complete"
  fi
}

changePassword() {
  runsql "alter user sys identified by \"$1\";
          alter user system identified by \"$1\";"
# TODO: Loop through PDB
#  runsql "alter user pdbadmin identified by \"$1\";"
}

#----------------------------------------------------------#
#                           MAIN                           #
#----------------------------------------------------------#
ORACLE_CHARACTERSET=${ORACLE_CHARACTERSET:-AL32UTF8}
ORACLE_NLS_CHARACTERSET=${ORACLE_NLS_CHARACTERSET:-AL16UTF16}

# If a parameter is passed to the script, run the associated action.
while getopts ":ehOpPRU" opt; do
      case ${opt} in
           h) # Check health of the database
              HealthCheck || exit 1
              exit 0 ;;
           e) # Configure environment
              configENV
              exit 0 ;;
           O) # Install Oracle
              installOracle "$ORACLE_VERSION" "$ORACLE_HOME"
              exit 0 ;;
           p) # List installed patches
              getPatches
              exit 0 ;;
           P) # Change passwords
              # TODO: Get the password from the CLI
              changePassword
              exit 0 ;;
           R) # Post install root scripts
              postInstallRoot
              exit 0 ;;
           U) # Install Oracle upgrade home
              installOracle "$TARGET_VERSION" "$TARGET_HOME"
              exit 0 ;;
      esac
 done

# Start the database if no option is provided
trap _sigint SIGINT
trap _sigterm SIGTERM
trap _sigkill SIGKILL

  if [ -n "$SYSTEMD" ]
then echo "Init:"
     /usr/bin/init
fi

# Check whether container has enough memory
  if [ -f /sys/fs/cgroup/cgroup.controllers ]
then __mem=$(cat /sys/fs/cgroup/memory.max)
else __mem=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
fi

  if [ -z "$__mem" ]
then error "There was a problem getting the cgroups memory limit on the system"
elif [ "${__mem}" != "max" ] && [ "${#__mem}" -lt 11 ] && [ "$__mem" -lt 2147483648 ]
then error "The database container requires at least 2GB of memory; only $__mem is available"
fi

  if [ "$(hostname | grep -Ec "_")" -gt 0 ]
then error "The host name may not contain any '_'"
fi

# Validate SID, PDB names
__oracle_sid=${ORACLE_SID:-ORCLCDB}
__pdb_count=${PDB_COUNT:-0}

# Validate the SID:
  if [ "${#__oracle_sid}" -gt 12 ]
then error "The SID may not be longer than 12 characters"
elif [[ "$__oracle_sid" =~ [^a-zA-Z0-9] ]]
then error "The SID must be alphanumeric"
# Check PDB settings.
elif [ -z "$ORACLE_PDB" ] && [ "$__pdb_count" -eq 0 ] && [ -z "$PDB_LIST" ]
then # No PDB name + no PDB count + no PDB list = Not a container DB
     export ORACLE_SID=${__oracle_sid:-ORCL}
#     unset ORACLE_PDB
     unset PDB_COUNT
     unset PDB_LIST
elif [ ! -z "$PDB_LIST" ]
then # PDB list is defined; create the first PDB as the fist PDB in the list.
     export ORACLE_PDB=$(echo $PDB_LIST | cut -d, -f1)
elif [ -n "$ORACLE_PDB" ] && [ -z "$PDB_COUNT" ]
then # No PDB count but PDB name; create a single PDB with the given name.
     export ORACLE_PDB=$ORACLE_PDB
elif [ -z "$ORACLE_PDB" ] && [ "$PDB_COUNT" -gt 1 ]
then # No PDB name but PDB count > 1; default the first PDB.
     export ORACLE_PDB=ORCLPDB1
else export ORACLE_PDB=$ORACLE_PDB
fi

# Check the audit path
createAudit "$ORACLE_SID"

# Check whether database already exists
#      There's an oratab  and  The ORACLE_SID is in the oratab                    and  There's an ORADATA for the SID    OR There's an ORADATA for the SID
  if [ -f "/etc/oratab" ] && [ "$(grep -Ec "^$ORACLE_SID\:" /etc/oratab)" -eq 1 ] && [ -d "$ORADATA"/"${ORACLE_SID^^}" ] || [ -d "$ORADATA"/"${ORACLE_SID}" ]
then # Before all else, move files. This puts the oratab from config into the expected location:
     moveFiles
     # Begin upgrade additions
     # Set the environment
       if [ -f "/usr/local/bin/oraenv" ]
     then __oraenv=/usr/local/bin/oraenv
     else __oraenv=$ORACLE_HOME/bin/oraenv
     fi

     # Start the "default" database defined by ORACLE_SID:
     . $__oraenv <<< $ORACLE_SID
     createAudit "$ORACLE_SID"
     startDB

     # Preserve the default ORACLE_SID used to call the container:
     DEFAULT_SID=$ORACLE_SID
     # Find other SID:
      for __sid in "$(grep $__home /etc/oratab | grep -v "^#" | grep -Ev "^$DEFAULT_SID\:" | cut -d: -f1)"
       do
            if [ -z "$__sid" ]
          then . $__oraenv <<< "$__sid"
               createAudit "$__sid"
               moveFiles
               startDB
          fi
     done

     # Restore the default ORACLE_SID environment
     . $__oraenv <<< $DEFAULT_SID
     # End upgrade additions
else # Create the TNS configuration
     setBase
     mkdir -p "$ORACLE_BASE_HOME"/network/admin 2>/dev/null
     copyTemplate "$INSTALL_DIR"/sqlnet.ora.tmpl "$ORACLE_BASE_HOME"/network/admin/sqlnet.ora replace
     copyTemplate "$INSTALL_DIR"/listener.ora.tmpl "$ORACLE_BASE_HOME"/network/admin/listener.ora replace

       if [ -f "$SETUP_DIR"/tnsnames.ora ]
     then cp "$SETUP_DIR"/tnsnames.ora "$ORACLE_BASE_HOME"/network/admin/tnsnames.ora
     else echo "$ORACLE_SID=localhost:1521/$ORACLE_SID" > "$ORACLE_BASE_HOME"/network/admin/tnsnames.ora
     fi

     # Create a database password if none exists
       if [ -z "$ORACLE_PWD" ]
     then export ORACLE_PWD="$(mkPass)"
          logger BA "Oracle password for SYS, SYSTEM and PDBADMIN: $ORACLE_PWD"
     fi

     # Create the user profile
     copyTemplate "$INSTALL_DIR"/env.tmpl "$HOME"/.bashrc append

       if [ "$(rlwrap -v)" ]
     then copyTemplate "$INSTALL_DIR"/rlwrap.tmpl "$HOME"/.bashrc append
     fi > /dev/null 2>&1

     # Create login.sql
       if [ -n "$ORACLE_PATH" ]
     then copyTemplate "$INSTALL_DIR"/login.sql.tmpl "$ORACLE_PATH"/login.sql replace
     fi

     # Run DBCA
     runDBCA
     moveFiles
     runUserScripts "$ORACLE_BASE"/scripts/setup
fi

# Check database status
  if HealthCheck
#  if [ "$?" -eq 0 ]
then runUserScripts "$ORACLE_BASE"/scripts/startup
       if [ -n "$DB_UNQNAME" ]
     then msg="$ORACLE_SID with unique name $DB_UNQNAME"
     else msg="$ORACLE_SID"
     fi
# TODO: Report the correct open mode
     logger BA "Database $msg is open and available."
else warn "Database setup for $ORACLE_SID was unsuccessful."
     warn "Check log output for additional information."
fi

# Tail on alert log and wait (otherwise container will exit)
logger B "Tailing alert_${ORACLE_SID}.log:"
tail -f "$ORACLE_BASE"/diag/rdbms/*/*/trace/alert*.log &
childPID=$!
wait $childPID
