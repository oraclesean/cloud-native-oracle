# cloud-native-oracle
A repository of container image builds for Oracle databases, with support for Intel, Apple Silicon, and ARM processors.

Jump to a section:
- [Build an image](#build-an-image)
  - [Build options and examples](#build-options-and-examples)
- [Run a container](#run-a-container)
  - [Examples: Run Oracle Database containers](#run-options-and-examples)
- [Directory structure](#directory-structure)
  - [Where to put files](#file-placement)
- [Why this Repo](#why-this-repo)
  - [Features](#features)
- [Errata](#errata)

# Build an image
One [reason behind this repo](#why-this-repo) was reducing duplication. I wanted one set of scripts (not one-per-version) and less maintenance. That created a need for more than one Dockerfile (one per version) because building 11g and 21c images is *mostly* boilerplate, but not entirely, and Dockerfiles don't take variables. This repo solves that by taking boilerplate Dockerfile templates, processing them to substitute variables, and using them for the build. Named Dockerfiles enable matching .dockerignore files to limit context. But, every version still needs a unique Dockerfile. Rather than polluting the directory with versioned Dockerfiles run directly with `docker build` I'm hiding the complexity with temporary files and a shell script. Version and edition information passed to the script generates temporary Dockerfile and .dockerignore files, runs `docker build`, then deletes the temporary file.

This is a temporary workaround. I'm working on integrating new capabilities but until then, `buildDBImage.sh` manages Dockerfiles and builds.

## Build options and examples
To build a database image, run `buildDBImage.sh` and pass optional values for version, edition, tag, source, and repository name:
```
./buildDBImage.sh [version] [edition] [tag] [source] [repository]
```

- `version`: The database version to build. The value must match a version in a manifest file. (Default: `19.19`)
- `edition`: The edition to build. Acceptable values:
  - `EE`: Enterprise Edition
  - 'SE`: Standard Edition, Standard Edition 2
  - `XE`: Express Edition (Only for versions 11.2.0.2, 18.4)
- `tag`: The base OEL version. Options are `7-slim` or `8-slim`. (Default: `8-slim`)
- `source`: The OEL source. (Default: `oraclelinux`)
- `repository`: The image repository name assignment. (Default: `oraclesean/db`)

Images created by the script are named as: `[repository]:[version]-[edition]`
It additionally creates a version-specific Linux image: `[source]-[tag]-[base_version]` where the base version is 11g, 12.1, 12.2, 18c, 19c, or 21c. This Linux image includes the database prerequisites for the given version and makes building multiple database images for the same database version faster. The majority of the build time is spent applying prerequisite RPMs. The build understands if a version-ready image is present and uses it.

### Build example: Macs with Apple Silicon/ARM Systems
The only database currently supported for ARM architectures is Oracle 19.19. 
- [Download the Oracle Database 19c for LINUX ARM (aarch64)](https://www.oracle.com/database/technologies/oracle-database-software-downloads.html#db_ee) zip file and place it in the `database` subdirectory. Do not unzip the file.
- From the base directory, run the `buildDBImage.sh` script:
```
./buildDBImage.sh
# or:
./buildDBImage.sh 19.19 EE
```
This will create two images
- A "database-ready" Oracle Enterprise Linux image, with `git`, `less`, `strace`, `tree`, `vi`, `which`, `bash-completion`, and `rlwrap` installed.
  - Change these by editing the `RPM_LIST` in `templates/oraclelinux.dockerfile`, or pass a build argument. Note that you *must* include `hostname` and `file` on `oraclelinux:8-slim` builds.
- A database image with a default `ORACLE_BASE` under `/u01/app/oracle` and an `ORACLE_HOME` under `$ORACLE_BASE/product/19c/dbhome_1`.
  - Change these by editing the entries in `templates/db.dockerfile`, or pass build arguments for each parameter.

### Build example: Intel-based systems (Linux, Mac, Windows)
All database versions are supported.
- Download the appropriate installation file and place it in the `database` subdirectory.
- Download any patches to be installed and place them in the `database/patches` subdirectory.
- Update the `config/manifest` file if necessary. See the `README` file under `database` for details on formatting.
- From the base directory, run the `buildDBImage.sh` script, passing the appropriate database version, edition, and OS version:
```
# Oracle 11g:
./buildDBImage.sh 11.2.0.4 EE 7-slim
# Oracle 12.1:
./buildDBImage.sh 12.1.0.1 EE 7-slim
# Oracle 12.2:
./buildDBImage.sh 12.2 EE 7-slim
# Oracle 18c:
./buildDBImage.sh 18.3 EE 7-slim
# Oracle 19c:
./buildDBImage.sh 19 EE
# or, to build a specific version:
./buildDBImage.sh <Release Update> EE
# ... where <Release Update> is the RU to apply atop the base 19.3
# Oracle 21c:
./buildDBImage.sh 21 EE
# or, to build a specific version:
./buildDBImage.sh <Release Update> EE
# ... where <Release Update> is the RU to apply atop the base 21.3
```

## FORCE_PATCH and `.netrc`
When a `'.netrc` file is present, the `FORCE_PATCH` build argument enables patch downloads from My Oracle Support. Patches are downloaded when:
- patches listed in the manifest aren't present in the build context (not added to the `./database/patches` directory)
- the checksum of a patch doesn't match the value in the manifest
- the `FORCE_PATCH` argument matches the patch type
- the `FORCE_PATCH` argument includes the numeric patch ID

`FORCE_PATCH` may have multiple options, separated by commas:
- `all`: Download all patches listed in the manifest.
- `opatch`: Download the latest version of `opatch`.
- `patch`: Download patches but not `opatch`.
- Patch ID: The numeric patch ID of patches to download.

Pass the FORCE_PATCH value to `docker build` as `--build-arg FORCE_PATCH=<value_1>(,<value_2>,<value_n>)`

The `.netrc` file is passed to the build process in an intermediate stage as a build secret. It is not copied to the final database image.

# Run a container
Run database containers as you would normally, using `docker run [options] [image-name]`.

## Run options and examples
Options are controlled by environment variables set via the `docker run -e` flag:
- `PDB_COUNT`: Create non-container databases by setting this value to 0, or set the number of pluggable databases to be spawned.
- `CREATE_CONTAINER`: Ture/false, an alternate method for creating a non-CDB database.
- `ORACLE_PDB`: This is the prefix for the PDB's (when PDB_COUNT > 1) or the PDB_NAME (when PDB_COUNT=1, the default).
- `DB_UNQNAME`: Set the database Unique Name. Default is ORACLE_SID; used mainly for creating containers used for Data Guard where the database and unique names are different, and avoids generating multiple diagnostic directory trees.
- `PDB_LIST`: A comma-delimited list of PDB names. When present, overrides the PDB_COUNT and ORACLE_PDB values.
- `ORACLE_CHARACTERSET` and `ORACLE_NLS_CHARACTERSET`: Set database character sets.
- `INIT_PARAMS`: A list of parameters to set in the database at creation time. The default sets the DB_CREATE_FILE_DEST, DB_CREATE_ONLINE_LOG_DEST_1, and DB_RECOVERY_FILE_DEST to $ORADATA (enabling OMF) and turns off auditing.
- `DEBUG="bash -x"`: Debug container creation.

Create a non-container database:
`docker run -d -e PDB_COUNT=0 IMG_NAME`

Create a container database with custom SID and PDB name:
`docker run -d -e ORACLE_SID=mysid -e ORACLE_PDB=mypdb IMG_NAME`

Create a container database with a default SID and three PDB named mypdb[1,2,3]:
`docker run -d -e PDB_COUNT=3 -e ORACLE_PDB=mypdb IMG_NAME`

Create a container database with custom SID and named PDB:
`docker run -d -e ORACLE_SID=mydb -e PDB_LIST="test,dev,prod" IMG_NAME`

Users running ARM/Apple Silicon do not need to do anything differently. On ARM/Apple Silicon, the build process creates an architecture-native image that runs without needing any special commands or virtualization (Colima, etc).

# Example for Apple Silicon
This is an example of the output seen on a 2021 Apple MacBook Pro (M1, 16GB RAM, Ventura 13.4.1, Docker version 23.0.0, build e92dd87c32):
```

# ./buildDBImage.sh
[+] Building 51.6s (8/8) FINISHED                                                   docker:desktop-linux
 => [internal] load .dockerignore                                                                   0.0s
 => => transferring context: 2B                                                                     0.0s
 => [internal] load build definition from Dockerfile.oraclelinux.202307031409.jTxd                  0.0s
 => => transferring dockerfile: 1.55kB                                                              0.0s
 => [internal] load metadata for docker.io/library/oraclelinux:8-slim                               1.3s
 => [internal] load build context                                                                   0.0s
 => => transferring context: 45.06kB                                                                0.0s
 => CACHED [1/3] FROM docker.io/library/oraclelinux:8-slim@sha256:0226d80b442e93f977753e1d          0.0s
 => => resolve docker.io/library/oraclelinux:8-slim@sha256:0226d80b442e93f977753e1d269c8ec          0.0s
 => [2/3] COPY manageOracle.sh /opt/scripts/                                                        0.0s
 => [3/3] RUN chmod ug+x /opt/scripts/manageOracle.sh &&      /opt/scripts/manageOracle.sh         48.7s
 => exporting to image                                                                              1.5s
 => => exporting layers                                                                             1.5s
 => => writing image sha256:6cdb5ddeb9d8ffbfcaeba0cb1fad0c003dbffc3cd77b204a8ddc60292e184b          0.0s
 => => naming to docker.io/library/oraclelinux:8-slim-19c                                           0.0s
oraclelinux:8-slim-19c
[+] Building 193.8s (21/21) FINISHED                                                docker:desktop-linux
 => [internal] load .dockerignore                                                                   0.0s
 => => transferring context: 2B                                                                     0.0s
 => [internal] load build definition from Dockerfile.db.202307031410.NUni                           0.0s
 => => transferring dockerfile: 5.11kB                                                              0.0s
 => resolve image config for docker.io/docker/dockerfile:1.4                                        0.9s
 => CACHED docker-image://docker.io/docker/dockerfile:1.4@sha256:9ba7531bd80fb0a858632727c          0.0s
 => [internal] load metadata for docker.io/library/oraclelinux:8-slim-19c                           0.0s
 => [db 1/6] FROM docker.io/library/oraclelinux:8-slim-19c                                          0.0s
 => [internal] load build context                                                                  38.5s
 => => transferring context: 2.42GB                                                                38.5s
 => [db 2/6] COPY --chown=oracle:oinstall manageOracle.sh      /opt/scripts/                        0.6s
 => [stage-1 2/9] COPY --chown=oracle:oinstall ./config/dbca.*        /opt/install/                 0.6s
 => [stage-1 3/9] COPY --chown=oracle:oinstall ./config/*.tmpl        /opt/install/                 0.0s
 => [db 3/6] COPY --chown=oracle:oinstall ./config/inst.*     /opt/install/                         0.0s
 => [db 4/6] COPY --chown=oracle:oinstall ./config/manifest.* /opt/install/                         0.0s
 => [stage-1 4/9] COPY --chown=oracle:oinstall manageOracle.sh         /opt/scripts/                0.0s
 => [db 5/6] COPY --chown=oracle:oinstall ./database/         /opt/install/                         6.3s
 => [db 6/6] RUN  chmod ug+x /opt/scripts/manageOracle.sh &&      /opt/scripts/manageOracl         98.9s
 => [stage-1 5/9] COPY --chown=oracle:oinstall --from=db /u01/app/oraInventory  /u01/app/o          0.0s
 => [stage-1 6/9] COPY --chown=oracle:oinstall --from=db /u01/app/oracle /u01/app/oracle           18.6s
 => [stage-1 7/9] COPY --chown=oracle:oinstall --from=db /opt/oracle/oradata     /opt/orac          0.0s
 => [stage-1 8/9] RUN  /opt/scripts/manageOracle.sh -R                                              0.5s
 => [stage-1 9/9] WORKDIR /home/oracle                                                              0.0s
 => exporting to image                                                                             17.6s
 => => exporting layers                                                                            17.6s
 => => writing image sha256:4874efbbfe1cfb271e314ed8d6d0773e5a270d1a0b789861af76e59d4b6f82          0.0s
 => => naming to docker.io/oraclesean/db:19.19-EE                                                   0.0s
```

Total build time was 245.4 seconds. After building the image:
```
# docker images
REPOSITORY      TAG          IMAGE ID       CREATED             SIZE
oraclesean/db   19.19-EE     4874efbbfe1c   About an hour ago   5.87GB
oraclelinux     8-slim-19c   6cdb5ddeb9d8   About an hour ago   690MB
```

The ARM image size is about 2GB smaller than its corresponding Intel-based image.

Here's an example of running a network and container, with volumes defined for data, database logs, the audit directory, and a scripts directory.

## Create a network (optional)
This creates a network called `oracle-db`. This step is optional; if you elect to not create a network here, be sure to remove the network assignment from the `docker run` command.
```
docker network create oracle-db --attachable --driver bridge
```

## Set the container name and data path
Set a name for the container and a path to mount bind volumes.
```
CONTAINER_NAME=ARM
ORADATA=~/oradata
```

## Create volumes
I cannot overemphasize the value of volumes for Oracle databases. They persist data outside the container and make data independent of the container itself. Putting volatile directories outside the container's filesystem improves performance. And, volumes don't "hide" data in the `/var/lib/docker` directory of the virtual machine. You have better visibility into space use, and you're far less likely to fill the VM's disk.

## Create a script directory (optional)
This creates a shared directory in the container for saving/sharing files between container and host. If you bypass this step, be sure to remove the corresponding definition from the `docker run` command later.
```
mkdir -p $ORADATA/scripts
```

## Create the audit, data, and diagnostic directories
This creates separate subdirectories for each file type and bind mounts them to Docker volumes. Assigning them to Docker volumes means they're visible in the Docker Desktop tool, as well as through the CLI via `docker volume ls` and other commands.
```
 for dir in audit data diag
  do mkdir -p $ORADATA/${CONTAINER_NAME}/${dir}
     rm -fr $ORADATA/${CONTAINER_NAME}/${dir}/*
     docker volume rm ${CONTAINER_NAME}_${dir} 2>/dev/null
     docker volume create --opt type=none --opt o=bind \
            --opt device=$ORADATA/${CONTAINER_NAME}/${dir} \
            ${CONTAINER_NAME}_${dir}
done
```

## Remove the container (if it already exists)
If you created a container by the same name, remove it before recreating it.
```
docker rm -f $CONTAINER_NAME 2>/dev/null
```

## Create the container
In the following command, I'm creating a container named `$CONTAINER_NAME`, then:
- Mapping volumes for data (`/opt/oracle/oradata`), log data (`/u01/app/oracle/diag`), audit files (`/u01/app/oracle/admin`), and a shared directory for scripts (`/scripts`)
- Assigning the container to a network called `oracle-db`
- Setting the database SID
- Setting the name of the PDB to ${CONTAINER_NAME}PDB1
- Mapping port 8080 in the container to port 8080 on the host
- Mapping port 1521 in the container to port 51521 on the host
```
docker run -d \
       --name ${CONTAINER_NAME} \
       --volume ${CONTAINER_NAME}_data:/opt/oracle/oradata \
       --volume ${CONTAINER_NAME}_diag:/u01/app/oracle/diag \
       --volume ${CONTAINER_NAME}_audit:/u01/app/oracle/admin \
       --volume $ORADATA/scripts:/scripts \
       --network oracle-db \
       -e ORACLE_SID=${CONTAINER_NAME} \
       -e ORACLE_PDB=${CONTAINER_NAME}PDB1 \
       -p 8080:8080 \
       -p 51521:1521 \
       oraclesean/db:19.19-EE
```

Add or remove options as you see fit.

## Monitor the database creation and logs
View the database activity:
```
docker logs -f $CONTAINER_NAME
```

Sample output from a database:
```
# docker logs -f $CONTAINER_NAME

# ----------------------------------------------------------------------------------------------- #
  Oracle password for SYS, SYSTEM and PDBADMIN: HB#K_xhkwM_O10
# ----------------------------------------------------------------------------------------------- #

# ----------------------------------------------------------------------------------------------- #
  runDBCA: Running DBCA for database ARM at 2023-07-03 20:16:05
# ----------------------------------------------------------------------------------------------- #

LSNRCTL for Linux: Version 19.0.0.0.0 - Production on 03-JUL-2023 20:16:05

Copyright (c) 1991, 2023, Oracle.  All rights reserved.

Starting /u01/app/oracle/product/19c/dbhome_1/bin/tnslsnr: please wait...

TNSLSNR for Linux: Version 19.0.0.0.0 - Production
System parameter file is /u01/app/oracle/product/19c/dbhome_1/network/admin/listener.ora
Log messages written to /u01/app/oracle/diag/tnslsnr/96bb65f2a1b7/listener/alert/log.xml
Listening on: (DESCRIPTION=(ADDRESS=(PROTOCOL=ipc)(KEY=EXTPROC1)))
Listening on: (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=0.0.0.0)(PORT=1521)))

Connecting to (DESCRIPTION=(ADDRESS=(PROTOCOL=IPC)(KEY=EXTPROC1)))
STATUS of the LISTENER
------------------------
Alias                     LISTENER
Version                   TNSLSNR for Linux: Version 19.0.0.0.0 - Production
Start Date                03-JUL-2023 20:16:06
Uptime                    0 days 0 hr. 0 min. 0 sec
Trace Level               off
Security                  ON: Local OS Authentication
SNMP                      OFF
Listener Parameter File   /u01/app/oracle/product/19c/dbhome_1/network/admin/listener.ora
Listener Log File         /u01/app/oracle/diag/tnslsnr/96bb65f2a1b7/listener/alert/log.xml
Listening Endpoints Summary...
  (DESCRIPTION=(ADDRESS=(PROTOCOL=ipc)(KEY=EXTPROC1)))
  (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=0.0.0.0)(PORT=1521)))
Services Summary...
Service "ARM" has 1 instance(s).
  Instance "ARM", status UNKNOWN, has 1 handler(s) for this service...
The command completed successfully
# ----------------------------------------------------------------------------------------------- #
  runDBCA: Creating container database ARM and 3 pluggable database(s) with name ARMPDB at 2023-07-03 20:16:06
# ----------------------------------------------------------------------------------------------- #
Prepare for db operation
8% complete
Copying database files
31% complete
Creating and starting Oracle instance
32% complete
36% complete
40% complete
43% complete
46% complete
Completing Database Creation
51% complete
54% complete
Creating Pluggable Databases
58% complete
63% complete
68% complete
77% complete
Executing Post Configuration Actions
100% complete
Database creation complete. For details check the logfiles at:
 /u01/app/oracle/cfgtoollogs/dbca/ARM.
Database Information:
Global Database Name:ARM
System Identifier(SID):ARM
Look at the log file "/u01/app/oracle/cfgtoollogs/dbca/ARM/ARM.log" for further details.

Pluggable database altered.

Pluggable database altered.

# ----------------------------------------------------------------------------------------------- #
  runDBCA: DBCA complete at 2023-07-03 20:26:37
# ----------------------------------------------------------------------------------------------- #

# ----------------------------------------------------------------------------------------------- #
  Database ARM with unique name ARM is open and available.
# ----------------------------------------------------------------------------------------------- #

# ----------------------------------------------------------------------------------------------- #
  Tailing alert_ARM.log:
2023-07-03T20:26:36.493063+00:00
ARMPDB3(5):CREATE SMALLFILE TABLESPACE "USERS" LOGGING  DATAFILE  '/opt/oracle/oradata/ARM/ARMPDB3/users01.dbf' SIZE 5M REUSE AUTOEXTEND ON NEXT  1280K MAXSIZE UNLIMITED  EXTENT MANAGEMENT LOCAL  SEGMENT SPACE MANAGEMENT  AUTO
ARMPDB3(5):Completed: CREATE SMALLFILE TABLESPACE "USERS" LOGGING  DATAFILE  '/opt/oracle/oradata/ARM/ARMPDB3/users01.dbf' SIZE 5M REUSE AUTOEXTEND ON NEXT  1280K MAXSIZE UNLIMITED  EXTENT MANAGEMENT LOCAL  SEGMENT SPACE MANAGEMENT  AUTO
ARMPDB3(5):ALTER DATABASE DEFAULT TABLESPACE "USERS"
ARMPDB3(5):Completed: ALTER DATABASE DEFAULT TABLESPACE "USERS"
2023-07-03T20:26:37.882084+00:00
alter pluggable database all open
Completed: alter pluggable database all open
alter pluggable database all save state
Completed: alter pluggable database all save state
```

Database creation took about 10 minutes; note that this output is for a CDB with three Pluggable Databases (PDB).

# Directory Structure
Three subdirectories contain the majority of assets and configuration needed by images.

## `./config`
Here you'll find version-specific files and configuration, including:
- `dbca.<version>.rsp`: Every version of Oracle seems to introduce new options and features for Database Configuration Assistant (DBCA). Each version-specific file includes options with default and placeholder values. During database creation, the script replaces placeholders with values passed to the container at runtime via the `-e` option.
- `inst.<version>.rsp`: The database install response files, like the DBCA response files, include default and placeholder values for customizing database installation for any version of Oracle. The script updates the placeholder values with those present in the Dockerfile or given to the build operation through a `--build-arg` option.
- `manifest`: The manifest file includes information for all database and/or patch versions:
  ```
  # md5sum                          File name                                Type      Version  Other
  1858bd0d281c60f4ddabd87b1c214a4f  LINUX.X64_193000_db_home.zip             database  19       SE,EE
  #1f86171d22137e31cc2086bf7af36e91  oracle-database-ee-19c-1.0-1.x86_64.rpm  database  19      SE,EE
  b8e1367997544ab2790c5bcbe65ca805  p6880880_190000_Linux-x86-64.zip         opatch    19       6880880
  2a06e8c7409b21de9be6d404d39febda  p30557433_190000_Linux-x86-64.zip        patch     19.6     30557433
  0e0831a46cc3f8312a761212505ba5d1  p30565805_196000DBRU_Linux-x86-64.zip    patch     19.6     30565805
  ...
  5b2f369f6c1f0397c656a5554bc864e6  p33192793_190000_Linux-x86-64.zip        patch     19.13    33192793
  680af566ae1ed41a9916dfb0a122565c  p33457235_1913000DBRU_Linux-x86-64.zip   patch     19.13    33457235
  30eb702fe0c1bee393bb80ff8f10afe9  p33516456_190000_Linux-x86-64.zip        patch     19.13.1  33516456
  de8c41d94676479b9aa35d66ca11c96a  p33457235_1913100DBRUR_Linux-x86-64.zip  patch     19.13.1  33457235
  7bcfdcd0f3086531e232fd0237b7438f  p33515361_190000_Linux-x86-64.zip        patch     19.14    33515361
  fd96f9db3c1873dfee00efe8088186a4  p33912872_190000_Linux-x86-64.zip        patch     19       33912872
  ```  

  Column layout:
  - md5sum: The md5sum used for verification/check.
  - File name: Asset file name.
  - Type: Identifies the type of file. Possible values:
    - `database`: A file for installing database software. May be a .zip or .rpm file.
    - `opatch`: The OPatch file for this database version.
    - `patch`: Individual (non-OPatch) patch files.
  - Version: The database version the file applies to. Possible values:
    - database, opatch: The "base version" (in this example, 19).
    - patch: The patch version (eg 19.13 or 19.13.1). When a patch (or version) has multiple files, enter files in apply order, first to last.
  - Other:
    - database: Indicates Edition support.
      - `SE`: Standard Edition, Standard Edition 2
      - `EE`: Enterprise Edition
      - `SE,EE`: All editions
      - `XE`: Express Edition
    - opatch, patch: The patch number.

  Lines beginning with a `#` are ignored as comments.

  In this example, the patch number `33457235` appears twice, once for 19.13 and agains for 19.13.1, but there are version-specific files/checksums.
  Patch 33912872 appears once, with a generic version. This patch is applicable to any release but must be applied after the RU. The build process evaluates patches in order, so it will apply this general patch last.

Additional template files exist in this directory (I will eventually move them to the `template` directory for consistency). There are three categories:
- TNS configurations. Templates for setting up listener and networking configurations. Customize as necessary. During initial database creation, the files are copied to their proper locations and variables interpreted from the environment.
  - `listener.ora.tmpl` 
  - `sqlnet.ora.tmpl`
  - `tnsnames.ora.tmpl`

- Database configuration. Templates used for specialized database creation outside the "normal" automation, currently only used in upgrade images.
  - `init.ora.tmpl`

- Environment configurations. Used to set up the interactive environment in the container. Each has a specific function:
  - `env.tmpl`: Used to build `~oracle/.bashrc`. Pay attention to escaping (`\`) on variables, there to support multi-home and multi-SID environments.
  - `login.sql.tmpl`: Used to create a `login.sql` file under `$SQLPATH` that formats and customizes SQLPlus output.
  - `rlwrap.tmpl`: If `rlwrap` is present in the environment, adds aliases for `sqlplus`, `rman`, and dgmgrl` to the shell.

- Credential files:
  - `.netrc`: MOS login credentials. See the netrc.example file in this directory for format. Adding a `netrc` file allows the build process to download patches from MOS. See the FORCE_PATCH build arguement for more information.

## `./database` and `./database/patches`
**All** database and patch files go here. I redesigned the file structure of this repo in March 2022 to use a common directory for all software. Eliminating versioned subdirectories simplified file management and eliminated file duplication.

I previously supported versioning at the directory and Dockerfile level. It required a 19.13 directory (or a 19c directory and a 19.13 subdirectory), a dedicated Dockerfile, `Dockerfile.19.13`, and a matching docker ignore file, `Dockerfile.19.13.dockerignore`. But all 19c versions use the same .zip/.rpm for installation. `docker build` reads everything in the current directory and its subdirectories into its context prior to performing the build. It doesn't support links. So, to build 19.13 meant I had to have a copy of the 19c base installation media in each subdirectory. Implementation of .dockerignore requires the Dockerfile and its ignore file to have matching names. So, to limit context (preventing `docker build` from reading _every_ file at/below the build directory) I had to have separate, identically-named Dockerfile/.dockerignore files for *every version* I wanted to build.

That duplication was something I set out to to avoid. I switched instead to a dynamic build process that reads context from a common directory, using .dockerignore to narrow its scope. The advantage is having one directory and one copy for all software.

Combining this design with a manifest file means I no longer need to move patches in and out of subdirectories to control the patch level of image builds, nor worry about placing them in numbered folders to manage the apply order. Add the file to the appropriate directory (`database` or `database/patch`) and include an entry in the version manifest.

## `./templates`
Dynamic builds run from the Dockerfile templates in this directory and create two images: a database image and a database-ready Oracle Linux image.

The Oracle Enterprise Linux image, tagged with the database version, includes all database version prerequisites (notably the database preinstall RPM). The same image works for any database version installed atop it, and installing the prereqs (at least on my system) takes longer than installing database software. Rather than duplicating that work, the build looks to see if the image is present and starts there. If not, it builds the OEL image.

Do not be confused by output like this:
```
REPOSITORY    TAG          SIZE
oraclelinux   7-slim-19c   442MB
oraclelinux   7-slim       133MB
oracle/db     19.13.1-EE   7.58GB
```

The total size of these images is not 442MB + 133MB + 7.58GB. Layers in the oraclelinux:7-slim are reused in the oraclelinux:7-slim-19c image, which are reused in the oracle/db:19.13.1-EE image.

The buildDBImage.sh script reads these templates and creates temporary Dockerfiles and dockerignore files, using information in the manifest according to the version (and other information) passed to the script.

# Why this Repo
I build and run many Oracle databases in containers. There were things I didn't like about Oracle's build scripts. My goals for this repository are:
- Build any version and any patch level
  - Code should be agnostic
  - Migrate version-specific actions to templates
  - Store versioned information as configurations and manifests
  - Eliminate duplicate assets
  - Flatten and simplify the directory tree
- Streamline builds and reduce image build times
- Allow build- and run-time customization
- Avoid unnecessary environment settings
- Follow Oracle recommendations and best practices
- Support for archive and RPM-based installations
- Leverage buildx/BuildKit capabilities
- Support advanced features and customization:
  - Read-Only Homes
  - CDB and non-CDB database creation
  - For CDB databases, control the number/naming of PDBs
  - Data Guard, Sharding, RAC, GoldenGate, upgrades, etc.

There is one script to handle all operations, for all editions and versions. This adds some complexity to the script (it has to accommodate peculiarities of every version and edition) but:
- _For the most part_ these operations are identical across the board
- One script in the root directory does everything and only one script needs maintenance
- Version differences are all in one place vs. hidden in multiple files in parallel directories

The `/opt/scripts/manageOracle.sh` script manages all Oracle/Docker operations, from build through installation:
- Configures the environment
- Installs RPM
- Installs the database
- Creates the database
- Starts and stops the database
- Performs health checks

## Flexible Image Creation
Each Dockerfile uses a set of common ARG values. Defaults are set in each Dockerfile but can be overridden by passing `--build-arg` values to `docker build`. This allows a single Dockerfile to accommodate a wide range of build options without changes to any files, including:
- Removing specific components (APEX, SQL Developer, help files, etc) to minimize image size without editing scripts. It's easier to build images to include components that are normally be deleted. This is particularly useful for building images for testing 19c upgrades. APEX is included in the seed database but older APEX schemas have to be removed prior to a 19c upgrade. Where's the removal script? In the APEX directory, among those commonly removed to trim image size!
- Add programs/binaries at build time as variables, rather than in a script. Hey, sometimes you want editors or `strace` or `git`, sometimes you don't. Set the defaults to your preferred set of binaries. Override them at build time as necessary, again without having to edit/revert any files.
- Some database versions may require special RPM. Rather than maintaining that in scripts, it's in the Dockerfile (configuration).
- Add supplemental RPMs. Some RPM have dependencies (such as `rlwrap`) that require a second execution of `rpm install`. All builds treat this the same way.
  - The RPM list includes tools for interactive use of containers. 
  - Remove `git`, `less`, `strace`, `tree`, `vi`, `which`, and `bash-completion` for non-interactive environments
  - `sudo` is used to run installations from the `manageOracle.sh` script
- All builds are multi-stage with identical steps, users and operations. Differences are handled by the management script by reading configuration information from the Dockerfile, discovered in the file structure, or set in the environment.
- Customizing the directories for `ORACLE_BASE`, `ORACLE_HOME`, `oraInventory`, and the `oradata` directory.
- Specify Read-Only Oracle Home (ROOH). Set `ROOH=ENABLE` in the Dockerfile, or pass `--build-arg ROOH=ENABLE` during build.

## Install Oracle from Archive (ZIP) or RPM
RPM builds operate a little differently. They have a dependency on `root` because database configuration and startup is managed through `/etc/init.d`. The configuration is in `/etc/sysconfig`. If left at their default (I have a repo for building default RPM-based Oracle installations elsewhere) they need `root` and pose a security risk. I experimented with workarounds (adding `oracle` to `sudoers`, changing the `/etc/init.d` script group to `oinstall`, etc) but RPM-created databases still ran differently.   

I use the RPM to create the Oracle software home, then discard what's in `/etc/init.d` and `/etc/sysconfig` and create and start the database "normally" using DBCA and SQLPlus.  

This allows additional options for RPM-based installations, including changing the directory structure (for non-18c XE installs—the 18c XE home does not include libraries needed to recompile) and managing configuration through the same mechanism as "traditional" installations, meaning anything that can be applied to a "normal" install can be set in a RPM-based installation, without editing a different set of files in `/etc/sysconfig` and `ORACLE_HOME`. Express Edition on 18c (18.4) can be extended to use:
- Custom SID (not stuck with XE)
- Container or non-container
- Custom PDB name(s)
- Multiple PDB

## Flexible Container Creation
I wanted images capable of running highly customizable database environments out of the gate, that mimic what's seen in real deployments. This includes running non-CDB databases, multiple pluggable databases, case-sensitive SID and PDB names, and custom PDB naming (to name a few). Database creation is controlled and customized by passing environment variables to `docker run` via `-e VARIABLE=VALUE`. Notable options include:
- `PDB_COUNT`: Create non-container databases by setting this value to 0, or set the number of pluggable databases to be spawned.
- `CREATE_CONTAINER`: Ture/false, an alternate method for creating a non-CDB database.
- `ORACLE_PDB`: This is the prefix for the PDB's (when PDB_COUNT > 1) or the PDB_NAME (when PDB_COUNT=1, the default).
- `DB_UNQNAME`: Set the database Unique Name. Default is ORACLE_SID; used mainly for creating containers used for Data Guard where the database and unique names are different, and avoids generating multiple diagnostic directory trees.
- `PDB_LIST`: A comma-delimited list of PDB names. When present, overrides the PDB_COUNT and ORACLE_PDB values.
- `ORACLE_CHARACTERSET` and `ORACLE_NLS_CHARACTERSET`: Set database character sets.
- `INIT_PARAMS`: A list of parameters to set in the database at creation time. The default sets the DB_CREATE_FILE_DEST, DB_CREATE_ONLINE_LOG_DEST_1, and DB_RECOVERY_FILE_DEST to $ORADATA (enabling OMF) and turns off auditing.

## DEBUG mode
Debug image builds, container creation, or container operation. 
- Use `--build-arg DEBUG="bash -x"` to debug image builds
- Use `-e DEBUG="bash -x"` to debug container creation
- Use `export DEBUG="bash -x"` to turn on debugging output in a running container
- Use `unset DEBUG` to turn debugging off in a running container

# Examples
Create a non-container database:  
`docker run -d -e PDB_COUNT=0 IMG_NAME`  
Create a container database with custom SID and PDB name:  
`docker run -d -e ORACLE_SID=mysid -e ORACLE_PDB=mypdb IMG_NAME`  
Create a container database with a default SID and three PDB named mypdb[1,2,3]:  
`docker run -d -e PDB_COUNT=3 -e ORACLE_PDB=mypdb IMG_NAME`  
Create a container database with custom SID and named PDB:  
`docker run -d -e ORACLE_SID=mydb -e PDB_LIST="test,dev,prod" IMG_NAME`

# Errata

## ORACLE_PDB Behavior in Containers
There are multiple mechanisms that set the ORACLE_PDB variable in a container. It is set explicitly by passing a value (e.g. `-e ORACLE_PDB=value`) during `docker run`. This is the preferred way of doing things since it correctly sets the environment.
The value may be set implicitly four ways:
- If ORACLE_PDB is not set and the database version requires a PDB (20c and later), the value of ORACLE_PDB is inherited from the image.
- If ORACLE_PDB is not set and PDB_COUNT is non-zero, PDB_COUNT PDBs are implied. The value of ORACLE_PDB is inherited from the image.
- If both ORACLE_PDB and PDB_COUNT are set, ORACLE_PDB is assumed to be a prefix. PDB_COUNT pluggable databases are created as ${ORACLE_PDB}1 through ${ORACLE_PDB}${PDB_COUNT}. ORACLE_PDB in this case is not an actual pluggable database but a prefix.
- If ORACLE_PDB is not set and PDB_LIST contains one or more values, ORACLE_PDB is inherited from the image.
In each case the ORACLE_PDB environment variable is added to the `oracle` user's login scripts. Run that request more than one PDB (PDB_LIST, PDB_COUNT > 1) set the default value to the first PDB in the list/${ORACLE_PDB}1.
In these latter cases, the ORACLE_PDB for interactive sessions is set by login but non-interactive sessions *DO NOT* get the local value. They inherit the value from the container's native environment.
Take the following examples:
- `docker run ... -e ORACLE_PDB=PDB ...`: The interactive and non-interactive values of ORACLE_PDB match.
- 'docker run ... -e PDB_COUNT=n ...`: The interactive value of ORACLE_PDB is ORCLPDB1. The non-interactive value is ORCLPDB. This happens because the inherited value, ORCLPDB is used for non-interactive sessions.
- `docker run ... -e PDB_LIST=PDB1,MYPDB ...`: The interactive value of ORACLE_PDB is PDB1. The non-interactive value is ORCLPDB (see above).
- `docker run ... ` a 21c database: The interactive value of ORACLE_PDB is set in the DBCA scripts as ORCLPDB. The non-interactive value equals whatever is set in the Dockerfile. 
This can cause confusion when calling scripts. For example:
```
docker exec -it CON_NAME bash
env | grep ORACLE_PDB
exit
```
...will show the correct, expected value. However:
```
docker exec -it CON_NAME bash -c "env | grep ORACLE_PDB"
```
...may show a different value. This is expected (and intended and desirable—it's necessary for statelessness and idempotency) but may lead to confusion.
I recommend handling this as follows:
- Set ORACLE_PDB explicitly in `docker run` even when using PDB_LIST. PDB_LIST is evaluated first so setting ORACLE_PDB sets the environment and PDB_LIST creates multiple pluggable databases. The default PDB should be first in the list and match ORACLE_PDB.
- If you need multiple PDBs, use PDB_LIST instead of PDB_COUNT, and set ORACLE_PDB to the "default" PDB. Otherwise, the ORACLE_PDB value in non-interactive shells is the prefix and not a full/valid PDB name.

# Glossary
- APEX: Oracle Application Express, a low-code web development tool.
- CDB: Container Database - Introduced in 12c, container databases introduce capacity and security enhancements. Each CDB consists of a root container plus one or more Pluggable Databases, or PDBs.
- DBCA: Oracle Database Configuration Assistant - a tool for creating databases.
- EE: Oracle Enterprise Edition - A licensed, more robust version of Oracle that can be extended through addition of add-ons like Advanced Compression, Partitioning, etc.
- ORACLE_BASE: The base directory for Oracle software installation.
- ORACLE_HOME: The directory path containing an Oracle database software installation.
- ORACLE_INVENTORY, Oracle Inventory: Metadata of Oracle database installations on a host.
- PDB: Pluggable Database - One or more PDBs "plug in" to a container database.
- RPM: RedHat Package Manager - package files for installing software on Linux.
- runInstall: Performs Oracle database software installation.
- SE, SE2: Oracle Standard Edition/Oracle Standard Edition 2 - A licensed version of Oracle with limited features. Not all features are available, licensed, or extensive in SE/SE2. For example, partitioning is not available in SE/SE2, and RAC is limited to specific node/core counts.
- XE: Oracle Express Edition - A limited version of the Oracle database that is free to use.

## TODO:
- Replace positional options with flags
- Expand customizations
- Add flexibility to pass `--build-arg`s to the script/image
- Add a "Create Dockerfile" option (don't run the build)
- Add Dockerfile naming capability
- Add a help menu and error dialogs
- Integrate secrets
- More...
