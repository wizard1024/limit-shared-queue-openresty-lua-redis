#!/bin/bash

rsync -av opt/ /opt/
rsync -av opt/ root@192.168.0.2:/opt/
service openresty restart
ssh root@192.168.0.2 "service openresty restart"
