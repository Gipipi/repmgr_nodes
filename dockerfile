FROM debian:13
COPY repmgr_standby.sh /scripts/repmgr_standby.sh
RUN chmod +x /scripts/repmgr_standby.sh
