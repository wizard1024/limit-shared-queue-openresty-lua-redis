#!/bin/bash

rsync -av opt/ /opt/
rsync -av opt/ root@app-2:/opt/
service openresty restart
ssh root@app-2 "service openresty restart"
