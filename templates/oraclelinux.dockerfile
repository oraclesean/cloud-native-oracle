###FROM_BASE###

# Directory defaults
ARG SCRIPTS_DIR=/opt/scripts
ARG INSTALL_DIR=/opt/install
ARG ORACLE_PATH=/home/oracle

# Database defaults
ARG ORACLE_VERSION=###ORACLE_BASE_VERSION###

# Build defaults
ARG RPM_LIST="file git hostname less strace sudo tree vi which bash-completion"
ARG RPM_SUPPLEMENT="rlwrap"
ARG MIN_SPACE_GB=###MIN_SPACE_GB_ARG###
ARG BUILD_DATE=
ARG BUILD_VERSION=1.0
ARG MANAGE_ORACLE=manageOracle.sh
# Pass --build-arg DEBUG="bash -x" to run scripts in debug mode.
ARG DEBUG=

# Labels
LABEL org.label-schema.schema-version="1.0"
LABEL org.label-schema.url="http://oraclesean.com"
LABEL org.label-schema.version="$BUILD_VERSION"
LABEL org.label-schema.build-date="$BUILD_DATE"
LABEL org.label-schema.vcs-url="https://github.com/oraclesean"
LABEL org.label-schema.name="###OEL_IMAGE###"
LABEL org.label-schema.description="oraclelinux with Oracle Database ###PREINSTALL_TAG### prerequisites"
LABEL maintainer="Sean Scott <sean.scott@viscosityna.com>"

ENV ORACLE_PATH=$ORACLE_PATH \
    INSTALL_DIR=$INSTALL_DIR \
    SCRIPTS_DIR=$SCRIPTS_DIR \
    MANAGE_ORACLE=$MANAGE_ORACLE \
    DEBUG=$DEBUG

COPY $MANAGE_ORACLE $SCRIPTS_DIR/

# Build base image:
RUN chmod ug+x $SCRIPTS_DIR/$MANAGE_ORACLE && \
    $DEBUG $SCRIPTS_DIR/$MANAGE_ORACLE -e && \
    rm -fr /tmp/* /var/cache/yum
