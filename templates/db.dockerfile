# syntax=docker/dockerfile:1.4
FROM ###FROM_OEL_BASE### as db

# Database defaults
ARG ORACLE_VERSION=###ORACLE_VERSION###
ARG ORACLE_INV=/u01/app/oraInventory
ARG ORACLE_BASE=/u01/app/oracle
ARG ORACLE_HOME=$ORACLE_BASE/product/###ORACLE_HOME_ARG###
###ORACLE_BASE_HOME_ARG###
###ORACLE_BASE_CONFIG_ARG###
ARG ORADATA=/opt/oracle/oradata
ARG ORACLE_EDITION=###ORACLE_EDITION_ARG###
ARG ORACLE_SID=###ORACLE_SID_ARG###
###ORACLE_PDB_ARG###
###PDB_COUNT_ARG###
###ORACLE_READ_ONLY_HOME_ARG###

# Pass --build-arg DEBUG="bash -x" to run scripts in debug mode.
ARG DEBUG=

# DB installation defaults
ARG INSTALL_RESPONSE=inst.###INSTALL_RESPONSE_ARG###.rsp
ARG REMOVE_COMPONENTS="DBMA,HELP,ORDS,OUI,PATCH,PILOT,SQLD,SUP,UCP,TCP,ZIP"
ARG FORCE_PATCH=
ARG FILE_MD5SUM=

# Environment settings
ENV ORACLE_BASE=$ORACLE_BASE \
    ORACLE_HOME=$ORACLE_HOME \
    ORACLE_INV=$ORACLE_INV \
    ###ORACLE_BASE_HOME_ENV###
    ###ORACLE_BASE_CONFIG_ENV###
    ORADATA=$ORADATA \
    ORACLE_VERSION=$ORACLE_VERSION \
    ORACLE_EDITION=$ORACLE_EDITION \
    ORACLE_SID=$ORACLE_SID \
    ###ORACLE_PDB_ENV###
    ###PDB_COUNT_ENV###
    ###ORACLE_ROH_ENV###
    ATTACH_HOME=$ATTACH_HOME \
    DEBUG=$DEBUG \
    PATH=$ORACLE_HOME/bin:$ORACLE_HOME/OPatch/:/usr/sbin:$PATH \
    CLASSPATH=$ORACLE_HOME/jlib:$ORACLE_HOME/rdbms/jlib \
    LD_LIBRARY_PATH=$ORACLE_HOME/lib:/usr/lib \
    TNS_ADMIN=$ORACLE_HOME/network/admin

# Copy DB install files
COPY --chown=oracle:oinstall $MANAGE_ORACLE      $SCRIPTS_DIR/
COPY --chown=oracle:oinstall ./config/inst.*     $INSTALL_DIR/
COPY --chown=oracle:oinstall ./config/manifest.* $INSTALL_DIR/
COPY --chown=oracle:oinstall ./database/         $INSTALL_DIR/

# Install DB software binaries
RUN ###MOS_SECRET### chmod ug+x $SCRIPTS_DIR/$MANAGE_ORACLE && \
    $DEBUG $SCRIPTS_DIR/$MANAGE_ORACLE -O

FROM ###FROM_OEL_BASE###

# Build defaults
ARG BUILD_DATE=
ARG BUILD_VERSION=1.0

# Database defaults
ARG ORACLE_VERSION=###ORACLE_VERSION###
ARG ORACLE_INV=/u01/app/oraInventory
ARG ORACLE_BASE=/u01/app/oracle
ARG ORACLE_HOME=$ORACLE_BASE/product/###ORACLE_HOME_ARG###
###ORACLE_BASE_HOME_ARG###
###ORACLE_BASE_CONFIG_ARG###
ARG ORADATA=/opt/oracle/oradata
ARG ORACLE_EDITION=###ORACLE_EDITION_ARG###
ARG ORACLE_SID=###ORACLE_SID_ARG###
###ORACLE_PDB_ARG###
###PDB_COUNT_ARG###
###ORACLE_READ_ONLY_HOME_ARG###

# Pass --build-arg DEBUG="bash -x" to run scripts in debug mode.
ARG DEBUG=

# Label the image:
LABEL org.label-schema.schema-version="1.0"
LABEL org.label-schema.url="http://oraclesean.com"
LABEL org.label-schema.version="$BUILD_VERSION"
LABEL org.label-schema.build-date="$BUILD_DATE"
LABEL org.label-schema.vcs-url="https://github.com/oraclesean"
LABEL org.label-schema.name="###DB_REPO###-${ORACLE_VERSION}-${ORACLE_EDITION}"
LABEL org.label-schema.description="Extensible Oracle $ORACLE_VERSION database"
LABEL org.label-schema.docker.cmd="docker run -d --name <CONTAINER_NAME> -e ORACLE_SID=<ORACLE SID> ###DOCKER_RUN_LABEL### ###DB_REPO###-${ORACLE_VERSION}-${ORACLE_EDITION}"
LABEL maintainer="Sean Scott <sean.scott@viscosityna.com>"
LABEL database.version="$ORACLE_VERSION"
LABEL database.edition="$ORACLE_EDITION"
###SOFTWARE_LABEL###
LABEL volume.data="$ORADATA"
LABEL volume.diagnostic_dest="$ORACLE_BASE/diag"
LABEL port.listener.listener1="1521"
LABEL port.oemexpress="5500"
LABEL port.http="8080"

# Environment settings
ENV ORACLE_BASE=$ORACLE_BASE \
    ORACLE_HOME=$ORACLE_HOME \
    ###ORACLE_BASE_HOME_ENV###
    ###ORACLE_BASE_CONFIG_ENV###
    ORADATA=$ORADATA \
    ORACLE_VERSION=$ORACLE_VERSION \
    ORACLE_EDITION=$ORACLE_EDITION \
    ORACLE_SID=$ORACLE_SID \
    ###ORACLE_PDB_ENV###
    ###PDB_COUNT_ENV###
    ###ORACLE_ROH_ENV###
    ATTACH_HOME=$ATTACH_HOME \
    DEBUG=$DEBUG \
    PATH=$ORACLE_HOME/bin:$ORACLE_HOME/OPatch/:/usr/sbin:$PATH \
    CLASSPATH=$ORACLE_HOME/jlib:$ORACLE_HOME/rdbms/jlib \
    LD_LIBRARY_PATH=$ORACLE_HOME/lib:/usr/lib \
    TNS_ADMIN=$ORACLE_HOME/network/admin

USER oracle
COPY --chown=oracle:oinstall ./config/dbca.*        $INSTALL_DIR/
COPY --chown=oracle:oinstall ./config/*.tmpl        $INSTALL_DIR/
COPY --chown=oracle:oinstall $MANAGE_ORACLE         $SCRIPTS_DIR/
COPY --chown=oracle:oinstall --from=db $ORACLE_INV  $ORACLE_INV
COPY --chown=oracle:oinstall --from=db $ORACLE_BASE $ORACLE_BASE
COPY --chown=oracle:oinstall --from=db $ORADATA     $ORADATA

USER root
RUN $DEBUG $SCRIPTS_DIR/$MANAGE_ORACLE -R

USER oracle
WORKDIR /home/oracle

VOLUME ["$ORADATA"]
VOLUME [ "$ORACLE_BASE/diag" ]
###SYSTEMD_VOLUME###
EXPOSE 1521 5500 8080
HEALTHCHECK --interval=1m --start-period=5m CMD $SCRIPTS_DIR/$MANAGE_ORACLE -h >/dev/null || exit 1
CMD exec $DEBUG $SCRIPTS_DIR/$MANAGE_ORACLE
