#!/bin/bash
# runs INSIDE the edgeai container; env set here because lxc-attach does not
# reliably carry the unit's Environment= through
exec env NN_HUB_URL=REPLACE_WITH_HUB_URL NN_REPORT_HOST=REPLACE_WITH_HOST_NAME \
  python3 /opt/nn/inferd/inferd_report.py
