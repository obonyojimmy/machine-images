#!/bin/bash
set -e
# Download github public keys from s3
aws s3 sync s3://github-team-keys/ /opt/features/ssh-keys/github-team-keys/
