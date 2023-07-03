logger() {
  local __format="$1"
  shift 1

  __line="# ----------------------------------------------------------------------------------------------- #"

    if [[ $__format =~ B ]]
  then printf "\n${__line}\n"
  elif [[ $__format =~ b ]]
  then printf "\n"
  fi

  printf "%s\n" "  $@"

    if [[ $__format =~ A ]]
  then printf "${__line}\n\n"
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
       __s2="${2//\n/}" #"$(echo $2 | sed 's/\n//g')"
       printf "%-40s: %s\n" "$__s1" "$__s2" | tee -a "$3"
  fi
}

fixcase() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

FIXCASE() {
  echo "$1" | tr '[:lower:]' '[:upper:]'
}

replaceVars() {
  local __file="$1"
  local __var="$2"
    if [ -z "$3" ]
  then local __val="$(eval echo "\$$(echo "$__var")")"
  else local __val="$3"
  fi
  sed -i '' -e "s|###${__var}###|"${__val}"|g" "$__file"
}

checkSum() {
  # $1 is the file name containing the md5 hashes
  # $2 is the extension to check
  grep -E "${2}$" "$1" | while read checksum_value filename
    do
       # md5sum is present and values do not match
         if [ "$(type md5sum 2>/dev/null)" ] && [ ! "$(md5sum "$INSTALL_DIR"/"$filename" | awk '{print $1}')" == "$checksum_value" ]
       then error "Checksum for $filename did not match"
       else # Unzip to the correct directory--ORACLE_HOME for 18c/19c, INSTALL_DIR for others
            case $ORACLE_VERSION in
                 18.*|19.*|21.*) sudo su - oracle -c "unzip -oq -d $ORACLE_HOME $INSTALL_DIR/$filename" ;;
                              *) sudo su - oracle -c "unzip -oq -d $INSTALL_DIR $INSTALL_DIR/$filename" ;;
            esac
       fi
  done
}

